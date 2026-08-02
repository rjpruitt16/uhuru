defmodule Uhuru.Providers.Granville do
  @moduledoc """
  Local provider — talks to a running `granville serve` process over its
  Unix-socket + MessagePack protocol (see granville/src/server.zig).

  The protocol is callback-based, not request/response: we open a temporary
  Unix socket, send a request naming that socket as `callback`, get an
  immediate ACK on the original connection, then wait for Granville to
  connect *back* to our callback socket. That callback connection is held
  open for the whole task: zero or more `%{"id" => id, "delta" => text}`
  chunk messages arrive as Granville generates each token, followed by
  exactly one final message -- either the normal result shape (with
  `tool_input_json`, discarded here since the deltas already carried the
  text) or an `%{"error" => ...}` message. MessagePack has no built-in
  framing, so multiple messages back-to-back on one connection can arrive
  split across TCP reads or bunched together -- see drain_messages/2 for
  the buffer-until-complete decode loop this requires.

  PII redaction (`opts[:ranked]`, default `false`) is an explicit opt-in,
  not automatic. Granville's ranking pass that redacts PII is a second full
  model call in the critical path — roughly doubles latency — so it's off
  by default and only triggered when the caller (the user, via the UI)
  asks for it.
  """

  @behaviour Uhuru.Provider

  @doc """
  Whether this deploy expects a local model at all (GRANVILLE_MODEL_URL was
  set at boot). False for Together-only deploys — nothing to poll or show.
  """
  @spec configured?() :: boolean()
  def configured?, do: config(:model_configured, false)

  @doc """
  Whether Granville is actually up and ready to serve. Checking for the
  socket file is a real signal, not a guess: server.zig only opens the
  Unix socket after all models finish loading, so its presence means the
  model is loaded, not just that the download finished.
  """
  @spec ready?() :: boolean()
  def ready?, do: File.exists?(socket_path())

  @doc "Friendly name for whatever model this deploy bundles, for message tags."
  @spec model_label() :: String.t()
  def model_label, do: config(:model_label, "Local Model")

  @impl true
  def complete(prompt, opts \\ []) do
    Process.put(:granville_complete_acc, [])
    on_chunk = fn chunk -> Process.put(:granville_complete_acc, [chunk | Process.get(:granville_complete_acc, [])]) end

    result =
      case stream(prompt, on_chunk, opts) do
        :ok -> {:ok, Process.get(:granville_complete_acc, []) |> Enum.reverse() |> Enum.join()}
        {:error, _reason} = error -> error
      end

    Process.delete(:granville_complete_acc)
    result
  end

  @doc """
  Same call, but streamed: `on_chunk.(text_delta)` fires once per token
  delta as Granville produces it, instead of waiting for the whole reply.
  Returns :ok once the stream completes, or {:error, _}.
  """
  @spec stream(String.t(), (String.t() -> any()), keyword()) :: :ok | {:error, term()}
  def stream(prompt, on_chunk, opts \\ []) do
    id = request_id()
    callback_path = callback_socket_path(id)
    File.rm(callback_path)

    case listen_callback(callback_path) do
      {:ok, listen_socket} ->
        result =
          with :ok <- send_request(id, prompt, callback_path, opts) do
            await_stream(listen_socket, on_chunk)
          end

        :gen_tcp.close(listen_socket)
        File.rm(callback_path)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp request_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp callback_socket_path(id), do: Path.join(System.tmp_dir!(), "uhuru_callback_#{id}.sock")

  defp listen_callback(path) do
    :gen_tcp.listen(0, [
      :binary,
      packet: :raw,
      active: false,
      backlog: 1,
      ifaddr: {:local, path}
    ])
  end

  defp send_request(id, prompt, callback_path, opts) do
    payload = %{
      "id" => id,
      "text" => prompt,
      "callback" => callback_path,
      "ranked" => Keyword.get(opts, :ranked, false),
      "max_tokens" => Keyword.get(opts, :max_tokens, 256)
    }

    connect_opts = [:binary, packet: :raw, active: false]

    with {:ok, conn} <- :gen_tcp.connect({:local, socket_path()}, 0, connect_opts, timeout()),
         :ok <- :gen_tcp.send(conn, Msgpax.pack!(payload)),
         {:ok, ack_bytes} <- :gen_tcp.recv(conn, 0, timeout()) do
      :gen_tcp.close(conn)

      case Msgpax.unpack!(ack_bytes) do
        %{"status" => "accepted"} -> :ok
        other -> {:error, {:unexpected_ack, other}}
      end
    end
  end

  defp await_stream(listen_socket, on_chunk) do
    with {:ok, conn} <- :gen_tcp.accept(listen_socket, timeout()) do
      result = read_stream(conn, "", on_chunk)
      :gen_tcp.close(conn)
      result
    end
  end

  defp read_stream(conn, buffer, on_chunk) do
    case drain_messages(buffer, on_chunk) do
      {:done, result} ->
        result

      {:continue, remaining} ->
        case :gen_tcp.recv(conn, 0, timeout()) do
          {:ok, bytes} -> read_stream(conn, remaining <> bytes, on_chunk)
          {:error, :closed} -> {:error, :connection_closed_without_result}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Decodes as many complete MessagePack terms as are currently in the
  # buffer, firing on_chunk for each delta, until either the final message
  # (result or error) is found or the buffer runs out mid-term.
  defp drain_messages(buffer, on_chunk) do
    case Msgpax.unpack_slice(buffer) do
      {:ok, %{"error" => reason}, _rest} ->
        {:done, {:error, reason}}

      # The final result still carries the full text (see server.zig), but
      # every token already arrived as a delta -- nothing left to do here
      # but signal completion.
      {:ok, %{"tool_input_json" => _json}, _rest} ->
        {:done, :ok}

      {:ok, %{"delta" => delta}, rest} ->
        on_chunk.(delta)
        drain_messages(rest, on_chunk)

      {:ok, _other, rest} ->
        drain_messages(rest, on_chunk)

      {:error, %Msgpax.UnpackError{reason: :incomplete}} ->
        {:continue, buffer}

      {:error, reason} ->
        {:done, {:error, {:decode_failed, reason}}}
    end
  end

  defp socket_path, do: config(:socket_path, "/tmp/granville.sock")
  defp timeout, do: config(:timeout_ms, 60_000)

  defp config(key, default),
    do: :uhuru |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
