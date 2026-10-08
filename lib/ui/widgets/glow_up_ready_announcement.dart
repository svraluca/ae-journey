import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/app_navigator.dart';

/// Center-screen glow-up announcement (on-brand dark card over dimmed backdrop).
enum GlowUpAnnouncementKind { studioReady, reportReady }

class GlowUpReadyAnnouncement extends StatelessWidget {
  const GlowUpReadyAnnouncement({
    super.key,
    required this.kind,
    required this.onView,
    required this.onLater,
    this.glowScore,
    this.potentialScore,
    this.upliftPercent,
  });

  final GlowUpAnnouncementKind kind;
  final VoidCallback onView;
  final VoidCallback onLater;
  final int? glowScore;
  final int? potentialScore;
  final int? upliftPercent;

  static const _ink = Color(0xFF111114);
  static const _muted = Color(0xFF8E8E93);
  static const _mutedDark = Color(0xFF555555);
  static const _brand = Color(0xFF1C1C2E);
  static const _upliftGreen = Color(0xFFA8D5A2);

  @override
  Widget build(BuildContext context) {
    final isReport = kind == GlowUpAnnouncementKind.reportReady;
    final score = glowScore?.clamp(0, 100);
    final potential = potentialScore?.clamp(0, 100);
    final uplift = upliftPercent;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onLater,
      child: Center(
        child: GestureDetector(
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _ink,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                    width: 0.5,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _headerRow(),
                      const SizedBox(height: 18),
                      if (isReport && score != null) ...[
                        _scoreRow(score: score, isReport: true),
                        const SizedBox(height: 16),
                        _progressBar(fraction: (score / 100).clamp(0.0, 1.0)),
                        if (potential != null) ...[
                          const SizedBox(height: 16),
                          _upliftRow(
                            original: score,
                            potential: potential,
                            uplift: uplift,
                          ),
                        ],
                        const SizedBox(height: 16),
                        Divider(
                          height: 0.5,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        const SizedBox(height: 16),
                      ] else ...[
                        _scoreRow(score: null, isReport: false),
                        const SizedBox(height: 16),
                        _progressBar(fraction: 1.0),
                        const SizedBox(height: 16),
                        Divider(
                          height: 0.5,
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                        const SizedBox(height: 16),
                      ],
                      _actions(isReport: isReport),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerRow() {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _brand,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.auto_awesome, size: 13, color: Colors.white),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'ÆSTHETIC JOURNEY',
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 2.5,
            color: _muted,
          ),
        ),
        const Spacer(),
        Text(
          'just now',
          style: GoogleFonts.urbanist(fontSize: 11, color: _mutedDark),
        ),
      ],
    );
  }

  Widget _scoreRow({required int? score, required bool isReport}) {
    final title = isReport ? 'Your glow-up\nis ready' : 'Your studio portrait\nis ready';
    final sub = isReport ? 'AI analysis complete' : 'Step 1 complete';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isReport && score != null)
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$score',
                  style: GoogleFonts.urbanist(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
                Text(
                  '/100',
                  style: GoogleFonts.urbanist(fontSize: 9, color: _mutedDark),
                ),
              ],
            ),
          )
        else
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.camera_enhance_outlined, size: 22, color: Colors.white.withValues(alpha: 0.85)),
          ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isReport ? 'GLOW SCORE' : 'STUDIO EDIT',
                style: GoogleFonts.urbanist(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: _muted,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                title,
                style: GoogleFonts.urbanist(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                style: GoogleFonts.urbanist(fontSize: 12, color: _mutedDark),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressBar({required double fraction}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          value: fraction,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          minHeight: 3,
        ),
      ),
    );
  }

  Widget _upliftRow({
    required int original,
    required int potential,
    int? uplift,
  }) {
    final upliftLabel = uplift != null ? '+$uplift%' : '—';
    return Row(
      children: [
        Expanded(child: _upliftCell('$original', 'Original')),
        Container(width: 0.5, height: 32, color: Colors.white.withValues(alpha: 0.08)),
        Expanded(child: _upliftCell('$potential', 'Potential')),
        Container(width: 0.5, height: 32, color: Colors.white.withValues(alpha: 0.08)),
        Expanded(
          child: _upliftCell(upliftLabel, 'Uplift', valueColor: _upliftGreen),
        ),
      ],
    );
  }

  Widget _upliftCell(String value, String label, {Color? valueColor}) {
    return Column(
      children: [
        Text(
          value,
          style: GoogleFonts.urbanist(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: valueColor ?? Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GoogleFonts.urbanist(fontSize: 10, color: _mutedDark),
        ),
      ],
    );
  }

  Widget _actions({required bool isReport}) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: onView,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF111111),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: Text(isReport ? 'View my report' : 'Continue glow-up'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: onLater,
            style: OutlinedButton.styleFrom(
              foregroundColor: _muted,
              backgroundColor: Colors.white.withValues(alpha: 0.07),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 0.5),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              textStyle: GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            child: const Text('Later'),
          ),
        ),
      ],
    );
  }
}

/// Shows the centered announcement over the current route stack.
Future<void> showGlowUpReadyAnnouncement({
  required GlowUpAnnouncementKind kind,
  required VoidCallback onView,
  VoidCallback? onLater,
  int? glowScore,
  int? potentialScore,
  int? upliftPercent,
}) {
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null) return Future.value();

  return showGeneralDialog<void>(
    context: ctx,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.5),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (context, animation, secondaryAnimation) {
      void dismiss() {
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
      }

      return GlowUpReadyAnnouncement(
        kind: kind,
        glowScore: glowScore,
        potentialScore: potentialScore,
        upliftPercent: upliftPercent,
        onView: () {
          dismiss();
          onView();
        },
        onLater: () {
          dismiss();
          onLater?.call();
        },
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curve),
          child: child,
        ),
      );
    },
  );
}
