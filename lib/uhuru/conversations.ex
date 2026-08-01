defmodule Uhuru.Conversations do
  @moduledoc """
  Threads and messages. Message content is encrypted at rest via
  Uhuru.Vault.EncryptedBinary — every read/write here requires the vault
  to be unlocked, which the UI already gates on before this context is
  ever called.
  """

  import Ecto.Query

  alias Uhuru.Repo
  alias Uhuru.Conversations.{Thread, Message}

  @title_length 48

  @spec list_threads() :: [Thread.t()]
  def list_threads do
    Repo.all(from t in Thread, order_by: [desc: t.updated_at])
  end

  @spec get_thread(integer()) :: Thread.t() | nil
  def get_thread(id), do: Repo.get(Thread, id)

  @spec list_messages(integer()) :: [Message.t()]
  def list_messages(thread_id) do
    Repo.all(from m in Message, where: m.thread_id == ^thread_id, order_by: [asc: m.inserted_at])
  end

  @doc "Create a new thread, titled from the first message's text."
  @spec create_thread(String.t()) :: {:ok, Thread.t()} | {:error, Ecto.Changeset.t()}
  def create_thread(first_message_text) do
    %Thread{}
    |> Thread.changeset(%{title: title_from(first_message_text)})
    |> Repo.insert()
  end

  @spec create_message(integer(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def create_message(thread_id, attrs) do
    result =
      %Message{}
      |> Message.changeset(Map.put(attrs, :thread_id, thread_id))
      |> Repo.insert()

    with {:ok, _message} <- result do
      touch_thread(thread_id)
    end

    result
  end

  defp touch_thread(thread_id) do
    Repo.update_all(from(t in Thread, where: t.id == ^thread_id), set: [updated_at: DateTime.utc_now()])
  end

  defp title_from(text) do
    text = String.trim(text)

    if String.length(text) > @title_length do
      String.slice(text, 0, @title_length) <> "…"
    else
      text
    end
  end
end
