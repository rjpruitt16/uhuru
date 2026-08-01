defmodule Uhuru.Vault do
  @moduledoc """
  Holds the unwrapped data-encryption key (DEK) in memory once unlocked —
  never on disk. The DEK is generated once and wrapped with a key derived
  (Argon2id) from the user's passphrase; only the wrapped copy and a
  random salt are ever persisted (see Uhuru.Vault.Keyring), and both are
  useless without the passphrase.

  Scoped to the whole process, not per browser session: this is a
  single-user, self-hosted app with no multi-tenant auth model yet.
  Unlocking from any tab unlocks it for the running server until it's
  explicitly locked again or the process restarts.

  Optionally auto-sets-up/unlocks from the UHURU_PASSPHRASE env var, for
  headless deployments where nobody's there to type it in. Using that
  env var means whoever can read the process environment can decrypt —
  an explicit, documented tradeoff, not the default.
  """

  use GenServer

  alias Uhuru.Repo
  alias Uhuru.Vault.{Crypto, Keyring}

  @name __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec set_up?() :: boolean()
  def set_up?, do: Repo.exists?(Keyring)

  @spec locked?() :: boolean()
  def locked?, do: GenServer.call(@name, :locked?)

  @doc "Create the vault for the first time. Fails if one already exists."
  @spec setup(String.t()) :: :ok | {:error, :already_set_up | Ecto.Changeset.t()}
  def setup(passphrase), do: GenServer.call(@name, {:setup, passphrase})

  @spec unlock(String.t()) :: :ok | {:error, :not_set_up | :invalid_passphrase}
  def unlock(passphrase), do: GenServer.call(@name, {:unlock, passphrase})

  @doc "Clear the in-memory key. Nothing on disk changes."
  @spec lock() :: :ok
  def lock, do: GenServer.call(@name, :lock)

  @spec encrypt(binary()) :: {:ok, binary()} | {:error, :locked}
  def encrypt(plaintext), do: GenServer.call(@name, {:encrypt, plaintext})

  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :locked | :decryption_failed}
  def decrypt(ciphertext), do: GenServer.call(@name, {:decrypt, ciphertext})

  @impl true
  def init(_opts), do: {:ok, %{dek: nil}, {:continue, :maybe_auto_unlock}}

  @impl true
  def handle_continue(:maybe_auto_unlock, state) do
    case System.get_env("UHURU_PASSPHRASE") do
      nil ->
        {:noreply, state}

      passphrase ->
        result = if set_up?(), do: do_unlock(passphrase, state), else: do_setup(passphrase, state)
        {:noreply, elem_or(result, state)}
    end
  end

  @impl true
  def handle_call(:locked?, _from, state), do: {:reply, is_nil(state.dek), state}

  def handle_call(:lock, _from, state), do: {:reply, :ok, %{state | dek: nil}}

  def handle_call({:setup, passphrase}, _from, state) do
    case do_setup(passphrase, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unlock, passphrase}, _from, state) do
    case do_unlock(passphrase, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:encrypt, _plaintext}, _from, %{dek: nil} = state),
    do: {:reply, {:error, :locked}, state}

  def handle_call({:encrypt, plaintext}, _from, state),
    do: {:reply, {:ok, Crypto.encrypt(state.dek, plaintext)}, state}

  def handle_call({:decrypt, _ciphertext}, _from, %{dek: nil} = state),
    do: {:reply, {:error, :locked}, state}

  def handle_call({:decrypt, ciphertext}, _from, state),
    do: {:reply, Crypto.decrypt(state.dek, ciphertext), state}

  defp do_setup(passphrase, state) do
    if set_up?() do
      {:error, :already_set_up}
    else
      dek = :crypto.strong_rand_bytes(32)
      salt = Crypto.gen_salt()
      kek = Crypto.derive_key(passphrase, salt)
      wrapped_dek = Crypto.encrypt(kek, dek)

      %Keyring{}
      |> Keyring.changeset(%{salt: salt, wrapped_dek: wrapped_dek})
      |> Repo.insert()
      |> case do
        {:ok, _} -> {:ok, %{state | dek: dek}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp do_unlock(passphrase, state) do
    case Repo.one(Keyring) do
      nil ->
        {:error, :not_set_up}

      %Keyring{salt: salt, wrapped_dek: wrapped_dek} ->
        kek = Crypto.derive_key(passphrase, salt)

        case Crypto.decrypt(kek, wrapped_dek) do
          {:ok, dek} -> {:ok, %{state | dek: dek}}
          {:error, :decryption_failed} -> {:error, :invalid_passphrase}
        end
    end
  end

  defp elem_or({:ok, new_state}, _fallback), do: new_state
  defp elem_or({:error, _reason}, fallback), do: fallback
end
