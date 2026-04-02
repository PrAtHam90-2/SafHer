import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../core/theme/app_colors.dart';
// ignore: unused_import
import '../../core/constants/app_constants.dart';
import '../../services/alert_service.dart';
import '../../widgets/profile_avatar.dart';

enum PanicState { idle, pressing, activated }

class PanicNotifier extends Notifier<PanicState> {
  Timer? _timer;

  @override
  PanicState build() {
    return PanicState.idle;
  }

  void startHoldTimer(AlertService alertService) {
    if (state == PanicState.activated) return;

    state = PanicState.pressing;
    _timer = Timer(const Duration(seconds: 2), () async {
      state = PanicState.activated;
      await alertService.triggerSOS();
    });
  }

  void cancelHoldTimer() {
    if (state == PanicState.activated) return;

    _timer?.cancel();
    state = PanicState.idle;
  }
}

final panicStateProvider = NotifierProvider<PanicNotifier, PanicState>(() {
  return PanicNotifier();
});

class PanicScreen extends ConsumerWidget {
  const PanicScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(panicStateProvider);

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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Text(
              'Emergency SOS',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state == PanicState.activated
                  ? 'Emergency protocol initiated.'
                  : 'Hold for 2 seconds to activate',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: AppColors.textGrey),
            ),
            const SizedBox(height: 40),
            _buildPanicButton(context, ref, state),
            const SizedBox(height: 40),
            if (state == PanicState.activated)
              _buildActivatedProtocolList(context)
            else
              _buildIdleProtocolList(context),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildPanicButton(
    BuildContext context,
    WidgetRef ref,
    PanicState state,
  ) {
    double scale = state == PanicState.pressing ? 0.95 : 1.0;

    return GestureDetector(
      onTapDown: (_) {
        ref
            .read(panicStateProvider.notifier)
            .startHoldTimer(ref.read(alertServiceProvider));
      },
      onTapUp: (_) => ref.read(panicStateProvider.notifier).cancelHoldTimer(),
      onTapCancel: () =>
          ref.read(panicStateProvider.notifier).cancelHoldTimer(),
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Outer very light ring
            Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.05),
              ),
            ),
            // Middle light ring
            Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.15),
              ),
            ),
            // Inner solid red button
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: state == PanicState.activated
                    ? AppColors.safeGreenDark
                    : AppColors.primaryPink,
                boxShadow: [
                  BoxShadow(
                    color:
                        (state == PanicState.activated
                                ? AppColors.safeGreenDark
                                : AppColors.primaryPink)
                            .withOpacity(0.4),
                    blurRadius: 20,
                    spreadRadius: state == PanicState.pressing ? 10 : 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    state == PanicState.activated
                        ? LucideIcons.checkCircle2
                        : LucideIcons.siren,
                    color: Colors.white,
                    size: 40,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state == PanicState.activated ? 'SENT' : 'HOLD SOS',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIdleProtocolList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Safety Protocol',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.safeGreenLight,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'ACTIVE SCANNING',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.safeGreenDark,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildProtocolItem(
          context,
          'Real-time GPS shared with cloud',
          LucideIcons.mapPin,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Emergency contacts alerted via SMS',
          LucideIcons.users,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Nearest police station notified',
          LucideIcons.shieldAlert,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Continuous audio recording starts',
          LucideIcons.mic,
        ),
      ],
    );
  }

  Widget _buildActivatedProtocolList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'ALERT SENT',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppColors.primaryPink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _buildProtocolItem(
          context,
          'Real-time GPS is LIVE',
          LucideIcons.mapPin,
          isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'SMS delivered to 3 contacts',
          LucideIcons.users,
          isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Police unit dispatched (Est. 4 mins)',
          LucideIcons.shieldAlert,
          isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Audio recording in progress...',
          LucideIcons.mic,
          isActive: true,
        ),
        const SizedBox(height: 24),
        Center(
          child: TextButton(
            onPressed: () {},
            child: const Text(
              'CANCEL SOS (Requires PIN)',
              style: TextStyle(color: AppColors.textGrey),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProtocolItem(
    BuildContext context,
    String text,
    IconData icon, {
    bool isActive = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.safeGreenLight.withOpacity(0.3)
            : AppColors.cardWhite.withOpacity(0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: isActive ? AppColors.safeGreenDark : AppColors.primaryPink,
            size: 24,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.textDark,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
