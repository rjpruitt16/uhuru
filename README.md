# Uhuru

*Uhuru* is Swahili for "freedom." Uhuru is a privacy-first AI workspace built on open models.

The goal isn't to become another chatbot. It's to give people an AI assistant where they own their conversations, own their memories, and decide where their data lives.

AI should feel like software you own — not a website you're renting.

## Why

Today's AI products require trust. Users send years of conversations to companies they don't control, and those conversations often become part of centralized systems outside the user's ownership. Even when providers publish strong privacy policies, users still depend on a third party to store and manage their information. For developers, researchers, founders, journalists, lawyers, and anyone else who thinks carefully about where their words end up, that's an uncomfortable tradeoff.

## Philosophy

**Open Models** — use open-weight models instead of proprietary black boxes whenever practical.

**User Ownership** — your conversations belong to you. Your memories belong to you. Your database belongs to you.

**Minimal Data Retention** — the system retains only what's necessary to operate. No centralized store of user conversations by default.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix LiveView                          │
│         (chat UI, streaming responses, minimal JS)           │
└───────────────────────────┬───────────────────────────────────┘
                             │
┌───────────────────────────▼───────────────────────────────────┐
│                      Uhuru Core (Elixir/OTP)                 │
│         conversation state · memory · session unlock          │
└───────────────────────────┬───────────────────────────────────┘
                             │
                  ┌──────────┴──────────┐
                  │  Provider Adapter    │
                  │  (routes to a local  │
                  │  or cloud model)     │
                  └──────────┬──────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
      ┌───────────────┐ ┌──────────┐ ┌─────────────┐
      │   Granville    │ │ Together │ │   future    │
      │ (local, CPU,   │ │    AI    │ │  adapters   │
      │   default)     │ │ (opt-in) │ │ (Ollama...) │
      └───────────────┘ └──────────┘ └─────────────┘

                  ┌─────────────────────┐
                  │       SQLite         │
                  │ (message/title text  │
                  │  encrypted per field,│
                  │   one file)          │
                  └─────────────────────┘
```

By default, nothing leaves the machine: Granville runs locally and your plaintext never crosses a network boundary. Redaction is a separate, opt-in toggle — turn it on and Granville runs a second local ranking pass that strips PII (emails, phone numbers, SSNs, names, addresses, card numbers) before the request goes to whichever provider you've picked, local or cloud. It's off by default because that ranking pass roughly doubles latency; it's a tradeoff you make per session, not a hidden gate baked into the pipeline.

## Storage

Uhuru uses envelope encryption. A per-install data encryption key (DEK) encrypts conversation and memory content. A key-encryption key (KEK), derived from your passphrase via Argon2id, wraps the DEK.

The DEK never changes — only its wrapped copy does. That gives cheap key management for free:

- **Change your passphrase** → re-wrap the DEK. No need to touch existing encrypted content.
- **Move self-hosted ↔ hosted** → export the encrypted SQLite file plus the wrapped DEK. The same passphrase unlocks it anywhere.

Unlocking works like a password manager, not a per-message prompt: enter your passphrase once per session, the decrypted key is held in memory only for that session, and it's never written to disk or logged. New device or session timeout means entering it again.

Two honest caveats:

- This is zero-trust *storage*, not zero-knowledge *processing*. Whichever model answers your message — local or cloud — still needs the plaintext briefly in memory to generate a response.
- Encryption is per-field, not whole-database. Message content and thread titles are encrypted; role, provider, model label, timestamps, and the shape of the data (how many threads, how many messages per thread, when they happened) are stored as plaintext in the SQLite file. Anyone with the raw file can't read what you said, but they can see the outline of your usage.

## Local inference, via Granville

[Granville](../granville) is Uhuru's default provider — a Zig-based inference kernel that runs locally, CPU-first, no GPU required.

The default experience uses Granville and never leaves your machine. When you want a stronger model, you explicitly trigger an adapter like Together AI — the tradeoff (cost, latency, what a third party briefly sees) is visible and opt-in, not silent.

## Why Elixir/OTP

OTP gives you many lightweight, isolated, supervised processes — real concurrency and fault tolerance without needing Kubernetes or a distributed-systems stack. That runs well on ordinary CPU hardware, which matches the rest of the design: one binary, one SQLite database, LiveView for streaming with minimal JavaScript.

## Self-hosting cost

Self-hosted on your own hardware — a laptop, a home server — is free. Granville runs locally with no metered cost, and nothing ever has to leave the machine.

If you'd rather not run your own box, Fly.io is the recommended hosted path, and Fly's auto-stop makes it genuinely cheap for personal use — you pay for compute only while a request is actually being handled, not for a server sitting idle:

- **With Granville + a local model bundled in (what's deployed today):** a dedicated `performance-1x`/8GB Machine, plus a small persistent volume so the model file (Gemma 3 4B, ~2.5GB) downloads once instead of on every wake — Fly volumes bill for capacity whether attached or not, so that's a small constant cost layered on top of pay-per-use compute. Worked estimate at ~20 hours of actual monthly usage: compute (~$1.76), the model-cache volume (~$0.45), Tigris backup storage (~$0.10) — **roughly $2.30/month**.
- **App alone, Together as the only model (lean mode — a documented one-line config swap):** a `shared-cpu-1x`/1GB Machine, no persistent volume — the SQLite database restores from Tigris object storage on boot and streams writes back continuously ([Litestream](https://litestream.io)), so there's nothing to provision beyond the app itself. Realistically a couple of dollars a month at low personal usage, and Tigris storage for the backups runs a few cents.

These are real numbers as researched in mid-2026, not guarantees — provider pricing changes. The point isn't the exact figure, it's that owning your own AI workspace doesn't require a server running 24/7 to be practical.

## Status

Pre-alpha, self-hosted-first. A live deployment is running at [uhuru.fly.dev](https://uhuru.fly.dev), but there's no packaged local install yet, so there's no Quick Start section here until there is one.

## License

MIT
