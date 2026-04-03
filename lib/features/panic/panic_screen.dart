// lib/features/panic/panic_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../core/theme/app_colors.dart';
import '../../services/alert_service.dart';
import '../../widgets/profile_avatar.dart';

// ============================================================================
//  SosState — sealed class hierarchy
// ============================================================================

sealed class SosState {
  const SosState();
}

class SosIdle extends SosState {
  const SosIdle();
}

class SosPressing extends SosState {
  const SosPressing();
}

/// Location + contacts are being fetched and the SMS app is about to open.
class SosSending extends SosState {
  const SosSending();
}

/// SMS app was launched (or failed). Shows per-contact results.
class SosDone extends SosState {
  final String locationLink;
  final List<SosContactResult> contactResults;
  final String? globalError;

  /// True  → combined multi-recipient URI was used (one app open).
  /// False → individual URIs were used (one open per contact, app backgrounds).
  final bool usedCombinedUri;

  const SosDone({
    required this.locationLink,
    required this.contactResults,
    this.globalError,
    this.usedCombinedUri = false,
  });

  int  get successCount  => contactResults.where((r) => r.success).length;
  bool get hasContacts   => contactResults.isNotEmpty;
  bool get locationShared => locationLink.isNotEmpty;
}

// ============================================================================
//  PanicNotifier
// ============================================================================

class PanicNotifier extends Notifier<SosState> {
  Timer? _holdTimer;

  @override
  SosState build() => const SosIdle();

  void startHold() {
    if (state is! SosIdle) return;
    state = const SosPressing();
    _holdTimer = Timer(const Duration(seconds: 2), _triggerSOS);
  }

  void cancelHold() {
    if (state is! SosPressing) return;
    _holdTimer?.cancel();
    state = const SosIdle();
  }

  Future<void> _triggerSOS() async {
    state = const SosSending();
    try {
      final result = await ref.read(alertServiceProvider).triggerSOS();
      state = SosDone(
        locationLink:    result.locationLink,
        contactResults:  result.contactResults,
        globalError:     result.globalError,
        usedCombinedUri: result.usedCombinedUri,
      );
    } catch (e) {
      state = const SosDone(
        locationLink:   '',
        contactResults: [],
        globalError:
            'Something went wrong. Please call emergency services directly.',
      );
    }
  }

  void reset() {
    _holdTimer?.cancel();
    state = const SosIdle();
  }
}

final panicStateProvider = NotifierProvider<PanicNotifier, SosState>(() {
  return PanicNotifier();
});

// ============================================================================
//  PanicScreen
// ============================================================================

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
              _subtitleFor(state),
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: AppColors.textGrey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),
            _buildPanicButton(context, ref, state),
            const SizedBox(height: 40),
            switch (state) {
              SosIdle()     => _buildIdleProtocolList(context),
              SosPressing() => _buildIdleProtocolList(context),
              SosSending()  => _buildSendingState(context),
              SosDone()     => _buildDoneState(context, ref, state),
            },
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ── Subtitle ───────────────────────────────────────────────────────────────

  String _subtitleFor(SosState state) => switch (state) {
        SosIdle()     => 'Hold for 2 seconds to activate',
        SosPressing() => 'Keep holding…',
        // CHANGED: reflects that we're opening an SMS app, not sending via API
        SosSending()  => 'Opening SMS app for your contacts…',
        SosDone(hasContacts: false, globalError: null) =>
          'No emergency contacts found.',
        SosDone(globalError: final e) when e != null =>
          'Something went wrong.',
        SosDone(usedCombinedUri: true, successCount: final n) =>
          'SMS app opened for $n contact${n == 1 ? '' : 's'} — tap Send.',
        SosDone(successCount: final n) =>
          'SMS ready for $n contact${n == 1 ? '' : 's'} — tap Send each time.',
      };

  // ── Panic button (layout UNCHANGED) ───────────────────────────────────────

  Widget _buildPanicButton(
    BuildContext context,
    WidgetRef ref,
    SosState state,
  ) {
    final bool isActivated = state is SosSending || state is SosDone;
    final double scale = state is SosPressing ? 0.95 : 1.0;

    return GestureDetector(
      onTapDown: (_) => ref.read(panicStateProvider.notifier).startHold(),
      onTapUp: (_) => ref.read(panicStateProvider.notifier).cancelHold(),
      onTapCancel: () => ref.read(panicStateProvider.notifier).cancelHold(),
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 100),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.05),
              ),
            ),
            Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.15),
              ),
            ),
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActivated
                    ? AppColors.safeGreenDark
                    : AppColors.primaryPink,
                boxShadow: [
                  BoxShadow(
                    color: (isActivated
                            ? AppColors.safeGreenDark
                            : AppColors.primaryPink)
                        .withOpacity(0.4),
                    blurRadius: 20,
                    spreadRadius: state is SosPressing ? 10 : 0,
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (state is SosSending)
                    const SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 3),
                    )
                  else
                    Icon(
                      isActivated
                          ? LucideIcons.checkCircle2
                          : LucideIcons.siren,
                      color: Colors.white,
                      size: 40,
                    ),
                  const SizedBox(height: 8),
                  Text(
                    state is SosSending
                        ? 'OPENING'
                        : isActivated
                            ? 'SENT'
                            : 'HOLD SOS',
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

  // ── Idle protocol list (UNCHANGED) ────────────────────────────────────────

  Widget _buildIdleProtocolList(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Safety Protocol',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w900),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
            context, 'Real-time GPS shared with cloud', LucideIcons.mapPin),
        const SizedBox(height: 12),
        _buildProtocolItem(
            context, 'Emergency contacts alerted via SMS', LucideIcons.users),
        const SizedBox(height: 12),
        _buildProtocolItem(
            context, 'Nearest police station notified', LucideIcons.shieldAlert),
        const SizedBox(height: 12),
        _buildProtocolItem(
            context, 'Continuous audio recording starts', LucideIcons.mic),
      ],
    );
  }

  // ── Sending state — CHANGED: reflects SMS app-open flow ──────────────────

  Widget _buildSendingState(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _buildProtocolItem(
          context,
          'Fetching your live GPS location…',
          LucideIcons.mapPin,
          isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Opening SMS app for your emergency contacts…',
          LucideIcons.messageCircle,
          isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context,
          'Logging SOS event to Firestore…',
          LucideIcons.shieldAlert,
          isActive: true,
        ),
      ],
    );
  }

  // ── Done state — CHANGED: copy reflects SMS-open semantics ───────────────

  Widget _buildDoneState(
    BuildContext context,
    WidgetRef ref,
    SosDone state,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SMS APP OPENED',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppColors.primaryPink,
              ),
        ),
        const SizedBox(height: 20),

        // ── Global error ────────────────────────────────────────────────
        if (state.globalError != null) ...[
          _buildResultRow(
            context,
            icon: LucideIcons.alertCircle,
            iconColor: AppColors.primaryPink,
            bgColor: AppColors.alertBg,
            text: state.globalError!,
            bold: true,
          ),
          const SizedBox(height: 24),
        ]

        // ── No contacts ─────────────────────────────────────────────────
        else if (!state.hasContacts) ...[
          _buildResultRow(
            context,
            icon: LucideIcons.userX,
            iconColor: AppColors.warningOrange,
            bgColor: AppColors.lightRed,
            text: 'No emergency contacts found. Please add contacts first.',
            bold: true,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => context.go('/contacts'),
              icon: const Icon(LucideIcons.userPlus,
                  color: AppColors.primaryPink),
              label: const Text(
                'Add Emergency Contacts',
                style: TextStyle(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.primaryPink),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ]

        // ── Per-contact results ─────────────────────────────────────────
        else ...[
          // Location row
          _buildResultRow(
            context,
            icon: state.locationShared
                ? LucideIcons.mapPin
                : LucideIcons.mapPinOff,
            iconColor: state.locationShared
                ? AppColors.safeGreenDark
                : AppColors.textGrey,
            bgColor: state.locationShared
                ? AppColors.safeGreenLight.withOpacity(0.3)
                : AppColors.cardWhite,
            text: state.locationShared
                ? 'Live GPS location included in message'
                : 'Location unavailable — message sent without GPS link',
          ),
          const SizedBox(height: 12),

          // Per-contact rows
          ...state.contactResults.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildResultRow(
                  context,
                  icon: r.success
                      ? LucideIcons.checkCircle2
                      : LucideIcons.xCircle,
                  iconColor: r.success
                      ? AppColors.safeGreenDark
                      : AppColors.primaryPink,
                  bgColor: r.success
                      ? AppColors.safeGreenLight.withOpacity(0.3)
                      : AppColors.alertBg,
                  // CHANGED: "SMS ready" not "Alert sent" — user must still tap Send
                  text: r.success
                      ? '${r.name} — SMS app opened'
                      : '${r.name} — Could not open SMS app',
                  bold: true,
                ),
              )),

          // ── Summary pill: combined vs individual ────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.lightPink,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              state.usedCombinedUri
                  // Combined: one open, all contacts in one thread
                  ? 'SMS app opened with ${state.successCount} '
                      'contact${state.successCount == 1 ? '' : 's'} — '
                      'tap Send to notify them.'
                  // Individual: app went to background; user must re-open for each remaining
                  : 'SMS ready for ${state.successCount} of '
                      '${state.contactResults.length} contact'
                      '${state.contactResults.length == 1 ? '' : 's'}. '
                      'Return here to open remaining contacts.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.primaryPink,
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
          ),

          // ── "Return to open next contact" prompt for per-contact mode ─
          if (!state.usedCombinedUri &&
              state.successCount < state.contactResults.length) ...[
            const SizedBox(height: 12),
            _buildResultRow(
              context,
              icon: LucideIcons.info,
              iconColor: AppColors.warningOrange,
              bgColor: AppColors.lightRed,
              text: 'Your SMS app opened for the first contact. '
                  'Return here after sending to open the next one.',
            ),
          ],

          const SizedBox(height: 24),
        ],

        // ── Cancel / reset (UNCHANGED) ──────────────────────────────────
        Center(
          child: TextButton(
            onPressed: () =>
                ref.read(panicStateProvider.notifier).reset(),
            child: const Text(
              'CANCEL SOS (Requires PIN)',
              style: TextStyle(color: AppColors.textGrey),
            ),
          ),
        ),
      ],
    );
  }

  // ── Shared widget: protocol row (UNCHANGED) ────────────────────────────────

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
                    fontWeight:
                        isActive ? FontWeight.bold : FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared widget: result row (UNCHANGED) ─────────────────────────────────

  Widget _buildResultRow(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String text,
    bool bold = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textDark,
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
