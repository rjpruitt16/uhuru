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

## MVP scope

**In:** chat, streaming responses, conversation history, local memory, web search, provider adapters (Granville local by default, Together AI opt-in).

**Deliberately out, for now:** plugins, multi-agent orchestration frameworks, multi-tenant hosting and billing. Those are real future directions, not MVP scope.

## Status

Pre-alpha. This is a self-hosted-first experiment — there's no runnable build yet, so there's no Quick Start section here until there is one.

## License

MIT
