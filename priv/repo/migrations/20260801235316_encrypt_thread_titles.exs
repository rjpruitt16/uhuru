defmodule Uhuru.Repo.Migrations.EncryptThreadTitles do
  use Ecto.Migration

  def change do
    # SQLite doesn't support ALTER COLUMN TYPE. No real data exists yet
    # (pre-launch), so drop and re-add rather than a data migration.
    alter table(:threads) do
      remove :title, :string
      add :title, :binary
    end
  end
end
