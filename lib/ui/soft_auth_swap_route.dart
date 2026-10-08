import 'package:flutter/material.dart';

import 'procedure_selection_theme.dart';

/// Soft cream wash + fade/slide between login ↔ signup (and similar auth peers).
class SoftAuthSwapRoute<T> extends PageRouteBuilder<T> {
  SoftAuthSwapRoute({
    required Widget page,
    /// `true` = slide in from the right (e.g. login → signup).
    this.forward = true,
  }) : super(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 620),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            final dx = forward ? 0.055 : -0.055;
            final slide = Tween<Offset>(
              begin: Offset(dx, 0.018),
              end: Offset.zero,
            ).animate(enter);

            final fade = CurvedAnimation(
              parent: animation,
              curve: const Interval(0.0, 0.85, curve: Curves.easeOut),
            );

            final veil = TweenSequence<double>([
              TweenSequenceItem(
                tween: Tween(begin: 0.0, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut)),
                weight: 38,
              ),
              TweenSequenceItem(
                tween: Tween(begin: 1.0, end: 0.0)
                    .chain(CurveTween(curve: Curves.easeIn)),
                weight: 62,
              ),
            ]).animate(animation);

            return ColoredBox(
              color: ProcedureSelectionTheme.pageBackground,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FadeTransition(
                    opacity: fade,
                    child: SlideTransition(
                      position: slide,
                      child: child,
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: veil,
                      builder: (context, _) {
                        final v = veil.value;
                        if (v <= 0.01) return const SizedBox.shrink();
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: Alignment(forward ? 0.15 : -0.15, 0.35),
                              radius: 1.2,
                              colors: [
                                Colors.white.withValues(alpha: 0.78 * v),
                                const Color(0xFFEAE6E5).withValues(alpha: 0.5 * v),
                                const Color(0xFFEAE6E5).withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.42, 1.0],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );

  final bool forward;
}

/// Soft cream wash into welcome (e.g. after logout).
class SoftWelcomeRoute<T> extends PageRouteBuilder<T> {
  SoftWelcomeRoute({required Widget page})
      : super(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 780),
          reverseTransitionDuration: const Duration(milliseconds: 420),
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final veil = TweenSequence<double>([
              TweenSequenceItem(
                tween: Tween(begin: 0.0, end: 1.0)
                    .chain(CurveTween(curve: Curves.easeOut)),
                weight: 40,
              ),
              TweenSequenceItem(
                tween: Tween(begin: 1.0, end: 0.0)
                    .chain(CurveTween(curve: Curves.easeIn)),
                weight: 60,
              ),
            ]).animate(animation);

            final slide = Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(enter);
            final scale = Tween<double>(begin: 0.96, end: 1.0).animate(enter);
            final fade = Tween<double>(begin: 0.0, end: 1.0).animate(
              CurvedAnimation(
                parent: animation,
                curve: const Interval(0.08, 1.0, curve: Curves.easeOut),
              ),
            );

            return ColoredBox(
              color: ProcedureSelectionTheme.pageBackground,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FadeTransition(
                    opacity: fade,
                    child: SlideTransition(
                      position: slide,
                      child: ScaleTransition(
                        scale: scale,
                        child: child,
                      ),
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedBuilder(
                      animation: veil,
                      builder: (context, _) {
                        final v = veil.value;
                        if (v <= 0.01) return const SizedBox.shrink();
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: const Alignment(0, 0.2),
                              radius: 1.15,
                              colors: [
                                Colors.white.withValues(alpha: 0.78 * v),
                                const Color(0xFFEAE6E5).withValues(alpha: 0.55 * v),
                                const Color(0xFFEAE6E5).withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.45, 1.0],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
}
