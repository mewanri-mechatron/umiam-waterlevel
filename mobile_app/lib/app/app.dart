import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class WaterLevelApp extends ConsumerWidget {
  WaterLevelApp({super.key});

  final _router = createRouter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Water Level Monitoring System',
      theme: buildAppTheme(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
