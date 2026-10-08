import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'app_navigator.dart';
import 'progress_share_service.dart';
import '../ui/community_glow_up_viewer_screen.dart';

/// Listens for aeglowup://share/{id} and https share links (legacy schemes supported).
class ProgressShareLinkHandler {
  ProgressShareLinkHandler._();
  static final ProgressShareLinkHandler instance = ProgressShareLinkHandler._();

  StreamSubscription<Uri>? _sub;
  final _appLinks = AppLinks();
  bool _handling = false;

  Future<void> start() async {
    await _sub?.cancel();
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) {
        // Wait for navigator to be ready after splash.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future<void>.delayed(const Duration(milliseconds: 600), () {
            unawaited(handleUri(initial));
          });
        });
      }
    } catch (e) {
      debugPrint('[ShareLink] initial link failed: $e');
    }

    _sub = _appLinks.uriLinkStream.listen(
      (uri) => unawaited(handleUri(uri)),
      onError: (Object e) => debugPrint('[ShareLink] stream error: $e'),
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> handleUri(Uri uri) async {
    final shareId = ProgressShareService.parseShareId(uri);
    if (shareId == null || shareId.isEmpty) return;
    if (_handling) return;
    _handling = true;
    try {
      final nav = appNavigatorKey.currentState;
      if (nav == null) return;

      final view = await ProgressShareService.instance.loadShare(shareId);
      if (view == null) {
        appMessengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('This shared progress is no longer available.')),
        );
        return;
      }

      await nav.push(
        MaterialPageRoute<void>(
          builder: (_) => CommunityGlowUpViewerScreen(post: view),
        ),
      );
    } finally {
      _handling = false;
    }
  }
}
