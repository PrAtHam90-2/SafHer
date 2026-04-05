import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../services/verification_service.dart';
import '../../services/trip_provider.dart';
import '../../widgets/profile_avatar.dart';

// ============================================================================
//  _CheckState — drives credential row icons without exposing bool complexity
// ============================================================================

enum _CheckState { passed, warning, danger }

// ============================================================================
//  VerifyScreen
// ============================================================================

class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key});

  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  late final TextEditingController _controller;
  bool _isScanning = false;

  // ── Route-anomaly listener ─────────────────────────────────────────────────
  StreamSubscription<String>? _anomalySub;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();

    // Listen to TripNotifier anomaly stream and show snackbars.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anomalySub = ref
          .read(tripProvider.notifier)
          .anomalyStream
          .listen((msg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: AppColors.primaryPink,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _anomalySub?.cancel();
    super.dispose();
  }

  // ── TextField submit ────────────────────────────────────────────────────────
  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    FocusScope.of(context).unfocus();
    ref.read(verifyProvider.notifier).verify(value);
  }

  // ── Camera plate scan ────────────────────────────────────────────────────────
  Future<void> _scanPlate() async {
    setState(() => _isScanning = true);
    try {
      final picker = ImagePicker();
      final XFile? photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.rear,
      );
      if (photo == null) return;

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final inputImage = InputImage.fromFilePath(photo.path);
      final recognized = await recognizer.processImage(inputImage);
      await recognizer.close();

      // Strip spaces → match Indian plate pattern
      final plateRegex = RegExp(r'[A-Z]{2}\d{2}[A-Z]{1,2}\d{4}');
      String? detected;
      for (final block in recognized.blocks) {
        final cleaned = block.text.replaceAll(RegExp(r'\s+'), '').toUpperCase();
        final match = plateRegex.firstMatch(cleaned);
        if (match != null) {
          detected = match.group(0);
          break;
        }
      }

      if (detected != null) {
        _controller.text = detected;
        if (mounted) ref.read(verifyProvider.notifier).verify(detected);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No plate detected. Please enter manually.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scan failed: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  // ── Start Journey — navigates to Trip screen; trip logic stays there ────────
  void _startJourney() => context.go('/trip');

  // ── Share Driver Details — shares visible verified data via share sheet ────
  void _shareDriverDetails(VerificationData data) {
    final status = data.driverStatus.badgeLabel.replaceAll('\n', ' ');
    final text = '''🚗 SafHer — Verified Driver Details

Driver : ${data.driverName}
Vehicle : ${data.vehicleInfo}
Licence : ${data.licenseNumber.isNotEmpty ? data.licenseNumber : 'N/A'}
Phone   : ${data.phone.isNotEmpty ? data.phone : 'N/A'}
Status  : $status
Score   : ${data.safetyScore}/100

Shared via SafHer Women's Safety App''';

    Share.share(text, subject: 'SafHer — Verified Driver Info');
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final verifyAsync = ref.watch(verifyProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(LucideIcons.shield, color: AppColors.primaryPink),
            const SizedBox(width: 8),
            Text(
              'SafHer',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.w800,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ),
        actions: const [ProfileAvatar()],
      ),
      body: Column(
        children: [
          _buildInputSection(context),
          Expanded(
            child: verifyAsync.when(
              data: (data) => data == null
                  ? _buildEmptyState(context)
                  : _buildBody(context, data),
              loading: () => const Center(
                child:
                    CircularProgressIndicator(color: AppColors.primaryPink),
              ),
              error: (error, _) => _buildError(context, error),
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(height: 0),
    );
  }

  // ── Input bar ──────────────────────────────────────────────────────────────
  Widget _buildInputSection(BuildContext context) {
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Enter vehicle number  (MH12AB1234)',
                hintStyle: const TextStyle(
                    color: AppColors.textLight, fontSize: 13),
                prefixIcon: const Icon(LucideIcons.car,
                    color: AppColors.primaryPink, size: 18),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search_rounded,
                      color: AppColors.primaryPink),
                  onPressed: _submit,
                  tooltip: 'Verify',
                ),
                filled: true,
                fillColor: AppColors.cardWhite,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        BorderSide(color: Colors.grey.shade200)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: AppColors.primaryPink, width: 1.5)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _isScanning ? null : _scanPlate,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.primaryPink,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryPink.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Icon(LucideIcons.scanLine,
                      color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  // ── Empty state ────────────────────────────────────────────────────────────
  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
                color: AppColors.lightPink, shape: BoxShape.circle),
            child: const Icon(LucideIcons.searchCheck,
                color: AppColors.primaryPink, size: 40),
          ),
          const SizedBox(height: 20),
          Text('Verify your driver',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Enter a vehicle number above or\nscan the number plate.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppColors.textGrey),
          ),
        ],
      ),
    );
  }

  // ── Error state ────────────────────────────────────────────────────────────
  Widget _buildError(BuildContext context, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.cloudOff,
                color: AppColors.alertRed, size: 40),
            const SizedBox(height: 16),
            Text('Verification failed',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(error.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppColors.textGrey)),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => ref.read(verifyProvider.notifier).reset(),
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryPink,
                side: const BorderSide(color: AppColors.primaryPink),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  RESULT BODY
  // ══════════════════════════════════════════════════════════════════════════

  Widget _buildBody(BuildContext context, VerificationData data) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeaderCard(context, data),
          const SizedBox(height: 16),
          _buildDriverCard(context, data),
          const SizedBox(height: 16),
          _buildCredentialsCheck(context, data),
          const SizedBox(height: 16),
          _buildSafetyScore(context, data),
          const SizedBox(height: 16),
          _buildAiRouteWatching(context),
          const SizedBox(height: 32),
          Row(
            children: [
              // ── Share Driver Details ───────────────────────────────────
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _shareDriverDetails(data),
                  icon: const Icon(Icons.share_rounded, size: 17),
                  label: const Text('Share Details',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.buttonBlue,
                    foregroundColor: AppColors.buttonBlueText,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // ── Go to Trip Screen ──────────────────────────────────────
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ElevatedButton(
                      onPressed: _startJourney,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryPink,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding:
                            const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      child: const Center(
                          child: Text('Start Journey',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold))),
                    ),
                    Positioned(
                      right: -10,
                      top: -10,
                      bottom: -10,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: AppColors.primaryPink,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                  color: AppColors.primaryPink
                                      .withOpacity(0.4),
                                  blurRadius: 10)
                            ]),
                        child: const Icon(LucideIcons.asterisk,
                            color: Colors.white, size: 30),
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── PART 1 — Header card: status-based badge ──────────────────────────────
  Widget _buildHeaderCard(BuildContext context, VerificationData data) {
    // Derive badge appearance purely from driverStatus
    final Color badgeBg;
    final Color badgeFg;
    final IconData badgeIcon;

    switch (data.driverStatus) {
      case DriverStatus.active:
        badgeBg   = AppColors.safeGreen;
        badgeFg   = AppColors.safeGreenDark;
        badgeIcon = Icons.verified;
        break;
      case DriverStatus.suspended:
        badgeBg   = AppColors.alertBg;
        badgeFg   = AppColors.alertRed;
        badgeIcon = Icons.cancel_rounded;
        break;
      case DriverStatus.expired:
      default:
        badgeBg   = const Color(0xFFFFF3E0); // light orange
        badgeFg   = AppColors.warningOrange;
        badgeIcon = Icons.warning_amber_rounded;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Driver\nVerification',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      height: 1.2,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'GOVT VERIFIED',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppColors.textGrey,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(badgeIcon, size: 16, color: badgeFg),
                const SizedBox(width: 4),
                Text(
                  data.driverStatus.badgeLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: badgeFg,
                        fontWeight: FontWeight.bold,
                        fontSize: 9,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── PART 2 — Driver card: placeholder avatar (no network image) ───────────
  Widget _buildDriverCard(BuildContext context, VerificationData data) {
    // Status icon next to driver name
    final Color statusIconColor;
    final IconData statusIcon;
    switch (data.driverStatus) {
      case DriverStatus.active:
        statusIcon      = Icons.check_circle;
        statusIconColor = AppColors.safeGreenDark;
        break;
      case DriverStatus.suspended:
        statusIcon      = Icons.cancel_rounded;
        statusIconColor = AppColors.alertRed;
        break;
      default:
        statusIcon      = Icons.warning_amber_rounded;
        statusIconColor = AppColors.warningOrange;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          // ── PART 2: default placeholder avatar (no network, no asset) ───
          CircleAvatar(
            radius: 35,
            backgroundColor: AppColors.lightPink,
            child: Icon(
              Icons.person_rounded,
              size: 38,
              color: AppColors.primaryPink,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        data.driverName,
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(statusIcon, color: statusIconColor, size: 20),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  data.vehicleInfo,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textGrey),
                ),
                if (data.phone.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    data.phone,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textLight),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── PART 3 — Credentials check ────────────────────────────────────────────
  Widget _buildCredentialsCheck(BuildContext context, VerificationData data) {
    // Background check state: active=safe, expired=warning, suspended=danger
    final bgCheckState = data.bgCheckState;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Credentials Check',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),

          // License Number — always green + show actual number below label
          _buildCheckRow(
            context,
            icon:        LucideIcons.userSquare2,
            title:       'License Number',
            subtitle:    data.licenseVerified ? data.licenseNumber : 'Not available',
            state:       _CheckState.passed,
          ),
          const SizedBox(height: 12),

          // Vehicle Plate — always green (user entered it to reach this screen)
          _buildCheckRow(
            context,
            icon:  LucideIcons.car,
            title: 'Vehicle Plate',
            state: _CheckState.passed,
          ),
          const SizedBox(height: 12),

          // Background Check — status-driven
          _buildCheckRow(
            context,
            icon:  LucideIcons.alertTriangle,
            title: 'Background Check',
            state: switch (bgCheckState) {
              BgCheckState.safe    => _CheckState.passed,
              BgCheckState.warning => _CheckState.warning,
              BgCheckState.danger  => _CheckState.danger,
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCheckRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required _CheckState state,
  }) {
    final bool isWarning = state == _CheckState.warning;
    final bool isDanger  = state == _CheckState.danger;

    final Color rowBg = isDanger
        ? AppColors.alertBg
        : isWarning
            ? const Color(0xFFFFF8E1)  // very light amber
            : AppColors.cardWhite;

    final Color iconBg = (isDanger || isWarning)
        ? AppColors.cardWhite
        : AppColors.background;

    final Color iconColor =
        (isDanger || isWarning) ? AppColors.primaryPink : AppColors.textDark;

    final Widget trailingIcon = switch (state) {
      _CheckState.passed  => const Icon(Icons.check_circle,
          color: AppColors.safeGreenDark, size: 24),
      _CheckState.warning => const Icon(Icons.warning_amber_rounded,
          color: AppColors.warningOrange, size: 24),
      _CheckState.danger  => const Icon(Icons.cancel_rounded,
          color: AppColors.alertRed, size: 24),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: rowBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textDark),
                ),
                if (subtitle != null && subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: AppColors.textGrey,
                            fontWeight: FontWeight.w500),
                  ),
                ],
              ],
            ),
          ),
          trailingIcon,
        ],
      ),
    );
  }

  // ── PART 4 — AI Safety Score: status-driven label ─────────────────────────
  Widget _buildSafetyScore(BuildContext context, VerificationData data) {
    final Color scoreColor;
    if (data.safetyScore >= 80) {
      scoreColor = AppColors.safeGreenDark;
    } else if (data.safetyScore >= 60) {
      scoreColor = AppColors.warningOrange;
    } else {
      scoreColor = AppColors.alertRed;
    }

    // Split label into bold prefix + grey suffix on " — "
    final parts = data.safetyScoreLabel.split(' — ');
    final prefix = parts.first;
    final suffix = parts.length > 1 ? ' — ${parts.sublist(1).join(' — ')}' : '';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI Safety Score',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${data.safetyScore}',
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      color: scoreColor,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              Text(
                ' / 100',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: AppColors.textGrey),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Stack(
            children: [
              Container(
                height: 8,
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              FractionallySizedBox(
                widthFactor:
                    (data.safetyScore / 100).clamp(0.0, 1.0),
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: scoreColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          RichText(
            text: TextSpan(
              text: prefix,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scoreColor,
                    fontWeight: FontWeight.bold,
                  ),
              children: [
                TextSpan(
                  text: suffix,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.textGrey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── PART 5 — AI Route Watching (live, wired to tripProvider) ─────────────
  Widget _buildAiRouteWatching(BuildContext context) {
    // Watch trip state so card updates reactively when journey starts/stops.
    final tripState = ref.watch(tripProvider);
    final isActive  = tripState.isTripActive;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isActive ? AppColors.lightPink : AppColors.background,
        borderRadius: BorderRadius.circular(AppConstants.borderRadius),
        border: Border.all(
          color: isActive
              ? AppColors.primaryPink.withOpacity(0.3)
              : Colors.grey.shade200,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.primaryPink.withOpacity(0.2)
                  : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.brain,
              color: isActive ? AppColors.primaryPink : AppColors.textGrey,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'AI route watching',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                            color: isActive
                                ? AppColors.primaryPink
                                : AppColors.textGrey,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(width: 8),
                    // Live indicator dot
                    if (isActive)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: AppColors.safeGreenDark,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  isActive
                      ? "Monitoring your journey in real-time. You'll receive instant alerts if any route deviation or unexpected stops occur."
                      : "Press 'Start Journey' to activate real-time route monitoring.",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textDark.withOpacity(
                            isActive ? 0.7 : 0.4),
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
