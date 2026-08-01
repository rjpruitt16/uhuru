defmodule Uhuru.Chat do
  @moduledoc """
  Chat turn orchestration. Granville (local) is the default provider;
  Together is an explicit opt-in, same as PII redaction — nothing beyond
  the local machine happens unless the caller asks for it.
  """

  alias Uhuru.Providers.{Granville, Together}

  @type provider :: :granville | :together

  @spec send_message(String.t(), provider(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def send_message(prompt, provider, opts \\ [])
  def send_message(prompt, :granville, opts), do: Granville.complete(prompt, opts)
  def send_message(prompt, :together, opts), do: Together.complete(prompt, opts)
end
