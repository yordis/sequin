defmodule Sequin.Consumers do
  @moduledoc false
  import Ecto.Query

  alias Sequin.Consumers.ConsumerEvent
  alias Sequin.Consumers.HttpPullConsumer
  alias Sequin.Consumers.HttpPushConsumer
  alias Sequin.Consumers.Query
  alias Sequin.Error
  alias Sequin.Repo
  alias Sequin.Streams
  alias Sequin.Streams.ConsumerBackfillWorker
  alias Sequin.Streams.ConsumerMessage

  require Logger

  @stream_schema Application.compile_env!(:sequin, [Sequin.Repo, :stream_schema_prefix])
  @config_schema Application.compile_env!(:sequin, [Sequin.Repo, :config_schema_prefix])

  @type consumer :: HttpPullConsumer.t() | HttpPushConsumer.t()

  def stream_schema, do: @stream_schema
  def config_schema, do: @config_schema

  # Consumers

  def get_consumer(consumer_id) do
    with {:error, _} <- get_http_pull_consumer(consumer_id),
         {:error, _} <- get_http_push_consumer(consumer_id) do
      {:error, Error.not_found(entity: :consumer)}
    end
  end

  def get_consumer!(consumer_id) do
    case get_consumer(consumer_id) do
      {:ok, consumer} -> consumer
      {:error, _} -> raise Error.not_found(entity: :consumer)
    end
  end

  def all_consumers do
    Repo.all(HttpPushConsumer) ++ Repo.all(HttpPullConsumer)
  end

  def update_consumer_with_lifecycle(%HttpPullConsumer{} = consumer, attrs) do
    consumer
    |> HttpPullConsumer.update_changeset(attrs)
    |> Repo.update()
  end

  def update_consumer_with_lifecycle(%HttpPushConsumer{} = consumer, attrs) do
    consumer
    |> HttpPushConsumer.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_consumer_with_lifecycle(consumer) do
    Repo.transact(fn ->
      case delete_consumer(consumer) do
        {:ok, _} ->
          :ok = delete_consumer_partition(consumer)
          {:ok, consumer}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  def delete_consumer(consumer) do
    Repo.delete(consumer)
  end

  # HttpPullConsumer

  def get_http_pull_consumer(consumer_id) do
    case Repo.get(HttpPullConsumer, consumer_id) do
      nil -> {:error, Error.not_found(entity: :http_pull_consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def get_http_pull_consumer_for_account(account_id, id_or_name) do
    res = account_id |> HttpPullConsumer.where_account_id() |> HttpPullConsumer.where_id_or_name(id_or_name) |> Repo.one()

    case res do
      nil -> {:error, Error.not_found(entity: :consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def create_http_pull_consumer_for_account_with_lifecycle(account_id, attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, consumer} <- create_http_pull_consumer(account_id, attrs),
           :ok <- create_consumer_partition(consumer) do
        unless opts[:no_backfill] do
          backfill_consumer!(consumer)
        end

        consumer = Repo.reload!(consumer)

        {:ok, consumer}
      end
    end)
  end

  def create_http_pull_consumer_with_lifecycle(attrs, opts \\ []) do
    account_id = Map.fetch!(attrs, :account_id)
    create_http_pull_consumer_for_account_with_lifecycle(account_id, attrs, opts)
  end

  def create_http_pull_consumer(account_id, attrs) do
    %HttpPullConsumer{account_id: account_id}
    |> HttpPullConsumer.create_changeset(attrs)
    |> Repo.insert()
  end

  # HttpPushConsumer

  def get_http_push_consumer(consumer_id) do
    case Repo.get(HttpPushConsumer, consumer_id) do
      nil -> {:error, Error.not_found(entity: :http_push_consumer)}
      consumer -> {:ok, consumer}
    end
  end

  def list_active_push_consumers do
    :push
    |> HttpPushConsumer.where_kind()
    |> HttpPushConsumer.where_status(:active)
    |> Repo.all()
  end

  def create_http_push_consumer_for_account_with_lifecycle(account_id, attrs, opts \\ []) do
    Repo.transact(fn ->
      with {:ok, consumer} <- create_http_push_consumer(account_id, attrs),
           :ok <- create_consumer_partition(consumer) do
        unless opts[:no_backfill] do
          backfill_consumer!(consumer)
        end

        consumer = Repo.reload!(consumer)

        {:ok, consumer}
      end
    end)
  end

  def create_http_push_consumer_with_lifecycle(attrs, opts \\ []) do
    account_id = Map.fetch!(attrs, :account_id)
    create_http_push_consumer_for_account_with_lifecycle(account_id, attrs, opts)
  end

  def create_http_push_consumer(account_id, attrs) do
    %HttpPushConsumer{account_id: account_id}
    |> HttpPushConsumer.create_changeset(attrs)
    |> Repo.insert()
  end

  # ConsumerEvent

  def reload(%ConsumerEvent{} = ce) do
    ce.consumer_id
    |> ConsumerEvent.where_consumer_id()
    |> ConsumerEvent.where_commit_lsn(ce.commit_lsn)
    |> Repo.one()
  end

  def get_consumer_event(consumer_id, commit_lsn) do
    consumer_event =
      consumer_id
      |> ConsumerEvent.where_consumer_id()
      |> ConsumerEvent.where_commit_lsn(commit_lsn)
      |> Repo.one()

    case consumer_event do
      nil -> {:error, Error.not_found(entity: :consumer_event)}
      consumer_event -> {:ok, consumer_event}
    end
  end

  def get_consumer_event!(consumer_id, commit_lsn) do
    case get_consumer_event(consumer_id, commit_lsn) do
      {:ok, consumer_event} -> consumer_event
      {:error, _} -> raise Error.not_found(entity: :consumer_event)
    end
  end

  def list_consumer_events_for_consumer(consumer_id, params \\ []) do
    base_query = ConsumerEvent.where_consumer_id(consumer_id)

    query =
      Enum.reduce(params, base_query, fn
        {:is_deliverable, false}, query ->
          ConsumerEvent.where_not_visible(query)

        {:is_deliverable, true}, query ->
          ConsumerEvent.where_deliverable(query)

        {:limit, limit}, query ->
          limit(query, ^limit)

        {:order_by, order_by}, query ->
          order_by(query, ^order_by)
      end)

    Repo.all(query)
  end

  def insert_consumer_events(consumer_events) do
    now = DateTime.utc_now()

    entries =
      Enum.map(consumer_events, fn event ->
        event
        |> Map.merge(%{
          updated_at: now,
          inserted_at: now
        })
        |> Map.update!(:record_pks, &ConsumerEvent.stringify_record_pks/1)
      end)

    {count, _} = Repo.insert_all(ConsumerEvent, entries)
    {:ok, count}
  end

  # Consumer Lifecycle

  defp create_consumer_partition(%{message_kind: :event} = consumer) do
    """
    CREATE TABLE #{stream_schema()}.consumer_events_#{consumer.name} PARTITION OF #{stream_schema()}.consumer_events FOR VALUES IN ('#{consumer.id}');
    """
    |> Repo.query()
    |> case do
      {:ok, %Postgrex.Result{command: :create_table}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_consumer_partition(%{message_kind: :record} = consumer) do
    """
    CREATE TABLE #{stream_schema()}.consumer_messages_#{consumer.name} PARTITION OF #{stream_schema()}.consumer_messages FOR VALUES IN ('#{consumer.id}');
    """
    |> Repo.query()
    |> case do
      {:ok, %Postgrex.Result{command: :create_table}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp delete_consumer_partition(%{message_kind: :event} = consumer) do
    consumer = Repo.preload(consumer, :stream)

    """
    DROP TABLE IF EXISTS #{stream_schema()}.consumer_events_#{consumer.name};
    """
    |> Repo.query()
    |> case do
      {:ok, %Postgrex.Result{command: :drop_table}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp delete_consumer_partition(%{message_kind: :record} = consumer) do
    consumer = Repo.preload(consumer, :stream)

    """
    DROP TABLE IF EXISTS #{stream_schema()}.consumer_messages_#{consumer.name};
    """
    |> Repo.query()
    |> case do
      {:ok, %Postgrex.Result{command: :drop_table}} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Consuming / Acking Messages

  def upsert_consumer_messages(%{}, []), do: {:ok, []}

  def upsert_consumer_messages(%{}, consumer_messages) do
    {consumer_ids, message_keys, message_seqs} =
      consumer_messages
      |> Enum.map(fn message ->
        {message.consumer_id, message.message_key, message.message_seq}
      end)
      |> Enum.reduce({[], [], []}, fn {consumer_id, message_key, message_seq}, {ids, keys, seqs} ->
        {[consumer_id | ids], [message_key | keys], [message_seq | seqs]}
      end)

    Query.upsert_consumer_records(
      consumer_ids: Enum.map(consumer_ids, &UUID.string_to_binary!/1),
      message_keys: message_keys,
      message_seqs: message_seqs
    )
  end

  def receive_for_consumer(%{message_kind: :event} = consumer, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    not_visible_until = DateTime.add(DateTime.utc_now(), consumer.ack_wait_ms, :millisecond)
    now = NaiveDateTime.utc_now()
    max_ack_pending = consumer.max_ack_pending

    outstanding_count =
      consumer.id
      |> ConsumerEvent.where_consumer_id()
      |> ConsumerEvent.where_not_visible()
      |> ConsumerEvent.count()
      |> Repo.one()

    case min(batch_size, max_ack_pending - outstanding_count) do
      0 ->
        {:ok, []}

      batch_size ->
        {:ok, events} =
          Query.receive_consumer_events(
            batch_size: batch_size,
            consumer_id: UUID.string_to_binary!(consumer.id),
            not_visible_until: not_visible_until,
            now: now
          )

        events =
          Enum.map(events, fn event ->
            event
            |> Map.update!(:consumer_id, &UUID.binary_to_string!/1)
            |> Map.update!(:ack_id, &UUID.binary_to_string!/1)
            |> Map.update!(:inserted_at, &DateTime.from_naive!(&1, "Etc/UTC"))
            |> Map.update!(:updated_at, &DateTime.from_naive!(&1, "Etc/UTC"))
            |> Map.update!(:last_delivered_at, &DateTime.from_naive!(&1, "Etc/UTC"))
            |> then(&struct!(ConsumerEvent, &1))
          end)

        {:ok, events}
    end
  end

  @spec ack_messages(Sequin.Consumers.HttpPushConsumer.t(), [integer()]) :: :ok
  def ack_messages(%{message_kind: :event} = consumer, ack_ids) do
    Repo.transact(fn ->
      {_, _} =
        consumer.id
        |> ConsumerEvent.where_consumer_id()
        |> ConsumerEvent.where_ack_ids(ack_ids)
        |> Repo.delete_all()

      :ok
    end)

    :ok
  end

  @spec nack_messages(Sequin.Consumers.HttpPushConsumer.t(), [integer()]) :: :ok
  def nack_messages(%{message_kind: :event} = consumer, ack_ids) do
    {_, _} =
      consumer.id
      |> ConsumerEvent.where_consumer_id()
      |> ConsumerEvent.where_ack_ids(ack_ids)
      |> Repo.update_all(set: [not_visible_until: nil])

    :ok
  end

  # Backfills

  def backfill_limit, do: 10_000

  defp backfill_consumer!(consumer) do
    {:ok, messages} = backfill_messages_for_consumer(consumer)

    if length(messages) < backfill_limit() do
      {:ok, _} = update_consumer_with_lifecycle(consumer, %{backfill_completed_at: DateTime.utc_now()})
    end

    next_seq = messages |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
    {:ok, _} = ConsumerBackfillWorker.create(consumer.id, next_seq)

    :ok
  end

  def backfill_messages_for_consumer(consumer, seq \\ 0) do
    messages =
      Streams.list_messages_for_stream(consumer.stream_id,
        seq_gt: seq,
        limit: backfill_limit(),
        order_by: [asc: :seq],
        select: [:key, :seq]
      )

    {:ok, _} =
      messages
      |> Enum.filter(fn message ->
        Sequin.Key.matches?(consumer.filter_key_pattern, message.key)
      end)
      |> Enum.map(fn message ->
        %ConsumerMessage{
          consumer_id: consumer.id,
          message_key: message.key,
          message_seq: message.seq
        }
      end)
      |> then(&upsert_consumer_messages(consumer, &1))

    {:ok, messages}
  end
end