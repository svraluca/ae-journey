import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_navigator.dart';
import '../services/glow_scan_cropper.dart';
import '../services/photo_processor.dart';
import 'glow_up_loading_screen.dart';
import 'photo_storage.dart';

/// Persists, crops, and opens the glow-up pipeline after any capture path.
Future<void> glowUpHandoffPhoto(
  BuildContext context, {
  required String path,
  required PhotoSource source,
}) async {
  var local = await persistPhotoPath(path);
  local = await GlowScanCropper.cropToPortraitFrame(local);
  try {
    local = await resizePickForStudioMaxSide(local);
  } catch (e) {
    debugPrint('[GlowUp] pick resize skipped: $e');
  }
  unawaited(persistAndUploadPhotoPath(local));
  if (!context.mounted) return;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      settings: const RouteSettings(name: glowUpFlowRoute),
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (context, animation, secondaryAnimation) =>
          GlowUpLoadingScreen(photoPath: local, source: source),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );
}
