defmodule UhuruWeb.ChatLive do
  use UhuruWeb, :live_view

  alias Uhuru.{Chat, Vault}

  # Together's model listing doesn't reliably flag which models are callable
  # on shared serverless capacity vs. which need a paid dedicated endpoint —
  # this list is only IDs verified against the live chat/completions API.
  @together_models [
    {"Qwen/Qwen2.5-7B-Instruct-Turbo", "Qwen 2.5 7B — fast"},
    {"meta-llama/Llama-3.3-70B-Instruct-Turbo", "Llama 3.3 70B — stronger"},
    {"deepseek-ai/DeepSeek-V3", "DeepSeek V3 — frontier-class, sometimes busy"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    vault_state = cond do
      not Vault.set_up?() -> :needs_setup
      Vault.locked?() -> :locked
      true -> :unlocked
    end

    socket = assign(socket, vault_state: vault_state, passphrase_error: nil)
    socket = if vault_state == :unlocked, do: init_chat(socket), else: socket

    {:ok, socket}
  end

  defp init_chat(socket) do
    {default_model, _label} = hd(@together_models)

    socket
    |> assign(
      page_title: "Uhuru",
      draft: "",
      provider: :granville,
      together_model: default_model,
      together_models: @together_models,
      redact: false,
      pending: false,
      next_id: 1
    )
    |> stream(:messages, [])
  end

  @impl true
  def handle_event("vault_setup", %{"passphrase" => params}, socket) do
    pass = Map.get(params, "value", "")
    confirm = Map.get(params, "confirm", "")

    cond do
      pass == "" ->
        {:noreply, assign(socket, passphrase_error: "Passphrase can't be blank.")}

      pass != confirm ->
        {:noreply, assign(socket, passphrase_error: "Passphrases don't match.")}

      true ->
        case Vault.setup(pass) do
          :ok ->
            {:noreply, socket |> assign(vault_state: :unlocked, passphrase_error: nil) |> init_chat()}

          {:error, _reason} ->
            {:noreply, assign(socket, passphrase_error: "Setup failed. Reload and try again.")}
        end
    end
  end

  def handle_event("vault_unlock", %{"passphrase" => %{"value" => pass}}, socket) do
    case Vault.unlock(pass) do
      :ok ->
        {:noreply, socket |> assign(vault_state: :unlocked, passphrase_error: nil) |> init_chat()}

      {:error, :invalid_passphrase} ->
        {:noreply, assign(socket, passphrase_error: "Incorrect passphrase.")}

      {:error, :not_set_up} ->
        {:noreply, assign(socket, vault_state: :needs_setup, passphrase_error: nil)}
    end
  end

  def handle_event("lock_vault", _params, socket) do
    Vault.lock()
    {:noreply, assign(socket, vault_state: :locked, passphrase_error: nil)}
  end

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

  def handle_event("select_together_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, together_model: model)}
  end

  def handle_event("send", %{"message" => %{"text" => raw_text}}, socket) do
    text = String.trim(raw_text)

    if text == "" or socket.assigns.pending do
      {:noreply, socket}
    else
      %{provider: provider, redact: redact, together_model: together_model, next_id: id} = socket.assigns

      opts =
        case provider do
          :together -> [ranked: redact, model: together_model]
          :granville -> [ranked: redact]
        end

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

  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :error, :string, default: nil
  attr :event, :string, required: true
  attr :confirm, :boolean, default: false

  defp vault_gate(assigns) do
    ~H"""
    <div class="gate">
      <form phx-submit={@event} class="gate-form">
        <p class="gate-title">{@title}</p>
        <p class="gate-hint">{@hint}</p>
        <input type="password" name="passphrase[value]" class="gate-input" placeholder="passphrase" autofocus />
        <input
          :if={@confirm}
          type="password"
          name="passphrase[confirm]"
          class="gate-input"
          placeholder="confirm passphrase"
        />
        <p :if={@error} class="gate-error">{@error}</p>
        <button type="submit" class="gate-submit">{if @confirm, do: "create vault", else: "unlock"}</button>
      </form>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="uhuru-shell">
      <div class="grain"></div>

      <header class="uhuru-header">
        <div class="wordmark">UHURU</div>
        <div class="tagline">a privacy-first ai workspace, built on open models</div>
      </header>

      <%= case @vault_state do %>
        <% :needs_setup -> %>
          <.vault_gate
            title="set a passphrase"
            hint="this encrypts everything stored locally. it is never saved anywhere — if you forget it, your data cannot be recovered."
            error={@passphrase_error}
            event="vault_setup"
            confirm={true}
          />
        <% :locked -> %>
          <.vault_gate
            title="enter your passphrase"
            hint="unlocks this session only. nothing is ever written to disk."
            error={@passphrase_error}
            event="vault_unlock"
          />
        <% :unlocked -> %>
          <div class="rail">
            <button type="button" phx-click="toggle_provider" class="rail-item">
              <span class={"dot #{if @provider == :granville, do: "dot-local", else: "dot-cloud"}"}></span>
              <span class="rail-label">provider</span>
              <span class="rail-value">{provider_label(@provider)}</span>
            </button>

            <div :if={@provider == :together} class="rail-item rail-select">
              <span class="dot dot-cloud"></span>
              <span class="rail-label">model</span>
              <form phx-change="select_together_model">
                <select name="model" class="rail-dropdown">
                  <option :for={{id, label} <- @together_models} value={id} selected={id == @together_model}>
                    {label}
                  </option>
                </select>
              </form>
            </div>

            <button type="button" phx-click="toggle_redact" class="rail-item">
              <span class={"dot #{if @redact, do: "dot-cloud", else: "dot-off"}"}></span>
              <span class="rail-label">redaction</span>
              <span class="rail-value">{if @redact, do: "ON — PII stripped before inference (slower)", else: "OFF"}</span>
            </button>

            <button type="button" phx-click="lock_vault" class="rail-item">
              <span class="dot dot-local"></span>
              <span class="rail-label">vault</span>
              <span class="rail-value">unlocked — click to lock</span>
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
      <% end %>
    </div>
    """
  end
end
