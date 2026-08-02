defmodule Uhuru.Search.Exa do
  @moduledoc """
  Web search via Exa (https://docs.exa.ai/reference/search). Opt-in, same
  as Together — nothing gets sent out for a search unless a caller asks
  for it explicitly.
  """

  @type result :: %{title: String.t() | nil, url: String.t(), text: String.t() | nil}

  @doc "Whether an Exa API key is configured -- gates whether web_search is ever offered as a tool."
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(api_key())

  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, term()}
  def search(query, opts \\ []) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        request(key, query, opts)
    end
  end

  defp request(api_key, query, opts) do
    body = %{
      "query" => query,
      "numResults" => Keyword.get(opts, :num_results, 5),
      "contents" => %{"text" => true}
    }

    [base_url: config(:base_url, "https://api.exa.ai")]
    |> Req.new()
    |> Req.post(
      url: "/search",
      headers: [{"x-api-key", api_key}],
      json: body,
      receive_timeout: config(:timeout_ms, 30_000)
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"results" => results}}}) do
    {:ok, Enum.map(results, &to_result/1)}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp to_result(entry) do
    %{
      title: Map.get(entry, "title"),
      url: Map.fetch!(entry, "url"),
      text: Map.get(entry, "text")
    }
  end

  defp api_key, do: config(:api_key, nil)

  defp config(key, default),
    do: :uhuru |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
