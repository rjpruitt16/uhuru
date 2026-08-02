defmodule UhuruWeb.ChatLiveTest do
  use UhuruWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Uhuru.{Conversations, Vault}

  describe "vault gate" do
    setup do
      Vault.lock()
      :ok
    end

    test "shows the setup screen when no vault exists yet", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "set a passphrase"
      assert html =~ "cannot be recovered"
    end

    test "creating the vault with mismatched passphrases shows an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("form", passphrase: %{value: "abc", confirm: "xyz"})
        |> render_submit()

      assert html =~ "don&#39;t match" or html =~ "don't match"
      refute Vault.set_up?()
    end

    test "creating the vault with matching passphrases unlocks straight into chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("form", passphrase: %{value: "correct horse", confirm: "correct horse"})
        |> render_submit()

      assert html =~ "LOCAL / GRANVILLE"
      assert Vault.set_up?()
      refute Vault.locked?()
    end

    test "shows the unlock screen once set up but locked", %{conn: conn} do
      :ok = Vault.setup("existing passphrase")
      Vault.lock()

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "enter your passphrase"
    end

    test "unlocking with the wrong passphrase shows an error and stays locked", %{conn: conn} do
      :ok = Vault.setup("existing passphrase")
      Vault.lock()

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> form("form", passphrase: %{value: "wrong"}) |> render_submit()

      assert html =~ "Incorrect passphrase"
      assert Vault.locked?()
    end

    test "unlocking with the correct passphrase reaches chat", %{conn: conn} do
      :ok = Vault.setup("existing passphrase")
      Vault.lock()

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> form("form", passphrase: %{value: "existing passphrase"}) |> render_submit()

      assert html =~ "LOCAL / GRANVILLE"
      refute Vault.locked?()
    end
  end

  describe "chat, once unlocked" do
    setup do
      Vault.lock()
      :ok = Vault.setup("test passphrase")
      :ok
    end

    test "renders the shell with local provider and redaction off by default, model picker in the dock", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "UHURU"
      assert html =~ "LOCAL / GRANVILLE"
      refute html =~ "ON — PII stripped"
      assert html =~ "dock-model-select"
      assert html =~ "Qwen 2.5 7B"
      assert html =~ "Llama 3.3 70B"
      assert html =~ "DeepSeek V3"
    end

    test "selecting a model in the dock switches both provider and together_model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> element("form.dock-model-form")
        |> render_change(%{"model_choice" => "together:meta-llama/Llama-3.3-70B-Instruct-Turbo"})

      assert html =~ "CLOUD / TOGETHER"

      html =
        view
        |> element("form.dock-model-form")
        |> render_change(%{"model_choice" => "granville"})

      assert html =~ "LOCAL / GRANVILLE"
    end

    test "toggle_redact switches PII redaction on and off", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button", "redaction") |> render_click()
      assert html =~ "ON — PII stripped"

      html = view |> element("button", "redaction") |> render_click()
      refute html =~ "ON — PII stripped"
    end

    test "lock_vault re-locks and returns to the unlock gate", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button", "vault") |> render_click()

      assert html =~ "enter your passphrase"
      assert Vault.locked?()
    end

    test "submitting blank text does not add a message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> form("form.dock", message: %{text: "   "}) |> render_submit()

      refute html =~ "log-entry-user"
    end

    test "user messages don't show a YOU tag; replies show a model + adapter tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> form("form.dock", message: %{text: "hello, uhuru"}) |> render_submit()
      refute html =~ ">YOU<"

      html = render_async(view)
      assert html =~ "ERROR"
      assert html =~ "Gemma 3 4B"
      assert html =~ "Granville"
    end

    test "sending a message with no provider configured surfaces a graceful error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> form("form.dock", message: %{text: "hello, uhuru"}) |> render_submit()
      assert html =~ "hello, uhuru"
      assert html =~ "awaiting response"

      html = render_async(view)
      assert html =~ "ERROR"
      assert html =~ "Local model socket not found"
    end

    test "sending the first message creates a thread and shows it in the sidebar", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "no threads yet"

      html = view |> form("form.dock", message: %{text: "what is the swahili coast"}) |> render_submit()

      assert html =~ "sidebar-thread"
      assert html =~ "what is the swahili coast"
      assert [%{title: "what is the swahili coast"}] = Conversations.list_threads()
    end

    test "message content is actually encrypted at rest, not stored as plaintext", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("form.dock", message: %{text: "a secret only i should read"}) |> render_submit()
      render_async(view)

      raw = Uhuru.Repo.query!("SELECT content FROM messages LIMIT 1").rows |> List.first() |> List.first()
      refute raw == "a secret only i should read"
    end

    test "new_chat clears the thread and starts fresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view |> form("form.dock", message: %{text: "first thread message"}) |> render_submit()
      render_async(view)

      html = view |> element("button.sidebar-new") |> render_click()

      refute html =~ "log-entry-user"
      assert html =~ "first thread message"
    end

    test "selecting a thread from the sidebar loads its messages", %{conn: conn} do
      {:ok, thread} = Conversations.create_thread("an older conversation", "granville")
      {:ok, _} = Conversations.create_message(thread.id, %{role: :user, content: "an older conversation"})

      {:ok, _} =
        Conversations.create_message(thread.id, %{
          role: :assistant,
          content: "an older reply",
          provider: :granville,
          model: "Gemma 3 4B"
        })

      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button.sidebar-thread", "an older conversation") |> render_click()

      assert html =~ "an older conversation"
      assert html =~ "an older reply"
    end

    test "the model picker locks once a thread has started, and shows which model is locked in", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "dock-model-select"
      refute html =~ "dock-model-locked"

      html = view |> form("form.dock", message: %{text: "hello"}) |> render_submit()

      assert html =~ "dock-model-locked"
      assert html =~ "locked for this thread"
      refute html =~ "dock-model-select"
    end

    test "delete_thread removes it from the sidebar and resets to new-chat if it was open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> form("form.dock", message: %{text: "a thread worth deleting"}) |> render_submit()
      assert html =~ "a thread worth deleting"

      [thread] = Conversations.list_threads()

      html = view |> element("button.sidebar-delete") |> render_click()

      refute html =~ "a thread worth deleting"
      assert html =~ "dock-model-select"
      assert Conversations.list_threads() == []
      assert Conversations.get_thread(thread.id) == nil
    end

    test "markdown in a reply renders as real HTML, not literal syntax characters", %{conn: conn} do
      {:ok, thread} = Conversations.create_thread("markdown test", "granville")

      {:ok, _} =
        Conversations.create_message(thread.id, %{
          role: :assistant,
          content: "# Heading\n\n**bold** and a list:\n\n- one\n- two",
          provider: :granville,
          model: "Gemma 3 4B"
        })

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("button.sidebar-thread", "markdown test") |> render_click()

      assert html =~ "<h1"
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<li>"
      refute html =~ "**bold**"
    end
  end
end
