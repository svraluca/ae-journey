import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'glow_analysis_codec.dart';
import 'glow_up_pipeline.dart';

/// Disk snapshot so glow-up jobs survive app kill / restart.
class GlowUpJobSnapshot {
  const GlowUpJobSnapshot({
    required this.status,
    required this.backgrounded,
    required this.notified,
    required this.source,
    this.photoPath,
    this.studioPath,
    this.rawPhotoPath,
    this.studioError,
    this.analysisResult,
  });

  /// [GlowUpJobStatus.name] value.
  final String status;
  final bool backgrounded;
  final bool notified;
  final PhotoSource source;
  final String? photoPath;
  final String? studioPath;
  final String? rawPhotoPath;
  final String? studioError;
  final GlowAnalysisResult? analysisResult;

  bool get hasWork => status != 'idle' && status != 'error';
}

class GlowUpJobPersistence {
  GlowUpJobPersistence._();

  static const _key = 'glow_up_job_snapshot_v1';

  static Future<void> save({
    required String status,
    required bool backgrounded,
    required bool notified,
    required PhotoSource source,
    String? photoPath,
    String? studioPath,
    String? rawPhotoPath,
    GlowStudioBeforeResult? studioResult,
    GlowAnalysisResult? analysisResult,
  }) async {
    if (status == 'idle') {
      await clear();
      return;
    }

    final map = <String, dynamic>{
      'status': status,
      'backgrounded': backgrounded,
      'notified': notified,
      'source': source.name,
      'photoPath': photoPath,
      'studioPath': studioPath ?? studioResult?.studioPath,
      'rawPhotoPath': rawPhotoPath ?? studioResult?.rawPhotoPath,
      'studioError': studioResult?.error,
      if (analysisResult != null)
        'analysis': GlowAnalysisCodec.encode(analysisResult),
    };

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(map));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<GlowUpJobSnapshot?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final statusName = map['status'] as String? ?? 'idle';
      if (statusName == 'idle') return null;

      final sourceName = map['source'] as String? ?? 'camera';
      final source = PhotoSource.values.firstWhere(
        (s) => s.name == sourceName,
        orElse: () => PhotoSource.camera,
      );

      GlowAnalysisResult? analysis;
      final analysisMap = map['analysis'];
      if (analysisMap is Map<String, dynamic>) {
        analysis = GlowAnalysisCodec.decode(analysisMap);
      }

      return GlowUpJobSnapshot(
        status: statusName,
        backgrounded: map['backgrounded'] == true,
        notified: map['notified'] == true,
        source: source,
        photoPath: map['photoPath'] as String?,
        studioPath: map['studioPath'] as String?,
        rawPhotoPath: map['rawPhotoPath'] as String?,
        studioError: map['studioError'] as String?,
        analysisResult: analysis,
      );
    } catch (_) {
      return null;
    }
  }

  /// Local file paths must still exist after restart.
  static bool pathsValid(GlowUpJobSnapshot snap) {
    bool ok(String? p) {
      if (p == null || p.trim().isEmpty) return false;
      if (p.startsWith('http://') || p.startsWith('https://')) return true;
      return File(p).existsSync();
    }

    switch (snap.status) {
      case 'runningStudio':
        return ok(snap.photoPath);
      case 'runningEnhance':
        return ok(snap.studioPath) && ok(snap.rawPhotoPath);
      case 'studioReady':
        return ok(snap.studioPath);
      case 'done':
        return ok(snap.analysisResult?.originalPath);
      default:
        return false;
    }
  }

}
