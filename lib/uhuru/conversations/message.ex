defmodule Uhuru.Conversations.Message do
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field :role, Ecto.Enum, values: [:user, :assistant, :error]
    field :content, Uhuru.Vault.EncryptedBinary
    field :provider, Ecto.Enum, values: [:granville, :together]
    # Friendly short label, e.g. "Qwen 2.5 7B" -- nil for user messages.
    field :model, :string
    belongs_to :thread, Uhuru.Conversations.Thread
    timestamps(updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:role, :content, :provider, :model, :thread_id])
    |> validate_required([:role, :content, :thread_id])
  end
end
