defmodule Uhuru.Conversations.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  schema "threads" do
    field :title, Uhuru.Vault.EncryptedBinary
    # Set once at creation, never changed: locks which provider/model this
    # thread uses, since different models can expect different message
    # formats. Plain metadata, not encrypted, same as role/provider.
    field :model_choice, :string
    has_many :messages, Uhuru.Conversations.Message
    timestamps()
  end

  def changeset(thread, attrs) do
    cast(thread, attrs, [:title, :model_choice])
  end
end
