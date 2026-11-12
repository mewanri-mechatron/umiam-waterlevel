import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/advanced/advanced_screen.dart';
import '../features/home/home_screen.dart';

final _rootKey = GlobalKey<NavigatorState>();

GoRouter createRouter() {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/advanced',
        builder: (context, state) => const AdvancedScreen(),
      ),
    ],
  );
}
