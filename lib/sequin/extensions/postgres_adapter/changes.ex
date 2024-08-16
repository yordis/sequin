defmodule Sequin.Extensions.PostgresAdapter.Changes do
  @moduledoc """
  This module provides structures of CDC changes.

  This file draws heavily from https://github.com/cainophile/cainophile
  License: https://github.com/cainophile/cainophile/blob/master/LICENSE
  """
  require Protocol

  @type record :: InsertedRecord.t() | UpdatedRecord.t() | DeletedRecord.t()

  defmodule Transaction do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :changes, list(any())
      field :commit_timestamp, DateTime.t()
    end
  end

  defmodule InsertedRecord do
    @moduledoc false
    use TypedStruct

    @derive {Jason.Encoder, except: [:subscription_ids]}

    typedstruct do
      field :columns, list(map())
      field :commit_timestamp, DateTime.t()
      field :errors, any()
      field :ids, list()
      field :table_schema, String.t()
      field :table_name, String.t()
      field :table_oid, integer()
      field :record, map()
      field :subscription_ids, list(String.t())
      field :type, String.t()
    end
  end

  defmodule UpdatedRecord do
    @moduledoc false
    use TypedStruct

    @derive {Jason.Encoder, except: [:subscription_ids]}

    typedstruct do
      field :columns, list(map())
      field :commit_timestamp, DateTime.t()
      field :errors, any()
      field :ids, list()
      field :table_schema, String.t()
      field :table_name, String.t()
      field :table_oid, integer()
      field :old_record, map()
      field :record, map()
      field :subscription_ids, list(String.t())
      field :type, String.t()
    end
  end

  defmodule DeletedRecord do
    @moduledoc false
    use TypedStruct

    @derive {Jason.Encoder, except: [:subscription_ids]}

    typedstruct do
      field :columns, list(map())
      field :commit_timestamp, DateTime.t()
      field :errors, any()
      field :ids, list()
      field :table_schema, String.t()
      field :table_name, String.t()
      field :table_oid, integer()
      field :old_record, map()
      field :subscription_ids, list(String.t())
      field :type, String.t()
    end
  end

  defmodule TruncatedRelation do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :type, String.t()
      field :schema, String.t()
      field :table, String.t()
      field :commit_timestamp, DateTime.t()
    end
  end
end