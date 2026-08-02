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
                  │  (PII redaction runs │
                  │  here, before every  │
                  │  request, regardless │
                  │  of provider)        │
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
                  │   Encrypted SQLite   │
                  │  (conversations,     │
                  │   memory, one file)  │
                  └─────────────────────┘
```

Every message passes through the redaction stage before it reaches *any* provider — local or cloud. The privacy claim is a mechanism built into the pipeline, not a policy promise from whoever answers the request.

## Storage

Uhuru uses envelope encryption. A per-install data encryption key (DEK) encrypts conversation and memory content. A key-encryption key (KEK), derived from your passphrase via Argon2id, wraps the DEK.

The DEK never changes — only its wrapped copy does. That gives cheap key management for free:

- **Change your passphrase** → re-wrap the DEK. No need to touch existing encrypted content.
- **Move self-hosted ↔ hosted** → export the encrypted SQLite file plus the wrapped DEK. The same passphrase unlocks it anywhere.

Unlocking works like a password manager, not a per-message prompt: enter your passphrase once per session, the decrypted key is held in memory only for that session, and it's never written to disk or logged. New device or session timeout means entering it again.

One honest caveat: this is zero-trust *storage*, not zero-knowledge *processing*. Whichever model answers your message — local or cloud — still needs the plaintext briefly in memory to generate a response.

## Local inference, via Granville

[Granville](../granville) is Uhuru's default provider — a Zig-based inference kernel that runs locally, CPU-first, no GPU required. It also does something more specific: its ranker strips PII (emails, phone numbers, SSNs, names, addresses, card numbers) before text reaches any model, local or remote.

The default experience uses Granville and never leaves your machine. When you want a stronger model, you explicitly trigger an adapter like Together AI — the tradeoff (cost, latency, what a third party briefly sees) is visible and opt-in, not silent.

## Why Elixir/OTP

OTP gives you many lightweight, isolated, supervised processes — real concurrency and fault tolerance without needing Kubernetes or a distributed-systems stack. That runs well on ordinary CPU hardware, which matches the rest of the design: one binary, one SQLite database, LiveView for streaming with minimal JavaScript.

## Self-hosting cost

Self-hosted on your own hardware — a laptop, a home server — is free. Granville runs locally with no metered cost, and nothing ever has to leave the machine.

If you'd rather not run your own box, Fly.io is the recommended hosted path, and Fly's auto-stop makes it genuinely cheap for personal use — you pay for compute only while a request is actually being handled, not for a server sitting idle:

- **App alone (Together as the model, what's deployed today):** a `shared-cpu-1x`/1GB Machine, no persistent volume — the SQLite database restores from Tigris object storage on boot and streams writes back continuously ([Litestream](https://litestream.io)), so there's nothing to provision beyond the app itself. Realistically a couple of dollars a month at low personal usage, and Tigris storage for the backups runs a few cents.
- **With Granville + a local model bundled in (planned, not built yet):** needs a dedicated vCPU for reasonable inference speed, and a small persistent volume so the model file downloads once instead of on every wake — Fly volumes bill for capacity whether attached or not, so that's a small constant cost layered on top of pay-per-use compute. Worked estimate for a Gemma 3 4B–class model at ~20 hours of actual monthly usage: `performance-1x`/8GB compute (~$1.76), a 3GB model-cache volume (~$0.45), Tigris backup storage (~$0.10) — **roughly $2.30/month**.

These are real numbers as researched in mid-2026, not guarantees — provider pricing changes. The point isn't the exact figure, it's that owning your own AI workspace doesn't require a server running 24/7 to be practical.

## MVP scope

**In:** chat, streaming responses, conversation history, local memory, web search, provider adapters (Granville local by default, Together AI opt-in).

**Deliberately out, for now:** plugins, multi-agent orchestration frameworks, multi-tenant hosting and billing. Those are real future directions, not MVP scope.

## Status

Pre-alpha. This is a self-hosted-first experiment — there's no runnable build yet, so there's no Quick Start section here until there is one.

## License

MIT
