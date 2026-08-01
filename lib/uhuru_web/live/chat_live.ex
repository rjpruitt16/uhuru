defmodule UhuruWeb.ChatLive do
  use UhuruWeb, :live_view

  alias Uhuru.Chat

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Uhuru", draft: "", provider: :granville, redact: false, pending: false, next_id: 1)
     |> stream(:messages, [])}
  end

  @impl true
  def handle_event("update_draft", %{"message" => %{"text" => text}}, socket) do
    {:noreply, assign(socket, draft: text)}
  end

  def handle_event("toggle_provider", _params, socket) do
    next = if socket.assigns.provider == :granville, do: :together, else: :granville
    {:noreply, assign(socket, provider: next)}
  end

  def handle_event("toggle_redact", _params, socket) do
    {:noreply, assign(socket, redact: !socket.assigns.redact)}
  end

  def handle_event("send", %{"message" => %{"text" => raw_text}}, socket) do
    text = String.trim(raw_text)

    if text == "" or socket.assigns.pending do
      {:noreply, socket}
    else
      %{provider: provider, redact: redact, next_id: id} = socket.assigns
      opts = [ranked: redact]

      socket =
        socket
        |> stream_insert(:messages, %{id: id, role: :user, text: text, provider: nil})
        |> assign(draft: "", pending: true, next_id: id + 1)
        |> start_async(:reply, fn -> Chat.send_message(text, provider, opts) end)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:reply, {:ok, result}, socket) do
    %{provider: provider, next_id: id} = socket.assigns

    message =
      case result do
        {:ok, text} -> %{id: id, role: :assistant, text: text, provider: provider}
        {:error, reason} -> %{id: id, role: :error, text: format_error(reason), provider: provider}
      end

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(pending: false, next_id: id + 1)}
  end

  def handle_async(:reply, {:exit, reason}, socket) do
    %{next_id: id} = socket.assigns

    message = %{id: id, role: :error, text: "Crashed: #{inspect(reason)}", provider: nil}

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(pending: false, next_id: id + 1)}
  end

  defp format_error(:missing_api_key), do: "No API key configured for this provider."
  defp format_error(:econnrefused), do: "Local model isn't running. Start it with: granville serve <model.gguf>"
  defp format_error(:enoent), do: "Local model socket not found. Start it with: granville serve <model.gguf>"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp provider_label(:granville), do: "LOCAL / GRANVILLE"
  defp provider_label(:together), do: "CLOUD / TOGETHER"

  defp role_tag(:user), do: "YOU"
  defp role_tag(:assistant), do: "REPLY"
  defp role_tag(:error), do: "ERROR"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="uhuru-shell">
      <div class="grain"></div>

      <header class="uhuru-header">
        <div class="wordmark">UHURU</div>
        <div class="tagline">a privacy-first ai workspace, built on open models</div>
      </header>

      <div class="rail">
        <button type="button" phx-click="toggle_provider" class="rail-item">
          <span class={"dot #{if @provider == :granville, do: "dot-local", else: "dot-cloud"}"}></span>
          <span class="rail-label">provider</span>
          <span class="rail-value">{provider_label(@provider)}</span>
        </button>

        <button type="button" phx-click="toggle_redact" class="rail-item">
          <span class={"dot #{if @redact, do: "dot-cloud", else: "dot-off"}"}></span>
          <span class="rail-label">redaction</span>
          <span class="rail-value">{if @redact, do: "ON — PII stripped before inference (slower)", else: "OFF"}</span>
        </button>

        <div class={"rail-item rail-status #{if @pending, do: "rail-status-active"}"}>
          <span class="pulse"></span>
          <span class="rail-value">{if @pending, do: "awaiting response…", else: "idle"}</span>
        </div>
      </div>

      <main id="messages" phx-update="stream" class="log">
        <div :for={{dom_id, message} <- @streams.messages} id={dom_id} class={"log-entry log-entry-#{message.role}"}>
          <div class="log-meta">
            <span class="log-tag">{role_tag(message.role)}</span>
            <span :if={message.provider} class="log-provider">{provider_label(message.provider)}</span>
          </div>
          <p class="log-text">{message.text}</p>
        </div>
      </main>

      <form phx-submit="send" phx-change="update_draft" class="dock">
        <textarea
          name="message[text]"
          class="dock-input"
          placeholder="speak freely — this stays on your machine unless you say otherwise"
          rows="2"
        >{@draft}</textarea>
        <button type="submit" class="dock-submit" disabled={@pending}>
          {if @pending, do: "…", else: "send"}
        </button>
      </form>
    </div>
    """
  end
end
