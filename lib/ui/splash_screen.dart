import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import '../services/notification_service.dart';
import '../services/session_prefs.dart';
import 'post_auth_stamp_splash.dart';
import 'welcome_screen2.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  late final Animation<double> _up = Tween<double>(begin: 10, end: 0).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  late final Animation<double> _textFade = CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.65, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future<void>.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      Future<void>(() async {
        final keep = await SessionPrefs.keepSignedIn();
        final auth = FirebaseAuth.instance;
        if (!keep && auth.currentUser != null) {
          await auth.signOut();
        }
        if (!mounted) return;
        final isAuthed = auth.currentUser != null;
        if (isAuthed) {
          await NotificationService.instance.initialize(requestPermission: false);
        }
        if (!mounted) return;
        if (isAuthed) {
          // Soften into AirDrop: dissolve brand on black, then hand off.
          await _c.animateTo(
            0,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOutCubic,
          );
          if (!mounted) return;
          openHomeWithStampSplash(context, widget.repo);
          return;
        }
        Navigator.of(context).pushReplacement(
          PageRouteBuilder<void>(
            transitionDuration: const Duration(milliseconds: 650),
            reverseTransitionDuration: const Duration(milliseconds: 350),
            pageBuilder: (context, animation, secondaryAnimation) =>
                WelcomeScreen2(repo: widget.repo),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              final fade = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
              final slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
              return FadeTransition(
                opacity: fade,
                child: SlideTransition(position: slide, child: child),
              );
            },
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            return Opacity(
              opacity: _fade.value,
              child: Transform.translate(
                offset: Offset(0, _up.value),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: _textFade.value,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'ÆSTHETIC JOURNEY',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                              letterSpacing: 2.5,
                              color: Colors.white,
                              height: 1.0,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Every Change. One Place.',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.urbanist(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.65),
                              height: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

