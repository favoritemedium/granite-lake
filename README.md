# Granite Lake

**Granite Lake** is an open-source, mobile-first platform that turns everyday field photos and critical project documents into cryptographically attested records. By hardware-locking user identity via a biometric gate and anchoring a signed hash of each record to the Sui blockchain, Granite Lake provides a permanent, tamper-evident record of who submitted a given photo or document and when — for industries like construction, insurance, and logistics.

## Core Capabilities

- **Hardware-Locked Identity**
  Cryptographic signing keys are secured by the user's physical fingerprint via a biometric gate.

- **Flexible Field Workflows**
  Teams can seamlessly capture field photos or securely upload critical documents (like PDFs and compliance logs).

- **Attested Context**
  Photos are bound with the device's self-reported GPS coordinates, altitude, and timestamp, and all assets (photos and documents) are tagged with project IDs. These values are recorded as submitted by the signing device and are not independently verified.

- **Zero-Trust Verification**
  Every file's cryptographic hash is anchored on-chain, allowing a public web portal to let anyone select a raw file and check whether a matching, trust-anchored attestation exists, or run comprehensive, chronological audits on a user's entire field history directly against the public ledger.

## Repository Structure

Top-level folders and what they contain:

- `app/`: Android-focused Flutter application for local wallet creation, biometric protection, photo capture, file upload, Sui attestation, and verification.
- `server/`: Per-domain backend API (Fastify + Postgres) for OTP registration, domain user management, and Sui writes.
- `contracts/`: Sui Move package for domain registration, user capabilities, enable/disable controls, and event-only photo and file attestation.
- `verification_portal/`: Public verification portal (Vite + React + TypeScript) for querying attested photos or uploaded files from Sui.
- `verification_api/`: HTTP API backend for photo and file verification against on-chain attestations with DNS TXT consensus lookup.

Folder-specific documentation:

- `app/README.md`
- `server/README.md`
- `contracts/README.md`
- `verification_portal/README.md`
- `verification_api/README.md`

## Local Development

Run Granite Lake locally with the API stack and Flutter app.

### 1) Install root tooling

```bash
npm install
```

This installs repository-level tooling such as ESLint, Prettier, and Husky. It does not install dependencies for `server/` or Flutter packages for `app/`; install those in the folders you are developing.

### 2) Start server stack

```bash
cd server
cp .env.example .env
npm install
docker compose --env-file .env up --build -d
```

This starts:

- API at `http://localhost:8080`
- Postgres for OTP sessions and registered users

Before using OTP verification, make sure the configured domain and admin wallet already exist in the deployed Sui registry. The server can read `SUI_PRIVATE_KEY` directly from `.env`, or from HashiCorp Vault when Vault is enabled. See `server/README.md` for the required environment variables, Vault setup, and deployment model.

### 3) Start Flutter app

```bash
cd app
flutter pub get
flutter run --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true
```

The app targets Android. For local development, pass `--dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true` to enable localhost fallback to `http://10.0.2.2:8080` (Android emulator) or `http://127.0.0.1:8080` (localhost).

For convenience, you can create `app/.env.local` (add to `.gitignore`) with:

```
GL_OTP_BACKEND_DEV_FALLBACKS=true
```

### 4) Start verification API (optional)

```bash
cd verification_api
cp .env.example .env
npm install
npm run dev
```

The verification API runs at `http://localhost:8081` and provides a `/verify-attestation` endpoint for photo and file verification.

### 5) Start verification portal (optional)

```bash
cd verification_portal
npm install
npm run dev
```

The verification portal runs at the Vite dev server URL and provides a web UI for public photo or file verification.

### 6) Quick health check

```bash
curl http://localhost:8080/health
curl http://localhost:8081/health  # if verification_api is running
```

## Contributing

This project is open source and contributions are welcome.

### Standard GitHub Flow

1. Open an issue describing the bug, enhancement, or proposal.
2. Create a branch from `main` tied to that issue.
3. Use an issue-based branch name, for example:

```txt
<issue-number>-short-description
```

Examples:

```txt
42-fix-otp-expiry-handling
107-add-photo-verification-indexer
```

4. Make focused commits that reference the issue number.
5. Open a pull request that links the issue and explains what changed, why it changed, and how it was tested.
6. Address review feedback, then merge when approved.

### Code Style And Checks

All root checks run from the repository root.

Run server and app checks:

```bash
npm run check:server
npm run check:app
npm run check:verification_api
npm run check:verification_portal
```

Or run the combined lint and format checks:

```bash
npm run lint
npm run format:check
```

These commands cover server, app, verification_api, and verification_portal.

To auto-format supported files:

```bash
npm run format
```

The Git hooks run these checks automatically:

- `pre-commit`: server/verification_api/verification_portal format/lint checks and Flutter format/analyze checks
- `pre-push`: pre-commit checks plus server build, server tests, contracts Move tests, verification_api build, and verification_portal build

### Server Checks

```bash
npm run build:server
npm run test:server
```

### Flutter App Checks

```bash
npm run lint:app
npm run format:app:check
```

`lint:app` runs `flutter analyze app`. Flutter tests can be added to the root scripts once the app has test files.

### Verification Checks

```bash
npm run lint:verification_api
npm run lint:verification_portal
```

## Domain And Contract Setup

Granite Lake requires the Sui contract registry to know the domain before users can be registered through OTP verification.

At a high level:

1. Publish or use the configured Granite Lake Move package.
2. Register a domain with its admin wallet in the shared registry.
3. Configure the server with matching `DOMAIN`, `ADMIN_WALLET`, `SUI_PRIVATE_KEY`, `SUI_PACKAGE_ID`, and `SUI_REGISTRY_ID`. `SUI_PRIVATE_KEY` can be a literal env value when Vault is disabled, or a `vault://` reference when Vault is enabled.
4. Publish a DNS TXT record at `_attest.<domain>` so `verification_api` and `verification_portal` can each confirm the domain's attester wallet out-of-band from the chain. The record value must be `;`-separated `key=value` pairs including `chain_id`, `attester`, and `revoked`, for example:

   ```text
   chain_id=sui:testnet;attester=0x<admin-wallet-address>;revoked=false
   ```

   `attester` must match the domain's admin wallet registered in step 2, and `chain_id` must match the network the registry entry lives on (e.g. `sui:testnet`, `sui:mainnet`). Set `revoked=true` to invalidate the record without removing it. Both `verification_api` (server-side) and `verification_portal` (client-side, in-browser) look this record up against Cloudflare, Google, and AliDNS for consensus, and additionally report DNSSEC validation when both Cloudflare and Google confirm the `AD` flag on the lookup.

5. Run OTP registration from the app.
6. Capture and attest photos from an enabled wallet.

See:

- `contracts/README.md` for Move package behavior
- `server/README.md` for API configuration and OTP routes
- `app/README.md` for app storage, onboarding, and photo/file attestation flow
- `verification_api/README.md` for the server-side DNS TXT consensus lookup and DNSSEC validation details
- `verification_portal/README.md` for the client-side (in-browser) DNS TXT consensus lookup
- `verification_api/README.md` for DNS TXT consensus lookup and DNSSEC validation details

## License

Granite Lake is licensed under the [Apache License, Version 2.0](LICENSE).
