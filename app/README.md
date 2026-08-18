# granite_lake

Cryptographically attested photo and file records for field operations.

## Overview

Granite Lake is an Android-focused Flutter app for:

- creating a device-local Sui wallet
- protecting that wallet with Android biometrics
- capturing photos with signed local proof data
- uploading files with signed local proof data
- submitting photo and file attestations to a Sui testnet smart contract
- verifying saved captures against the on-chain `PhotoAttested` and `FileAttested` events

The app currently targets Android because the biometric gate is implemented through Flutter plus an Android `MethodChannel` bridge backed by Android Keystore.

## User Flow

The current onboarding and capture flow is:

1. Prepare local app data
2. Create a wallet on-device
3. Link the device to a user account with:
   - company domain
   - employee / user id
   - OTP
4. Protect the wallet with biometrics
5. Start a secure session
6. Choose a capture method: capture a photo or upload a file
7. Save the local signed proof bundle
8. Submit `attest_photo` or `attest_file` to Sui testnet
9. Verify later that on-chain event data matches the local photo or file attestation

Important implementation detail:

- the user does not enter `packageId` or `registryId`
- those are bundled in the app and synced into SQLite automatically at startup

## Current Sui Contract Defaults

Bundled defaults live in:

- `lib/core/constants/app_constants.dart`

Current testnet defaults:

- RPC URL: `https://fullnode.testnet.sui.io:443`
- package id: `0xf4b83a02ad29b78266f8b1a39f5b533bde6bd5ef00eb434db46c3f7be29639db`
- registry id: `0xde8b9f476c91dbdb05238c656a6ea3aa9f670e3b732e3e5d48628f5d2b66122d`
- module: `photo_attestation`
- faucet URL: `https://faucet.sui.io/?network=testnet`
- OTP / UTC backend URL: resolved dynamically at runtime (see Backend URL Configuration below)

Runtime behavior:

- on a fresh install, these defaults are written into SQLite
- on later app launches, if bundled defaults change, the SQLite config row is updated to match
- the app reads contract config from SQLite at runtime

Config sync logic lives in:

- `lib/core/database/controllers/config_data_controller.dart`

## Backend URL Configuration

The app needs to know the backend API URL and app API key to connect for OTP verification and UTC time. Each domain is deployed as its own backend stack (see `server/README.md`), and each app build targets exactly one client's domain, so the app is built with a single `{domain, url, apiKey}` object rather than a map covering several tenants. (An earlier version used a per-domain map so one build could serve multiple tenants; that was replaced because a single leaked build would then expose every tenant's key at once instead of just its own — see `granite-lake-app-auth-design.md`.)

### Build Arguments

| Argument                       | Required         | Description                                                                                                                                |
| ------------------------------ | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `GL_OTP_BACKEND_CONFIG`        | Yes (production) | JSON object `{"domain": ..., "url": ..., "apiKey": ...}`, e.g. `{"domain":"acme.com","url":"https://acme-api.example.com","apiKey":"..."}` |
| `GL_OTP_BACKEND_DEV_FALLBACKS` | No               | Enable localhost fallback for development (`true` or `false`)                                                                              |
| `GL_OTP_BACKEND_DEV_API_KEY`   | No               | App API key to send with localhost fallback requests, matching the local server's `APP_API_KEY`                                            |

Pass `GL_OTP_BACKEND_CONFIG` via `--dart-define-from-file=<path>` pointing at a **gitignored** JSON file, not inline on the command line — inline values land in shell history, `ps aux` output during the build, and CI logs. The file just needs a top-level `GL_OTP_BACKEND_CONFIG` key whose value is the JSON string above.

### Build Examples

```bash
# Production build (secrets.json is gitignored, contains
# {"GL_OTP_BACKEND_CONFIG": "{\"domain\":\"acme.com\",\"url\":\"https://acme-api.example.com\",\"apiKey\":\"...\"}"})
flutter build apk --dart-define-from-file=secrets.json

# Development build with localhost fallback
flutter build apk --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true --dart-define=GL_OTP_BACKEND_DEV_API_KEY=<key matching local server APP_API_KEY>
```

### URL Resolution

For the company domain entered at registration, the app resolves candidates in this order:

1. If the domain matches `GL_OTP_BACKEND_CONFIG`'s configured `domain`, use its `url`/`apiKey`
2. In debug mode with `GL_OTP_BACKEND_DEV_FALLBACKS=true`, also try (paired with `GL_OTP_BACKEND_DEV_API_KEY`):
   - `http://10.0.2.2:8080` (Android emulator host machine)
   - `http://127.0.0.1:8080` (localhost)

Any other domain, and any domain with no working dev fallback, is refused — the app will not talk to an unconfigured backend.

### Security

The connection is secured by TLS (HTTPS). Ensure your backend is configured with a valid TLS certificate.

The app sends `apiKey` as an `x-app-api-key` header on every OTP/UTC request, gating out opportunistic/scripted callers. This is a Phase 1, dev/staging-appropriate control, not a durable production one: any value embedded in a compiled app is extractable via decompilation or by proxying the app's own traffic, so it does not prove a request came from an unmodified, legitimate copy of the app. A decompiled build still exposes its own domain's key — the single-config change above only stops one leak from exposing every tenant's key at once. See `granite-lake-app-auth-design.md` at the repo root for the full design and the Phase 2 (device attestation + short-lived session tokens) follow-up.

## Smart Contract Integration

The app integrates with the published Move module:

- `granite_lake::photo_attestation`

The app currently uses these contract entry points:

- `attest_photo`
- `attest_file`

OTP and UserCap claim flow:

- the app calls the backend `POST /otp/request` endpoint with the company domain and user email
- the backend delivers the OTP through its configured delivery channel
- the app calls `POST /otp/verify` with `userId`, `otp`, `domain`, and the device wallet address
- the backend verifies the OTP, then signs the contract `add_user` transaction with the configured domain-admin wallet
- after success, the backend returns the transaction digest and `UserCap` object id
- the app stores the successful claim record in SQLite and verifies that the `UserCap` resolves for the device wallet

Attestation flow:

- the app uses the claimed `UserCap`
- the app loads the configured `Registry` object
- it calls `attest_photo` with:
  - `UserCap`
  - `Registry`
  - image SHA-256
  - GPS string
  - altitude string
  - project id

File upload flow:

- the app lets the user choose a file from the capture method screen
- the app reuses the claimed `UserCap`
- it calls `attest_file` with:
  - `UserCap`
  - `Registry`
  - file SHA-256
  - file id
  - project id

Important contract behavior:

- `attest_photo` emits an event
- it does not create a separate photo object
- `attest_file` emits an event
- it does not create a separate file object

Because of that:

- `sui_tx_digest` is the real transaction digest
- `sui_object_id` in the app is the `UserCap` object id used for attestation
- the actual proof of attestation is the transaction plus the `PhotoAttested` or `FileAttested` event

## Storage Layout

Granite Lake separates storage into:

- Flutter secure storage for secret or session-gated state
- SQLite for operational app data
- Android Keystore for the biometric gate key
- local filesystem for image binaries

### Flutter secure storage

Granite Lake uses:

- `FlutterSecureStorage(AndroidOptions(encryptedSharedPreferences: true))`

Secure records stored there:

- `registration_code_salt`
- `registration_code_verifier`
- `identity_record`
- `biometric_binding`
- `biometric_gate_payload`
- `session_record`
- `reset_notice`

Concrete secure-storage keys used by the app:

- `registration_code_salt`
- `registration_code_verifier`
- `identity_record`
- `biometric_binding`
- `biometric_gate_payload`
- `session_record`
- `reset_notice`

Field layout for each stored value:

- `registration_code_salt`
  - Type: string
  - Format: Base64-encoded random salt bytes

- `registration_code_verifier`
  - Type: string
  - Format: Base64-encoded PBKDF2-SHA256 output

- `identity_record`
  - Type: JSON object
  - Fields always present:
    - `walletAddress`: Sui address string
    - `publicKeyHex`: hex-encoded Sui public key
    - `createdAt`: ISO-8601 UTC timestamp string
  - Field present only before biometric binding or in legacy state:
    - `suiPrivateKey`: Sui secret-key string returned by `toSuiPrivateKey()`

- `biometric_binding`
  - Type: JSON object
  - Fields:
    - `boundAt`: ISO-8601 UTC timestamp string
    - `modalities`: array of strings such as `FINGERPRINT` or `FACE`
    - `gateAlias`: Android Keystore alias string

- `biometric_gate_payload`
  - Type: JSON object
  - Fields:
    - `ciphertextBase64`: Base64-encoded AES-GCM ciphertext of the protected bundle
    - `ivBase64`: Base64-encoded AES-GCM IV used for that ciphertext

- `session_record`
  - Type: JSON object
  - Fields:
    - `startedAt`: ISO-8601 UTC timestamp string
    - `expiresAt`: ISO-8601 UTC timestamp string

- `reset_notice`
  - Type: string
  - Format: plain user-facing message shown after a destructive reset

Important notes:

- `identity_record` contains the exportable Sui private key only before biometric binding
- after biometric binding, the identity record is rewritten without plaintext private key material
- the claimed `UserCap` is no longer stored here; it is persisted in SQLite `app_config`

### SQLite database

SQLite service:

- `lib/core/database/granite_lake_database_service.dart`

Schema and migrations:

- `lib/core/database/migrations.dart`

Current database version:

- `6`

Current tables:

- `employees`
- `projects`
- `captures`
- `app_config`

#### `employees`

Stores the local employee profile used by profile and onboarding state.

Current fields include:

- `employee_id`
- `full_name`
- `role`
- `tenant_name`
- `company_domain`
- `initials`
- `is_placeholder`
- `created_at`
- `updated_at`

Behavior:

- first local init seeds a placeholder employee (`EMP-0001 / John Doe`)
- after successful account claim, the app replaces the placeholder row with the entered:
  - employee / user id
  - company domain

#### `projects`

Stores project definitions used during capture and history filtering.

#### `captures`

Stores all persisted capture records, including:

- `captured_at`
- `submitted_at`
- local image path
- image SHA-256
- signature
- proof payload JSON
- `sui_tx_digest`
- `sui_object_id` (`UserCap` object id)
- `sui_submission_status`
- `sui_error_message`
- project id
- tags
- note

#### `uploaded_files`

Stores uploaded file attestations separately from camera captures, including:

- local file path and name
- MIME type and size
- file SHA-256
- transaction digest
- UserCap object id
- submission status and error message
- project id, tags, and note

#### `app_config`

Stores lightweight runtime configuration such as:

- selected project id
- photo attestation contract config
- claimed photo attestation record

Important config keys:

- `selected_project_id`
- `photo_attestation_contract_config`
- `photo_attestation_claim`

### Android Keystore

The biometric gate key is not stored in Flutter secure storage.

It lives in Android Keystore under an alias like:

- `granite_gate_<uuid>`

Example alias shape:

- `granite_gate_550e8400-e29b-41d4-a716-446655440000`

Notes about the alias:

- prefix is always `granite_gate_`
- suffix is a randomly generated UUID
- the alias is stored in Flutter secure storage as `biometric_binding.gateAlias`
- the AES key material behind that alias remains only in Android Keystore and is not exportable

Important properties of the Keystore key:

- non-exportable AES key
- user authentication required
- invalidated when biometric enrollment changes
- AES/GCM/NoPadding

Implementation:

- `android/app/src/main/kotlin/com/example/granite_lake/MainActivity.kt`

Important Android key configuration includes:

- `setUserAuthenticationRequired(true)`
- `setInvalidatedByBiometricEnrollment(true)`
- `AUTH_BIOMETRIC_STRONG` on supported Android versions

This means:

- the AES key cannot be exported into Flutter or application storage
- the key can only be used after biometric authentication
- Android invalidates the key automatically if the enrolled biometric set changes

Exposed method channel operations are:

- `createBiometricGate`
- `unlockBiometricGate`
- `deleteBiometricGate`

### What is actually encrypted by the biometric gate?

Granite Lake does not encrypt only a flag or marker.

It encrypts a JSON payload that currently contains:

- `sentinelBase64`
- `suiPrivateKey`

The protected JSON bundle before encryption has this shape:

- `sentinelBase64`: Base64-encoded 32-byte random value
- `suiPrivateKey`: Sui secret-key string

Why this matters:

- the private key itself is part of the encrypted payload
- Flutter stores only ciphertext plus IV
- the Keystore AES key that can decrypt that payload never leaves Android Keystore

The sentinel exists as an integrity-bound extra value inside the protected bundle so the decrypted payload is a structured gate payload and not merely a raw key string.

### Local filesystem

Only image binaries are stored in app documents storage:

- `<app-documents>/captures/<captureId>/capture.jpg`

If the app is reset after biometric invalidation or account deletion, Granite Lake removes the capture artifacts directory.

## Security Model

Granite Lake separates security into these layers:

1. Device-local wallet creation
2. Biometric protection of the wallet
3. Short-lived in-memory session unlock
4. Signed local proof generation
5. Optional Sui testnet attestation

At a high level:

- a Sui Ed25519 private key is generated locally on-device
- before biometric binding completes, that key is still temporarily exportable inside secure storage
- during biometric binding, the private key is wrapped behind an Android Keystore key that requires biometric authentication
- during session start, Granite Lake recovers the wrapped Sui key only after successful biometric approval
- the unlocked signing key exists only in process memory during an active session
- local proof payloads are signed only while a session is active

## Sui Private Key Lifecycle

### 1. Identity creation

`createIdentity()` generates a Sui Ed25519 private key in Dart and stores:

- `walletAddress`
- `publicKeyHex`
- `suiPrivateKey`
- `createdAt`

Important:

- before biometric binding, the Sui private key still exists in secure storage as exportable application data

### 2. Biometric binding

When the user enables biometrics:

1. Granite Lake checks biometric support and enrollment
2. it builds a protected JSON bundle containing:
   - `sentinelBase64`
   - `suiPrivateKey`
3. that bundle is sent to Android over the `granite_lake/biometric_gate` method channel
4. Android creates a biometric-gated Keystore AES key
5. Android encrypts the payload after biometric approval
6. Flutter stores:
   - the gate alias in `biometric_binding`
   - ciphertext and IV in `biometric_gate_payload`
7. Flutter rewrites `identity_record` without `suiPrivateKey`

After this point:

- the plaintext Sui private key is no longer persisted in app state

### 3. Session start

When the user starts a secure session:

1. Flutter reads the encrypted biometric gate payload
2. Android prompts for biometric approval
3. Android decrypts the protected bundle
4. Flutter restores the Sui private key into `_sessionSigningKey`
5. Flutter opens a short-lived `session_record`

The decrypted key is kept only in memory.

### 4. Session end

When the session ends or expires:

- `_sessionSigningKey` is cleared from memory
- `session_record` is removed

Another biometric unlock is required before more signing can happen.

## Capture Pipeline

Capture logic spans:

- `lib/core/services/granite_lake_capture_workflow_service.dart`
- `lib/core/state/granite_lake_controller.dart`

Current sequence:

1. copy the image into app documents storage
2. compute SHA-256 of the image
3. record `capturedAt` from the backend `GET /utc` endpoint at capture-button press time
4. re-check current GPS and altitude at submit time and fail submission if the normalized formatted values no longer match the captured values
5. record `submittedAt` from the backend `GET /utc` endpoint at submit-button press time
6. build the signed proof payload
7. sign the payload with the active session key
8. save the local capture row to SQLite with:
   - `suiTxDigest = ''`
   - `suiObjectId = ''`
   - `suiSubmissionStatus = 'PENDING_SUBMISSION'`
   - `suiErrorMessage = ''`
   - both `captured_at` and `submitted_at`
9. submit `attest_photo` to Sui testnet
10. update the same capture row with:

- transaction digest
- `UserCap` object id
- submission status
- translated error message if submission failed

Submission preconditions now include:

- backend connectivity via `GET /utc`
- non-null `capturedAt`
- non-null `submittedAt`
- non-empty GPS label
- non-empty altitude label
- non-empty project id

The post-submit progress screen now reflects real pipeline stages:

- hashing and signing evidence
- saving local record
- submitting to Sui testnet
- refreshing device history

## On-Chain Verification

History verification now checks the real `PhotoAttested` and `FileAttested` events, not just local status flags.

Verification service:

- `lib/core/services/photo_attestation_service.dart`

The app fetches the transaction block and compares:

- on-chain `photo_hash` or `file_hash`
- on-chain `gps`
- on-chain `altitude`
- on-chain `project_id`
- on-chain timestamp

against local capture data:

- `imageSha256`
- `fileSha256`
- `gpsLabel`
- `altitudeLabel`
- `projectId`
- `submittedAt`

History behavior:

- successful submission alone is not treated as fully verified
- an anchored photo or file is marked verified only after the event fields match
- chain timestamp is checked against local `submittedAt` with the configured tolerance window
- mismatches and chain lookup failures are surfaced in history/detail state

## Error Handling

Granite Lake now preserves and surfaces real Sui submission errors for attestation.

Behavior:

- raw Sui / Move failures are translated into user-friendly messages where possible
- translated errors are stored on the capture row as `sui_error_message`
- submit success/failure screens and history detail can display that message

Examples of friendly errors now handled:

- no SUI gas coins in wallet
- insufficient SUI balance
- timeout / connectivity issues
- missing contract registry
- missing `UserCap`
- invalid OTP
- OTP already used
- contract aborts such as:
  - user disabled
  - wallet mismatch
  - user not authorized to attest

If an exact abort code cannot be mapped, Granite Lake still tries to summarize the raw chain error instead of showing only a generic failure.

## Registration and Claim State

Granite Lake currently still supports a registration verifier model in secure storage:

- `registration_code_salt`
- `registration_code_verifier`

This remains part of the secure state service, but the active onboarding flow for Sui contract integration is centered on:

- wallet setup
- employee/domain claim via backend OTP verification
- biometric protection

The successful claim record stored in SQLite contains:

- `domain`
- `userId`
- `userCapObjectId`
- `claimedAt`

## Reset Behavior

When biometric enrollment changes and the Android Keystore key is invalidated:

1. Granite Lake attempts session unlock
2. Android reports the biometric-gated key is no longer usable
3. the app offers a reset flow
4. if confirmed, Granite Lake clears:
   - secure storage state
   - local capture artifacts
   - SQLite captures
   - SQLite projects
   - SQLite employees
   - SQLite config

The app then returns to onboarding.

## Current Security Properties

What Granite Lake does well now:

- generates the Sui key locally on-device
- removes the exportable Sui private key from persistent state after biometric binding
- uses Android Keystore non-exportable AES keys for biometric-gated unwrap
- invalidates access when the biometric enrollment set changes
- keeps the recovered Sui private key only in process memory during an active session
- persists operational state in SQLite while keeping secrets in secure storage / Keystore

Important limitations:

- before biometric binding completes, the Sui private key still exists in secure storage as plaintext application data
- during an active session, the recovered Sui private key is resident in app memory
- attestation currently uses an exportable Sui private key that has been wrapped, not a non-exportable hardware-backed Sui signing key
- the app is currently testnet-only for Sui contract integration

## Future Hardening

The strongest next steps would be:

1. remove the brief pre-binding plaintext persistence window for the Sui private key
2. move from wrapping an exportable Sui private key to signing with non-exportable hardware-backed key material
3. add iOS secure storage / biometric gate support
4. add server-side or operator-side verification tooling for attestation events

## Development Setup

### Running the App

The app requires the backend API URL and app API key to be configured at build time, via `--dart-define-from-file`. **Always run/build through `secrets.json`, even for local development** — it's the same file and the same flag whether you're pointing at your local server or a deployed one, so there's no separate "dev mode" config path to keep in sync with `GL_OTP_BACKEND_CONFIG`'s shape.

`secrets.json` lives at `app/secrets.json`, is gitignored (see `.gitignore`), and is never committed. See "Backend URL Configuration" above for its shape. For local development, point `url` at your local server instead of a real one:

```json
{
  "GL_OTP_BACKEND_CONFIG": "{\"domain\":\"acme.com\",\"url\":\"http://10.0.2.2:8080\",\"apiKey\":\"<matches local server APP_API_KEY>\"}"
}
```

- `http://10.0.2.2:8080` — Android emulator (this is the standard alias the emulator uses to reach the host machine's `localhost`; this app is Android-only today, no iOS/desktop targets exist)
- For a **physical device** on the same network, use your machine's LAN IP instead (e.g. `http://192.168.1.23:8080`), since `10.0.2.2` only resolves inside the emulator
- `apiKey` must match the `APP_API_KEY` value in `server/.env` for the stack you're pointing at

Make sure the server is running first:

```bash
cd server
docker compose --env-file .env up --build -d
```

#### Quick Start

```bash
flutter run --dart-define-from-file=secrets.json
```

#### VS Code Setup (Recommended for Development)

Create `.vscode/launch.json` in the app folder:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Granite Lake (Dev)",
      "request": "launch",
      "type": "dart",
      "program": "lib/main.dart",
      "args": ["--dart-define-from-file=secrets.json"]
    }
  ]
}
```

Then simply press `F5` or run from the debug panel.

#### Production Build

```bash
# Before building, swap the url in secrets.json back to the real backend
# for that domain — it's the same file used for local dev, so it's easy
# to forget to swap it back.
flutter build apk --dart-define-from-file=secrets.json
```

#### Running on Specific Device

```bash
# List available devices
flutter devices

# Run on a specific device/emulator
flutter run -d <device-id> --dart-define-from-file=secrets.json
```

### Troubleshooting

**"Could not reach OTP backend"**

- Ensure server is running: `docker compose ps`
- Check server logs: `docker compose logs api`
- Verify port 8080 is accessible
- Verify `secrets.json` has an entry for the exact domain you typed at registration (matching is case-insensitive but must be the same domain string)

**Connection refused**

- Android emulator can't access localhost directly - use `10.0.2.2` in `secrets.json`
- Physical device needs your machine's LAN IP in `secrets.json`, not `10.0.2.2` or `127.0.0.1`

**401 Unauthorized**

- `apiKey` in `secrets.json` doesn't match `APP_API_KEY` in `server/.env` for the stack you're pointing at — after changing either, rebuild/rerun the app (dart-define values are baked in at build time) and restart the server (see "Environment" in `server/README.md`)

There is still a `GL_OTP_BACKEND_DEV_FALLBACKS=true` / `GL_OTP_BACKEND_DEV_API_KEY=<key>` dart-define pair available as a fallback that tries `10.0.2.2:8080` then `127.0.0.1:8080` automatically in debug builds without needing a `secrets.json` entry for your domain — useful for a quick one-off run, but `secrets.json` is the recommended day-to-day path since it's identical to how the app is actually built for real deployments.

## Development Notes

Useful validation commands:

```bash
flutter analyze lib
cd android && ./gradlew :app:assembleDebug
```

Because the secure biometric flow depends on Android Keystore behavior, the most important runtime validation still needs:

- a real Android device, or
- an emulator with biometrics enrolled
