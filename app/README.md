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
3. Protect the wallet with biometrics
4. Link the device to a user account with:
   - company domain
   - employee / user id
   - OTP
5. Start a secure session (30 minutes)
6. Choose a capture method: capture a photo or upload a file
7. Save the local signed proof bundle
8. Submit `attest_photo` or `attest_file` to Sui testnet
9. Verify later that on-chain event data matches the local photo or file attestation

Important implementation details:

- the user does not enter `packageId` or `registryId`
- those are bundled in the app and synced into SQLite automatically at startup
- biometric protection is set up before account registration, not after: the router redirects identity setup → biometric setup → registration, because the wallet's raw signing key exists unprotected in storage from the moment it is created until the hardware-backed biometric gate wraps it

## Current Sui Contract Defaults

Bundled defaults live in:

- `lib/core/constants/app_constants.dart`

Current testnet defaults:

- GraphQL endpoint: `https://graphql.testnet.sui.io/graphql` (legacy `fullnode.*.sui.io` RPC URLs are normalized to their `graphql.*.sui.io/graphql` equivalents at runtime)
- package id: `0xf4b83a02ad29b78266f8b1a39f5b533bde6bd5ef00eb434db46c3f7be29639db`
- registry id: `0xde8b9f476c91dbdb05238c656a6ea3aa9f670e3b732e3e5d48628f5d2b66122d`
- module: `photo_attestation`
- faucet URL: `https://faucet.sui.io/?network=testnet`
- minimum wallet SUI balance for attestation: 0.004 SUI (4,000,000 MIST)
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
- the backend delivers the OTP through its configured delivery channel and returns `userId`, `expiresAt`, and a server-issued `walletNonce`
- the app calls `POST /otp/verify` with `userId`, `otp`, `domain`, the device wallet address (`userWallet`), and `userWalletSignature` — an Ed25519 personal-message signature over the `walletNonce`, proving the caller controls the wallet's private key
- the backend verifies the OTP and the wallet signature, then signs the contract `add_user` transaction with the configured domain-admin wallet
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

Sui GraphQL client:

- all chain access goes through `lib/core/services/sui_graphql_service.dart`, which talks to the Sui GraphQL endpoint instead of the JSON-RPC fullnode
- its public API is `getChainInfo`, `getReferenceGasPrice`, `getSuiAddressBalance`, `getSuiBalance`, `getObject`, `listOwnedObjectsByType`, `getTransaction`, `simulateTransaction`, and `executeTransaction`
- `normalizeUrl` maps legacy `fullnode.*.sui.io` URLs to their `graphql.*.sui.io/graphql` equivalents so older stored configs keep working
- requests are retried only on transient network errors (dropped connection, DNS blip, timeout): 3 attempts with exponential backoff; errors the server actually answered are never retried

Gas payment and budgeting:

- before execution, every attestation transaction is dry-run through `simulateTransaction`, and the gas budget is set from the dry-run's computation and storage costs plus a safety margin
- gas is normally paid with owned `Coin<SUI>` objects selected to cover the budget (larger coins first, skipping coins already used as inputs by the transaction)
- when coin objects alone do not cover the budget, the app falls back to paying gas from the wallet's address balance — where the Sui faucet deposits testnet funds: the transaction is submitted with an empty gas payment, and its BCS expiration is rewritten into a `ValidDuring` expiration carrying the current epoch and chain identifier (`_bcsWithValidDuringExpiration`, covered by `test/core/services/valid_during_bcs_test.dart`)
- if neither source covers the budget, submission fails with a gas or insufficient-balance error

## Storage Layout

Granite Lake separates storage into:

- Flutter secure storage for secret or session-gated state
- SQLite for operational app data
- Android Keystore for the biometric gate key
- local filesystem for captured photos and uploaded files

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
- `device_registration`
- `reset_notice`

Concrete secure-storage keys used by the app:

- `registration_code_salt`
- `registration_code_verifier`
- `identity_record`
- `biometric_binding`
- `biometric_gate_payload`
- `session_record`
- `device_registration`
- `reset_notice`
- `otp_backend_build_version`

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

- `device_registration`
  - Type: JSON object
  - Fields:
    - `registeredAt`: ISO-8601 UTC timestamp string
    - `model`, `manufacturer`, `platform`, `osVersion`: device descriptors captured when the device is registered

- `reset_notice`
  - Type: string
  - Format: plain user-facing message shown after a destructive reset

- `otp_backend_build_version`
  - Type: string
  - Format: backend resolver contract version (currently `2`, `AppConstants.otpBackendAppBuildVersion`), written by the backend URL resolver in `lib/core/utils/utils.dart`; a mismatch against the bundled version forces re-resolution of the backend configuration

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

- `9`

Current tables:

- `employees`
- `projects`
- `photo_captures`
- `uploaded_files`
- `app_config`

The legacy `captures` table only exists on installs upgraded from database version 7 or earlier; fresh installs never create it, and no controller reads or writes it.

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
- `wallet_address`
- `created_at`
- `updated_at`

Behavior:

- first local init seeds a placeholder employee (`EMP-0001 / John Doe`)
- after successful account claim, the app replaces the placeholder row with the entered:
  - employee / user id
  - company domain
  - wallet address of the device wallet

#### `projects`

Stores project definitions used during capture and history filtering.

#### `photo_captures`

Stores camera photo records, including:

- `captured_at`
- `submitted_at`
- local image path
- image SHA-256
- signature
- `wallet_address` and `public_key_hex` of the signing wallet
- proof payload JSON
- `sui_tx_digest`
- `sui_object_id` (`UserCap` object id)
- `sui_submission_status`
- `sui_error_message`
- project id
- tags
- note
- `preview_kind`
- `storage_mode`

#### `uploaded_files`

Stores uploaded file attestations separately from camera captures, including:

- local file path and name
- MIME type, size, and file extension
- file SHA-256
- `wallet_address` and `public_key_hex` of the signing wallet
- transaction digest
- UserCap object id
- submission status and error message
- project id, tags, and note
- `preview_kind`
- `storage_mode`

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

- `android/app/src/main/kotlin/com/favoritemedium/granite_lake/MainActivity.kt`
- the Android namespace and application id are `com.favoritemedium.granite_lake`

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
- `stripGpsExif` (GPS EXIF stripping, see Capture Pipeline below)

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

Captured photos and uploaded files are both stored in app documents storage:

- photos: `<app-documents>/captures/<captureId>/capture.jpg`
- uploaded files: `<app-documents>/captures/<recordId>/<safeFileName>`, where `safeFileName` is the picked file name sanitized to `A-Za-z0-9._-` characters (falling back to `uploaded_asset` when nothing survives sanitization)

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
- the Android activity sets `FLAG_SECURE` for the whole app, so screenshots, screen recording, and the recent-apps thumbnail are blocked on every screen

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
5. Flutter opens a short-lived `session_record` (sessions run for 30 minutes, `captureSessionDurationMinutes`)

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
2. strip GPS EXIF tags from the stored copy (Android only, before hashing)
3. compute SHA-256 of the image
4. record `capturedAt` from the backend `GET /utc` endpoint at capture-button press time
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

GPS EXIF stripping:

- before hashing, the app invokes the `stripGpsExif` method-channel operation on the stored photo copy
- this removes GPS-related EXIF tags in place so Android's later EXIF location redaction (applied for readers without `ACCESS_MEDIA_LOCATION`) cannot change the hash of an already-attested file
- the attested GPS coordinates come from Geolocator, never from the photo's EXIF
- stripping is best-effort: if it fails, the capture still proceeds

Location resolution:

- GPS fixes resolve network-first: `resolveBestEffortPosition` in `lib/core/utils/location_settings.dart` tries a medium-accuracy (cell/Wi-Fi) request with a 10-second timeout, then falls back to a high-accuracy GPS fix with a 2-minute timeout
- the latest fix is cached in the controller (`recordLocationFix`) so the next screen seeds its readout without paying a second cold scan

Wallet SUI balance gate:

- the controller tracks the wallet's SUI balance (`walletSuiBalanceMist`, refreshed via `refreshWalletSuiBalance`)
- photo and file submission abort with an "add test SUI" message when the balance is below 0.004 SUI / 4,000,000 MIST (`minimumAttestationSuiBalance` / `minimumAttestationMistBalance`)
- the registration and profile screens surface the balance and this gate ("Add test funds first")

Submission preconditions now include:

- backend connectivity via `GET /utc`
- non-null `capturedAt`
- non-null `submittedAt`
- non-empty GPS label
- non-empty altitude label
- non-empty project id
- wallet SUI balance at or above the minimum-balance gate

The post-submit progress screen now reflects real pipeline stages:

- hashing and signing evidence
- saving local record
- submitting to Sui testnet
- refreshing device history

The signed proof payload is built by `granite_lake_capture_workflow_service.dart` and includes:

- `captureId` and `fileId`
- `capturedAt` and `submittedAt`
- `imagePath` and `imageSha256`
- asset metadata: `assetType`, `fileName`, `mimeType`, `fileSizeBytes`, `fileExtension`, `previewKind`, `storageMode`
- signing wallet: `walletAddress`, `publicKeyHex`
- session bounds: `sessionStartedAt`, `sessionExpiresAt`
- `signatureAlgorithm` (`SUI_ED25519`) and `signatureIntent` (`PERSONAL_MESSAGE`)
- `appName` and `appVersion`
- context labels when available: `buildLabel`, `gpsLabel`, `altitudeLabel`, `cameraLabel`, `cameraDetailsLabel`
- `projectId`, `tags`, and `note`

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
- on-chain sender: the transaction sender and the event sender must equal the device wallet address, and for `FileAttested` the event's `user_wallet` field must match as well
- for files, the on-chain `file_id` must match the local file id

against local capture data:

- `imageSha256`
- `fileSha256`
- `gpsLabel`
- `altitudeLabel`
- `projectId`
- `submittedAt`
- `walletAddress`
- `fileId`

History behavior:

- successful submission alone is not treated as fully verified
- an anchored photo or file is marked verified only after the event fields match
- chain timestamp is checked against local `submittedAt` with a 15-minute tolerance window (`maximumAttestationTimeGapMinutes`)
- verification retries automatically on transient-looking failures (event not indexed yet, transaction not found, timeout, network): up to 5 attempts, delayed 3 seconds per attempt
- a network failure keeps the record pending rather than marking it failed, since a failed round-trip is not evidence the on-chain attestation failed
- mismatches and chain lookup failures are surfaced in history/detail state

Operator-side verification tooling already exists at the repo root:

- `verification_api/` exposes `POST /verify-attestation` for server-side checks
- `verification_portal/` provides a browser-based, hash-first verification flow

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
- biometric protection
- employee/domain claim via backend OTP verification

The successful claim record stored in SQLite contains:

- `domain`
- `userId`
- `userCapObjectId`
- `claimTxDigest`
- `claimedAt`

## Reset Behavior

When biometric enrollment changes and the Android Keystore key is invalidated:

1. Granite Lake attempts session unlock
2. Android reports the biometric-gated key is no longer usable
3. the app offers a reset flow
4. if confirmed, Granite Lake clears:
   - secure storage state
   - local capture artifacts
   - SQLite `photo_captures`
   - SQLite `uploaded_files`
   - SQLite projects
   - SQLite employees
   - SQLite config

A separate user-initiated account-deletion flow (`deleteAccount()`) clears the same local state. Before wiping, it calls the backend `PATCH otp/<userId>/deactivate` endpoint best-effort so the server and the on-chain enabled flag stop listing the user as active; local deletion proceeds even when the device is offline or the call fails.

After either flow, the router sends the user to `/local-data-init` (local data re-initialization) rather than onboarding.

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

## UI Features

- dark-mode toggle on the welcome and profile screens (`toggleTheme`, `lib/core/widgets/theme_toggle_button.dart`)
- save an attested photo to the device gallery from the capture detail screen (`Gal.putImage`)

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
flutter test
cd android && ./gradlew :app:assembleDebug
```

Because the secure biometric flow depends on Android Keystore behavior, the most important runtime validation still needs:

- a real Android device, or
- an emulator with biometrics enrolled
