import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app/theme.dart';

/// MePGCL logo path (same asset as web_dashboard/img/mepgcl-logo.png).
const kMepgclLogoAsset = 'assets/img/mepgcl-logo.png';

/// Top-of-app brand block — matches web dashboard header.
class MeeclBrandHeader extends StatelessWidget {
  const MeeclBrandHeader({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final logoW = compact ? 56.0 : 72.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.outline),
          ),
          padding: const EdgeInsets.all(4),
          child: Image.asset(
            kMepgclLogoAsset,
            width: logoW,
            height: logoW * 0.8,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Water Level Monitoring System',
                style: GoogleFonts.poppins(
                  fontSize: compact ? 15 : 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                  height: 1.2,
                  color: AppColors.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'MeECL Reservoir Monitoring & Early-Warning System',
                style: GoogleFonts.poppins(
                  color: AppColors.muted,
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dark MeECL footer — matches web_dashboard site-footer.
class MeeclSiteFooter extends StatelessWidget {
  const MeeclSiteFooter({super.key});

  static const _footerBg = Color(0xFF0F2924);
  static const _muted = Color(0xFF8FABA1);
  static const _link = Color(0xFFB7D4C8);
  static const _powered = Color(0xFF91CFBE);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: _footerBg,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(4),
                child: Image.asset(
                  kMepgclLogoAsset,
                  width: 48,
                  height: 38,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Water Level Monitoring System',
                      style: GoogleFonts.poppins(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Meghalaya Energy Corporation Limited',
                      style: GoogleFonts.poppins(
                        color: const Color(0xFFC5D8D0),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'A Government of Meghalaya Undertaking',
                      style: GoogleFonts.poppins(
                        color: _muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'VERSION 1.3.0',
            style: GoogleFonts.poppins(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'support@meecl.in',
            style: GoogleFonts.poppins(
              color: _link,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            '+91 364 222 2222',
            style: GoogleFonts.poppins(
              color: _link,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: const Color(0x29D7E5DF)),
          const SizedBox(height: 12),
          Text(
            '© 2026 Meghalaya Energy Corporation Limited. All rights reserved.',
            style: GoogleFonts.poppins(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Powered by Mechatron Private Limited.',
            style: GoogleFonts.poppins(
              color: _powered,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
