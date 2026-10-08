import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/before_after_analysis_service.dart';
import '../services/transformation_history_store.dart';
import 'formatters.dart';
import 'photo_storage.dart';

// ── meitu_compare.html ─────────────────────────────────────────────────────────
const _bg = Color(0xFF0C0C0E);
const _surface = Color(0xFF111115);
const _surface2 = Color(0xFF1A1A1F);
const _tabOn = Color(0xFF222228);
const _tabBg = Color(0xFF0C0C0E);
const _border = Color(0xFF1E1E24);
const _borderSoft = Color(0xFF1A1A1F);
const _photoBefore = Color(0xFF0E0E12);
const _photoAfter = Color(0xFF131318);
const _faceBg = Color(0xFF1A1A20);
const _pageHPad = 12.0;
const _frameMarginH = 8.0;
const _sectionMb = 18.0;
const _sectionHeaderMb = 12.0;
const _containerInnerV = 14.0;
const _containerInnerH = 14.0;
const _photoHMin = 300.0;
const _photoHMax = 440.0;
const _photoHScreenFraction = 0.44;
const _frameRadius = 16.0;

double _comparePhotoHeight(BuildContext context) {
  final screenH = MediaQuery.sizeOf(context).height;
  return (screenH * _photoHScreenFraction).clamp(_photoHMin, _photoHMax);
}

enum _CompareTab { sideBySide, slider }

abstract final class _Type {
  static const _fonts = <String>['.SF Pro Display', 'Helvetica Neue', 'Arial'];

  static TextStyle _s(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        fontFamily: '.SF Pro Display',
        fontFamilyFallback: _fonts,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
        decoration: TextDecoration.none,
      );

  static TextStyle get base => _s(13, color: Colors.white);

  static TextStyle get navTitle =>
      _s(15, weight: FontWeight.w500, color: Colors.white, letterSpacing: -0.15, height: 1.2);

  static TextStyle get navSub =>
      _s(11, color: Colors.white.withValues(alpha: 0.28), letterSpacing: 0.4, height: 1.25);

  static TextStyle get tab => _s(11,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.32));

  static TextStyle get tabOn =>
      _s(11, weight: FontWeight.w500, color: Colors.white);

  static TextStyle get frameDate =>
      _s(10, color: Colors.white.withValues(alpha: 0.24), letterSpacing: 0.2);

  static TextStyle get photoTag => _s(10,
      weight: FontWeight.w500,
      color: Colors.white.withValues(alpha: 0.6),
      letterSpacing: 0.4);

  static TextStyle get photoDate =>
      _s(10, color: Colors.white.withValues(alpha: 0.38), height: 1.2);

  static TextStyle get circleScore => _s(15,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.38), height: 1);

  static TextStyle get circleScoreHi =>
      _s(15, weight: FontWeight.w500, color: Colors.white, height: 1);

  static TextStyle get circleLbl =>
      _s(8, color: Colors.white.withValues(alpha: 0.22), letterSpacing: 0.2, height: 1.1);

  static TextStyle get scoreLbl => _s(9,
      color: Colors.white.withValues(alpha: 0.24), letterSpacing: 0.5, height: 1.2);

  static TextStyle get scoreVal =>
      _s(12, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.38), height: 1.2);

  static TextStyle get scoreValHi =>
      _s(12, weight: FontWeight.w500, color: Colors.white, height: 1.2);

  static TextStyle get scoreDelta =>
      _s(10, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.42), height: 1.2);

  static TextStyle get scoreDeltaHi =>
      _s(10, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.65), height: 1.2);

  static TextStyle get deltaBadgeLbl => _s(10,
      color: Colors.white.withValues(alpha: 0.28), letterSpacing: 0.4, height: 1.2);

  static TextStyle get deltaPill => _s(10,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.62), height: 1.2);

  static TextStyle get sectionTitle =>
      _s(13, weight: FontWeight.w500, color: Colors.white, letterSpacing: -0.1, height: 1.2);

  static TextStyle get sectionRight =>
      _s(11, color: Colors.white.withValues(alpha: 0.24), height: 1.2);

  static TextStyle get zoneName =>
      _s(11, color: Colors.white.withValues(alpha: 0.4), height: 1.2);

  static TextStyle get zoneVal =>
      _s(12, weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.75), height: 1.2);

  static TextStyle get zoneBefore =>
      _s(10, color: Colors.white.withValues(alpha: 0.28), height: 1.25);

  static TextStyle get zoneAfter =>
      _s(10, color: Colors.white.withValues(alpha: 0.55), height: 1.25);

  static TextStyle get mapDotScore => _s(11, weight: FontWeight.w700, color: Colors.black, height: 1);

  static TextStyle get mapDotScoreDim =>
      _s(9, weight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.85), height: 1);

  static TextStyle get metricName =>
      _s(11, color: Colors.white.withValues(alpha: 0.34), height: 1.25);

  static TextStyle get metricVal => _s(11,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.58), height: 1.25);

  static TextStyle get procName => _s(12,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.72), height: 1.25);

  static TextStyle get procMeta =>
      _s(10, color: Colors.white.withValues(alpha: 0.26), height: 1.25);

  static TextStyle get procNum =>
      _s(10, color: Colors.white.withValues(alpha: 0.2), height: 1.2);

  static TextStyle get procScore => _s(11,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.52), height: 1.2);

  static TextStyle get procDate =>
      _s(10, color: Colors.white.withValues(alpha: 0.24), height: 1.2);

  static TextStyle get shareMain =>
      _s(13, weight: FontWeight.w500, color: Colors.black);

  static TextStyle get shareSecondary => _s(11,
      weight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.34));
}

class FaceZone {
  const FaceZone(this.name, this.fill, this.delta, this.before, this.after);
  final String name;
  final double fill;
  final String delta;
  final String before;
  final String after;
}

const _zones = [
  FaceZone('Lips', 0.88, '+31%', '6.1', '8.0'),
  FaceZone('Cheeks', 0.72, '+24%', '6.5', '8.1'),
  FaceZone('Eyes area', 0.58, '+18%', '6.8', '8.0'),
  FaceZone('Skin tone', 0.65, '+21%', '6.3', '7.6'),
  FaceZone('Jaw line', 0.44, '+16%', '7.0', '8.1'),
  FaceZone('Forehead', 0.30, '+12%', '7.2', '8.1'),
];

/// Dot layout aligned with [_FacePointsMap] in procedure_form_screen.dart.
class _FaceZoneDotDef {
  const _FaceZoneDotDef(this.zoneName, this.alignment, {this.size = 18});
  final String zoneName;
  final Alignment alignment;
  final double size;
}

const _faceZoneDots = [
  _FaceZoneDotDef('Forehead', Alignment(0, -0.48), size: 22),
  _FaceZoneDotDef('Eyes area', Alignment(-0.40, -0.20), size: 20),
  _FaceZoneDotDef('Eyes area', Alignment(0.40, -0.20), size: 20),
  _FaceZoneDotDef('Cheeks', Alignment(-0.65, 0.16), size: 20),
  _FaceZoneDotDef('Cheeks', Alignment(0.65, 0.16), size: 20),
  _FaceZoneDotDef('Skin tone', Alignment(0, 0.10), size: 18),
  _FaceZoneDotDef('Lips', Alignment(0, 0.48), size: 20),
  _FaceZoneDotDef('Jaw line', Alignment(-0.55, 0.62), size: 18),
  _FaceZoneDotDef('Jaw line', Alignment(0.55, 0.62), size: 18),
];

Color _zoneDotColor(double fill) {
  final t = fill.clamp(0.0, 1.0);
  if (t < 0.22) return const Color(0xFF2A2A32);
  if (t < 0.45) return Color.lerp(const Color(0xFF2A2A32), const Color(0xFF3D4F5C), (t - 0.22) / 0.23)!;
  return Color.lerp(const Color(0xFF4A7A8C), const Color(0xFF9AE8FF), (t - 0.45) / 0.55)!;
}

int? _parseDeltaPercent(String delta) {
  final match = RegExp(r'\+(\d+)').firstMatch(delta);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Green → teal → cyan by improvement strength (fill 0–1 or parsed %).
Color _improvementColor({double? fill, String? delta}) {
  final pct = delta != null ? _parseDeltaPercent(delta) : null;
  final t = (fill ?? (pct != null ? pct / 32.0 : 0.4)).clamp(0.0, 1.0);
  if (t >= 0.82) return const Color(0xFF9AE8FF);
  if (t >= 0.68) return const Color(0xFF6EE8C4);
  if (t >= 0.52) return const Color(0xFF8ADFA0);
  if (t >= 0.38) return const Color(0xFFE8C96A);
  if (t >= 0.22) return const Color(0xFFD4A8E8);
  return const Color(0xFF8E95A8);
}

TextStyle _coloredDeltaStyle(TextStyle base, {double? fill, required String delta}) {
  return base.copyWith(color: _improvementColor(fill: fill, delta: delta));
}

double _zoneDotDiameter(FaceZone zone, double baseSize) =>
    (baseSize + zone.fill * 6).clamp(baseSize, baseSize + 8);

/// Maps [Alignment] to top-left offset on the 120×200 face canvas (procedure form).
Offset _faceAlignOffset(Alignment a, double dotSize) {
  const canvasW = 120.0;
  const canvasH = 200.0;
  return Offset(
    (a.x + 1) / 2 * canvasW - dotSize / 2,
    (a.y + 1) / 2 * canvasH - dotSize / 2,
  );
}

class MetricRow {
  const MetricRow(this.name, this.fill, this.beforeMark, this.delta);
  final String name;
  final double fill;
  final double beforeMark;
  final String delta;
}

class ProcedureItem {
  const ProcedureItem(
    this.num,
    this.name,
    this.clinic,
    this.detail,
    this.date,
    this.points,
    this.icon,
  );
  final String num;
  final String name;
  final String clinic;
  final String detail;
  final String date;
  final String points;
  final IconData icon;
}

enum _ComparePhase { setup, results }

/// Snapshot shown in the results phase — derived from photos + procedure history.
class _ComparisonSnapshot {
  const _ComparisonSnapshot({
    required this.beforePath,
    required this.afterPath,
    required this.beforeDate,
    required this.afterDate,
    required this.beforeScore,
    required this.afterScore,
    required this.overallDelta,
    required this.zones,
    required this.metrics,
    required this.procedures,
    required this.monthsApart,
    required this.zoneCount,
    required this.landmarksDetected,
  });

  final String beforePath;
  final String afterPath;
  final DateTime? beforeDate;
  final DateTime? afterDate;
  final int beforeScore;
  final int afterScore;
  final String overallDelta;
  final List<FaceZone> zones;
  final List<MetricRow> metrics;
  final List<ProcedureItem> procedures;
  final int monthsApart;
  final int zoneCount;
  final int landmarksDetected;

  String get rangeLabel => _ComparisonLogic.rangeLabel(beforeDate, afterDate);
  String get beforePhotoLabel =>
      beforeDate != null ? DateFormat('MMM yyyy').format(beforeDate!) : 'Before';
  String get afterPhotoLabel =>
      afterDate != null ? DateFormat('MMM yyyy').format(afterDate!) : 'After';

  _ComparisonSnapshot copyWithPaths({
    required String beforePath,
    required String afterPath,
  }) {
    return _ComparisonSnapshot(
      beforePath: beforePath,
      afterPath: afterPath,
      beforeDate: beforeDate,
      afterDate: afterDate,
      beforeScore: beforeScore,
      afterScore: afterScore,
      overallDelta: overallDelta,
      zones: zones,
      metrics: metrics,
      procedures: procedures,
      monthsApart: monthsApart,
      zoneCount: zoneCount,
      landmarksDetected: landmarksDetected,
    );
  }
}

abstract final class _ComparisonSnapshotCodec {
  static Map<String, dynamic>? _coerceMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static List<FaceZone> _decodeZones(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (_coerceMap(item) case final m?)
          FaceZone(
            m['name'] as String? ?? '',
            (m['fill'] as num?)?.toDouble() ?? 0,
            m['delta'] as String? ?? '',
            m['before'] as String? ?? '',
            m['after'] as String? ?? '',
          ),
    ];
  }

  static List<MetricRow> _decodeMetrics(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (_coerceMap(item) case final m?)
          MetricRow(
            m['name'] as String? ?? '',
            (m['fill'] as num?)?.toDouble() ?? 0,
            (m['beforeMark'] as num?)?.toDouble() ?? 0,
            m['delta'] as String? ?? '',
          ),
    ];
  }

  static List<ProcedureItem> _decodeProcedures(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (_coerceMap(item) case final m?)
          ProcedureItem(
            m['num'] as String? ?? '',
            m['name'] as String? ?? '',
            m['clinic'] as String? ?? '',
            m['detail'] as String? ?? '',
            m['date'] as String? ?? '',
            m['points'] as String? ?? '',
            _procedureIconFor(m['name'] as String? ?? ''),
          ),
    ];
  }

  static Map<String, dynamic> encode(_ComparisonSnapshot s) => {
        'beforePath': s.beforePath,
        'afterPath': s.afterPath,
        if (s.beforeDate != null) 'beforeDate': s.beforeDate!.toUtc().toIso8601String(),
        if (s.afterDate != null) 'afterDate': s.afterDate!.toUtc().toIso8601String(),
        'beforeScore': s.beforeScore,
        'afterScore': s.afterScore,
        'overallDelta': s.overallDelta,
        'monthsApart': s.monthsApart,
        'zoneCount': s.zoneCount,
        'landmarksDetected': s.landmarksDetected,
        'zones': [
          for (final z in s.zones)
            {
              'name': z.name,
              'fill': z.fill,
              'delta': z.delta,
              'before': z.before,
              'after': z.after,
            },
        ],
        'metrics': [
          for (final m in s.metrics)
            {
              'name': m.name,
              'fill': m.fill,
              'beforeMark': m.beforeMark,
              'delta': m.delta,
            },
        ],
        'procedures': [
          for (final p in s.procedures)
            {
              'num': p.num,
              'name': p.name,
              'clinic': p.clinic,
              'detail': p.detail,
              'date': p.date,
              'points': p.points,
              'icon': p.icon.codePoint,
            },
        ],
      };

  static _ComparisonSnapshot? decode(Map<String, dynamic> raw) {
    try {
      DateTime? parseDate(String? v) =>
          v == null ? null : DateTime.tryParse(v)?.toLocal();

      return _ComparisonSnapshot(
        beforePath: raw['beforePath'] as String? ?? '',
        afterPath: raw['afterPath'] as String? ?? '',
        beforeDate: parseDate(raw['beforeDate'] as String?),
        afterDate: parseDate(raw['afterDate'] as String?),
        beforeScore: (raw['beforeScore'] as num?)?.round() ?? 0,
        afterScore: (raw['afterScore'] as num?)?.round() ?? 0,
        overallDelta: raw['overallDelta'] as String? ?? '',
        monthsApart: (raw['monthsApart'] as num?)?.round() ?? 0,
        zoneCount: (raw['zoneCount'] as num?)?.round() ?? 0,
        landmarksDetected: (raw['landmarksDetected'] as num?)?.round() ?? 68,
        zones: _decodeZones(raw['zones']),
        metrics: _decodeMetrics(raw['metrics']),
        procedures: _decodeProcedures(raw['procedures']),
      );
    } catch (_) {
      return null;
    }
  }

  static _ComparisonSnapshot fromHistoryEntry(TransformationHistoryEntry entry) {
    final before = entry.beforeForDisplay;
    final after = entry.afterForDisplay;
    final saved = TransformationHistoryEntry.coerceSnapshotMap(entry.snapshotData);
    if (saved != null) {
      final decoded = decode(saved);
      if (decoded != null) {
        return decoded.copyWithPaths(beforePath: before, afterPath: after);
      }
    }
    final pct = entry.beforeScore <= 0
        ? 0
        : (((entry.afterScore - entry.beforeScore) / entry.beforeScore) * 100).round();
    return _ComparisonSnapshot(
      beforePath: before,
      afterPath: after,
      beforeDate: entry.beforeDate,
      afterDate: entry.afterDate,
      beforeScore: entry.beforeScore,
      afterScore: entry.afterScore,
      overallDelta: pct >= 0 ? '+$pct% overall' : '$pct% overall',
      zones: const [],
      metrics: const [],
      procedures: const [],
      monthsApart: _ComparisonLogic.monthsBetween(entry.beforeDate, entry.afterDate),
      zoneCount: 0,
      landmarksDetected: 68,
    );
  }
}

abstract final class _ComparisonLogic {
  static String rangeLabel(DateTime? before, DateTime? after) {
    if (before == null && after == null) return 'CUSTOM COMPARISON';
    final fmt = DateFormat('MMM yyyy');
    final b = before != null ? fmt.format(before).toUpperCase() : '—';
    final a = after != null ? fmt.format(after).toUpperCase() : 'NOW';
    return '$b → $a';
  }

  static String canonicalZone(String raw) {
    final z = raw.toLowerCase().trim();
    if (z.contains('lip')) return 'Lips';
    if (z.contains('cheek')) return 'Cheeks';
    if (z.contains('eye') || z.contains('under-eye')) return 'Eyes area';
    if (z.contains('forehead') || z.contains('temple')) return 'Forehead';
    if (z.contains('jaw') || z.contains('chin') || z.contains('jowl')) return 'Jaw line';
    return 'Skin tone';
  }

  static List<Procedure> proceduresInWindow(
    Iterable<Procedure> allDone, {
    DateTime? beforeDate,
    DateTime? afterDate,
  }) {
    final sorted = allDone.toList()..sort((a, b) => a.date.compareTo(b.date));
    if (beforeDate == null && afterDate == null) {
      return sorted.reversed.toList();
    }
    final a = beforeDate ?? DateTime(2000);
    final b = afterDate ?? DateTime.now();
    final lo = a.isBefore(b) ? a : b;
    final hi = a.isBefore(b) ? b : a;
    return sorted
        .where((p) => !p.date.isBefore(lo) && !p.date.isAfter(hi.add(const Duration(days: 1))))
        .toList()
        .reversed
        .toList();
  }

  static int monthsBetween(DateTime? before, DateTime? after) {
    if (before == null || after == null) return 0;
    final lo = before.isBefore(after) ? before : after;
    final hi = before.isBefore(after) ? after : before;
    return math.max(1, (hi.year - lo.year) * 12 + hi.month - lo.month);
  }

  static _ComparisonSnapshot build({
    required BeforeAfterAnalysisResult analysis,
    required String beforePath,
    required String afterPath,
    DateTime? beforeDate,
    DateTime? afterDate,
    required Iterable<Procedure> allDone,
  }) {
    final inRange = proceduresInWindow(allDone, beforeDate: beforeDate, afterDate: afterDate);

    final zones = analysis.zones
        .map(
          (z) => FaceZone(
            z.name,
            (z.improvementPercent / 36.0).clamp(0.12, 0.95),
            _formatDelta(z.improvementPercent),
            z.beforeScore.toStringAsFixed(1),
            z.afterScore.toStringAsFixed(1),
          ),
        )
        .toList();
    if (zones.isEmpty) zones.addAll(_zones);

    final metrics = analysis.metrics
        .map(
          (m) => MetricRow(
            m.name,
            m.fill,
            m.beforeMark,
            _formatDelta(m.improvementPercent),
          ),
        )
        .toList();

    final procedureItems = [
      for (var i = 0; i < inRange.length; i++)
        ProcedureItem(
          (i + 1).toString().padLeft(2, '0'),
          inRange[i].title,
          (inRange[i].clinic ?? '').trim().isEmpty ? 'ÆSTHETIC JOURNEY' : inRange[i].clinic!.trim(),
          _procedureDetailLine(inRange[i]),
          formatDate(inRange[i].date),
          '+${_procedureImpactPoints(inRange[i], analysis)} pts',
          _procedureIconFor(inRange[i].title),
        ),
    ];

    final overallPct = analysis.overallImprovementPercent;

    return _ComparisonSnapshot(
      beforePath: beforePath,
      afterPath: afterPath,
      beforeDate: beforeDate,
      afterDate: afterDate,
      beforeScore: analysis.beforeGlowScore,
      afterScore: analysis.afterGlowScore,
      overallDelta: overallPct >= 0 ? '+$overallPct% overall' : '$overallPct% overall',
      zones: zones,
      metrics: metrics,
      procedures: procedureItems,
      monthsApart: monthsBetween(beforeDate, afterDate),
      zoneCount: zones.length,
      landmarksDetected: analysis.landmarksDetected,
    );
  }

  static String _formatDelta(int pct) => pct >= 0 ? '+$pct%' : '$pct%';

  static int _procedureImpactPoints(Procedure p, BeforeAfterAnalysisResult analysis) {
    if (p.zones.isEmpty) return 5;
    var sum = 0;
    var n = 0;
    for (final raw in p.zones) {
      final key = canonicalZone(raw);
      for (final z in analysis.zones) {
        if (z.name == key) {
          sum += z.improvementPercent.clamp(0, 40);
          n++;
          break;
        }
      }
    }
    if (n == 0) return 5;
    return (sum / n).round().clamp(4, 18);
  }
}

class BeforeAfterComparisonScreen extends StatefulWidget {
  const BeforeAfterComparisonScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<BeforeAfterComparisonScreen> createState() => _BeforeAfterComparisonScreenState();
}

class _BeforeAfterComparisonScreenState extends State<BeforeAfterComparisonScreen> {
  final _picker = ImagePicker();
  final _analysisService = BeforeAfterAnalysisService();
  _ComparePhase _phase = _ComparePhase.setup;
  String? _beforePath;
  String? _afterPath;
  DateTime? _beforeDate;
  DateTime? _afterDate;
  _ComparisonSnapshot? _snapshot;
  double _split = 0.5;
  _CompareTab _tab = _CompareTab.sideBySide;
  bool _analyzing = false;
  bool _viewingSavedTransformation = false;
  List<TransformationHistoryEntry> _transformationHistory = const [];
  bool _historyLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTransformationHistory();
  }

  @override
  void dispose() {
    _analysisService.close();
    super.dispose();
  }

  bool get _canCompare =>
      _photoExists(_beforePath) &&
      _photoExists(_afterPath) &&
      _beforeDate != null &&
      _afterDate != null;

  List<Procedure> get _proceduresWithPhotos {
    return widget.repo
        .allDone()
        .where((p) => _photoExists(p.beforePhotoPath) || _photoExists(p.afterPhotoPath))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> _loadTransformationHistory() async {
    final items = await TransformationHistoryStore.list();
    if (!mounted) return;
    setState(() {
      _transformationHistory = [
        for (final e in items)
          if (_photoExists(e.beforeForDisplay) && _photoExists(e.afterForDisplay)) e,
      ];
      _historyLoading = false;
    });
  }

  Future<void> _saveTransformationHistory(_ComparisonSnapshot snapshot) async {
    try {
      final entry = await TransformationHistoryStore.createEntry(
        beforeSource: snapshot.beforePath,
        afterSource: snapshot.afterPath,
        beforeDate: snapshot.beforeDate,
        afterDate: snapshot.afterDate,
        beforeScore: snapshot.beforeScore,
        afterScore: snapshot.afterScore,
      );
      final archivedSnapshot = snapshot.copyWithPaths(
        beforePath: entry.beforeForDisplay,
        afterPath: entry.afterForDisplay,
      );
      final entryWithSnapshot = entry.copyWith(
        snapshotData: _ComparisonSnapshotCodec.encode(archivedSnapshot),
      );
      debugPrint(
        '[Compare] saving transformation history '
        'zones=${archivedSnapshot.zones.length} '
        'metrics=${archivedSnapshot.metrics.length} '
        'procedures=${archivedSnapshot.procedures.length}',
      );
      await TransformationHistoryStore.add(entryWithSnapshot);
      if (!mounted) return;
      await _loadTransformationHistory();
    } catch (e, st) {
      debugPrint('[Compare] save transformation history failed: $e\n$st');
    }
  }

  void _openSavedTransformation(TransformationHistoryEntry entry) {
    if (!_photoExists(entry.beforeForDisplay) || !_photoExists(entry.afterForDisplay)) {
      return;
    }
    setState(() {
      _snapshot = _ComparisonSnapshotCodec.fromHistoryEntry(entry);
      _phase = _ComparePhase.results;
      _viewingSavedTransformation = true;
      _tab = _CompareTab.sideBySide;
      _split = 0.5;
    });
  }

  Future<DateTime?> _showPhotoTakenDatePicker({
    required String title,
    DateTime? initialDate,
  }) {
    return showDatePicker(
      context: context,
      helpText: title,
      initialDate: initialDate ?? DateTime.now(),
      firstDate: DateTime(1990),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Colors.white,
              onPrimary: Colors.black,
              surface: _surface,
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
  }

  void _swapIfChronologyReversed() {
    if (_beforeDate == null || _afterDate == null) return;
    if (!_afterDate!.isBefore(_beforeDate!)) return;
    final tmpD = _beforeDate;
    _beforeDate = _afterDate;
    _afterDate = tmpD;
    final tmpP = _beforePath;
    _beforePath = _afterPath;
    _afterPath = tmpP;
  }

  Future<void> _pickPhoto({required bool before}) async {
    final source = await _showPhotoSourceSheet();
    if (source == null || !mounted) return;
    final img = await _picker.pickImage(source: source, imageQuality: 88);
    if (img == null || !mounted) return;
    final path = await persistAndUploadPhotoPath(img.path);
    final initialDate = before
        ? (_beforeDate ?? DateTime.now())
        : (_afterDate ?? _beforeDate ?? DateTime.now());
    final pickedDate = await _showPhotoTakenDatePicker(
      title: before ? 'When was your before photo taken?' : 'When was your after photo taken?',
      initialDate: initialDate,
    );
    if (!mounted) return;
    setState(() {
      if (before) {
        _beforePath = path;
        _beforeDate = pickedDate ?? DateTime.now();
      } else {
        _afterPath = path;
        _afterDate = pickedDate ?? DateTime.now();
      }
      _swapIfChronologyReversed();
    });
  }

  Future<void> _editPhotoDate({required bool before}) async {
    if (before && !_photoExists(_beforePath)) return;
    if (!before && !_photoExists(_afterPath)) return;
    final picked = await _showPhotoTakenDatePicker(
      title: before ? 'When was your before photo taken?' : 'When was your after photo taken?',
      initialDate: (before ? _beforeDate : _afterDate) ?? DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (before) {
        _beforeDate = picked;
      } else {
        _afterDate = picked;
      }
      _swapIfChronologyReversed();
    });
  }

  Future<ImageSource?> _showPhotoSourceSheet() {
    return showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined, color: Colors.white54),
              title: Text('Camera', style: _Type.base.copyWith(fontWeight: FontWeight.w500)),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined, color: Colors.white54),
              title: Text('Photo library', style: _Type.base.copyWith(fontWeight: FontWeight.w500)),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  void _applyProcedurePhotos(Procedure p, {required bool useBefore, required bool useAfter}) {
    setState(() {
      if (useBefore && _photoExists(p.beforePhotoPath)) {
        _beforePath = p.beforePhotoPath;
        _beforeDate = p.date;
      }
      if (useAfter && _photoExists(p.afterPhotoPath)) {
        _afterPath = p.afterPhotoPath;
        _afterDate = p.date;
      }
      _swapIfChronologyReversed();
    });
  }

  Future<void> _openProcedurePhotoPicker(Procedure p) async {
    final hasBefore = _photoExists(p.beforePhotoPath);
    final hasAfter = _photoExists(p.afterPhotoPath);
    if (!hasBefore && !hasAfter) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Text(p.title, style: _Type.sectionTitle),
            ),
            if (hasBefore && hasAfter)
              ListTile(
                leading: const Icon(Icons.compare_outlined, color: Colors.white54),
                title: Text('Use before & after', style: _Type.base.copyWith(fontWeight: FontWeight.w500)),
                onTap: () => Navigator.pop(ctx, 'both'),
              ),
            if (hasBefore)
              ListTile(
                leading: const Icon(Icons.history_outlined, color: Colors.white54),
                title: Text('Use as before photo', style: _Type.base.copyWith(fontWeight: FontWeight.w500)),
                onTap: () => Navigator.pop(ctx, 'before'),
              ),
            if (hasAfter)
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined, color: Colors.white54),
                title: Text('Use as after photo', style: _Type.base.copyWith(fontWeight: FontWeight.w500)),
                onTap: () => Navigator.pop(ctx, 'after'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'both':
        _applyProcedurePhotos(p, useBefore: true, useAfter: true);
      case 'before':
        _applyProcedurePhotos(p, useBefore: true, useAfter: false);
      case 'after':
        _applyProcedurePhotos(p, useBefore: false, useAfter: true);
    }
  }

  Future<void> _showComparison() async {
    if (!_canCompare || _analyzing) return;
    setState(() => _analyzing = true);
    try {
      final inRange = _ComparisonLogic.proceduresInWindow(
        widget.repo.allDone(),
        beforeDate: _beforeDate,
        afterDate: _afterDate,
      );
      final analysis = await _analysisService.analyze(
        beforePath: _beforePath!,
        afterPath: _afterPath!,
        loggedProcedures: inRange,
        beforeDate: _beforeDate,
        afterDate: _afterDate,
      );
      if (!mounted) return;
      final snapshot = _ComparisonLogic.build(
        analysis: analysis,
        beforePath: _beforePath!,
        afterPath: _afterPath!,
        beforeDate: _beforeDate,
        afterDate: _afterDate,
        allDone: widget.repo.allDone(),
      );
      setState(() {
        _snapshot = snapshot;
        _phase = _ComparePhase.results;
        _viewingSavedTransformation = false;
        _analyzing = false;
      });
      await _saveTransformationHistory(snapshot);
    } catch (e) {
      debugPrint('[Compare] analysis failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not analyse photos. Try again.')),
      );
      setState(() => _analyzing = false);
    }
  }

  void _backFromResults() {
    setState(() {
      _phase = _ComparePhase.setup;
      _viewingSavedTransformation = false;
    });
    _loadTransformationHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: ListenableBuilder(
        listenable: widget.repo,
        builder: (context, _) {
          return DefaultTextStyle(
            style: _Type.base,
            child: _phase == _ComparePhase.setup
                ? _CompareSetupView(
                    beforePath: _beforePath,
                    afterPath: _afterPath,
                    beforeDate: _beforeDate,
                    afterDate: _afterDate,
                    canCompare: _canCompare && !_analyzing,
                    analyzing: _analyzing,
                    procedures: _proceduresWithPhotos,
                    transformationHistory: _transformationHistory,
                    historyLoading: _historyLoading,
                    onBack: () => Navigator.of(context).pop(),
                    onPickBefore: () => _pickPhoto(before: true),
                    onPickAfter: () => _pickPhoto(before: false),
                    onPickBeforeDate: () => _editPhotoDate(before: true),
                    onPickAfterDate: () => _editPhotoDate(before: false),
                    onTransformationHistoryTap: _openSavedTransformation,
                    onProcedureTap: _openProcedurePhotoPicker,
                    onShowComparison: _showComparison,
                  )
                : _CompareResultsView(
                    snapshot: _snapshot!,
                    tab: _tab,
                    split: _split,
                    readOnly: _viewingSavedTransformation,
                    onBack: _backFromResults,
                    onClose: () => Navigator.of(context).pop(),
                    onTab: (t) => setState(() => _tab = t),
                    onSplit: (v) => setState(() => _split = v.clamp(0.08, 0.92)),
                    onPickBefore: _viewingSavedTransformation
                        ? () {}
                        : () => _pickPhoto(before: true),
                    onPickAfter: _viewingSavedTransformation
                        ? () {}
                        : () => _pickPhoto(before: false),
                  ),
          );
        },
      ),
    );
  }
}

// ── Phase 1: pick before / after ─────────────────────────────────────────────
class _CompareSetupView extends StatelessWidget {
  const _CompareSetupView({
    required this.beforePath,
    required this.afterPath,
    required this.beforeDate,
    required this.afterDate,
    required this.canCompare,
    required this.analyzing,
    required this.procedures,
    required this.transformationHistory,
    required this.historyLoading,
    required this.onBack,
    required this.onPickBefore,
    required this.onPickAfter,
    required this.onPickBeforeDate,
    required this.onPickAfterDate,
    required this.onTransformationHistoryTap,
    required this.onProcedureTap,
    required this.onShowComparison,
  });

  final String? beforePath;
  final String? afterPath;
  final DateTime? beforeDate;
  final DateTime? afterDate;
  final bool canCompare;
  final bool analyzing;
  final List<Procedure> procedures;
  final List<TransformationHistoryEntry> transformationHistory;
  final bool historyLoading;
  final VoidCallback onBack;
  final VoidCallback onPickBefore;
  final VoidCallback onPickAfter;
  final VoidCallback onPickBeforeDate;
  final VoidCallback onPickAfterDate;
  final ValueChanged<TransformationHistoryEntry> onTransformationHistoryTap;
  final ValueChanged<Procedure> onProcedureTap;
  final VoidCallback onShowComparison;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CompareNavBar(
          title: 'Compare transformation',
          subtitle: 'ADD BEFORE & AFTER PHOTOS',
          onBack: onBack,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(_pageHPad, 0, _pageHPad, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose two photos to analyse your glow-up — upload new ones, pick from procedures, or reuse a past transformation.',
                  style: _Type.base.copyWith(
                    color: Colors.white.withValues(alpha: 0.42),
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SetupPhotoSlot(
                            label: 'Before',
                            photoPath: beforePath,
                            onTap: onPickBefore,
                          ),
                          if (_photoExists(beforePath))
                            _PhotoDateRow(
                              date: beforeDate,
                              onTap: onPickBeforeDate,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _SetupPhotoSlot(
                            label: 'After',
                            photoPath: afterPath,
                            onTap: onPickAfter,
                          ),
                          if (_photoExists(afterPath))
                            _PhotoDateRow(
                              date: afterDate,
                              onTap: onPickAfterDate,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _SectionHeader(
                  title: 'From my procedures',
                  trailing: procedures.isEmpty ? 'None yet' : '${procedures.length} with photos',
                ),
                if (procedures.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _border, width: 0.5),
                    ),
                    child: Text(
                      'Complete a procedure and add before/after photos — they will appear here.',
                      style: _Type.base.copyWith(color: Colors.white.withValues(alpha: 0.35), height: 1.4),
                    ),
                  )
                else
                  SizedBox(
                    height: 112,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: procedures.length,
                      separatorBuilder: (context, index) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final p = procedures[i];
                        final thumb = _photoExists(p.afterPhotoPath)
                            ? p.afterPhotoPath!
                            : p.beforePhotoPath!;
                        return _StoredProcedureCard(
                          title: p.title,
                          date: formatDate(p.date),
                          thumbPath: thumb,
                          hasPair: _photoExists(p.beforePhotoPath) && _photoExists(p.afterPhotoPath),
                          onTap: () => onProcedureTap(p),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 22),
                _SectionHeader(
                  title: 'History of transformation',
                  trailing: historyLoading
                      ? 'Loading…'
                      : transformationHistory.isEmpty
                          ? 'None yet'
                          : '${transformationHistory.length} saved',
                ),
                if (historyLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                      ),
                    ),
                  )
                else if (transformationHistory.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _border, width: 0.5),
                    ),
                    child: Text(
                      'Tap “Show comparison result” — your last 5 analyses will appear here. Tap one to view it again.',
                      style: _Type.base.copyWith(color: Colors.white.withValues(alpha: 0.35), height: 1.4),
                    ),
                  )
                else
                  SizedBox(
                    height: 112,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: transformationHistory.length,
                      separatorBuilder: (context, index) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final entry = transformationHistory[i];
                        return _StoredTransformationHistoryCard(
                          date: formatDate(entry.afterDate ?? entry.createdAt),
                          scoreLabel: entry.scoreLabel,
                          thumbPath: entry.afterForDisplay,
                          onTap: () => onTransformationHistoryTap(entry),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            _pageHPad,
            8,
            _pageHPad,
            12 + MediaQuery.paddingOf(context).bottom,
          ),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: canCompare ? onShowComparison : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.18),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.28),
                padding: const EdgeInsets.symmetric(vertical: 15),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
              ),
              child: analyzing
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        ),
                        const SizedBox(width: 10),
                        Text('Analysing photos…', style: _Type.shareMain),
                      ],
                    )
                  : Text('Show comparison result', style: _Type.shareMain),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhotoDateRow extends StatelessWidget {
  const _PhotoDateRow({required this.date, required this.onTap});

  final DateTime? date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: _surface2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined, size: 14, color: Colors.white.withValues(alpha: 0.45)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    date != null ? 'Taken ${formatDate(date!)}' : 'Set photo date',
                    style: _Type.base.copyWith(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: date != null ? 0.65 : 0.38),
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 16, color: Colors.white.withValues(alpha: 0.25)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupPhotoSlot extends StatelessWidget {
  const _SetupPhotoSlot({
    required this.label,
    required this.photoPath,
    required this.onTap,
  });

  final String label;
  final String? photoPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photoExists(photoPath);
    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 200,
          decoration: BoxDecoration(
            border: Border.all(color: _border, width: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasPhoto)
                Image(image: _imageProvider(photoPath!), fit: BoxFit.cover)
              else
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined,
                        size: 28, color: Colors.white.withValues(alpha: 0.22)),
                    const SizedBox(height: 8),
                    Text(
                      'Add $label',
                      style: _Type.base.copyWith(
                        color: Colors.white.withValues(alpha: 0.38),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              Positioned(
                left: 8,
                bottom: 8,
                child: _PhotoTag(label: label.toUpperCase()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoredTransformationHistoryCard extends StatelessWidget {
  const _StoredTransformationHistoryCard({
    required this.date,
    required this.scoreLabel,
    required this.thumbPath,
    required this.onTap,
  });

  final String date;
  final String scoreLabel;
  final String thumbPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 148,
          decoration: BoxDecoration(
            border: Border.all(color: _border, width: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image(image: _imageProvider(thumbPath), fit: BoxFit.cover),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'Pair',
                          style: _Type.base.copyWith(fontSize: 9, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Transformation',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _Type.base.copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      date,
                      style: _Type.base.copyWith(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.38),
                      ),
                    ),
                    Text(
                      scoreLabel,
                      style: _Type.base.copyWith(
                        fontSize: 10,
                        color: const Color(0xFF22D3EE).withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoredProcedureCard extends StatelessWidget {
  const _StoredProcedureCard({
    required this.title,
    required this.date,
    required this.thumbPath,
    required this.hasPair,
    required this.onTap,
  });

  final String title;
  final String date;
  final String thumbPath;
  final bool hasPair;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 148,
          decoration: BoxDecoration(
            border: Border.all(color: _border, width: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image(image: _imageProvider(thumbPath), fit: BoxFit.cover),
                    if (hasPair)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('Pair', style: _Type.photoTag),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _Type.procName.copyWith(fontSize: 11)),
                    Text(date, style: _Type.procDate),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Phase 2: full comparison ──────────────────────────────────────────────────
class _CompareResultsView extends StatefulWidget {
  const _CompareResultsView({
    required this.snapshot,
    required this.tab,
    required this.split,
    this.readOnly = false,
    required this.onBack,
    required this.onClose,
    required this.onTab,
    required this.onSplit,
    required this.onPickBefore,
    required this.onPickAfter,
  });

  final _ComparisonSnapshot snapshot;
  final _CompareTab tab;
  final double split;
  final bool readOnly;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final ValueChanged<_CompareTab> onTab;
  final ValueChanged<double> onSplit;
  final VoidCallback onPickBefore;
  final VoidCallback onPickAfter;

  @override
  State<_CompareResultsView> createState() => _CompareResultsViewState();
}

class _CompareResultsViewState extends State<_CompareResultsView> {
  bool _sliderDragging = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: _sliderDragging
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CompareNavBar(
            title: 'My transformation',
            subtitle: widget.snapshot.rangeLabel,
            onBack: widget.onBack,
            onClose: widget.onClose,
          ),
          _CompareFrame(
            tab: widget.tab,
            split: widget.split,
            beforePath: widget.snapshot.beforePath,
            afterPath: widget.snapshot.afterPath,
            beforeLabel: widget.snapshot.beforePhotoLabel,
            afterLabel: widget.snapshot.afterPhotoLabel,
            monthsApart: widget.snapshot.monthsApart,
            beforeScore: widget.snapshot.beforeScore,
            afterScore: widget.snapshot.afterScore,
            overallDelta: widget.snapshot.overallDelta,
            zoneCount: widget.snapshot.zoneCount,
            landmarksDetected: widget.snapshot.landmarksDetected,
            onTab: widget.onTab,
            onSplit: widget.onSplit,
            onPickBefore: widget.readOnly ? null : widget.onPickBefore,
            onPickAfter: widget.readOnly ? null : widget.onPickAfter,
            onSliderDragActive: (active) {
              if (_sliderDragging != active) {
                setState(() => _sliderDragging = active);
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(_pageHPad, 0, _pageHPad, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ZoneDifferencesSection(zones: widget.snapshot.zones),
                _MetricsSection(metrics: widget.snapshot.metrics),
                _ProceduresSection(items: widget.snapshot.procedures),
                const _ShareSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Nav ───────────────────────────────────────────────────────────────────────
class _CompareNavBar extends StatelessWidget {
  const _CompareNavBar({
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.onClose,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Row(
          children: [
            _NavCircleButton(icon: Icons.chevron_left, onTap: onBack),
            Expanded(
              child: Column(
                children: [
                  Text(title, style: _Type.navTitle),
                  const SizedBox(height: 1),
                  Text(subtitle, style: _Type.navSub),
                ],
              ),
            ),
            if (onClose != null) ...[
              _NavCircleButton(icon: Icons.download_outlined, onTap: () {}),
              const SizedBox(width: 6),
              _NavCircleButton(icon: Icons.share_outlined, onTap: () {}),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavCircleButton extends StatelessWidget {
  const _NavCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface2,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.5)),
        ),
      ),
    );
  }
}

// ── Compare frame ─────────────────────────────────────────────────────────────
class _CompareFrame extends StatelessWidget {
  const _CompareFrame({
    required this.tab,
    required this.split,
    required this.beforePath,
    required this.afterPath,
    required this.beforeLabel,
    required this.afterLabel,
    required this.monthsApart,
    required this.beforeScore,
    required this.afterScore,
    required this.overallDelta,
    required this.zoneCount,
    required this.landmarksDetected,
    required this.onTab,
    required this.onSplit,
    required this.onPickBefore,
    required this.onPickAfter,
    this.onSliderDragActive,
  });

  final _CompareTab tab;
  final double split;
  final String? beforePath;
  final String? afterPath;
  final String beforeLabel;
  final String afterLabel;
  final int monthsApart;
  final int beforeScore;
  final int afterScore;
  final String overallDelta;
  final int zoneCount;
  final int landmarksDetected;
  final ValueChanged<_CompareTab> onTab;
  final ValueChanged<double> onSplit;
  final VoidCallback? onPickBefore;
  final VoidCallback? onPickAfter;
  final ValueChanged<bool>? onSliderDragActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(_frameMarginH, 4, _frameMarginH, _sectionMb),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(_frameRadius),
        border: Border.all(color: _border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CompareFrameHeader(tab: tab, onTab: onTab, monthsApart: monthsApart),
          SizedBox(
            height: _comparePhotoHeight(context),
            child: _ComparePhotos(
              tab: tab,
              split: split,
              beforePath: beforePath,
              afterPath: afterPath,
              beforeLabel: beforeLabel,
              afterLabel: afterLabel,
              onSplit: onSplit,
              onPickBefore: onPickBefore,
              onPickAfter: onPickAfter,
              onSliderDragActive: onSliderDragActive,
            ),
          ),
          _ScoreStrip(
            beforeScore: beforeScore,
            afterScore: afterScore,
            overallDelta: overallDelta,
          ),
          _DeltaBadge(zoneCount: zoneCount, landmarksDetected: landmarksDetected),
        ],
      ),
    );
  }
}

class _CompareFrameHeader extends StatelessWidget {
  const _CompareFrameHeader({
    required this.tab,
    required this.onTab,
    required this.monthsApart,
  });

  final _CompareTab tab;
  final ValueChanged<_CompareTab> onTab;
  final int monthsApart;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _border, width: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: _tabBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                _TabChip(
                  label: 'Side by side',
                  selected: tab == _CompareTab.sideBySide,
                  onTap: () => onTab(_CompareTab.sideBySide),
                ),
                _TabChip(
                  label: 'Slider',
                  selected: tab == _CompareTab.slider,
                  onTap: () => onTab(_CompareTab.slider),
                ),
              ],
            ),
          ),
          const Spacer(),
          Text(
            monthsApart > 0 ? '$monthsApart months apart' : 'Comparison',
            style: _Type.frameDate,
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? _tabOn : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: selected ? _Type.tabOn : _Type.tab),
      ),
    );
  }
}

class _ComparePhotos extends StatelessWidget {
  const _ComparePhotos({
    required this.tab,
    required this.split,
    required this.beforePath,
    required this.afterPath,
    required this.beforeLabel,
    required this.afterLabel,
    required this.onSplit,
    required this.onPickBefore,
    required this.onPickAfter,
    this.onSliderDragActive,
  });

  final _CompareTab tab;
  final double split;
  final String? beforePath;
  final String? afterPath;
  final String beforeLabel;
  final String afterLabel;
  final ValueChanged<double> onSplit;
  final VoidCallback? onPickBefore;
  final VoidCallback? onPickAfter;
  final ValueChanged<bool>? onSliderDragActive;

  void _setSplit(double next) {
    onSplit(next.clamp(0.08, 0.92));
  }

  void _setSliderDragging(bool active) => onSliderDragActive?.call(active);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;

        if (tab == _CompareTab.sideBySide) {
          return Row(
            children: [
              Expanded(
                child: _PhotoSide(
                  bg: _photoBefore,
                  label: 'BEFORE',
                  date: beforeLabel,
                  photoPath: beforePath,
                  onTap: onPickBefore,
                ),
              ),
              Container(width: 1, color: _border),
              Expanded(
                child: _PhotoSide(
                  bg: _photoAfter,
                  label: 'NOW',
                  date: afterLabel,
                  photoPath: afterPath,
                  onTap: onPickAfter,
                ),
              ),
            ],
          );
        }

        final fraction = split.clamp(0.08, 0.92);
        final splitX = w * fraction;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) => _setSliderDragging(true),
          onHorizontalDragUpdate: (d) => _setSplit(split + d.delta.dx / w),
          onHorizontalDragEnd: (_) => _setSliderDragging(false),
          onHorizontalDragCancel: () => _setSliderDragging(false),
          onTapDown: (d) => _setSplit(d.localPosition.dx / w),
          child: ColoredBox(
            color: _bg,
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: _CompareFillImage(path: afterPath, bg: _photoAfter),
                ),
                Positioned.fill(
                  child: ClipRect(
                    clipper: _CompareLeftSplitClipper(fraction: fraction),
                    child: _CompareFillImage(path: beforePath, bg: _photoBefore),
                  ),
                ),
                Positioned(
                  left: splitX - 0.75,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 1.5,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
                Positioned(
                  left: splitX - 14,
                  top: h / 2 - 14,
                  child: const _DragDot(),
                ),
                Positioned(
                  left: 8,
                  bottom: 8,
                  child: _PhotoTag(label: 'BEFORE'),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: _PhotoDateTag(date: afterLabel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Clips the before image from the left — same approach as glow_up_result_screen.
class _CompareLeftSplitClipper extends CustomClipper<Rect> {
  const _CompareLeftSplitClipper({required this.fraction});

  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(covariant _CompareLeftSplitClipper old) => old.fraction != fraction;
}

class _CompareFillImage extends StatelessWidget {
  const _CompareFillImage({required this.path, required this.bg});

  final String? path;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    if (!_photoExists(path)) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Icon(Icons.person_outline, size: 48, color: _faceBg),
        ),
      );
    }
    return Image(
      image: _imageProvider(path!),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      gaplessPlayback: true,
    );
  }
}

class _DragDot extends StatelessWidget {
  const _DragDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: _bg, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.swap_horiz, size: 13, color: Colors.black),
    );
  }
}

class _PhotoSide extends StatelessWidget {
  const _PhotoSide({
    required this.bg,
    required this.label,
    required this.date,
    required this.photoPath,
    required this.onTap,
  });

  final Color bg;
  final String label;
  final String date;
  final String? photoPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photoExists(photoPath);
    return Material(
      color: bg,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasPhoto)
              Image(image: _imageProvider(photoPath!), fit: BoxFit.cover)
            else
              Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final ph = constraints.maxHeight;
                    final iconH = (ph * 0.42).clamp(100.0, 160.0);
                    final iconW = iconH * 0.75;
                    return Container(
                      width: iconW,
                      height: iconH,
                      decoration: BoxDecoration(
                        color: _faceBg,
                        borderRadius: BorderRadius.circular(iconH / 2),
                        border: Border.all(color: const Color(0xFF222228), width: 0.5),
                      ),
                      child: Icon(
                        Icons.person_outline,
                        size: iconH * 0.28,
                        color: const Color(0xFF222228),
                      ),
                    );
                  },
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: _PhotoTag(label: label),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: _PhotoDateTag(date: date),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoTag extends StatelessWidget {
  const _PhotoTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: _Type.photoTag),
    );
  }
}

class _PhotoDateTag extends StatelessWidget {
  const _PhotoDateTag({required this.date});

  final String date;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(date, style: _Type.photoDate),
    );
  }
}

class _ScoreStrip extends StatelessWidget {
  const _ScoreStrip({
    required this.beforeScore,
    required this.afterScore,
    required this.overallDelta,
  });

  final int beforeScore;
  final int afterScore;
  final String overallDelta;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _border, width: 0.5)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(right: BorderSide(color: _border, width: 0.5)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: _ScoreHalf(
                  score: '$beforeScore',
                  highlight: false,
                  label: 'GLOW SCORE',
                  value: '$beforeScore / 100',
                  delta: 'Baseline',
                  showTrend: false,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                child: _ScoreHalf(
                  score: '$afterScore',
                  highlight: true,
                  label: 'CURRENT',
                  value: '$afterScore / 100',
                  delta: overallDelta,
                  showTrend: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreHalf extends StatelessWidget {
  const _ScoreHalf({
    required this.score,
    required this.highlight,
    required this.label,
    required this.value,
    required this.delta,
    required this.showTrend,
  });

  final String score;
  final bool highlight;
  final String label;
  final String value;
  final String delta;
  final bool showTrend;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: highlight ? Colors.white.withValues(alpha: 0.4) : const Color(0xFF2A2A30),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(score, style: highlight ? _Type.circleScoreHi : _Type.circleScore),
              Text('score', style: _Type.circleLbl),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: _Type.scoreLbl),
              const SizedBox(height: 4),
              Text(value, style: highlight ? _Type.scoreValHi : _Type.scoreVal),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showTrend) ...[
                    Icon(Icons.trending_up, size: 11, color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      delta,
                      style: highlight
                          ? _coloredDeltaStyle(_Type.scoreDeltaHi, fill: 0.85, delta: delta)
                          : _Type.scoreDelta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({required this.zoneCount, required this.landmarksDetected});

  final int zoneCount;
  final int landmarksDetected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: _surface2,
        border: Border(top: BorderSide(color: _border, width: 0.5)),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text('IMPROVEMENTS DETECTED', style: _Type.deltaBadgeLbl),
          ),
          const SizedBox(width: 8),
          _InfoPill(icon: Icons.visibility_outlined, label: '$landmarksDetected landmarks'),
          const SizedBox(width: 4),
          _InfoPill(icon: Icons.document_scanner_outlined, label: '$zoneCount zones'),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _tabOn,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: Colors.white.withValues(alpha: 0.4)),
          const SizedBox(width: 4),
          Text(label, style: _Type.deltaPill),
        ],
      ),
    );
  }
}

// ── Sections below compare frame ──────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.trailing});

  final String title;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _sectionHeaderMb),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(title, style: _Type.sectionTitle),
          const Spacer(),
          Text(trailing, style: _Type.sectionRight),
        ],
      ),
    );
  }
}

class _ZoneDifferencesSection extends StatelessWidget {
  const _ZoneDifferencesSection({required this.zones});

  final List<FaceZone> zones;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _sectionMb),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(title: 'Zone differences', trailing: 'AI analysed'),
          _TransformationFaceMap(zones: zones),
          const SizedBox(height: 20),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.55,
            padding: EdgeInsets.zero,
            children: [for (final z in zones) _ZoneTile(zone: z)],
          ),
        ],
      ),
    );
  }
}

class _TransformationFaceMap extends StatelessWidget {
  const _TransformationFaceMap({required this.zones});

  final List<FaceZone> zones;

  FaceZone? _zoneByName(String name) {
    for (final z in zones) {
      if (z.name == name) return z;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 248,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border, width: 0.5),
      ),
      child: Center(
        child: SizedBox(
          width: 120,
          height: 200,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: 20,
                left: 0,
                child: Container(
                  width: 120,
                  height: 160,
                  decoration: BoxDecoration(
                    color: _faceBg,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _border, width: 0.5),
                  ),
                ),
              ),
              for (final d in _faceZoneDots)
                _ZoneMapDot(
                  zone: _zoneByName(d.zoneName),
                  alignment: d.alignment,
                  baseSize: d.size,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoneMapDot extends StatelessWidget {
  const _ZoneMapDot({
    required this.zone,
    required this.alignment,
    required this.baseSize,
  });

  final FaceZone? zone;
  final Alignment alignment;
  final double baseSize;

  @override
  Widget build(BuildContext context) {
    final z = zone;
    final fill = z?.fill ?? 0.15;
    final diameter = z != null ? _zoneDotDiameter(z, baseSize) : baseSize * 0.75;
    final color = _zoneDotColor(fill);
    final bright = fill >= 0.45;
    final score = z?.after ?? '';

    final offset = _faceAlignOffset(alignment, diameter);

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: Container(
        width: diameter,
        height: diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: bright ? Colors.white.withValues(alpha: 0.75) : const Color(0xFF3A3A44),
            width: bright ? 2 : 1.2,
          ),
          boxShadow: bright
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.55),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: z != null
            ? Text(
                score,
                style: bright ? _Type.mapDotScore : _Type.mapDotScoreDim,
              )
            : null,
      ),
    );
  }
}

class _ZoneTile extends StatelessWidget {
  const _ZoneTile({required this.zone});

  final FaceZone zone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(zone.name, style: _Type.zoneName, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              Text(
                zone.delta,
                style: _coloredDeltaStyle(_Type.zoneVal, fill: zone.fill, delta: zone.delta),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(1),
            child: LinearProgressIndicator(
              value: zone.fill,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation(
                _improvementColor(fill: zone.fill, delta: zone.delta).withValues(alpha: 0.85),
              ),
              minHeight: 2,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(zone.before, style: _Type.zoneBefore),
              Text(' → ', style: _Type.zoneBefore.copyWith(color: Colors.white.withValues(alpha: 0.18))),
              Text(zone.after, style: _Type.zoneAfter),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricsSection extends StatelessWidget {
  const _MetricsSection({required this.metrics});

  final List<MetricRow> metrics;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _sectionMb),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionHeader(title: 'Metric changes', trailing: 'before → after'),
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < metrics.length; i++)
                  _MetricRow(metric: metrics[i], showDivider: i < metrics.length - 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metric, required this.showDivider});

  final MetricRow metric;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _containerInnerH,
        vertical: _containerInnerV,
      ),
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: _borderSoft, width: 0.5)),
            )
          : null,
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(metric.name, style: _Type.metricName)),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final markX = constraints.maxWidth * metric.beforeMark;
                return SizedBox(
                  height: 6,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.centerLeft,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(1),
                        child: LinearProgressIndicator(
                          value: metric.fill,
                          backgroundColor: _border,
                          valueColor: AlwaysStoppedAnimation(
                            _improvementColor(fill: metric.fill, delta: metric.delta)
                                .withValues(alpha: 0.8),
                          ),
                          minHeight: 2,
                        ),
                      ),
                      Positioned(
                        left: markX,
                        top: -2,
                        child: Container(
                          width: 1,
                          height: 6,
                          color: Colors.white.withValues(alpha: 0.15),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 26,
            child: Text(
              metric.delta,
              textAlign: TextAlign.right,
              style: _coloredDeltaStyle(_Type.metricVal, fill: metric.fill, delta: metric.delta),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProceduresSection extends StatelessWidget {
  const _ProceduresSection({required this.items});

  final List<ProcedureItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: _sectionMb),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            title: 'Procedures done',
            trailing: items.isEmpty ? 'None in period' : '${items.length} total',
          ),
          Container(
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No procedures logged between these photo dates. Add treatments in your passport to see them here.',
                      style: _Type.base.copyWith(
                        color: Colors.white.withValues(alpha: 0.35),
                        height: 1.4,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        _ProcedureRow(item: items[i], showDivider: i < items.length - 1),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProcedureRow extends StatelessWidget {
  const _ProcedureRow({required this.item, required this.showDivider});

  final ProcedureItem item;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final meta = item.detail.isEmpty ? item.clinic : '${item.clinic} · ${item.detail}';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: _containerInnerH,
        vertical: _containerInnerV,
      ),
      decoration: showDivider
          ? const BoxDecoration(
              border: Border(bottom: BorderSide(color: _borderSoft, width: 0.5)),
            )
          : null,
      child: Row(
        children: [
          SizedBox(width: 16, child: Text(item.num, style: _Type.procNum)),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _surface2,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(item.icon, size: 12, color: Colors.white.withValues(alpha: 0.25)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: _Type.procName),
                const SizedBox(height: 2),
                Text(meta, style: _Type.procMeta),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                item.points,
                style: _coloredDeltaStyle(_Type.procScore, fill: 0.55, delta: item.points),
              ),
              const SizedBox(height: 1),
              Text(item.date, style: _Type.procDate),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareSection extends StatelessWidget {
  const _ShareSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.share_outlined, size: 15, color: Colors.black),
              label: Text('Share my transformation', style: _Type.shareMain),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _ShareChip(icon: Icons.music_note, label: 'TikTok')),
              const SizedBox(width: 8),
              Expanded(child: _ShareChip(icon: Icons.camera_alt_outlined, label: 'Instagram')),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareChip extends StatelessWidget {
  const _ShareChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () {},
      icon: Icon(icon, size: 14, color: Colors.white.withValues(alpha: 0.3)),
      label: Text(label, style: _Type.shareSecondary),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        side: const BorderSide(color: _border, width: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: _surface,
      ),
    );
  }
}

String _procedureDetailLine(Procedure p) {
  if (p.volumeMl != null) return '${p.volumeMl} ml';
  if ((p.product ?? '').trim().isNotEmpty) return p.product!.trim();
  if (p.zones.isNotEmpty) return p.zones.take(2).join(', ');
  return '';
}

IconData _procedureIconFor(String title) {
  final t = title.toLowerCase();
  if (t.contains('lip') || t.contains('filler')) return Icons.colorize_outlined;
  if (t.contains('prp') || t.contains('plasma')) return Icons.water_drop_outlined;
  if (t.contains('botox') || t.contains('toxin')) return Icons.auto_awesome_outlined;
  return Icons.medical_services_outlined;
}

bool _photoExists(String? path) {
  final p = (path ?? '').trim();
  if (p.isEmpty) return false;
  return isRemoteUrl(p) || File(p).existsSync();
}

ImageProvider _imageProvider(String path) {
  if (isRemoteUrl(path)) return NetworkImage(path);
  return FileImage(File(path));
}
