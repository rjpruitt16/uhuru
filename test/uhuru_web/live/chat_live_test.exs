defmodule UhuruWeb.ChatLiveTest do
  use UhuruWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the shell with local provider and redaction off by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "UHURU"
    assert html =~ "LOCAL / GRANVILLE"
    assert html =~ ">OFF<"
  end

  test "toggle_provider switches between granville and together", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element("button", "provider") |> render_click()
    assert html =~ "CLOUD / TOGETHER"

    html = view |> element("button", "provider") |> render_click()
    assert html =~ "LOCAL / GRANVILLE"
  end

  test "toggle_redact switches PII redaction on and off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> element("button", "redaction") |> render_click()
    assert html =~ "ON — PII stripped"

    html = view |> element("button", "redaction") |> render_click()
    assert html =~ ">OFF<"
  end

  test "submitting blank text does not add a message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("form", message: %{text: "   "}) |> render_submit()

    refute html =~ "log-entry-user"
  end

  test "sending a message with no provider configured surfaces a graceful error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html = view |> form("form", message: %{text: "hello, uhuru"}) |> render_submit()
    assert html =~ "hello, uhuru"
    assert html =~ "awaiting response"

    html = render_async(view)
    assert html =~ "ERROR"
    assert html =~ "Local model socket not found"
  end
end
