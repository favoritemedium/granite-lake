import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/utils.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/location_settings.dart';

enum _CaptureFlow { live, review, submitting, success }

class _LocationSnapshot {
  const _LocationSnapshot({
    required this.gpsLabel,
    required this.altitudeLabel,
  });

  final String gpsLabel;
  final String altitudeLabel;
}

class _CaptureMetadataSnapshot {
  const _CaptureMetadataSnapshot({
    required this.capturedAtUtc,
    this.submittedAtUtc,
    required this.buildLabel,
    required this.gpsLabel,
    required this.altitudeLabel,
    required this.cameraLabel,
    required this.cameraDetailsLabel,
    required this.networkLabel,
  });

  final DateTime capturedAtUtc;
  final DateTime? submittedAtUtc;
  final String buildLabel;
  final String gpsLabel;
  final String altitudeLabel;
  final String cameraLabel;
  final String cameraDetailsLabel;
  final String networkLabel;
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  static const _tags = ['STRUCTURAL', 'EROSION', 'HAZARD', 'COMPLIANCE'];

  CameraController? _cameraController;
  List<CameraDescription> _cameras = const [];
  int _selectedCameraIndex = 0;
  bool _isPreparing = true;
  bool _isCapturing = false;
  bool _isFlashEnabled = false;
  String? _errorMessage;
  String _buildLabel =
      '${AppConstants.appVersion} (${AppConstants.appVersion})';
  String _gpsStatusLabel = 'Locating...';
  String _altitudeStatusLabel = 'Altitude unavailable';
  String _networkStatusLabel = 'Checking...';
  bool _isMockLocationDetected = false;
  Timer? _networkTimer;
  // Raw exception from the last failed GPS fix, shown verbatim in the
  // capture-blocked panel so it can be diagnosed on-device without adb.
  // Kept separate from _gpsStatusLabel: that field is embedded directly in
  // the forensic capture metadata and gates _hasGpsFix via a ", " check, so
  // it must stay a clean status string, never raw error text.
  String? _gpsDebugError;
  // On GrapheneOS without Sandboxed Google Play there is no network location
  // provider at all (by design - see grapheneos.org/usage and
  // https://discuss.grapheneos.org/d/79-location-not-working), so every fix
  // is a raw GPS cold start: 2-5+ minutes outdoors is normal, confirmed by
  // GrapheneOS's own team. Restarting that request from scratch every 30s
  // (the readiness timer's interval) would thrash it and could make the fix
  // take even longer, so skip relaunching _refreshLocation while one is
  // already in flight - let it run to its own (patient) timeLimit instead.
  bool _isFetchingLocation = false;

  _CaptureFlow _flow = _CaptureFlow.live;
  int _submissionRunId = 0;
  Future<void> _submissionProgressQueue = Future<void>.value();
  String? _stagedImagePath;
  AttestationRecord? _latestRecord;
  _CaptureMetadataSnapshot? _stagedMetadata;
  _CaptureMetadataSnapshot? _latestMetadata;
  final TextEditingController _noteController = TextEditingController();
  String _selectedTag = 'STRUCTURAL';
  int _submissionStep = 0;
  AttestationSubmissionStage? _activeSubmissionStage;
  String _submissionProgressMessage =
      'Preparing secure capture and attestation steps.';
  final Map<AttestationSubmissionStage, AttestationSubmissionStageState>
  _submissionStageStates = {
    for (final stage in AttestationSubmissionStage.values)
      stage: AttestationSubmissionStageState.pending,
  };

  @override
  void initState() {
    super.initState();
    debugPrint('[READINESS] initState @${DateTime.now().toIso8601String()}');
    _startClock();
    unawaited(_loadBuildInfo());
    // Deferred to a microtask: _refreshCaptureReadiness -> _refreshBackendStatus
    // calls GraniteLakeScope.of(context), an inherited-widget lookup that
    // Flutter forbids calling synchronously before initState() returns.
    // Future.wait's list literal evaluates both branches synchronously, so
    // calling this directly here throws every time the screen opens
    // (silently, since nothing awaits it) and only ever succeeds once
    // something else re-triggers the check later (the 30s timer or a manual
    // retry) — which read as "network always fails on first load."
    unawaited(Future.microtask(_refreshCaptureReadiness));
    _prepareCamera();
  }

  @override
  void dispose() {
    _networkTimer?.cancel();
    _noteController.dispose();
    _cameraController?.dispose();
    _deleteStagedImageIfNeeded();
    super.dispose();
  }

  void _resetSubmissionProgress() {
    _submissionProgressQueue = Future<void>.value();
    _submissionStep = 0;
    _activeSubmissionStage = null;
    _submissionProgressMessage =
        'Preparing secure capture and attestation steps.';
    for (final stage in AttestationSubmissionStage.values) {
      _submissionStageStates[stage] = AttestationSubmissionStageState.pending;
    }
  }

  void _startClock() {
    _networkTimer?.cancel();
    _networkTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_refreshCaptureReadiness());
    });
  }

  Future<void> _loadBuildInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) {
        return;
      }
      setState(() {
        _buildLabel = '${packageInfo.version} (${packageInfo.buildNumber})';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _buildLabel = AppConstants.appVersion;
      });
    }
  }

  Future<_LocationSnapshot?> _refreshLocation() async {
    if (_isFetchingLocation) {
      debugPrint('[READINESS] _refreshLocation skipped - already in flight');
      return null;
    }
    _isFetchingLocation = true;
    final sw = Stopwatch()..start();
    debugPrint(
      '[READINESS] _refreshLocation start @${DateTime.now().toIso8601String()}',
    );
    try {
      if (mounted) {
        setState(() {
          _gpsStatusLabel = 'Locating...';
          _altitudeStatusLabel = 'Fetching altitude...';
          _isMockLocationDetected = false;
          _gpsDebugError = null;
        });
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      debugPrint(
        '[READINESS] isLocationServiceEnabled=$serviceEnabled elapsed=${sw.elapsedMilliseconds}ms',
      );
      if (!serviceEnabled) {
        if (!mounted) {
          return null;
        }
        setState(() {
          _gpsStatusLabel = 'Location off';
          _altitudeStatusLabel = 'Altitude unavailable';
          _isMockLocationDetected = false;
        });
        return null;
      }

      var permission = await Geolocator.checkPermission();
      debugPrint(
        '[READINESS] checkPermission=$permission elapsed=${sw.elapsedMilliseconds}ms',
      );
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        debugPrint(
          '[READINESS] requestPermission=$permission elapsed=${sw.elapsedMilliseconds}ms',
        );
      }

      if (permission == LocationPermission.denied) {
        if (!mounted) {
          return null;
        }
        setState(() {
          _gpsStatusLabel = 'Permission denied';
          _altitudeStatusLabel = 'Altitude unavailable';
          _isMockLocationDetected = false;
        });
        return null;
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) {
          return null;
        }
        setState(() {
          _gpsStatusLabel = 'Permission blocked';
          _altitudeStatusLabel = 'Altitude unavailable';
          _isMockLocationDetected = false;
        });
        return null;
      }

      debugPrint(
        '[READINESS] calling getCurrentPosition elapsed=${sw.elapsedMilliseconds}ms',
      );
      // A raw GPS cold fix (no network/Play Services assistance, e.g. on
      // GrapheneOS without Sandboxed Google Play) is confirmed by GrapheneOS's
      // own team to normally take 2-5+ minutes outdoors on first use. No
      // timeLimit would hang forever with nothing to show; too short a one
      // (e.g. 30s) would misreport that normal wait as a failure. 2 minutes
      // balances the two - still bounded, but won't fire on a healthy fix.
      final position = await Geolocator.getCurrentPosition(
        locationSettings: resolveLocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(minutes: 2),
        ),
      );
      debugPrint(
        '[READINESS] getCurrentPosition -> lat=${position.latitude} lng=${position.longitude} elapsed=${sw.elapsedMilliseconds}ms',
      );
      final snapshot = _LocationSnapshot(
        gpsLabel: _formatPosition(position),
        altitudeLabel: _formatAltitude(position),
      );
      final isMockLocationDetected = _detectMockLocation(position);
      debugPrint(
        'Geolocator mock status: ${isMockLocationDetected ? 'mocked' : 'not mocked'}',
      );
      if (!mounted) {
        return snapshot;
      }
      setState(() {
        _gpsStatusLabel = snapshot.gpsLabel;
        _altitudeStatusLabel = snapshot.altitudeLabel;
        _isMockLocationDetected = isMockLocationDetected;
      });
      debugPrint(
        '[READINESS] _refreshLocation DONE (success) totalElapsed=${sw.elapsedMilliseconds}ms',
      );
      return snapshot;
    } catch (error, stack) {
      debugPrint(
        '[READINESS] _refreshLocation FAILED error=$error (${error.runtimeType}) totalElapsed=${sw.elapsedMilliseconds}ms\n$stack',
      );
      if (!mounted) {
        return null;
      }
      setState(() {
        // A GPS-only cold fix (no network/Play Services assistance) can
        // legitimately take several minutes - a timeout here just means
        // "still trying," not "broken." Say so instead of implying failure.
        // The 30s/15s readiness timers keep retrying automatically either way.
        // No ", " anywhere in this string - _hasGpsFix below treats that
        // substring as "looks like a real lat/lng fix" and would wrongly
        // unblock capture without one.
        _gpsStatusLabel = error is TimeoutException
            ? 'Still acquiring GPS - first fix outdoors can take a few minutes'
            : 'GPS unavailable';
        _altitudeStatusLabel = 'Altitude unavailable';
        _isMockLocationDetected = false;
        _gpsDebugError = '${error.runtimeType}: $error';
      });
      return null;
    } finally {
      _isFetchingLocation = false;
    }
  }

  Future<DateTime?> _fetchBackendUtcTimestamp() async {
    final domain = GraniteLakeScope.of(context).employee?.companyDomain;
    if (domain == null || domain.isEmpty) {
      return null;
    }
    return await AppUtils.fetchBackendUtcTimestamp(domain: domain);
  }

  Future<void> _refreshBackendStatus() async {
    final sw = Stopwatch()..start();
    debugPrint(
      '[READINESS] _refreshBackendStatus start @${DateTime.now().toIso8601String()}',
    );
    if (mounted) {
      setState(() => _networkStatusLabel = 'Checking...');
    }

    final domain = GraniteLakeScope.of(context).employee?.companyDomain;
    debugPrint(
      '[READINESS] domain="$domain" elapsed=${sw.elapsedMilliseconds}ms',
    );
    if (domain == null || domain.isEmpty) {
      debugPrint('[READINESS] _refreshBackendStatus: no domain, bailing');
      if (mounted) {
        setState(() => _networkStatusLabel = 'Offline');
      }
      return;
    }

    try {
      final connected = await AppUtils.hasBackendConnectivity(domain: domain);
      debugPrint(
        '[READINESS] _refreshBackendStatus DONE connected=$connected totalElapsed=${sw.elapsedMilliseconds}ms',
      );
      if (!mounted) return;
      setState(() {
        _networkStatusLabel = connected ? 'Connected' : 'Offline';
      });
    } catch (error, stack) {
      debugPrint(
        '[READINESS] _refreshBackendStatus FAILED error=$error (${error.runtimeType}) totalElapsed=${sw.elapsedMilliseconds}ms\n$stack',
      );
      if (!mounted) return;
      setState(() {
        _networkStatusLabel = 'Offline';
      });
    }
  }

  Future<void> _refreshCaptureReadiness() async {
    debugPrint(
      '[READINESS] _refreshCaptureReadiness start @${DateTime.now().toIso8601String()}',
    );
    await Future.wait([_refreshLocation(), _refreshBackendStatus()]);
    debugPrint(
      '[READINESS] _refreshCaptureReadiness ALL DONE @${DateTime.now().toIso8601String()}',
    );
  }

  Future<void> _prepareCamera() async {
    setState(() {
      _isPreparing = true;
      _errorMessage = null;
    });

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No device cameras are available.');
      }

      final preferredIndex = cameras.indexWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      final resolvedIndex = preferredIndex == -1 ? 0 : preferredIndex;
      await _openCamera(cameras, resolvedIndex);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isPreparing = false;
        _errorMessage = '$error';
      });
    }
  }

  Future<void> _openCamera(List<CameraDescription> cameras, int index) async {
    await _cameraController?.dispose();
    final camera = cameras[index];
    final nextController = CameraController(
      camera,
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await nextController.initialize();
    if (_isFlashEnabled) {
      try {
        await nextController.setFlashMode(FlashMode.torch);
      } catch (_) {}
    }
    if (!mounted) {
      await nextController.dispose();
      return;
    }

    setState(() {
      _cameras = cameras;
      _selectedCameraIndex = index;
      _cameraController = nextController;
      _isPreparing = false;
      _errorMessage = null;
    });
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 ||
        _isPreparing ||
        _isCapturing ||
        _flow != _CaptureFlow.live) {
      return;
    }

    final nextIndex = (_selectedCameraIndex + 1) % _cameras.length;
    setState(() => _isPreparing = true);
    try {
      await _openCamera(_cameras, nextIndex);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isPreparing = false;
        _errorMessage = '$error';
      });
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final nextValue = !_isFlashEnabled;
    try {
      await controller.setFlashMode(
        nextValue ? FlashMode.torch : FlashMode.off,
      );
      if (!mounted) {
        return;
      }
      setState(() => _isFlashEnabled = nextValue);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Flash control is unavailable on this camera.';
      });
    }
  }

  Future<void> _capturePhoto() async {
    final appController = GraniteLakeScope.of(context);
    if (!appController.hasProjects) {
      await _showMissingProjectsDialog();
      return;
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isCapturing) {
      return;
    }
    if (!_hasGpsFix || !_hasNetworkConnectivity || _isMockLocationDetected) {
      setState(() {
        _errorMessage = _captureBlockedMessage;
      });
      return;
    }

    setState(() {
      _isCapturing = true;
      _errorMessage = null;
    });

    try {
      final capturedAtUtc = await _fetchBackendUtcTimestamp();
      if (capturedAtUtc == null) {
        throw const HttpException('Backend UTC timestamp unavailable.');
      }
      final imageFile = await controller.takePicture();
      if (!mounted) {
        return;
      }

      await _deleteStagedImageIfNeeded();
      setState(() {
        _isCapturing = false;
        _stagedImagePath = imageFile.path;
        _stagedMetadata = _buildMetadataSnapshot(capturedAtUtc);
        _flow = _CaptureFlow.review;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCapturing = false;
        _errorMessage = '$error';
      });
    }
  }

  Future<void> _discardStagedCapture() async {
    await _deleteStagedImageIfNeeded();
    if (!mounted) {
      return;
    }

    setState(() {
      _flow = _CaptureFlow.live;
      _errorMessage = null;
      _submissionStep = 0;
      _stagedMetadata = null;
      _noteController.clear();
      _selectedTag = 'STRUCTURAL';
    });
  }

  Future<void> _submitCapture() async {
    final stagedImagePath = _stagedImagePath;
    if (stagedImagePath == null || _isCapturing) {
      return;
    }

    final appController = GraniteLakeScope.of(context);
    if (!appController.hasProjects) {
      await _showMissingProjectsDialog();
      return;
    }
    final selectedProject = appController.selectedProject;
    if (selectedProject == null) {
      setState(() {
        _errorMessage =
            'Select an active project before submitting this capture.';
      });
      return;
    }
    final metadata = _stagedMetadata;
    if (metadata == null ||
        selectedProject.projectId.trim().isEmpty ||
        metadata.gpsLabel.trim().isEmpty ||
        metadata.altitudeLabel.trim().isEmpty) {
      setState(() {
        _errorMessage =
            'Submission failed. Captured time, GPS, altitude, and project id are required.';
      });
      return;
    }

    setState(() {
      _resetSubmissionProgress();
      _isCapturing = true;
      _errorMessage = null;
      _flow = _CaptureFlow.submitting;
    });
    final submissionRunId = ++_submissionRunId;

    // final currentLocation = await _refreshLocation();
    // if (currentLocation == null ||
    //     !_matchesFormattedGps(currentLocation.gpsLabel, metadata.gpsLabel) ||
    //     !_matchesFormattedAltitude(
    //       currentLocation.altitudeLabel,
    //       metadata.altitudeLabel,
    //     )) {
    //   if (!mounted) {
    //     return;
    //   }
    //   setState(() {
    //     _isCapturing = false;
    //     _flow = _CaptureFlow.review;
    //     _submissionStep = 0;
    //     _errorMessage =
    //         'Submission failed. GPS or altitude changed since capture. Retake the photo and try again.';
    //   });
    //   return;
    // }

    final submittedAtUtc = await _fetchBackendUtcTimestamp();
    if (submittedAtUtc == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isCapturing = false;
        _flow = _CaptureFlow.review;
        _submissionStep = 0;
        _errorMessage = 'Backend UTC timestamp unavailable.';
      });
      return;
    }
    final result = await appController.persistCaptureWithMetadata(
      stagedImagePath,
      projectId: selectedProject.projectId,
      tags: [_selectedTag],
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
      capturedAtUtc: metadata.capturedAtUtc,
      submittedAtUtc: submittedAtUtc,
      buildLabel: metadata.buildLabel,
      gpsLabel: metadata.gpsLabel,
      altitudeLabel: metadata.altitudeLabel,
      cameraLabel: metadata.cameraLabel,
      cameraDetailsLabel: metadata.cameraDetailsLabel,
      onProgress: (progress) {
        unawaited(_applySubmissionProgress(progress, submissionRunId));
      },
    );
    if (!mounted) {
      return;
    }

    if (!result.isSuccess || result.record == null) {
      await _submissionProgressQueue;
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      _submissionRunId++;
      if (!mounted) {
        return;
      }
      setState(() {
        _isCapturing = false;
        _flow = _CaptureFlow.review;
        _submissionStep = 0;
        _errorMessage = result.message;
      });
      return;
    }

    await _submissionProgressQueue;
    _submissionRunId++;
    setState(() {
      _stagedImagePath = null;
      _latestRecord = result.record;
      _latestMetadata = _CaptureMetadataSnapshot(
        capturedAtUtc: metadata.capturedAtUtc,
        submittedAtUtc: submittedAtUtc,
        buildLabel: metadata.buildLabel,
        gpsLabel: metadata.gpsLabel,
        altitudeLabel: metadata.altitudeLabel,
        cameraLabel: metadata.cameraLabel,
        cameraDetailsLabel: metadata.cameraDetailsLabel,
        networkLabel: metadata.networkLabel,
      );
      _stagedMetadata = null;
    });

    final shouldPauseForFailure = result.record!.normalizedSuiSubmissionStatus
        .startsWith('FAILED');
    await Future<void>.delayed(
      Duration(milliseconds: shouldPauseForFailure ? 1600 : 900),
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _isCapturing = false;
      _flow = _CaptureFlow.success;
    });
  }

  Future<void> _applySubmissionProgress(
    AttestationSubmissionProgress progress,
    int runId,
  ) {
    _submissionProgressQueue = _submissionProgressQueue.then((_) async {
      if (!mounted || _submissionRunId != runId) {
        return;
      }

      setState(() {
        _submissionStageStates[progress.stage] = progress.state;
        _activeSubmissionStage = progress.stage;
        _submissionProgressMessage = progress.message ?? _submissionDetail;
        final stageIndex =
            AttestationSubmissionStage.values.indexOf(progress.stage) + 1;
        if (stageIndex > _submissionStep) {
          _submissionStep = stageIndex;
        }
      });

      final delay = switch (progress.state) {
        AttestationSubmissionStageState.active => const Duration(
          milliseconds: 1200,
        ),
        AttestationSubmissionStageState.completed => const Duration(
          milliseconds: 900,
        ),
        AttestationSubmissionStageState.failed => const Duration(
          milliseconds: 1400,
        ),
        AttestationSubmissionStageState.pending => Duration.zero,
      };
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
    });
    return _submissionProgressQueue;
  }

  Future<void> _showMissingProjectsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Text(
            'No Projects Created',
            style: AppTextStyles.headlineMedium,
          ),
          content: Text(
            'Create and select a project before opening or submitting a verified capture.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                'CLOSE',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copyProofBundle() async {
    final record = _latestRecord;
    final metadata = _latestMetadata;
    if (record == null || metadata == null) {
      return;
    }

    final payload = [
      'App Build: ${metadata.buildLabel}',
      'Capture ID: ${record.captureId}',
      'Captured At (UTC): ${metadata.capturedAtUtc.toIso8601String()}',
      'Submitted At (UTC): ${(metadata.submittedAtUtc ?? record.effectiveSubmittedAt).toIso8601String()}',
      'GPS: ${metadata.gpsLabel}',
      'Altitude: ${metadata.altitudeLabel}',
      'Network: ${metadata.networkLabel}',
      'Camera: ${metadata.cameraLabel}',
      'Camera Details: ${metadata.cameraDetailsLabel}',
      'SHA-256: ${record.imageSha256}',
      'UserCap ID: ${record.suiObjectId}',
      'Sui Transaction Digest: ${record.suiTxDigest}',
      'Sui Submission Status: ${record.suiSubmissionStatus}',
      if (record.attestationErrorLabel != null)
        'Sui Attestation Error: ${record.attestationErrorLabel}',
      if (record.proofPayload.readString('sessionStartedAt') != null)
        'Session Started: ${record.proofPayload.readString('sessionStartedAt')}',
      if (record.proofPayload.readString('sessionExpiresAt') != null)
        'Session Expires: ${record.proofPayload.readString('sessionExpiresAt')}',
    ].join('\n');

    await Clipboard.setData(ClipboardData(text: payload));
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Proof bundle copied')));
  }

  Future<void> _deleteStagedImageIfNeeded() async {
    final stagedImagePath = _stagedImagePath;
    if (stagedImagePath == null) {
      return;
    }

    final file = File(stagedImagePath);
    if (await file.exists()) {
      await file.delete();
    }
    _stagedImagePath = null;
  }

  @override
  Widget build(BuildContext context) {
    final appController = GraniteLakeScope.of(context);
    final session = appController.session;
    final identity = appController.identity;
    final isCompact = MediaQuery.sizeOf(context).height < 760;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: switch (_flow) {
            _CaptureFlow.live => _buildLiveCapture(
              context,
              appController,
              session,
              identity,
              isCompact,
            ),
            _CaptureFlow.review => _buildReviewScreen(
              context,
              appController,
              identity,
            ),
            _CaptureFlow.submitting => _buildSubmissionScreen(context),
            _CaptureFlow.success => _buildSuccessScreen(context, identity),
          },
        ),
      ),
    );
  }

  Widget _buildLiveCapture(
    BuildContext context,
    GraniteLakeController appController,
    SessionRecord? session,
    IdentityRecord? identity,
    bool isCompact,
  ) {
    final countdown = _formatShortDuration(
      appController.remainingSessionDuration,
    );
    final liveCameraLabel = _cameraLabel;
    final liveCameraDetails = _cameraDetailsLabel;
    final canCapture =
        !_isPreparing &&
        !_isCapturing &&
        _hasGpsFix &&
        _hasNetworkConnectivity &&
        !_isMockLocationDetected;

    return Column(
      key: const ValueKey('live-capture'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 10,
                    color: session == null
                        ? AppColors.statusError
                        : AppColors.statusError,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    countdown,
                    style: AppTextStyles.labelLarge.copyWith(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  'LIVE VERIFIED CAPTURE',
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.labelLarge.copyWith(
                    color: AppColors.textPrimary,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _IdentityBadge(
                    initials: _resolveInitials(identity?.walletAddress),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.verified_rounded,
                    color: AppColors.statusActive,
                    size: 20,
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: ColoredBox(
                      color: Colors.black,
                      child: _buildPreview(),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x99000000),
                            Colors.transparent,
                            Color(0xB3000000),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _ViewfinderPainter()),
                  ),
                ),
                if (_errorMessage != null)
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 24,
                    child: _ErrorBanner(message: _errorMessage!),
                  ),
                if (!_isPreparing && _errorMessage == null) ...[
                  Positioned(
                    left: 28,
                    top: isCompact ? 120 : 160,
                    child: _LabeledMetric(label: 'GPS', value: _gpsStatusLabel),
                  ),
                  Positioned(
                    left: 28,
                    top: isCompact ? 184 : 236,
                    child: _LabeledMetric(
                      label: 'ALTITUDE',
                      value: _altitudeStatusLabel,
                    ),
                  ),
                  Positioned(
                    right: 28,
                    top: isCompact ? 120 : 160,
                    child: _LabeledMetric(
                      label: 'REAR CAMERA',
                      value: liveCameraLabel,
                      alignEnd: true,
                    ),
                  ),
                  Positioned(
                    right: 28,
                    top: isCompact ? 184 : 236,
                    child: _LabeledMetric(
                      label: 'NETWORK',
                      value: _networkStatusLabel,
                      alignEnd: true,
                    ),
                  ),
                ],
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: isCompact ? 132 : 144,
                  child: Center(
                    child: _TelemetryBar(
                      items: [
                        (
                          Icons.location_on_rounded,
                          'GPS: $_gpsStatusLabel',
                          AppColors.statusActive,
                        ),
                        (
                          Icons.height_rounded,
                          'ALT: $_altitudeStatusLabel',
                          AppColors.textPrimary,
                        ),
                        (
                          Icons.wifi_rounded,
                          'NET: $_networkStatusLabel',
                          _hasNetworkConnectivity
                              ? AppColors.statusActive
                              : AppColors.statusError,
                        ),
                        (
                          Icons.photo_camera_back_rounded,
                          liveCameraDetails,
                          AppColors.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            children: [
              if (!_hasGpsFix ||
                  !_hasNetworkConnectivity ||
                  _isMockLocationDetected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      border: Border.all(color: AppColors.borderActive),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _isMockLocationDetected
                              ? Icons.gps_off_rounded
                              : !_hasGpsFix
                              ? Icons.location_searching_rounded
                              : Icons.wifi_off_rounded,
                          size: 16,
                          color: _isMockLocationDetected
                              ? AppColors.statusError
                              : !_hasGpsFix
                              ? AppColors.statusActive
                              : AppColors.statusError,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _captureBlockedMessage,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _refreshCaptureReadiness,
                          child: Text(
                            'RETRY',
                            style: AppTextStyles.labelMedium.copyWith(
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Container(
                height: 112,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _ControlButton(
                          icon: _isFlashEnabled
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          label: 'FLASH',
                          isHighlighted: _isFlashEnabled,
                          onTap: _toggleFlash,
                        ),
                      ),
                    ),
                    _ShutterButton(
                      isBusy: _isCapturing,
                      onTap: canCapture ? _capturePhoto : null,
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _ControlButton(
                          icon: Icons.flip_camera_ios_rounded,
                          label: 'FLIP',
                          onTap: _cameras.length > 1 ? _switchCamera : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReviewScreen(
    BuildContext context,
    GraniteLakeController appController,
    IdentityRecord? identity,
  ) {
    final stagedImagePath = _stagedImagePath;
    final metadata = _stagedMetadata;
    if (stagedImagePath == null) {
      return const SizedBox.shrink();
    }
    final projects = appController.projects;
    final selectedProjectId = appController.selectedProjectId;
    final hasProjects = projects.isNotEmpty;

    return Container(
      key: const ValueKey('review-capture'),
      color: AppColors.background,
      child: Column(
        children: [
          _ReviewHeader(initials: _resolveInitials(identity?.walletAddress)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(stagedImagePath),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                color: AppColors.surfaceElevated,
                                alignment: Alignment.center,
                                child: Text(
                                  'Preview unavailable',
                                  style: AppTextStyles.bodyMedium,
                                ),
                              ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.transparent,
                                AppColors.background.withAlpha(190),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 16,
                          child: _ReviewMetadataPanel(
                            capturedAtLabel: _formatTimestamp(
                              metadata?.capturedAtUtc ?? DateTime.now().toUtc(),
                            ),
                            submittedAtLabel: metadata?.submittedAtUtc == null
                                ? 'Pending submission'
                                : _formatTimestamp(metadata!.submittedAtUtc!),
                            gpsLabel: metadata?.gpsLabel ?? _gpsStatusLabel,
                            altitudeLabel:
                                metadata?.altitudeLabel ?? _altitudeStatusLabel,
                            cameraLabel: metadata?.cameraLabel ?? _cameraLabel,
                            cameraDetailsLabel:
                                metadata?.cameraDetailsLabel ??
                                _cameraDetailsLabel,
                            networkLabel:
                                metadata?.networkLabel ?? _networkStatusLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(text: 'PROJECT ASSOCIATION'),
                        const SizedBox(height: 8),
                        if (hasProjects)
                          DropdownButtonFormField<String>(
                            initialValue: selectedProjectId,
                            isExpanded: true,
                            decoration: _inputDecoration(),
                            dropdownColor: AppColors.surfaceElevated,
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textPrimary,
                            ),
                            items: projects
                                .map(
                                  (project) => DropdownMenuItem<String>(
                                    value: project.projectId,
                                    child: Text(
                                      project.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) async {
                              await appController.selectProject(value);
                              if (!mounted) {
                                return;
                              }
                              setState(() => _errorMessage = null);
                            },
                          )
                        else
                          _MissingProjectCard(
                            onPressed: _showMissingProjectsDialog,
                          ),
                        const SizedBox(height: 18),
                        _SectionLabel(text: 'CATEGORIZATION TAGS'),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _tags
                              .map(
                                (tag) => FilterChip(
                                  label: Text(tag),
                                  selected: _selectedTag == tag,
                                  showCheckmark: false,
                                  onSelected: (selected) {
                                    if (!selected || _selectedTag == tag) {
                                      return;
                                    }
                                    setState(() => _selectedTag = tag);
                                  },
                                  selectedColor: AppColors.primary,
                                  backgroundColor: AppColors.surface,
                                  side: BorderSide(
                                    color: _selectedTag == tag
                                        ? AppColors.primary
                                        : AppColors.borderActive,
                                  ),
                                  labelStyle: AppTextStyles.labelMedium
                                      .copyWith(
                                        color: _selectedTag == tag
                                            ? AppColors.textPrimary
                                            : AppColors.textSecondary,
                                      ),
                                ),
                              )
                              .toList(),
                        ),
                        const SizedBox(height: 18),
                        _SectionLabel(text: 'DOCUMENTATION NOTE'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _noteController,
                          maxLines: 4,
                          decoration: _inputDecoration(
                            hintText: 'Enter forensic observations...',
                          ),
                          style: AppTextStyles.bodyMedium.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border.all(color: AppColors.borderActive),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'IDENTITY FINGERPRINT',
                                    style: AppTextStyles.labelSmall.copyWith(
                                      color: AppColors.textMuted,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                  const Spacer(),
                                  Icon(
                                    Icons.lock_rounded,
                                    size: 16,
                                    color: AppColors.textSecondary,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                identity?.fingerprint ??
                                    'IDENTITY NOT AVAILABLE',
                                style: AppTextStyles.labelMedium.copyWith(
                                  color: AppColors.statusActive,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          _ErrorBanner(message: _errorMessage!),
                        ],
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _discardStagedCapture,
                                child: Text(
                                  'DISCARD',
                                  style: AppTextStyles.buttonText.copyWith(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: hasProjects ? _submitCapture : null,
                                child: Text(
                                  _isCapturing ? 'SUBMITTING' : 'SAVE CAPTURE',
                                  style: AppTextStyles.buttonText,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmissionScreen(BuildContext context) {
    return Container(
      key: const ValueKey('submitting-capture'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          const Spacer(),
          SizedBox(
            width: 176,
            height: 176,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 176,
                  height: 176,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.statusActive.withAlpha(70),
                      width: 2,
                    ),
                  ),
                ),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation(AppColors.statusActive),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _SubmissionScanPainter()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            _submissionHeadline,
            style: AppTextStyles.headlineLarge.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Text(
              _submissionDetail,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              children: [
                _SubmissionStep(
                  title: 'Hashing And Signing Evidence',
                  value: _submissionStageValue(
                    AttestationSubmissionStage.signing,
                    activeLabel:
                        'Hashing the image and signing the proof bundle',
                    completeLabel: 'Proof bundle signed for this session',
                    failedLabel: 'Signing the local proof bundle failed',
                  ),
                  state:
                      _submissionStageStates[AttestationSubmissionStage
                          .signing]!,
                ),
                _SubmissionStep(
                  title: 'Saving Local Record',
                  value: _submissionStageValue(
                    AttestationSubmissionStage.savingLocalRecord,
                    activeLabel:
                        'Writing image metadata and manifest to this device',
                    completeLabel: 'Local capture record saved on-device',
                    failedLabel: 'Saving the local capture record failed',
                  ),
                  state:
                      _submissionStageStates[AttestationSubmissionStage
                          .savingLocalRecord]!,
                ),
                _SubmissionStep(
                  title: 'Submitting To Sui Testnet',
                  value: _submissionStageValue(
                    AttestationSubmissionStage.submittingToChain,
                    activeLabel:
                        'Calling `attest_photo` with UserCap, Registry, hash, GPS, altitude, and project id',
                    completeLabel: 'Sui attestation transaction submitted',
                    failedLabel: 'Sui attestation transaction failed',
                  ),
                  state:
                      _submissionStageStates[AttestationSubmissionStage
                          .submittingToChain]!,
                ),
                _SubmissionStep(
                  title: 'Refreshing Device History',
                  value: _submissionStageValue(
                    AttestationSubmissionStage.refreshingHistory,
                    activeLabel: 'Refreshing the local capture ledger',
                    completeLabel:
                        'Capture ledger updated with the latest status',
                    failedLabel: 'Refreshing the local capture ledger failed',
                  ),
                  state:
                      _submissionStageStates[AttestationSubmissionStage
                          .refreshingHistory]!,
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildSuccessScreen(BuildContext context, IdentityRecord? identity) {
    final record = _latestRecord;
    final metadata = _latestMetadata;
    if (record == null || metadata == null) {
      return const SizedBox.shrink();
    }
    final hasSubmissionFailure = _hasAttestationFailure(record);
    return Container(
      key: const ValueKey('success-capture'),
      color: AppColors.background,
      child: Column(
        children: [
          _ReviewHeader(initials: _resolveInitials(identity?.walletAddress)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              child: Column(
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: hasSubmissionFailure
                            ? AppColors.statusError
                            : AppColors.statusActive,
                        width: 2,
                      ),
                      color:
                          (hasSubmissionFailure
                                  ? AppColors.statusError
                                  : AppColors.statusActive)
                              .withAlpha(20),
                    ),
                    child: Icon(
                      hasSubmissionFailure
                          ? Icons.warning_rounded
                          : Icons.check_circle_rounded,
                      color: hasSubmissionFailure
                          ? AppColors.statusError
                          : AppColors.statusActive,
                      size: 56,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    hasSubmissionFailure
                        ? 'Capture Saved Locally'
                        : 'Image Attested',
                    style: AppTextStyles.headlineLarge.copyWith(
                      fontWeight: FontWeight.w800,
                      color: hasSubmissionFailure
                          ? AppColors.statusError
                          : AppColors.statusActive,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    hasSubmissionFailure
                        ? 'On-chain attestation needs attention'
                        : 'Data integrity verified and sequenced',
                    style: AppTextStyles.labelMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (hasSubmissionFailure) ...[
                    const SizedBox(height: 10),
                    Text(
                      _submissionStatusMessage(record),
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  _MetadataCard(
                    title: 'HASH_FINGERPRINT',
                    icon: Icons.fingerprint_rounded,
                    rows: [
                      ('SHA256', record.contentSha256),
                      ('Image', record.assetName),
                      ('capture_id', record.captureId),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _MetadataCard(
                    title: 'CHAIN_REFERENCE',
                    icon: Icons.receipt_long_rounded,
                    rows: [
                      ('Project', record.displayProject),
                      (
                        'Transaction',
                        record.suiTxDigest.isEmpty
                            ? 'Pending'
                            : record.suiTxDigest,
                      ),
                      ('Status', record.verificationLabel),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _MetadataCard(
                    title: 'CAPTURE_METADATA',
                    icon: Icons.image_search_rounded,
                    rows: [
                      ('Captured', metadata.capturedAtUtc.toIso8601String()),
                      (
                        'Submitted',
                        (metadata.submittedAtUtc ?? record.effectiveSubmittedAt)
                            .toIso8601String(),
                      ),
                      ('GPS', metadata.gpsLabel),
                      ('Altitude', metadata.altitudeLabel),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _MetadataCard(
                    title: 'DEVICE_CONTEXT',
                    icon: Icons.photo_camera_rounded,
                    rows: [
                      (
                        'Camera',
                        '${metadata.cameraLabel} • ${metadata.cameraDetailsLabel}',
                      ),
                      ('App Build', metadata.buildLabel),
                    ],
                  ),
                  if (record.attestationErrorLabel != null) ...[
                    const SizedBox(height: 12),
                    _MetadataCard(
                      title: 'ATTESTATION_ERROR',
                      icon: Icons.warning_rounded,
                      rows: [('Error', record.attestationErrorLabel!)],
                    ),
                  ],
                  if (record.note?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: 12),
                    _MetadataCard(
                      title: 'ADDITIONAL_NOTE',
                      icon: Icons.note_alt_rounded,
                      rows: [('Note', record.note!.trim())],
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _copyProofBundle,
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: Text(
                        'COPY PROOF BUNDLE',
                        style: AppTextStyles.buttonText,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => context.go(AppRoutes.capture),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                      icon: const Icon(Icons.radio_button_checked_rounded),
                      label: Text(
                        'BACK_TO_CAPTURE',
                        style: AppTextStyles.buttonText.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _latestRecord = null;
                          _latestMetadata = null;
                          _flow = _CaptureFlow.live;
                          _errorMessage = null;
                          _submissionStep = 0;
                          _noteController.clear();
                          _selectedTag = 'STRUCTURAL';
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: AppColors.borderActive),
                        padding: const EdgeInsets.symmetric(vertical: 18),
                      ),
                      icon: const Icon(Icons.camera_alt_rounded),
                      label: Text(
                        'CAPTURE_ANOTHER',
                        style: AppTextStyles.buttonText.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  _CaptureMetadataSnapshot _buildMetadataSnapshot(DateTime capturedAtUtc) {
    return _CaptureMetadataSnapshot(
      capturedAtUtc: capturedAtUtc,
      buildLabel: _buildLabel,
      gpsLabel: _gpsStatusLabel,
      altitudeLabel: _altitudeStatusLabel,
      cameraLabel: _cameraLabel,
      cameraDetailsLabel: _cameraDetailsLabel,
      networkLabel: _networkStatusLabel,
    );
  }

  Widget _buildPreview() {
    if (_isPreparing) {
      return const Center(child: CircularProgressIndicator());
    }

    final controller = _cameraController;
    if (_errorMessage != null ||
        controller == null ||
        !controller.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _errorMessage ?? 'Camera initialization failed.',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium,
          ),
        ),
      );
    }

    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.previewSize!.height,
        height: controller.value.previewSize!.width,
        child: CameraPreview(controller),
      ),
    );
  }

  String get _cameraLabel {
    if (_cameras.isEmpty) {
      return 'Camera unavailable';
    }

    final camera = _cameras[_selectedCameraIndex];
    return switch (camera.lensDirection) {
      CameraLensDirection.front => 'Front camera',
      CameraLensDirection.back => 'Rear camera',
      CameraLensDirection.external => 'External camera',
    };
  }

  String get _cameraDetailsLabel {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return _isFlashEnabled ? 'Flash on' : 'Flash off';
    }

    final previewSize = controller.value.previewSize;
    final resolutionLabel = previewSize == null
        ? 'Resolution unavailable'
        : '${previewSize.height.round()}x${previewSize.width.round()}';
    final flashLabel = _isFlashEnabled ? 'Flash on' : 'Flash off';
    return '$resolutionLabel • $flashLabel';
  }

  InputDecoration _inputDecoration({String? hintText}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: AppTextStyles.bodyMedium.copyWith(color: AppColors.textMuted),
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.borderActive),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.borderActive),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.primary),
      ),
    );
  }

  String _formatShortDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatPosition(Position position) {
    final lat = position.latitude.toStringAsFixed(5);
    final lng = position.longitude.toStringAsFixed(5);
    final accuracy = position.accuracy.isFinite
        ? position.accuracy.toStringAsFixed(0)
        : '?';
    return '$lat, $lng (${accuracy}m)';
  }

  String _formatAltitude(Position position) {
    if (!position.altitude.isFinite) {
      return 'Altitude unavailable';
    }
    return '${position.altitude.toStringAsFixed(1)} m';
  }

  bool _detectMockLocation(Position position) {
    return position.isMocked;
  }

  // bool _matchesFormattedGps(String currentValue, String capturedValue) {
  //   return _normalizeGpsComparisonValue(currentValue) ==
  //       _normalizeGpsComparisonValue(capturedValue);
  // }

  // bool _matchesFormattedAltitude(String currentValue, String capturedValue) {
  //   return _normalizeAltitudeComparisonValue(currentValue) ==
  //       _normalizeAltitudeComparisonValue(capturedValue);
  // }

  // String _normalizeGpsComparisonValue(String value) {
  //   final trimmed = value.trim();
  //   final accuracyIndex = trimmed.indexOf(' (');
  //   if (accuracyIndex == -1) {
  //     return trimmed;
  //   }
  //   return trimmed.substring(0, accuracyIndex).trim();
  // }

  // String _normalizeAltitudeComparisonValue(String value) {
  //   return value.trim().toLowerCase();
  // }

  String _formatTimestamp(DateTime timestampUtc) {
    final local = timestampUtc.toLocal();
    final date =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  bool get _hasGpsFix => _gpsStatusLabel.contains(', ');

  bool get _hasNetworkConnectivity => _networkStatusLabel == 'Connected';

  String get _captureBlockedMessage {
    if (_isMockLocationDetected) {
      return 'Mock location detected. Disable mock location before using camera capture.';
    }
    if (_gpsStatusLabel == 'Location off') {
      // This is the device-wide Location services toggle (Settings >
      // Location), not this app's own Location permission - the app
      // permission page can say "Allowed" while this is still off, and
      // no app can get a fix until it's on.
      return 'Turn on Location in your device Settings (Settings > Location) - '
          "this is separate from this app's own Location permission, which "
          'can already be granted while the device-wide toggle is off.';
    }
    if (!_hasGpsFix) {
      final debugError = _gpsDebugError;
      return debugError == null
          ? 'Position data is required before capture. Status: $_gpsStatusLabel'
          : 'Position data is required before capture. Status: $_gpsStatusLabel\n\n$debugError';
    }
    return 'Internet connectivity is required before capture. Status: $_networkStatusLabel';
  }

  bool _hasAttestationFailure(AttestationRecord record) {
    return record.normalizedSuiSubmissionStatus.startsWith('FAILED');
  }

  String get _submissionHeadline {
    final hasFailure = _submissionStageStates.values.contains(
      AttestationSubmissionStageState.failed,
    );
    if (hasFailure) {
      return 'Capture Submission Needs Attention';
    }
    return switch (_activeSubmissionStage) {
      AttestationSubmissionStage.signing || null => 'Preparing Secure Evidence',
      AttestationSubmissionStage.savingLocalRecord => 'Saving Local Proof',
      AttestationSubmissionStage.submittingToChain =>
        'Writing Attestation To Chain',
      AttestationSubmissionStage.refreshingHistory => 'Updating Capture Ledger',
    };
  }

  String get _submissionDetail {
    return _submissionProgressMessage;
  }

  String _submissionStatusMessage(AttestationRecord record) {
    return switch (record.normalizedSuiSubmissionStatus) {
      'FAILED_NOT_CONFIGURED' =>
        'This capture was saved, but the app does not have valid Sui contract settings for attestation.',
      'FAILED_SUBMISSION' =>
        record.attestationErrorLabel ??
            'This capture was saved, but the Sui attestation transaction did not complete. Check wallet gas and network connectivity, then try again later.',
      _ =>
        record.attestationErrorLabel ??
            'This capture was saved, but the on-chain attestation status requires attention.',
    };
  }

  String _submissionStageValue(
    AttestationSubmissionStage stage, {
    required String activeLabel,
    required String completeLabel,
    required String failedLabel,
  }) {
    return switch (_submissionStageStates[stage]!) {
      AttestationSubmissionStageState.pending => 'Queued',
      AttestationSubmissionStageState.active => activeLabel,
      AttestationSubmissionStageState.completed => completeLabel,
      AttestationSubmissionStageState.failed => failedLabel,
    };
  }

  String _resolveInitials(String? value) {
    if (value == null || value.isEmpty) {
      return 'GL';
    }

    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.length >= 2) {
      return cleaned.substring(0, 2).toUpperCase();
    }
    return 'GL';
  }
}

class _MissingProjectCard extends StatelessWidget {
  const _MissingProjectCard({required this.onPressed});

  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.statusError),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No project available for this capture.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a project first, then come back to save this evidence.',
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onPressed,
            child: Text(
              'OPEN PROJECTS',
              style: AppTextStyles.buttonText.copyWith(
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IdentityBadge extends StatelessWidget {
  const _IdentityBadge({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        initials,
        style: AppTextStyles.labelMedium.copyWith(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    this.isHighlighted = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isHighlighted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = isHighlighted
        ? AppColors.statusError
        : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: onTap == null ? AppColors.textMuted : color),
            const SizedBox(height: 4),
            Text(
              label,
              style: AppTextStyles.labelSmall.copyWith(
                color: onTap == null ? AppColors.textMuted : color,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.isBusy, required this.onTap});

  final bool isBusy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    final isDark = GraniteLakeScope.of(context).isDarkMode;
    final ringColor = isDark ? Colors.white : AppColors.primary;
    return Opacity(
      opacity: isEnabled ? 1 : 0.45,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isEnabled
                        ? AppColors.statusActive.withAlpha(100)
                        : AppColors.textMuted,
                    width: 2,
                  ),
                ),
              ),
              Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isEnabled ? ringColor : AppColors.textSecondary,
                    width: 4,
                  ),
                ),
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: isBusy
                          ? AppColors.statusActive
                          : isEnabled
                          ? ringColor
                          : AppColors.textSecondary,
                      shape: BoxShape.circle,
                    ),
                    child: isBusy
                        ? Padding(
                            padding: EdgeInsets.all(14),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                AppColors.background,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TelemetryBar extends StatelessWidget {
  const _TelemetryBar({required this.items});

  final List<(IconData, String, Color)> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(210),
        border: Border.all(color: AppColors.borderActive),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final item in items)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.$1, size: 16, color: item.$3),
                const SizedBox(width: 6),
                Text(
                  item.$2,
                  style: AppTextStyles.labelSmall.copyWith(
                    color: AppColors.textPrimary,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LabeledMetric extends StatelessWidget {
  const _LabeledMetric({
    required this.label,
    required this.value,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.hudLabel.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.statusError.withAlpha(24),
        border: Border.all(color: AppColors.statusError.withAlpha(130)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: AppTextStyles.bodySmall.copyWith(color: AppColors.statusError),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.labelMedium.copyWith(
        color: AppColors.textSecondary,
        letterSpacing: 1.1,
      ),
    );
  }
}

class _ReviewHeader extends StatelessWidget {
  const _ReviewHeader({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          _IdentityBadge(initials: initials),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${AppConstants.appName}_${AppConstants.appVersion}',
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelLarge.copyWith(
                color: AppColors.textPrimary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Icon(Icons.verified_rounded, color: AppColors.primary),
        ],
      ),
    );
  }
}

class _SubmissionStep extends StatelessWidget {
  const _SubmissionStep({
    required this.title,
    required this.value,
    required this.state,
  });

  final String title;
  final String value;
  final AttestationSubmissionStageState state;

  @override
  Widget build(BuildContext context) {
    final isActive = state == AttestationSubmissionStageState.active;
    final isComplete = state == AttestationSubmissionStageState.completed;
    final isFailed = state == AttestationSubmissionStageState.failed;
    final accent = isFailed
        ? AppColors.statusError
        : isComplete || isActive
        ? AppColors.statusActive
        : AppColors.borderActive;
    final icon = isFailed
        ? Icons.close_rounded
        : isComplete
        ? Icons.check_rounded
        : Icons.more_horiz_rounded;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: accent.withAlpha(isActive ? 180 : 100)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withAlpha(isActive ? 36 : 20),
              border: Border.all(color: accent),
            ),
            child: isActive
                ? Padding(
                    padding: const EdgeInsets.all(6),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  )
                : Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.labelMedium),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewMetadataPanel extends StatelessWidget {
  const _ReviewMetadataPanel({
    required this.capturedAtLabel,
    required this.submittedAtLabel,
    required this.gpsLabel,
    required this.altitudeLabel,
    required this.cameraLabel,
    required this.cameraDetailsLabel,
    required this.networkLabel,
  });

  final String capturedAtLabel;
  final String submittedAtLabel;
  final String gpsLabel;
  final String altitudeLabel;
  final String cameraLabel;
  final String cameraDetailsLabel;
  final String networkLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background.withAlpha(170),
        border: Border.all(color: AppColors.borderActive.withAlpha(210)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CAPTURE METADATA',
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          _MetadataRow(label: 'Captured At', value: capturedAtLabel),
          const SizedBox(height: 8),
          _MetadataRow(label: 'Submitted At', value: submittedAtLabel),
          const SizedBox(height: 8),
          _MetadataRow(label: 'GPS', value: gpsLabel),
          const SizedBox(height: 8),
          _MetadataRow(label: 'Altitude', value: altitudeLabel),
          const SizedBox(height: 8),
          _MetadataRow(label: 'Rear Camera', value: cameraLabel),
          const SizedBox(height: 8),
          _MetadataRow(label: 'Network', value: networkLabel),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 74),
            child: Text(
              cameraDetailsLabel,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 66,
          child: Text(
            label.toUpperCase(),
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 0.9,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.labelMedium.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

class _MetadataCard extends StatelessWidget {
  const _MetadataCard({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final row in rows) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row.$1.toUpperCase(),
                    style: AppTextStyles.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _middleEllipsis(row.$2),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () =>
                            _copyMetadataValue(context, row.$1, row.$2),
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Future<void> _copyMetadataValue(
    BuildContext context,
    String label,
    String value,
  ) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${label.toUpperCase()} copied')));
  }
}

String _middleEllipsis(String value, {int keepStart = 14, int keepEnd = 12}) {
  final normalized = value.trim();
  if (normalized.length <= keepStart + keepEnd + 3) {
    return normalized;
  }
  final start = normalized.substring(0, keepStart);
  final end = normalized.substring(normalized.length - keepEnd);
  return '$start...$end';
}

class _ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = Colors.white.withAlpha(56)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final accentPaint = Paint()
      ..color = AppColors.statusActive.withAlpha(180)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(18),
    );
    canvas.drawRRect(rect, borderPaint);

    const corner = 28.0;
    final corners = [
      (const Offset(0, 0), const Offset(corner, 0), const Offset(0, corner)),
      (
        Offset(size.width, 0),
        Offset(size.width - corner, 0),
        Offset(size.width, corner),
      ),
      (
        Offset(0, size.height),
        Offset(corner, size.height),
        Offset(0, size.height - corner),
      ),
      (
        Offset(size.width, size.height),
        Offset(size.width - corner, size.height),
        Offset(size.width, size.height - corner),
      ),
    ];

    for (final cornerData in corners) {
      final path = Path()
        ..moveTo(cornerData.$1.dx, cornerData.$1.dy)
        ..lineTo(cornerData.$2.dx, cornerData.$2.dy)
        ..moveTo(cornerData.$1.dx, cornerData.$1.dy)
        ..lineTo(cornerData.$3.dx, cornerData.$3.dy);
      canvas.drawPath(path, accentPaint);
    }

    final crosshairPaint = Paint()
      ..color = AppColors.statusActive.withAlpha(110)
      ..strokeWidth = 1.5;
    final center = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(center, 26, borderPaint);
    canvas.drawLine(
      Offset(center.dx - 18, center.dy),
      Offset(center.dx + 18, center.dy),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 18),
      Offset(center.dx, center.dy + 18),
      crosshairPaint,
    );

    final scanPaint = Paint()..color = AppColors.primary.withAlpha(36);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.18, size.width, 2),
      scanPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SubmissionScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = AppColors.statusActive.withAlpha(70)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final glowPaint = Paint()
      ..color = AppColors.statusActive.withAlpha(32)
      ..style = PaintingStyle.fill;
    final centerY = size.height * 0.5;
    final rect = Rect.fromLTWH(0, centerY - 6, size.width, 12);
    canvas.drawRect(rect, glowPaint);
    canvas.drawLine(
      Offset(18, centerY),
      Offset(size.width - 18, centerY),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
