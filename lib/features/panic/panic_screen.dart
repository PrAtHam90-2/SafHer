// lib/features/panic/panic_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../core/theme/app_colors.dart';
import '../../services/alert_service.dart';
import '../../services/voice_sos_service.dart'; // ← NEW
import '../../widgets/profile_avatar.dart';

// ============================================================================
//  SosState — sealed class hierarchy (UNCHANGED)
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

  int  get successCount   => contactResults.where((r) => r.success).length;
  bool get hasContacts    => contactResults.isNotEmpty;
  bool get locationShared => locationLink.isNotEmpty;
}

// ============================================================================
//  PanicNotifier (UNCHANGED except triggerSOSImmediately added)
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

  // ── NEW: called via ref.listen in PanicScreen when voice detects keyword ──
  // Bypasses the 2-second hold timer — fires SOS immediately.
  // Guarded: no-ops if SOS is already in flight or done.
  Future<void> triggerSOSImmediately() async {
    if (state is SosSending || state is SosDone) return;
    await _triggerSOS();
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
//  PanicScreen — converted to ConsumerStatefulWidget for pulse animation timer
// ============================================================================

class PanicScreen extends ConsumerStatefulWidget {
  const PanicScreen({super.key});

  @override
  ConsumerState<PanicScreen> createState() => _PanicScreenState();
}

class _PanicScreenState extends ConsumerState<PanicScreen> {
  // ── Simple timer-driven pulse for mic listening indicator ─────────────────
  Timer? _pulseTimer;
  bool   _pulseVisible = true;

  @override
  void initState() {
    super.initState();
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 850), (_) {
      if (mounted) setState(() => _pulseVisible = !_pulseVisible);
    });
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final state      = ref.watch(panicStateProvider);
    final voiceState = ref.watch(voiceSosProvider);

    // ── Voice trigger → fire existing SOS flow ────────────────────────────
    // VoiceSosNotifier sets status to [triggered] on keyword detection.
    // We observe that here and call the EXISTING _triggerSOS path inside
    // PanicNotifier — zero duplicate SOS logic.
    ref.listen<VoiceSosState>(voiceSosProvider, (prev, next) {
      if (next.isTriggered && !(prev?.isTriggered ?? false)) {
        ref.read(panicStateProvider.notifier).triggerSOSImmediately();
      }
    });

    // ── When SOS is cancelled → reset voice state to idle ────────────────
    ref.listen<SosState>(panicStateProvider, (prev, next) {
      if (prev is SosDone && next is SosIdle) {
        ref.read(voiceSosProvider.notifier).resetToIdle();
      }
    });

    final bool showVoiceCard = state is SosIdle || state is SosPressing;

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

            // ── Hold-to-activate button (UNCHANGED) ───────────────────────
            _buildPanicButton(context, state),

            // ── NEW: Voice SOS card (only shown before SOS fires) ─────────
            if (showVoiceCard) ...[
              const SizedBox(height: 20),
              _buildVoiceSosCard(context, voiceState),
              const SizedBox(height: 20),
            ] else
              const SizedBox(height: 40),

            // ── State-specific body ───────────────────────────────────────
            switch (state) {
              SosIdle()     => _buildIdleProtocolList(context),
              SosPressing() => _buildIdleProtocolList(context),
              SosSending()  => _buildSendingState(context),
              SosDone()     => _buildDoneState(context, state),
            },
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ── Subtitle (UNCHANGED) ───────────────────────────────────────────────────

  String _subtitleFor(SosState state) => switch (state) {
        SosIdle()     => 'Hold for 2 seconds to activate',
        SosPressing() => 'Keep holding…',
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

  // ── Panic button (UNCHANGED) ───────────────────────────────────────────────

  Widget _buildPanicButton(BuildContext context, SosState state) {
    final bool isActivated = state is SosSending || state is SosDone;
    final double scale = state is SosPressing ? 0.95 : 1.0;

    return GestureDetector(
      onTapDown:   (_) => ref.read(panicStateProvider.notifier).startHold(),
      onTapUp:     (_) => ref.read(panicStateProvider.notifier).cancelHold(),
      onTapCancel: ()  => ref.read(panicStateProvider.notifier).cancelHold(),
      child: AnimatedScale(
        scale:    scale,
        duration: const Duration(milliseconds: 100),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 250, height: 250,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.05),
              ),
            ),
            Container(
              width: 190, height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryPink.withOpacity(0.15),
              ),
            ),
            Container(
              width: 130, height: 130,
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
                      width: 36, height: 36,
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

  // ══════════════════════════════════════════════════════════════════════════
  //  NEW: Voice SOS card
  // ══════════════════════════════════════════════════════════════════════════
  //
  // Compact card — mic glow ring | mic button | status text | switch toggle.
  // Visible only while state is SosIdle or SosPressing (disappears when SOS
  // fires so the sending/done UI has full screen real-estate).

  Widget _buildVoiceSosCard(BuildContext context, VoiceSosState voiceState) {
    final bool listening = voiceState.isListening;
    final bool init      = voiceState.isInitializing;
    final bool triggered = voiceState.isTriggered;
    final bool error     = voiceState.hasError;

    // Animate glow opacity in sync with _pulseTimer while listening.
    final double glowOpacity =
        listening ? (_pulseVisible ? 0.25 : 0.06) : 0.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: triggered
            ? AppColors.safeGreenLight
            : listening
                ? AppColors.alertBg
                : AppColors.cardWhite.withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: triggered
              ? AppColors.safeGreenDark.withOpacity(0.4)
              : listening
                  ? AppColors.primaryPink.withOpacity(0.5)
                  : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          // ── Mic button with animated glow ring ─────────────────────────
          GestureDetector(
            onTap: (init || triggered)
                ? null
                : () => ref.read(voiceSosProvider.notifier).toggleListening(),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Pulsing outer glow
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 64, height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primaryPink.withOpacity(glowOpacity),
                  ),
                ),
                // Inner button
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: triggered
                        ? AppColors.safeGreenDark
                        : listening
                            ? AppColors.primaryPink
                            : AppColors.lightPink,
                  ),
                  child: init
                      ? const Center(
                          child: SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primaryPink,
                            ),
                          ),
                        )
                      : Icon(
                          triggered
                              ? LucideIcons.checkCircle2
                              : listening
                                  ? LucideIcons.micOff
                                  : LucideIcons.mic,
                          color: (listening || triggered)
                              ? Colors.white
                              : AppColors.primaryPink,
                          size: 22,
                        ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 14),

          // ── Status label (animated crossfade between states) ────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Voice SOS',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppColors.textDark,
                      ),
                ),
                const SizedBox(height: 3),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    _voiceStatusLabel(voiceState),
                    key: ValueKey(voiceState.status),
                    maxLines: 2,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: error
                              ? AppColors.primaryPink
                              : triggered
                                  ? AppColors.safeGreenDark
                                  : AppColors.textGrey,
                          fontWeight: (listening || triggered)
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // ── Toggle / retry control ──────────────────────────────────────
          if (!error && !triggered)
            Switch(
              // Bound to userEnabled so switch stays on after navigation.
              value:    voiceState.userEnabled || listening || init,
              onChanged: init
                  ? null
                  : (_) =>
                      ref.read(voiceSosProvider.notifier).toggleListening(),
              activeColor: AppColors.primaryPink,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          else if (error)
            TextButton(
              onPressed: () =>
                  ref.read(voiceSosProvider.notifier).toggleListening(),
              style: TextButton.styleFrom(
                padding:     EdgeInsets.zero,
                minimumSize: const Size(48, 32),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color:      AppColors.primaryPink,
                  fontWeight: FontWeight.bold,
                  fontSize:   13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _voiceStatusLabel(VoiceSosState vs) => switch (vs.status) {
        VoiceSosStatus.idle          => 'Toggle on to enable voice activation',
        VoiceSosStatus.initializing  => 'Requesting microphone access…',
        VoiceSosStatus.listening     => 'Listening for emergency phrase…',
        VoiceSosStatus.permissionDenied =>
          vs.message ?? 'Microphone permission denied — check Settings',
        VoiceSosStatus.unavailable   =>
          vs.message ?? 'Voice recognition unavailable. Tap to retry.',
        VoiceSosStatus.triggered     => 'Phrase detected — SOS activated!',
      };

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

  // ── Sending state (UNCHANGED) ─────────────────────────────────────────────

  Widget _buildSendingState(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _buildProtocolItem(
          context, 'Fetching your live GPS location…',
          LucideIcons.mapPin, isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context, 'Opening SMS app for your emergency contacts…',
          LucideIcons.messageCircle, isActive: true,
        ),
        const SizedBox(height: 12),
        _buildProtocolItem(
          context, 'Logging SOS event to Firestore…',
          LucideIcons.shieldAlert, isActive: true,
        ),
      ],
    );
  }

  // ── Done state (UNCHANGED) ────────────────────────────────────────────────

  Widget _buildDoneState(BuildContext context, SosDone state) {
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

        if (state.globalError != null) ...[
          _buildResultRow(
            context,
            icon:      LucideIcons.alertCircle,
            iconColor: AppColors.primaryPink,
            bgColor:   AppColors.alertBg,
            text:      state.globalError!,
            bold:      true,
          ),
          const SizedBox(height: 24),
        ] else if (!state.hasContacts) ...[
          _buildResultRow(
            context,
            icon:      LucideIcons.userX,
            iconColor: AppColors.warningOrange,
            bgColor:   AppColors.lightRed,
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
                    color:      AppColors.primaryPink,
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
        ] else ...[
          _buildResultRow(
            context,
            icon: state.locationShared
                ? LucideIcons.mapPin : LucideIcons.mapPinOff,
            iconColor: state.locationShared
                ? AppColors.safeGreenDark : AppColors.textGrey,
            bgColor: state.locationShared
                ? AppColors.safeGreenLight.withOpacity(0.3)
                : AppColors.cardWhite,
            text: state.locationShared
                ? 'Live GPS location included in message'
                : 'Location unavailable — message sent without GPS link',
          ),
          const SizedBox(height: 12),
          ...state.contactResults.map((r) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildResultRow(
                  context,
                  icon: r.success
                      ? LucideIcons.checkCircle2 : LucideIcons.xCircle,
                  iconColor: r.success
                      ? AppColors.safeGreenDark : AppColors.primaryPink,
                  bgColor: r.success
                      ? AppColors.safeGreenLight.withOpacity(0.3)
                      : AppColors.alertBg,
                  text: r.success
                      ? '${r.name} — SMS app opened'
                      : '${r.name} — Could not open SMS app',
                  bold: true,
                ),
              )),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.lightPink,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              state.usedCombinedUri
                  ? 'SMS app opened with ${state.successCount} '
                      'contact${state.successCount == 1 ? '' : 's'} — '
                      'tap Send to notify them.'
                  : 'SMS ready for ${state.successCount} of '
                      '${state.contactResults.length} contact'
                      '${state.contactResults.length == 1 ? '' : 's'}. '
                      'Return here to open remaining contacts.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color:      AppColors.primaryPink,
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
          if (!state.usedCombinedUri &&
              state.successCount < state.contactResults.length) ...[
            const SizedBox(height: 12),
            _buildResultRow(
              context,
              icon:      LucideIcons.info,
              iconColor: AppColors.warningOrange,
              bgColor:   AppColors.lightRed,
              text: 'Your SMS app opened for the first contact. '
                  'Return here after sending to open the next one.',
            ),
          ],
          const SizedBox(height: 24),
        ],

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

  // ── Shared widget: protocol item (UNCHANGED) ───────────────────────────────

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
                    color:      AppColors.textDark,
                    fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
