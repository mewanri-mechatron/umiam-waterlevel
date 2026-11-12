import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/constants/app_constants.dart';

/// Fallback only — normal use never needs this screen.
class AdvancedScreen extends ConsumerStatefulWidget {
  const AdvancedScreen({super.key});

  @override
  ConsumerState<AdvancedScreen> createState() => _AdvancedScreenState();
}

class _AdvancedScreenState extends ConsumerState<AdvancedScreen> {
  String? _note;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F7F5),
      appBar: AppBar(
        title: const Text('Advanced'),
        backgroundColor: const Color(0xFFF3F7F5),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text(
            'Only needed if automatic sync fails near the station.',
            style: GoogleFonts.manrope(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connect manually',
                    style: GoogleFonts.manrope(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Join SSID ${AppConstants.gatewaySsid} so the phone can pull readings from the ESP.',
                    style: const TextStyle(color: AppColors.muted, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() {
                              _busy = true;
                              _note = null;
                            });
                            final net = ref.read(networkServiceProvider);
                            final msg =
                                await net.requestGatewayWifiConnection();
                            // After join attempt, try one sync cycle.
                            await ref
                                .read(autoSyncControllerProvider)
                                .runCycle(force: true);
                            ref.invalidate(dashboardDataProvider);
                            if (!mounted) return;
                            setState(() {
                              _busy = false;
                              _note = msg;
                            });
                          },
                    child: Text(_busy ? 'Connecting…' : 'Connect to WaterLevel WiFi'),
                  ),
                ],
              ),
            ),
          ),
          if (_note != null) ...[
            const SizedBox(height: 14),
            Text(
              _note!,
              style: GoogleFonts.manrope(fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }
}
