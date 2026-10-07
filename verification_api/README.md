# Granite Lake Verification API

HTTP API that verifies an uploaded photo or file against Granite Lake on-chain attestations.

## What it does

On `POST /verify-attestation` with a multipart file upload and required `attest_type`, the API performs the same verification flow as the web portal:

- Computes SHA-256 of the uploaded file.
- Scans Sui `PhotoAttested` events for a matching `photo_hash` when `attest_type=attest_photo`.
- Scans Sui `FileAttested` events for a matching `file_hash` when `attest_type=attest_file`.
- Scans each event type under both the current and original package ids, so attestations made before a package upgrade are still found.
- Reads the domain directly from the attestation event's `domain` field; the attester's `UserCap` is fetched only to report its object id.
- Resolves the domain admin wallet from the live Registry object's `domains` table, so key rotations are always reflected.
- Resolves user status at attestation time from `UserEnabled` and `UserDisabled` event history, falling back to the live Registry user flag when no status event predates the attestation.
- Runs DNS TXT consensus lookup (`_attest.<domain>`) against 3 providers.
- Parses the TXT records for `chain_id`, `attester`, and `revoked`, groups them per Sui network, and selects the record for this deployment's network (derived from the RPC URL); same-network duplicates or cross-provider disagreement fail verification.
- Compares DNS `attester` wallet against on-chain domain admin wallet.

`hasMatch` is trust-gated: it is `true` only when the hash matched on-chain, exactly one distinct wallet attested it, and every trust check passed — DNS TXT responses agreed across all providers, no DNS provider errored, the DNS `attester` wallet matches the on-chain domain admin wallet, and the DNS record is not revoked. When more than one distinct wallet has attested the same hash, the response sets `collision: true` and `hasMatch: false`, and returns every candidate in `attestations` instead of picking one.

The response is intentionally detailed and includes scan metadata, attestation metadata, DNS evidence, warnings, and total duration.

## Endpoints

- `GET /health`
- `POST /verify-attestation`
- `GET /wallet-attestations/:wallet`

Invalid input is rejected with a 400: `POST /verify-attestation` requires a non-empty multipart `file` and an `attest_type` of `attest_photo` or `attest_file`; `GET /wallet-attestations/:wallet` requires a hex wallet address, and its `attest_type` query parameter accepts only `photo`, `attest_photo`, `file`, or `attest_file` (omit it to return both).

## Limits

- Rate limiting: 100 requests per 1-minute window, keyed per IP, across all endpoints.
- Uploads: one file per request, 25 MB max per file.
- Event scanning: pagination capped at 200 pages per request.
- Timeouts: Sui GraphQL requests fail after 10 seconds; DNS-over-HTTPS lookups fail after 5 seconds.

## Environment

Copy `.env.example` to `.env` and adjust values as needed.

Main settings:

- `PORT` default `8081`
- `HOST` default `0.0.0.0`
- `SUI_RPC_URL` — Sui GraphQL endpoint used for all chain reads. Defaults to `https://graphql.testnet.sui.io/graphql`; legacy JSON-RPC URLs (`fullnode.testnet.sui.io`, `fullnode.mainnet.sui.io`, `fullnode.devnet.sui.io`, `rpc.ankr.com`) are silently rewritten to the matching `graphql.*.sui.io/graphql` endpoint.
- `GRANITE_LAKE_PACKAGE_ID` — id of the current package.
- `GRANITE_LAKE_ORIGINAL_PACKAGE_ID` — id of the pre-upgrade package; defaults to `GRANITE_LAKE_PACKAGE_ID` and only needs to be set once the current package has itself been upgraded. Every event type is scanned under both package ids.
- `GRANITE_LAKE_REGISTRY_ID` — id of the Registry object used for domain-admin and user-status lookups.

## Local run

Requires Node.js >= 22.

```bash
npm install
npm run dev
```

Build:

```bash
npm run build
```

Run the built server (the same command the Dockerfile runs as `CMD`):

```bash
npm start
```

## Docker

Build image:

```bash
docker build -t granite-lake-verification-api .
```

Run container:

```bash
docker run --rm -p 8081:8081 --env-file .env granite-lake-verification-api
```

## Request example

```bash
curl -X POST "http://localhost:8081/verify-attestation" \
  -F "attest_type=attest_photo" \
  -F "file=@/absolute/path/to/capture1.jpg"
```

```bash
curl -X POST "http://localhost:8081/verify-attestation" \
  -F "attest_type=attest_file" \
  -F "file=@/absolute/path/to/document.pdf"
```

## Wallet attestations

`GET /wallet-attestations/:wallet` returns every attestation event whose `user_wallet` field matches the given wallet, including both photo and file attestations, bounded by the 200-page scan ceiling.

Query parameters:

- `attest_type=photo` or `attest_type=attest_photo` to filter photo attestations
- `attest_type=file` or `attest_type=attest_file` to filter file attestations
- omit `attest_type` to return both

Example:

```bash
curl "http://localhost:8081/wallet-attestations/0x48da47049ce3ca6ffea81a74c74f20592ad6accc9a19f3ae3c1c7b57e986422c"
```

```bash
curl "http://localhost:8081/wallet-attestations/0x48da47049ce3ca6ffea81a74c74f20592ad6accc9a19f3ae3c1c7b57e986422c?attest_type=file"
```

Response fields include:

- `wallet`
- `attestTypeFilter`
- `pagesScanned`
- `eventsScanned`
- `photoCount`
- `fileCount`
- `events`
- `durationMs`

## Response shape summary

Top-level response includes:

- `hasMatch` (`true` only when the hash matched on-chain, exactly one wallet attested it, and every trust check passed)
- `collision` (`true` when more than one distinct wallet attested this hash; `hasMatch` is then `false`)
- `summary`
- `request` (attestation type, file metadata, and computed hash)
- `config` (effective package/rpc settings)
- `scan` (pages/events scanned and the event types scanned)
- `attestations` (array of full public attestation records: empty when nothing matched, all candidates on a collision; each record includes `userWallet`, `domain`, `domainAdminWallet`, `userCapObjectId`, and `userEnabledAtAttestation` as `{ value, latestEnabledTimestampMs, latestDisabledTimestampMs }`)
- `dnsVerification` (provider-by-provider evidence and wallet match checks; `null` when DNS verification was not attempted — no match, a collision, or a matched attestation with no domain)
  - `record`: the TXT record selected for this deployment's network, including the parsed `chainId`, `attester`, and `revoked` fields
  - `dnssecValidated`: `true` only when Cloudflare and Google both report the `AD` (Authenticated Data) flag on the `_attest.<domain>` TXT lookup; AliDNS is excluded from this check since its public resolver never sets `AD`, even for correctly signed zones. `null` when the DNS lookup was attempted but failed.
  - `providerResults[].ad`: raw per-provider `AD` flag (`true`/`false`/`null` on error)
- `warnings`
- `durationMs`
