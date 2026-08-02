defmodule Uhuru.Chat do
  @moduledoc """
  Chat turn orchestration. Granville (local) is the default provider;
  Together is an explicit opt-in, same as PII redaction — nothing beyond
  the local machine happens unless the caller asks for it.
  """

  alias Uhuru.Providers.{Granville, Together}
  alias Uhuru.Search.Exa

  @type provider :: :granville | :together

  @web_search_tool %{
    "type" => "function",
    "function" => %{
      "name" => "web_search",
      "description" =>
        "Search the live web for current information not in your training data " <>
          "-- recent events, prices, docs, anything time-sensitive.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "The search query."}
        },
        "required" => ["query"]
      }
    }
  }

  @doc """
  Sends a message and delivers the reply through on_chunk/1, one piece at
  a time. Both providers stream for real now: Together over SSE, Granville
  over its callback socket (see Uhuru.Providers.Granville's moduledoc) —
  callers get a uniform interface either way.

  For Together, when Exa is configured (see Uhuru.Search.Exa.configured?/0),
  the model is offered a `web_search` tool. If it uses it, opts[:on_tool_call]
  (if given) fires once with the search query, then exactly one follow-up
  call is made with the results and no tool offered -- one search per turn,
  never a loop, regardless of what the model asks for after that.
  """
  @spec send_message_streaming(String.t(), provider(), keyword(), (String.t() -> any())) ::
          :ok | {:error, term()}
  def send_message_streaming(prompt, provider, opts \\ [], on_chunk)

  def send_message_streaming(prompt, :together, opts, on_chunk),
    do: send_together(prompt, opts, on_chunk)

  def send_message_streaming(prompt, :granville, opts, on_chunk),
    do: Granville.stream(prompt, on_chunk, opts)

  defp send_together(prompt, opts, on_chunk) do
    on_tool_call = Keyword.get(opts, :on_tool_call, fn _query -> :ok end)
    tools = if Exa.configured?(), do: [@web_search_tool], else: nil
    messages = [%{"role" => "user", "content" => prompt}]

    messages
    |> Together.stream_chat(on_chunk, Keyword.put(opts, :tools, tools))
    |> handle_together_result(messages, on_tool_call, opts, on_chunk)
  end

  defp handle_together_result(:ok, _messages, _on_tool_call, _opts, _on_chunk), do: :ok

  defp handle_together_result(
         {:tool_calls, [%{name: "web_search", arguments: %{"query" => query}} = call | _]},
         messages,
         on_tool_call,
         opts,
         on_chunk
       ) do
    on_tool_call.(query)
    run_web_search_followup(messages, call, opts, on_chunk)
  end

  # Model asked for a tool we don't offer/recognize -- fail closed rather
  # than silently answering as though nothing happened.
  defp handle_together_result({:tool_calls, _unknown}, _messages, _on_tool_call, _opts, _on_chunk),
    do: {:error, :unsupported_tool_call}

  defp handle_together_result({:error, _reason} = error, _messages, _on_tool_call, _opts, _on_chunk),
    do: error

  defp run_web_search_followup(messages, call, opts, on_chunk) do
    case Exa.search(call.arguments["query"]) do
      {:ok, results} ->
        followup_messages =
          messages ++
            [
              %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => call.id,
                    "type" => "function",
                    "function" => %{
                      "name" => "web_search",
                      "arguments" => Jason.encode!(call.arguments)
                    }
                  }
                ]
              },
              %{
                "role" => "tool",
                "tool_call_id" => call.id,
                "content" => Jason.encode!(Enum.map(results, &Map.take(&1, [:title, :url, :text])))
              }
            ]

        # No :tools this round -- exactly one search, never a further loop,
        # no matter what the model does with the results.
        Together.stream_chat(followup_messages, on_chunk, Keyword.delete(opts, :tools))

      {:error, reason} ->
        {:error, {:web_search_failed, reason}}
    end
  end
end
