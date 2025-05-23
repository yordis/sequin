defmodule Sequin.ApiTokens do
  @moduledoc false
  import Ecto.Query

  alias Sequin.ApiTokens.ApiToken
  alias Sequin.Error
  alias Sequin.Repo

  @doc """
  Creates a token for the given org.
  """
  def create_for_account!(account_id, attrs) do
    account_id
    |> ApiToken.build_token()
    |> ApiToken.create_changeset(attrs)
    |> Repo.insert!()
  end

  def create_for_account(account_id, attrs) do
    attrs = Map.new(attrs)
    {token, attrs} = Map.pop(attrs, "token")

    account_id
    |> ApiToken.build_token(token)
    |> ApiToken.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Finds a token by the given (unhashed) token.
  """
  def find_by_token(token) do
    token
    |> ApiToken.where_token()
    |> Repo.one()
    |> case do
      nil -> {:error, Error.not_found(entity: :api_token)}
      token -> {:ok, token}
    end
  end

  def list_tokens_for_account(account_id) do
    Repo.all(from t in ApiToken, where: t.account_id == ^account_id)
  end

  def get_token_by(params) do
    ApiToken
    |> Repo.get_by(params)
    |> case do
      nil -> {:error, Error.not_found(entity: :api_token)}
      token -> {:ok, token}
    end
  end

  def delete_token_for_account(account_id, token_id) do
    case get_token_by(id: token_id, account_id: account_id) do
      {:ok, token} ->
        Repo.delete(token)

      {:error, _} = error ->
        error
    end
  end
end
