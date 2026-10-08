import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../ui/photo_storage.dart';

/// A saved before/after transformation comparison from the compare screen.
class TransformationHistoryEntry {
  const TransformationHistoryEntry({
    required this.id,
    required this.beforePath,
    required this.afterPath,
    this.beforeLocalPath,
    this.afterLocalPath,
    this.beforeDate,
    this.afterDate,
    required this.beforeScore,
    required this.afterScore,
    required this.createdAt,
    this.snapshotData,
  });

  final String id;
  final String beforePath;
  final String afterPath;
  final String? beforeLocalPath;
  final String? afterLocalPath;
  final DateTime? beforeDate;
  final DateTime? afterDate;
  final int beforeScore;
  final int afterScore;
  final DateTime createdAt;

  /// Full comparison UI payload (zones, metrics, procedures, scores).
  final Map<String, dynamic>? snapshotData;

  String get beforeForDisplay {
    final local = (beforeLocalPath ?? '').trim();
    if (isRemoteUrl(beforePath)) return beforePath;
    if (local.isNotEmpty && File(local).existsSync()) return local;
    return beforePath;
  }

  String get afterForDisplay {
    final local = (afterLocalPath ?? '').trim();
    if (isRemoteUrl(afterPath)) return afterPath;
    if (local.isNotEmpty && File(local).existsSync()) return local;
    return afterPath;
  }

  String get scoreLabel => '$beforeScore → $afterScore';

  bool get hasFullSnapshot {
    final snap = snapshotData;
    if (snap == null || snap.isEmpty) return false;
    final zones = snap['zones'];
    final metrics = snap['metrics'];
    final procedures = snap['procedures'];
    return zones is List && zones.isNotEmpty ||
        metrics is List && metrics.isNotEmpty ||
        procedures is List && procedures.isNotEmpty;
  }

  TransformationHistoryEntry copyWith({
    String? beforePath,
    String? afterPath,
    String? beforeLocalPath,
    String? afterLocalPath,
    DateTime? beforeDate,
    DateTime? afterDate,
    int? beforeScore,
    int? afterScore,
    DateTime? createdAt,
    Map<String, dynamic>? snapshotData,
  }) {
    return TransformationHistoryEntry(
      id: id,
      beforePath: beforePath ?? this.beforePath,
      afterPath: afterPath ?? this.afterPath,
      beforeLocalPath: beforeLocalPath ?? this.beforeLocalPath,
      afterLocalPath: afterLocalPath ?? this.afterLocalPath,
      beforeDate: beforeDate ?? this.beforeDate,
      afterDate: afterDate ?? this.afterDate,
      beforeScore: beforeScore ?? this.beforeScore,
      afterScore: afterScore ?? this.afterScore,
      createdAt: createdAt ?? this.createdAt,
      snapshotData: snapshotData ?? this.snapshotData,
    );
  }

  static Map<String, dynamic>? coerceSnapshotMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'beforePath': beforePath,
        'afterPath': afterPath,
        'beforeLocalPath': beforeLocalPath,
        'afterLocalPath': afterLocalPath,
        if (beforeDate != null) 'beforeDate': beforeDate!.toUtc().toIso8601String(),
        if (afterDate != null) 'afterDate': afterDate!.toUtc().toIso8601String(),
        'beforeScore': beforeScore,
        'afterScore': afterScore,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (snapshotData != null) 'snapshot': snapshotData,
      };

  factory TransformationHistoryEntry.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(String? raw) =>
        raw == null ? null : DateTime.tryParse(raw)?.toLocal();

    return TransformationHistoryEntry(
      id: json['id'] as String? ?? const Uuid().v4(),
      beforePath: json['beforePath'] as String? ?? '',
      afterPath: json['afterPath'] as String? ?? '',
      beforeLocalPath: json['beforeLocalPath'] as String?,
      afterLocalPath: json['afterLocalPath'] as String?,
      beforeDate: parseDate(json['beforeDate'] as String?),
      afterDate: parseDate(json['afterDate'] as String?),
      beforeScore: (json['beforeScore'] as num?)?.round() ?? 0,
      afterScore: (json['afterScore'] as num?)?.round() ?? 0,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      snapshotData: coerceSnapshotMap(json['snapshot']),
    );
  }
}

/// Local cache + Firestore under `users/{uid}/transformation_history/{id}`.
class TransformationHistoryStore {
  static const _key = 'transformation_history_v1';
  static const _maxEntries = 5;

  /// Firestore subcollection: `users/{uid}/transformation_history`.
  static const firestoreCollection = 'transformation_history';

  static FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  static FirebaseAuth get _auth => FirebaseAuth.instance;

  static String? get _uid => _auth.currentUser?.uid;

  static CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _firestore.collection('users').doc(uid).collection(firestoreCollection);

  static Map<String, dynamic> _toFirestore(TransformationHistoryEntry entry) => {
        'id': entry.id,
        'beforePath': entry.beforePath,
        'afterPath': entry.afterPath,
        'createdAt': Timestamp.fromDate(entry.createdAt.toUtc()),
        'beforeScore': entry.beforeScore,
        'afterScore': entry.afterScore,
        if (entry.beforeDate != null)
          'beforeDate': Timestamp.fromDate(entry.beforeDate!.toUtc()),
        if (entry.afterDate != null)
          'afterDate': Timestamp.fromDate(entry.afterDate!.toUtc()),
        if (entry.snapshotData != null) 'snapshot': entry.snapshotData,
      };

  static TransformationHistoryEntry? _fromFirestoreDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    if (data == null) return null;
    try {
      final m = Map<String, dynamic>.from(data);
      m['id'] = doc.id;
      for (final key in ['createdAt', 'beforeDate', 'afterDate']) {
        final v = data[key];
        if (v is Timestamp) {
          m[key] = v.toDate().toUtc().toIso8601String();
        }
      }
      return TransformationHistoryEntry.fromJson(m);
    } catch (e) {
      debugPrint('[TransformationHistory] firestore parse error: $e');
      return null;
    }
  }

  static Future<List<TransformationHistoryEntry>> _listFromFirestore(String uid) async {
    final snap = await _col(uid)
        .orderBy('createdAt', descending: true)
        .limit(_maxEntries)
        .get();
    return [
      for (final d in snap.docs)
        if (_fromFirestoreDoc(d) case final e?) e,
    ];
  }

  static TransformationHistoryEntry _preferSnapshot(
    TransformationHistoryEntry remoteEntry,
    TransformationHistoryEntry? cached,
  ) {
    if (remoteEntry.hasFullSnapshot || cached == null || !cached.hasFullSnapshot) {
      return remoteEntry;
    }
    return remoteEntry.copyWith(snapshotData: cached.snapshotData);
  }

  static List<TransformationHistoryEntry> _mergeWithLocalSnapshots(
    List<TransformationHistoryEntry> remote,
    List<TransformationHistoryEntry> local,
  ) {
    final localById = {for (final e in local) e.id: e};
    return [
      for (final remoteEntry in remote)
        _preferSnapshot(remoteEntry, localById[remoteEntry.id]),
    ];
  }

  static Future<List<TransformationHistoryEntry>> _listLocal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final items = [
        for (final item in decoded)
          if (item is Map<String, dynamic>) TransformationHistoryEntry.fromJson(item),
      ];
      if (items.length <= _maxEntries) return items;
      return items.sublist(0, _maxEntries);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _saveLocal(List<TransformationHistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<TransformationHistoryEntry>> list() async {
    final local = await _listLocal();
    final uid = _uid;
    if (uid != null) {
      try {
        final remote = await _listFromFirestore(uid);
        if (remote.isNotEmpty) {
          final merged = _mergeWithLocalSnapshots(remote, local);
          await _saveLocal(merged);
          return merged;
        }
      } catch (e) {
        debugPrint('[TransformationHistory] firestore list error: $e');
      }
    }
    return local;
  }

  static Future<TransformationHistoryEntry> createEntry({
    required String beforeSource,
    required String afterSource,
    DateTime? beforeDate,
    DateTime? afterDate,
    required int beforeScore,
    required int afterScore,
    DateTime? createdAt,
    Map<String, dynamic>? snapshotData,
  }) async {
    final id = const Uuid().v4();
    GlowHistoryImagePaths paths;
    try {
      paths = await persistGlowHistoryImages(
        entryId: id,
        beforeSource: beforeSource,
        afterSource: afterSource,
      );
    } catch (e, st) {
      debugPrint('[TransformationHistory] archive failed: $e\n$st');
      paths = GlowHistoryImagePaths(
        beforeDisplayPath: beforeSource,
        afterDisplayPath: afterSource,
        beforeLocalPath: beforeSource,
        afterLocalPath: afterSource,
      );
    }

    return TransformationHistoryEntry(
      id: id,
      beforePath: paths.beforeDisplayPath,
      afterPath: paths.afterDisplayPath ?? afterSource,
      beforeLocalPath: paths.beforeLocalPath,
      afterLocalPath: paths.afterLocalPath,
      beforeDate: beforeDate,
      afterDate: afterDate,
      beforeScore: beforeScore,
      afterScore: afterScore,
      createdAt: createdAt ?? DateTime.now(),
      snapshotData: snapshotData,
    );
  }

  static Future<void> _deleteFromFirestore(String uid, String entryId) async {
    try {
      await _col(uid).doc(entryId).delete();
    } catch (e) {
      debugPrint('[TransformationHistory] firestore delete error ($entryId): $e');
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
      debugPrint('[TransformationHistory] firestore trim error: $e');
    }
  }

  static Future<void> _syncToFirestore(TransformationHistoryEntry entry) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _col(uid).doc(entry.id).set(_toFirestore(entry));
      await _trimFirestore(uid);
    } catch (e) {
      debugPrint('[TransformationHistory] firestore sync error: $e');
    }
  }

  static Future<void> add(TransformationHistoryEntry entry) async {
    if (entry.beforePath.trim().isEmpty && (entry.beforeLocalPath ?? '').trim().isEmpty) {
      return;
    }
    if (entry.afterPath.trim().isEmpty && (entry.afterLocalPath ?? '').trim().isEmpty) {
      return;
    }

    final existing = await _listLocal();

    final dupeIndex = existing.indexWhere(
      (e) =>
          e.id == entry.id ||
          (e.beforePath == entry.beforePath &&
              e.afterPath == entry.afterPath &&
              entry.createdAt.difference(e.createdAt).inSeconds.abs() < 60),
    );
    if (dupeIndex >= 0) {
      final previous = existing[dupeIndex];
      if (entry.hasFullSnapshot && !previous.hasFullSnapshot) {
        final next = [...existing];
        next[dupeIndex] = entry;
        final trimmed = next.length > _maxEntries ? next.sublist(0, _maxEntries) : next;
        final dropped = next.length > _maxEntries
            ? next.sublist(_maxEntries)
            : const <TransformationHistoryEntry>[];
        await _saveLocal(trimmed);
        final uid = _uid;
        if (uid != null) {
          await _syncToFirestore(entry);
          for (final old in dropped) {
            await _deleteFromFirestore(uid, old.id);
          }
        }
      }
      return;
    }

    final next = [entry, ...existing];
    final trimmed = next.length > _maxEntries ? next.sublist(0, _maxEntries) : next;
    final dropped =
        next.length > _maxEntries ? next.sublist(_maxEntries) : const <TransformationHistoryEntry>[];

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
