defmodule Uhuru.Repo.Migrations.CreateThreadsAndMessages do
  use Ecto.Migration

  def change do
    create table(:threads) do
      add :title, :string
      timestamps()
    end

    create table(:messages) do
      add :role, :string, null: false
      add :content, :binary, null: false
      add :provider, :string
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      timestamps(updated_at: false)
    end

    create index(:messages, [:thread_id])
  end
end
