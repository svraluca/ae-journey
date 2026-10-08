import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'checkpoint.dart';
import 'community_post.dart';
import 'procedure.dart';

/// Persisted under `users/{uid}/procedure_done` and `users/{uid}/procedure_reminder`.
///
/// Live community cards are mirrored to top-level `community_posts` when tagged
/// `community_live`, so the Glow Up community can show them across users.
class ProcedureRepository extends ChangeNotifier {
  ProcedureRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance {
    _authSub = _auth.authStateChanges().listen(_onAuthChanged);
    _onAuthChanged(_auth.currentUser);
  }

  static const doneCollection = 'procedure_done';
  static const reminderCollection = 'procedure_reminder';
  static const checkpointsCollection = 'checkpoints';
  static const communityPostsCollection = 'community_posts';
  static const liveTag = 'community_live';

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _doneSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _reminderSub;

  String? _attachedUid;

  final Map<String, Procedure> _doneById = {};
  final Map<String, Procedure> _reminderById = {};

  CollectionReference<Map<String, dynamic>> _doneCol(String uid) =>
      _firestore.collection('users').doc(uid).collection(doneCollection);

  CollectionReference<Map<String, dynamic>> _reminderCol(String uid) =>
      _firestore.collection('users').doc(uid).collection(reminderCollection);

  CollectionReference<Map<String, dynamic>> _checkpointCol(String uid, String procedureId) =>
      _firestore.collection('users').doc(uid).collection(doneCollection).doc(procedureId).collection(checkpointsCollection);

  CollectionReference<Map<String, dynamic>> get _communityCol =>
      _firestore.collection(communityPostsCollection);

  static String communityPostDocId(String uid, String procedureId) => '${uid}_$procedureId';

  static bool _isRemoteUrl(String? path) {
    final p = (path ?? '').trim();
    return p.startsWith('http://') || p.startsWith('https://');
  }

  static String? _remoteOrNull(String? path) {
    final p = (path ?? '').trim();
    if (!_isRemoteUrl(p)) return null;
    return p;
  }

  void _onAuthChanged(User? user) {
    final uid = user?.uid;
    if (uid == _attachedUid && _doneSub != null && _reminderSub != null) return;
    _attachedUid = uid;

    _doneSub?.cancel();
    _reminderSub?.cancel();
    _doneSub = null;
    _reminderSub = null;
    _doneById.clear();
    _reminderById.clear();
    notifyListeners();

    if (uid == null) return;

    _doneSub = _doneCol(uid).snapshots().listen(
          _applyDoneSnap,
          onError: (_) => notifyListeners(),
        );
    _reminderSub = _reminderCol(uid).snapshots().listen(
          _applyReminderSnap,
          onError: (_) => notifyListeners(),
        );
  }

  static Map<String, dynamic> _normalizeDocMap(Map<String, dynamic> raw) {
    String? coerceDate(dynamic v) {
      if (v == null) return null;
      if (v is Timestamp) return v.toDate().toIso8601String();
      if (v is String && v.isNotEmpty) return v;
      return null;
    }

    final m = Map<String, dynamic>.from(raw);
    for (final k in ['date', 'createdAt', 'updatedAt', 'followUpDate']) {
      final c = coerceDate(m[k]);
      if (c != null) {
        m[k] = c;
      } else if (k != 'followUpDate' && m[k] != null && m[k] is! String) {
        m.remove(k);
      }
    }
    return m;
  }

  static Checkpoint? checkpointFromFirestoreDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    try {
      final m = _normalizeDocMap(data);
      m['id'] = d.id;
      return Checkpoint.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  static Procedure? procedureFromFirestoreDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data();
    if (data == null) return null;
    try {
      final m = _normalizeDocMap(data);
      m['id'] = d.id;
      return Procedure.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  void _applyDoneSnap(QuerySnapshot<Map<String, dynamic>> snap) {
    _doneById.clear();
    for (final d in snap.docs) {
      final p = procedureFromFirestoreDoc(d);
      if (p != null) _doneById[p.id] = p;
    }
    notifyListeners();
  }

  void _applyReminderSnap(QuerySnapshot<Map<String, dynamic>> snap) {
    _reminderById.clear();
    for (final d in snap.docs) {
      final p = procedureFromFirestoreDoc(d);
      if (p != null) _reminderById[p.id] = p;
    }
    notifyListeners();
  }

  /// Passport / timeline: procedures completed via [ProcedureFormScreen].
  Iterable<Procedure> allDone() => _doneById.values;

  /// My reminders: rows from [AddReminderScreen].
  Iterable<Procedure> allReminders() => _reminderById.values;

  /// Alias for callers that historically meant “passport procedures” only.
  Iterable<Procedure> all() => allDone();

  Procedure? getDoneById(String id) => _doneById[id];
  Procedure? getReminderById(String id) => _reminderById[id];

  Procedure? getById(String id) => _doneById[id] ?? _reminderById[id];

  Future<void> upsertDone(Procedure procedure) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Must be signed in to save procedures');
    await _doneCol(uid).doc(procedure.id).set(procedure.toMap(), SetOptions(merge: true));
    await _syncCommunityPost(uid, procedure);
  }

  Future<void> upsertReminder(Procedure procedure) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Must be signed in to save reminders');
    await _reminderCol(uid).doc(procedure.id).set(procedure.toMap(), SetOptions(merge: true));
  }

  Future<void> deleteDone(String id) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _doneCol(uid).doc(id).delete();
    try {
      await _communityCol.doc(communityPostDocId(uid, id)).delete();
    } catch (e) {
      debugPrint('[Community] delete mirror failed: $e');
    }
  }

  /// Public live feed for Glow Up results community.
  Stream<List<CommunityPost>> communityPostsStream({int limit = 60}) {
    return _communityCol
        .orderBy('postedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) {
      final out = <CommunityPost>[];
      for (final d in snap.docs) {
        final post = CommunityPost.fromMap(d.data(), docId: d.id);
        if (post != null) out.add(post);
      }
      return out;
    });
  }

  Future<void> _syncCommunityPost(String uid, Procedure procedure) async {
    final ref = _communityCol.doc(communityPostDocId(uid, procedure.id));
    final isLive = procedure.tags.contains(liveTag);
    if (!isLive) {
      try {
        await ref.delete();
      } catch (_) {}
      return;
    }

    final existing = await ref.get();
    final existingPostedAt = existing.data()?['postedAt'];
    final postedAt = existingPostedAt is String && existingPostedAt.isNotEmpty
        ? (DateTime.tryParse(existingPostedAt) ?? DateTime.now())
        : DateTime.now();

    final display = (_auth.currentUser?.displayName ?? '').trim();
    final post = CommunityPost(
      id: ref.id,
      ownerUid: uid,
      procedureId: procedure.id,
      title: procedure.title,
      date: procedure.date,
      postedAt: postedAt,
      category: procedure.category,
      clinic: procedure.clinic,
      practitioner: procedure.practitioner,
      product: procedure.product,
      volumeMl: procedure.volumeMl,
      zones: procedure.zones,
      beforePhotoUrl: _remoteOrNull(procedure.beforePhotoPath),
      afterPhotoUrl: _remoteOrNull(procedure.afterPhotoPath),
      ownerDisplayName: display.isEmpty ? null : display,
    );

    try {
      await ref.set(post.toMap(), SetOptions(merge: true));
    } catch (e) {
      debugPrint('[Community] mirror failed: $e');
    }
  }

  Future<void> deleteReminder(String id) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _reminderCol(uid).doc(id).delete();
  }

  /// Checkpoints are stored under `users/{uid}/procedure_done/{procedureId}/checkpoints/{checkpointId}`.
  Stream<List<Checkpoint>> checkpointsStream(String procedureId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream<List<Checkpoint>>.empty();
    return _checkpointCol(uid, procedureId).snapshots().map((snap) {
      final out = <Checkpoint>[];
      for (final d in snap.docs) {
        final c = checkpointFromFirestoreDoc(d);
        if (c != null) out.add(c);
      }
      out.sort((a, b) => a.date.compareTo(b.date));
      return out;
    });
  }

  Future<void> upsertCheckpoint(String procedureId, Checkpoint checkpoint) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw StateError('Must be signed in to save checkpoints');
    await _checkpointCol(uid, procedureId).doc(checkpoint.id).set(checkpoint.toMap(), SetOptions(merge: true));
  }

  Future<void> deleteCheckpoint(String procedureId, String checkpointId) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    await _checkpointCol(uid, procedureId).doc(checkpointId).delete();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _doneSub?.cancel();
    _reminderSub?.cancel();
    super.dispose();
  }
}
