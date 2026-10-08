import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Builds a PNG mask for [OpenAIImageEditService] / gpt-image-1 edits.
///
/// Fully **opaque** pixels are preserved; **transparent** pixels may be edited.
/// Regions are tuned for a centered portrait selfie (face ~centered, 3:4).
Uint8List buildGlowUpEditMask(int width, int height) {
  final mask = img.Image(width: width, height: height, numChannels: 4);
  img.fill(mask, color: img.ColorRgba8(255, 255, 255, 255));

  void zone(double cx, double cy, double rx, double ry) {
    _softEllipse(mask, cx * width, cy * height, rx * width, ry * height);
  }

  // Under-eye bags
  zone(0.36, 0.40, 0.11, 0.055);
  zone(0.64, 0.40, 0.11, 0.055);

  // Nasolabial / smile lines
  zone(0.38, 0.57, 0.09, 0.11);
  zone(0.62, 0.57, 0.09, 0.11);

  // Lips (upper + lower)
  zone(0.50, 0.63, 0.13, 0.075);

  // Outer eye corners (small edit zones)
  zone(0.27, 0.36, 0.055, 0.045);
  zone(0.73, 0.36, 0.055, 0.045);

  return Uint8List.fromList(img.encodePng(mask));
}

/// Smaller mask (under-eyes + smile lines only) for moderation fallback.
Uint8List buildGlowUpEditMaskMinimal(int width, int height) {
  final mask = img.Image(width: width, height: height, numChannels: 4);
  img.fill(mask, color: img.ColorRgba8(255, 255, 255, 255));

  void zone(double cx, double cy, double rx, double ry) {
    _softEllipse(mask, cx * width, cy * height, rx * width, ry * height);
  }

  zone(0.36, 0.40, 0.11, 0.055);
  zone(0.64, 0.40, 0.11, 0.055);
  zone(0.38, 0.57, 0.09, 0.11);
  zone(0.62, 0.57, 0.09, 0.11);

  return Uint8List.fromList(img.encodePng(mask));
}

/// Transparent center (edit) with soft opaque falloff at edges.
void _softEllipse(img.Image mask, double cx, double cy, double rx, double ry) {
  final x0 = math.max(0, (cx - rx - 4).floor());
  final x1 = math.min(mask.width - 1, (cx + rx + 4).ceil());
  final y0 = math.max(0, (cy - ry - 4).floor());
  final y1 = math.min(mask.height - 1, (cy + ry + 4).ceil());

  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final dx = (x - cx) / rx;
      final dy = (y - cy) / ry;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > 1.15) continue;
      // 0 = edit in core, 255 = preserve; feather 0.85–1.15
      final alpha = d <= 0.85
          ? 0
          : ((d - 0.85) / 0.3 * 255).round().clamp(0, 255);
      final p = mask.getPixel(x, y);
      if (alpha < p.a.toInt()) {
        // Fully transparent edit zones must use alpha 0 (not white + alpha 0).
        mask.setPixelRgba(x, y, 0, 0, 0, alpha);
      }
    }
  }
}
