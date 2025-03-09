defmodule Sequin.Runtime.SlotProcessorServer do
  @moduledoc """
  Subscribes to the Postgres replication slot, decodes write ahead log binary messages
  and publishes them to a stream.
  """

  # See below, where we set restart: :temporary
  use Sequin.Postgres.ReplicationConnection

  import Sequin.Error.Guards, only: [is_error: 1]

  alias __MODULE__
  alias Ecto.Adapters.SQL.Sandbox
  alias Sequin.Constants
  alias Sequin.Databases.ConnectionCache
  alias Sequin.Error
  alias Sequin.Error.InvariantError
  alias Sequin.Error.ServiceError
  alias Sequin.Health
  alias Sequin.Health.Event
  alias Sequin.Postgres
  alias Sequin.Postgres.ReplicationConnection
  alias Sequin.Repo
  alias Sequin.Runtime
  alias Sequin.Runtime.MessageHandler
  alias Sequin.Runtime.PostgresAdapter.Decoder
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Begin
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Commit
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Delete
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Insert
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.LogicalMessage
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Relation
  alias Sequin.Runtime.PostgresAdapter.Decoder.Messages.Update
  alias Sequin.Runtime.SlotMessageStore
  alias Sequin.Runtime.SlotProcessor
  alias Sequin.Runtime.SlotProcessor.Message
  alias Sequin.Runtime.SlotProcessor.State
  alias Sequin.Workers.CreateReplicationSlotWorker

  require Logger

  # 100 MB
  @max_accumulated_bytes 100 * 1024 * 1024
  @max_accumulated_messages 100_000
  @backfill_batch_high_watermark Constants.backfill_batch_high_watermark()

  @config_schema Application.compile_env(:sequin, [Sequin.Repo, :config_schema_prefix])
  @stream_schema Application.compile_env(:sequin, [Sequin.Repo, :stream_schema_prefix])

  def max_accumulated_bytes do
    Application.get_env(:sequin, :slot_processor_max_accumulated_bytes) || @max_accumulated_bytes
  end

  def max_accumulated_messages do
    Application.get_env(:sequin, :slot_processor_max_accumulated_messages) || @max_accumulated_messages
  end

  def max_accumulated_messages_time_ms do
    case Application.get_env(:sequin, :slot_processor_max_accumulated_messages_time_ms) do
      nil ->
        if Application.get_env(:sequin, :env) == :test do
          # We can lower this even more when we handle heartbeat messages sync
          # Right now, there are races where we receive a heartbeat message before our
          # regular messages get a chance to come through and be part of the batch.
          30
        else
          100
        end

      value ->
        value
    end
  end

  def set_max_accumulated_messages(value) do
    Application.put_env(:sequin, :slot_processor_max_accumulated_messages, value)
  end

  def set_max_accumulated_bytes(value) do
    Application.put_env(:sequin, :slot_processor_max_accumulated_bytes, value)
  end

  def set_max_accumulated_messages_time_ms(value) do
    Application.put_env(:sequin, :slot_processor_max_accumulated_messages_time_ms, value)
  end

  def ets_table, do: __MODULE__

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    connection = Keyword.fetch!(opts, :connection)
    publication = Keyword.fetch!(opts, :publication)
    slot_name = Keyword.fetch!(opts, :slot_name)
    postgres_database = Keyword.fetch!(opts, :postgres_database)
    replication_slot = Keyword.fetch!(opts, :replication_slot)
    test_pid = Keyword.get(opts, :test_pid)
    message_handler_ctx = Keyword.fetch!(opts, :message_handler_ctx)
    message_handler_module = Keyword.fetch!(opts, :message_handler_module)
    max_memory_bytes = Keyword.get_lazy(opts, :max_memory_bytes, &default_max_memory_bytes/0)
    bytes_between_limit_checks = Keyword.get(opts, :bytes_between_limit_checks, div(max_memory_bytes, 100))

    rep_conn_opts =
      [auto_reconnect: true, name: via_tuple(id)]
      |> Keyword.merge(connection)
      # Very important. If we don't add this, ReplicationConnection will block start_link (and the
      # calling process!) while it connects.
      |> Keyword.put(:sync_connect, false)

    init = %State{
      id: id,
      publication: publication,
      slot_name: slot_name,
      postgres_database: postgres_database,
      replication_slot: replication_slot,
      test_pid: test_pid,
      message_handler_ctx: message_handler_ctx,
      message_handler_module: message_handler_module,
      connection: connection,
      last_commit_lsn: nil,
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, :timer.minutes(1)),
      max_memory_bytes: max_memory_bytes,
      bytes_between_limit_checks: bytes_between_limit_checks,
      check_memory_fn: Keyword.get(opts, :check_memory_fn, &default_check_memory_fn/0),
      safe_wal_cursor_fn: Keyword.get(opts, :safe_wal_cursor_fn, &default_safe_wal_cursor_fn/1)
    }

    ReplicationConnection.start_link(SlotProcessorServer, init, rep_conn_opts)
  end

  def child_spec(opts) do
    # Not used by DynamicSupervisor, but used by Supervisor in test
    id = Keyword.fetch!(opts, :id)

    spec = %{
      id: via_tuple(id),
      start: {__MODULE__, :start_link, [opts]}
    }

    # Eventually, we can wrap this in a Supervisor, to get faster retries on restarts before "giving up"
    # The Starter will eventually restart this SlotProcessorServer GenServer.
    Supervisor.child_spec(spec, restart: :permanent)
  end

  @spec update_message_handler_ctx(id :: String.t(), ctx :: any()) :: :ok | {:error, :not_running}
  def update_message_handler_ctx(id, ctx) do
    GenServer.call(via_tuple(id), {:update_message_handler_ctx, ctx})
  catch
    :exit, {:noproc, {GenServer, :call, _}} ->
      {:error, :not_running}
  end

  def monitor_message_store(id, consumer) do
    GenServer.call(via_tuple(id), {:monitor_message_store, consumer}, :timer.seconds(120))
  end

  def demonitor_message_store(id, consumer_id) do
    GenServer.call(via_tuple(id), {:demonitor_message_store, consumer_id})
  end

  def via_tuple(id) do
    {:via, :syn, {:replication, {__MODULE__, id}}}
  end

  @impl ReplicationConnection
  def init(%State{} = state) do
    Logger.metadata(
      account_id: state.postgres_database.account_id,
      replication_id: state.id,
      database_id: state.postgres_database.id
    )

    Logger.info(
      "[SlotProcessorServer] Initialized with opts: #{inspect(Keyword.delete(state.connection, :password), pretty: true)}"
    )

    if state.test_pid do
      Mox.allow(Sequin.Runtime.SlotMessageHandlerMock, state.test_pid, self())
      Mox.allow(Sequin.TestSupport.DateTimeMock, state.test_pid, self())
      Mox.allow(Sequin.TestSupport.EnumMock, state.test_pid, self())
      Sandbox.allow(Sequin.Repo, state.test_pid, self())
    end

    state = schedule_heartbeat(state, 0)
    schedule_process_logging(0)

    {:ok, %{state | step: :disconnected}}
  end

  @impl ReplicationConnection
  def handle_connect(%State{connect_attempts: attempts} = state) when attempts >= 5 do
    Logger.error("[SlotProcessorServer] Failed to connect to replication slot after 5 attempts")

    conn = get_cached_conn(state)

    error_msg =
      case Postgres.fetch_replication_slot(conn, state.slot_name) do
        {:ok, %{"active" => false}} ->
          "Failed to connect to replication slot after 5 attempts"

        {:ok, %{"active" => true}} ->
          "Replication slot '#{state.slot_name}' is currently in use by another connection"

        {:error, %Error.NotFoundError{}} ->
          maybe_recreate_slot(state)
          "Replication slot '#{state.slot_name}' does not exist"

        {:error, error} ->
          Exception.message(error)
      end

    Health.put_event(
      state.replication_slot,
      %Event{slug: :replication_connected, status: :fail, error: Error.service(service: :replication, message: error_msg)}
    )

    launch_stop(state)

    {:noreply, state}
  end

  def handle_connect(state) do
    Logger.debug("[SlotProcessorServer] Handling connect (attempt #{state.connect_attempts + 1})")

    {:ok, low_watermark_wal_cursor} = Sequin.Replication.low_watermark_wal_cursor(state.id)

    query =
      if state.id in ["59d70fc1-e6a2-4c0e-9f4d-c5ced151cec1", "dcfba45f-d503-4fef-bb11-9221b9efa70a"] do
        "START_REPLICATION SLOT #{state.slot_name} LOGICAL 0/0 (proto_version '1', publication_names '#{state.publication}')"
      else
        "START_REPLICATION SLOT #{state.slot_name} LOGICAL 0/0 (proto_version '1', publication_names '#{state.publication}', messages 'true')"
      end

    current_memory = state.check_memory_fn.()

    if current_memory > state.max_memory_bytes do
      Logger.warning("[SlotProcessorServer] System at memory limit, shutting down",
        limit: state.max_memory_bytes,
        current_memory: current_memory
      )

      launch_stop(state)
    end

    {:stream, query, [],
     %{
       state
       | step: :streaming,
         connect_attempts: state.connect_attempts + 1,
         low_watermark_wal_cursor: low_watermark_wal_cursor
     }}
  end

  @impl ReplicationConnection
  def handle_result(result, state) do
    Logger.warning("Unknown result: #{inspect(result)}")
    {:noreply, state}
  end

  @spec stop(pid) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @impl ReplicationConnection
  def handle_data(data, %State{} = state) do
    execute_timed(:handle_data_sequin, fn ->
      # TODO: Move to better spot by having ReplicationConnection callback when it connects
      Health.put_event(
        state.replication_slot,
        %Event{slug: :replication_connected, status: :success}
      )

      # Because these are <14 Postgres databases, they will not receive heartbeat messages
      # temporarily mark them as healthy if we receive a keepalive message
      if state.id in ["59d70fc1-e6a2-4c0e-9f4d-c5ced151cec1", "dcfba45f-d503-4fef-bb11-9221b9efa70a"] do
        Health.put_event(
          state.replication_slot,
          %Event{slug: :replication_heartbeat_received, status: :success}
        )
      end

      case SlotProcessor.handle_data(data, state) do
        {:ok, replies, state} ->
          maybe_schedule_flush(state)

          should_flush? =
            state.accumulated_msg_binaries.count > max_accumulated_messages() or
              state.accumulated_msg_binaries.bytes > max_accumulated_bytes()

          state = if should_flush?, do: flush_messages(state), else: state
          {:noreply, replies, state}

        {:error, %InvariantError{code: :over_system_memory_limit}} ->
          Health.put_event(
            state.replication_slot,
            %Event{slug: :replication_memory_limit_exceeded, status: :info}
          )

          Logger.warning("[SlotProcessorServer] System hit memory limit, shutting down",
            limit: state.max_memory_bytes,
            current_memory: state.check_memory_fn.()
          )

          state = flush_messages(state)
          launch_stop(state)
          {:noreply, state}
      end
    end)
  rescue
    e ->
      Logger.error("Error processing message: #{inspect(e)}")

      error = if is_error(e), do: e, else: Error.service(service: :replication, message: Exception.message(e))

      Health.put_event(
        state.replication_slot,
        %Event{slug: :replication_message_processed, status: :fail, error: error}
      )

      reraise e, __STACKTRACE__
  end

  @impl ReplicationConnection
  def handle_call({:update_message_handler_ctx, ctx}, from, %State{} = state) do
    execute_timed(:update_message_handler_ctx, fn ->
      :ok = state.message_handler_module.reload_entities(ctx)
      state = %{state | message_handler_ctx: ctx}
      # Need to manually send reply
      GenServer.reply(from, :ok)
      {:noreply, state}
    end)
  end

  @impl ReplicationConnection
  def handle_call({:monitor_message_store, consumer}, from, state) do
    execute_timed(:monitor_message_store, fn ->
      if Map.has_key?(state.message_store_refs, consumer.id) do
        GenServer.reply(from, :ok)
        {:noreply, state}
      else
        # Monitor just the first partition (there's always at least one) and if any crash they will all restart
        # due to supervisor setting of :one_for_all
        pid = GenServer.whereis(SlotMessageStore.via_tuple(consumer.id, 0))
        ref = Process.monitor(pid)
        :ok = SlotMessageStore.set_monitor_ref(consumer, ref)
        Logger.info("Monitoring message store for consumer #{consumer.id}")
        GenServer.reply(from, :ok)
        {:noreply, %{state | message_store_refs: Map.put(state.message_store_refs, consumer.id, ref)}}
      end
    end)
  end

  @impl ReplicationConnection
  def handle_call({:demonitor_message_store, consumer_id}, from, state) do
    execute_timed(:demonitor_message_store, fn ->
      case state.message_store_refs[consumer_id] do
        nil ->
          Logger.warning("No monitor found for consumer #{consumer_id}")
          GenServer.reply(from, :ok)
          {:noreply, state}

        ref ->
          res = Process.demonitor(ref)
          Logger.info("Demonitored message store for consumer #{consumer_id}: (res=#{inspect(res)})")
          GenServer.reply(from, :ok)
          {:noreply, %{state | message_store_refs: Map.delete(state.message_store_refs, consumer_id)}}
      end
    end)
  end

  @impl ReplicationConnection
  def handle_info(:flush_messages, %State{} = state) do
    execute_timed(:handle_info_flush_messages, fn ->
      {:noreply, flush_messages(%{state | flush_timer: nil})}
    end)
  end

  @impl ReplicationConnection
  def handle_info({:EXIT, _pid, :normal}, %State{} = state) do
    # Probably a Flow process
    {:noreply, state}
  end

  @impl ReplicationConnection
  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{} = state) do
    if Application.get_env(:sequin, :env) == :test and reason == :shutdown do
      {:noreply, state}
    else
      {consumer_id, ^ref} = Enum.find(state.message_store_refs, fn {_, r} -> r == ref end)

      Logger.error(
        "[SlotProcessorServer] SlotMessageStore died. Shutting down.",
        consumer_id: consumer_id,
        reason: reason
      )

      raise "SlotMessageStore died (consumer_id=#{consumer_id}, reason=#{inspect(reason)})"
    end
  end

  @impl ReplicationConnection
  def handle_info(:emit_heartbeat, %State{id: "dcfba45f-d503-4fef-bb11-9221b9efa70a"} = state) do
    execute_timed(:handle_info_emit_heartbeat, fn ->
      # Carve out for individual cloud customer who still needs to upgrade to Postgres 14+
      # This heartbeat is not used for health, but rather to advance the slot even if tables are dormant.
      conn = get_cached_conn(state)

      # We can schedule right away, as we'll not be receiving a heartbeat message
      state = schedule_heartbeat(%{state | heartbeat_timer: nil})

      q =
        "insert into sequin_heartbeat(id, updated_at) values (1, now()) on conflict (id) do update set updated_at = now()"

      case Postgres.query(conn, q) do
        {:ok, _res} ->
          Logger.info("Emitted heartbeat", emitted_at: Sequin.utc_now())

        {:error, error} ->
          Logger.error("Error emitting heartbeat: #{inspect(error)}")
      end

      {:noreply, state}
    end)
  end

  def handle_info(:emit_heartbeat, %State{} = state) do
    execute_timed(:emit_heartbeat, fn ->
      conn = get_cached_conn(state)

      emitted_at = Sequin.utc_now()

      case Postgres.query(conn, "SELECT pg_logical_emit_message(true, 'sequin.heartbeat.0', '#{emitted_at}')") do
        {:ok, _res} ->
          Logger.info("Emitted heartbeat", emitted_at: emitted_at)

        {:error, error} ->
          Logger.error("Error emitting heartbeat: #{inspect(error)}")
      end

      {:noreply, %{state | heartbeat_timer: nil}}
    end)
  end

  @impl ReplicationConnection
  def handle_info(:process_logging, state) do
    info =
      Process.info(self(), [
        # Total memory used by process in bytes
        :memory,
        # Number of messages in queue
        :message_queue_len
      ])

    last_logged_at = Process.get(:last_logged_at)
    raw_bytes_received_since_last_log = Process.get(:raw_bytes_received_since_last_log)
    messages_processed_since_last_log = Process.get(:messages_processed_since_last_log)
    seconds_diff = if last_logged_at, do: DateTime.diff(Sequin.utc_now(), last_logged_at, :second), else: 0

    ms_since_last_logged_at =
      if last_logged_at, do: DateTime.diff(Sequin.utc_now(), last_logged_at, :millisecond)

    {messages_per_second, raw_bytes_per_second} =
      if is_integer(messages_processed_since_last_log) and is_integer(raw_bytes_received_since_last_log) and
           seconds_diff > 0 do
        {messages_processed_since_last_log / seconds_diff, raw_bytes_received_since_last_log / seconds_diff}
      else
        {0.0, 0.0}
      end

    Logger.info(
      "[SlotProcessorServer] #{Float.round(messages_per_second, 1)} messages/s, #{Sequin.String.format_bytes(raw_bytes_per_second)}/s"
    )

    # Get all timing metrics from process dictionary
    timing_metrics =
      Process.get()
      |> Enum.filter(fn {key, _} ->
        key |> to_string() |> String.ends_with?("_total_ms")
      end)
      |> Keyword.new()

    count_metrics =
      Process.get()
      |> Enum.filter(fn {key, _} ->
        key |> to_string() |> String.ends_with?("_count")
      end)
      |> Keyword.new()

    # Log all timing metrics as histograms with operation tag
    Enum.each(timing_metrics, fn {key, value} ->
      operation = key |> to_string() |> String.replace("_total_ms", "")

      Sequin.Statsd.histogram("sequin.slot_processor.operation_time_ms", value,
        tags: %{
          replication_slot_id: state.replication_slot.id,
          operation: operation
        }
      )
    end)

    unaccounted_ms =
      if ms_since_last_logged_at do
        # Calculate total accounted time
        slot_processor_metrics =
          MapSet.new([
            :handle_data_total_ms,
            :handle_data_keepalive_total_ms,
            :update_message_handler_ctx_total_ms,
            :monitor_message_store_total_ms,
            :demonitor_message_store_total_ms,
            :handle_info_emit_heartbeat_total_ms,
            :emit_heartbeat_total_ms,
            :flush_messages_total_ms
          ])

        total_accounted_ms =
          Enum.reduce(timing_metrics, 0, fn {key, value}, acc ->
            if MapSet.member?(slot_processor_metrics, key), do: acc + value, else: acc
          end)

        # Calculate unaccounted time
        max(0, ms_since_last_logged_at - total_accounted_ms)
      end

    if unaccounted_ms do
      # Log unaccounted time with same metric but different operation tag
      Sequin.Statsd.histogram("sequin.slot_processor.operation_time_ms", unaccounted_ms,
        tags: %{
          replication_slot_id: state.replication_slot.id,
          operation: "unaccounted"
        }
      )
    end

    metadata =
      [
        memory_mb: Float.round(info[:memory] / 1_024 / 1_024, 2),
        message_queue_len: info[:message_queue_len],
        accumulated_payload_size_bytes: state.accumulated_msg_binaries.bytes,
        accumulated_message_count: state.accumulated_msg_binaries.count,
        last_commit_lsn: state.last_commit_lsn,
        low_watermark_wal_cursor_lsn: state.low_watermark_wal_cursor[:commit_lsn],
        low_watermark_wal_cursor_idx: state.low_watermark_wal_cursor[:commit_idx],
        messages_processed: Process.get(:messages_processed, 0),
        raw_bytes_received: Process.get(:raw_bytes_received, 0),
        messages_per_second: messages_per_second,
        raw_bytes_per_second: raw_bytes_per_second
      ]
      |> Keyword.merge(timing_metrics)
      |> Keyword.merge(count_metrics)
      |> Sequin.Keyword.put_if_present(:unaccounted_total_ms, unaccounted_ms)

    Logger.info("[SlotProcessorServer] Process metrics", metadata)

    # Clear timing metrics after logging
    timing_metrics
    |> Keyword.keys()
    |> Enum.each(&clear_counter/1)

    count_metrics
    |> Keyword.keys()
    |> Enum.each(&clear_counter/1)

    clear_counter(:messages_processed)
    clear_counter(:messages_processed_since_last_log)
    clear_counter(:raw_bytes_received)
    clear_counter(:raw_bytes_received_since_last_log)

    Process.put(:last_logged_at, Sequin.utc_now())
    schedule_process_logging()

    {:noreply, state}
  end

  defp maybe_schedule_flush(%State{flush_timer: nil} = state) do
    ref = Process.send_after(self(), :flush_messages, max_accumulated_messages_time_ms())
    %{state | flush_timer: ref}
  end

  defp maybe_schedule_flush(%State{flush_timer: ref} = state) when is_reference(ref) do
    state
  end

  defp schedule_process_logging(interval \\ :timer.seconds(10)) do
    Process.send_after(self(), :process_logging, interval)
  end

  defp schedule_heartbeat(state, interval \\ nil)

  defp schedule_heartbeat(%State{heartbeat_timer: nil} = state, interval) do
    ref = Process.send_after(self(), :emit_heartbeat, interval || state.heartbeat_interval)
    %{state | heartbeat_timer: ref}
  end

  defp schedule_heartbeat(%State{heartbeat_timer: ref} = state, _interval) when is_reference(ref) do
    state
  end

  defp maybe_recreate_slot(%State{connection: connection} = state) do
    # Neon databases have ephemeral replication slots. At time of writing, this
    # happens after 45min of inactivity.
    # In the future, we will want to "rewind" the slot on create to last known good LSN
    if String.ends_with?(connection[:hostname], ".aws.neon.tech") do
      CreateReplicationSlotWorker.enqueue(state.id)
    end
  end

  defp skip_message?(%Message{} = msg, %State{} = state) do
    %{commit_lsn: low_watermark_lsn, commit_idx: low_watermark_idx} = state.low_watermark_wal_cursor
    {message_lsn, message_idx} = {msg.commit_lsn, msg.commit_idx}

    lte_watermark? =
      message_lsn < low_watermark_lsn or (message_lsn == low_watermark_lsn and message_idx <= low_watermark_idx)

    lte_watermark? or (msg.table_schema in [@config_schema, @stream_schema] and msg.table_schema != "public")
  end

  @spec process_message(State.t(), map()) :: {State.t(), map() | nil}
  defp process_message(
         %State{last_commit_lsn: last_commit_lsn} = state,
         %Begin{commit_timestamp: ts, final_lsn: lsn, xid: xid} = msg
       ) do
    begin_lsn = Postgres.lsn_to_int(lsn)

    state =
      if not is_nil(last_commit_lsn) and begin_lsn < last_commit_lsn do
        Logger.error(
          "Received a Begin message with an LSN that is less than the last commit LSN (#{begin_lsn} < #{last_commit_lsn})"
        )

        %{state | dirty: true}
      else
        state
      end

    {%State{state | current_commit_ts: ts, current_commit_idx: 0, current_xaction_lsn: begin_lsn, current_xid: xid}, msg}
  end

  # Ensure we do not have an out-of-order bug by asserting equality
  defp process_message(
         %State{current_xaction_lsn: current_lsn, current_commit_ts: ts, id: id} = state,
         %Commit{lsn: lsn, commit_timestamp: ts} = msg
       ) do
    lsn = Postgres.lsn_to_int(lsn)

    unless current_lsn == lsn do
      raise "Unexpectedly received a commit LSN that does not match current LSN (#{current_lsn} != #{lsn})"
    end

    :ets.insert(ets_table(), {{id, :last_committed_at}, ts})

    {%State{
       state
       | last_commit_lsn: lsn,
         current_xaction_lsn: nil,
         current_xid: nil,
         current_commit_ts: nil,
         current_commit_idx: 0,
         dirty: false
     }, msg}
  end

  defp process_message(%State{} = state, %Message{} = msg) do
    msg = %Message{
      msg
      | commit_lsn: state.current_xaction_lsn,
        commit_idx: state.current_commit_idx,
        commit_timestamp: state.current_commit_ts
    }

    # TracerServer.message_replicated(state.postgres_database, msg)

    Health.put_event(
      state.replication_slot,
      %Event{slug: :replication_message_processed, status: :success}
    )

    {%State{state | current_commit_idx: state.current_commit_idx + 1}, msg}
  end

  # Ignore type messages, we receive them before type columns:
  # %Sequin.Extensions.PostgresAdapter.Decoder.Messages.Type{id: 551312, namespace: "public", name: "citext"}
  # Custom enum:
  # %Sequin.Extensions.PostgresAdapter.Decoder.Messages.Type{id: 3577319, namespace: "public", name: "character_status"}
  defp process_message(%State{} = state, %Decoder.Messages.Type{}) do
    {state, nil}
  end

  defp process_message(%State{} = state, %LogicalMessage{prefix: "sequin.heartbeat.0", content: emitted_at}) do
    Logger.info("[SlotProcessorServer] Heartbeat received", emitted_at: emitted_at)
    Health.put_event(state.replication_slot, %Event{slug: :replication_heartbeat_received, status: :success})

    state = schedule_heartbeat(state)

    if state.test_pid do
      # TODO: Decouple
      send(state.test_pid, {__MODULE__, :heartbeat_received})
    end

    {state, nil}
  end

  defp process_message(%State{} = state, %LogicalMessage{prefix: @backfill_batch_high_watermark} = msg) do
    {%State{state | backfill_watermark_messages: [msg | state.backfill_watermark_messages]}, nil}
  end

  # Ignore other logical messages
  defp process_message(%State{} = state, %LogicalMessage{}) do
    {state, nil}
  end

  # It's important we assert this message is not a message that we *should* have a handler for
  defp process_message(%State{} = state, %struct{} = msg)
       when struct not in [Begin, Commit, Message, LogicalMessage, Relation] do
    Logger.error("Unknown message: #{inspect(msg)}")
    {state, nil}
  end

  @spec maybe_cast_message(decoded_message :: map(), schemas :: map()) :: Message.t() | map()
  defp maybe_cast_message(%Insert{} = msg, schemas) do
    %{columns: columns, schema: schema, table: table, parent_table_id: parent_table_id} =
      Map.get(schemas, msg.relation_id)

    ids = data_tuple_to_ids(columns, msg.tuple_data)

    %Message{
      action: :insert,
      errors: nil,
      ids: ids,
      table_schema: schema,
      table_name: table,
      table_oid: parent_table_id,
      fields: data_tuple_to_fields(ids, columns, msg.tuple_data),
      trace_id: UUID.uuid4()
    }
  end

  defp maybe_cast_message(%Update{} = msg, schemas) do
    %{columns: columns, schema: schema, table: table, parent_table_id: parent_table_id} =
      Map.get(schemas, msg.relation_id)

    ids = data_tuple_to_ids(columns, msg.tuple_data)

    old_fields =
      if msg.old_tuple_data do
        data_tuple_to_fields(ids, columns, msg.old_tuple_data)
      end

    %Message{
      action: :update,
      errors: nil,
      ids: ids,
      table_schema: schema,
      table_name: table,
      table_oid: parent_table_id,
      old_fields: old_fields,
      fields: data_tuple_to_fields(ids, columns, msg.tuple_data),
      trace_id: UUID.uuid4()
    }
  end

  defp maybe_cast_message(%Delete{} = msg, schemas) do
    %{columns: columns, schema: schema, table: table, parent_table_id: parent_table_id} =
      Map.get(schemas, msg.relation_id)

    prev_tuple_data =
      if msg.old_tuple_data do
        msg.old_tuple_data
      else
        msg.changed_key_tuple_data
      end

    ids = data_tuple_to_ids(columns, prev_tuple_data)

    %Message{
      action: :delete,
      errors: nil,
      ids: ids,
      table_schema: schema,
      table_name: table,
      table_oid: parent_table_id,
      old_fields: data_tuple_to_fields(ids, columns, prev_tuple_data),
      trace_id: UUID.uuid4()
    }
  end

  defp maybe_cast_message(msg, _schemas), do: msg

  defp flush_messages(%State{accumulated_msg_binaries: %{count: 0}} = state), do: state

  defp flush_messages(%State{} = state) do
    execute_timed(:flush_messages, fn ->
      if ref = state.flush_timer do
        Process.cancel_timer(ref)
      end

      accumulated_binares = state.accumulated_msg_binaries.binaries
      schemas = state.schemas

      messages =
        accumulated_binares
        |> Enum.reverse()
        |> Enum.with_index()
        |> Flow.from_enumerable(max_demand: 50, min_demand: 25)
        |> Flow.map(fn {msg, idx} ->
          {msg |> Decoder.decode_message() |> maybe_cast_message(schemas), idx}
        end)
        # Merge back to single partition - always use 1 stage to ensure ordering
        |> Flow.partition(stages: 1)
        # Sort by original index
        |> Enum.sort_by(&elem(&1, 1))
        # Extract just the messages
        |> Enum.map(&elem(&1, 0))

      if Enum.any?(messages, &(not match?(%LogicalMessage{prefix: "sequin.heartbeat.0"}, &1))) do
        # A replication message is *their* message(s), not our message.
        Health.put_event(
          state.replication_slot,
          %Event{slug: :replication_message_processed, status: :success}
        )
      end

      {state, messages} =
        Enum.reduce(messages, {state, []}, fn msg, {state, messages} ->
          case process_message(state, msg) do
            {%State{} = state, %Message{} = message} ->
              if skip_message?(message, state) do
                {state, messages}
              else
                {state, [message | messages]}
              end

            {%State{} = state, _} ->
              {state, messages}
          end
        end)

      messages = Enum.reverse(messages)

      count = length(messages)
      incr_counter(:messages_processed, count)
      incr_counter(:messages_processed_since_last_log, count)

      # Flush accumulated messages
      # Temp: Do this here, as handle_messages call is going to become async
      state.message_handler_module.before_handle_messages(state.message_handler_ctx, messages)

      {time, res} =
        :timer.tc(fn ->
          state.message_handler_module.handle_messages(state.message_handler_ctx, messages)
        end)

      state.backfill_watermark_messages
      |> Enum.reverse()
      |> Enum.each(fn %LogicalMessage{} = msg ->
        lsn = Postgres.lsn_to_int(msg.lsn)
        state.message_handler_module.handle_logical_message(state.message_handler_ctx, lsn, msg)
      end)

      time_ms = time / 1000

      if time_ms > 100 do
        Logger.warning("[SlotProcessorServer] Flushed messages took longer than 100ms",
          duration_ms: time_ms,
          message_count: count
        )
      end

      case res do
        :ok ->
          if state.test_pid do
            state.message_handler_module.flush_messages(state.message_handler_ctx)
            send(state.test_pid, {__MODULE__, :flush_messages})
          end

          %{
            state
            | accumulated_msg_binaries: %{count: 0, bytes: 0, binaries: []},
              backfill_watermark_messages: []
          }

        {:error, error} ->
          raise error
      end
    end)
  end

  defp default_safe_wal_cursor_fn(%State{last_commit_lsn: nil}),
    do: raise("Unsafe to call safe_wal_cursor when last_commit_lsn is nil")

  defp default_safe_wal_cursor_fn(%State{} = state) do
    consumers =
      Repo.preload(state.replication_slot, :not_disabled_sink_consumers, force: true).not_disabled_sink_consumers

    with :ok <- verify_messages_flushed(state),
         :ok <- verify_monitor_refs(state) do
      low_for_message_stores =
        state.message_store_refs
        |> Enum.flat_map(fn {consumer_id, ref} ->
          consumer = Sequin.Enum.find!(consumers, &(&1.id == consumer_id))
          SlotMessageStore.min_unpersisted_wal_cursors(consumer, ref)
        end)
        |> Enum.filter(& &1)
        |> case do
          [] -> nil
          cursors -> Enum.min_by(cursors, &{&1.commit_lsn, &1.commit_idx})
        end

      cond do
        not is_nil(low_for_message_stores) ->
          # Use the minimum unpersisted WAL cursor from the message stores.
          Logger.info(
            "[SlotProcessorServer] safe_wal_cursor/1: low_for_message_stores=#{inspect(low_for_message_stores)}"
          )

          low_for_message_stores

        accumulated_messages?(state) ->
          # When there are messages that the SlotProcessorServer has not flushed yet,
          # we need to fallback on the last low_watermark_wal_cursor (not safe to use
          # the last_commit_lsn, as it has not been flushed or processed by SlotMessageStores yet)
          Logger.info(
            "[SlotProcessorServer] safe_wal_cursor/1: state.low_watermark_wal_cursor=#{inspect(state.low_watermark_wal_cursor)}"
          )

          state.low_watermark_wal_cursor

        true ->
          # The SlotProcessorServer has processed messages beyond what the message stores have.
          # This might be due to health messages or messages for tables that do not belong
          # to any sinks.
          # We want to advance the slot to the last_commit_lsn in that case because:
          # 1. It's safe to do.
          # 2. If the tables in this slot are dormant, the slot will continue to accumulate
          # WAL unless we advance it. (This is the secondary purpose of the health message,
          # to allow us to advance the slot even if tables are dormant.)
          Logger.info("[SlotProcessorServer] safe_wal_cursor/1: state.last_commit_lsn=#{inspect(state.last_commit_lsn)}")
          %{commit_lsn: state.last_commit_lsn, commit_idx: 0}
      end

      cond do
        not is_nil(low_for_message_stores) ->
          # Use the minimum unpersisted WAL cursor from the message stores.
          Logger.info(
            "[SlotProcessorServer] safe_wal_cursor/1: low_for_message_stores=#{inspect(low_for_message_stores)}"
          )

          low_for_message_stores

        accumulated_messages?(state) ->
          # When there are messages that the SlotProcessorServer has not flushed yet,
          # we need to fallback on the last low_watermark_wal_cursor (not safe to use
          # the last_commit_lsn, as it has not been flushed or processed by SlotMessageStores yet)
          Logger.info(
            "[SlotProcessorServer] safe_wal_cursor/1: state.low_watermark_wal_cursor=#{inspect(state.low_watermark_wal_cursor)}"
          )

          state.low_watermark_wal_cursor

        true ->
          # The SlotProcessorServer has processed messages beyond what the message stores have.
          # This might be due to health messages or messages for tables that do not belong
          # to any sinks.
          # We want to advance the slot to the last_commit_lsn in that case because:
          # 1. It's safe to do.
          # 2. If the tables in this slot are dormant, the slot will continue to accumulate
          # WAL unless we advance it. (This is the secondary purpose of the health message,
          # to allow us to advance the slot even if tables are dormant.)
          Logger.info("[SlotProcessorServer] safe_wal_cursor/1: state.last_commit_lsn=#{inspect(state.last_commit_lsn)}")
          %{commit_lsn: state.last_commit_lsn, commit_idx: 0}
      end
    else
      {:error, error} ->
        raise error
    end
  end

  defp accumulated_messages?(%State{accumulated_msg_binaries: %{count: count}}) when is_integer(count) do
    count > 0
  end

  defp verify_monitor_refs(%State{} = state) do
    sink_consumer_ids =
      state.replication_slot
      |> Sequin.Repo.preload(:not_disabled_sink_consumers, force: true)
      |> Map.fetch!(:not_disabled_sink_consumers)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    monitored_sink_consumer_ids = Enum.sort(Map.keys(state.message_store_refs))

    %MessageHandler.Context{consumers: message_handler_consumers} = state.message_handler_ctx
    message_handler_sink_consumer_ids = Enum.sort(Enum.map(message_handler_consumers, & &1.id))

    cond do
      sink_consumer_ids != message_handler_sink_consumer_ids ->
        {:error,
         Error.invariant(
           message: """
           Sink consumer IDs do not match message handler sink consumer IDs.
           Sink consumers: #{inspect(sink_consumer_ids)}.
           Message handler: #{inspect(message_handler_sink_consumer_ids)}
           """
         )}

      sink_consumer_ids != monitored_sink_consumer_ids ->
        {:error,
         Error.invariant(
           message: """
           Sink consumer IDs do not match monitored sink consumer IDs.
           Sink consumers: #{inspect(sink_consumer_ids)}.
           Monitored: #{inspect(monitored_sink_consumer_ids)}
           """
         )}

      true ->
        :ok
    end
  end

  defp verify_messages_flushed(%State{} = state) do
    state.message_handler_module.flush_messages(state.message_handler_ctx)
  end

  def data_tuple_to_ids(columns, tuple_data) do
    columns
    |> Enum.zip(Tuple.to_list(tuple_data))
    |> Enum.filter(fn {col, _} -> col.pk? end)
    # Very important - the system expects the PKs to be sorted by attnum
    |> Enum.sort_by(fn {col, _} -> col.attnum end)
    |> Enum.map(fn {_, value} -> value end)
  end

  @spec data_tuple_to_fields(list(), [map()], tuple()) :: [Message.Field.t()]
  def data_tuple_to_fields(id_list, columns, tuple_data) do
    columns
    |> Enum.zip(Tuple.to_list(tuple_data))
    |> Enum.map(fn {%{name: name, attnum: attnum, type: type}, value} ->
      case cast_value(type, value) do
        {:ok, casted_value} ->
          %Message.Field{
            column_name: name,
            column_attnum: attnum,
            value: casted_value
          }

        {:error, %ServiceError{code: :invalid_json} = error} ->
          details = Map.put(error.details, :ids, id_list)

          raise %{
            error
            | details: details,
              message: error.message <> " for column `#{name}` in row with ids: #{inspect(id_list)}"
          }
      end
    end)
  end

  defp cast_value("bool", "t"), do: {:ok, true}
  defp cast_value("bool", "f"), do: {:ok, false}

  defp cast_value("_" <> _type, "{}"), do: {:ok, []}

  defp cast_value("_" <> type, array_string) when is_binary(array_string) do
    array_string
    |> String.trim("{")
    |> String.trim("}")
    |> parse_pg_array()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case cast_value(type, value) do
        {:ok, casted_value} -> {:cont, {:ok, [casted_value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, array} -> {:ok, Enum.reverse(array)}
      error -> error
    end
  end

  defp cast_value(type, value) when type in ["json", "jsonb"] and is_binary(value) do
    case Jason.decode(value) do
      {:ok, json} ->
        {:ok, json}

      {:error, %Jason.DecodeError{} = error} ->
        Logger.error("Failed to decode JSON value: #{inspect(error, limit: 10_000)}")

        wrapped_error =
          Error.service(
            service: :postgres_replication_slot,
            message: "Failed to decode JSON value: #{inspect(error)}",
            details: %{error: Exception.message(error)},
            code: :invalid_json
          )

        {:error, wrapped_error}
    end
  end

  defp cast_value("vector", nil), do: {:ok, nil}

  defp cast_value("vector", value_str) when is_binary(value_str) do
    list =
      value_str
      |> String.trim("[")
      |> String.trim("]")
      |> String.split(",")
      |> Enum.map(fn num ->
        {float, ""} = Float.parse(num)
        float
      end)

    {:ok, list}
  end

  defp cast_value(type, value) do
    case Ecto.Type.cast(string_to_ecto_type(type), value) do
      {:ok, casted_value} -> {:ok, casted_value}
      # Fallback to original value if casting fails
      :error -> {:ok, value}
    end
  end

  defp parse_pg_array(str) do
    str
    # split the string on commas, but only when they're not inside quotes.
    |> String.split(~r/,(?=(?:[^"]*"[^"]*")*[^"]*$)/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&unescape_string/1)
  end

  # When an array element contains a comma and is coming from Postgres, it will be wrapped in double quotes:
  # "\"royal,interest\""
  # We want to remove the double quotes so that we get:
  # "royal,interest"
  defp unescape_string(<<"\"", rest::binary>>) do
    rest
    |> String.slice(0..-2//1)
    |> String.replace("\\\"", "\"")
  end

  defp unescape_string(str), do: str

  @postgres_to_ecto_type_mapping %{
    # Numeric Types
    "int2" => :integer,
    "int4" => :integer,
    "int8" => :integer,
    "float4" => :float,
    "float8" => :float,
    "numeric" => :decimal,
    "money" => :decimal,
    # Character Types
    "char" => :string,
    "varchar" => :string,
    "text" => :string,
    # Binary Data Types
    "bytea" => :binary,
    # Date/Time Types
    "timestamp" => :naive_datetime,
    "timestamptz" => :utc_datetime,
    "date" => :date,
    "time" => :time,
    "timetz" => :time,
    # Ecto doesn't have a direct interval type
    "interval" => :map,
    # Boolean Type
    "bool" => :boolean,
    # Geometric Types
    "point" => {:array, :float},
    "line" => :string,
    "lseg" => :string,
    "box" => :string,
    "path" => :string,
    "polygon" => :string,
    "circle" => :string,
    # Network Address Types
    "inet" => :string,
    "cidr" => :string,
    "macaddr" => :string,
    # Bit String Types
    "bit" => :string,
    "bit_varying" => :string,
    # Text Search Types
    "tsvector" => :string,
    "tsquery" => :string,
    # UUID Type
    "uuid" => Ecto.UUID,
    # XML Type
    "xml" => :string,
    # JSON Types
    "json" => :map,
    "jsonb" => :map,
    # Arrays
    "_text" => {:array, :string},
    # Composite Types
    "composite" => :map,
    # Range Types
    "range" => {:array, :any},
    # Domain Types
    "domain" => :any,
    # Object Identifier Types
    "oid" => :integer,
    # pg_lsn Type
    "pg_lsn" => :string,
    # Pseudotypes
    "any" => :any
  }

  defp string_to_ecto_type(type) do
    Map.get(@postgres_to_ecto_type_mapping, type, :string)
  end

  # Add this function to get the last committed timestamp
  def get_last_committed_at(id) do
    case :ets.lookup(ets_table(), {id, :last_committed_at}) do
      [{{^id, :last_committed_at}, ts}] -> ts
      [] -> nil
    end
  end

  defp get_cached_conn(%State{} = state) do
    {:ok, conn} = ConnectionCache.connection(state.postgres_database)
    conn
  end

  defp default_check_memory_fn do
    :erlang.memory(:total)
  end

  defp default_max_memory_bytes do
    Application.get_env(:sequin, :max_memory_bytes)
  end

  defp launch_stop(state) do
    # Returning :stop tuple results in an error that looks like a crash
    task =
      Task.Supervisor.async_nolink(Sequin.TaskSupervisor, fn ->
        Logger.metadata(replication_id: state.id, database_id: state.postgres_database.id)
        Logger.info("[SlotProcessorServer] Stopping replication for #{state.id}")

        if Application.get_env(:sequin, :env) == :test and not is_nil(state.test_pid) do
          send(state.test_pid, {:stop_replication, state.id})
        else
          :ok = Runtime.Supervisor.stop_replication(state.id)
        end
      end)

    Process.demonitor(task.ref, [:flush])
  end

  defp incr_counter(name, amount \\ 1) do
    current = Process.get(name, 0)
    Process.put(name, current + amount)
  end

  defp clear_counter(name) do
    Process.delete(name)
  end

  defp execute_timed(name, fun) do
    {time, result} = :timer.tc(fun)
    # Convert microseconds to milliseconds
    incr_counter(:"#{name}_total_ms", time / 1000)
    incr_counter(:"#{name}_count")
    result
  end
end
