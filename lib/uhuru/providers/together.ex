defmodule Uhuru.Providers.Together do
  @moduledoc """
  Opt-in provider for stronger models via Together AI's OpenAI-compatible
  chat completions API. Never the default — a caller reaches for this
  explicitly when Granville's local model isn't enough.
  """

  @behaviour Uhuru.Provider

  @impl true
  def complete(prompt, opts \\ []) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        request(key, prompt, opts)
    end
  end

  defp request(api_key, prompt, opts) do
    body = %{
      "model" => Keyword.get(opts, :model, config(:model, "Qwen/Qwen2.5-7B-Instruct-Turbo")),
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, 1024)
    }

    [base_url: config(:base_url, "https://api.together.xyz/v1")]
    |> Req.new()
    |> Req.post(
      url: "/chat/completions",
      auth: {:bearer, api_key},
      json: body,
      receive_timeout: config(:timeout_ms, 60_000)
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    case body do
      %{"choices" => [%{"message" => %{"content" => text}} | _]} -> {:ok, text}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp api_key, do: config(:api_key, nil)

  defp config(key, default),
    do: :uhuru |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
