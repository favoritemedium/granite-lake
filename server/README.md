# Granite Lake API

TypeScript/Fastify API for Granite Lake domain-scoped OTP verification. Each running Docker stack is for one configured domain and one domain admin wallet. OTP sessions and users are stored in Postgres; user add/enable/disable operations are submitted to Sui and later used by the app for photo and file attestation.

## Deployment Model

One container stack equals one domain.

- `CLIENT_ID` is the Docker/Postgres naming slug. Use the domain label without `.com` or dots, for example `CLIENT_ID=acme`.
- `DOMAIN` is the actual email/on-chain domain, for example `DOMAIN=acme.com`.
- `ADMIN_WALLET` is the public wallet address for the domain admin.
- `SUI_PRIVATE_KEY` must belong to `ADMIN_WALLET`. It can be a literal key or a Vault reference.

Compose names are derived from:

```txt
<NODE_ENV>_<CLIENT_ID>_granite_lake
```

## Before Starting

Register the domain and admin wallet on-chain before starting the API stack. The Move contract requires the domain to exist in the shared registry, and `add_user`, `enable_user`, and `disable_user` must be signed by that domain's admin wallet.

Make sure these values all refer to the same on-chain domain setup:

- `DOMAIN` is the domain already added to the Sui registry.
- `ADMIN_WALLET` is the admin wallet recorded for that domain.
- `SUI_PRIVATE_KEY` is the private key for `ADMIN_WALLET`, either as a literal value or a Vault reference.
- `SUI_PACKAGE_ID` and `SUI_REGISTRY_ID` point to the deployed Granite Lake package and registry that contain the domain.

If the domain was not added first, OTP verification will fail when the server submits `add_user`.

## Environment

Required for runtime:

```env
NODE_ENV=development
CLIENT_ID=acme
DOMAIN=acme.com
ADMIN_WALLET=0x...
ADMIN_API_KEY=<admin-api-key>
APP_API_KEY=<app-api-key>
GOOGLE_CHAT_WEBHOOK_URL=<google-chat-webhook-url>
SUI_RPC_URL=https://fullnode.testnet.sui.io:443
SUI_PRIVATE_KEY=<domain-admin-suiprivkey-or-vault-ref>
SUI_PACKAGE_ID=0x...
SUI_REGISTRY_ID=0x...
```

Optional:

```env
PORT=8080
HOST=0.0.0.0
OTP_TTL_MS=300000
SUI_NETWORK=testnet
SUI_MODULE=photo_attestation
SUI_GAS_BUDGET=10000000
VAULT_ENABLED=false
VAULT_ADDR=
VAULT_TOKEN=
VAULT_NAMESPACE=
VAULT_AUTH_METHOD=token
VAULT_ROLE_ID=
VAULT_SECRET_ID=
VAULT_KV_MOUNT=secret
VAULT_SECRET_PREFIX=
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_HOST_PORT=5432
API_HOST_PORT=8080
VAULT_HOST_PORT=8200
```

`SUI_MODULE` is only the Move module name. Even though the source declares `module granite_lake::photo_attestation`, the transaction target is built as `<SUI_PACKAGE_ID>::<SUI_MODULE>::<function>`, so use `SUI_MODULE=photo_attestation`, not `granite_lake::photo_attestation`.

Postgres connection settings are optional at runtime: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, and `POSTGRES_PORT` default to `postgres`/`postgres`/`db`/`5432`, and `POSTGRES_DB` — also optional — defaults to `<NODE_ENV>_<CLIENT_ID>_granite_lake` (with `CLIENT_ID` lowercased and non-alphanumeric characters replaced by `_`), the same name compose derives for the stack. `DATABASE_URL` is always derived from these values, never set directly. The `*_HOST_PORT` variables are read only by compose, never by the API: `POSTGRES_HOST_PORT` and `API_HOST_PORT` (and `VAULT_HOST_PORT` in the local Vault override) choose which host ports the db, api, and vault services publish on `127.0.0.1`.

### OTP Delivery

OTP codes are currently posted to a Google Chat incoming webhook using `GOOGLE_CHAT_WEBHOOK_URL`. This is a temporary delivery path until the paid email service is available. The API still requires `user_email` so it can validate the user belongs to the configured domain and record the verified user identity.

## App Authentication

`APP_API_KEY` gates `/otp/request`, `/otp/verify`, `/otp/:userId`, `PATCH /otp/:userId/deactivate`, and `/utc` via an `x-app-api-key` header. It is separate from `ADMIN_API_KEY`, which protects the operator-only `/admin/*` routes. `/health` stays public and requires no credential, so deployment/uptime checks keep working.

Requests missing the header, or sending the wrong value, get a `401`:

```json
{ "error": "unauthorized", "message": "Invalid app API key." }
```

This is a Phase 1, dev/staging-appropriate control: it stops opportunistic and scripted abuse, but a static key embedded in the mobile app is extractable from a decompiled build or by proxying the app's own traffic, so it does not prove a request came from an unmodified, legitimate copy of the app. Each per-domain stack should get its own distinct `APP_API_KEY`, matching the corresponding entry in the app's build-time domain configuration. See `granite-lake-app-auth-design.md` at the repo root for the full design, including the Phase 2 (device attestation + short-lived session tokens) follow-up and why it requires Play Store distribution to provide its full guarantee.

## HashiCorp Vault Secrets

The API supports HashiCorp Vault KV v2 for `SUI_PRIVATE_KEY`. This is the only secret currently resolved from Vault in Granite Lake.

Vault is optional. When `VAULT_ENABLED=false`, leave the Vault settings blank and set `SUI_PRIVATE_KEY` to the literal domain-admin Sui private key in `.env`:

```env
VAULT_ENABLED=false
VAULT_ADDR=
SUI_PRIVATE_KEY=<domain-admin-suiprivkey>
```

In this mode the API never contacts Vault. Empty Vault settings such as `VAULT_ADDR=`, `VAULT_TOKEN=`, `VAULT_ROLE_ID=`, `VAULT_SECRET_ID=`, and `VAULT_SECRET_PREFIX=` are treated as unset.

Use a fixed static path per client container:

```txt
secret/<NODE_ENV>/<CLIENT_ID>/static#SUI_PRIVATE_KEY
```

For example:

```env
VAULT_ENABLED=true
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=dev-root-token
VAULT_AUTH_METHOD=token
VAULT_KV_MOUNT=secret
SUI_PRIVATE_KEY=vault://secret/development/domain_demo/static#SUI_PRIVATE_KEY
```

`VAULT_SECRET_PREFIX` defaults to `<NODE_ENV>/<CLIENT_ID>`. Override it only when a deployment needs a different prefix, for example `VAULT_SECRET_PREFIX=production/acme`.

For production, use an external Vault or HCP Vault and prefer AppRole:

```env
VAULT_ENABLED=true
VAULT_ADDR=https://vault.example.com:8200
VAULT_AUTH_METHOD=approle
VAULT_ROLE_ID=<vault-approle-role-id>
VAULT_SECRET_ID=<vault-approle-secret-id>
VAULT_KV_MOUNT=secret
SUI_PRIVATE_KEY=vault://secret/production/acme/static#SUI_PRIVATE_KEY
```

Each per-client container should receive a Vault token/AppRole policy that can read only its own static path. Do not run Vault dev mode in production.

## Local Development

```bash
npm install
cp .env.example .env
docker compose --env-file .env up --build -d
```

`.env.example` ships `SUI_PRIVATE_KEY=` empty while the compose file requires that variable to be non-empty, so `docker compose up` fails with `SUI_PRIVATE_KEY must be set` until you fill it in — with a literal key or a `vault://` reference. Set `GOOGLE_CHAT_WEBHOOK_URL` too: without it every `POST /otp/request` fails with `500 internal_error`, because the OTP has nowhere to be delivered.

To run local Vault dev mode, enable Vault in `.env`:

```env
VAULT_ENABLED=true
VAULT_ADDR=http://vault:8200
VAULT_TOKEN=dev-root-token
SUI_PRIVATE_KEY=vault://secret/development/domain_demo/static#SUI_PRIVATE_KEY
```

Then start the local override and seed the private key:

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env up --build -d
npm run vault:local:write
```

The helper writes only `SUI_PRIVATE_KEY` to `secret/<NODE_ENV>/<CLIENT_ID>/static` and does not print the secret value. You can also seed directly with the Vault CLI:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token
vault kv put secret/development/domain_demo/static SUI_PRIVATE_KEY='<domain-admin-suiprivkey>'
```

The app always derives `DATABASE_URL` from `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, and `POSTGRES_DB`. If running the API directly on your machine, set `POSTGRES_HOST=localhost`.

Run checks:

```bash
npm run build
npm test
docker compose --env-file .env config
docker compose -f docker-compose.yml -f docker-compose.local.yml --env-file .env config
```

Validate compose against the filled-in `.env`, not `.env.example`: the example file ships `SUI_PRIVATE_KEY=` empty while the compose file requires a non-empty value, so `--env-file .env.example` fails during interpolation with `SUI_PRIVATE_KEY must be set`. `docker compose config` only resolves and prints the configuration; it starts nothing.

For running the API outside Docker: `npm run dev` starts it with tsx in watch mode, and `npm run db:migrate` applies the migrations — it runs the compiled `dist/src/db/migrate.js`, so `npm run build` must come first. Node 22 or newer is required (`engines` in `package.json`). Inside the compose stack these steps are automatic: the `migrate` service runs the migrations and the api service starts only after it completes successfully.

## Authentication

Admin routes require:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Only `GET /health` is public. Every `/otp/*` route, including `PATCH /otp/:userId/deactivate`, and `GET /utc` require the `x-app-api-key` header — see [App Authentication](#app-authentication).

## API Reference

### `GET /health`

Checks API and database connectivity.

Response:

```json
{
  "ok": true,
  "service": "granite-lake-api",
  "database": "up"
}
```

When Postgres is unreachable, `/health` returns `503` instead:

```json
{
  "ok": false,
  "service": "granite-lake-api",
  "database": "down"
}
```

### `GET /utc`

Returns server UTC time. Requires the `x-app-api-key` header — see [App Authentication](#app-authentication).

Response:

```json
{
  "utc": "2026-06-05T05:30:00.000Z"
}
```

### `POST /otp/request`

Creates an OTP session and posts the OTP details to the configured Google Chat webhook. This replaces email delivery for now, until the paid email service is enabled.

Rules:

- `domain` must match env `DOMAIN`.
- `user_email` must be a valid email.
- `user_email` domain must match env `DOMAIN`.
- `user_email` must not already exist in the `users` table, **including disabled users** — see [Account Deletion and Re-registration](#account-deletion-and-re-registration).
- A `user_email` can have only one pending session at a time. Pending sessions past their `expires_at` are flipped to `expired` before the insert, so re-requesting after the OTP expired works; while an unexpired pending session exists, a new request fails. That rejection currently has no dedicated mapping and surfaces as the generic `500 internal_error` — see [Error Handling](#error-handling).
- The OTP is not returned by the API.

Request:

```json
{
  "domain": "acme.com",
  "user_email": "alice@acme.com"
}
```

Success `201`:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "expiresAt": "2026-06-05T05:35:00.000Z",
  "domain": "acme.com",
  "userEmail": "alice@acme.com",
  "walletNonce": "KUB3CptWJYZe/qJBEX9G+sbToEPICRM9eGjZDfTL0GQ="
}
```

`walletNonce` is a one-time, server-issued nonce: the client base64-decodes it, signs the raw bytes as a Sui personal message with the private key of the wallet it will claim at `POST /otp/verify`, and submits that signature as `userWalletSignature` there.

Possible errors:

```json
{
  "error": "invalid_email_domain",
  "message": "user_email must belong to acme.com."
}
```

```json
{
  "error": "user_email_exists",
  "message": "User email alice@acme.com is already registered."
}
```

### `GET /otp/:userId`

Returns OTP session status for debugging/status polling.

Response:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "domain": "acme.com",
  "userEmail": "alice@acme.com",
  "userWallet": null,
  "adminWallet": "0x...",
  "txDigest": null,
  "userCapId": null,
  "status": "pending_verification",
  "createdAt": "2026-06-05T05:30:00.000Z",
  "expiresAt": "2026-06-05T05:35:00.000Z",
  "verifiedAt": null,
  "error": null
}
```

When no session exists for `userId`, the response is `404`:

```json
{
  "error": "not_found",
  "message": "No OTP session found."
}
```

### `POST /otp/verify`

Verifies the OTP and submits on-chain `add_user`.

Rules:

- All of `userId`, `otp`, `domain`, `userWallet`, and `userWalletSignature` are required; a body missing any of them returns `400 invalid_request`.
- OTP session must exist.
- OTP must not be expired.
- OTP must match.
- `domain` must match env `DOMAIN`.
- `userWallet` must be a Sui address.
- `userWalletSignature` must be a Sui personal-message signature over the raw bytes of the session's `walletNonce` (base64-decode the value returned by `POST /otp/request`), made with the private key of `userWallet`. The server verifies it against `userWallet` before minting — a mismatch, or a legacy session with no nonce, fails verification.
- Sui `add_user` must succeed before the user is stored as active.

Request:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "otp": "123456",
  "domain": "acme.com",
  "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "userWalletSignature": "AM2YBbQrxU+ri6RtDKIQfueMic8dPUAyO5rpEDCWOeMcPivcretYH0bIB3/qxEx9g0h9a712/ODkWUpVOTFGfEPvgls7FLda0y1O+sQI/U1fmm7RIgBl7ItJVG0ji3oCwg=="
}
```

Success:

```json
{
  "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
  "domain": "acme.com",
  "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "txDigest": "9k...",
  "userCapId": "0x...",
  "status": "completed",
  "verifiedAt": "2026-06-05T05:31:00.000Z"
}
```

Errors:

`409` — the session was already completed:

```json
{
  "error": "otp_already_used",
  "message": "OTP already used."
}
```

`400` `otp_verification_failed` — wrong or expired OTP, `userWallet` not a Sui address, `domain` not matching this container, or a signature that does not verify against `userWallet`. The message names the specific cause:

```json
{
  "error": "otp_verification_failed",
  "message": "userWallet does not match the OTP session."
}
```

`404` — no session for `userId`:

```json
{
  "error": "not_found",
  "message": "No OTP session for 3cb8c8a1-69da-4efe-8a78-4d51cfc2df48."
}
```

`502` `vault_unavailable` — Vault could not be reached while resolving `SUI_PRIVATE_KEY`:

```json
{
  "error": "vault_unavailable",
  "message": "Vault is unavailable at http://vault:8200. Check VAULT_ADDR and ensure the Vault service is running."
}
```

`502` `sui_rpc_failed` — Sui RPC answered with an HTTP error:

```json
{
  "error": "sui_rpc_failed",
  "message": "Sui RPC request failed (503 Service Unavailable). Check SUI_RPC_URL and SUI_NETWORK configuration."
}
```

Any other failure — including an email that already has a `users` row by the time verification runs — has no dedicated mapping here and surfaces as `500 internal_error`; see [Error Handling](#error-handling).

### `PATCH /otp/:userId/deactivate`

Self-service deactivation: submits on-chain `disable_user`, then marks the user as disabled in Postgres. Called by the app when a user deletes their local account, so the server and chain stop listing them as active. Gated by `x-app-api-key`, the same as every other `/otp/*` route — not `x-admin-api-key`. See [App Authentication](#app-authentication) for what that credential does and does not prove.

Headers:

```http
x-app-api-key: <APP_API_KEY>
```

Success:

```json
{
  "message": "User disabled successfully.",
  "user": {
    "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
    "domain": "acme.com",
    "userEmail": "alice@acme.com",
    "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "adminWallet": "0x...",
    "status": "disabled",
    "userCapId": "0x...",
    "addUserTxDigest": "9k...",
    "disableUserTxDigest": "8s...",
    "enableUserTxDigest": null,
    "createdAt": "2026-06-05T05:31:00.000Z",
    "updatedAt": "2026-06-05T06:12:00.000Z",
    "lastVerifiedAt": "2026-06-05T05:31:00.000Z",
    "disabledAt": "2026-06-05T06:12:00.000Z"
  }
}
```

`user` is the full user record, the same shape `GET /admin/users` returns. When `userId` has no `users` row, the response is `404`:

```json
{
  "error": "not_found",
  "message": "No user found."
}
```

### `GET /admin/users`

Lists users for this domain container.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Response:

```json
{
  "users": [
    {
      "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
      "domain": "acme.com",
      "userEmail": "alice@acme.com",
      "userWallet": "0x...",
      "adminWallet": "0x...",
      "status": "active",
      "userCapId": "0x...",
      "addUserTxDigest": "9k...",
      "disableUserTxDigest": null,
      "enableUserTxDigest": null,
      "createdAt": "2026-06-05T05:31:00.000Z",
      "updatedAt": "2026-06-05T05:31:00.000Z",
      "lastVerifiedAt": "2026-06-05T05:31:00.000Z",
      "disabledAt": null
    }
  ]
}
```

### `GET /admin/orphaned-sessions`

Lists completed `otp_sessions` rows that have no matching `users` row — sessions that minted an on-chain `UserCap` via `add_user` but whose `users` insert never landed, most commonly when two sessions for the same email completed concurrently and one lost the race. The minted `UserCap`s are live on chain yet unreachable through `GET /admin/users`, which reads only the `users` table; use this endpoint to find them for manual follow-up.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Response (ordered by `verifiedAt`, newest first):

```json
{
  "orphanedSessions": [
    {
      "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
      "userEmail": "alice@acme.com",
      "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "verifiedAt": "2026-06-05T05:31:00.000Z",
      "txDigest": "9k...",
      "userCapId": "0x..."
    }
  ]
}
```

### `PATCH /admin/users/:userId/disable`

Submits on-chain `disable_user`, then marks the user as disabled in Postgres.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Success:

```json
{
  "message": "User disabled successfully.",
  "user": {
    "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
    "domain": "acme.com",
    "userEmail": "alice@acme.com",
    "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "adminWallet": "0x...",
    "status": "disabled",
    "userCapId": "0x...",
    "addUserTxDigest": "9k...",
    "disableUserTxDigest": "8s...",
    "enableUserTxDigest": null,
    "createdAt": "2026-06-05T05:31:00.000Z",
    "updatedAt": "2026-06-05T06:12:00.000Z",
    "lastVerifiedAt": "2026-06-05T05:31:00.000Z",
    "disabledAt": "2026-06-05T06:12:00.000Z"
  }
}
```

`user` is the full user record, the same shape `GET /admin/users` returns. When `userId` has no `users` row, the response is `404`:

```json
{
  "error": "not_found",
  "message": "No user found."
}
```

### `PATCH /admin/users/:userId/enable`

Submits on-chain `enable_user`, then marks the user as active in Postgres.

Headers:

```http
x-admin-api-key: <ADMIN_API_KEY>
```

Success:

```json
{
  "message": "User enabled successfully.",
  "user": {
    "userId": "3cb8c8a1-69da-4efe-8a78-4d51cfc2df48",
    "domain": "acme.com",
    "userEmail": "alice@acme.com",
    "userWallet": "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "adminWallet": "0x...",
    "status": "active",
    "userCapId": "0x...",
    "addUserTxDigest": "9k...",
    "disableUserTxDigest": "8s...",
    "enableUserTxDigest": "7q...",
    "createdAt": "2026-06-05T05:31:00.000Z",
    "updatedAt": "2026-06-05T07:05:00.000Z",
    "lastVerifiedAt": "2026-06-05T05:31:00.000Z",
    "disabledAt": null
  }
}
```

`user` is the full user record, the same shape `GET /admin/users` returns. When `userId` has no `users` row, the response is `404`:

```json
{
  "error": "not_found",
  "message": "No user found."
}
```

## Data Model

`otp_sessions` stores pending/completed OTP flows:

- `user_id`
- `user_email`
- `user_wallet`
- `otp_hash`
- `wallet_nonce`
- `status`
- `created_at`
- `expires_at`
- `verified_at`
- `tx_digest`
- `user_cap_id`
- `error`

`wallet_nonce` is the server-issued nonce the wallet must sign at `POST /otp/verify` (migration `006_add_otp_wallet_nonce.sql`); it is null only for sessions created before the column existed. A partial unique index, `otp_sessions_pending_email_unique` (migration `005_unique_pending_otp_session_per_email.sql`), enforces at most one `pending_verification` session per `user_email`.

`users` stores verified users:

- `user_id`
- `user_email`
- `user_wallet`
- `status`
- `user_cap_id`
- `add_user_tx_digest`
- `disable_user_tx_digest`
- `enable_user_tx_digest`
- timestamps

The database does not store `domain` or `admin_wallet`; those come from env because each stack is domain-scoped.

## Flow

1. User requests an OTP with `domain` and `user_email`.
2. Server validates the email domain and checks the email is not already registered.
3. Server stores an OTP session (issuing a `walletNonce`) and posts the OTP to Google Chat.
4. User submits `userId`, `otp`, `domain`, `userWallet`, and `userWalletSignature` — a Sui personal-message signature over the session's `walletNonce`, proving control of `userWallet`'s private key.
5. Server verifies the OTP and the wallet signature, then submits Sui `add_user`.
6. Server stores the user as `active`.
7. Admin can call disable/enable endpoints, which also submit Sui transactions.

The Sui domain-admin calls (`add_user`, `disable_user`, `enable_user`) are attempted up to three times with exponential backoff starting at 300 ms when they fail with transient network errors. When a submission still fails, the server logs the admin wallet's SUI balances (total, coin-object, and address balance) so gas problems are diagnosable.

## Account Deletion and Re-registration

Deleting a user's local app data (or an admin disabling them via `PATCH /admin/users/:userId/disable`) sets their `users` row to `status = 'disabled'`. It does not delete the row, and it does not free their `user_email` for a new registration — `POST /otp/request` rejects an email that already has a `users` row, active or disabled, with a `409 user_email_exists`. `POST /otp/verify` enforces the same rule — the session is marked `expired` and the request fails — but that error is currently not mapped to a dedicated response, so it surfaces as the generic `500 internal_error` from the global error handler rather than `user_email_exists`.

This is intentional, not an oversight. The only thing standing between "anyone who can receive an OTP at this email" and "a working on-chain identity for this domain" is possession of the inbox. That is an acceptable bar for _creating_ an identity, because it is bounded: it can only mint one capability per email, once. It is not an acceptable bar for _restoring one that was disabled_, because disabling is meant to be a deliberate act — the account holder choosing to delete their own device, or a domain admin responding to something (offboarding, a lost or compromised device, a policy violation). Letting the same low-friction, self-service OTP flow silently reverse that decision — no admin involved, no record of why the original disable happened — would mean disabling a user never actually revokes anything durably: anyone who still receives that address's mail could immediately reopen the identity on a new device. That collapses `disable` from an admin-controlled trust boundary into a formality.

Concretely, this closes off a scenario worth naming: an attacker who gains transient access to a target's email inbox cannot use the disable/re-register pattern to permanently seize that person's identity slot for their own wallet outside the domain admin's view, even briefly. They can request and verify an OTP once (creating a new identity, if the email is not already registered) or self-deactivate an account they already control the device for (see `PATCH /otp/:userId/deactivate`), but they cannot make a previously-registered, since-disabled email start working with a wallet of their choosing.

The tradeoff is operational: there is currently no self-service or admin path to free up a disabled email for re-registration. A person who deletes their own account is locked out of that email permanently unless an operator intervenes directly in Postgres.

**Planned follow-up:** re-registration will go through the domain admin, not self-service. An admin who confirms the request is legitimate reassigns the email to the new wallet manually; the app gets a dedicated re-registration onboarding flow, separate from first-time signup, that this admin-mediated path drives. Neither exists yet.

## Error Handling

Each route maps its expected failures to the explicit responses documented above. Anything else — an unmapped application error, a bug, a framework-level failure such as unparseable JSON — reaches a global error handler. It logs the full error server-side together with a generated `correlationId` and returns, without leaking internal detail (raw error messages, stack traces, framework error codes):

```json
{
  "error": "internal_error",
  "message": "An unexpected error occurred.",
  "correlationId": "5b9a1f2e-8c3d-4e6a-9f0b-1d2e3f4a5b6c"
}
```

Errors already assigned a 4xx status by the framework (for example a malformed request body) return the same shape with `"error": "bad_request"` and `"message": "The request could not be processed."` The `correlationId` in the response matches the server log entry for that request.

## Security

### Rate Limiting

The API implements rate limiting to prevent brute-force attacks:

| Endpoint       | Limit        | Window     | Key        |
| -------------- | ------------ | ---------- | ---------- |
| `/otp/request` | 5 requests   | 1 minute   | IP address |
| `/otp/verify`  | 10 attempts  | 15 minutes | userId     |
| All routes     | 100 requests | 1 minute   | IP address |

The last row is a global limiter (`@fastify/rate-limit`) applied to every route, including `/health`, `/utc`, and `/admin/*`. It throws when tripped, so its `429` response goes through the global error handler (see [Error Handling](#error-handling)) and uses the generic `bad_request` shape rather than the `rate_limit_exceeded` shape below.

When rate limited by the per-endpoint OTP limiters, the API returns:

- HTTP `429 Too Many Requests`
- `Retry-After` header with seconds until reset
- Error response — for `/otp/request`:

```json
{
  "error": "rate_limit_exceeded",
  "message": "Too many OTP requests. Limit: 5 per minute. Try again in 45 seconds."
}
```

For `/otp/verify`:

```json
{
  "error": "rate_limit_exceeded",
  "message": "Too many OTP verification attempts. Limit: 10 per 15 minutes. Try again in 45 seconds."
}
```

### TLS/SSL

For production deployments, always use TLS (HTTPS) to encrypt traffic between the app and server. The API itself does not handle TLS; terminate TLS at a reverse proxy or load balancer (e.g., nginx, Cloudflare).

### Admin API Key

Admin endpoints require the `x-admin-api-key` header. Keep this key secret and do not expose it in client-side code.
