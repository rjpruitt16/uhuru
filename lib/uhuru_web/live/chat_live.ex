defmodule UhuruWeb.ChatLive do
  use UhuruWeb, :live_view

  alias Uhuru.{Chat, Conversations, Vault}
  alias Uhuru.Providers.Granville

  # Together's model listing doesn't reliably flag which models are callable
  # on shared serverless capacity vs. which need a paid dedicated endpoint —
  # these IDs are verified against the live chat/completions API.
  @model_choices [
    %{
      value: "granville",
      label: "Local — Granville",
      provider: :granville,
      model: nil,
      short_label: nil
    },
    %{
      value: "together:Qwen/Qwen2.5-7B-Instruct-Turbo",
      label: "Together — Qwen 2.5 7B (fast)",
      provider: :together,
      model: "Qwen/Qwen2.5-7B-Instruct-Turbo",
      short_label: "Qwen 2.5 7B"
    },
    %{
      value: "together:meta-llama/Llama-3.3-70B-Instruct-Turbo",
      label: "Together — Llama 3.3 70B (stronger)",
      provider: :together,
      model: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
      short_label: "Llama 3.3 70B"
    },
    %{
      value: "together:deepseek-ai/DeepSeek-V3",
      label: "Together — DeepSeek V3 (frontier, sometimes busy)",
      provider: :together,
      model: "deepseek-ai/DeepSeek-V3",
      short_label: "DeepSeek V3"
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
    granville_configured = Granville.configured?()
    granville_ready = granville_configured and Granville.ready?()
    granville_downloaded = granville_configured and Granville.downloaded?()

    if connected?(socket) and granville_configured and not granville_ready do
      Process.send_after(self(), :check_granville, 3000)
    end

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
      threads: Conversations.list_threads(),
      granville_configured: granville_configured,
      granville_ready: granville_ready,
      granville_downloaded: granville_downloaded,
      streaming_reply: nil
    )
    |> stream(:messages, [])
  end

  @impl true
  def handle_info(:check_granville, socket) do
    ready = Granville.ready?()
    unless ready, do: Process.send_after(self(), :check_granville, 3000)
    {:noreply, assign(socket, granville_ready: ready, granville_downloaded: Granville.downloaded?())}
  end

  def handle_info({:tool_call, id, query}, socket) do
    case socket.assigns.streaming_reply do
      %{id: ^id} = reply ->
        updated = %{reply | tool_call: query}

        {:noreply,
         socket
         |> assign(streaming_reply: updated)
         |> stream_insert(:messages, updated)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:stream_chunk, id, chunk}, socket) do
    case socket.assigns.streaming_reply do
      %{id: ^id} = reply ->
        updated = %{reply | text: reply.text <> chunk}

        {:noreply,
         socket
         |> assign(streaming_reply: updated)
         |> stream_insert(:messages, updated)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:stream_done, id, result}, socket) do
    case socket.assigns.streaming_reply do
      %{id: ^id} = reply ->
        final =
          case result do
            :ok -> reply
            {:error, reason} -> %{reply | role: :error, text: format_error(reason)}
          end

        {:ok, _} =
          Conversations.create_message(socket.assigns.current_thread_id, %{
            role: final.role,
            content: final.text,
            provider: final.provider,
            model: final.model_label
          })

        {:noreply,
         socket
         |> stream_insert(:messages, final)
         |> assign(pending: false, threads: Conversations.list_threads(), streaming_reply: nil)}

      _ ->
        {:noreply, socket}
    end
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
    if socket.assigns.current_thread_id do
      # Locked once a thread has started (the UI already disables the
      # select for this state); ignore rather than trust the client.
      {:noreply, socket}
    else
      choice = Enum.find(@model_choices, &(&1.value == value))

      {:noreply,
       assign(socket,
         model_choice: choice.value,
         provider: choice.provider,
         together_model: choice.model
       )}
    end
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply,
     socket
     |> assign(current_thread_id: nil, draft: "", next_id: 1, streaming_reply: nil)
     |> stream(:messages, [], reset: true)}
  end

  def handle_event("select_thread", %{"id" => id}, socket) do
    thread_id = String.to_integer(id)
    thread = Conversations.get_thread(thread_id)
    messages = Conversations.list_messages(thread_id)

    mapped =
      Enum.map(
        messages,
        &%{
          id: &1.id,
          role: &1.role,
          text: &1.content,
          provider: &1.provider,
          model_label: &1.model,
          tool_call: nil
        }
      )

    next_id = mapped |> Enum.map(& &1.id) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
    {provider, together_model} = provider_for_model_choice(thread.model_choice)

    {:noreply,
     socket
     |> assign(
       current_thread_id: thread_id,
       next_id: next_id,
       model_choice: thread.model_choice,
       provider: provider,
       together_model: together_model,
       streaming_reply: nil
     )
     |> stream(:messages, mapped, reset: true)}
  end

  def handle_event("delete_thread", %{"id" => id}, socket) do
    thread_id = String.to_integer(id)
    Conversations.delete_thread(thread_id)

    socket =
      if socket.assigns.current_thread_id == thread_id do
        socket
        |> assign(current_thread_id: nil, draft: "", next_id: 1, streaming_reply: nil)
        |> stream(:messages, [], reset: true)
      else
        socket
      end

    {:noreply, assign(socket, threads: Conversations.list_threads())}
  end

  def handle_event("send", %{"message" => %{"text" => raw_text}}, socket) do
    text = String.trim(raw_text)

    if text == "" or socket.assigns.pending do
      {:noreply, socket}
    else
      %{
        provider: provider,
        redact: redact,
        together_model: together_model,
        model_choice: model_choice,
        next_id: id
      } = socket.assigns

      thread_id = ensure_thread(socket, text, model_choice)
      {:ok, _} = Conversations.create_message(thread_id, %{role: :user, content: text})

      model_label = model_label_for(provider, together_model)

      reply = %{
        id: id + 1,
        role: :assistant,
        text: "",
        provider: provider,
        model_label: model_label,
        tool_call: nil
      }

      live_view_pid = self()

      opts =
        case provider do
          :together ->
            [
              ranked: redact,
              model: together_model,
              on_tool_call: fn query -> send(live_view_pid, {:tool_call, reply.id, query}) end
            ]

          :granville ->
            [ranked: redact]
        end

      socket =
        socket
        |> assign(current_thread_id: thread_id, threads: Conversations.list_threads())
        |> stream_insert(:messages, %{
          id: id,
          role: :user,
          text: text,
          provider: nil,
          model_label: nil,
          tool_call: nil
        })
        |> stream_insert(:messages, reply)
        |> assign(draft: "", pending: true, next_id: id + 2, streaming_reply: reply)

      Task.start(fn ->
        on_chunk = fn chunk -> send(live_view_pid, {:stream_chunk, reply.id, chunk}) end
        result = Chat.send_message_streaming(text, provider, opts, on_chunk)
        send(live_view_pid, {:stream_done, reply.id, result})
      end)

      {:noreply, socket}
    end
  end

  defp ensure_thread(%{assigns: %{current_thread_id: nil}}, first_message_text, model_choice) do
    {:ok, thread} = Conversations.create_thread(first_message_text, model_choice)
    thread.id
  end

  defp ensure_thread(%{assigns: %{current_thread_id: id}}, _first_message_text, _model_choice),
    do: id

  defp provider_for_model_choice(model_choice) do
    case Enum.find(@model_choices, &(&1.value == model_choice)) do
      %{provider: provider, model: model} -> {provider, model}
      nil -> {:granville, nil}
    end
  end

  defp model_label_for(:granville, _together_model), do: Granville.model_label()

  defp model_label_for(:together, together_model) do
    Enum.find_value(@model_choices, together_model, fn choice ->
      if choice.model == together_model, do: choice.short_label
    end)
  end

  defp format_error(:missing_api_key), do: "No API key configured for this provider."
  defp format_error(:econnrefused), do: "Local model isn't running. Start it with: granville serve <model.gguf>"
  defp format_error(:enoent), do: "Local model socket not found. Start it with: granville serve <model.gguf>"
  defp format_error(:unsupported_tool_call), do: "The model tried to use a tool we don't support."
  defp format_error({:web_search_failed, reason}), do: "Web search failed: #{inspect(reason)}"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  defp provider_label(:granville), do: "LOCAL / GRANVILLE"
  defp provider_label(:together), do: "CLOUD / TOGETHER"

  defp adapter_name(:granville), do: "Granville"
  defp adapter_name(:together), do: "Together"

  defp granville_status(true, _downloaded), do: "loaded"
  defp granville_status(false, false), do: "downloading model…"
  defp granville_status(false, true), do: "loading into memory…"

  defp role_tag(:assistant), do: "REPLY"
  defp role_tag(:error), do: "ERROR"

  defp thread_title(%{title: nil}), do: "untitled"
  defp thread_title(%{title: title}), do: title

  defp locked_model_label(model_choice, choices) do
    case Enum.find(choices, &(&1.value == model_choice)) do
      %{label: label} -> label
      nil -> model_choice
    end
  end

  defp render_markdown(text) do
    text
    |> Earmark.as_html!(escape: true, compact_output: true)
    |> Phoenix.HTML.raw()
  end

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
                <div
                  :for={thread <- @threads}
                  class={[
                    "sidebar-thread-row",
                    thread.id == @current_thread_id && "sidebar-thread-row-active"
                  ]}
                >
                  <button type="button" phx-click="select_thread" phx-value-id={thread.id} class="sidebar-thread">
                    {thread_title(thread)}
                  </button>
                  <button
                    type="button"
                    phx-click="delete_thread"
                    phx-value-id={thread.id}
                    class="sidebar-delete"
                    data-confirm="Delete this thread? This can't be undone."
                    aria-label="Delete thread"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
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

                  <div :if={@granville_configured} class="rail-item rail-status">
                    <span class={"dot #{if @granville_ready, do: "dot-local", else: "dot-cloud"}"}>
                    </span>
                    <span class="rail-label">local model</span>
                    <span class="rail-value">
                      {granville_status(@granville_ready, @granville_downloaded)}
                    </span>
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
                  <div :if={message.role != :user} class="log-meta">
                    <span class="log-tag">{role_tag(message.role)}</span>
                    <span :if={message.model_label} class="log-provider">
                      {message.model_label} · {adapter_name(message.provider)}
                    </span>
                  </div>
                  <div :if={message.tool_call} class="log-tool-call">
                    🔍 searched the web for "{message.tool_call}"
                  </div>
                  <div class="log-text">{render_markdown(message.text)}</div>
                </div>
              </main>

              <div class="dock-wrap">
                <div class="dock-inner">
                  <%= if @current_thread_id do %>
                    <div class="dock-model-locked">
                      model: {locked_model_label(@model_choice, @model_choices)} (locked for this thread)
                    </div>
                  <% else %>
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
                  <% end %>

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
