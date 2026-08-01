defmodule Uhuru.Vault.Keyring do
  @moduledoc """
  Single-row table: a random salt and the data-encryption key (DEK),
  wrapped by a key derived from the user's passphrase. Both fields are
  useless without the passphrase — nothing here is a secret on its own.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "vault_keyring" do
    field :salt, :binary
    field :wrapped_dek, :binary
    timestamps(updated_at: false)
  end

  def changeset(keyring, attrs) do
    keyring
    |> cast(attrs, [:salt, :wrapped_dek])
    |> validate_required([:salt, :wrapped_dek])
  end
end
