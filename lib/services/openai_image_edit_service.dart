import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'glow_up_edit_composite.dart';

const kGlowUpFaceEditPrompt = '''
Neutral ring-light beauty portrait retouch.
Same real person — same skin undertone as input.

Preserve exact skin color — neutral beige/pink,
NOT orange, NOT golden, NOT tan.

Soften under-eye shadows, forehead lines, smile lines.
Clear even skin with soft dewy luminosity — no bronzer.
Bright natural sclera. Subtle lip volume +10%.
Soft neutral studio light. Black background unchanged.
Keep pores and real texture. No makeup. No warm filter.

FORBIDDEN: orange skin, bronze tan, warm grade,
heavy makeup, plastic airbrush, identity change.
''';

/// Stage 1 — background only. No face retouch, no relighting, no crop.
const kBlackStudioBackgroundPrompt = '''
Replace ONLY the background with solid black (#000000).
Keep the person pixel-identical: same face, eyes, skin, hair, pose, framing.
Do NOT retouch, smooth, darken, or relight the face.
Do NOT zoom, crop, or reframe.
''';

/// Before preview — match soft studio light to the after shot; do not retouch features.
const kBeforeStudioLightingPrompt = '''
Pure black studio background (#000000). Soft, even beauty-portrait studio lighting on the face.
Do NOT change face shape, eyes, nose, lips, jaw, pores, wrinkles, or expression.
Do NOT add makeup or skin smoothing. Only gently even out harsh shadows and color cast.
Same framing, pose, and head size as the input.
''';

bool isOpenAiBillingError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('insufficient_quota') ||
      text.contains('billing_hard_limit') ||
      text.contains('billing_limit') ||
      text.contains('exceeded your current quota');
}

String glowUpEditUserMessage(Object error) {
  if (isModerationBlocked(error)) {
    return 'AI preview could not be generated for this photo (safety filter). Showing your original.';
  }
  if (isOpenAiBillingError(error)) {
    return 'OpenAI billing limit reached — using Replicate for preview.';
  }
  return 'AI preview unavailable. Showing your original.';
}

bool isModerationBlocked(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('moderation_blocked') ||
      text.contains('safety system') ||
      text.contains('rejected by the safety');
}

/// Client for OpenAI's `gpt-image-1` image-edit endpoint.
class OpenAIImageEditService {
  OpenAIImageEditService({http.Client? client, String? apiKey})
      : _client = client ?? http.Client(),
        _apiKey = (apiKey ?? dotenv.env['OPENAI_API_KEY'] ?? '').trim();

  final http.Client _client;
  final String _apiKey;

  static const _endpoint = 'https://api.openai.com/v1/images/edits';

  bool get hasKey => _apiKey.isNotEmpty;

  /// Set when OpenAI returns billing / quota errors — skip further edit calls.
  static bool billingBlocked = false;

  bool get canEdit => hasKey && !billingBlocked;

  /// Puts the portrait on a pure black studio background (pipeline stage 1).
  Future<String> normalizeBlackStudio(String imageRef) async {
    return edit(
      imageRef: imageRef,
      prompt: kBlackStudioBackgroundPrompt,
      inputFidelity: 'high',
      quality: 'high',
      compositeOnOriginal: false,
    );
  }

  /// Gentle studio lighting on the before preview (identity preserved).
  Future<String> polishBeforeStudioLighting(String studioImageRef) async {
    return edit(
      imageRef: studioImageRef,
      prompt: kBeforeStudioLightingPrompt,
      inputFidelity: 'high',
      quality: 'high',
      compositeOnOriginal: false,
    );
  }

  /// Glow Up face retouch (pipeline stage 2). Pass [customPrompt] from vision analysis.
  Future<String> editGlowUp(
    String imageRef, {
    String? customPrompt,
    bool compositeOnOriginal = false,
  }) async {
    final prompt = customPrompt?.trim().isNotEmpty == true
        ? customPrompt!.trim()
        : kGlowUpFaceEditPrompt;
    final fidelity = _glowUpInputFidelity();

    debugPrint('[ImageEdit] glow-up attempt 1/1');
    return edit(
      imageRef: imageRef,
      prompt: prompt,
      inputFidelity: fidelity,
      quality: 'high',
      compositeOnOriginal: false,
    );
  }

  Future<String> edit({
    required String imageRef,
    required String prompt,
    Uint8List? maskPngBytes,
    String quality = 'high',
    String size = 'auto',
    String inputFidelity = 'high',
    bool compositeOnOriginal = false,
  }) async {
    if (!hasKey) {
      throw StateError(
        'Missing OPENAI_API_KEY. Add it to .env or pass apiToken to '
        'OpenAIImageEditService().',
      );
    }

    final rawBytes = await _resolveBytes(imageRef);
    final inputBytes = _prepareInputForEdit(rawBytes);

    final request = http.MultipartRequest('POST', Uri.parse(_endpoint))
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..fields['model'] = 'gpt-image-1'
      ..fields['prompt'] = prompt
      ..fields['n'] = '1'
      ..fields['quality'] = quality
      ..fields['size'] = size
      ..fields['input_fidelity'] = inputFidelity
      ..fields['output_format'] = 'jpeg'
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          inputBytes,
          filename: 'input.jpg',
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    if (maskPngBytes != null) {
      request.files.add(
        http.MultipartFile.fromBytes(
          'mask',
          maskPngBytes,
          filename: 'mask.png',
          contentType: MediaType('image', 'png'),
        ),
      );
    }

    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (isOpenAiBillingError(response.body)) {
        billingBlocked = true;
      }
      throw HttpException(
        'gpt-image-1 edit failed: ${response.statusCode} ${response.body}',
      );
    }

    billingBlocked = false;

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List?;
    if (data == null || data.isEmpty) {
      throw const HttpException('gpt-image-1 returned empty data array');
    }
    final first = data.first as Map<String, dynamic>;
    final b64 = first['b64_json'] as String?;
    if (b64 == null || b64.isEmpty) {
      throw const HttpException(
        'gpt-image-1 returned no b64_json — response shape unexpected',
      );
    }

    var outputBytes = base64Decode(b64);
    // Always use direct resize — no compositing.
    // Compositing causes ghost/blur when AI shifts face.
    outputBytes = _resizeToInput(inputBytes, outputBytes);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    final out = File('${dir.path}/glow_${const Uuid().v4()}.jpg');
    await out.writeAsBytes(outputBytes, flush: true);
    debugPrint(
      '[ImageEdit] saved ${outputBytes.length} bytes → ${out.path}'
      '${maskPngBytes != null ? ' (masked)' : ''}',
    );
    return out.path;
  }

  Future<List<int>> _resolveBytes(String ref) async {
    final trimmed = ref.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final res = await _client.get(Uri.parse(trimmed));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException(
          'Could not download image (${res.statusCode}) from $trimmed',
        );
      }
      return res.bodyBytes;
    }
    if (trimmed.startsWith('data:')) {
      final comma = trimmed.indexOf(',');
      if (comma < 0) {
        throw const FormatException('Malformed data URI');
      }
      return base64Decode(trimmed.substring(comma + 1));
    }
    final file = File(trimmed);
    if (!await file.exists()) {
      throw FileSystemException('Local image not found', trimmed);
    }
    return file.readAsBytes();
  }

  void close() => _client.close();
}

String _glowUpInputFidelity() {
  final chatGpt = (dotenv.env['GLOW_UP_CHATGPT_STYLE'] ?? 'false')
      .trim()
      .toLowerCase();
  if (chatGpt == 'true' || chatGpt == '1' || chatGpt == 'on') {
    return 'high';
  }
  final v = (dotenv.env['GLOW_UP_EDIT_INPUT_FIDELITY'] ?? 'high')
      .trim()
      .toLowerCase();
  if (v == 'high' || v == 'low') return v;
  return 'high';
}

double _editBlendStrength() {
  final raw = (dotenv.env['GLOW_UP_EDIT_BLEND'] ?? '0.55').trim();
  final v = double.tryParse(raw);
  if (v == null) return 0.55;
  return v.clamp(0.2, 1.0);
}

class _EditAttempt {
  const _EditAttempt(this.prompt, this.mask);
  final String prompt;
  final Uint8List? mask;
}

/// Black-hole count on face skin — lower is better (used to reject bad boost passes).
int glowUpEditCorruptScore(List<int> outputBytes, List<int> inputBytes) =>
    _corruptScore(outputBytes, inputBytes);

/// True only when a large fraction of the face has pure-black inpaint holes.
bool glowUpEditHasSevereInpaintHoles(List<int> outputBytes, List<int> inputBytes) =>
    _hasSevereInpaintHoles(outputBytes, inputBytes);

bool _hasSevereInpaintHoles(List<int> outputBytes, List<int> inputBytes) {
  final out = img.decodeImage(Uint8List.fromList(outputBytes));
  final inp = img.decodeImage(Uint8List.fromList(inputBytes));
  if (out == null || inp == null) return false;

  final outSized = out.width == inp.width && out.height == inp.height
      ? out
      : img.copyResize(
          out,
          width: inp.width,
          height: inp.height,
          interpolation: img.Interpolation.linear,
        );

  final cx = outSized.width * 0.5;
  final cy = outSized.height * 0.42;
  final rx = outSized.width * 0.26;
  final ry = outSized.height * 0.32;

  var skinPixels = 0;
  var holesOnSkin = 0;
  for (var y = 0; y < outSized.height; y++) {
    for (var x = 0; x < outSized.width; x++) {
      final dx = (x - cx) / rx;
      final dy = (y - cy) / ry;
      if (dx * dx + dy * dy > 1) continue;

      final pi = inp.getPixel(x, y);
      final lumIn = 0.299 * pi.r + 0.587 * pi.g + 0.114 * pi.b;
      if (lumIn <= 32) continue; // skip studio background in input

      skinPixels++;
      final po = outSized.getPixel(x, y);
      if (po.r < 12 && po.g < 12 && po.b < 12) holesOnSkin++;
    }
  }
  if (skinPixels < 80) return false;
  final ratio = holesOnSkin / skinPixels;
  return ratio > 0.14;
}

/// Counts near-pure-black pixels on face skin in the input silhouette (for ranking).
int _corruptScore(List<int> outputBytes, List<int> inputBytes) {
  final out = img.decodeImage(Uint8List.fromList(outputBytes));
  final inp = img.decodeImage(Uint8List.fromList(inputBytes));
  if (out == null || inp == null) return 0;

  final outSized = out.width == inp.width && out.height == inp.height
      ? out
      : img.copyResize(
          out,
          width: inp.width,
          height: inp.height,
          interpolation: img.Interpolation.linear,
        );

  final cx = outSized.width * 0.5;
  final cy = outSized.height * 0.42;
  final rx = outSized.width * 0.26;
  final ry = outSized.height * 0.32;

  var holesOnSkin = 0;
  for (var y = 0; y < outSized.height; y++) {
    for (var x = 0; x < outSized.width; x++) {
      final dx = (x - cx) / rx;
      final dy = (y - cy) / ry;
      if (dx * dx + dy * dy > 1) continue;

      final pi = inp.getPixel(x, y);
      final po = outSized.getPixel(x, y);
      final lumIn = 0.299 * pi.r + 0.587 * pi.g + 0.114 * pi.b;
      if (lumIn <= 32) continue;
      final hole = po.r < 12 && po.g < 12 && po.b < 12;
      if (hole) holesOnSkin++;
    }
  }
  return holesOnSkin;
}

List<int> _prepareInputForEdit(List<int> inputBytes) {
  final im = img.decodeImage(Uint8List.fromList(inputBytes));
  if (im == null) return inputBytes;

  if (im.width == im.height && im.width == 1024) {
    return inputBytes;
  }

  int w;
  int h;
  if (im.width >= im.height) {
    w = 1024;
    h = (1024 * im.height / im.width).round();
  } else {
    h = 1024;
    w = (1024 * im.width / im.height).round();
  }

  final resized = img.copyResize(
    im,
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );

  return img.encodeJpg(resized, quality: 95);
}

Uint8List _resizeToInput(List<int> inputBytes, List<int> outputBytes) {
  final input = img.decodeImage(Uint8List.fromList(inputBytes));
  final output = img.decodeImage(Uint8List.fromList(outputBytes));
  if (input == null || output == null) {
    return Uint8List.fromList(outputBytes);
  }
  if (input.width == output.width && input.height == output.height) {
    return Uint8List.fromList(outputBytes);
  }
  final fitted = letterboxToSize(output, input.width, input.height);
  return Uint8List.fromList(img.encodeJpg(fitted, quality: 92));
}

