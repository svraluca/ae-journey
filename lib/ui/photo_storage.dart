import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

bool isRemoteUrl(String? path) {
  final p = (path ?? '').trim();
  return p.startsWith('http://') || p.startsWith('https://');
}

/// Resolves [path] to a readable local file (downloads remote URLs to cache).
Future<String> resolveLocalPhotoPath(String path) async {
  final p = path.trim();
  if (p.isEmpty) return p;
  if (!isRemoteUrl(p)) {
    if (await File(p).exists()) return p;
    return p;
  }
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(p));
    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    final bytes = await consolidateHttpClientResponseBytes(res);
    client.close(force: true);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/photos/cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    final out = File('${dir.path}/dl_${const Uuid().v4()}.jpg');
    await out.writeAsBytes(bytes, flush: true);
    debugPrint('[PhotoStorage] cached remote photo → ${out.path}');
    return out.path;
  } catch (e) {
    debugPrint('[PhotoStorage] remote download failed: $e');
    rethrow;
  }
}

Future<String> persistPhotoPath(String sourcePath) async {
  final src = File(sourcePath);
  if (!await src.exists()) return sourcePath;

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

  final dot = sourcePath.lastIndexOf('.');
  final ext = (dot >= 0 && dot > sourcePath.lastIndexOf(Platform.pathSeparator)) ? sourcePath.substring(dot) : '.jpg';
  final name = 'photo_${const Uuid().v4()}$ext';
  final dest = File('${dir.path}/$name');

  await src.copy(dest.path);
  return dest.path;
}

/// Writes image bytes into app documents `photos/` and returns the local path.
Future<String> persistPhotoBytes(
  List<int> bytes, {
  String fileName = '',
}) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/photos');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final name = fileName.trim().isEmpty ? 'photo_${const Uuid().v4()}.jpg' : fileName.trim();
  final dest = File('${dir.path}/$name');
  await dest.writeAsBytes(bytes, flush: true);
  return dest.path;
}

/// Copies the file into app documents and uploads to Firebase Storage (if signed in).
///
/// Returns a Storage download URL when upload succeeds, otherwise returns the local persisted path.
Future<String> persistAndUploadPhotoPath(
  String sourcePath, {
  FirebaseAuth? auth,
  FirebaseStorage? storage,
}) async {
  final local = await persistPhotoPath(sourcePath);

  final user = (auth ?? FirebaseAuth.instance).currentUser;
  if (user == null) return local;

  try {
    final file = File(local);
    if (!await file.exists()) return local;

    final uid = user.uid;
    final dot = local.lastIndexOf('.');
    final ext = (dot >= 0 && dot > local.lastIndexOf(Platform.pathSeparator)) ? local.substring(dot) : '.jpg';
    final key = const Uuid().v4();
    final bucketPath = 'users/$uid/photos/$key$ext';
    final ref = (storage ?? FirebaseStorage.instance).ref().child(bucketPath);
    // Read into memory + putData instead of putFile. putFile uses the
    // resumable-upload protocol which the iOS Simulator's network stack
    // mangles, surfacing as `Unexpected -1017 code from backend`. putData
    // sends a single multipart request and is reliable on Simulator + device.
    final bytes = await file.readAsBytes();
    debugPrint(
      '[Storage] uploading ${bytes.length} bytes → gs://${ref.bucket}/$bucketPath',
    );
    await ref.putData(
      bytes,
      SettableMetadata(contentType: _contentTypeFor(ext)),
    );
    final url = await ref.getDownloadURL();
    debugPrint('[Storage] upload OK → $url');
    return url;
  } on FirebaseException catch (e) {
    // The whole pipeline silently falls back to a local path on failure;
    // print loudly enough that the developer notices in the console.
    debugPrint(
      '[Storage] UPLOAD FAILED — code=${e.code} plugin=${e.plugin} '
      'message=${e.message ?? ''}',
    );
    if (e.code == 'unauthorized' || e.code == 'storage/unauthorized') {
      debugPrint(
        '[Storage] Hint: deploy storage.rules with '
        '`firebase deploy --only storage` (rules file at repo root).',
      );
    }
    return local;
  } catch (e) {
    debugPrint('[Storage] upload failed (non-Firebase): $e');
    return local;
  }
}

/// Stable Firebase Storage path for the signed-in user's profile avatar.
String profilePhotoStoragePath(String uid) => 'users/$uid/profile/avatar.jpg';

/// Uploads [sourcePath] to Firebase Storage at `users/{uid}/profile/avatar.jpg`
/// and returns the download URL. Throws if the user is signed out or upload fails.
Future<String> uploadProfilePhotoPath(
  String sourcePath, {
  FirebaseAuth? auth,
  FirebaseStorage? storage,
}) async {
  final user = (auth ?? FirebaseAuth.instance).currentUser;
  if (user == null) {
    throw StateError('Must be signed in to upload a profile photo');
  }

  final local = await persistPhotoPath(sourcePath);
  final file = File(local);
  if (!await file.exists()) {
    throw StateError('Profile photo file missing after save');
  }

  final bucketPath = profilePhotoStoragePath(user.uid);
  final ref = (storage ?? FirebaseStorage.instance).ref().child(bucketPath);
  final bytes = await file.readAsBytes();
  debugPrint(
    '[Storage] profile photo uploading ${bytes.length} bytes → gs://${ref.bucket}/$bucketPath',
  );

  await ref.putData(
    bytes,
    SettableMetadata(
      contentType: 'image/jpeg',
      cacheControl: 'public,max-age=3600',
    ),
  );
  final url = await ref.getDownloadURL();
  // Cache-bust so UI refreshes when the same storage path is overwritten.
  final stamped = url.contains('?') ? '$url&v=${DateTime.now().millisecondsSinceEpoch}' : '$url?v=${DateTime.now().millisecondsSinceEpoch}';
  debugPrint('[Storage] profile photo upload OK → $stamped');
  return stamped;
}

/// Deletes the profile avatar object from Firebase Storage (best-effort).
Future<void> deleteProfilePhotoFromStorage({
  FirebaseAuth? auth,
  FirebaseStorage? storage,
}) async {
  final user = (auth ?? FirebaseAuth.instance).currentUser;
  if (user == null) return;
  try {
    final ref = (storage ?? FirebaseStorage.instance).ref().child(profilePhotoStoragePath(user.uid));
    await ref.delete();
    debugPrint('[Storage] profile photo deleted');
  } on FirebaseException catch (e) {
    if (e.code == 'object-not-found') return;
    debugPrint('[Storage] profile photo delete failed: ${e.code} ${e.message}');
  } catch (e) {
    debugPrint('[Storage] profile photo delete failed: $e');
  }
}

/// Stable paths for a saved Glow Up history entry (local + optional Firebase URL).
class GlowHistoryImagePaths {
  const GlowHistoryImagePaths({
    required this.beforeDisplayPath,
    this.afterDisplayPath,
    required this.beforeLocalPath,
    this.afterLocalPath,
    this.sliderBeforeDisplayPath,
    this.sliderAfterDisplayPath,
    this.sliderBeforeLocalPath,
    this.sliderAfterLocalPath,
  });

  /// URL when uploaded, otherwise local archive path.
  final String beforeDisplayPath;
  final String? afterDisplayPath;
  final String beforeLocalPath;
  final String? afterLocalPath;
  final String? sliderBeforeDisplayPath;
  final String? sliderAfterDisplayPath;
  final String? sliderBeforeLocalPath;
  final String? sliderAfterLocalPath;
}

/// Copies before/after into `glow_history/{entryId}/` and uploads when signed in.
Future<GlowHistoryImagePaths> persistGlowHistoryImages({
  required String entryId,
  required String beforeSource,
  String? afterSource,
  String? sliderBeforeSource,
  String? sliderAfterSource,
  FirebaseAuth? auth,
  FirebaseStorage? storage,
}) async {
  final beforeLocal = await _archiveGlowHistoryFile(
    entryId: entryId,
    fileName: 'before.jpg',
    sourcePath: beforeSource,
  );
  String? afterLocal;
  if (afterSource != null && afterSource.trim().isNotEmpty) {
    afterLocal = await _archiveGlowHistoryFile(
      entryId: entryId,
      fileName: 'after.jpg',
      sourcePath: afterSource,
    );
  }

  String? sliderBeforeLocal;
  if (sliderBeforeSource != null && sliderBeforeSource.trim().isNotEmpty) {
    sliderBeforeLocal = await _archiveGlowHistoryFile(
      entryId: entryId,
      fileName: 'slider_before.jpg',
      sourcePath: sliderBeforeSource,
    );
  }
  String? sliderAfterLocal;
  if (sliderAfterSource != null && sliderAfterSource.trim().isNotEmpty) {
    sliderAfterLocal = await _archiveGlowHistoryFile(
      entryId: entryId,
      fileName: 'slider_after.jpg',
      sourcePath: sliderAfterSource,
    );
  }

  final beforeRemote = await _uploadGlowHistoryFile(
    localPath: beforeLocal,
    entryId: entryId,
    fileName: 'before.jpg',
    auth: auth,
    storage: storage,
  );
  final afterRemote = afterLocal != null
      ? await _uploadGlowHistoryFile(
          localPath: afterLocal,
          entryId: entryId,
          fileName: 'after.jpg',
          auth: auth,
          storage: storage,
        )
      : null;
  final sliderBeforeRemote = sliderBeforeLocal != null
      ? await _uploadGlowHistoryFile(
          localPath: sliderBeforeLocal,
          entryId: entryId,
          fileName: 'slider_before.jpg',
          auth: auth,
          storage: storage,
        )
      : null;
  final sliderAfterRemote = sliderAfterLocal != null
      ? await _uploadGlowHistoryFile(
          localPath: sliderAfterLocal,
          entryId: entryId,
          fileName: 'slider_after.jpg',
          auth: auth,
          storage: storage,
        )
      : null;

  debugPrint(
    '[Storage] glow history $entryId '
    'before=${beforeRemote != null ? 'cloud' : 'local'} '
    'after=${afterRemote != null ? 'cloud' : (afterLocal != null ? 'local' : 'none')} '
    'slider=${sliderBeforeLocal != null ? 'yes' : 'no'}',
  );

  return GlowHistoryImagePaths(
    beforeDisplayPath: beforeRemote ?? beforeLocal,
    afterDisplayPath: afterRemote ?? afterLocal,
    beforeLocalPath: beforeLocal,
    afterLocalPath: afterLocal,
    sliderBeforeDisplayPath: sliderBeforeRemote ?? sliderBeforeLocal,
    sliderAfterDisplayPath: sliderAfterRemote ?? sliderAfterLocal,
    sliderBeforeLocalPath: sliderBeforeLocal,
    sliderAfterLocalPath: sliderAfterLocal,
  );
}

Future<String> _archiveGlowHistoryFile({
  required String entryId,
  required String fileName,
  required String sourcePath,
}) async {
  var local = sourcePath.trim();
  if (local.isEmpty) {
    throw ArgumentError('Empty source for glow history archive');
  }
  if (isRemoteUrl(local)) {
    local = await resolveLocalPhotoPath(local);
  }
  final src = File(local);
  if (!await src.exists()) {
    throw FileSystemException('History source missing', local);
  }

  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/glow_history/$entryId');
  if (!await dir.exists()) await dir.create(recursive: true);
  final dest = File('${dir.path}/$fileName');
  await src.copy(dest.path);
  return dest.path;
}

Future<String?> _uploadGlowHistoryFile({
  required String localPath,
  required String entryId,
  required String fileName,
  FirebaseAuth? auth,
  FirebaseStorage? storage,
}) async {
  final user = (auth ?? FirebaseAuth.instance).currentUser;
  if (user == null) return null;

  final file = File(localPath);
  if (!await file.exists()) return null;

  try {
    final uid = user.uid;
    final bucketPath = 'users/$uid/glow_history/$entryId/$fileName';
    final ref = (storage ?? FirebaseStorage.instance).ref().child(bucketPath);
    final bytes = await file.readAsBytes();
    debugPrint(
      '[Storage] glow history upload ${bytes.length} bytes → $bucketPath',
    );
    await ref.putData(
      bytes,
      SettableMetadata(contentType: _contentTypeFor('.jpg')),
    );
    final url = await ref.getDownloadURL();
    return url;
  } on FirebaseException catch (e) {
    debugPrint('[Storage] glow history upload failed: ${e.code} ${e.message}');
    return null;
  } catch (e) {
    debugPrint('[Storage] glow history upload failed: $e');
    return null;
  }
}

String _contentTypeFor(String ext) {
  switch (ext.toLowerCase()) {
    case '.png':
      return 'image/png';
    case '.heic':
    case '.heif':
      return 'image/heic';
    case '.webp':
      return 'image/webp';
    case '.gif':
      return 'image/gif';
    default:
      return 'image/jpeg';
  }
}

