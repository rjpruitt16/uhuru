defmodule Uhuru.Repo.Migrations.AddModelFields do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Friendly short label ("Qwen 2.5 7B"), not a raw model slug -- plain
      # metadata like role/provider, not encrypted content.
      add :model, :string
    end

    alter table(:threads) do
      # Set once at thread creation, never changed after: different models
      # can have different message-format expectations, so a thread's
      # model is locked to whatever it started with.
      add :model_choice, :string
    end
  end
end
