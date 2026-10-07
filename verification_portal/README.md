# Granite Lake Verification Portal

Public verification portal for Granite Lake, modeled after Granite Ridge's hash-first verification flow.

## What it does

- Requires selecting whether the upload is a field photo or an uploaded file
- Computes SHA-256 locally in the browser
- Queries Sui `PhotoAttested` or `FileAttested` events via Sui GraphQL (default `https://graphql.testnet.sui.io/graphql`); `suix_queryEvents` survives only as an internal label that is translated into a GraphQL `events(first, after, filter: { module })` query filtered on the `photo_attestation` module, with the event-type suffix matched client-side
- Scans all pages of results, never stopping at the first match, so every matching event is collected
- Detects hash collisions: when multiple distinct wallets attest the same `photo_hash` or `file_hash`, every matching record is returned with `collision: true` instead of being attributed to a single attester
- Scans events under both the current and the original package ID, so attestations made before a package upgrade are still found
- Displays public on-chain metadata when matched:
  - GPS (photo matches only)
  - Altitude (photo matches only)
  - File Hash and File ID (file matches only, instead of GPS/Altitude)
  - Project ID
  - Attesting wallet
  - Timestamp (from event envelope `timestampMs`)
  - Domain, from the attestation event's `domain` field
  - Domain Admin Wallet, read from the Registry's `domains` Table via dynamic-field lookups
  - User enabled status at attestation time (latest `UserEnabled` / `UserDisabled` before timestamp; falls back to the live flag from the Registry's `DomainRecord.users` Table when no such event precedes the attestation)
  - Suiscan explorer link for the attesting transaction (`https://suiscan.xyz/testnet/tx/<digest>`)
- Includes a light/dark theme toggle, persisted to localStorage under `granite-lake-portal-theme`

## DNS TXT trust-anchor verification

When a verified match includes a domain, the portal looks up the `_attest.<domain>` TXT record through three DNS-over-HTTPS providers — AliDNS (`223.5.5.5`), Cloudflare (`1.1.1.1`), and Google (`8.8.8.8`) — and requires all three to agree (response status and TXT answer set must match):

- The record must parse into `chain_id` (Sui format, e.g. `sui:testnet`), `attester`, and `revoked`.
- More than one attester record for the same network is rejected as a possible tampering signal; separate records for different networks are allowed.
- The DNS attester wallet is compared against the on-chain Domain Admin Wallet. Revocation, a wallet mismatch, a missing on-chain admin wallet, or a failed lookup downgrades the hash match to "unconfirmed".
- DNSSEC validation is reported from the AD flag (Cloudflare and Google only; AliDNS never sets AD). Lack of validation is surfaced as a reduced-confidence warning rather than a downgrade.
- The result panel shows DNS Consensus ("n / 3 matched"), DNSSEC status, Admin Wallet Match/Mismatch, DNS TXT Attester Wallet, DNS Chain ID, and DNS Revoked.

## Wallet attestations

A second portal mode ("Wallet attestations") lists attestations by wallet: `getWalletAttestationsByWallet({ wallet, onProgress? })` scans every `PhotoAttested` / `FileAttested` event whose transaction sender or `user_wallet` field matches the wallet, returning them sorted newest-first with pages/events-scanned counters, photo/file counts, and a detail card per event.

## Environment

Copy `.env.example` to `.env`. This is effectively required: the built-in defaults for the package ID and registry ID are empty strings, so without a `.env` (or equivalent `VITE_*` environment variables) the portal cannot find any attestations.

Supported variables:

- `VITE_SUI_RPC_URL` — Sui GraphQL endpoint; defaults to `https://graphql.testnet.sui.io/graphql`. JSON-RPC-style URLs (for example `https://rpc.ankr.com/sui/testnet` or `https://fullnode.testnet.sui.io`) are silently rewritten to the matching Sui GraphQL endpoint at runtime.
- `VITE_GRANITE_LAKE_PACKAGE_ID` — current Granite Lake package ID; defaults to an empty string.
- `VITE_GRANITE_LAKE_ORIGINAL_PACKAGE_ID` — original (pre-upgrade) package ID; defaults to `VITE_GRANITE_LAKE_PACKAGE_ID`.
- `VITE_GRANITE_LAKE_REGISTRY_ID` — Registry object ID; defaults to an empty string.

The package and registry IDs in `.env.example` match the testnet constants currently used by the mobile app.

## Run

```bash
npm install
npm run dev
```

Then open the URL printed by Vite.

For a production build and a local preview of it:

```bash
npm run build
npm run preview
```

`npm run build` type-checks `tsconfig.app.json` and `tsconfig.node.json` (via `tsc --noEmit`) before running `vite build`.

## Notes

- Current lookup strategy is event scan (`O(n)` by pages) across both photo and file attestation event types.
- This is suitable for MVP and audit use.
- If event volume grows substantially, move to a Postgres indexer for `photo_hash -> event`.
