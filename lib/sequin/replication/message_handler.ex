defmodule Sequin.Replication.MessageHandler do
  @moduledoc false
  @behaviour Sequin.Extensions.MessageHandlerBehaviour

  alias Sequin.Consumers
  alias Sequin.Extensions.MessageHandlerBehaviour
  alias Sequin.Extensions.PostgresAdapter.Changes.DeletedRecord
  alias Sequin.Extensions.PostgresAdapter.Changes.InsertedRecord
  alias Sequin.Extensions.PostgresAdapter.Changes.UpdatedRecord
  alias Sequin.Replication.PostgresReplicationSlot

  defmodule Context do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :consumers, [Sequin.Consumers.consumer()]
    end
  end

  def context(%PostgresReplicationSlot{} = pr) do
    %Context{consumers: pr.http_pull_consumers ++ pr.http_push_consumers}
  end

  @impl MessageHandlerBehaviour
  def handle_messages(%Context{} = ctx, messages) do
    messages
    |> Enum.flat_map(fn message ->
      Enum.map(ctx.consumers, fn consumer ->
        Sequin.Map.from_ecto(%Sequin.Consumers.ConsumerEvent{
          consumer_id: consumer.id,
          commit_lsn: DateTime.to_unix(message.commit_timestamp, :microsecond),
          record_pks: message.ids,
          table_oid: message.table_oid,
          deliver_count: 0,
          data: create_data_from_message(message)
        })
      end)
    end)
    |> Consumers.insert_consumer_events()
  end

  defp create_data_from_message(%InsertedRecord{} = message) do
    %{
      record: message.record,
      changes: nil,
      action: :insert
    }
  end

  defp create_data_from_message(%UpdatedRecord{} = message) do
    changes = if message.old_record, do: filter_changes(message.old_record, message.record), else: %{}

    %{
      record: message.record,
      changes: changes,
      action: :update
    }
  end

  defp create_data_from_message(%DeletedRecord{} = message) do
    %{
      record: message.old_record,
      changes: nil,
      action: :delete
    }
  end

  defp filter_changes(old_record, new_record) do
    old_record
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      if v == Map.get(new_record, k) do
        acc
      else
        Map.put(acc, k, v)
      end
    end)
    |> Map.new()
  end
end