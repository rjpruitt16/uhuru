defmodule UhuruWeb.ChatLive do
  use UhuruWeb, :live_view

  alias Uhuru.{Chat, Conversations, Vault}

  # Together's model listing doesn't reliably flag which models are callable
  # on shared serverless capacity vs. which need a paid dedicated endpoint —
  # these IDs are verified against the live chat/completions API.
  @model_choices [
    %{value: "granville", label: "Local — Granville", provider: :granville, model: nil},
    %{
      value: "together:Qwen/Qwen2.5-7B-Instruct-Turbo",
      label: "Together — Qwen 2.5 7B (fast)",
      provider: :together,
      model: "Qwen/Qwen2.5-7B-Instruct-Turbo"
    },
    %{
      value: "together:meta-llama/Llama-3.3-70B-Instruct-Turbo",
      label: "Together — Llama 3.3 70B (stronger)",
      provider: :together,
      model: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
    },
    %{
      value: "together:deepseek-ai/DeepSeek-V3",
      label: "Together — DeepSeek V3 (frontier, sometimes busy)",
      provider: :together,
      model: "deepseek-ai/DeepSeek-V3"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    vault_state =
      cond do
        not Vault.set_up?() -> :needs_setup
        Vault.locked?() -> :locked
        true -> :unlocked
      end

    socket = assign(socket, vault_state: vault_state, passphrase_error: nil)
    socket = if vault_state == :unlocked, do: init_chat(socket), else: socket

    {:ok, socket}
  end

  defp init_chat(socket) do
    default = hd(@model_choices)

    socket
    |> assign(
      page_title: "Uhuru",
      draft: "",
      model_choice: default.value,
      provider: default.provider,
      together_model: default.model,
      model_choices: @model_choices,
      redact: false,
      pending: false,
      next_id: 1,
      current_thread_id: nil,
      threads: Conversations.list_threads()
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
            {:noreply,
             socket |> assign(vault_state: :unlocked, passphrase_error: nil) |> init_chat()}

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

  def handle_event("toggle_redact", _params, socket) do
    {:noreply, assign(socket, redact: !socket.assigns.redact)}
  end

  def handle_event("select_model", %{"model_choice" => value}, socket) do
    choice = Enum.find(@model_choices, &(&1.value == value))

    {:noreply,
     assign(socket,
       model_choice: choice.value,
       provider: choice.provider,
       together_model: choice.model
     )}
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply,
     socket
     |> assign(current_thread_id: nil, draft: "", next_id: 1)
     |> stream(:messages, [], reset: true)}
  end

  def handle_event("select_thread", %{"id" => id}, socket) do
    thread_id = String.to_integer(id)
    messages = Conversations.list_messages(thread_id)

    mapped =
      Enum.map(messages, &%{id: &1.id, role: &1.role, text: &1.content, provider: &1.provider})

    next_id = mapped |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

    {:noreply,
     socket
     |> assign(current_thread_id: thread_id, next_id: next_id)
     |> stream(:messages, mapped, reset: true)}
  end

  def handle_event("send", %{"message" => %{"text" => raw_text}}, socket) do
    text = String.trim(raw_text)

    if text == "" or socket.assigns.pending do
      {:noreply, socket}
    else
      %{provider: provider, redact: redact, together_model: together_model, next_id: id} =
        socket.assigns

      opts =
        case provider do
          :together -> [ranked: redact, model: together_model]
          :granville -> [ranked: redact]
        end

      thread_id = ensure_thread(socket, text)
      {:ok, _} = Conversations.create_message(thread_id, %{role: :user, content: text})

      socket =
        socket
        |> assign(current_thread_id: thread_id, threads: Conversations.list_threads())
        |> stream_insert(:messages, %{id: id, role: :user, text: text, provider: nil})
        |> assign(draft: "", pending: true, next_id: id + 1)
        |> start_async(:reply, fn -> Chat.send_message(text, provider, opts) end)

      {:noreply, socket}
    end
  end

  defp ensure_thread(%{assigns: %{current_thread_id: nil}}, first_message_text) do
    {:ok, thread} = Conversations.create_thread(first_message_text)
    thread.id
  end

  defp ensure_thread(%{assigns: %{current_thread_id: id}}, _first_message_text), do: id

  @impl true
  def handle_async(:reply, {:ok, result}, socket) do
    %{provider: provider, next_id: id, current_thread_id: thread_id} = socket.assigns

    message =
      case result do
        {:ok, text} ->
          %{id: id, role: :assistant, text: text, provider: provider}

        {:error, reason} ->
          %{id: id, role: :error, text: format_error(reason), provider: provider}
      end

    {:ok, _} =
      Conversations.create_message(thread_id, %{
        role: message.role,
        content: message.text,
        provider: message.provider
      })

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(pending: false, next_id: id + 1, threads: Conversations.list_threads())}
  end

  def handle_async(:reply, {:exit, reason}, socket) do
    %{next_id: id, current_thread_id: thread_id} = socket.assigns
    text = "Crashed: #{inspect(reason)}"
    message = %{id: id, role: :error, text: text, provider: nil}

    {:ok, _} = Conversations.create_message(thread_id, %{role: :error, content: text})

    {:noreply,
     socket
     |> stream_insert(:messages, message)
     |> assign(pending: false, next_id: id + 1, threads: Conversations.list_threads())}
  end

  defp format_error(:missing_api_key), do: "No API key configured for this provider."

  defp format_error(:econnrefused),
    do: "Local model isn't running. Start it with: granville serve <model.gguf>"

  defp format_error(:enoent),
    do: "Local model socket not found. Start it with: granville serve <model.gguf>"

  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp provider_label(:granville), do: "LOCAL / GRANVILLE"
  defp provider_label(:together), do: "CLOUD / TOGETHER"

  defp role_tag(:user), do: "YOU"
  defp role_tag(:assistant), do: "REPLY"
  defp role_tag(:error), do: "ERROR"

  defp thread_title(%{title: nil}), do: "untitled"
  defp thread_title(%{title: title}), do: title

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
        <input
          type="password"
          name="passphrase[value]"
          class="gate-input"
          placeholder="passphrase"
          autofocus
        />
        <input
          :if={@confirm}
          type="password"
          name="passphrase[confirm]"
          class="gate-input"
          placeholder="confirm passphrase"
        />
        <p :if={@error} class="gate-error">{@error}</p>
        <button type="submit" class="gate-submit">
          {if @confirm, do: "create vault", else: "unlock"}
        </button>
      </form>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="uhuru-shell">
      <div class="grain"></div>

      <%= case @vault_state do %>
        <% :needs_setup -> %>
          <header class="uhuru-header">
            <div class="wordmark">UHURU</div>
            <div class="tagline">a privacy-first ai workspace, built on open models</div>
          </header>
          <.vault_gate
            title="set a passphrase"
            hint="this encrypts everything stored locally. it is never saved anywhere — if you forget it, your data cannot be recovered."
            error={@passphrase_error}
            event="vault_setup"
            confirm={true}
          />
        <% :locked -> %>
          <header class="uhuru-header">
            <div class="wordmark">UHURU</div>
            <div class="tagline">a privacy-first ai workspace, built on open models</div>
          </header>
          <.vault_gate
            title="enter your passphrase"
            hint="unlocks this session only. nothing is ever written to disk."
            error={@passphrase_error}
            event="vault_unlock"
          />
        <% :unlocked -> %>
          <div class="app-body">
            <aside class="sidebar">
              <div class="sidebar-brand">
                <div class="wordmark">UHURU</div>
              </div>
              <button type="button" phx-click="new_chat" class="sidebar-new">+ new thread</button>
              <div class="sidebar-threads">
                <button
                  :for={thread <- @threads}
                  type="button"
                  phx-click="select_thread"
                  phx-value-id={thread.id}
                  class={[
                    "sidebar-thread",
                    thread.id == @current_thread_id && "sidebar-thread-active"
                  ]}
                >
                  {thread_title(thread)}
                </button>
                <p :if={@threads == []} class="sidebar-empty">no threads yet</p>
              </div>
            </aside>

            <div class="chat-column">
              <div class="rail">
                <div class="rail-inner">
                  <div class="rail-item rail-status">
                    <span class={"dot #{if @provider == :granville, do: "dot-local", else: "dot-cloud"}"}>
                    </span>
                    <span class="rail-label">model</span>
                    <span class="rail-value">{provider_label(@provider)}</span>
                  </div>

                  <button type="button" phx-click="toggle_redact" class="rail-item">
                    <span class={"dot #{if @redact, do: "dot-cloud", else: "dot-off"}"}></span>
                    <span class="rail-label">redaction</span>
                    <span class="rail-value">
                      {if @redact, do: "ON — PII stripped before inference (slower)", else: "OFF"}
                    </span>
                  </button>

                  <button type="button" phx-click="lock_vault" class="rail-item">
                    <span class="dot dot-local"></span>
                    <span class="rail-label">vault</span>
                    <span class="rail-value">unlocked — click to lock</span>
                  </button>

                  <div class={"rail-item rail-status #{if @pending, do: "rail-status-active"}"}>
                    <span class="pulse"></span>
                    <span class="rail-value">
                      {if @pending, do: "awaiting response…", else: "idle"}
                    </span>
                  </div>
                </div>
              </div>

              <main id="messages" phx-update="stream" class="log">
                <div
                  :for={{dom_id, message} <- @streams.messages}
                  id={dom_id}
                  class={"log-entry log-entry-#{message.role}"}
                >
                  <div class="log-meta">
                    <span class="log-tag">{role_tag(message.role)}</span>
                    <span :if={message.provider} class="log-provider">
                      {provider_label(message.provider)}
                    </span>
                  </div>
                  <p class="log-text">{message.text}</p>
                </div>
              </main>

              <div class="dock-wrap">
                <div class="dock-inner">
                  <form phx-change="select_model" class="dock-model-form">
                    <select name="model_choice" class="dock-model-select">
                      <option
                        :for={choice <- @model_choices}
                        value={choice.value}
                        selected={choice.value == @model_choice}
                      >
                        {choice.label}
                      </option>
                    </select>
                  </form>

                  <form phx-submit="send" phx-change="update_draft" class="dock">
                    <textarea
                      id="message-input"
                      name="message[text]"
                      class="dock-input"
                      placeholder="speak freely — this stays on your machine unless you say otherwise"
                      rows="2"
                      phx-hook="SubmitOnEnter"
                    >{@draft}</textarea>
                    <button type="submit" class="dock-submit" disabled={@pending}>
                      {if @pending, do: "…", else: "send"}
                    </button>
                  </form>
                </div>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end
end
