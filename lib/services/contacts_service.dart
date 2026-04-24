// lib/services/contacts_service.dart
//
// Replaces the in-memory ContactsNotifier that lived inside contacts_screen.dart.
// This version persists contacts to Firestore under:
//   users/{uid}/contacts/{docId}
//
// The notifier is an AsyncNotifier so the UI can handle loading / error states
// gracefully (e.g., show a spinner on first load, surface errors without crashing).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/contact.dart';

// ============================================================================
//  ContactsNotifier — Firestore-backed AsyncNotifier
// ============================================================================

class ContactsNotifier extends AsyncNotifier<List<Contact>> {
  // Convenience accessor — throws if the user is not logged in (shouldn't
  // happen since the auth gate guards all screens, but defensive).
  CollectionReference<Map<String, dynamic>> get _col {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    assert(uid != null, 'ContactsNotifier: user must be logged in');
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('contacts');
  }

  // ── build: called once on provider creation, returns initial state ─────────

  @override
  Future<List<Contact>> build() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return [];

    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('contacts')
        .orderBy('name')
        .get();

    return snap.docs
        .map((d) => Contact.fromFirestore(d.id, d.data()))
        .toList();
  }

  // ── add: write to Firestore, then update local state optimistically ─────────

  Future<void> add(String name, String phone) async {
    final trimmedName  = name.trim();
    final trimmedPhone = phone.trim();
    if (trimmedName.isEmpty || trimmedPhone.isEmpty) return;

    // Defense-in-depth: reject oversized strings even if UI validation is bypassed.
    if (trimmedName.length > 50 || trimmedPhone.length > 15) return;

    // Optimistic: add a temp entry with a placeholder id so the UI updates
    // instantly (replaces it once the Firestore write returns the real docId).
    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    final tempContact = Contact(id: tempId, name: trimmedName, phone: trimmedPhone);

    final current = state.value ?? [];
    state = AsyncData([...current, tempContact]);

    try {
      final docRef = await _col.add(tempContact.toMap());

      // Replace the temp entry with the real Firestore id
      state = AsyncData(
        (state.value ?? []).map((c) {
          return c.id == tempId
              ? Contact(id: docRef.id, name: trimmedName, phone: trimmedPhone)
              : c;
        }).toList(),
      );
    } catch (e) {
      // Roll back on failure
      state = AsyncData(
        (state.value ?? []).where((c) => c.id != tempId).toList(),
      );
      // Re-surface the error so the UI can show a snackbar
      rethrow;
    }
  }

  // ── remove: delete from Firestore, optimistic local removal ────────────────

  Future<void> remove(String id) async {
    final previous = state.value ?? [];

    // Optimistic remove
    state = AsyncData(previous.where((c) => c.id != id).toList());

    try {
      await _col.doc(id).delete();
    } catch (e) {
      // Roll back on failure
      state = AsyncData(previous);
      rethrow;
    }
  }
}

// ============================================================================
//  Provider
// ============================================================================

final contactsProvider =
    AsyncNotifierProvider<ContactsNotifier, List<Contact>>(
  ContactsNotifier.new,
);
