import 'dart:convert';

/// A single domain's backend routing + credential, resolved from
/// [AppConstants.otpBackendConfig].
class DomainBackendConfig {
  const DomainBackendConfig({required this.url, required this.apiKey});

  final String url;
  final String apiKey;
}

abstract final class AppConstants {
  // ── App meta ───────────────────────────────────────────────────────────────
  static const String appName = 'GRANITE LAKE';
  static const String appTitle = 'Granite Lake';
  static const String appVersion = 'V1.0';
  static const String walletCreateAsset = 'assets/images/wallet_create.png';
  static const int captureSessionDurationMinutes = 30;
  static const String captureDirectoryName = 'captures';

  // ── Onboarding ─────────────────────────────────────────────────────────────
  static const String welcomeFlowId = 'ONBOARDING_FLOW_V1.0';
  static const String welcomeStatus = 'READY';
  static const String welcomeEncryptMode = 'DEVICE_TRUST';
  static const String welcomeDisplayId = 'FIELD_CAPTURE_INIT';

  static const String registrationFlowId = 'ACCESS_CONTROL_V1.0';
  static const String registrationStatus = 'SUI_CLAIM';
  static const String registrationEncryptMode = 'PHOTO_ATTESTATION';
  static const String registrationDisplayId = 'USER_CAP_CLAIM';

  static const String identityFlowId = 'IDENTITY_BINDING_V1.0';
  static const String identityStatus = 'KEYPAIR_SETUP';
  static const String identityEncryptMode = 'SUI_KEYPAIR';

  static const String biometricFlowId = 'IDENTITY_BINDING_V1.0';
  static const String biometricStatus = 'BIOMETRIC_STEP';
  static const String biometricEncryptMode = 'SECURE_ENCLAVE';

  static const String defaultSuiRpcUrl =
      'https://graphql.testnet.sui.io/graphql';
  static const String suiTestnetFaucetUrl =
      'https://faucet.sui.io/?network=testnet';

  // OTP / UTC backend configuration.
  //
  // One backend stack is deployed per domain, and each app build serves
  // exactly one client's domain, so production builds embed a single
  // {domain, url, apiKey} object rather than a map covering several
  // tenants. Earlier this was a per-domain map so one build could carry
  // several tenants' credentials at once; extracting the compiled app (see
  // the Security note below) would then have handed over every tenant's
  // key in one string instead of just this build's own. Production builds
  // MUST set GL_OTP_BACKEND_CONFIG. The resolver in `core/utils/utils.dart`
  // will refuse to talk to any domain other than the one configured here.
  //
  // Security: Phase 1 only. The connection is secured by TLS (HTTPS), and
  // apiKey stops opportunistic/scripted callers, but a value embedded in a
  // compiled app is extractable via decompilation or by proxying the app's
  // own traffic \u2014 it does not prove a request came from an unmodified,
  // legitimate copy of the app. See granite-lake-app-auth-design.md at the
  // repo root for the Phase 2 (device attestation) follow-up.
  //
  // Pass this via `--dart-define-from-file=<gitignored-json>` rather than
  // inline on the command line, so the values don't land in shell history,
  // `ps aux` output, or CI logs.
  //
  // For local development, enable dev fallbacks:
  //   --dart-define=GL_OTP_BACKEND_DEV_FALLBACKS=true
  //   --dart-define=GL_OTP_BACKEND_DEV_API_KEY=<key matching local server .env>
  static const String _rawOtpBackendConfig = String.fromEnvironment(
    'GL_OTP_BACKEND_CONFIG',
    defaultValue: '',
  );
  static const bool otpBackendDevFallbacksEnabled = bool.fromEnvironment(
    'GL_OTP_BACKEND_DEV_FALLBACKS',
    defaultValue: false,
  );
  static const String otpBackendDevApiKey = String.fromEnvironment(
    'GL_OTP_BACKEND_DEV_API_KEY',
    defaultValue: '',
  );

  /// Bump this whenever the resolver contract changes. The resolver compares it
  /// to a value stored in secure storage and forces a re-resolution on mismatch.
  static const int otpBackendAppBuildVersion = 2;

  /// The one domain this build serves, lowercased and trimmed, parsed from
  /// [_rawOtpBackendConfig]. Null if unset or malformed.
  static String? get otpBackendDomain {
    final domain = (_parsedOtpBackendConfig?['domain'] as String? ?? '')
        .trim()
        .toLowerCase();
    return domain.isEmpty ? null : domain;
  }

  /// This build's single backend config, parsed from [_rawOtpBackendConfig].
  /// Example shape: `{"domain":"acme.com","url":"https://acme-api.example.com","apiKey":"..."}`.
  static DomainBackendConfig? get otpBackendConfig {
    final decoded = _parsedOtpBackendConfig;
    if (decoded == null) {
      return null;
    }

    final url = (decoded['url'] as String? ?? '').trim();
    final apiKey = (decoded['apiKey'] as String? ?? '').trim();
    if (url.isEmpty || apiKey.isEmpty) {
      return null;
    }

    return DomainBackendConfig(url: url, apiKey: apiKey);
  }

  static Map<String, dynamic>? get _parsedOtpBackendConfig {
    final cleaned = _rawOtpBackendConfig.trim();
    if (cleaned.isEmpty) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      return null;
    }

    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static const String defaultPhotoAttestationModule = 'photo_attestation';
  static const String defaultPhotoAttestationPackageId =
      '0xf4b83a02ad29b78266f8b1a39f5b533bde6bd5ef00eb434db46c3f7be29639db';
  static const String defaultPhotoAttestationRegistryId =
      '0xde8b9f476c91dbdb05238c656a6ea3aa9f670e3b732e3e5d48628f5d2b66122d';
  static const double minimumAttestationSuiBalance = 0.004;
  static const int minimumAttestationMistBalance = 4000000;
  static const int maximumAttestationTimeGapMinutes = 15;
}
