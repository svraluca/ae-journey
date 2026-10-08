import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'meitu_openapi_client.dart';

bool isMeituGatewayAuthorizedError(Object error) {
  final t = error.toString().toLowerCase();
  return t.contains('gateway_authorized') ||
      t.contains('authorization failed') ||
      t.contains('code":90002');
}

String meituEditUserMessage(Object error) {
  if (isMeituGatewayAuthorizedError(error)) {
    return 'This access key signs in, but it is not entitled for Miracle Vision OpenClaw '
        '(image-edit / gummy_pro). Your API Application trial (Cloud Repair, Beauty, Aesthetic) '
        'uses a different product line than meitu-cli and GlowPass stage 3. '
        'Apply for OpenClaw image-edit at miraclevision.com/open-claw, or use the Cloud Repair '
        'HTTP task path from your console API docs in MEITU_OPENAPI_IMAGE_EDIT_TASK.';
  }
  return error.toString();
}

/// Glow Up stage 3 — Meitu `image-edit` (gummy_pro).
/// iOS/Android: OpenAPI directly. Desktop: meitu-cli when available, else OpenAPI.
class MeituGlowUpEditService {
  MeituGlowUpEditService({MeituOpenApiClient? api})
      : _api = api ?? MeituOpenApiClient();

  final MeituOpenApiClient _api;
  static bool? _cliProbeCache;

  bool get hasCredentials => _api.hasCredentials;

  Future<bool> get canRun async => hasCredentials;

  Future<String> editGlowUp(
    String imagePath, {
    required String customPrompt,
  }) async {
    if (!hasCredentials) {
      throw StateError('Missing MEITU_OPENAPI_ACCESS_KEY/SECRET_KEY');
    }
    final prompt = customPrompt.trim();
    if (prompt.isEmpty) {
      throw ArgumentError('Meitu edit prompt must not be empty');
    }

    final useCli = !Platform.isIOS && !Platform.isAndroid && await _cliReady();
    if (useCli) {
      try {
        return await _runCli(imagePath, prompt);
      } catch (e) {
        debugPrint('[MeituEdit] CLI failed, trying OpenAPI: $e');
      }
    }

    debugPrint('[MeituEdit] OpenAPI image-edit (${_api.imageEditModel})');
    final bytes = await _api.editPortrait(
      localImagePath: imagePath,
      prompt: prompt,
    );
    return _saveBytes(bytes);
  }

  Future<bool> _cliReady() async {
    if (_cliProbeCache != null) return _cliProbeCache!;
    try {
      final useNpx = (dotenv.env['MEITU_CLI_USE_NPX'] ?? 'false')
              .trim()
              .toLowerCase() ==
          'true';
      final bin = useNpx ? 'npx' : (dotenv.env['MEITU_CLI_BIN'] ?? 'meitu');
      final r = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [bin],
      );
      _cliProbeCache = r.exitCode == 0;
    } catch (_) {
      _cliProbeCache = false;
    }
    return _cliProbeCache!;
  }

  Map<String, String> _meituEnv() => {
        ...Platform.environment,
        if ((dotenv.env['MEITU_OPENAPI_ACCESS_KEY'] ?? '').trim().isNotEmpty)
          'MEITU_OPENAPI_ACCESS_KEY':
              dotenv.env['MEITU_OPENAPI_ACCESS_KEY']!.trim(),
        if ((dotenv.env['MEITU_OPENAPI_SECRET_KEY'] ?? '').trim().isNotEmpty)
          'MEITU_OPENAPI_SECRET_KEY':
              dotenv.env['MEITU_OPENAPI_SECRET_KEY']!.trim(),
      };

  Future<String> _runCli(String imagePath, String prompt) async {
    final useNpx = (dotenv.env['MEITU_CLI_USE_NPX'] ?? 'false')
            .trim()
            .toLowerCase() ==
        'true';
    final executable = useNpx ? 'npx' : (dotenv.env['MEITU_CLI_BIN'] ?? 'meitu');
    final prefix = useNpx ? ['-y', 'meitu-cli'] : <String>[];
    final model =
        (dotenv.env['MEITU_OPENAPI_IMAGE_EDIT_MODEL'] ?? 'gummy_pro').trim();
    final dir = await Directory.systemTemp.createTemp('meitu_glow_');
    try {
      final result = await Process.run(
        executable,
        [
          ...prefix,
          'image-edit',
          '--image_list',
          File(imagePath).absolute.path,
          '--prompt',
          prompt,
          '--model',
          model,
          '--json',
          '--download-dir',
          dir.path,
        ],
        environment: _meituEnv(),
      ).timeout(const Duration(minutes: 8));
      if (result.exitCode != 0) {
        throw HttpException(result.stderr.toString().trim());
      }
      final json = _parseJson(result.stdout.toString());
      final path = await _pathFromCliJson(json, dir);
      final docs = await getApplicationDocumentsDirectory();
      final photos = Directory('${docs.path}/photos');
      if (!await photos.exists()) await photos.create(recursive: true);
      final dest = File('${photos.path}/glow_meitu_${const Uuid().v4()}.jpg');
      await File(path).copy(dest.path);
      debugPrint('[MeituEdit] CLI saved → ${dest.path}');
      return dest.path;
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<String> _saveBytes(List<int> bytes) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    final out = File('${dir.path}/glow_meitu_${const Uuid().v4()}.jpg');
    await out.writeAsBytes(bytes, flush: true);
    debugPrint('[MeituEdit] API saved → ${out.path}');
    return out.path;
  }

  Map<String, dynamic>? _parseJson(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    try {
      final d = jsonDecode(t);
      if (d is Map<String, dynamic>) return d;
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    final s = t.lastIndexOf('{');
    final e = t.lastIndexOf('}');
    if (s >= 0 && e > s) {
      try {
        final d = jsonDecode(t.substring(s, e + 1));
        if (d is Map<String, dynamic>) return d;
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }

  Future<String> _pathFromCliJson(
    Map<String, dynamic>? json,
    Directory dir,
  ) async {
    final downloaded = json?['downloaded_files'];
    if (downloaded is List) {
      for (final item in downloaded) {
        if (item is Map) {
          final p = item['path'] ?? item['save_path'];
          if (p is String && await File(p).exists()) return p;
        } else if (item is String && await File(item).exists()) {
          return item;
        }
      }
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .toList();
    if (files.isNotEmpty) {
      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );
      return files.first.path;
    }
    throw const HttpException('Meitu CLI returned no image file');
  }
}
