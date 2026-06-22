import 'package:google_sign_in/google_sign_in.dart';

/// The signed-in Google user plus the ID token the server verifies.
class GoogleUser {
  GoogleUser({
    required this.id,
    required this.email,
    required this.idToken,
    this.name,
    this.photoUrl,
  });

  final String id;
  final String email;
  final String? name;
  final String? photoUrl;

  /// Google-signed JWT; sent to the server (`POST /v1/auth/google`) for verification.
  final String idToken;
}

/// Thin wrapper around `google_sign_in` v7.
///
/// Requires a **Web OAuth client ID** as `serverClientId` so Google returns an
/// ID token whose audience the backend can verify. Provide it at build time:
///
///   flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=XXXX.apps.googleusercontent.com
///
/// An Android OAuth client (app package + signing SHA-1) must also exist in the
/// same Google Cloud project for sign-in to succeed on device.
class GoogleAuthService {
  static const _serverClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Whether a server client ID was supplied at build time.
  bool get isConfigured => _serverClientId.isNotEmpty;

  bool _initialized = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: _serverClientId);
    _initialized = true;
  }

  /// Interactive sign-in. Throws [GoogleAuthException] with a readable message
  /// on misconfiguration or if no ID token comes back.
  Future<GoogleUser> signIn() async {
    if (!isConfigured) {
      throw GoogleAuthException(
        'Google sign-in is not configured. Rebuild with '
        '--dart-define=GOOGLE_SERVER_CLIENT_ID=<web-client-id>.',
      );
    }
    await _ensureInitialized();

    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw GoogleAuthException(
        'Google sign-in is not supported on this platform.',
      );
    }

    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw GoogleAuthException(
        'No ID token returned — verify the serverClientId matches the server.',
      );
    }
    return GoogleUser(
      id: account.id,
      email: account.email,
      name: account.displayName,
      photoUrl: account.photoUrl,
      idToken: idToken,
    );
  }

  Future<void> signOut() async {
    if (_initialized) {
      await GoogleSignIn.instance.signOut();
    }
  }
}

class GoogleAuthException implements Exception {
  GoogleAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
