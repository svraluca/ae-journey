import 'package:flutter/material.dart';

import '../data/procedure_repository.dart';
import '../services/app_navigator.dart';
import '../services/notification_service.dart';
import '../services/session_prefs.dart';
import 'explore_procedure_interests_screen.dart';
import 'glow_up_results_community_screen.dart';
import 'home_screen.dart';
import 'procedure_form_screen.dart';
import 'profile_screen.dart';
import 'reminders_screen.dart';
import 'search_compare_screen.dart';
import 'widgets/app_background.dart';
import 'widgets/bottom_nav.dart';
import 'widgets/step2_warm_background.dart';

void openHome(BuildContext context, ProcedureRepository repo) {
  Navigator.of(context).pushAndRemoveUntil(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (context, animation, secondaryAnimation) => AppShell(repo: repo),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final fade = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: fade, child: child);
      },
    ),
    (_) => false,
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    AppTabNavigation.instance.register(_setIndex);
    RemindersOpenNavigation.instance.register(_openReminders);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.instance.handleInitialMessage();
      _promptInterestsIfNeeded();
    });
  }

  Future<void> _promptInterestsIfNeeded() async {
    final done = await SessionPrefs.exploreInterestsCompleted();
    if (!mounted || done) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ExploreProcedureInterestsScreen(
          repo: widget.repo,
        ),
      ),
    );
  }

  @override
  void dispose() {
    AppTabNavigation.instance.unregister();
    RemindersOpenNavigation.instance.unregister();
    super.dispose();
  }

  void _openReminders({required bool upcoming}) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemindersScreen(repo: widget.repo),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      RemindersTabNavigation.instance.switchTo(upcoming ? 0 : 1);
    });
  }

  void _setIndex(int i) {
    if (!mounted) return;
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    AppTabNavigation.instance.register(_setIndex);
    RemindersOpenNavigation.instance.register(_openReminders);
    return NavController(
      index: _index,
      setIndex: _setIndex,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: Stack(
          children: [
            if (_index == 0 || _index == 1 || _index == 2 || _index == 3)
              const Step2WarmBackground()
            else
              const AppBackground(),
            SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  HomeScreen(repo: widget.repo),
                  SearchCompareScreen(active: _index == 1),
                  GlowUpResultsCommunityScreen(
                    repo: widget.repo,
                    embeddedInShell: true,
                  ),
                  ProfileScreen(repo: widget.repo),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BottomNav(
                index: _index,
                onChanged: _setIndex,
                onAddPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProcedureFormScreen(repo: widget.repo),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NavController extends InheritedWidget {
  const NavController({
    super.key,
    required super.child,
    required this.index,
    required this.setIndex,
  });

  final int index;
  final ValueChanged<int> setIndex;

  static NavController of(BuildContext context) {
    final c = context.dependOnInheritedWidgetOfExactType<NavController>();
    assert(c != null, 'NavController not found in context');
    return c!;
  }

  @override
  bool updateShouldNotify(NavController oldWidget) => index != oldWidget.index;
}

