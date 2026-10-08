import 'dart:io';

import 'package:image/image.dart' as img;

Future<void> knockOutBlack(
  String path, {
  int threshold = 72,
  int feather = 48,
}) async {
  final bytes = await File(path).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    stdout.writeln('Failed to decode $path');
    return;
  }
  final image = decoded.convert(numChannels: 4);
  var transparent = 0;

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      final r = p.r.toInt();
      final g = p.g.toInt();
      final b = p.b.toInt();
      final a = p.a.toInt();
      final lum = (r + g + b) / 3.0;

      // Feather dark pixels to transparent instead of a hard cutoff.
      if (lum <= threshold) {
        image.setPixelRgba(x, y, r, g, b, 0);
        transparent++;
      } else if (lum <= threshold + feather) {
        final t = (lum - threshold) / feather;
        final nextA = (a * t).round().clamp(0, 255);
        if (nextA == 0) transparent++;
        image.setPixelRgba(x, y, r, g, b, nextA);
      }
    }
  }

  final out = path.replaceAll(RegExp(r'\.(png|jpg|jpeg)$', caseSensitive: false), '_transparent.png');
  await File(out).writeAsBytes(img.encodePng(image));
  stdout.writeln('$path -> $out ($transparent px transparent)');
}

Future<void> main(List<String> args) async {
  final paths = args.isEmpty
      ? [
          'assets/logofacescan2.png',
          'assets/bodylogoscan.png',
          'assets/logofacescan.png',
          'assets/aestheticlogo.png',
          'assets/surgerylogo.png',
        ]
      : args;

  for (final path in paths) {
    if (await File(path).exists()) {
      await knockOutBlack(path, threshold: path.contains('face') || path.contains('body') ? 82 : 72);
    }
  }
}
