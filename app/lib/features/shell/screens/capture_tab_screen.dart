import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/state/granite_lake_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../../../core/utils/location_settings.dart';

/// The Capture tab body shown inside [MainShell].
///
/// Displays session status and lets the operator start/end a secure session.
/// When a session is active, tapping the Capture nav item (or the button here)
/// navigates to the capture method chooser at [AppRoutes.capture].
class CaptureTabScreen extends StatefulWidget {
  const CaptureTabScreen({super.key});

  @override
  State<CaptureTabScreen> createState() => _CaptureTabScreenState();
}

class _CaptureTabScreenState extends State<CaptureTabScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _isStartingSession = false;
  bool _isEndingSession = false;
  String? _errorMessage;
  AnimationController? _pulseController;
  String _locationLabel = 'Locating...';
  // _refreshLocation() previously ran exactly once, in initState. If the
  // system Location toggle (Settings > Location - separate from this app's
  // own Location permission) got switched off after that, or a fix just
  // never arrived (no timeLimit was set), the label went stale forever:
  // nothing re-ran the check, so a changed state never had a chance to show.
  // A periodic timer plus a resume listener make sure it's re-checked.
  Timer? _locationTimer;
  int _locationRequestId = 0;
  // On GrapheneOS without Sandboxed Google Play, a GPS-only cold fix is
  // confirmed by GrapheneOS's own team to normally take 2-5+ minutes
  // outdoors (https://discuss.grapheneos.org/d/79-location-not-working).
  // Firing a fresh _refreshLocation every 15s while one is still in flight
  // would restart that request from scratch each time, so skip relaunching
  // it until the current attempt actually finishes.
  bool _isFetchingLocation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensurePulseController();
    unawaited(_refreshLocation());
    _locationTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshLocation());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Catches the common case immediately: user backgrounds the app,
      // flips Location in system Settings, comes back.
      unawaited(_refreshLocation());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationTimer?.cancel();
    _pulseController?.dispose();
    super.dispose();
  }

  Future<bool?> _showBiometricResetDialog(String message) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.surfaceElevated,
          title: Text(
            'Biometrics Changed',
            style: AppTextStyles.labelLarge.copyWith(
              color: AppColors.textPrimary,
            ),
          ),
          content: Text(
            '$message\n\nReset ${AppConstants.appTitle} and restart onboarding on this device?',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                'NO',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'YES',
                style: AppTextStyles.buttonText.copyWith(
                  color: AppColors.statusError,
                ),
              ),
            ),
          ],
        );
      },
    );
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
            'Create a project before starting or continuing a verified capture session.',
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textSecondary,
              height: 1.5,
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

  Future<void> _handlePrimaryAction(bool activeSession) async {
    if (_isStartingSession || _isEndingSession) {
      return;
    }

    final controller = GraniteLakeScope.of(context);
    if (!controller.hasProjects) {
      await _showMissingProjectsDialog();
      return;
    }

    if (activeSession) {
      context.push(AppRoutes.capture);
      return;
    }

    setState(() {
      _isStartingSession = true;
      _errorMessage = null;
    });

    final result = await controller.startSession();
    if (!mounted) {
      return;
    }

    if (result.code == 'biometric_reset_required') {
      setState(() => _isStartingSession = false);
      final shouldReset = await _showBiometricResetDialog(
        result.message ??
            'Biometrics changed on this device. Re-bind required.',
      );
      if (!mounted) {
        return;
      }
      if (shouldReset == true) {
        await controller.resetForBiometricInvalidation();
        if (!mounted) {
          return;
        }
        context.go(AppRoutes.welcome);
      }
      return;
    }

    if (!result.isSuccess) {
      setState(() {
        _isStartingSession = false;
        _errorMessage = result.message;
      });
      return;
    }

    setState(() => _isStartingSession = false);
    context.push(AppRoutes.capture);
  }

  Future<void> _handleEndSession() async {
    if (_isStartingSession || _isEndingSession) {
      return;
    }

    setState(() {
      _isEndingSession = true;
      _errorMessage = null;
    });

    await GraniteLakeScope.of(context).endSession();
    if (!mounted) {
      return;
    }

    setState(() => _isEndingSession = false);
  }

  Future<void> _refreshLocation() async {
    if (_isFetchingLocation) {
      return;
    }
    // Guards against the periodic timer, the resume listener, and initState
    // firing overlapping calls: a slow/late call from an earlier trigger
    // must not clobber the state set by a newer one.
    final requestId = ++_locationRequestId;
    bool isCurrent() => mounted && requestId == _locationRequestId;
    _isFetchingLocation = true;

    try {
      if (isCurrent()) {
        setState(() => _locationLabel = 'Locating...');
      }

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!isCurrent()) {
        return;
      }
      if (!serviceEnabled) {
        setState(() => _locationLabel = 'Location off');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (!isCurrent()) {
        return;
      }

      if (permission == LocationPermission.denied) {
        setState(() => _locationLabel = 'Permission denied');
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() => _locationLabel = 'Permission blocked');
        return;
      }

      // A raw GPS cold fix (no network/Play Services assistance, e.g. on
      // GrapheneOS without Sandboxed Google Play) is confirmed by GrapheneOS's
      // own team to normally take 2-5+ minutes outdoors on first use. No
      // timeLimit would hang forever with nothing to show; too short a one
      // would misreport that normal wait as a failure.
      final position = await Geolocator.getCurrentPosition(
        locationSettings: resolveLocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: const Duration(minutes: 2),
        ),
      );
      if (!isCurrent()) {
        return;
      }
      setState(() => _locationLabel = _formatPosition(position));
    } catch (error) {
      if (!isCurrent()) {
        return;
      }
      // A GPS-only cold fix (no network/Play Services assistance) can
      // legitimately take several minutes - a timeout here just means
      // "still trying," not "broken."
      setState(
        () => _locationLabel = error is TimeoutException
            ? 'Still acquiring GPS'
            : 'GPS unavailable',
      );
      // This HUD readout is too tight to show a full exception without
      // breaking the layout, so surface it via a snackbar the user can read
      // and dismiss instead - see capture_screen.dart's blocked-capture
      // panel for the equivalent on the actual capture flow.
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('GPS error: ${error.runtimeType}: $error'),
            duration: const Duration(seconds: 12),
          ),
        );
    } finally {
      _isFetchingLocation = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = GraniteLakeScope.of(context);
    final activeSession = controller.hasActiveSession;
    final session = controller.session;
    final identity = controller.identity;
    final size = MediaQuery.sizeOf(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final availableHeight =
        size.height - topPadding - kBottomNavigationBarHeight;
    final showTopTelemetry = availableHeight > 680;
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceFirst('T', ' ')
        .split('.')
        .first;
    final initials = _resolveInitials(
      identity?.walletAddress ?? AppConstants.appName,
    );
    final biometricIcon = _resolveBiometricIcon(controller.biometricBinding);
    final pulseController = _ensurePulseController();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 1.0,
          colors: [
            controller.isDarkMode
                ? const Color(0xFF1A2E1E)
                : const Color(0xFFE8F2FF),
            AppColors.background,
            AppColors.background,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _ScanlineOverlay()),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  _CaptureHeader(initials: initials),
                  Expanded(
                    child: Stack(
                      children: [
                        const Positioned(
                          top: 16,
                          left: 0,
                          child: _CornerReticle(top: true, left: true),
                        ),
                        const Positioned(
                          top: 16,
                          right: 0,
                          child: _CornerReticle(top: true, left: false),
                        ),
                        const Positioned(
                          bottom: 16,
                          left: 0,
                          child: _CornerReticle(top: false, left: true),
                        ),
                        const Positioned(
                          bottom: 16,
                          right: 0,
                          child: _CornerReticle(top: false, left: false),
                        ),
                        if (showTopTelemetry) ...[
                          Positioned(
                            top: 8,
                            left: 0,
                            child: _TechReadout(
                              alignment: CrossAxisAlignment.start,
                              entries: [
                                ('LOC', _locationLabel),
                                ('SIGN', 'SHA-256 / ED25519'),
                              ],
                            ),
                          ),
                          Positioned(
                            top: 8,
                            right: 0,
                            child: _TechReadout(
                              alignment: CrossAxisAlignment.end,
                              entries: [
                                const ('SYS_STATE', 'READY'),
                                ('STAMP', '$timestamp UTC'),
                              ],
                            ),
                          ),
                        ],
                        Center(
                          child: Padding(
                            padding: EdgeInsets.only(
                              top: showTopTelemetry ? 84 : 12,
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 360,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'AUTHENTICATED USER',
                                      style: AppTextStyles.labelMedium.copyWith(
                                        color: AppColors.textSecondary,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          identity?.walletTag ??
                                              AppConstants.appTitle,
                                          maxLines: 1,
                                          textAlign: TextAlign.center,
                                          style: AppTextStyles.displayMedium
                                              .copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    GestureDetector(
                                      onTap: () =>
                                          _handlePrimaryAction(activeSession),
                                      child: _BiometricUnlockButton(
                                        pulse: pulseController,
                                        isBusy: _isStartingSession,
                                        isActive: activeSession,
                                        iconData: biometricIcon,
                                      ),
                                    ),
                                    const SizedBox(height: 28),
                                    Text(
                                      activeSession
                                          ? 'Session active. Tap to continue your verified capture workflow.'
                                          : 'Unlock to start a 30-minute verified capture session.',
                                      textAlign: TextAlign.center,
                                      style: AppTextStyles.bodyMedium.copyWith(
                                        color: AppColors.textSecondary,
                                        height: 1.6,
                                      ),
                                    ),
                                    const SizedBox(height: 18),
                                    _SessionProtocolCard(
                                      sessionStatus: activeSession
                                          ? 'ACTIVE'
                                          : 'LOCKED',
                                      hashValue:
                                          identity?.fingerprint ??
                                          'SHA256: UNBOUND',
                                      ttlValue: activeSession
                                          ? _formatSeconds(
                                              controller
                                                  .remainingSessionDuration,
                                            )
                                          : '--.--s',
                                    ),
                                    const SizedBox(height: 18),
                                    if (session != null)
                                      Text(
                                        'Expires ${session.expiresAt.toLocal().toString().substring(11, 19)}',
                                        style: AppTextStyles.labelMedium
                                            .copyWith(
                                              color: AppColors.textSecondary,
                                            ),
                                      ),
                                    if (_errorMessage != null) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _errorMessage!,
                                        textAlign: TextAlign.center,
                                        style: AppTextStyles.bodySmall.copyWith(
                                          color: AppColors.statusError,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (activeSession) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: _isStartingSession || _isEndingSession
                            ? null
                            : _handleEndSession,
                        child: Text(
                          _isEndingSession ? 'ENDING SESSION' : 'END SESSION',
                          style: AppTextStyles.buttonText.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'CAPTURES ARE HASHED AND SIGNED ON DEVICE',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.labelSmall.copyWith(
                      color: AppColors.textMuted,
                      letterSpacing: 1.2,
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

  String _resolveInitials(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.length >= 2) {
      return cleaned.substring(0, 2).toUpperCase();
    }
    return 'GL';
  }

  String _formatSeconds(Duration duration) {
    final seconds = duration.inMilliseconds / 1000;
    return '${seconds.toStringAsFixed(2)}s';
  }

  IconData _resolveBiometricIcon(BiometricBindingRecord? binding) {
    final modalities =
        binding?.modalities.map((item) => item.toUpperCase()).toList() ??
        const <String>[];
    if (modalities.any((item) => item.contains('FACE'))) {
      return Icons.face_retouching_natural_rounded;
    }
    if (modalities.any((item) => item.contains('IRIS'))) {
      return Icons.visibility_rounded;
    }
    return Icons.fingerprint_rounded;
  }

  AnimationController _ensurePulseController() {
    return _pulseController ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
  }

  String _formatPosition(Position position) {
    final lat = position.latitude.toStringAsFixed(5);
    final lng = position.longitude.toStringAsFixed(5);
    final accuracy = position.accuracy.isFinite
        ? position.accuracy.toStringAsFixed(0)
        : '?';
    return '$lat, $lng (${accuracy}m)';
  }
}

class _CaptureHeader extends StatelessWidget {
  const _CaptureHeader({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.background.withAlpha(220),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Container(
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
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${AppConstants.appName}_${AppConstants.appVersion}',
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelLarge.copyWith(
                color: AppColors.textPrimary,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Icon(Icons.verified_rounded, color: AppColors.primary),
        ],
      ),
    );
  }
}

class _TechReadout extends StatelessWidget {
  const _TechReadout({required this.alignment, required this.entries});

  final CrossAxisAlignment alignment;
  final List<(String, String)> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      children: entries
          .map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '${entry.$1}: ${entry.$2}',
                style: AppTextStyles.hudValue.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _SessionProtocolCard extends StatelessWidget {
  const _SessionProtocolCard({
    required this.sessionStatus,
    required this.hashValue,
    required this.ttlValue,
  });

  final String sessionStatus;
  final String hashValue;
  final String ttlValue;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(220),
        border: Border.all(color: AppColors.borderActive),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'SESSION PROTOCOL',
                style: AppTextStyles.labelSmall.copyWith(
                  color: AppColors.textMuted,
                  letterSpacing: 1.1,
                ),
              ),
              const Spacer(),
              Text(
                'V-CAP 4.2',
                style: AppTextStyles.labelMedium.copyWith(
                  color: AppColors.statusActive,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ProtocolValue(
                  label: 'Identity Fingerprint',
                  value: hashValue,
                  alignment: CrossAxisAlignment.start,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ProtocolValue(
                  label: 'TTL Remaining',
                  value: ttlValue,
                  alignment: CrossAxisAlignment.end,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 16,
                color: AppColors.statusActive,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sessionStatus,
                  style: AppTextStyles.labelMedium.copyWith(
                    color: sessionStatus == 'ACTIVE'
                        ? AppColors.statusActive
                        : AppColors.textSecondary,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProtocolValue extends StatelessWidget {
  const _ProtocolValue({
    required this.label,
    required this.value,
    required this.alignment,
  });

  final String label;
  final String value;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignment,
      children: [
        Text(
          label.toUpperCase(),
          style: AppTextStyles.hudLabel.copyWith(color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.labelMedium.copyWith(
            color: AppColors.textPrimary,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );
  }
}

class _BiometricUnlockButton extends StatelessWidget {
  const _BiometricUnlockButton({
    required this.pulse,
    required this.isBusy,
    required this.isActive,
    required this.iconData,
  });

  final Animation<double> pulse;
  final bool isBusy;
  final bool isActive;
  final IconData iconData;

  @override
  Widget build(BuildContext context) {
    final ringColor = isActive
        ? AppColors.statusActive
        : const Color(0xFF40E56C);

    return SizedBox(
      width: 180,
      height: 180,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final scale = 0.94 + (pulse.value * 0.14);
          final opacity = 0.14 + (pulse.value * 0.18);

          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 176,
                  height: 176,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor.withValues(alpha: opacity),
                      width: 2,
                    ),
                  ),
                ),
              ),
              Container(
                width: 144,
                height: 144,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ringColor.withAlpha(90)),
                ),
              ),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceElevated,
                  border: Border.all(color: AppColors.borderActive),
                  boxShadow: [
                    BoxShadow(
                      color: ringColor.withAlpha(30),
                      blurRadius: 24,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: Center(
                  child: isBusy
                      ? const SizedBox(
                          width: 30,
                          height: 30,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isActive
                              ? Icons.collections_bookmark_rounded
                              : iconData,
                          size: 44,
                          color: ringColor,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CornerReticle extends StatelessWidget {
  const _CornerReticle({required this.top, required this.left});

  final bool top;
  final bool left;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _CornerReticlePainter(
          top: top,
          left: left,
          color: AppColors.borderActive.withAlpha(180),
        ),
      ),
    );
  }
}

class _CornerReticlePainter extends CustomPainter {
  const _CornerReticlePainter({
    required this.top,
    required this.left,
    required this.color,
  });

  final bool top;
  final bool left;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final path = Path();
    final x = left ? 0.0 : size.width;
    final y = top ? 0.0 : size.height;
    path.moveTo(x, y + (top ? 24 : -24));
    path.lineTo(x, y);
    path.lineTo(x + (left ? 24 : -24), y);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerReticlePainter oldDelegate) {
    return oldDelegate.top != top ||
        oldDelegate.left != left ||
        oldDelegate.color != color;
  }
}

class _ScanlineOverlay extends StatelessWidget {
  const _ScanlineOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ShaderMask(
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: List.generate(
              16,
              (index) => index.isEven
                  ? Colors.transparent
                  : const Color(0xFF40E56C).withAlpha(14),
            ),
          ).createShader(bounds);
        },
        blendMode: BlendMode.srcATop,
        child: Container(color: Colors.white.withAlpha(12)),
      ),
    );
  }
}
