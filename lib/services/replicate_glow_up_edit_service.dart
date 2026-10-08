import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'photo_processor.dart';
import 'replicate_service.dart';

/// FLUX Kontext Pro — better identity lock for subtle portrait edits.
const kDefaultGlowEditModel = 'black-forest-labs/flux-kontext-pro';

const kDefaultRembgModel = 'cjwbw/rembg';

const kDefaultCodeformerModel = 'sczhou/codeformer';

/// Replicate stack: rembg → black studio → FLUX Kontext edit → CodeFormer clarity.
class ReplicateGlowUpEditService {
  ReplicateGlowUpEditService({
    ReplicateService? replicate,
    String? editModelSlug,
    String? rembgModelSlug,
    String? restoreModelSlug,
  })  : _replicate = replicate ?? ReplicateService(),
        _editSlug = _envOr(editModelSlug, 'REPLICATE_GLOW_EDIT_MODEL', kDefaultGlowEditModel),
        _rembgSlug = _envOr(rembgModelSlug, 'REPLICATE_REMBG_MODEL', kDefaultRembgModel),
        _restoreSlug = _envOr(restoreModelSlug, 'REPLICATE_FACE_RESTORE_MODEL', kDefaultCodeformerModel);

  final ReplicateService _replicate;
  final String _editSlug;
  final String _rembgSlug;
  final String _restoreSlug;

  bool get canRun => _replicate.hasToken;

  String get modelSlug => _editSlug;

  static String _envOr(String? override, String key, String fallback) {
    final v = (override ?? dotenv.env[key] ?? '').trim();
    return v.isEmpty ? fallback : v;
  }

  double get _codeformerFidelity {
    final raw = dotenv.env['REPLICATE_CODEFORMER_FIDELITY'] ?? '0.78';
    return (double.tryParse(raw) ?? 0.78).clamp(0.5, 0.95);
  }

  bool get _skipCodeformer {
    final v =
        (dotenv.env['GLOW_UP_SKIP_CODEFORMER'] ?? 'true').trim().toLowerCase();
    return v != 'false' && v != '0';
  }

  /// Stage-1 studio: rembg composite (default), or FLUX background (env).
  Future<String> normalizeBlackStudio(String imagePath) async {
    if (!canRun) {
      throw StateError('Missing REPLICATE_API_TOKEN');
    }

    final mode =
        (dotenv.env['GLOW_UP_STUDIO_MODE'] ?? 'rembg').trim().toLowerCase();
    const fluxPrompt = '''
Replace ONLY the background with a dark charcoal professional studio backdrop (#0E0E12).
Keep the person exactly the same — same face, visible white sclera and iris, skin, hair, pose, clothing.
Soft even beauty lighting on the face. Do not retouch or reshape the face.
''';

    if (mode == 'replicate_flux' ||
        mode == 'flux' ||
        mode == 'ai' ||
        mode == 'replicate') {
      try {
        final path = await _runEditModel(
          imagePath: imagePath,
          prompt: fluxPrompt,
        );
        debugPrint('[ReplicateEdit] studio (flux raw) → $path');
        return path;
      } catch (e) {
        debugPrint('[ReplicateEdit] flux studio failed, rembg fallback: $e');
      }
    }

    try {
      final imageUri = await ReplicateService.imageInputFor(imagePath);
      debugPrint('[ReplicateEdit] rembg $_rembgSlug');
      final raw = await _replicate.run(
        _rembgSlug,
        input: {'image': imageUri},
        timeout: const Duration(minutes: 3),
      );
      final url = _outputUrl(raw);
      if (url == null) throw HttpException('rembg returned no URL');
      final pngBytes = await _replicate.downloadBytes(url);
      final path = await compositeCutoutOverBackdrop(
        rgbaPng: pngBytes,
        source: PhotoSource.camera,
        originalPhotoPath: imagePath,
      );
      debugPrint('[ReplicateEdit] studio (rembg) → $path');
      return path;
    } catch (e) {
      debugPrint('[ReplicateEdit] rembg failed, AI studio fallback: $e');
      final path = await _runEditModel(
        imagePath: imagePath,
        prompt: fluxPrompt,
      );
      return polishStudioBeforeFile(
        path,
        originalPhotoPath: imagePath,
        aiGeneratedStudio: true,
      );
    }
  }

  Future<String> editGlowUp(
    String imagePath, {
    required String customPrompt,
  }) async {
    // FLUX Kontext: shorten to core instructions only
    // Long prompts dilute the model's attention
    const fluxPrompt =
        'Same person. Professional aesthetic clinic result. '
        'Remove dark circles completely. Smooth luminous skin. '
        'Remove smile lines and forehead wrinkles. '
        'Foxy eye lift outer corners 4 degrees. '
        'Russian lips +20% volume with cupid bow. '
        'Cheek filler lift midface. Golden skin glow. '
        'Ultra realistic. Same background framing clothing.';

    var path = await _runEditModel(imagePath: imagePath, prompt: fluxPrompt);
    if (!_skipCodeformer) {
      path = await _restoreClarity(path);
    } else {
      debugPrint('[ReplicateEdit] CodeFormer skipped (GLOW_UP_SKIP_CODEFORMER)');
    }
    return path;
  }

  Future<String> _runEditModel({
    required String imagePath,
    required String prompt,
  }) async {
    if (!canRun) {
      throw StateError('Missing REPLICATE_API_TOKEN for $_editSlug');
    }

    final imageUri = await ReplicateService.imageInputFor(imagePath);
    final preview = prompt.length > 160 ? '${prompt.substring(0, 160)}…' : prompt;
    debugPrint('[ReplicateEdit] $_editSlug (${prompt.length} chars): $preview');

    final Map<String, Object?> input;
    if (_editSlug.startsWith('google/nano-banana')) {
      input = {
        'prompt': prompt,
        'image_input': [imageUri],
        'aspect_ratio': 'match_input_image',
        'output_format': 'jpg',
      };
    } else if (_editSlug.contains('flux-kontext')) {
      input = {
        'prompt': prompt,
        'input_image': imageUri,
        'aspect_ratio': 'match_input_image',
        'output_format': 'jpg',
        'safety_tolerance': 2,
      };
    } else {
      input = {
        'prompt': prompt,
        'input_image': imageUri,
        'aspect_ratio': 'match_input_image',
      };
    }

    final raw = await _replicate.run(
      _editSlug,
      input: input,
      timeout: const Duration(minutes: 5),
    );

    return _downloadToPhotos(raw, _editSlug);
  }

  /// CodeFormer restores sharp facial detail after generative edits.
  Future<String> _restoreClarity(String imagePath) async {
    if (_restoreSlug.isEmpty || !canRun) return imagePath;
    try {
      final imageUri = await ReplicateService.imageInputFor(imagePath);
      debugPrint(
        '[ReplicateEdit] CodeFormer fidelity=$_codeformerFidelity',
      );
      final raw = await _replicate.run(
        _restoreSlug,
        input: {
          'image': imageUri,
          'codeformer_fidelity': _codeformerFidelity,
          'background_enhance': false,
          'face_upsample': true,
          'upscale': 1,
        },
        timeout: const Duration(minutes: 3),
      );
      final path = await _downloadToPhotos(raw, 'codeformer');
      debugPrint('[ReplicateEdit] clarity restore → $path');
      return path;
    } catch (e) {
      debugPrint('[ReplicateEdit] CodeFormer skipped: $e');
      return imagePath;
    }
  }

  Future<String> _downloadToPhotos(Object? raw, String label) async {
    final url = _outputUrl(raw);
    if (url == null || url.isEmpty) {
      throw HttpException('Replicate ($label) returned no image URL');
    }
    final bytes = await _replicate.downloadBytes(url);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    final out = File('${dir.path}/glow_${const Uuid().v4()}.jpg');
    await out.writeAsBytes(bytes, flush: true);
    debugPrint('[ReplicateEdit] saved $label → ${out.path}');
    return out.path;
  }

  static String? _outputUrl(Object? output) {
    if (output is String && output.startsWith('http')) return output;
    if (output is List) {
      for (final item in output) {
        if (item is String && item.startsWith('http')) return item;
      }
    }
    return null;
  }
}
