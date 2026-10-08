import 'package:flutter/material.dart';

import '../data/procedure_repository.dart';
import '../services/auth_service.dart';
import 'app_shell.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Light "confirming purchase" loader shown right after the user taps the CTA.
class SubscriptionProcessingScreen extends StatefulWidget {
  const SubscriptionProcessingScreen({
    super.key,
    this.repo,
    required this.planKey,
    required this.planTitle,
    required this.priceLine,
  });

  final ProcedureRepository? repo;
  /// `monthly` | `yearly` | `lifetime`
  final String planKey;
  final String planTitle;
  final String priceLine;

  @override
  State<SubscriptionProcessingScreen> createState() => _SubscriptionProcessingScreenState();
}

class _SubscriptionProcessingScreenState extends State<SubscriptionProcessingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  static const _hold = Duration(milliseconds: 2200);

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(_hold, () async {
      if (!mounted) return;
      try {
        await AuthService().setSubscriptionPlan(
          plan: widget.planKey,
          planTitle: widget.planTitle,
          status: 'trial',
        );
      } catch (e, st) {
        debugPrint('setSubscriptionPlan: $e\n$st');
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 450),
          pageBuilder: (context, animation, secondaryAnimation) => SubscriptionSuccessScreen(
            repo: widget.repo,
            planTitle: widget.planTitle,
            priceLine: widget.priceLine,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              child: child,
            );
          },
        ),
      );
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
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              ProcedureSelectionTheme.pageBackgroundTop,
              ProcedureSelectionTheme.pageBackground,
              ProcedureSelectionTheme.pageBackgroundBottom,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(999),
                  compact: true,
                  child: SizedBox(
                    width: 88,
                    height: 88,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Image.asset('assets/logoapp.PNG', fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Activating your passport',
                  textAlign: TextAlign.center,
                  style: ProcedureSelectionTypography.display(
                    size: 18,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Confirming your purchase',
                  style: ProcedureSelectionTypography.body(
                    size: 13,
                    color: ProcedureSelectionTheme.muted,
                  ),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: AnimatedBuilder(
                    animation: _c,
                    builder: (context, _) => CircularProgressIndicator(
                      value: null,
                      strokeWidth: 2.4,
                      color: ProcedureSelectionTheme.ink.withValues(alpha: 0.55),
                      backgroundColor: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Post-purchase thank-you screen — light glass vibe matching Timeline.
class SubscriptionSuccessScreen extends StatefulWidget {
  const SubscriptionSuccessScreen({
    super.key,
    this.repo,
    this.planTitle = 'Yearly Pro',
    this.priceLine = r'yearly plan · $24.99 · 3-day trial',
    this.onDone,
    this.onShare,
  });

  final ProcedureRepository? repo;
  final String planTitle;
  final String priceLine;
  final VoidCallback? onDone;
  final VoidCallback? onShare;

  @override
  State<SubscriptionSuccessScreen> createState() => _SubscriptionSuccessScreenState();
}

class _SubscriptionSuccessScreenState extends State<SubscriptionSuccessScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late final Animation<double> _stampScale = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
  );
  late final Animation<double> _stampFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
  );
  late final Animation<double> _topFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.12, 0.5, curve: Curves.easeOut),
  );
  late final Animation<double> _planFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.4, 0.8, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _cardFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.55, 0.95, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _barFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.7, 1.0, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  void _done() {
    if (widget.onDone != null) {
      widget.onDone!();
      return;
    }
    final repo = widget.repo;
    if (repo != null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => AppShell(repo: repo)),
        (route) => false,
      );
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Widget _slideFade(Animation<double> a, Widget child, {double dy = 16}) {
    return AnimatedBuilder(
      animation: a,
      builder: (context, _) => Opacity(
        opacity: a.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - a.value) * dy),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              ProcedureSelectionTheme.pageBackgroundTop,
              ProcedureSelectionTheme.pageBackground,
              ProcedureSelectionTheme.pageBackgroundBottom,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + bottomPad),
            child: Column(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _slideFade(
                        _topFade,
                        Column(
                          children: [
                            const ProcedureSectionLabel('Today · your first day'),
                            const SizedBox(height: 10),
                            Text(
                              'Passport activated',
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.display(
                                size: 24,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                          ],
                        ),
                        dy: -10,
                      ),
                      const SizedBox(height: 28),
                      AnimatedBuilder(
                        animation: _entrance,
                        builder: (context, child) => Opacity(
                          opacity: _stampFade.value.clamp(0.0, 1.0),
                          child: Transform.scale(
                            scale: 0.72 + _stampScale.value * 0.28,
                            child: child,
                          ),
                        ),
                        child: ProcedureGlassSurface(
                          borderRadius: BorderRadius.circular(999),
                          compact: true,
                          child: SizedBox(
                            width: 120,
                            height: 120,
                            child: Padding(
                              padding: const EdgeInsets.all(26),
                              child: Image.asset(
                                'assets/logoapp.PNG',
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      _slideFade(
                        _planFade,
                        Column(
                          children: [
                            Text(
                              widget.planTitle,
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.display(
                                size: 28,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Full passport access',
                              style: ProcedureSelectionTypography.body(
                                size: 13,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      _slideFade(_cardFade, _planCard()),
                    ],
                  ),
                ),
                _slideFade(_barFade, _bottomBar()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _planCard() {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: ProcedureSelectionTheme.buttonPrimary,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Activated just now',
                    style: ProcedureSelectionTypography.label(
                      size: 10,
                      color: ProcedureSelectionTheme.sectionLabel,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'ÆSTHETIC JOURNEY',
                    style: ProcedureSelectionTypography.display(
                      size: 14,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.priceLine,
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
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

  Widget _bottomBar() {
    return Row(
      children: [
        Expanded(
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            compact: true,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => widget.onShare?.call(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.ios_share_rounded, size: 17, color: ProcedureSelectionTheme.ink),
                      const SizedBox(width: 8),
                      Text(
                        'Share',
                        style: ProcedureSelectionTypography.label(
                          size: 14,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Material(
            color: ProcedureSelectionTheme.buttonPrimary,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: _done,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 15),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_rounded, size: 17, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'Done',
                      style: ProcedureSelectionTypography.label(
                        size: 14,
                        weight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
