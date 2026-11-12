import 'package:firebase_core/firebase_core.dart';

/// Firebase options for project **umiam-waterlevel**.
/// Values taken from `android/app/google-services.json`.
class DefaultFirebaseOptions {
  static const bool isConfigured = true;

  static FirebaseOptions get currentPlatform => const FirebaseOptions(
        apiKey: 'AIzaSyBHAQdfBcowfRfcEga0eqC95ADL-9KXtYM',
        appId: '1:435036676231:android:34afd9c60a373f30331822',
        messagingSenderId: '435036676231',
        projectId: 'umiam-waterlevel',
        databaseURL:
            'https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app',
        storageBucket: 'umiam-waterlevel.firebasestorage.app',
      );
}
