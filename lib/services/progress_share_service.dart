import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../data/procedure.dart';
import '../ui/community_glow_up_viewer_screen.dart';

/// Creates a public share snapshot and opens the system share sheet
/// (WhatsApp, Messages, etc.).
class ProgressShareService {
  ProgressShareService._();
  static final ProgressShareService instance = ProgressShareService._();

  static const collection = 'shared_progress';

  /// Public Firebase Hosting fallback (legacy).
  static const hostingHost = 'https://ae-glowup.web.app';

  /// Local preview: `python3 share-web/server.py` then `--dart-define=SHARE_LOCAL=true`.
  static const localHost = 'http://localhost:1111';

  /// Custom domain — primary share link host.
  static const customHost = 'https://ae-journey.com';

  static const scheme = 'aeglowup';
  static const legacyScheme = 'glowpass';
  static const legacySchemeAepass = 'aepass';

  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  /// Shared links must be reachable on other devices — use the custom domain.
  String get httpsHost {
    const useLocal = bool.fromEnvironment('SHARE_LOCAL', defaultValue: false);
    if (useLocal) return localHost;
    return customHost;
  }

  String shareUrlFor(String shareId) => '$httpsHost/share/$shareId';

  String deepLinkFor(String shareId) => '$scheme://share/$shareId';

  Future<String> createShare({
    required Procedure procedure,
    String? areaFallback,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Sign in to share your progress.');
    }

    final shareId = const Uuid().v4().replaceAll('-', '').substring(0, 16);
    final area = procedure.zones.isNotEmpty
        ? procedure.zones.first
        : (areaFallback ?? (procedure.category ?? 'Procedure'));
    final daysAgo = DateTime.now().difference(procedure.date).inDays.clamp(0, 9999);
    final duration = _durationLabel(daysAgo);

    await _db.collection(collection).doc(shareId).set({
      'id': shareId,
      'ownerUid': uid,
      'procedureId': procedure.id,
      'procedure': procedure.title,
      'area': area,
      'duration': duration,
      'daysAgo': daysAgo,
      'userName': _auth.currentUser?.displayName?.trim().isNotEmpty == true
          ? _auth.currentUser!.displayName!.trim()
          : 'ÆSTHETIC JOURNEY member',
      'iconAsset': 'assets/staricon.png',
      'clinic': procedure.clinic,
      'doctor': procedure.practitioner,
      'product': procedure.product,
      'volumeMl': procedure.volumeMl,
      'beforePhotoPath': procedure.beforePhotoPath,
      'afterPhotoPath': procedure.afterPhotoPath,
      'createdAt': FieldValue.serverTimestamp(),
    });

    return shareId;
  }

  Future<void> shareProcedure({
    required Procedure procedure,
    String? areaFallback,
    Rect? sharePositionOrigin,
  }) async {
    final shareId = await createShare(
      procedure: procedure,
      areaFallback: areaFallback,
    );
    final url = shareUrlFor(shareId);
    final title = procedure.title.trim().isEmpty ? 'my Glow Up' : procedure.title.trim();

    await _openShareSheet(
      text: url,
      subject: 'My $title progress',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<void> shareCommunityView(
    CommunityGlowUpView post, {
    Rect? sharePositionOrigin,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Sign in to share this progress.');
    }
    final shareId = const Uuid().v4().replaceAll('-', '').substring(0, 16);

    await _db.collection(collection).doc(shareId).set({
      'id': shareId,
      'ownerUid': uid,
      'procedure': post.procedure,
      'area': post.area,
      'duration': post.duration,
      'daysAgo': post.daysAgo,
      'userName': post.userName,
      'iconAsset': post.iconAsset,
      'clinic': post.clinic,
      'doctor': post.doctor,
      'product': post.product,
      'volumeMl': post.volumeMl,
      'beforePhotoPath': post.beforePhotoUrl,
      'afterPhotoPath': post.afterPhotoUrl,
      'createdAt': FieldValue.serverTimestamp(),
    });

    final url = shareUrlFor(shareId);
    final title = post.procedure.trim().isEmpty ? 'Glow Up' : post.procedure.trim();

    await _openShareSheet(
      text: url,
      subject: '$title on ÆSTHETIC JOURNEY',
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  Future<void> _openShareSheet({
    required String text,
    required String subject,
    Rect? sharePositionOrigin,
  }) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: subject,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
    } catch (e, st) {
      debugPrint('[ProgressShare] sheet failed: $e\n$st');
      rethrow;
    }
  }

  /// Prefer a real button rect on iPad / iOS share popover.
  static Rect? originFromContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<CommunityGlowUpView?> loadShare(String shareId) async {
    final id = shareId.trim();
    if (id.isEmpty) return null;
    try {
      final snap = await _db.collection(collection).doc(id).get();
      if (!snap.exists) return null;
      final d = snap.data() ?? {};
      return CommunityGlowUpView(
        procedure: (d['procedure'] as String?)?.trim().isNotEmpty == true
            ? (d['procedure'] as String).trim()
            : 'Procedure',
        area: (d['area'] as String?)?.trim().isNotEmpty == true
            ? (d['area'] as String).trim()
            : '—',
        duration: (d['duration'] as String?)?.trim().isNotEmpty == true
            ? (d['duration'] as String).trim()
            : 'Recently',
        daysAgo: (d['daysAgo'] as num?)?.toInt() ?? 0,
        userName: (d['userName'] as String?)?.trim() ?? '',
        iconAsset: (d['iconAsset'] as String?)?.trim().isNotEmpty == true
            ? (d['iconAsset'] as String).trim()
            : 'assets/staricon.png',
        clinic: (d['clinic'] as String?)?.trim(),
        doctor: (d['doctor'] as String?)?.trim(),
        product: (d['product'] as String?)?.trim(),
        volumeMl: (d['volumeMl'] as num?)?.toDouble(),
        beforePhotoUrl: (d['beforePhotoPath'] as String?)?.trim(),
        afterPhotoUrl: (d['afterPhotoPath'] as String?)?.trim(),
      );
    } catch (e) {
      debugPrint('[ProgressShare] load failed: $e');
      return null;
    }
  }

  static String? parseShareId(Uri uri) {
    // aeglowup://share/{id} (+ legacy aepass:// / glowpass://)
    if (uri.scheme == scheme ||
        uri.scheme == legacyScheme ||
        uri.scheme == legacySchemeAepass) {
      if (uri.host == 'share' && uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.first;
      }
      if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'share') {
        return uri.pathSegments[1];
      }
    }
    // https://ae-journey.com/share/{id} (+ legacy hosts)
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments[0] == 'share') {
      final host = uri.host.toLowerCase();
      if (host == 'ae-journey.com' ||
          host == 'www.ae-journey.com' ||
          host.contains('ae-glowup') ||
          host.contains('ae-pass') ||
          host.contains('glowpass') ||
          host.contains('glowup-pass') ||
          host.contains('aestheticpass') ||
          host.contains('firebaseapp') ||
          host.contains('web.app') ||
          host == 'localhost' ||
          host == '127.0.0.1') {
        return uri.pathSegments[1];
      }
    }
    return null;
  }

  String _durationLabel(int daysAgo) {
    if (daysAgo <= 0) return 'Today';
    if (daysAgo == 1) return '1 day ago';
    if (daysAgo < 7) return '$daysAgo days ago';
    if (daysAgo < 14) return '1 week ago';
    if (daysAgo < 30) return '${daysAgo ~/ 7} weeks ago';
    if (daysAgo < 60) return '1 month ago';
    if (daysAgo < 365) return '${daysAgo ~/ 30} months ago';
    return '${daysAgo ~/ 365} year${daysAgo >= 730 ? 's' : ''} ago';
  }
}
