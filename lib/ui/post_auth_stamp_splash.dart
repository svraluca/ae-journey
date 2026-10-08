import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import '../services/session_prefs.dart';
import 'app_shell.dart';
import 'explore_procedure_interests_screen.dart';
import 'widgets/airdrop_light_field.dart';
import 'widgets/thinking_orb.dart';

const _paperBg = Color(0xFFF5F3EF);
const _muted = Color(0xFFBBBBBB);

void openHomeWithStampSplash(BuildContext context, ProcedureRepository repo) {
  Navigator.of(context).pushAndRemoveUntil(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 700),
      reverseTransitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (context, animation, secondaryAnimation) =>
          PostAuthStampSplash(repo: repo),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        // Stay on black so splash → AirDrop (also starts black) never flashes cream.
        final fadeIn = CurvedAnimation(
          parent: animation,
          curve: Curves.easeInOutCubic,
        );
        return ColoredBox(
          color: Colors.black,
          child: FadeTransition(
            opacity: fadeIn,
            child: child,
          ),
        );
      },
    ),
    (_) => false,
  );
}

class PostAuthStampSplash extends StatefulWidget {
  const PostAuthStampSplash({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<PostAuthStampSplash> createState() => _PostAuthStampSplashState();
}

class _PostAuthStampSplashState extends State<PostAuthStampSplash>
    with TickerProviderStateMixin {
  static const _lightPhaseEnd = 0.55;
  static const _sealPhaseStart = 0.58;

  static const _timeline = Duration(milliseconds: 5500);
  static const _hold = Duration(milliseconds: 2200);
  static const _exitDuration = Duration(milliseconds: 900);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _timeline,
  );

  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _exitDuration,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
    Future<void>.delayed(_timeline + _hold, _startExit);
  }

  void _startExit() {
    if (!mounted) return;
    _exit.forward();
    _goHome();
  }

  Future<void> _goHome() async {
    if (!mounted) return;
    final interestsDone = await SessionPrefs.exploreInterestsCompleted();
    if (!mounted) return;

    if (!interestsDone) {
      final repo = widget.repo;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: _exitDuration,
          reverseTransitionDuration: _exitDuration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              ExploreProcedureInterestsScreen(
            repo: repo,
            homeBuilder: (_) => AppShell(repo: repo),
          ),
          transitionsBuilder: _softFadeIn,
        ),
        (_) => false,
      );
      return;
    }

    Navigator.of(context).pushAndRemoveUntil(
      _homeRoute(),
      (_) => false,
    );
  }

  PageRouteBuilder<void> _homeRoute() {
    return PageRouteBuilder<void>(
      transitionDuration: _exitDuration,
      reverseTransitionDuration: _exitDuration,
      pageBuilder: (context, animation, secondaryAnimation) =>
          AppShell(repo: widget.repo),
      transitionsBuilder: _softFadeIn,
    );
  }

  Widget _softFadeIn(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return ColoredBox(
      color: _paperBg,
      child: FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          scale: Tween<double>(begin: 1.03, end: 1.0).animate(fade),
          child: child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_c, _exit]),
      builder: (context, _) {
        final t = _c.value;
        final exitT = Curves.easeInOut.transform(_exit.value);

        final paperT = Curves.easeInOut.transform(
          ((t - 0.42) / 0.32).clamp(0.0, 1.0),
        );
        final airdropOpacity = (1.0 -
                Curves.easeIn.transform(((t - 0.52) / 0.20).clamp(0.0, 1.0)))
            .clamp(0.0, 1.0);
        final sealT = Curves.easeOut.transform(
          ((t - _sealPhaseStart) / 0.32).clamp(0.0, 1.0),
        );

        final bgColor = Color.lerp(Colors.black, _paperBg, paperT)!;

        return ColoredBox(
          color: bgColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (airdropOpacity > 0.01)
                Opacity(
                  opacity: airdropOpacity,
                  child: AirdropLightField(
                    progress: (t / _lightPhaseEnd).clamp(0.0, 1.0),
                    paperReveal: paperT,
                  ),
                ),
              if (paperT > 0.08)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: _paperBg.withValues(
                        alpha: (paperT * (1.0 - airdropOpacity * 0.35)).clamp(0.0, 1.0),
                      ),
                    ),
                  ),
                ),
              if (sealT > 0)
                Opacity(
                  opacity: (1.0 - exitT).clamp(0.0, 1.0),
                  child: Transform.scale(
                    scale: 1.0 + 0.05 * exitT,
                    child: _PassportReadyMinimal(sealOpacity: sealT),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _PassportReadyMinimal extends StatelessWidget {
  const _PassportReadyMinimal({required this.sealOpacity});

  final double sealOpacity;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Opacity(
        opacity: sealOpacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: 0.94 + 0.06 * Curves.easeOutBack.transform(sealOpacity.clamp(0.0, 1.0)),
          child: const Center(
            child: _PassportSeal(size: 172),
          ),
        ),
      ),
    );
  }
}

class _PassportSeal extends StatelessWidget {
  const _PassportSeal({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final mono = GoogleFonts.jetBrainsMono;
    final scale = size / 120;
    final orbSize = size * 0.72;

    return SizedBox(
      width: size,
      height: size,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ThinkingWorkingOrb(size: orbSize),
          SizedBox(height: size * 0.04),
          Text(
            'WELCOME',
            style: mono(
              fontSize: 8.5 * scale,
              fontWeight: FontWeight.w500,
              letterSpacing: 1.8,
              color: _muted,
              decoration: TextDecoration.none,
              decorationColor: Colors.transparent,
            ),
          ),
        ],
      ),
    );
  }
}
