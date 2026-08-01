defmodule Uhuru.Repo.Migrations.CreateVaultKeyring do
  use Ecto.Migration

  def change do
    create table(:vault_keyring) do
      add :salt, :binary, null: false
      add :wrapped_dek, :binary, null: false

      timestamps(updated_at: false)
    end
  end
end
