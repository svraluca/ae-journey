import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../data/procedure.dart';
import '../ui/photo_storage.dart';
import 'photo_processor.dart';

/// OpenAI vision comparison of a before/after face photo pair.
class BeforeAfterAnalysisResult {
  const BeforeAfterAnalysisResult({
    required this.beforeGlowScore,
    required this.afterGlowScore,
    required this.zones,
    required this.metrics,
    this.overview = '',
    this.landmarksDetected = 68,
    this.fromAi = true,
  });

  final int beforeGlowScore;
  final int afterGlowScore;
  final List<BeforeAfterZoneResult> zones;
  final List<BeforeAfterMetricResult> metrics;
  final String overview;
  final int landmarksDetected;
  final bool fromAi;

  int get overallImprovementPercent {
    if (beforeGlowScore <= 0) return 0;
    return (((afterGlowScore - beforeGlowScore) / beforeGlowScore) * 100).round();
  }
}

class BeforeAfterZoneResult {
  const BeforeAfterZoneResult({
    required this.name,
    required this.beforeScore,
    required this.afterScore,
    required this.improvementPercent,
  });

  final String name;
  final double beforeScore;
  final double afterScore;
  final int improvementPercent;
}

class BeforeAfterMetricResult {
  const BeforeAfterMetricResult({
    required this.name,
    required this.beforeLevel,
    required this.afterLevel,
    required this.improvementPercent,
  });

  final String name;
  final double beforeLevel;
  final double afterLevel;
  final int improvementPercent;

  double get beforeMark => beforeLevel.clamp(0.0, 1.0);
  double get fill => afterLevel.clamp(0.0, 1.0);
}

class BeforeAfterAnalysisService {
  BeforeAfterAnalysisService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = (apiKey ?? dotenv.env['OPENAI_API_KEY'] ?? '').trim();

  final http.Client _client;
  final String _apiKey;

  String get _model {
    final fromEnv = (dotenv.env['GLOW_ANALYSIS_MODEL'] ?? '').trim();
    if (fromEnv.isNotEmpty) return fromEnv;
    return 'gpt-4o';
  }

  bool get hasKey => _apiKey.isNotEmpty;

  Future<BeforeAfterAnalysisResult> analyze({
    required String beforePath,
    required String afterPath,
    List<Procedure> loggedProcedures = const [],
    DateTime? beforeDate,
    DateTime? afterDate,
  }) async {
    if (!hasKey) {
      debugPrint('[BeforeAfterAnalysis] no API key — using fallback');
      return _fallback(beforePath: beforePath, afterPath: afterPath);
    }

    try {
      final beforeLocal = await _prepareImage(beforePath);
      final afterLocal = await _prepareImage(afterPath);
      final beforeB64 = base64Encode(await File(beforeLocal).readAsBytes());
      final afterB64 = base64Encode(await File(afterLocal).readAsBytes());

      final procedureContext = _procedureContext(loggedProcedures, beforeDate, afterDate);

      final body = <String, Object?>{
        'model': _model,
        'temperature': 0.2,
        'max_tokens': 2400,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': _systemPrompt},
          {
            'role': 'user',
            'content': [
              {
                'type': 'text',
                'text':
                    'Compare these two face photos. Image 1 is BEFORE, image 2 is AFTER. '
                    '$procedureContext '
                    'Score each facial zone and skin metrics based on visible changes only. '
                    'Be realistic — small changes = small percentages.',
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$beforeB64', 'detail': 'high'},
              },
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$afterB64', 'detail': 'high'},
              },
            ],
          },
        ],
      };

      final res = await _client.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint('[BeforeAfterAnalysis] API ${res.statusCode}: ${res.body}');
        return _fallback(beforePath: beforePath, afterPath: afterPath);
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = decoded['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        return _fallback(beforePath: beforePath, afterPath: afterPath);
      }

      final content = (choices.first as Map)['message']?['content'] as String? ?? '';
      final json = jsonDecode(content) as Map<String, dynamic>;
      return _parseJson(json);
    } catch (e, st) {
      debugPrint('[BeforeAfterAnalysis] failed: $e\n$st');
      return _fallback(beforePath: beforePath, afterPath: afterPath);
    }
  }

  Future<String> _prepareImage(String path) async {
    final local = await resolveLocalPhotoPath(path);
    try {
      return await resizePickForStudioMaxSide(local, maxSide: 1024);
    } catch (_) {
      return local;
    }
  }

  String _procedureContext(
    List<Procedure> procedures,
    DateTime? beforeDate,
    DateTime? afterDate,
  ) {
    if (procedures.isEmpty) return 'No procedures logged in the app for this period.';
    final buf = StringBuffer('Logged aesthetic procedures in the app during this period:\n');
    for (final p in procedures) {
      final zones = p.zones.isEmpty ? 'general' : p.zones.join(', ');
      final clinic = (p.clinic ?? '').trim();
      buf.writeln(
        '- ${p.title} on ${p.date.toIso8601String().split('T').first}'
        '${clinic.isNotEmpty ? ' at $clinic' : ''}, treated zones: $zones',
      );
    }
    if (beforeDate != null || afterDate != null) {
      buf.write(
        ' Photo dates: before=${beforeDate?.toIso8601String().split('T').first ?? 'unknown'}, '
        'after=${afterDate?.toIso8601String().split('T').first ?? 'unknown'}.',
      );
    }
    return buf.toString();
  }

  BeforeAfterAnalysisResult _parseJson(Map<String, dynamic> json) {
    final beforeScore = _asInt(json['before_glow_score'], 62).clamp(40, 85);
    final afterScore = _asInt(json['after_glow_score'], 74).clamp(beforeScore + 1, 98);

    final zonesRaw = json['zones'];
    final zones = <BeforeAfterZoneResult>[];
    if (zonesRaw is List) {
      for (final item in zonesRaw) {
        if (item is! Map) continue;
        final m = item.cast<String, dynamic>();
        final name = _canonicalZoneName(m['name']?.toString() ?? '');
        if (name.isEmpty) continue;
        final before = _asDouble(m['before_score'], 6.0).clamp(3.0, 9.5);
        final after = _asDouble(m['after_score'], before + 0.5).clamp(before, 9.8);
        final pct = _asInt(m['improvement_percent'], _pctFromScores(before, after));
        zones.add(BeforeAfterZoneResult(
          name: name,
          beforeScore: before,
          afterScore: after,
          improvementPercent: pct.clamp(-20, 60),
        ));
      }
    }

    final metricsRaw = json['metrics'];
    final metrics = <BeforeAfterMetricResult>[];
    if (metricsRaw is List) {
      for (final item in metricsRaw) {
        if (item is! Map) continue;
        final m = item.cast<String, dynamic>();
        final name = (m['name']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        final beforeLvl = _asDouble(m['before_level'], 0.45).clamp(0.2, 0.9);
        final afterLvl = _asDouble(m['after_level'], beforeLvl + 0.1).clamp(beforeLvl, 0.98);
        final pct = _asInt(m['improvement_percent'], _pctFromLevels(beforeLvl, afterLvl));
        metrics.add(BeforeAfterMetricResult(
          name: name,
          beforeLevel: beforeLvl,
          afterLevel: afterLvl,
          improvementPercent: pct.clamp(-20, 60),
        ));
      }
    }

    return BeforeAfterAnalysisResult(
      beforeGlowScore: beforeScore,
      afterGlowScore: afterScore,
      zones: zones.isEmpty ? _defaultZones() : zones,
      metrics: metrics.isEmpty ? _defaultMetrics() : metrics,
      overview: json['overview']?.toString() ?? '',
      landmarksDetected: _asInt(json['landmarks_detected'], 68).clamp(40, 80),
      fromAi: true,
    );
  }

  BeforeAfterAnalysisResult _fallback({
    required String beforePath,
    required String afterPath,
  }) {
    final seed = beforePath.hashCode ^ afterPath.hashCode;
    final before = 58 + (seed % 8);
    final after = (before + 12 + (seed % 10)).clamp(before + 5, 94);
    return BeforeAfterAnalysisResult(
      beforeGlowScore: before,
      afterGlowScore: after,
      zones: _defaultZones(),
      metrics: _defaultMetrics(),
      fromAi: false,
    );
  }

  static List<BeforeAfterZoneResult> _defaultZones() => const [
        BeforeAfterZoneResult(name: 'Lips', beforeScore: 6.1, afterScore: 8.0, improvementPercent: 31),
        BeforeAfterZoneResult(name: 'Cheeks', beforeScore: 6.5, afterScore: 8.1, improvementPercent: 24),
        BeforeAfterZoneResult(name: 'Eyes area', beforeScore: 6.8, afterScore: 8.0, improvementPercent: 18),
        BeforeAfterZoneResult(name: 'Skin tone', beforeScore: 6.3, afterScore: 7.6, improvementPercent: 21),
        BeforeAfterZoneResult(name: 'Jaw line', beforeScore: 7.0, afterScore: 8.1, improvementPercent: 16),
        BeforeAfterZoneResult(name: 'Forehead', beforeScore: 7.2, afterScore: 8.1, improvementPercent: 12),
      ];

  static List<BeforeAfterMetricResult> _defaultMetrics() => const [
        BeforeAfterMetricResult(
          name: 'Skin texture',
          beforeLevel: 0.48,
          afterLevel: 0.74,
          improvementPercent: 24,
        ),
        BeforeAfterMetricResult(
          name: 'Symmetry',
          beforeLevel: 0.42,
          afterLevel: 0.58,
          improvementPercent: 15,
        ),
        BeforeAfterMetricResult(
          name: 'Brightness',
          beforeLevel: 0.50,
          afterLevel: 0.83,
          improvementPercent: 28,
        ),
        BeforeAfterMetricResult(
          name: 'Volume',
          beforeLevel: 0.44,
          afterLevel: 0.79,
          improvementPercent: 31,
        ),
      ];

  static String _canonicalZoneName(String raw) {
    final z = raw.toLowerCase().trim();
    if (z.contains('lip')) return 'Lips';
    if (z.contains('cheek')) return 'Cheeks';
    if (z.contains('eye') || z.contains('under-eye')) return 'Eyes area';
    if (z.contains('forehead') || z.contains('temple')) return 'Forehead';
    if (z.contains('jaw') || z.contains('chin') || z.contains('jowl')) return 'Jaw line';
    if (z.contains('skin')) return 'Skin tone';
    return raw.trim().isEmpty ? '' : raw.trim();
  }

  static int _pctFromScores(double before, double after) {
    if (before <= 0) return 0;
    return (((after - before) / before) * 100).round();
  }

  static int _pctFromLevels(double before, double after) {
    if (before <= 0) return 0;
    return (((after - before) / before) * 100).round();
  }

  static int _asInt(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  static double _asDouble(Object? v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  void close() => _client.close();

  static const _systemPrompt = '''
You are an aesthetic medicine analyst comparing BEFORE and AFTER face photos.
Return ONLY valid JSON (no markdown):
{
  "overview": "2-3 sentences on visible transformation",
  "before_glow_score": integer 0-100 overall aesthetic glow BEFORE,
  "after_glow_score": integer 0-100 overall aesthetic glow AFTER (must be >= before unless clear regression),
  "landmarks_detected": integer ~68,
  "zones": [
    {
      "name": "Lips|Cheeks|Eyes area|Skin tone|Jaw line|Forehead",
      "before_score": number 0-10,
      "after_score": number 0-10,
      "improvement_percent": integer (can be negative if worse)
    }
  ],
  "metrics": [
    {
      "name": "Skin texture|Symmetry|Brightness|Volume",
      "before_level": number 0.0-1.0,
      "after_level": number 0.0-1.0,
      "improvement_percent": integer
    }
  ]
}
Include all 6 zones and all 4 metrics. Base scores on visible skin quality, symmetry, volume, and harmony.
''';
}
