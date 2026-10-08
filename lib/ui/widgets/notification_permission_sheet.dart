import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/notification_service.dart';
import '../../services/session_prefs.dart';

const _ink = Color(0xFF1A1C24);
const _bodyGrey = Color(0xFF757575);
const _hintGrey = Color(0xFFBDBDBD);
const _cardGrey = Color(0xFFF3F4F6);
const _iconGrey = Color(0xFFE8EAED);

enum NotificationPromptKind { auth, glowUp }

/// Bottom sheet styled like a native notification prompt — stacked cards,
/// soft shadows, enable / skip actions.
class NotificationPermissionSheet extends StatelessWidget {
  const NotificationPermissionSheet({super.key, required this.kind});

  final NotificationPromptKind kind;

  /// Shows once after auth unless the user already completed this step.
  static Future<void> promptAfterAuthIfNeeded(BuildContext context) async {
    if (await SessionPrefs.notificationPromptCompleted()) return;
    if (await NotificationService.instance.hasNotificationPermission()) {
      await SessionPrefs.setNotificationPromptCompleted(true);
      await SessionPrefs.setGlowUpNotificationPromptCompleted(true);
      return;
    }
    if (!context.mounted) return;
    await _show(context, NotificationPromptKind.auth);
  }

  /// Glow-up flow — when AI starts or the user leaves to wait in background.
  static Future<void> promptForGlowUpIfNeeded(BuildContext context) async {
    if (await SessionPrefs.glowUpNotificationPromptCompleted()) return;
    if (await NotificationService.instance.hasNotificationPermission()) {
      await SessionPrefs.setGlowUpNotificationPromptCompleted(true);
      return;
    }
    if (!context.mounted) return;
    await _show(context, NotificationPromptKind.glowUp);
  }

  static Future<void> _show(
    BuildContext context,
    NotificationPromptKind kind,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      isDismissible: true,
      enableDrag: true,
      builder: (_) => NotificationPermissionSheet(kind: kind),
    );
  }

  Future<void> _enable(BuildContext context) async {
    await _markCompleted();
    if (context.mounted) Navigator.of(context).pop();
    await NotificationService.instance.requestPermissionAfterAuth();
  }

  Future<void> _skip(BuildContext context) async {
    await _markCompleted();
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _markCompleted() async {
    if (kind == NotificationPromptKind.auth) {
      await SessionPrefs.setNotificationPromptCompleted(true);
      await SessionPrefs.setGlowUpNotificationPromptCompleted(true);
    } else {
      await SessionPrefs.setGlowUpNotificationPromptCompleted(true);
    }
  }

  String get _title => switch (kind) {
        NotificationPromptKind.auth => 'Get Real-Time Alerts',
        NotificationPromptKind.glowUp => 'Know When Your Glow Up Is Ready',
      };

  String get _body => switch (kind) {
        NotificationPromptKind.auth =>
          'Get instant updates when your glow-up is ready, '
          'treatment reminders, and clinic news — so you never '
          'miss a step in your aesthetic journey.',
        NotificationPromptKind.glowUp =>
          'Turn on alerts so we can ping you the moment your '
          'before & after preview is finished — even if you leave '
          'the app while AI is working.',
      };

  @override
  Widget build(BuildContext context) {
    final inter = GoogleFonts.inter;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE0E0E0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: [
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 200,
                child: _DotGridBackground(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Column(
                  children: [
                    _NotificationCardStack(kind: kind),
                    const SizedBox(height: 28),
                    Text(
                      _title,
                      textAlign: TextAlign.center,
                      style: inter(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                        height: 1.15,
                        letterSpacing: -0.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _body,
                      textAlign: TextAlign.center,
                      style: inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: _bodyGrey,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 28, 20, bottom + 16),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => _enable(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: _ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: Text(
                      'Enable Notifications',
                      style: inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => _skip(context),
                  style: TextButton.styleFrom(
                    foregroundColor: _hintGrey,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  child: Text(
                    "I don't want to receive any notifications",
                    textAlign: TextAlign.center,
                    style: inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: _hintGrey,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DotGridBackground extends StatelessWidget {
  const _DotGridBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DotGridPainter());
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFE8EAED);
    const step = 14.0;
    const r = 1.2;
    for (var x = step / 2; x < size.width; x += step) {
      for (var y = step / 2; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NotificationCardStack extends StatelessWidget {
  const _NotificationCardStack({required this.kind});

  final NotificationPromptKind kind;

  @override
  Widget build(BuildContext context) {
    final back = kind == NotificationPromptKind.glowUp
        ? (
            title: 'Studio portrait',
            body: 'Your before photo is being prepared.',
            time: '2m ago',
          )
        : (
            title: 'Treatment reminder',
            body: 'Your check-in is scheduled for tomorrow.',
            time: '1h ago',
          );
    final mid = kind == NotificationPromptKind.glowUp
        ? (
            title: 'Analysis running',
            body: 'AI is building your glow-up preview.',
            time: '1m ago',
          )
        : (
            title: 'Clinic update',
            body: 'New availability near you this week.',
            time: '3h ago',
          );

    return SizedBox(
      height: 168,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: 0,
            left: 28,
            right: 28,
            child: Opacity(
              opacity: 0.32,
              child: Transform.translate(
                offset: const Offset(0, 4),
                child: _NotificationCard(
                  title: back.title,
                  body: back.body,
                  time: back.time,
                  elevation: 4,
                ),
              ),
            ),
          ),
          Positioned(
            top: 18,
            left: 14,
            right: 14,
            child: Opacity(
              opacity: 0.52,
              child: Transform.translate(
                offset: const Offset(0, 2),
                child: _NotificationCard(
                  title: mid.title,
                  body: mid.body,
                  time: mid.time,
                  elevation: 8,
                ),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _NotificationCard(
              title: 'Glow up ready',
              body: 'Your before & after preview is ready to view.',
              time: 'now',
              elevation: 16,
              prominent: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.title,
    required this.body,
    required this.time,
    this.elevation = 12,
    this.prominent = false,
  });

  final String title;
  final String body;
  final String time;
  final double elevation;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final inter = GoogleFonts.inter;

    return Material(
      color: Colors.white,
      elevation: 0,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: prominent ? 0.10 : 0.06),
              blurRadius: elevation,
              offset: Offset(0, elevation * 0.35),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _iconGrey,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    value: prominent ? 1.0 : 0.72,
                    strokeWidth: 2.5,
                    backgroundColor: _cardGrey,
                    color: _ink,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _ink,
                          ),
                        ),
                      ),
                      Text(
                        time,
                        style: inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: _hintGrey,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: _bodyGrey,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
