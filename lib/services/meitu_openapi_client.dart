import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'meitu_openapi_signer.dart';

/// Meitu OpenAPI — push, poll, upload (for iOS/Android; desktop can use CLI).
class MeituOpenApiClient {
  MeituOpenApiClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const defaultBaseUrl = 'https://openapi-global.meitu.com';
  static const defaultStrategyBaseUrl = 'https://strategy.app.meitudata.com';
  /// OpenClaw combo-tool task (meitu-cli registry). Not the same as Cloud Repair trial APIs.
  static const defaultImageEditTask = '/v1/openclaw/default/image-edit';

  String get _accessKey =>
      (dotenv.env['MEITU_OPENAPI_ACCESS_KEY'] ?? '').trim();
  String get _secretKey =>
      (dotenv.env['MEITU_OPENAPI_SECRET_KEY'] ?? '').trim();

  bool get hasCredentials => _accessKey.isNotEmpty && _secretKey.isNotEmpty;

  String get imageBaseUrl =>
      (dotenv.env['MEITU_OPENAPI_IMAGE_BASE_URL'] ??
              dotenv.env['MEITU_OPENAPI_BASE_URL'] ??
              defaultBaseUrl)
          .trim();

  String get strategyBaseUrl =>
      (dotenv.env['MEITU_OPENAPI_STRATEGY_BASE_URL'] ?? defaultStrategyBaseUrl)
          .trim();

  String get imageEditTask =>
      (dotenv.env['MEITU_OPENAPI_IMAGE_EDIT_TASK'] ?? defaultImageEditTask)
          .trim();

  String get imageEditModel =>
      (dotenv.env['MEITU_OPENAPI_IMAGE_EDIT_MODEL'] ?? 'gummy_pro').trim();

  Future<List<int>> editPortrait({
    required String localImagePath,
    required String prompt,
  }) async {
    final imageUrl = await uploadLocalFile(localImagePath);
    var res = await _push(imageUrl: imageUrl, prompt: prompt);
    if ((res['code'] as num?)?.toInt() != 0) {
      throw HttpException(res['message']?.toString() ?? 'Meitu push failed');
    }
    final taskId = _taskId(res);
    if (taskId != null) {
      res = await _waitTask(taskId);
    }
    if (_failed(res)) {
      throw HttpException(
        res['message']?.toString() ?? 'Meitu edit failed',
      );
    }
    final urls = _resultUrls(res);
    if (urls.isEmpty) {
      throw const HttpException('Meitu returned no image URL');
    }
    debugPrint('[MeituAPI] download ${urls.first}');
    final dl = await _http.get(Uri.parse(urls.first)).timeout(
          const Duration(minutes: 2),
        );
    if (dl.statusCode != 200) {
      throw HttpException('Meitu download HTTP ${dl.statusCode}');
    }
    return dl.bodyBytes;
  }

  /// Meitu push API expects `params` as a JSON **string**, not an object.
  static String _encodePushParams({
    required String prompt,
    required String imageUrl,
    required String model,
  }) =>
      MeituOpenApiSigner.canonicalBodyString({
        'prompt': prompt,
        'model': model,
        'image_list': [imageUrl],
        'ratio': 'auto',
      });

  Future<Map<String, dynamic>> _push({
    required String imageUrl,
    required String prompt,
  }) async {
    final body = <String, dynamic>{
      'task': imageEditTask,
      'task_type': 'mtlab',
      'init_images': [
        {'url': imageUrl},
      ],
      'params': _encodePushParams(
        prompt: prompt,
        imageUrl: imageUrl,
        model: imageEditModel,
      ),
    };
    return _signedJson(
      method: 'POST',
      uri: Uri.parse('$imageBaseUrl/api/v1/sdk/push'),
      body: body,
    );
  }

  Future<Map<String, dynamic>> _waitTask(String taskId) async {
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final res = await _getTask(taskId);
      if ((res['code'] as num?)?.toInt() != 0) return res;
      final status = (res['data'] as Map?)?['status'];
      final code = status is num ? status.toInt() : int.tryParse('$status');
      if (code == 10) return res;
      if (code != null && code != 0 && code != 1 && code != 9) return res;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw TimeoutException('Meitu task timeout: $taskId');
  }

  Future<Map<String, dynamic>> _getTask(String taskId) async {
    return _signedJson(
      method: 'GET',
      uri: Uri.parse('$imageBaseUrl/api/v1/sdk/status').replace(
        queryParameters: {'task_id': taskId},
      ),
      body: null,
    );
  }

  Future<String> uploadLocalFile(String filePath) async {
    final policy = _normalizeUploadPolicy(await _fetchUploadPolicy());
    final endpoint = policy['endpoint']?.toString() ?? '';
    final bucket = policy['bucket']?.toString() ?? '';
    final key = policy['key']?.toString() ?? '';
    final publicUrl = policy['public_url']?.toString().trim() ?? '';
    final creds = policy['credentials'] as Map?;
    if (endpoint.isEmpty || bucket.isEmpty || key.isEmpty || creds == null) {
      debugPrint(
        '[MeituAPI] upload policy missing fields: '
        'endpoint=${endpoint.isNotEmpty} bucket=${bucket.isNotEmpty} '
        'key=${key.isNotEmpty} creds=${creds != null}',
      );
      throw StateError('Invalid Meitu upload policy');
    }
    final bytes = await File(filePath).readAsBytes();
    await _s3Put(
      endpoint: endpoint,
      bucket: bucket,
      key: key,
      bytes: bytes,
      contentType: _mime(filePath),
      accessKey: creds['access_key']?.toString() ?? '',
      secretKey: creds['secret_key']?.toString() ?? '',
      sessionToken: creds['session_token']?.toString(),
      region: policy['region']?.toString(),
    );
    if (publicUrl.isNotEmpty) return publicUrl;
    final host = Uri.parse(endpoint).host;
    return 'https://$bucket.$host/$key';
  }

  /// Strategy API returns `url` + `data`; older docs used `endpoint` + `prefix_url`.
  static Map<String, dynamic> _normalizeUploadPolicy(Map<String, dynamic> raw) {
    final endpoint =
        (raw['endpoint'] ?? raw['url'] ?? raw['backup_url'])?.toString() ?? '';
    final publicUrl = (raw['prefix_url'] ??
            raw['data'] ??
            raw['access_url'])
        ?.toString();
    return {
      ...raw,
      'endpoint': endpoint,
      'public_url': publicUrl,
    };
  }

  Future<Map<String, dynamic>> _fetchUploadPolicy() async {
    final strategyType =
        (dotenv.env['MEITU_OPENAPI_STRATEGY_TYPE'] ?? 'mtai').trim();
    final res = await _signedJson(
      method: 'GET',
      uri: Uri.parse(
        '$strategyBaseUrl/ai/token_policy?type=${Uri.encodeComponent(strategyType)}',
      ),
      body: null,
    );
    if ((res['code'] as num?)?.toInt() != 0) {
      throw HttpException(res['message']?.toString() ?? 'strategy failed');
    }
    final data = res['data'] as Map?;
    final uploadRoot = data?['mtai'] ?? data?[strategyType];
    if (uploadRoot is! Map) throw StateError('strategy missing upload');
    var upload = uploadRoot['upload'];
    if (upload is String) upload = jsonDecode(upload);
    if (upload is! Map) throw StateError('strategy missing upload block');
    final order = upload['order'] as List?;
    if (order == null || order.isEmpty) {
      throw StateError('strategy upload order empty');
    }
    final provider = order.first.toString();
    final cfg = upload[provider];
    if (cfg is! Map) {
      throw StateError('strategy upload config missing for $provider');
    }
    return Map<String, dynamic>.from(cfg);
  }

  Future<Map<String, dynamic>> _signedJson({
    required String method,
    required Uri uri,
    Object? body,
  }) async {
    if (!hasCredentials) {
      throw StateError('Missing MEITU_OPENAPI_ACCESS_KEY/SECRET_KEY');
    }
    final headers = MeituOpenApiSigner.signSdkHeaders(
      url: uri,
      method: method,
      headers: {
        if (body != null) HttpHeaders.contentTypeHeader: 'application/json',
      },
      body: body,
      accessKey: _accessKey,
      secretKey: _secretKey,
      includeHost: true,
    );
    final req = http.Request(method, uri)
      ..headers.addAll(headers)
      ..bodyBytes = body != null
          ? MeituOpenApiSigner.canonicalBodyBytes(body)
          : const [];
    final res = await _http.send(req).timeout(const Duration(seconds: 60));
    final text = await res.stream.bytesToString();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('Meitu HTTP ${res.statusCode}: $text');
    }
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Meitu response not JSON object');
  }

  Future<void> _s3Put({
    required String endpoint,
    required String bucket,
    required String key,
    required List<int> bytes,
    required String contentType,
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    String? region,
  }) async {
    final endpointUri = Uri.parse(endpoint);
    final host = '$bucket.${endpointUri.host}';
    final objectUri = Uri(
      scheme: endpointUri.scheme,
      host: host,
      path: '/$key',
    );
    final amzDate = MeituOpenApiSigner.formatBasicDate();
    final dateStamp = amzDate.substring(0, 8);
    final reg = (region?.isNotEmpty == true) ? region! : 'us-east-1';
    final contentHash = sha256.convert(bytes).toString();
    const service = 's3';
    final signedHeaders = [
      'content-type',
      'host',
      'x-amz-content-sha256',
      'x-amz-date',
      if (sessionToken != null) 'x-amz-security-token',
    ].join(';');
    final canonicalHeaders = [
      'content-type:$contentType',
      'host:$host',
      'x-amz-content-sha256:$contentHash',
      'x-amz-date:$amzDate',
      if (sessionToken != null) 'x-amz-security-token:$sessionToken',
    ].join('\n');
    final canonicalRequest = [
      'PUT',
      '/$key',
      '',
      canonicalHeaders,
      '',
      signedHeaders,
      contentHash,
    ].join('\n');
    final scope = '$dateStamp/$reg/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    List<int> hmac(List<int> key, String data) =>
        Hmac(sha256, key).convert(utf8.encode(data)).bytes;
    final kDate = hmac(utf8.encode('AWS4$secretKey'), dateStamp);
    final kRegion = hmac(kDate, reg);
    final kService = hmac(kRegion, service);
    final kSigning = hmac(kService, 'aws4_request');
    final signature =
        Hmac(sha256, kSigning).convert(utf8.encode(stringToSign)).toString();
    final auth =
        'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
    final res = await _http.put(
      objectUri,
      headers: {
        HttpHeaders.contentTypeHeader: contentType,
        'x-amz-content-sha256': contentHash,
        'x-amz-date': amzDate,
        HttpHeaders.authorizationHeader: auth,
        ...? (sessionToken != null
            ? {'x-amz-security-token': sessionToken}
            : null),
      },
      body: bytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException('S3 upload ${res.statusCode}: ${res.body}');
    }
  }

  static String? _taskId(Map<String, dynamic> res) {
    final data = res['data'];
    if (data is! Map) return null;
    final id = data['task_id']?.toString().trim();
    if (id != null && id.isNotEmpty) return id;
    final task = data['task'];
    if (task is Map) return task['id']?.toString();
    return null;
  }

  static bool _failed(Map<String, dynamic> res) {
    if ((res['code'] as num?)?.toInt() != 0) return true;
    final status = (res['data'] as Map?)?['status'];
    final code = status is num ? status.toInt() : int.tryParse('$status');
    if (code == null) return false;
    return code != 10 && code != 0 && code != 1 && code != 9;
  }

  static List<String> _resultUrls(Map<String, dynamic> res) {
    final urls = <String>[];
    void add(dynamic v) {
      if (v is String && v.startsWith('http')) urls.add(v);
    }

    final result = (res['data'] as Map?)?['result'];
    if (result is Map) {
      final list = result['urls'] ?? result['media_list'];
      if (list is List) {
        for (final item in list) {
          if (item is String) {
            add(item);
          } else if (item is Map) {
            add(item['url']);
          }
        }
      }
      add(result['url']);
    }
    return urls;
  }

  static String _mime(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  void close() => _http.close();
}
