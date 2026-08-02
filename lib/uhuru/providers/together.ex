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

  @doc """
  Streams a full chat-completions turn. `messages` is the raw OpenAI-style
  message list (not just a single prompt), so callers can inject prior
  tool results, not just a bare user turn. `on_chunk.(text_delta)` fires
  for content as it streams in over SSE.

  Pass `opts[:tools]` (an OpenAI-style tool schema list) to let the model
  request a tool call instead of answering directly. If it does, nothing
  is streamed to on_chunk for this turn -- the call returns
  `{:tool_calls, calls}` instead of `:ok`, and it's the caller's job (see
  Uhuru.Chat) to run the tool and issue a follow-up call.

  Together's API already does SSE token streaming natively, unlike
  Granville (see Uhuru.Providers.Granville's moduledoc) -- this is an
  Elixir-only change, no protocol work needed.
  """
  @spec stream_chat([map()], (String.t() -> any()), keyword()) ::
          :ok | {:tool_calls, [map()]} | {:error, term()}
  def stream_chat(messages, on_chunk, opts \\ []) do
    case api_key() do
      nil -> {:error, :missing_api_key}
      key -> request_stream(key, messages, on_chunk, opts)
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

  defp request_stream(api_key, messages, on_chunk, opts) do
    body =
      %{
        "model" => Keyword.get(opts, :model, config(:model, "Qwen/Qwen2.5-7B-Instruct-Turbo")),
        "messages" => messages,
        "max_tokens" => Keyword.get(opts, :max_tokens, 1024),
        "stream" => true
      }
      |> maybe_put_tools(Keyword.get(opts, :tools))

    # SSE chunk boundaries from :into don't reliably line up with "\n"
    # boundaries -- a chunk can split a JSON line in half. Buffered in the
    # process dictionary since this runs in its own short-lived Task
    # process per request; only complete lines get parsed, the trailing
    # partial line carries over to the next chunk. Tool-call argument
    # fragments arrive the same fragmented way, keyed by index, so any
    # in-flight tool calls are accumulated here too.
    Process.put(:together_sse_buffer, "")
    Process.put(:together_sse_tool_calls, %{})

    [base_url: config(:base_url, "https://api.together.xyz/v1")]
    |> Req.new()
    |> Req.post(
      url: "/chat/completions",
      auth: {:bearer, api_key},
      json: body,
      receive_timeout: config(:timeout_ms, 60_000),
      into: fn {:data, data}, {req, resp} ->
        buffer = Process.get(:together_sse_buffer, "") <> data
        {complete_lines, remainder} = split_complete_lines(buffer)
        Process.put(:together_sse_buffer, remainder)
        Enum.each(complete_lines, &handle_sse_line(&1, on_chunk))
        {:cont, {req, resp}}
      end
    )
    |> case do
      {:ok, %Req.Response{status: 200}} ->
        case collect_tool_calls() do
          [] -> :ok
          calls -> {:tool_calls, calls}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_tools(body, tools) when tools in [nil, []], do: body

  defp maybe_put_tools(body, tools),
    do: Map.merge(body, %{"tools" => tools, "tool_choice" => "auto"})

  defp split_complete_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

  defp handle_sse_line(line, on_chunk) do
    case String.trim_trailing(line, "\r") do
      "data: [DONE]" ->
        :ok

      "data: " <> json ->
        case Jason.decode(json) do
          {:ok, %{"choices" => [%{"delta" => delta} | _]}} -> handle_delta(delta, on_chunk)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_delta(%{"content" => content}, on_chunk) when is_binary(content) do
    on_chunk.(content)
  end

  defp handle_delta(%{"tool_calls" => deltas}, _on_chunk) when is_list(deltas) do
    Enum.each(deltas, &accumulate_tool_call_delta/1)
  end

  defp handle_delta(_delta, _on_chunk), do: :ok

  defp accumulate_tool_call_delta(delta) do
    index = Map.get(delta, "index", 0)
    calls = Process.get(:together_sse_tool_calls, %{})
    existing = Map.get(calls, index, %{id: nil, name: nil, arguments: ""})

    updated = %{
      id: delta["id"] || existing.id,
      name: get_in(delta, ["function", "name"]) || existing.name,
      arguments: existing.arguments <> (get_in(delta, ["function", "arguments"]) || "")
    }

    Process.put(:together_sse_tool_calls, Map.put(calls, index, updated))
  end

  defp collect_tool_calls do
    :together_sse_tool_calls
    |> Process.get(%{})
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {_index, %{id: id, name: name, arguments: arguments}} ->
      %{id: id, name: name, arguments: decode_arguments(arguments)}
    end)
  end

  defp decode_arguments(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp api_key, do: config(:api_key, nil)

  defp config(key, default),
    do: :uhuru |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
