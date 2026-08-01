defmodule Uhuru.Providers.Granville do
  @moduledoc """
  Local provider — talks to a running `granville serve` process over its
  Unix-socket + MessagePack protocol (see granville/src/server.zig).

  The protocol is callback-based, not request/response: we open a temporary
  Unix socket, send a request naming that socket as `callback`, get an
  immediate ACK on the original connection, then wait for Granville to
  connect *back* to our callback socket with the real result once
  inference finishes.

  `ranked` is hardcoded to `true`: Granville runs a ranking pass that
  classifies priority AND redacts PII before the redacted text (not the
  original) reaches inference. That's a second full model call in the
  critical path, so every request costs roughly double the latency of a
  single completion — an intentional tradeoff for the privacy guarantee,
  not an oversight.
  """

  @behaviour Uhuru.Provider

  @impl true
  def complete(prompt, opts \\ []) do
    id = request_id()
    callback_path = callback_socket_path(id)
    File.rm(callback_path)

    case listen_callback(callback_path) do
      {:ok, listen_socket} ->
        result =
          with :ok <- send_request(id, prompt, callback_path, opts) do
            await_result(listen_socket)
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
      "ranked" => true,
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

  defp await_result(listen_socket) do
    with {:ok, conn} <- :gen_tcp.accept(listen_socket, timeout()),
         {:ok, bytes} <- :gen_tcp.recv(conn, 0, timeout()) do
      :gen_tcp.close(conn)

      case Msgpax.unpack!(bytes) do
        %{"error" => reason} -> {:error, reason}
        %{"tool_input_json" => json} -> {:ok, decode_text(json)}
        other -> {:error, {:unexpected_result, other}}
      end
    end
  end

  defp decode_text(json) do
    case Jason.decode(json) do
      {:ok, [text | _]} -> text
      _ -> json
    end
  end

  defp socket_path, do: config(:socket_path, "/tmp/granville.sock")
  defp timeout, do: config(:timeout_ms, 60_000)

  defp config(key, default),
    do: :uhuru |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
