defmodule Uhuru.Repo do
  use Ecto.Repo,
    otp_app: :uhuru,
    adapter: Ecto.Adapters.SQLite3
end
