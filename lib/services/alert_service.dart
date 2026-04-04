// lib/services/alert_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/contact.dart';

// ============================================================================
//  SosContactResult — per-contact SMS launch outcome
//
//  [success] means the SMS app was successfully opened for this contact.
//  It does NOT mean the message was delivered — delivery confirmation
//  requires a server-side API (Twilio, Firebase Functions, etc.).
// ============================================================================

class SosContactResult {
  final String name;
  final String phone;

  /// true  → SMS app opened successfully for this contact.
  /// false → Device could not launch SMS app for this contact.
  final bool success;

  const SosContactResult({
    required this.name,
    required this.phone,
    required this.success,
  });
}

// ============================================================================
//  SosResult — full outcome returned by AlertService.triggerSOS()
// ============================================================================

class SosResult {
  /// Google Maps link from GPS at the moment SOS fired.
  /// Empty string when location was unavailable — SMS is still attempted.
  final String locationLink;

  /// One entry per emergency contact. Empty list means no contacts exist.
  final List<SosContactResult> contactResults;

  /// Non-null only when a global failure prevents ANY useful action.
  /// Individual send failures live inside [contactResults] instead.
  final String? globalError;

  /// True  → combined multi-recipient URI was used (one SMS app open).
  /// False → individual per-contact URIs were used (one open per contact).
  final bool usedCombinedUri;

  const SosResult({
    required this.locationLink,
    required this.contactResults,
    this.globalError,
    this.usedCombinedUri = false,
  });

  int get successCount => contactResults.where((r) => r.success).length;
}

// ============================================================================
//  AlertService
// ============================================================================

class AlertService {
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  AlertService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  // ── Main entry point ───────────────────────────────────────────────────────

  Future<SosResult> triggerSOS() async {
    // ── Step 1: Obtain current GPS position ─────────────────────────────────
    // Strategy: try a fresh high-accuracy fix (15 s timeout).
    // If that times out or fails, fall back to lastKnownPosition which
    // may be a few minutes old but is always better than nothing.
    // The Google Maps link remains valid as long as the user is nearby —
    // at SOS time we share a snapshot that contacts can open immediately.
    String locationLink = '';
    try {
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.denied &&
          permission != LocationPermission.deniedForever) {
        Position? position;
        try {
          position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
            ),
          ).timeout(const Duration(seconds: 15));
        } catch (_) {
          // Timed out or GPS not ready — use the last known position.
          position = await Geolocator.getLastKnownPosition();
        }

        if (position != null) {
          locationLink =
              'https://www.google.com/maps?q=${position.latitude},${position.longitude}';
        }
      }
    } catch (e) {
      debugPrint('AlertService: location unavailable — $e');
    }

    // ── Step 2: Fetch emergency contacts from Firestore ──────────────────────
    final uid = _auth.currentUser?.uid;
    List<Contact> contacts = [];

    if (uid != null) {
      try {
        final snap = await _db
            .collection('users')
            .doc(uid)
            .collection('contacts')
            .get();
        contacts = snap.docs
            .map((d) => Contact.fromFirestore(d.id, d.data()))
            .toList();
      } catch (e) {
        debugPrint('AlertService: failed to fetch contacts — $e');
      }
    }

    // Global failure — nothing actionable.
    if (contacts.isEmpty && locationLink.isEmpty && uid == null) {
      return const SosResult(
        locationLink: '',
        contactResults: [],
        globalError:
            'Could not reach emergency contacts or determine location.',
      );
    }

    // No contacts in Firestore — surface clearly so the user can add them.
    if (contacts.isEmpty) {
      return SosResult(
        locationLink: locationLink,
        contactResults: const [],
      );
    }

    // ── Step 3: Build the alert message ─────────────────────────────────────
    final message = locationLink.isNotEmpty
        ? '🚨 EMERGENCY! I need help. Track me live here: $locationLink'
        : '🚨 EMERGENCY! I need help. Please contact me immediately.';

    // ── Step 4: Open native SMS app ─────────────────────────────────────────
    final (results, usedCombined) = await _launchSms(
      contacts: contacts,
      message: message,
    );

    // ── Step 5: Persist SOS event to Firestore (fire-and-forget) ────────────
    if (uid != null) {
      _persistAlertEvent(
        uid: uid,
        locationLink: locationLink,
        results: results,
        usedCombinedUri: usedCombined,
      );
    }

    return SosResult(
      locationLink:    locationLink,
      contactResults:  results,
      usedCombinedUri: usedCombined,
    );
  }

  // ── SMS launcher ─────────────────────────────────────────────────────────
  //
  // Strategy
  // ────────
  // Attempt 1 — combined multi-recipient URI:
  //   sms:num1,num2,num3?body=<encoded_message>
  //   Opens the SMS app ONCE with all recipients pre-filled in one thread.
  //   Supported by: Google Messages (Android), Apple Messages (iOS).
  //   May not work on: Samsung One UI < 5, MIUI, some older OEM apps.
  //
  // Attempt 2 — individual per-contact URI (fallback):
  //   sms:num?body=<encoded_message>  — one URI per contact.
  //   ⚠ IMPORTANT: launchUrl() backgrounds the app after the first launch.
  //   The user must return to SafHer between opens. The UI communicates this.
  //
  // Android 11+ requirement
  // ───────────────────────
  // Add this inside <manifest> in android/app/src/main/AndroidManifest.xml:
  //
  //   <queries>
  //     <intent>
  //       <action android:name="android.intent.action.VIEW" />
  //       <data android:scheme="sms" />
  //     </intent>
  //     <intent>
  //       <action android:name="android.intent.action.SENDTO" />
  //       <data android:scheme="smsto" />
  //     </intent>
  //   </queries>
  //
  // Without this, canLaunchUrl() always returns false on Android 11+,
  // causing the fallback loop to mark every contact as failed.

  Future<(List<SosContactResult>, bool)> _launchSms({
    required List<Contact> contacts,
    required String message,
  }) async {
    // Encode the message body once.
    // Uri.encodeQueryComponent() uses application/x-www-form-urlencoded
    // encoding (spaces → '+'), which SMS apps on both platforms handle.
    final encodedBody = Uri.encodeQueryComponent(message);

    // ── Attempt 1: combined multi-recipient URI ───────────────────────────
    final phones = contacts.map((c) => c.phone.trim()).join(',');
    // Use Uri.parse (not Uri constructor) because the sms: scheme is
    // non-standard and Uri() would double-encode the already-encoded body.
    final combinedUri = Uri.parse('sms:$phones?body=$encodedBody');

    try {
      if (await canLaunchUrl(combinedUri)) {
        await launchUrl(combinedUri, mode: LaunchMode.externalApplication);
        // All contacts reached in one open — mark everyone as success.
        return (
          contacts
              .map((c) => SosContactResult(
                    name: c.name, phone: c.phone, success: true))
              .toList(),
          true, // usedCombinedUri
        );
      }
    } catch (e) {
      debugPrint('AlertService: combined SMS URI failed — $e');
    }

    // ── Attempt 2: individual URI per contact ─────────────────────────────
    debugPrint('AlertService: falling back to per-contact SMS URIs');
    final results = <SosContactResult>[];

    for (final contact in contacts) {
      final uri =
          Uri.parse('sms:${contact.phone.trim()}?body=$encodedBody');
      bool opened = false;
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          opened = true;
        }
      } catch (e) {
        debugPrint(
            'AlertService: could not open SMS for ${contact.name} — $e');
      }
      results.add(SosContactResult(
          name: contact.name, phone: contact.phone, success: opened));
    }

    return (results, false); // usedCombinedUri = false
  }

  // ── Firestore persistence ─────────────────────────────────────────────────
  //
  // Collection: users/{uid}/alerts/{autoId}
  // Fields:
  //   timestamp        Timestamp  (server-generated)
  //   locationLink     String
  //   usedCombinedUri  bool
  //   contactsNotified [ { name, phone, success } ]
  //   totalContacts    int
  //   successCount     int

  void _persistAlertEvent({
    required String uid,
    required String locationLink,
    required List<SosContactResult> results,
    required bool usedCombinedUri,
  }) {
    _db
        .collection('users')
        .doc(uid)
        .collection('alerts')
        .add({
          'timestamp':       FieldValue.serverTimestamp(),
          'locationLink':    locationLink,
          'usedCombinedUri': usedCombinedUri,
          'contactsNotified': results
              .map((r) =>
                  {'name': r.name, 'phone': r.phone, 'success': r.success})
              .toList(),
          'totalContacts': results.length,
          'successCount':  results.where((r) => r.success).length,
        })
        .catchError((e) =>
            debugPrint('AlertService: failed to persist alert — $e'));
  }
}

// ============================================================================
//  Provider
// ============================================================================

final alertServiceProvider = Provider<AlertService>((ref) => AlertService());
