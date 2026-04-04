// lib/services/voice_sos_service.dart
//
// Voice-activated SOS trigger.
//
// DESIGN
// ──────
// • User-initiated only — listening starts and stops on explicit user action.
// • No background recording — the mic is released the moment listening stops.
// • Keyword detection — case-insensitive substring match against a phrase list.
// • When a keyword is detected, the notifier sets its state to [triggered].
//   PanicScreen listens for that transition via ref.listen and calls
//   panicNotifier.triggerSOSImmediately() — no SOS logic lives here.
// • The provider is autoDispose so the mic is freed when the SOS screen
//   is no longer in the widget tree.
//
// PERMISSIONS REQUIRED (add to your platform files — see bottom of file)
// ────────────────────────────────────────────────────────────────────────
// Android : RECORD_AUDIO in AndroidManifest.xml
// iOS     : NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription
//           in ios/Runner/Info.plist
//
// TRIGGER PHRASES
// ───────────────
// Ordered most-specific → least-specific.
// Matching is a case-insensitive *contains* check on the full recognised
// utterance, so "please help me now" still matches "help me".

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

// ── Trigger phrase list ──────────────────────────────────────────────────────

const _kTriggerPhrases = <String>[
  'help me',
  'call help',
  'save me',
  'emergency',
  'sos',
  'help',
];

// ============================================================================
//  VoiceSosStatus
// ============================================================================

enum VoiceSosStatus {
  /// Default — not listening, no error.
  idle,

  /// Permission check + STT initialisation in progress.
  initializing,

  /// Actively listening for trigger phrases.
  listening,

  /// Mic / speech-recognition permission was denied by the user.
  permissionDenied,

  /// Device does not support speech recognition.
  unavailable,

  /// A trigger phrase was recognised; SOS has been fired.
  triggered,
}

// ============================================================================
//  VoiceSosState
// ============================================================================

class VoiceSosState {
  final VoiceSosStatus status;

  /// Optional detail message shown in the UI (errors, triggered phrase).
  final String? message;

  /// Whether the user has enabled Voice SOS — persists across navigation.
  /// Saved to Firestore so it survives app restarts.
  final bool userEnabled;

  const VoiceSosState({
    required this.status,
    this.message,
    this.userEnabled = false,
  });

  bool get isListening    => status == VoiceSosStatus.listening;
  bool get isInitializing => status == VoiceSosStatus.initializing;
  bool get isTriggered    => status == VoiceSosStatus.triggered;

  bool get hasError =>
      status == VoiceSosStatus.permissionDenied ||
      status == VoiceSosStatus.unavailable;

  VoiceSosState copyWith({VoiceSosStatus? status, String? message, bool? userEnabled}) =>
      VoiceSosState(
        status:      status      ?? this.status,
        message:     message     ?? this.message,
        userEnabled: userEnabled ?? this.userEnabled,
      );
}

// ============================================================================
//  VoiceSosService — thin speech_to_text wrapper (no Riverpod)
// ============================================================================

class VoiceSosService {
  VoiceSosService({
    required this.onKeywordDetected,
    required this.onStatusChanged,
    required this.onError,
  });

  final void Function(String phrase) onKeywordDetected;
  final void Function(bool isListening) onStatusChanged;
  final void Function(String error) onError;

  final SpeechToText _speech = SpeechToText();

  bool _initialized   = false;
  bool _wantListening = false; // user-intent flag — drives auto-restart

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Initialises the recogniser and requests mic permission.
  /// Returns true if speech recognition is available and permitted.
  Future<bool> initialize() async {
    if (_initialized) return _speech.isAvailable;
    try {
      _initialized = await _speech.initialize(
        onError:      (err) => onError(err.errorMsg),
        onStatus:     _onStatus,
        debugLogging: false,
      );
    } catch (e) {
      debugPrint('VoiceSosService: init failed — $e');
      _initialized = false;
    }
    return _initialized && _speech.isAvailable;
  }

  // ── Public control ─────────────────────────────────────────────────────────

  Future<void> startListening() async {
    _wantListening = true;
    if (!_initialized || !_speech.isAvailable) {
      onError('Speech recognition unavailable.');
      return;
    }
    await _beginListen();
  }

  Future<void> stopListening() async {
    _wantListening = false;
    if (_speech.isListening) await _speech.stop();
    onStatusChanged(false);
  }

  Future<void> dispose() async {
    _wantListening = false;
    if (_speech.isListening) await _speech.stop();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _beginListen() async {
    if (!_wantListening || _speech.isListening) return;
    try {
      await _speech.listen(
        onResult:   _onResult,
        // 30-second max per session; auto-restarts via _onStatus.
        listenFor:  const Duration(seconds: 30),
        // 4-second silence window before the engine finalises the result.
        pauseFor:   const Duration(seconds: 4),
        localeId:   'en_US',
        listenMode: ListenMode.dictation, // capture more words per utterance
      );
      onStatusChanged(true);
    } catch (e) {
      debugPrint('VoiceSosService: listen error — $e');
      onStatusChanged(false);
    }
  }

  void _onStatus(String status) {
    debugPrint('VoiceSosService: status → $status');

    // When the engine reaches end-of-session or silence timeout, auto-restart
    // so the user stays in continuous listening mode without re-tapping.
    if (status == 'done' || status == 'notListening') {
      if (_wantListening) {
        // Brief pause prevents a tight restart loop on repeated errors.
        Future.delayed(const Duration(milliseconds: 600), _beginListen);
      } else {
        onStatusChanged(false);
      }
    } else if (status == 'listening') {
      onStatusChanged(true);
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    // Process both interim and final results — catches phrases before
    // the engine commits to a "final" transcription.
    final words = result.recognizedWords.toLowerCase().trim();
    if (words.isEmpty) return;
    debugPrint('VoiceSosService: recognised → "$words"');

    for (final phrase in _kTriggerPhrases) {
      if (words.contains(phrase)) {
        debugPrint('VoiceSosService: keyword match → "$phrase"');
        // Stop immediately — one trigger per session.
        _wantListening = false;
        onKeywordDetected(phrase);
        return;
      }
    }
  }
}

// ============================================================================
//  VoiceSosNotifier
// ============================================================================

class VoiceSosNotifier extends Notifier<VoiceSosState> {
  VoiceSosService? _service;

  // ── Firestore persistence helpers ──────────────────────────────────────────
  static const _kVoiceSosField = 'voiceSosEnabled';

  DocumentReference<Map<String, dynamic>>? get _settingsDoc {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('settings')
        .doc('preferences');
  }

  Future<void> _persistEnabled(bool enabled) async {
    try {
      await _settingsDoc?.set(
        {_kVoiceSosField: enabled},
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint('VoiceSosNotifier: failed to persist — $e');
    }
  }

  Future<bool> _loadEnabled() async {
    try {
      final snap = await _settingsDoc?.get();
      return (snap?.data()?[_kVoiceSosField] as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  VoiceSosState build() {
    // Keep provider alive across navigation — mic persists while app is open.
    // The provider is NOT autoDispose so VoiceSosNotifier is a singleton
    // for the lifetime of the ProviderScope.
    //
    // Restore the previously saved enabled state from Firestore on first build.
    _restoreState();

    ref.onDispose(() async {
      await _service?.dispose();
      _service = null;
    });
    return const VoiceSosState(status: VoiceSosStatus.idle);
  }

  Future<void> _restoreState() async {
    final wasEnabled = await _loadEnabled();
    if (wasEnabled) {
      // User had Voice SOS enabled last session — resume listening automatically.
      await _startListening(userInitiated: false);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Toggle: starts listening if idle/triggered/errored; stops if listening.
  /// Also persists the intent to Firestore.
  Future<void> toggleListening() async {
    if (state.isListening) {
      await _stopListening();
      await _persistEnabled(false);
    } else {
      await _startListening(userInitiated: true);
    }
  }

  /// Resets back to idle after SOS is cancelled.
  /// Does NOT clear the userEnabled flag — user must explicitly toggle off.
  void resetToIdle() {
    if (state.isListening) _service?.stopListening();
    // Restart listening if the user still has it enabled.
    if (state.userEnabled) {
      state = state.copyWith(status: VoiceSosStatus.idle);
      _startListening(userInitiated: false);
    } else {
      state = const VoiceSosState(status: VoiceSosStatus.idle);
    }
  }

  // ── Private ────────────────────────────────────────────────────────────────

  Future<void> _startListening({bool userInitiated = true}) async {
    if (state.isInitializing) return;
    state = state.copyWith(status: VoiceSosStatus.initializing);

    _service = VoiceSosService(
      onKeywordDetected: _onKeyword,
      onStatusChanged:   _onStatusChanged,
      onError:           _onError,
    );

    final available = await _service!.initialize();

    if (!available) {
      await _service?.dispose();
      _service = null;
      state = VoiceSosState(
        status:      VoiceSosStatus.permissionDenied,
        userEnabled: state.userEnabled,
        message:     'Microphone access denied or unavailable.\n'
                     'Enable it in Settings to use Voice SOS.',
      );
      return;
    }

    // Persist enabled state only on explicit user action, not on auto-restore.
    if (userInitiated) await _persistEnabled(true);

    // Mark userEnabled so the UI switch stays on and auto-resume works.
    state = state.copyWith(userEnabled: true);

    await _service!.startListening();
  }

  Future<void> _stopListening() async {
    await _service?.stopListening();
    state = VoiceSosState(status: VoiceSosStatus.idle, userEnabled: false);
  }

  void _onStatusChanged(bool isListening) {
    // Never overwrite [triggered] — the keyword was already matched.
    if (state.isTriggered) return;

    if (isListening && !state.isListening) {
      state = const VoiceSosState(status: VoiceSosStatus.listening);
    }
    // isListening=false during auto-restart: keep showing [listening] so
    // the UI does not flicker during the 600 ms restart window.
    // Explicit stop (_stopListening) always sets state directly.
  }

  void _onKeyword(String phrase) {
    _service?.dispose();
    _service = null;

    state = state.copyWith(
      status:  VoiceSosStatus.triggered,
      message: 'Phrase detected: "$phrase"',
    );
    // PanicScreen observes this via ref.listen → calls triggerSOSImmediately().
  }

  void _onError(String error) {
    debugPrint('VoiceSosService error: $error');
    if (state.isListening || state.isInitializing) {
      state = state.copyWith(
        status:  VoiceSosStatus.unavailable,
        message: 'Voice recognition interrupted. Tap to retry.',
      );
    }
  }
}

// ============================================================================
//  Provider
// ============================================================================

/// Non-autoDispose — mic stays alive while the app is open.
/// State is restored from Firestore on first build.
final voiceSosProvider =
    NotifierProvider<VoiceSosNotifier, VoiceSosState>(
  VoiceSosNotifier.new,
);

// ============================================================================
//  PLATFORM PERMISSION SETUP — copy these snippets into your project
// ============================================================================
//
// ── ANDROID ─────────────────────────────────────────────────────────────────
// File: android/app/src/main/AndroidManifest.xml
// Add inside <manifest> (outside <application>):
//
//   <uses-permission android:name="android.permission.RECORD_AUDIO"/>
//   <uses-permission android:name="android.permission.INTERNET"/>
//
// Add inside <manifest> for Android 11+ package visibility:
//
//   <queries>
//     <intent>
//       <action android:name="android.speech.RecognitionService" />
//     </intent>
//   </queries>
//
// ── iOS ──────────────────────────────────────────────────────────────────────
// File: ios/Runner/Info.plist
// Add inside the root <dict>:
//
//   <key>NSMicrophoneUsageDescription</key>
//   <string>SafHer needs microphone access to listen for your emergency phrase and activate SOS hands-free.</string>
//   <key>NSSpeechRecognitionUsageDescription</key>
//   <string>SafHer uses speech recognition to detect emergency phrases like "help me" and activate SOS automatically.</string>
//
// ─────────────────────────────────────────────────────────────────────────────
