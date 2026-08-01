defmodule UhuruWeb.ChatLiveTest do
  use UhuruWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Uhuru.Vault

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
      assert html =~ ">OFF<"
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
      assert html =~ ">OFF<"
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

    test "sending a message with no provider configured surfaces a graceful error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> form("form.dock", message: %{text: "hello, uhuru"}) |> render_submit()
      assert html =~ "hello, uhuru"
      assert html =~ "awaiting response"

      html = render_async(view)
      assert html =~ "ERROR"
      assert html =~ "Local model socket not found"
    end
  end
end
