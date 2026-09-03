import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:on_chain/sui/sui.dart';

import '../database/granite_lake_data_controllers.dart';
import '../constants/app_constants.dart';
import '../services/granite_lake_capture_workflow_service.dart';
import '../services/photo_attestation_service.dart';
import '../services/granite_lake_secure_state_service.dart';
import 'granite_lake_models.dart';

export 'granite_lake_models.dart';

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class GraniteLakeController extends ChangeNotifier {
  static GraniteLakeController? _current;

  static GraniteLakeController? get current => _current;

  GraniteLakeController()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      ),
      _dataControllers = GraniteLakeDataControllers.create() {
    _current = this;
    _secureStateService = GraniteLakeSecureStateService(storage: _storage);
    _captureWorkflowService = GraniteLakeCaptureWorkflowService();
    _photoAttestationService = PhotoAttestationService();
  }

  final FlutterSecureStorage _storage;
  final GraniteLakeDataControllers _dataControllers;
  late final GraniteLakeSecureStateService _secureStateService;
  late final GraniteLakeCaptureWorkflowService _captureWorkflowService;
  late final PhotoAttestationService _photoAttestationService;

  Timer? _sessionTicker;
  bool _isInitializing = true;
  String? _initializationError;
  bool _hasCompletedRegistration = false;
  DeviceRegistrationRecord? _deviceRegistration;
  EmployeeRecord? _employee;
  IdentityRecord? _identity;
  PhotoAttestationClaimRecord? _photoAttestationClaim;
  BiometricBindingRecord? _biometricBinding;
  BiometricGatePayload? _biometricGatePayload;
  SuiED25519PrivateKey? _sessionSigningKey;
  SessionRecord? _session;
  AttestationRecord? _lastAttestation;
  PhotoCaptureRecord? _lastPhotoCapture;
  UploadedFileRecord? _lastUploadedFile;
  List<AttestationRecord> _attestationHistory = const [];
  List<PhotoCaptureRecord> _photoCaptureHistory = const [];
  List<UploadedFileRecord> _uploadedFileHistory = const [];
  Map<String, AttestationChainVerificationRecord> _attestationVerifications =
      const {};
  Map<String, int> _verificationRetryCounts = const {};
  String? _resetNotice;
  List<ProjectRecord> _projects = const [];
  String? _selectedProjectId;
  PhotoAttestationContractConfig? _photoAttestationConfig;
  bool _requiresLocalDataInitialization = false;
  BigInt? _walletSuiBalanceMist;
  bool _isRefreshingWalletSuiBalance = false;
  bool _isDarkMode = false;

  bool get isInitializing => _isInitializing;
  String? get initializationError => _initializationError;
  bool get hasCompletedRegistration => _hasCompletedRegistration;
  DeviceRegistrationRecord? get deviceRegistration => _deviceRegistration;
  EmployeeRecord? get employee => _employee;
  IdentityRecord? get identity => _identity;
  PhotoAttestationClaimRecord? get photoAttestationClaim =>
      _photoAttestationClaim;
  BiometricBindingRecord? get biometricBinding => _biometricBinding;
  SessionRecord? get session => _session;
  AttestationRecord? get lastAttestation => _lastAttestation;
  PhotoCaptureRecord? get lastPhotoCapture => _lastPhotoCapture;
  UploadedFileRecord? get lastUploadedFile => _lastUploadedFile;
  List<AttestationRecord> get attestationHistory =>
      List.unmodifiable(_attestationHistory);
  List<PhotoCaptureRecord> get photoCaptureHistory =>
      List.unmodifiable(_photoCaptureHistory);
  List<UploadedFileRecord> get uploadedFileHistory =>
      List.unmodifiable(_uploadedFileHistory);
  AttestationChainVerificationRecord? attestationVerificationFor(
    String captureId,
  ) => _attestationVerifications[captureId];
  String? get resetNotice => _resetNotice;
  List<ProjectRecord> get projects => List.unmodifiable(_projects);
  String? get selectedProjectId => _selectedProjectId;
  PhotoAttestationContractConfig? get photoAttestationConfig =>
      _photoAttestationConfig;
  bool get requiresLocalDataInitialization => _requiresLocalDataInitialization;
  BigInt? get walletSuiBalanceMist => _walletSuiBalanceMist;
  bool get isRefreshingWalletSuiBalance => _isRefreshingWalletSuiBalance;
  bool get isDarkMode => _isDarkMode;
  double? get walletSuiBalanceSui => _walletSuiBalanceMist == null
      ? null
      : _walletSuiBalanceMist!.toDouble() / 1000000000;
  bool get hasEnoughSuiForAttestation =>
      (_walletSuiBalanceMist ?? BigInt.zero) >=
      BigInt.from(AppConstants.minimumAttestationMistBalance);
  ProjectRecord? get selectedProject {
    final selectedProjectId = _selectedProjectId;
    if (selectedProjectId == null) {
      return null;
    }

    for (final project in _projects) {
      if (project.projectId == selectedProjectId) {
        return project;
      }
    }
    return null;
  }

  bool get hasProjects => _projects.isNotEmpty;
  bool get hasIdentity => _identity != null;
  bool get hasClaimedPhotoAttestationUser => _photoAttestationClaim != null;
  bool get isBiometricBound => _biometricBinding != null;
  bool get hasActiveSession => _session?.isActive ?? false;

  Duration get remainingSessionDuration {
    final session = _session;
    if (session == null) {
      return Duration.zero;
    }

    final remaining = session.expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) {
      return Duration.zero;
    }

    return remaining;
  }

  Future<void> initialize() async {
    _isInitializing = true;
    _initializationError = null;
    notifyListeners();

    try {
      final secureState = await _secureStateService.loadPersistedState();
      _applySecureInitializationState(secureState);

      await _dataControllers.initialize(secureStorage: _storage);
      _photoAttestationConfig = await _dataControllers.config
          .syncPhotoAttestationContractConfig();
      await _loadDatabaseState();
      unawaited(refreshWalletSuiBalance());
    } catch (error) {
      _initializationError = 'Application initialization failed: $error';
    } finally {
      _isInitializing = false;
      _syncSessionTicker();
      notifyListeners();
    }
  }

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void setDarkMode(bool isDark) {
    if (_isDarkMode != isDark) {
      _isDarkMode = isDark;
      notifyListeners();
    }
  }

  Future<ActionResult> initializeLocalData() async {
    try {
      await _dataControllers.employee.seedDefaultEmployee();
      _photoAttestationConfig = await _dataControllers.config
          .syncPhotoAttestationContractConfig();
      await _loadDatabaseState();
      unawaited(refreshWalletSuiBalance());
      notifyListeners();
      return const ActionResult.success();
    } catch (error) {
      return ActionResult.failure('Local data initialization failed: $error');
    }
  }

  Future<ActionResult> createIdentity() async {
    if (_identity != null) {
      return const ActionResult.success();
    }

    final result = await _secureStateService.createIdentity();
    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    try {
      _identity = result.data;
      notifyListeners();
      return const ActionResult.success();
    } catch (error) {
      return ActionResult.failure('Identity generation failed: $error');
    }
  }

  Future<SecureOperationResult<PhotoAttestationOtpRequestResult>>
  requestPhotoAttestationOtp({
    required String domain,
    required String userEmail,
  }) async {
    final normalizedDomain = domain.trim();
    final normalizedUserEmail = userEmail.trim();
    if (normalizedDomain.isEmpty || normalizedUserEmail.isEmpty) {
      return const SecureOperationResult.failure(
        'Company domain and user email are required.',
      );
    }

    try {
      final result = await _photoAttestationService.requestUserOtp(
        domain: normalizedDomain,
        userEmail: normalizedUserEmail,
      );
      return SecureOperationResult.success(result);
    } on PhotoAttestationException catch (error) {
      return SecureOperationResult.failure(error.userMessage);
    } catch (error) {
      debugPrint('[OTP] requestPhotoAttestationOtp unexpected error: $error');
      return const SecureOperationResult.failure(
        'Something went wrong while requesting the OTP. Please try again.',
      );
    }
  }

  Future<ActionResult> claimPhotoAttestationUser({
    required String domain,
    required String userId,
    required String otp,
    required String walletNonce,
  }) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    if (identity == null) {
      return const ActionResult.failure(
        'Create the local Sui identity before claiming your user record.',
      );
    }
    if (config == null || !config.isComplete) {
      return const ActionResult.failure(
        'Contract config is incomplete. Set RPC URL, package id, registry id, and module name first.',
      );
    }

    final normalizedDomain = domain.trim();
    final normalizedUserId = userId.trim();
    final normalizedOtp = otp.trim();
    final normalizedWalletNonce = walletNonce.trim();
    if (normalizedDomain.isEmpty ||
        normalizedUserId.isEmpty ||
        normalizedOtp.isEmpty ||
        normalizedWalletNonce.isEmpty) {
      return const ActionResult.failure(
        'Company domain, OTP session id, OTP, and wallet nonce are all required.',
      );
    }

    // Proving wallet possession needs the raw signing key. Biometrics are
    // bound before registration runs (see F-09), which strips that key out
    // of the in-memory identity, so unlock it the same way the capture flow
    // does rather than reading it off `identity`. Registration itself has
    // no use for a standing session afterward, so only start one here if
    // none is already active, and tear back down whatever this call started
    // once the signature has been produced - the signing key only needs to
    // exist for the moment it's used.
    final hadActiveSessionBeforeClaim = hasActiveSession;
    if (!hadActiveSessionBeforeClaim) {
      final sessionResult = await startSession(
        promptTitle: 'Confirm your identity',
        promptSubtitle: 'Verify biometrics to complete registration.',
      );
      if (!sessionResult.isSuccess) {
        return sessionResult;
      }
    }
    final sessionSigningKey = _sessionSigningKey;
    if (sessionSigningKey == null) {
      return const ActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }

    try {
      final claim = await _photoAttestationService.claimUserWithOtp(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        input: PhotoAttestationClaimInput(
          domain: normalizedDomain,
          userId: normalizedUserId,
          otp: normalizedOtp,
          walletNonce: normalizedWalletNonce,
        ),
      );
      await _dataControllers.config.savePhotoAttestationClaim(claim);
      await _dataControllers.employee.saveClaimedEmployee(
        employeeId: normalizedUserId,
        companyDomain: normalizedDomain,
        walletAddress: identity.walletAddress,
      );
      _photoAttestationClaim = claim;
      _employee = EmployeeRecord.fromJson(
        (await _dataControllers.employee.loadPrimaryEmployee())!,
      );
      _hasCompletedRegistration = true;
      _resetNotice = null;
      _deviceRegistration ??=
          (await _secureStateService.loadPersistedState()).deviceRegistration;
      unawaited(refreshWalletSuiBalance(force: true));
      notifyListeners();
      return const ActionResult.success();
    } on PhotoAttestationException catch (error) {
      return ActionResult.failure(error.userMessage);
    } catch (error) {
      debugPrint('[OTP] claimPhotoAttestationUser unexpected error: $error');
      return const ActionResult.failure(
        'Something went wrong while verifying your OTP. Please try again.',
      );
    } finally {
      if (!hadActiveSessionBeforeClaim) {
        await endSession();
      }
    }
  }

  Future<ActionResult> updatePhotoAttestationConfig({
    required String rpcUrl,
    required String packageId,
    required String registryId,
    required String moduleName,
  }) async {
    final nextConfig = PhotoAttestationContractConfig(
      rpcUrl: rpcUrl.trim(),
      packageId: packageId.trim(),
      registryId: registryId.trim(),
      moduleName: moduleName.trim(),
      updatedAt: DateTime.now().toUtc(),
    );
    if (!nextConfig.isComplete) {
      return const ActionResult.failure(
        'RPC URL, package id, and module name are required.',
      );
    }

    await _dataControllers.config.savePhotoAttestationContractConfig(
      nextConfig,
    );
    _photoAttestationConfig = nextConfig;
    notifyListeners();
    return const ActionResult.success();
  }

  Future<ActionResult> bindBiometrics() async {
    final result = await _secureStateService.bindBiometrics(
      identity: _identity,
    );
    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    _identity = result.data!.identity;
    _biometricBinding = result.data!.biometricBinding;
    _biometricGatePayload = result.data!.biometricGatePayload;
    _sessionSigningKey = null;
    _session = null;
    _syncSessionTicker();
    notifyListeners();
    return const ActionResult.success();
  }

  Future<ActionResult> startSession({
    String? promptTitle,
    String? promptSubtitle,
  }) async {
    if (hasActiveSession) {
      return const ActionResult.success();
    }

    final result = await _secureStateService.startSession(
      identity: _identity,
      biometricBinding: _biometricBinding,
      biometricGatePayload: _biometricGatePayload,
      promptTitle: promptTitle,
      promptSubtitle: promptSubtitle,
    );
    if (result.clearedBiometricBinding) {
      _clearLocalBiometricSessionState();
      notifyListeners();
    }

    if (!result.isSuccess || result.data == null) {
      return _toActionResult(result);
    }

    _sessionSigningKey = result.data!.sessionSigningKey;
    _session = result.data!.session;
    _syncSessionTicker();
    notifyListeners();
    return const ActionResult.success();
  }

  Future<void> endSession() async {
    await _secureStateService.endSession();
    _clearLocalSessionState();
    notifyListeners();
  }

  Future<void> dismissResetNotice() async {
    if (_resetNotice == null) {
      return;
    }

    _resetNotice = null;
    await _secureStateService.dismissResetNotice();
    notifyListeners();
  }

  Future<void> resetForBiometricInvalidation() async {
    await _resetAppState(GraniteLakeSecureStateService.biometricChangedMessage);
  }

  Future<void> deleteAccount() async {
    final claim = _photoAttestationClaim;
    if (claim != null) {
      // Best-effort: local deletion must succeed even if this fails or the
      // device is offline. Without it, the server (and the on-chain
      // enabled flag) would keep listing this user as active indefinitely.
      try {
        await _photoAttestationService.deactivateUser(
          domain: claim.domain,
          userId: claim.userId,
        );
      } catch (_) {
        // Ignored: nothing the user can do about a failed server sync from
        // the delete-account flow, and their device-local deletion should
        // not be blocked by it.
      }
    }

    await _resetAppState(GraniteLakeSecureStateService.accountDeletedMessage);
  }

  Future<void> _resetAppState(String notice) async {
    await _secureStateService.resetApplicationState(
      biometricBinding: _biometricBinding,
      notice: notice,
    );
    await _captureWorkflowService.clearCaptureArtifacts();
    _clearLocalBiometricSessionState(clearIdentity: true);

    _hasCompletedRegistration = false;
    _deviceRegistration = null;
    _employee = null;
    _photoAttestationClaim = null;
    _lastAttestation = null;
    _lastPhotoCapture = null;
    _lastUploadedFile = null;
    _attestationHistory = const [];
    _photoCaptureHistory = const [];
    _uploadedFileHistory = const [];
    _attestationVerifications = const {};
    _verificationRetryCounts = const {};
    _projects = const [];
    _selectedProjectId = null;
    _photoAttestationConfig = null;
    _requiresLocalDataInitialization = true;
    _resetNotice = notice;
    _walletSuiBalanceMist = null;
    _isRefreshingWalletSuiBalance = false;

    await _dataControllers.photoCapture.clear();
    await _dataControllers.uploadedFile.clear();
    await _dataControllers.project.clear();
    await _dataControllers.employee.clear();
    await _dataControllers.config.clear();
    notifyListeners();
  }

  Future<AttestationActionResult> persistCapture(
    String temporaryImagePath,
  ) async {
    return persistCaptureWithMetadata(temporaryImagePath);
  }

  Future<ActionResult> createProject({
    String? projectId,
    required String title,
  }) async {
    final normalizedTitle = title.trim();
    if (normalizedTitle.isEmpty) {
      return const ActionResult.failure('Project title is required.');
    }
    final requestedProjectId = projectId?.trim().toLowerCase();
    final normalizedProjectId =
        requestedProjectId == null || requestedProjectId.isEmpty
        ? _generateProjectId(normalizedTitle)
        : requestedProjectId;
    if (!_uuidPattern.hasMatch(normalizedProjectId)) {
      return const ActionResult.failure(
        'Project ID must be a standard UUID v4.',
      );
    }
    final duplicateId = _projects.any(
      (project) => project.projectId == normalizedProjectId,
    );
    if (duplicateId) {
      return const ActionResult.failure('That project ID already exists.');
    }
    final duplicateTitle = _projects.any(
      (project) => project.title.toLowerCase() == normalizedTitle.toLowerCase(),
    );
    if (duplicateTitle) {
      return const ActionResult.failure('That project title already exists.');
    }

    final project = ProjectRecord(
      projectId: normalizedProjectId,
      title: normalizedTitle,
      createdAt: DateTime.now().toUtc(),
    );

    _projects = [..._projects, project]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _selectedProjectId = project.projectId;
    await _dataControllers.project.saveProject(project.toJson());
    await _persistSelectedProject();
    notifyListeners();
    return const ActionResult.success();
  }

  Future<void> selectProject(String? projectId) async {
    final normalizedProjectId = projectId?.trim();
    if (normalizedProjectId == null || normalizedProjectId.isEmpty) {
      _selectedProjectId = null;
      await _persistSelectedProject();
      notifyListeners();
      return;
    }

    final exists = _projects.any(
      (project) => project.projectId == normalizedProjectId,
    );
    if (!exists) {
      return;
    }

    if (_selectedProjectId == normalizedProjectId) {
      return;
    }

    _selectedProjectId = normalizedProjectId;
    await _persistSelectedProject();
    notifyListeners();
  }

  Future<void> refreshWalletSuiBalance({bool force = false}) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    if (identity == null || config == null || !config.isComplete) {
      if (_walletSuiBalanceMist != null) {
        _walletSuiBalanceMist = null;
        notifyListeners();
      }
      return;
    }
    if (_isRefreshingWalletSuiBalance && !force) {
      return;
    }

    _isRefreshingWalletSuiBalance = true;
    notifyListeners();
    try {
      _walletSuiBalanceMist = await _photoAttestationService
          .getWalletSuiBalanceMist(
            config: config,
            walletAddress: identity.walletAddress,
          );
    } catch (_) {
      if (force) {
        _walletSuiBalanceMist = null;
      }
    } finally {
      _isRefreshingWalletSuiBalance = false;
      notifyListeners();
    }
  }

  Future<AttestationActionResult> persistCaptureWithMetadata(
    String temporaryImagePath, {
    String? projectId,
    List<String> tags = const <String>[],
    String? note,
    DateTime? capturedAtUtc,
    DateTime? submittedAtUtc,
    String? buildLabel,
    String? gpsLabel,
    String? altitudeLabel,
    String? cameraLabel,
    String? cameraDetailsLabel,
    void Function(AttestationSubmissionProgress progress)? onProgress,
  }) async {
    final identity = _identity;
    final session = _session;
    final sessionSigningKey = _sessionSigningKey;
    if (identity == null) {
      return const AttestationActionResult.failure(
        'Device identity is unavailable.',
      );
    }
    if (session == null || !session.isActive) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure capture session has expired.',
      );
    }
    if (sessionSigningKey == null) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }
    final missingFields = <String>[
      if (capturedAtUtc == null) 'captured_at',
      if (submittedAtUtc == null) 'submitted_at',
      if (gpsLabel == null || gpsLabel.trim().isEmpty) 'gps',
      if (altitudeLabel == null || altitudeLabel.trim().isEmpty) 'altitude',
      if (projectId == null || projectId.trim().isEmpty) 'project_id',
    ];
    if (missingFields.isNotEmpty) {
      return AttestationActionResult.failure(
        'Capture submission failed. Missing required fields: ${missingFields.join(', ')}.',
      );
    }
    await refreshWalletSuiBalance(force: true);
    if ((_walletSuiBalanceMist ?? BigInt.zero) <
        BigInt.from(AppConstants.minimumAttestationMistBalance)) {
      return AttestationActionResult.failure(
        'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting an attestation. Add test SUI and try again.',
      );
    }

    final result = await _captureWorkflowService.persistCapture(
      photoCaptureDataController: _dataControllers.photoCapture,
      identity: identity,
      session: session,
      sessionSigningKey: sessionSigningKey,
      temporaryImagePath: temporaryImagePath,
      projectId: projectId,
      tags: tags,
      note: note,
      capturedAtUtc: capturedAtUtc,
      submittedAtUtc: submittedAtUtc,
      buildLabel: buildLabel,
      gpsLabel: gpsLabel,
      altitudeLabel: altitudeLabel,
      cameraLabel: cameraLabel,
      cameraDetailsLabel: cameraDetailsLabel,
      onProgress: onProgress,
    );
    if (!result.isSuccess || result.record == null) {
      return result;
    }

    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: AttestationSubmissionStageState.active,
        message: 'Submitting the attestation transaction to Sui testnet.',
      ),
    );
    final record = await _submitPhotoAttestation(
      result.record!,
      sessionSigningKey: sessionSigningKey,
      gpsLabel: gpsLabel,
      altitudeLabel: altitudeLabel,
      projectId: projectId,
    );
    final submissionFailed = record.normalizedSuiSubmissionStatus.startsWith(
      'FAILED',
    );
    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: submissionFailed
            ? AttestationSubmissionStageState.failed
            : AttestationSubmissionStageState.completed,
        message: submissionFailed
            ? _attestationSubmissionFailureMessage(record)
            : 'Attestation transaction accepted by Sui.',
      ),
    );
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.active,
        message: 'Refreshing the on-device attestation ledger.',
      ),
    );
    final photoRecord = PhotoCaptureRecord.fromAttestationRecord(record);
    _lastAttestation = record;
    _lastPhotoCapture = photoRecord;
    _photoCaptureHistory = [
      photoRecord,
      ..._photoCaptureHistory.where(
        (item) => item.photoCaptureId != photoRecord.photoCaptureId,
      ),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _syncAttestationHistory();
    final seededVerification =
        _attestationVerifications[record.captureId] ??
        _localVerification(record);
    _attestationVerifications = {
      ..._attestationVerifications,
      record.captureId: seededVerification,
    };
    notifyListeners();
    if (record.isAttestationAnchored && !seededVerification.isVerified) {
      unawaited(verifyAttestationOnChain(record));
    }
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.completed,
        message: 'Local attestation history updated.',
      ),
    );
    return AttestationActionResult.success(record);
  }

  Future<AttestationActionResult> persistFileWithMetadata({
    required String sourceFilePath,
    required String sourceFileName,
    required int fileSizeBytes,
    required String mimeType,
    String? projectId,
    List<String> tags = const <String>[],
    String? note,
    DateTime? capturedAtUtc,
    DateTime? submittedAtUtc,
    String? buildLabel,
    void Function(AttestationSubmissionProgress progress)? onProgress,
  }) async {
    final identity = _identity;
    final session = _session;
    final sessionSigningKey = _sessionSigningKey;
    final claim = _photoAttestationClaim;
    if (identity == null) {
      return const AttestationActionResult.failure(
        'Device identity is unavailable.',
      );
    }
    if (session == null || !session.isActive) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure capture session has expired.',
      );
    }
    if (sessionSigningKey == null) {
      await endSession();
      return const AttestationActionResult.failure(
        'Your secure signing key is locked. Start a new session.',
      );
    }
    if (claim == null) {
      return const AttestationActionResult.failure(
        'Claim your on-chain user record before uploading a file for attestation.',
      );
    }

    final missingFields = <String>[
      if (sourceFilePath.trim().isEmpty) 'file_path',
      if (sourceFileName.trim().isEmpty) 'file_name',
      if (fileSizeBytes <= 0) 'file_size_bytes',
      if (mimeType.trim().isEmpty) 'mime_type',
      if (capturedAtUtc == null) 'captured_at',
      if (submittedAtUtc == null) 'submitted_at',
      if (projectId == null || projectId.trim().isEmpty) 'project_id',
    ];
    if (missingFields.isNotEmpty) {
      return AttestationActionResult.failure(
        'File attestation failed. Missing required fields: ${missingFields.join(', ')}.',
      );
    }

    await refreshWalletSuiBalance(force: true);
    if ((_walletSuiBalanceMist ?? BigInt.zero) <
        BigInt.from(AppConstants.minimumAttestationMistBalance)) {
      return AttestationActionResult.failure(
        'Your wallet needs at least ${AppConstants.minimumAttestationSuiBalance.toStringAsFixed(3)} SUI before submitting an attestation. Add test SUI and try again.',
      );
    }

    final result = await _captureWorkflowService.persistFile(
      uploadedFileDataController: _dataControllers.uploadedFile,
      identity: identity,
      session: session,
      sessionSigningKey: sessionSigningKey,
      sourceFilePath: sourceFilePath,
      sourceFileName: sourceFileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      projectId: projectId,
      tags: tags,
      note: note,
      capturedAtUtc: capturedAtUtc,
      submittedAtUtc: submittedAtUtc,
      buildLabel: buildLabel,
      domain: claim.domain,
      onProgress: onProgress,
    );
    if (!result.isSuccess || result.record == null) {
      return result;
    }

    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: AttestationSubmissionStageState.active,
        message: 'Submitting the file attestation transaction to Sui testnet.',
      ),
    );
    final record = await _submitFileAttestation(
      result.record!,
      sessionSigningKey: sessionSigningKey,
      projectId: projectId,
    );
    final submissionFailed = record.normalizedSuiSubmissionStatus.startsWith(
      'FAILED',
    );
    onProgress?.call(
      AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.submittingToChain,
        state: submissionFailed
            ? AttestationSubmissionStageState.failed
            : AttestationSubmissionStageState.completed,
        message: submissionFailed
            ? _attestationSubmissionFailureMessage(record)
            : 'File attestation transaction accepted by Sui.',
      ),
    );
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.active,
        message: 'Refreshing the on-device attestation ledger.',
      ),
    );
    final uploadedFile = UploadedFileRecord.fromAttestationRecord(record);
    _lastAttestation = record;
    _lastUploadedFile = uploadedFile;
    _uploadedFileHistory = [
      uploadedFile,
      ..._uploadedFileHistory.where(
        (item) => item.uploadedFileId != uploadedFile.uploadedFileId,
      ),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _syncAttestationHistory();
    final seededVerification =
        _attestationVerifications[record.captureId] ??
        _localVerification(record);
    _attestationVerifications = {
      ..._attestationVerifications,
      record.captureId: seededVerification,
    };
    notifyListeners();
    if (record.isAttestationAnchored && !seededVerification.isVerified) {
      unawaited(verifyAttestationOnChain(record));
    }
    onProgress?.call(
      const AttestationSubmissionProgress(
        stage: AttestationSubmissionStage.refreshingHistory,
        state: AttestationSubmissionStageState.completed,
        message: 'Local attestation history updated.',
      ),
    );
    return AttestationActionResult.success(record);
  }

  @override
  void dispose() {
    if (identical(_current, this)) {
      _current = null;
    }
    _sessionTicker?.cancel();
    unawaited(_dataControllers.dispose());
    super.dispose();
  }

  Future<void> _persistSelectedProject() async {
    await _dataControllers.config.saveSelectedProjectId(_selectedProjectId);
  }

  Future<void> _loadDatabaseState() async {
    final employeeRow = await _dataControllers.employee.loadPrimaryEmployee();
    final projectRows = await _dataControllers.project.loadProjects();
    final photoCaptureRows = await _dataControllers.photoCapture
        .loadPhotoCaptures();
    final uploadedFileRows = await _dataControllers.uploadedFile
        .loadUploadedFiles();
    final selectedProjectId = await _dataControllers.config
        .loadSelectedProjectId();
    _photoAttestationConfig = await _dataControllers.config
        .syncPhotoAttestationContractConfig();
    _photoAttestationClaim = await _dataControllers.config
        .loadPhotoAttestationClaim();

    _employee = employeeRow == null
        ? null
        : EmployeeRecord.fromJson(employeeRow);

    // Sync wallet address for existing employees if identity exists but employee doesn't have wallet
    if (_employee != null &&
        _identity != null &&
        _employee!.walletAddress.isEmpty) {
      await _dataControllers.employee.updateWalletAddress(
        _identity!.walletAddress,
      );
      final updatedRow = await _dataControllers.employee.loadPrimaryEmployee();
      _employee = updatedRow == null
          ? null
          : EmployeeRecord.fromJson(updatedRow);
    }
    _projects = projectRows.map(ProjectRecord.fromJson).toList(growable: false)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _photoCaptureHistory =
        photoCaptureRows
            .map(PhotoCaptureRecord.fromJson)
            .toList(growable: false)
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _uploadedFileHistory =
        uploadedFileRows
            .map(UploadedFileRecord.fromJson)
            .toList(growable: false)
          ..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    _lastPhotoCapture = _photoCaptureHistory.isEmpty
        ? null
        : _photoCaptureHistory.first;
    _lastUploadedFile = _uploadedFileHistory.isEmpty
        ? null
        : _uploadedFileHistory.first;
    _syncAttestationHistory();
    _lastAttestation = _attestationHistory.isEmpty
        ? null
        : _attestationHistory.first;
    _attestationVerifications = {
      for (final attestation in _attestationHistory)
        attestation.captureId: _localVerification(attestation),
    };
    _verificationRetryCounts = const {};

    final hasSavedSelection =
        selectedProjectId != null &&
        _projects.any((project) => project.projectId == selectedProjectId);
    _selectedProjectId = hasSavedSelection
        ? selectedProjectId
        : _projects.isEmpty
        ? null
        : _projects.first.projectId;
    _hasCompletedRegistration = _photoAttestationClaim != null;
    _requiresLocalDataInitialization = _employee == null;

    if (!hasSavedSelection || _selectedProjectId == null) {
      await _persistSelectedProject();
    }
  }

  Future<AttestationRecord> _submitPhotoAttestation(
    AttestationRecord record, {
    required SuiED25519PrivateKey sessionSigningKey,
    String? gpsLabel,
    String? altitudeLabel,
    String? projectId,
  }) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    final claim = _photoAttestationClaim;
    if (identity == null ||
        config == null ||
        claim == null ||
        !config.isComplete) {
      return _updateAttestationRecord(
        record,
        suiSubmissionStatus: 'FAILED_NOT_CONFIGURED',
        suiErrorMessage:
            'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
      );
    }

    try {
      final submission = await _photoAttestationService.attestPhoto(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        claim: claim,
        imageSha256: record.imageSha256,
        gps: gpsLabel?.trim().isNotEmpty == true ? gpsLabel!.trim() : 'UNKNOWN',
        altitude: altitudeLabel?.trim().isNotEmpty == true
            ? altitudeLabel!.trim()
            : 'UNKNOWN',
        projectId: projectId?.trim().isNotEmpty == true
            ? projectId!.trim()
            : 'UNASSIGNED',
      );
      final updated = await _updateAttestationRecord(
        record,
        suiTxDigest: submission.transactionDigest,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: submission.status,
        suiErrorMessage: '',
      );
      final verification = submission.verification;
      if (verification != null) {
        _attestationVerifications = {
          ..._attestationVerifications,
          record.captureId: AttestationChainVerificationRecord(
            state: verification.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: verification.transactionDigest,
            transactionStatus: verification.transactionStatus,
            photoHashMatches: verification.photoHashMatches,
            senderMatches: verification.senderMatches,
            gpsMatches: verification.gpsMatches,
            altitudeMatches: verification.altitudeMatches,
            projectIdMatches: verification.projectIdMatches,
            timestampWithinTolerance: verification.timestampWithinTolerance,
            chainTimestamp: verification.chainTimestamp,
            failureReason: verification.failureReason,
          ),
        };
      }
      return updated;
    } on PhotoAttestationException catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: error.userMessage,
      );
    } catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: 'The attestation transaction failed: $error',
      );
    }
  }

  Future<AttestationRecord> _submitFileAttestation(
    AttestationRecord record, {
    required SuiED25519PrivateKey sessionSigningKey,
    required String? projectId,
  }) async {
    final identity = _identity;
    final config = _photoAttestationConfig;
    final claim = _photoAttestationClaim;
    if (identity == null ||
        config == null ||
        claim == null ||
        !config.isComplete) {
      return _updateAttestationRecord(
        record,
        suiSubmissionStatus: 'FAILED_NOT_CONFIGURED',
        suiErrorMessage:
            'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
      );
    }

    try {
      final submission = await _photoAttestationService.attestFile(
        identity: identity,
        signingKey: sessionSigningKey,
        config: config,
        claim: claim,
        record: record,
        projectId: projectId?.trim().isNotEmpty == true
            ? projectId!.trim()
            : 'UNASSIGNED',
        timestampMs: record.effectiveSubmittedAt.millisecondsSinceEpoch,
      );
      final updated = await _updateAttestationRecord(
        record,
        suiTxDigest: submission.transactionDigest,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: submission.status,
        suiErrorMessage: '',
      );
      final verification = submission.verification;
      if (verification != null) {
        _attestationVerifications = {
          ..._attestationVerifications,
          record.captureId: AttestationChainVerificationRecord(
            state: verification.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: verification.transactionDigest,
            transactionStatus: verification.transactionStatus,
            photoHashMatches: verification.fileHashMatches,
            senderMatches: verification.senderMatches,
            projectIdMatches: verification.projectIdMatches,
            fileIdMatches: verification.fileIdMatches,
            timestampWithinTolerance: verification.timestampWithinTolerance,
            chainTimestamp: verification.chainTimestamp,
            failureReason: verification.failureReason,
          ),
        };
      }
      return updated;
    } on PhotoAttestationException catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: error.userMessage,
      );
    } catch (error) {
      return _updateAttestationRecord(
        record,
        suiObjectId: claim.userCapObjectId,
        suiSubmissionStatus: 'FAILED_SUBMISSION',
        suiErrorMessage: 'The attestation transaction failed: $error',
      );
    }
  }

  String _attestationSubmissionFailureMessage(AttestationRecord record) {
    return switch (record.normalizedSuiSubmissionStatus) {
      'FAILED_NOT_CONFIGURED' =>
        'Sui contract configuration is missing, so on-chain attestation could not be submitted.',
      'FAILED_SUBMISSION' =>
        record.attestationErrorLabel ??
            'The Sui attestation transaction failed. Check network access and wallet gas, then try again later.',
      _ =>
        record.attestationErrorLabel ??
            'The on-chain attestation did not complete successfully.',
    };
  }

  Future<void> verifyAttestationOnChain(AttestationRecord capture) async {
    final config = _photoAttestationConfig;
    if (config == null || !config.isComplete) {
      _attestationVerifications = {
        ..._attestationVerifications,
        capture.captureId: AttestationChainVerificationRecord(
          state: AttestationChainVerificationState.failed,
          checkedAt: DateTime.now().toUtc(),
          transactionDigest: capture.suiTxDigest,
          transactionStatus: capture.suiSubmissionStatus,
          failureReason: 'Contract config is unavailable.',
        ),
      };
      notifyListeners();
      return;
    }

    final baseline = _localVerification(capture);
    if (!capture.isAttestationAnchored) {
      final existing = _attestationVerifications[capture.captureId];
      if (existing == null || existing.state != baseline.state) {
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: baseline,
        };
        notifyListeners();
      }
      return;
    }

    _attestationVerifications = {
      ..._attestationVerifications,
      capture.captureId: AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      ),
    };
    notifyListeners();

    try {
      if (capture.isFile) {
        final result = await _photoAttestationService.verifyFileAttestation(
          config: config,
          capture: capture,
        );
        final shouldRetry =
            !result.isVerified &&
            _shouldRetryChainVerification(result.failureReason);
        if (shouldRetry && _scheduleVerificationRetry(capture)) {
          _attestationVerifications = {
            ..._attestationVerifications,
            capture.captureId: AttestationChainVerificationRecord(
              state: AttestationChainVerificationState.pending,
              checkedAt: DateTime.now().toUtc(),
              transactionDigest: result.transactionDigest,
              transactionStatus: result.transactionStatus,
              failureReason: result.failureReason,
            ),
          };
          notifyListeners();
          return;
        }
        _clearVerificationRetry(capture.captureId);
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: result.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: result.transactionDigest,
            transactionStatus: result.transactionStatus,
            photoHashMatches: result.fileHashMatches,
            senderMatches: result.senderMatches,
            projectIdMatches: result.projectIdMatches,
            fileIdMatches: result.fileIdMatches,
            timestampWithinTolerance: result.timestampWithinTolerance,
            chainTimestamp: result.chainTimestamp,
            failureReason: result.failureReason,
          ),
        };
      } else {
        final result = await _photoAttestationService.verifyPhotoAttestation(
          config: config,
          capture: capture,
        );
        final shouldRetry =
            !result.isVerified &&
            _shouldRetryChainVerification(result.failureReason);
        if (shouldRetry && _scheduleVerificationRetry(capture)) {
          _attestationVerifications = {
            ..._attestationVerifications,
            capture.captureId: AttestationChainVerificationRecord(
              state: AttestationChainVerificationState.pending,
              checkedAt: DateTime.now().toUtc(),
              transactionDigest: result.transactionDigest,
              transactionStatus: result.transactionStatus,
              failureReason: result.failureReason,
            ),
          };
          notifyListeners();
          return;
        }
        _clearVerificationRetry(capture.captureId);
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: result.isVerified
                ? AttestationChainVerificationState.verified
                : AttestationChainVerificationState.mismatched,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: result.transactionDigest,
            transactionStatus: result.transactionStatus,
            photoHashMatches: result.photoHashMatches,
            senderMatches: result.senderMatches,
            gpsMatches: result.gpsMatches,
            altitudeMatches: result.altitudeMatches,
            projectIdMatches: result.projectIdMatches,
            timestampWithinTolerance: result.timestampWithinTolerance,
            chainTimestamp: result.chainTimestamp,
            failureReason: result.failureReason,
          ),
        };
      }
    } catch (error) {
      if (_shouldRetryChainVerification('$error') &&
          _scheduleVerificationRetry(capture)) {
        _attestationVerifications = {
          ..._attestationVerifications,
          capture.captureId: AttestationChainVerificationRecord(
            state: AttestationChainVerificationState.pending,
            checkedAt: DateTime.now().toUtc(),
            transactionDigest: capture.suiTxDigest,
            transactionStatus: capture.suiSubmissionStatus,
            failureReason: '$error',
          ),
        };
        notifyListeners();
        return;
      }
      _clearVerificationRetry(capture.captureId);
      // Reaching this catch block means the verification round-trip itself
      // never completed (network error, timeout, indexer lag, etc.) — it is
      // not evidence the on-chain attestation failed. A genuine on-chain
      // failure comes back as a normal (non-throwing) result with
      // transactionStatus != 'SUCCESS', handled separately above. So we
      // leave this as pending rather than flipping it to a hard "failed",
      // which previously caused the status to flash failed on every
      // exhausted retry even when the device simply had no connection.
      _attestationVerifications = {
        ..._attestationVerifications,
        capture.captureId: AttestationChainVerificationRecord(
          state: AttestationChainVerificationState.pending,
          checkedAt: DateTime.now().toUtc(),
          transactionDigest: capture.suiTxDigest,
          transactionStatus: capture.suiSubmissionStatus,
          failureReason:
              'Could not reach the network to verify this attestation. '
              'It will be re-checked automatically once a connection is '
              'available. ($error)',
        ),
      };
    }
    notifyListeners();
  }

  bool _shouldRetryChainVerification(String? failureReason) {
    final reason = (failureReason ?? '').trim().toLowerCase();
    if (reason.isEmpty) {
      return false;
    }
    return reason.contains('event not found') ||
        reason.contains('transaction block not found') ||
        reason.contains('not found for digest') ||
        reason.contains('not indexed') ||
        reason.contains('temporar') ||
        reason.contains('timeout') ||
        reason.contains('socket') ||
        reason.contains('network');
  }

  bool _scheduleVerificationRetry(AttestationRecord capture) {
    final captureId = capture.captureId;
    final attempt = (_verificationRetryCounts[captureId] ?? 0) + 1;
    const maxAttempts = 5;
    if (attempt > maxAttempts) {
      return false;
    }
    _verificationRetryCounts = {
      ..._verificationRetryCounts,
      captureId: attempt,
    };

    final delay = Duration(seconds: attempt * 3);
    Future<void>.delayed(delay, () async {
      final latest = _attestationHistory
          .where((item) => item.captureId == captureId)
          .firstOrNull;
      if (latest == null || !latest.isAttestationAnchored) {
        _clearVerificationRetry(captureId);
        return;
      }
      await verifyAttestationOnChain(latest);
    });

    return true;
  }

  void _clearVerificationRetry(String captureId) {
    if (!_verificationRetryCounts.containsKey(captureId)) {
      return;
    }
    final next = {..._verificationRetryCounts};
    next.remove(captureId);
    _verificationRetryCounts = next;
  }

  Future<void> verifyAttestationsOnChain(
    Iterable<AttestationRecord> captures,
  ) async {
    for (final capture in captures) {
      final current = _attestationVerifications[capture.captureId];
      if (current?.isVerified == true) {
        continue;
      }
      unawaited(verifyAttestationOnChain(capture));
    }
  }

  AttestationChainVerificationRecord _localVerification(
    AttestationRecord capture,
  ) {
    if (capture.isAttestationAnchored) {
      return AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    if (capture.isAttestationPending) {
      return AttestationChainVerificationRecord(
        state: AttestationChainVerificationState.pending,
        checkedAt: DateTime.now().toUtc(),
        transactionDigest: capture.suiTxDigest,
        transactionStatus: capture.suiSubmissionStatus,
      );
    }
    return AttestationChainVerificationRecord(
      state: AttestationChainVerificationState.failed,
      checkedAt: DateTime.now().toUtc(),
      transactionDigest: capture.suiTxDigest,
      transactionStatus: capture.suiSubmissionStatus,
      failureReason: capture.suiSubmissionStatus,
    );
  }

  Future<AttestationRecord> _updateAttestationRecord(
    AttestationRecord record, {
    String? suiTxDigest,
    String? suiObjectId,
    String? suiSubmissionStatus,
    String? suiErrorMessage,
  }) async {
    final updated = AttestationRecord(
      captureId: record.captureId,
      capturedAt: record.capturedAt,
      submittedAt: record.submittedAt,
      imagePath: record.imagePath,
      imageSha256: record.imageSha256,
      signatureBase64: record.signatureBase64,
      walletAddress: record.walletAddress,
      publicKeyHex: record.publicKeyHex,
      proofPayload: record.proofPayload,
      suiTxDigest: suiTxDigest ?? record.suiTxDigest,
      suiObjectId: suiObjectId ?? record.suiObjectId,
      suiSubmissionStatus: suiSubmissionStatus ?? record.suiSubmissionStatus,
      suiErrorMessage: suiErrorMessage ?? record.suiErrorMessage,
      projectId: record.projectId,
      tags: record.tags,
      note: record.note,
      assetType: record.assetType,
      fileName: record.fileName,
      mimeType: record.mimeType,
      fileSizeBytes: record.fileSizeBytes,
      fileExtension: record.fileExtension,
      previewKind: record.previewKind,
      storageMode: record.storageMode,
    );
    if (updated.isFile) {
      final uploadedFile = UploadedFileRecord.fromAttestationRecord(updated);
      await _dataControllers.uploadedFile.saveUploadedFile(
        uploadedFile.toJson(),
      );
      _lastUploadedFile = uploadedFile;
      _uploadedFileHistory = [
        uploadedFile,
        ..._uploadedFileHistory.where(
          (item) => item.uploadedFileId != uploadedFile.uploadedFileId,
        ),
      ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    } else {
      final photoCapture = PhotoCaptureRecord.fromAttestationRecord(updated);
      await _dataControllers.photoCapture.savePhotoCapture(
        photoCapture.toJson(),
      );
      _lastPhotoCapture = photoCapture;
      _photoCaptureHistory = [
        photoCapture,
        ..._photoCaptureHistory.where(
          (item) => item.photoCaptureId != photoCapture.photoCaptureId,
        ),
      ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
    }
    _syncAttestationHistory();
    _lastAttestation = _attestationHistory.isEmpty
        ? null
        : _attestationHistory.first;
    return updated;
  }

  void _syncAttestationHistory() {
    _attestationHistory = [
      ..._photoCaptureHistory.map((item) => item.toAttestationRecord()),
      ..._uploadedFileHistory.map((item) => item.toAttestationRecord()),
    ]..sort((a, b) => b.capturedAt.compareTo(a.capturedAt));
  }

  String _generateProjectId(String title) {
    final random = Random.secure();

    while (true) {
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;

      final hex = bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final candidate = [
        hex.substring(0, 8),
        hex.substring(8, 12),
        hex.substring(12, 16),
        hex.substring(16, 20),
        hex.substring(20, 32),
      ].join('-');

      final exists = _projects.any((project) => project.projectId == candidate);
      if (!exists) {
        return candidate;
      }
    }
  }

  void _applySecureInitializationState(SecureInitializationState state) {
    _hasCompletedRegistration = state.hasCompletedRegistration;
    _deviceRegistration = state.deviceRegistration;
    _identity = state.identity;
    _photoAttestationClaim = state.photoAttestationClaim;
    _biometricBinding = state.biometricBinding;
    _biometricGatePayload = state.biometricGatePayload;
    _resetNotice = state.resetNotice;
    _clearLocalSessionState();
  }

  ActionResult _toActionResult<T>(SecureOperationResult<T> result) {
    if (result.isSuccess) {
      return const ActionResult.success();
    }
    if (result.code != null) {
      return ActionResult.failureWithCode(
        result.code!,
        result.message ?? 'Operation failed.',
      );
    }
    return ActionResult.failure(result.message ?? 'Operation failed.');
  }

  void _clearLocalBiometricSessionState({bool clearIdentity = false}) {
    _biometricBinding = null;
    _biometricGatePayload = null;
    _clearLocalSessionState();
    if (clearIdentity) {
      _identity = null;
    }
  }

  void _clearLocalSessionState() {
    _sessionTicker?.cancel();
    _sessionTicker = null;
    _sessionSigningKey = null;
    _session = null;
  }

  void _syncSessionTicker() {
    _sessionTicker?.cancel();
    final session = _session;
    if (session == null || !session.isActive) {
      _sessionTicker = null;
      return;
    }

    _sessionTicker = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!hasActiveSession) {
        timer.cancel();
        await endSession();
        return;
      }
      notifyListeners();
    });
  }
}
