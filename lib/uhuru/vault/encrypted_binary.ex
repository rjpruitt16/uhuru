defmodule Uhuru.Vault.EncryptedBinary do
  @moduledoc """
  Ecto type that transparently encrypts/decrypts through Uhuru.Vault.
  Reads and writes fail (rather than silently storing plaintext) while
  the vault is locked — there is no fallback path that skips encryption.
  """

  use Ecto.Type

  alias Uhuru.Vault

  def type, do: :binary

  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(value) when is_binary(value) do
    case Vault.encrypt(value) do
      {:ok, ciphertext} -> {:ok, ciphertext}
      {:error, _reason} -> :error
    end
  end

  def dump(_), do: :error

  def load(ciphertext) when is_binary(ciphertext) do
    case Vault.decrypt(ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _reason} -> :error
    end
  end
end
