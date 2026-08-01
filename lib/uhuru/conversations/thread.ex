defmodule Uhuru.Conversations.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  schema "threads" do
    field :title, :string
    has_many :messages, Uhuru.Conversations.Message
    timestamps()
  end

  def changeset(thread, attrs) do
    cast(thread, attrs, [:title])
  end
end
