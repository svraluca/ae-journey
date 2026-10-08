import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Thin client for [Replicate](https://replicate.com)'s REST API.
///
/// Reads `REPLICATE_API_TOKEN` from `.env` (same pattern as OpenAI/Anthropic
/// keys in this project). Use [run] to invoke a model by its `owner/name`
/// slug — the call blocks until the prediction finishes (or fails / times
/// out). Successful output is returned as the raw decoded JSON value from
/// Replicate's `output` field; callers are responsible for narrowing it
/// (single URL string vs list of URLs vs structured map).
class ReplicateService {
  ReplicateService({http.Client? client, String? apiToken})
    : _client = client ?? http.Client(),
      _token = (apiToken ?? dotenv.env['REPLICATE_API_TOKEN'] ?? '').trim();

  final http.Client _client;
  final String _token;

  /// Caches `latest_version.id` per `owner/name` for the lifetime of this
  /// service. Replicate's version-based endpoint is universal (community +
  /// official models), but it requires a per-request version hash — without
  /// the cache we'd burn an extra HTTP round-trip on every pipeline stage.
  final Map<String, String> _versionCache = {};

  static const _base = 'https://api.replicate.com/v1';

  bool get hasToken => _token.isNotEmpty;

  // Replicate's docs specify `Token <token>` — `Bearer` is silently rejected
  // by some endpoints with no helpful error, which causes the whole pipeline
  // to look like it "ran but did nothing".
  Map<String, String> get _authHeaders => {
    'Authorization': 'Token $_token',
    'Content-Type': 'application/json',
  };

  /// Run a model by its `owner/name` slug. Uses Replicate's "official models"
  /// endpoint which selects the latest version automatically.
  Future<Object?> run(
    String modelSlug, {
    required Map<String, Object?> input,
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 3),
    int maxStartAttempts = 5,
  }) async {
    if (!hasToken) {
      throw StateError(
        'Missing REPLICATE_API_TOKEN. Add it to .env or pass apiToken to ReplicateService().',
      );
    }

    final version = await _resolveLatestVersion(modelSlug);

    http.Response? created;
    for (var attempt = 0; attempt < maxStartAttempts; attempt++) {
      created = await _client.post(
        Uri.parse('$_base/predictions'),
        headers: _authHeaders,
        body: jsonEncode({'version': version, 'input': input}),
      );
      if (created.statusCode == 429 && attempt < maxStartAttempts - 1) {
        final wait = _retryAfterSeconds(created.body) ?? 12;
        await Future<void>.delayed(Duration(seconds: wait));
        continue;
      }
      break;
    }
    final response = created!;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Replicate ($modelSlug) start failed: ${response.statusCode} ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final id = body['id'] as String?;
    if (id == null) {
      throw const HttpException('Replicate response missing prediction id');
    }
    // Already finished synchronously (rare).
    final inlineOutput = _outputIfTerminal(body);
    if (inlineOutput.terminated) return inlineOutput.output;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      final res = await _client.get(
        Uri.parse('$_base/predictions/$id'),
        headers: _authHeaders,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'Replicate ($modelSlug) poll failed: ${res.statusCode}',
        );
      }
      final state = jsonDecode(res.body) as Map<String, dynamic>;
      final term = _outputIfTerminal(state);
      if (term.terminated) return term.output;
    }
    throw TimeoutException(
      'Replicate ($modelSlug) prediction timed out after ${timeout.inSeconds}s',
    );
  }

  /// Looks up `latest_version.id` for `owner/name`. Cached for the lifetime
  /// of this service so the version round-trip happens once per model per
  /// session, not once per pipeline stage.
  Future<String> _resolveLatestVersion(String modelSlug) async {
    final cached = _versionCache[modelSlug];
    if (cached != null) return cached;
    final res = await _client.get(
      Uri.parse('$_base/models/$modelSlug'),
      headers: _authHeaders,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException(
        'Replicate model lookup ($modelSlug) failed: ${res.statusCode} ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final lv = body['latest_version'] as Map<String, dynamic>?;
    final id = lv?['id'] as String?;
    if (id == null) {
      throw HttpException(
        'Replicate model $modelSlug has no latest_version — check the slug.',
      );
    }
    _versionCache[modelSlug] = id;
    return id;
  }

  static int? _retryAfterSeconds(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final retry = map['retry_after'];
      if (retry is int) return retry;
      if (retry is num) return retry.round();
    } catch (_) {}
    return null;
  }

  _TerminalState _outputIfTerminal(Map<String, dynamic> state) {
    final status = state['status'] as String?;
    if (status == 'succeeded') {
      return _TerminalState(true, state['output']);
    }
    if (status == 'failed' || status == 'canceled') {
      throw HttpException(
        'Replicate prediction $status: ${state['error'] ?? '(no error)'}',
      );
    }
    return const _TerminalState(false, null);
  }

  /// Normalises a local file path or remote URL into a value Replicate accepts
  /// as an image input. Remote `http(s)://` URLs are forwarded as-is; local
  /// files are base64-encoded into a `data:image/...;base64,...` URI.
  static Future<String> imageInputFor(String pathOrUrl) async {
    final trimmed = pathOrUrl.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Empty photo path');
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    final file = File(trimmed);
    if (!await file.exists()) {
      throw FileSystemException('Photo not found', trimmed);
    }
    final bytes = await file.readAsBytes();
    final mime = _mimeFromPath(trimmed);
    final b64 = base64Encode(bytes);
    return 'data:$mime;base64,$b64';
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  /// Fetches the bytes of a Replicate model output URL (or any public URL).
  /// Used to pull a rembg cutout back into the app for local compositing.
  Future<List<int>> downloadBytes(String url) async {
    final res = await _client.get(Uri.parse(url));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('Download failed (${res.statusCode}) for $url');
    }
    return res.bodyBytes;
  }

  /// Encodes a raw byte payload as a `data:<mime>;base64,...` URI suitable
  /// for the `image` input of most Replicate models.
  static String bytesToDataUri(List<int> bytes, {String mime = 'image/jpeg'}) {
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  void close() => _client.close();
}

class _TerminalState {
  const _TerminalState(this.terminated, this.output);
  final bool terminated;
  final Object? output;
}

@visibleForTesting
String debugDescribeReplicateOutput(Object? output) {
  if (output is String) return output;
  if (output is List) return output.join(', ');
  return output?.toString() ?? '';
}
