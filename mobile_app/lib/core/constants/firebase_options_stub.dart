import 'package:firebase_core/firebase_core.dart';

/// Placeholder Firebase options for project agri-db-fa27f.
/// Replace with real values from the Firebase console / FlutterFire CLI
/// before enabling live cloud sync.
class DefaultFirebaseOptions {
  static const bool isConfigured = false;

  static FirebaseOptions get currentPlatform => const FirebaseOptions(
        apiKey: 'YOUR_API_KEY',
        appId: 'YOUR_ANDROID_APP_ID',
        messagingSenderId: 'YOUR_SENDER_ID',
        projectId: 'agri-db-fa27f',
        databaseURL:
            'https://agri-db-fa27f-default-rtdb.asia-southeast1.firebasedatabase.app',
        storageBucket: 'agri-db-fa27f.appspot.com',
      );
}
