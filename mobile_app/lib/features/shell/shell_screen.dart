import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../history/history_screen.dart';
import '../home/home_screen.dart';
import '../setup/setup_screen.dart';

/// Simple 3-tab app: Level · History · Setup.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomeScreen(), HistoryScreen(), SetupScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: Colors.white,
        indicatorColor: AppColors.tealSoft.withValues(alpha: 0.35),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.water_drop_outlined),
            selectedIcon: Icon(Icons.water_drop, color: AppColors.deepTeal),
            label: 'Level',
          ),
          NavigationDestination(
            icon: Icon(Icons.timeline_outlined),
            selectedIcon: Icon(Icons.timeline, color: AppColors.deepTeal),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune, color: AppColors.deepTeal),
            label: 'Setup',
          ),
        ],
      ),
    );
  }
}
