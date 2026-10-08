import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Optional Cloud Translation v2 fallback when curated local procedure
/// names are missing. Session memory first, then a small Firestore cache.
///
/// Missing/invalid key → no-op (English + curated names still work).
class ExploreProcedureTranslationStore {
  ExploreProcedureTranslationStore._({http.Client? client})
      : _client = client ?? http.Client();

  static final ExploreProcedureTranslationStore instance =
      ExploreProcedureTranslationStore._();

  static const collection = 'explore_procedure_translations';

  final http.Client _client;
  final Map<String, String> _memory = {};
  final Map<String, Future<String?>> _inFlight = {};
  bool _loggedMissingKey = false;
  bool _loggedHttpError = false;

  static String cacheKey(String canonical, String lang) =>
      '${canonical.trim().toLowerCase()}|${lang.trim().toLowerCase()}';

  static String _docId(String canonical, String lang) {
    final raw = cacheKey(canonical, lang);
    final encoded = Uri.encodeComponent(raw).replaceAll('%', '_');
    if (encoded.length <= 400) return encoded;
    return encoded.substring(0, 400);
  }

  String _apiKey() => (dotenv.env['GOOGLE_TRANSLATE_API_KEY'] ?? '').trim();

  /// Returns a translated phrase, or null if skipped/failed.
  Future<String?> translateIfNeeded({
    required String canonical,
    required String lang,
  }) {
    final source = canonical.trim();
    final target = lang.trim().toLowerCase();
    if (source.isEmpty || target.isEmpty || target == 'en') {
      return Future<String?>.value(null);
    }
    final key = cacheKey(source, target);
    final mem = _memory[key];
    if (mem != null && mem.isNotEmpty) return Future.value(mem);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final fut = _translateUncached(source: source, lang: target);
    _inFlight[key] = fut;
    fut.whenComplete(() => _inFlight.remove(key));
    return fut;
  }

  Future<String?> _translateUncached({
    required String source,
    required String lang,
  }) async {
    final key = cacheKey(source, lang);
    try {
      final fromFs = await _loadFirestore(source, lang);
      if (fromFs != null && fromFs.isNotEmpty) {
        _memory[key] = fromFs;
        return fromFs;
      }
    } catch (e) {
      debugPrint('[GP] Translate cache read failed: $e');
    }

    final apiKey = _apiKey();
    if (apiKey.isEmpty) {
      if (!_loggedMissingKey) {
        _loggedMissingKey = true;
        debugPrint(
          '[GP] Cloud Translation skipped — set GOOGLE_TRANSLATE_API_KEY '
          'in .env (optional fallback)',
        );
      }
      return null;
    }

    try {
      final uri = Uri.https(
        'translation.googleapis.com',
        '/language/translate/v2',
        {
          'q': source,
          'source': 'en',
          'target': lang,
          'format': 'text',
          'key': apiKey,
        },
      );
      final res = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 401 || res.statusCode == 403) {
        if (!_loggedHttpError) {
          _loggedHttpError = true;
          debugPrint('[GP] Cloud Translation HTTP ${res.statusCode}');
        }
        return null;
      }
      if (res.statusCode != 200) {
        if (!_loggedHttpError) {
          _loggedHttpError = true;
          debugPrint('[GP] Cloud Translation HTTP ${res.statusCode}');
        }
        return null;
      }
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final translations = data['translations'];
      if (translations is! List || translations.isEmpty) return null;
      final first = translations.first;
      if (first is! Map) return null;
      final text = '${first['translatedText'] ?? ''}'.trim();
      if (text.isEmpty) return null;
      if (text.toLowerCase() == source.toLowerCase()) return null;
      _memory[key] = text;
      unawaited(_saveFirestore(source: source, lang: lang, translated: text));
      debugPrint('[GP] Cloud Translation: $source → $text ($lang)');
      return text;
    } catch (e) {
      debugPrint('[GP] Cloud Translation failed: $e');
      return null;
    }
  }

  Future<String?> _loadFirestore(String source, String lang) async {
    if (FirebaseAuth.instance.currentUser == null) return null;
    final snap = await FirebaseFirestore.instance
        .collection(collection)
        .doc(_docId(source, lang))
        .get();
    if (!snap.exists) return null;
    final data = snap.data();
    final translated = '${data?['translated'] ?? ''}'.trim();
    return translated.isEmpty ? null : translated;
  }

  Future<void> _saveFirestore({
    required String source,
    required String lang,
    required String translated,
  }) async {
    try {
      if (FirebaseAuth.instance.currentUser == null) return;
      await FirebaseFirestore.instance
          .collection(collection)
          .doc(_docId(source, lang))
          .set({
        'source': source,
        'translated': translated,
        'lang': lang,
        'cachedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[GP] Translate cache write failed: $e');
    }
  }
}
