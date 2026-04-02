// lib/models/contact.dart
//
// Shared Contact model — imported by contacts_service.dart and contacts_screen.dart
// Extracted from contacts_screen.dart so other files can use it without a
// circular dependency.

class Contact {
  final String id;
  final String name;
  final String phone;

  const Contact({required this.id, required this.name, required this.phone});

  /// Round-trip serialisation for Firestore writes.
  Map<String, dynamic> toMap() => {'name': name, 'phone': phone};

  /// Reconstruct from a Firestore document snapshot.
  factory Contact.fromFirestore(String docId, Map<String, dynamic> data) {
    return Contact(
      id:    docId,
      name:  data['name']?.toString()  ?? '',
      phone: data['phone']?.toString() ?? '',
    );
  }
}
