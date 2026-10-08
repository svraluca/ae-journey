import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class NotificationsStore {
  NotificationsStore._();

  static CollectionReference<Map<String, dynamic>> _col() =>
      FirebaseFirestore.instance.collection('notifications');

  static String? _uid() => FirebaseAuth.instance.currentUser?.uid;

  static Query<Map<String, dynamic>> streamForCurrentUser() {
    final uid = _uid();
    if (uid == null) {
      // Empty query (never matches) to keep UI simple.
      return _col().where('recipientId', isEqualTo: '__none__');
    }
    // Single-field filter only — avoids composite index requirement.
    // Sort newest-first on the client in [streamDocsForCurrentUser].
    return _col().where('recipientId', isEqualTo: uid);
  }

  /// Live notification docs for the signed-in user, newest first.
  static Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      streamDocsForCurrentUser() {
    return streamForCurrentUser().snapshots().map((snap) {
      final docs = snap.docs.toList()
        ..sort((a, b) {
          final ta = a.data()['timestamp'];
          final tb = b.data()['timestamp'];
          if (ta is! Timestamp && tb is! Timestamp) return 0;
          if (ta is! Timestamp) return 1;
          if (tb is! Timestamp) return -1;
          return tb.compareTo(ta);
        });
      return docs;
    });
  }

  /// Saves an in-app notification (shows in Notifications tab).
  /// Set [pushSent] true when a local/FCM push was already shown.
  static Future<void> recordInApp({
    required String title,
    required String body,
    String type = 'general',
    bool pushSent = true,
  }) async {
    final uid = _uid();
    if (uid == null) return;
    await _col().add({
      'recipientId': uid,
      'type': type,
      'title': title,
      'body': body,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
      'pushSent': pushSent,
    });
  }

  static Future<int> unreadCount() async {
    final uid = _uid();
    if (uid == null) return 0;
    final snap = await _col().where('recipientId', isEqualTo: uid).get();
    return snap.docs.where((d) => d.data()['isRead'] != true).length;
  }

  /// Immediate test push (Cloud Function sends on create).
  static Future<void> sendTestPushNow() async {
    final uid = _uid();
    if (uid == null) return;
    await _col().add({
      'recipientId': uid,
      'type': 'test',
      'title': 'ÆSTHETIC JOURNEY test',
      'body': 'If you see this, push is working.',
      'timestamp': FieldValue.serverTimestamp(),
      'pushSent': false,
      'isRead': false,
    });
  }

  /// Schedules a push via Cloud Functions (writes `notifications` + FCM).
  static Future<void> schedulePush({
    required String title,
    required String body,
    required DateTime deliverAt,
    String type = 'procedure_reminder',
  }) async {
    final uid = _uid();
    if (uid == null) return;
    await _col().add({
      'recipientId': uid,
      'type': type,
      'title': title,
      'body': body,
      'timestamp': FieldValue.serverTimestamp(),
      'deliverAt': Timestamp.fromDate(deliverAt),
      'pushSent': false,
      'isRead': false,
    });
  }

  static Future<void> markAsRead(String docId) async {
    final uid = _uid();
    if (uid == null || docId.isEmpty) return;
    final ref = _col().doc(docId);
    final snap = await ref.get();
    if (!snap.exists) return;
    if (snap.data()?['recipientId'] != uid) return;
    if (snap.data()?['isRead'] == true) return;
    await ref.update({'isRead': true});
  }

  static Future<void> markAllRead() async {
    final uid = _uid();
    if (uid == null) return;
    final all = await _col().where('recipientId', isEqualTo: uid).get();
    final unread = all.docs.where((d) => d.data()['isRead'] != true);
    if (unread.isEmpty) return;

    final batch = FirebaseFirestore.instance.batch();
    for (final d in unread) {
      batch.update(d.reference, {'isRead': true});
    }
    await batch.commit();
  }
}

