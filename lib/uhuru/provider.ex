defmodule Uhuru.Provider do
  @moduledoc """
  Behaviour for pluggable model providers.

  Granville (local, CPU-first) is the default and never leaves the
  machine. Together AI and any future adapter are explicit, opt-in
  upgrades a caller reaches for when they want a stronger model.
  """

  @type opts :: [max_tokens: pos_integer()]

  @callback complete(prompt :: String.t(), opts :: opts()) ::
              {:ok, String.t()} | {:error, term()}
end
