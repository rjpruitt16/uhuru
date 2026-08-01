defmodule Uhuru.VaultTest do
  use Uhuru.DataCase, async: false

  alias Uhuru.Vault

  setup do
    Vault.lock()
    :ok
  end

  test "not set up and locked initially" do
    refute Vault.set_up?()
    assert Vault.locked?()
  end

  test "setup creates the vault and unlocks it" do
    assert :ok = Vault.setup("correct horse battery staple")
    assert Vault.set_up?()
    refute Vault.locked?()
  end

  test "setup fails if already set up" do
    assert :ok = Vault.setup("first passphrase")
    assert {:error, :already_set_up} = Vault.setup("second passphrase")
  end

  test "lock clears the in-memory key without touching storage" do
    :ok = Vault.setup("my passphrase")
    refute Vault.locked?()

    assert :ok = Vault.lock()
    assert Vault.locked?()
    assert Vault.set_up?()
  end

  test "unlock with the correct passphrase" do
    :ok = Vault.setup("my passphrase")
    Vault.lock()

    assert :ok = Vault.unlock("my passphrase")
    refute Vault.locked?()
  end

  test "unlock with the wrong passphrase fails and stays locked" do
    :ok = Vault.setup("my passphrase")
    Vault.lock()

    assert {:error, :invalid_passphrase} = Vault.unlock("wrong passphrase")
    assert Vault.locked?()
  end

  test "unlock before any setup" do
    assert {:error, :not_set_up} = Vault.unlock("anything")
  end

  test "encrypt/decrypt round-trip once unlocked" do
    :ok = Vault.setup("my passphrase")

    assert {:ok, ciphertext} = Vault.encrypt("a secret message")
    assert ciphertext != "a secret message"
    assert {:ok, "a secret message"} = Vault.decrypt(ciphertext)
  end

  test "encrypt/decrypt fail while locked" do
    assert {:error, :locked} = Vault.encrypt("secret")
    assert {:error, :locked} = Vault.decrypt("whatever")
  end
end
