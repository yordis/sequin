defmodule Sequin.Factory.AccountsFactory do
  @moduledoc false
  import Sequin.Factory.Support

  alias Sequin.Accounts.Account
  alias Sequin.Accounts.LocalTunnel
  alias Sequin.Accounts.User
  alias Sequin.Factory
  alias Sequin.Repo

  def password, do: 5 |> Faker.Lorem.words() |> Enum.join("-")

  def email, do: "user#{Factory.unique_integer()}@example.com"

  def account(attrs \\ []) do
    merge_attributes(
      %Account{
        name: "Account #{Factory.unique_integer()}",
        inserted_at: Factory.utc_datetime(),
        updated_at: Factory.utc_datetime()
      },
      attrs
    )
  end

  def account_attrs(attrs \\ []) do
    attrs
    |> account()
    |> Sequin.Map.from_ecto()
  end

  def insert_account!(attrs \\ []) do
    attrs
    |> account()
    |> Repo.insert!()
  end

  def user(attrs \\ []) do
    attrs = Map.new(attrs)
    {auth_provider, attrs} = Map.pop_lazy(attrs, :auth_provider, fn -> Factory.one_of([:identity, :github]) end)

    {auth_provider_id, attrs} =
      Map.pop_lazy(attrs, :auth_provider_id, fn ->
        if auth_provider == :identity, do: nil, else: Factory.uuid()
      end)

    merge_attributes(
      %User{
        name: "User #{:rand.uniform(1000)}",
        email: email(),
        password: password(),
        account_id: Factory.uuid(),
        auth_provider: auth_provider,
        auth_provider_id: auth_provider_id,
        inserted_at: Factory.utc_datetime(),
        updated_at: Factory.utc_datetime()
      },
      attrs
    )
  end

  def user_attrs(attrs \\ []) do
    attrs
    |> user()
    |> Sequin.Map.from_ecto()
  end

  def insert_user!(attrs \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:auth_provider, :identity)

    {account_id, attrs} = Map.pop_lazy(attrs, :account_id, fn -> insert_account!().id end)

    attrs = user_attrs(attrs)

    changeset =
      if attrs.auth_provider in [:identity, "identity"] do
        User.registration_changeset(%User{account_id: account_id}, attrs, hash_password: true)
      else
        User.provider_registration_changeset(
          %User{account_id: account_id},
          attrs
        )
      end

    changeset
    |> Repo.insert!()
    # Some tests need to then use the password
    |> Map.put(:password, attrs.password)
  end

  def local_tunnel(attrs \\ []) do
    merge_attributes(
      %Sequin.Accounts.LocalTunnel{
        description: "Local Tunnel #{Factory.unique_integer()}",
        bastion_port: Enum.random(10_000..65_535),
        account_id: Factory.uuid(),
        inserted_at: Factory.utc_datetime(),
        updated_at: Factory.utc_datetime()
      },
      attrs
    )
  end

  def local_tunnel_attrs(attrs \\ []) do
    attrs
    |> local_tunnel()
    |> Sequin.Map.from_ecto()
  end

  def insert_local_tunnel!(attrs \\ []) do
    attrs = Map.new(attrs)
    {account_id, attrs} = Map.pop_lazy(attrs, :account_id, fn -> insert_account!().id end)

    attrs = local_tunnel_attrs(attrs)

    %LocalTunnel{account_id: account_id}
    |> LocalTunnel.create_changeset(attrs)
    |> Repo.insert!()
  end
end
