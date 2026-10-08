import 'package:flutter/material.dart';

/// Global navigator + messenger keys so background services (glow-up jobs,
/// notification taps) can navigate or show banners without a live
/// [BuildContext]. Wired into [MaterialApp] in `main.dart`.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Shared route name for every screen in the glow-up flow (photo source →
/// loading → confirm → loading → result). Lets us pop the whole flow at once
/// when the user chooses to let a step finish in the background.
const String glowUpFlowRoute = 'glowUpFlow';

typedef TabIndexSetter = void Function(int index);

/// Lets services (notification taps, deep links) switch bottom-nav tabs
/// without a [BuildContext] under [NavController].
class AppTabNavigation {
  AppTabNavigation._();

  static final AppTabNavigation instance = AppTabNavigation._();

  TabIndexSetter? _setIndex;

  void register(TabIndexSetter setIndex) => _setIndex = setIndex;

  void unregister() => _setIndex = null;

  void switchTo(int index) => _setIndex?.call(index);
}

typedef RemindersTabSetter = void Function(int tabIndex);

/// Switches the Upcoming / Done sub-tab on [RemindersScreen].
class RemindersTabNavigation {
  RemindersTabNavigation._();

  static final RemindersTabNavigation instance = RemindersTabNavigation._();

  RemindersTabSetter? _setTab;

  void register(RemindersTabSetter setTab) => _setTab = setTab;

  void unregister() => _setTab = null;

  /// 0 = Upcoming, 1 = Done
  void switchTo(int tabIndex) => _setTab?.call(tabIndex);
}

typedef RemindersOpenSetter = void Function({required bool upcoming});

/// Opens [RemindersScreen] as a pushed route (no longer a bottom-nav tab).
class RemindersOpenNavigation {
  RemindersOpenNavigation._();

  static final RemindersOpenNavigation instance = RemindersOpenNavigation._();

  RemindersOpenSetter? _open;

  void register(RemindersOpenSetter open) => _open = open;

  void unregister() => _open = null;

  void open({required bool upcoming}) => _open?.call(upcoming: upcoming);
}
