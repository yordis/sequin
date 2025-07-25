defmodule SequinWeb.SinkConsumersLive.ShowTest do
  use SequinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sequin.Factory.DatabasesFactory, only: [table_attrs: 1, column_attrs: 1]

  alias Sequin.Consumers
  alias Sequin.Factory.ConsumersFactory
  alias Sequin.Factory.DatabasesFactory

  setup :logged_in_user

  setup %{conn: conn, account: account} do
    table =
      table_attrs(
        columns: [
          column_attrs(attnum: 1, name: "id", type: "uuid", is_pk?: true),
          column_attrs(attnum: 2, name: "name", type: "text", is_pk?: false),
          column_attrs(attnum: 3, name: "created_at", type: "timestamp with time zone", is_pk?: false),
          column_attrs(attnum: 4, name: "updated_at", type: "timestamp with time zone", is_pk?: false)
        ]
      )

    table2 =
      table_attrs(
        columns: [
          column_attrs(attnum: 1, name: "partition", type: "integer", is_pk?: true),
          column_attrs(attnum: 2, name: "id", type: "integer", is_pk?: true),
          column_attrs(attnum: 3, name: "name", type: "text", is_pk?: false),
          column_attrs(attnum: 4, name: "created_at", type: "timestamp", is_pk?: false),
          column_attrs(attnum: 5, name: "updated_at", type: "timestamp", is_pk?: false)
        ]
      )

    database =
      DatabasesFactory.insert_postgres_database!(
        account_id: account.id,
        table_count: 2,
        tables: [table, table2]
      )

    consumer = ConsumersFactory.insert_sink_consumer!(account_id: account.id, postgres_database_id: database.id)
    [table, table2] = database.tables

    {:ok, conn: conn, consumer: consumer, table: table, table2: table2}
  end

  describe "backfills" do
    test "runs a full backfill", %{conn: conn, consumer: consumer, table: table} do
      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      rendered =
        render_hook(view, "run-backfill", %{
          "selectedTables" => [
            %{
              "oid" => table.oid,
              "type" => "full"
            }
          ]
        })

      assert rendered =~ "Backfills"

      [backfill] = Consumers.list_backfills_for_sink_consumer(consumer.id)
      assert backfill.state == :active
      assert backfill.table_oid == table.oid
      assert backfill.sink_consumer_id == consumer.id
      assert backfill.account_id == consumer.account_id

      assert backfill.initial_min_cursor == %{
               1 => "00000000-0000-0000-0000-000000000000"
             }
    end

    test "runs a partial backfill with a timestamp sort column", %{conn: conn, consumer: consumer, table: table} do
      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      rendered =
        render_hook(view, "run-backfill", %{
          "selectedTables" => [
            %{
              "oid" => table.oid,
              "type" => "partial",
              # Sort by created_at
              "sortColumnAttnum" => 3,
              "initialMinCursor" => "2021-01-01 00:00:00Z"
            }
          ]
        })

      assert rendered =~ "Backfills"

      [backfill] = Consumers.list_backfills_for_sink_consumer(consumer.id)
      assert backfill.state == :active
      assert backfill.table_oid == table.oid
      assert backfill.sink_consumer_id == consumer.id

      assert backfill.initial_min_cursor == %{
               1 => "00000000-0000-0000-0000-000000000000",
               3 => "2021-01-01 00:00:00Z"
             }
    end

    test "runs a partial backfill with a integer sort column", %{conn: conn, consumer: consumer, table: table} do
      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      rendered =
        render_hook(view, "run-backfill", %{
          "selectedTables" => [
            %{
              "oid" => table.oid,
              "type" => "partial",
              "sortColumnAttnum" => 1,
              "initialMinCursor" => "1"
            }
          ]
        })

      assert rendered =~ "Backfills"

      [backfill] = Consumers.list_backfills_for_sink_consumer(consumer.id)
      assert backfill.state == :active
      assert backfill.table_oid == table.oid
      assert backfill.sink_consumer_id == consumer.id

      assert backfill.initial_min_cursor == %{1 => "1"}
    end

    test "runs a backfill with custom max timeout", %{conn: conn, consumer: consumer, table: table} do
      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      rendered =
        render_hook(view, "run-backfill", %{
          "selectedTables" => [
            %{
              "oid" => table.oid,
              "type" => "full"
            }
          ],
          "maxTimeoutMs" => 45_000
        })

      assert rendered =~ "Backfills"

      [backfill] = Consumers.list_backfills_for_sink_consumer(consumer.id)
      assert backfill.max_timeout_ms == 45_000
    end

    test "pauses an active backfill", %{conn: conn, consumer: consumer, table: table} do
      # Create an active backfill
      backfill =
        ConsumersFactory.insert_active_backfill!(
          account_id: consumer.account_id,
          sink_consumer_id: consumer.id,
          table_oid: table.oid
        )

      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      # Pause the backfill
      rendered = render_hook(view, "pause_backfill", %{"backfill_id" => backfill.id})

      # Check that the event was handled successfully
      assert rendered =~ "Backfills"

      # Verify the backfill state was updated
      updated_backfill = Consumers.get_backfill!(backfill.id)
      assert updated_backfill.state == :paused
    end

    test "resumes a paused backfill", %{conn: conn, consumer: consumer, table: table} do
      # Create a paused backfill
      backfill =
        ConsumersFactory.insert_backfill!(
          account_id: consumer.account_id,
          sink_consumer_id: consumer.id,
          table_oid: table.oid,
          state: :paused
        )

      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      # Resume the backfill
      rendered = render_hook(view, "resume_backfill", %{"backfill_id" => backfill.id})

      # Check that the event was handled successfully
      assert rendered =~ "Backfills"

      # Verify the backfill state was updated
      updated_backfill = Consumers.get_backfill!(backfill.id)
      assert updated_backfill.state == :active
    end

    test "cancels an active backfill", %{conn: conn, consumer: consumer, table: table} do
      # Create an active backfill
      backfill =
        ConsumersFactory.insert_active_backfill!(
          account_id: consumer.account_id,
          sink_consumer_id: consumer.id,
          table_oid: table.oid
        )

      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      # Cancel the backfill
      rendered = render_hook(view, "cancel_backfill", %{"backfill_id" => backfill.id})

      # Check that the event was handled successfully
      assert rendered =~ "Backfills"

      # Verify the backfill state was updated
      updated_backfill = Consumers.get_backfill!(backfill.id)
      assert updated_backfill.state == :cancelled
    end

    test "prevents pause/resume of backfill from another consumer", %{conn: conn, consumer: consumer} do
      # Create a backfill for a different consumer
      other_consumer = ConsumersFactory.insert_sink_consumer!(account_id: consumer.account_id)

      backfill =
        ConsumersFactory.insert_active_backfill!(
          account_id: consumer.account_id,
          sink_consumer_id: other_consumer.id
        )

      {:ok, view, _html} = live(conn, ~p"/sinks/#{consumer.type}/#{consumer.id}/backfills")

      # Try to pause the backfill from another consumer
      render_hook(view, "pause_backfill", %{"backfill_id" => backfill.id})

      # Verify the backfill state was NOT updated
      unchanged_backfill = Consumers.get_backfill!(backfill.id)
      assert unchanged_backfill.state == :active
    end
  end
end
