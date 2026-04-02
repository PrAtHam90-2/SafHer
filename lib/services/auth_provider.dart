import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================================
//  Auth state stream
// ============================================================================

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.authStateChanges();
});

// ============================================================================
//  AuthService — Google Sign-In via Firebase's built-in GoogleAuthProvider
//  (no google_sign_in package needed)
// ============================================================================

class AuthService {
  final _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;

  Future<void> signInWithGoogle() async {
    final googleProvider = GoogleAuthProvider();
    // Opens the Google account picker using Firebase's native flow.
    // Works on Android/iOS without the google_sign_in package.
    await _auth.signInWithProvider(googleProvider);
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
