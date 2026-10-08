import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../ui/photo_storage.dart';
import 'glow_analysis_codec.dart';
import 'glow_up_pipeline.dart';

/// A saved Glow Up transformation (before/after + metadata).
class GlowUpHistoryEntry {
  const GlowUpHistoryEntry({
    required this.id,
    required this.beforePath,
    this.afterPath,
    this.beforeLocalPath,
    this.afterLocalPath,
    this.sliderBeforePath,
    this.sliderAfterPath,
    this.sliderBeforeLocalPath,
    this.sliderAfterLocalPath,
    required this.createdAt,
    required this.glowScore,
    required this.potentialScore,
    this.analysisSnapshot,
  });

  final String id;
  /// Firebase URL or archived local file — used for display.
  final String beforePath;
  final String? afterPath;
  /// On-device archive (survives temp slider file cleanup).
  final String? beforeLocalPath;
  final String? afterLocalPath;
  /// Matched 1024² slider pair — same framing as the live result screen.
  final String? sliderBeforePath;
  final String? sliderAfterPath;
  final String? sliderBeforeLocalPath;
  final String? sliderAfterLocalPath;
  final DateTime createdAt;
  final int glowScore;
  final int potentialScore;

  /// Full glow report (scores, face report, dissolve zones, preview text).
  final Map<String, dynamic>? analysisSnapshot;

  String get beforeForDisplay {
    final slider = (sliderBeforeLocalPath ?? sliderBeforePath ?? '').trim();
    if (slider.isNotEmpty && !isRemoteUrl(slider) && File(slider).existsSync()) {
      return slider;
    }
    if (slider.isNotEmpty && isRemoteUrl(slider)) return slider;
    final local = (beforeLocalPath ?? '').trim();
    if (isRemoteUrl(beforePath)) return beforePath;
    if (local.isNotEmpty && File(local).existsSync()) return local;
    return beforePath;
  }

  String? get afterForDisplay {
    final slider = (sliderAfterLocalPath ?? sliderAfterPath ?? '').trim();
    if (slider.isNotEmpty && !isRemoteUrl(slider) && File(slider).existsSync()) {
      return slider;
    }
    if (slider.isNotEmpty && isRemoteUrl(slider)) return slider;
    final after = (afterPath ?? '').trim();
    if (after.isEmpty) return null;
    final local = (afterLocalPath ?? '').trim();
    if (isRemoteUrl(after)) return after;
    if (local.isNotEmpty && File(local).existsSync()) return local;
    return after;
  }

  /// Slider paths for the compare UI (prefer archived slider JPEGs).
  String? get sliderBeforeForDisplay {
    final slider = (sliderBeforeLocalPath ?? sliderBeforePath ?? '').trim();
    if (slider.isEmpty) return null;
    if (!isRemoteUrl(slider) && !File(slider).existsSync()) return null;
    return slider;
  }

  String? get sliderAfterForDisplay {
    final slider = (sliderAfterLocalPath ?? sliderAfterPath ?? '').trim();
    if (slider.isEmpty) return null;
    if (!isRemoteUrl(slider) && !File(slider).existsSync()) return null;
    return slider;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'beforePath': beforePath,
        'afterPath': afterPath,
        'beforeLocalPath': beforeLocalPath,
        'afterLocalPath': afterLocalPath,
        'sliderBeforePath': sliderBeforePath,
        'sliderAfterPath': sliderAfterPath,
        'sliderBeforeLocalPath': sliderBeforeLocalPath,
        'sliderAfterLocalPath': sliderAfterLocalPath,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'glowScore': glowScore,
        'potentialScore': potentialScore,
        if (analysisSnapshot != null) 'analysis': analysisSnapshot,
      };

  /// Rebuilds the live result UI from archived images + saved analysis.
  GlowAnalysisResult toAnalysisResult() {
    final sliderBefore = sliderBeforeForDisplay;
    final sliderAfter = sliderAfterForDisplay;
    if (analysisSnapshot != null && analysisSnapshot!.isNotEmpty) {
      final decoded = GlowAnalysisCodec.decode(analysisSnapshot!);
      return GlowAnalysisResult(
        originalPath: beforeForDisplay,
        rawPhotoPath: decoded.rawPhotoPath,
        enhancedUrl: afterForDisplay,
        sliderBeforePath: sliderBefore ?? decoded.sliderBeforePath,
        sliderAfterPath: sliderAfter ?? decoded.sliderAfterPath,
        sliderSideBySidePath: decoded.sliderSideBySidePath,
        scores: decoded.scores,
        faceReport: decoded.faceReport,
        dissolveZones: decoded.dissolveZones,
        error: decoded.error,
      );
    }
    final base = GlowScores.synthetic(id.hashCode);
    return GlowAnalysisResult(
      originalPath: beforeForDisplay,
      enhancedUrl: afterForDisplay,
      sliderBeforePath: sliderBefore,
      sliderAfterPath: sliderAfter,
      scores: GlowScores(
        glowScore: glowScore,
        potentialScore: potentialScore,
        zones: base.zones,
        skinMetrics: base.skinMetrics,
      ),
    );
  }

  factory GlowUpHistoryEntry.fromJson(Map<String, dynamic> json) {
    return GlowUpHistoryEntry(
      id: json['id'] as String? ?? const Uuid().v4(),
      beforePath: json['beforePath'] as String? ?? '',
      afterPath: json['afterPath'] as String?,
      beforeLocalPath: json['beforeLocalPath'] as String?,
      afterLocalPath: json['afterLocalPath'] as String?,
      sliderBeforePath: json['sliderBeforePath'] as String?,
      sliderAfterPath: json['sliderAfterPath'] as String?,
      sliderBeforeLocalPath: json['sliderBeforeLocalPath'] as String?,
      sliderAfterLocalPath: json['sliderAfterLocalPath'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      glowScore: (json['glowScore'] as num?)?.round() ?? 0,
      potentialScore: (json['potentialScore'] as num?)?.round() ?? 0,
      analysisSnapshot: json['analysis'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(json['analysis'] as Map)
          : null,
    );
  }
}

/// Local cache + Firestore under `users/{uid}/glow_up_history/{id}`.
/// Images archived under Documents/glow_history/{id}/ (and Firebase Storage when signed in).
class GlowUpHistoryStore {
  static const _key = 'glow_up_history_v2';
  static const _legacyKey = 'glow_up_history_v1';
  static const _maxEntries = 5;

  /// Firestore subcollection: `users/{uid}/glow_up_history`.
  static const firestoreCollection = 'glow_up_history';

  static FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  static FirebaseAuth get _auth => FirebaseAuth.instance;

  static String? get _uid => _auth.currentUser?.uid;

  static CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _firestore.collection('users').doc(uid).collection(firestoreCollection);

  static Map<String, dynamic> _toFirestore(GlowUpHistoryEntry entry) => {
        'id': entry.id,
        'beforePath': entry.beforePath,
        'createdAt': Timestamp.fromDate(entry.createdAt.toUtc()),
        'glowScore': entry.glowScore,
        'potentialScore': entry.potentialScore,
        if (entry.afterPath != null) 'afterPath': entry.afterPath,
        if (entry.sliderBeforePath != null) 'sliderBeforePath': entry.sliderBeforePath,
        if (entry.sliderAfterPath != null) 'sliderAfterPath': entry.sliderAfterPath,
        if (entry.analysisSnapshot != null) 'analysis': entry.analysisSnapshot,
      };

  static GlowUpHistoryEntry? _fromFirestoreDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) return null;
    try {
      final m = Map<String, dynamic>.from(data);
      m['id'] = doc.id;
      final created = data['createdAt'];
      if (created is Timestamp) {
        m['createdAt'] = created.toDate().toUtc().toIso8601String();
      }
      return GlowUpHistoryEntry.fromJson(m);
    } catch (e) {
      debugPrint('[GlowUpHistory] firestore parse error: $e');
      return null;
    }
  }

  static Future<List<GlowUpHistoryEntry>> _listFromFirestore(String uid) async {
    final snap = await _col(uid)
        .orderBy('createdAt', descending: true)
        .limit(_maxEntries)
        .get();
    return [
      for (final d in snap.docs)
        if (_fromFirestoreDoc(d) case final e?) e,
    ];
  }

  static Future<List<GlowUpHistoryEntry>> _listLocal() async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      raw = prefs.getString(_legacyKey);
    }
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final items = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) GlowUpHistoryEntry.fromJson(item),
      ];
      if (items.length <= _maxEntries) return items;
      return items.sublist(0, _maxEntries);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveLocal(List<GlowUpHistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<GlowUpHistoryEntry>> list() async {
    final uid = _uid;
    if (uid != null) {
      try {
        final remote = await _listFromFirestore(uid);
        if (remote.isNotEmpty) {
          await _saveLocal(remote);
          return remote;
        }
      } catch (e) {
        debugPrint('[GlowUpHistory] firestore list error: $e');
      }
    }
    return _listLocal();
  }

  /// Archives before/after to permanent storage and optional Firebase upload.
  static Future<GlowUpHistoryEntry> createEntry({
    required String beforeSource,
    String? afterSource,
    String? sliderBeforeSource,
    String? sliderAfterSource,
    required int glowScore,
    required int potentialScore,
    GlowAnalysisResult? analysis,
    DateTime? createdAt,
  }) async {
    final id = const Uuid().v4();
    GlowHistoryImagePaths paths;
    try {
      paths = await persistGlowHistoryImages(
        entryId: id,
        beforeSource: beforeSource,
        afterSource: afterSource,
        sliderBeforeSource: sliderBeforeSource,
        sliderAfterSource: sliderAfterSource,
      );
    } catch (e, st) {
      debugPrint('[GlowUpHistory] archive failed: $e\n$st');
      paths = GlowHistoryImagePaths(
        beforeDisplayPath: beforeSource,
        afterDisplayPath: afterSource,
        beforeLocalPath: beforeSource,
        afterLocalPath: afterSource,
        sliderBeforeDisplayPath: sliderBeforeSource,
        sliderAfterDisplayPath: sliderAfterSource,
        sliderBeforeLocalPath: sliderBeforeSource,
        sliderAfterLocalPath: sliderAfterSource,
      );
    }

    return GlowUpHistoryEntry(
      id: id,
      beforePath: paths.beforeDisplayPath,
      afterPath: paths.afterDisplayPath,
      beforeLocalPath: paths.beforeLocalPath,
      afterLocalPath: paths.afterLocalPath,
      sliderBeforePath: paths.sliderBeforeDisplayPath,
      sliderAfterPath: paths.sliderAfterDisplayPath,
      sliderBeforeLocalPath: paths.sliderBeforeLocalPath,
      sliderAfterLocalPath: paths.sliderAfterLocalPath,
      createdAt: createdAt ?? DateTime.now(),
      glowScore: glowScore,
      potentialScore: potentialScore,
      analysisSnapshot:
          analysis != null ? GlowAnalysisCodec.encode(analysis) : null,
    );
  }

  static Future<void> _deleteFromFirestore(String uid, String entryId) async {
    try {
      await _col(uid).doc(entryId).delete();
    } catch (e) {
      debugPrint('[GlowUpHistory] firestore delete error ($entryId): $e');
    }
  }

  static Future<void> _trimFirestore(String uid) async {
    try {
      final snap = await _col(uid).orderBy('createdAt', descending: true).get();
      if (snap.docs.length <= _maxEntries) return;
      final batch = _firestore.batch();
      for (final d in snap.docs.sublist(_maxEntries)) {
        batch.delete(d.reference);
      }
      await batch.commit();
    } catch (e) {
      debugPrint('[GlowUpHistory] firestore trim error: $e');
    }
  }

  static Future<void> _syncToFirestore(GlowUpHistoryEntry entry) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _col(uid).doc(entry.id).set(_toFirestore(entry));
      await _trimFirestore(uid);
    } catch (e) {
      debugPrint('[GlowUpHistory] firestore sync error: $e');
    }
  }

  static Future<void> add(GlowUpHistoryEntry entry) async {
    if (entry.beforePath.trim().isEmpty &&
        (entry.beforeLocalPath ?? '').trim().isEmpty) {
      return;
    }

    final existing = await _listLocal();

    final duplicate = existing.any(
      (e) =>
          e.id == entry.id ||
          (e.beforePath == entry.beforePath &&
              e.afterPath == entry.afterPath &&
              entry.createdAt.difference(e.createdAt).inSeconds.abs() < 60),
    );
    if (duplicate) return;

    final next = [entry, ...existing];
    final trimmed =
        next.length > _maxEntries ? next.sublist(0, _maxEntries) : next;
    final dropped =
        next.length > _maxEntries ? next.sublist(_maxEntries) : const <GlowUpHistoryEntry>[];

    await _saveLocal(trimmed);

    final uid = _uid;
    if (uid != null) {
      await _syncToFirestore(entry);
      for (final old in dropped) {
        await _deleteFromFirestore(uid, old.id);
      }
    }
  }
}
