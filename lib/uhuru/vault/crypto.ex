defmodule Uhuru.Vault.Crypto do
  @moduledoc """
  Low-level primitives: Argon2id for passphrase -> key derivation, and
  AES-256-GCM for authenticated encryption. Raw key material never
  touches disk — only Argon2 salts (not secret) and AEAD ciphertext.
  """

  @key_length 32
  @iv_length 12
  @tag_length 16
  @aad "uhuru.vault.v1"

  @spec gen_salt() :: binary()
  def gen_salt, do: Argon2.Base.gen_salt()

  @spec derive_key(String.t(), binary()) :: binary()
  def derive_key(passphrase, salt) do
    passphrase
    |> Argon2.Base.hash_password(salt, format: :raw_hash, hashlen: @key_length)
    |> Base.decode16!(case: :lower)
  end

  @spec encrypt(binary(), binary()) :: binary()
  def encrypt(key, plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_length)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  @spec decrypt(binary(), binary()) :: {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(key, <<iv::binary-size(@iv_length), tag::binary-size(@tag_length), ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      :error -> {:error, :decryption_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def decrypt(_key, _invalid), do: {:error, :decryption_failed}
end
