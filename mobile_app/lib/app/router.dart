import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/advanced/advanced_screen.dart';
import '../features/audit/audit_log_screen.dart';
import '../features/shell/shell_screen.dart';

final _rootKey = GlobalKey<NavigatorState>();

GoRouter createRouter() {
  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const ShellScreen(),
      ),
      // Old links land on the main shell (Setup / History are tabs).
      GoRoute(path: '/setup', redirect: (context, state) => '/'),
      GoRoute(path: '/readings', redirect: (context, state) => '/'),
      GoRoute(path: '/history', redirect: (context, state) => '/'),
      GoRoute(
        path: '/advanced',
        builder: (context, state) => const AdvancedScreen(),
      ),
      GoRoute(
        path: '/audit',
        builder: (context, state) => const AuditLogScreen(),
      ),
    ],
  );
}
