import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../app.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../widgets/hud_overlay.dart';
import '../widgets/scan_line_overlay.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _domainController = TextEditingController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();

  String? _otpUserId;
  DateTime? _otpExpiresAt;
  String? _otpWalletNonce;
  String? _errorText;
  String? _statusText;
  bool _isRequestingOtp = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _domainController.addListener(_clearOtpSession);
    _emailController.addListener(_clearOtpSession);
  }

  @override
  void dispose() {
    _domainController.removeListener(_clearOtpSession);
    _emailController.removeListener(_clearOtpSession);
    _domainController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _clearOtpSession() {
    if (_otpUserId == null || _isRequestingOtp || _isSubmitting) {
      return;
    }

    setState(() {
      _otpUserId = null;
      _otpExpiresAt = null;
      _otpWalletNonce = null;
      _statusText = null;
      _otpController.clear();
    });
  }

  Future<void> _copyWalletAddress(String? walletAddress) async {
    final normalized = walletAddress?.trim();
    if (normalized == null || normalized.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: normalized));
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Wallet address copied')));
  }

  Future<void> _requestOtp() async {
    setState(() {
      _isRequestingOtp = true;
      _errorText = null;
      _statusText = null;
      _otpUserId = null;
      _otpExpiresAt = null;
      _otpWalletNonce = null;
    });

    final controller = GraniteLakeScope.of(context);
    final result = await controller.requestPhotoAttestationOtp(
      domain: _domainController.text,
      userEmail: _emailController.text,
    );
    if (!mounted) {
      return;
    }

    if (!result.isSuccess || result.data == null) {
      setState(() {
        _isRequestingOtp = false;
        _errorText = result.message;
      });
      return;
    }

    final otpRequest = result.data!;
    setState(() {
      _isRequestingOtp = false;
      _otpUserId = otpRequest.userId;
      _otpExpiresAt = otpRequest.expiresAt;
      _otpWalletNonce = otpRequest.walletNonce;
      _statusText =
          'OTP requested for ${otpRequest.userEmail}. Check the configured delivery channel.';
    });
  }

  Future<void> _submit() async {
    final userId = _otpUserId;
    final walletNonce = _otpWalletNonce;
    if (userId == null ||
        userId.isEmpty ||
        walletNonce == null ||
        walletNonce.isEmpty) {
      setState(() {
        _errorText = 'Request an OTP before verifying your wallet.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final controller = GraniteLakeScope.of(context);
    final result = await controller.claimPhotoAttestationUser(
      domain: _domainController.text,
      userId: userId,
      otp: _otpController.text,
      walletNonce: walletNonce,
    );
    if (!mounted) {
      return;
    }

    if (!result.isSuccess) {
      setState(() {
        _isSubmitting = false;
        _errorText = result.message;
      });
      return;
    }

    setState(() => _isSubmitting = false);
    context.go(AppRoutes.dashboard);
  }

  String? get _otpExpiryLabel {
    final expiresAt = _otpExpiresAt;
    if (expiresAt == null) {
      return null;
    }
    final local = expiresAt.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return 'OTP expires at $hour:$minute.';
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final controller = GraniteLakeScope.of(context);
    final identity = controller.identity;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Positioned.fill(child: ScanLineOverlay()),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    20 + viewInsets.bottom,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TopHudOverlay(
                            flowId: AppConstants.registrationFlowId,
                            status: AppConstants.registrationStatus,
                            encryptAlgo: AppConstants.registrationEncryptMode,
                            trailing: const ShieldBadge(size: 64),
                          ),
                          const SizedBox(height: 28),
                          Text(
                            AppConstants.registrationDisplayId,
                            style: AppTextStyles.labelMedium.copyWith(
                              color: AppColors.textMuted,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Confirm Your\nAccount',
                            style: AppTextStyles.displayLarge.copyWith(
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.5,
                              height: 1.1,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Enter your company email to request a one-time code, then verify it to link this wallet to your on-chain UserCap.',
                            style: AppTextStyles.bodyMedium.copyWith(
                              color: AppColors.textSecondary,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 20),
                          _InfoCard(
                            title: 'YOUR WALLET ADDRESS',
                            body:
                                identity?.walletAddress ??
                                'Wallet not ready yet.',
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: AppColors.surface.withAlpha(90),
                              border: Border.all(
                                color: AppColors.secondary.withAlpha(120),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'ADD TEST FUNDS',
                                  style: AppTextStyles.labelSmall.copyWith(
                                    color: AppColors.secondary,
                                    letterSpacing: 1,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Your new wallet needs a small amount of test SUI before you continue. Open the link below, paste your wallet address, and send test funds to yourself.',
                                  style: AppTextStyles.bodyMedium.copyWith(
                                    color: AppColors.textPrimary,
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SelectableText(
                                  AppConstants.suiTestnetFaucetUrl,
                                  style: AppTextStyles.labelLarge.copyWith(
                                    color: AppColors.actionFill,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton(
                                        onPressed: identity == null
                                            ? null
                                            : () => _copyWalletAddress(
                                                identity.walletAddress,
                                              ),
                                        child: Text(
                                          'COPY ADDRESS',
                                          style: AppTextStyles.buttonText
                                              .copyWith(
                                                color: AppColors.textPrimary,
                                              ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          _InfoCard(
                            title: 'BEFORE YOU CONTINUE',
                            body:
                                'Add test funds first, then request an OTP for your company email. The OTP is delivered through the configured backend channel.',
                          ),
                          const SizedBox(height: 24),
                          _LabeledField(
                            label: 'COMPANY DOMAIN',
                            controller: _domainController,
                            hintText: 'example: acme.com',
                          ),
                          const SizedBox(height: 16),
                          _LabeledField(
                            label: 'COMPANY EMAIL',
                            controller: _emailController,
                            hintText: 'example: alice@acme.com',
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton(
                            onPressed: _isRequestingOtp || _isSubmitting
                                ? null
                                : _requestOtp,
                            child: Text(
                              _isRequestingOtp
                                  ? 'REQUESTING OTP'
                                  : 'REQUEST OTP',
                              style: AppTextStyles.buttonText.copyWith(
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          if (_statusText != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              [
                                _statusText,
                                _otpExpiryLabel,
                              ].whereType<String>().join(' '),
                              style: AppTextStyles.bodyMedium.copyWith(
                                color: AppColors.statusActive,
                                height: 1.5,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          _LabeledField(
                            label: 'ONE-TIME CODE',
                            controller: _otpController,
                            hintText: 'example: 123456',
                            keyboardType: TextInputType.number,
                            errorText: _errorText,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed:
                                _isSubmitting ||
                                    _isRequestingOtp ||
                                    _otpUserId == null
                                ? null
                                : _submit,
                            child: Text(
                              _isSubmitting ? 'VERIFYING OTP' : 'CONTINUE',
                              style: AppTextStyles.buttonText,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.controller,
    required this.hintText,
    this.keyboardType,
    this.errorText,
  });

  final String label;
  final TextEditingController controller;
  final String hintText;
  final TextInputType? keyboardType;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(
            color: AppColors.textMuted,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          style: AppTextStyles.labelLarge.copyWith(
            color: AppColors.textPrimary,
            letterSpacing: 0.8,
          ),
          decoration: InputDecoration(
            hintText: hintText,
            errorText: errorText,
            // Flutter truncates errorText to a single ellipsized line unless
            // errorMaxLines is set explicitly, even though the field grows
            // to fit it. These messages can run several sentences.
            errorMaxLines: 6,
            errorStyle: AppTextStyles.labelSmall.copyWith(
              color: AppColors.statusError,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface.withAlpha(90),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: AppTextStyles.labelSmall.copyWith(
              color: AppColors.textMuted,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: AppTextStyles.bodyMedium.copyWith(
              color: AppColors.textPrimary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
