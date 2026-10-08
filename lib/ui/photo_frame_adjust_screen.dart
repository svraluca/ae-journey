import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

import 'photo_storage.dart';

/// Opens a full-screen 3:4 framing editor (drag + pinch zoom).
///
/// Returns a local JPEG path of the framed result, or null if cancelled.
Future<String?> openPhotoFrameAdjust(
  BuildContext context, {
  required String sourcePath,
  required String label,
  String? referencePath,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoFrameAdjustScreen(
        sourcePath: sourcePath,
        label: label,
        referencePath: referencePath,
      ),
    ),
  );
}

class PhotoFrameAdjustScreen extends StatefulWidget {
  const PhotoFrameAdjustScreen({
    super.key,
    required this.sourcePath,
    required this.label,
    this.referencePath,
  });

  final String sourcePath;
  final String label;
  final String? referencePath;

  @override
  State<PhotoFrameAdjustScreen> createState() => _PhotoFrameAdjustScreenState();
}

class _PhotoFrameAdjustScreenState extends State<PhotoFrameAdjustScreen> {
  final _boundaryKey = GlobalKey();
  final _transform = TransformationController();

  String? _localSource;
  String? _localReference;
  Size? _imageSize;
  var _loading = true;
  var _saving = false;
  var _showGhost = true;
  var _scale = 1.0;
  String? _error;

  static const _aspect = 3 / 4;
  static const _outW = 768;
  static const _outH = 1024;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    try {
      final src = await resolveLocalPhotoPath(widget.sourcePath);
      String? ref;
      final r = (widget.referencePath ?? '').trim();
      if (r.isNotEmpty) {
        try {
          ref = await resolveLocalPhotoPath(r);
          if (!File(ref).existsSync()) ref = null;
        } catch (_) {
          ref = null;
        }
      }

      final bytes = await File(src).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();

      if (!mounted) return;
      setState(() {
        _localSource = src;
        _localReference = ref;
        _imageSize = size;
        _showGhost = ref != null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load photo';
      });
      debugPrint('[PhotoFrame] prepare failed: $e');
    }
  }

  void _onInteraction() {
    final s = _transform.value.getMaxScaleOnAxis();
    if ((s - _scale).abs() > 0.01) {
      setState(() => _scale = s);
    }
  }

  void _setScale(double next) {
    final clamped = next.clamp(1.0, 4.0);
    final current = _transform.value.getMaxScaleOnAxis().clamp(1.0, 4.0);
    if (current <= 0) return;
    final factor = clamped / current;
    final matrix = Matrix4.copy(_transform.value)..scaleByDouble(factor, factor, 1, 1);
    _transform.value = matrix;
    setState(() => _scale = clamped);
  }

  void _reset() {
    _transform.value = Matrix4.identity();
    setState(() => _scale = 1.0);
  }

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 24));
      final boundary = _boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Missing frame boundary');

      final pixelRatio = (_outW / boundary.size.width).clamp(2.0, 4.0);
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) throw StateError('Empty frame capture');

      final pngBytes = byteData.buffer.asUint8List();
      final decoded = img.decodeImage(pngBytes);
      if (decoded == null) throw StateError('Could not decode framed image');
      final resized = img.copyResize(
        decoded,
        width: _outW,
        height: _outH,
        interpolation: img.Interpolation.linear,
      );
      final jpgBytes = img.encodeJpg(resized, quality: 92);

      // Prefer app documents; fall back to temp if path_provider FFI fails on iOS.
      final out = await _writeFramedJpg(jpgBytes);

      if (!mounted) return;
      Navigator.of(context).pop(out.path);
    } catch (e, st) {
      debugPrint('[PhotoFrame] confirm failed: $e\n$st');
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save framing. Try again.')),
        );
      }
    }
  }

  Future<File> _writeFramedJpg(List<int> jpgBytes) async {
    final name = 'frame_${const Uuid().v4()}.jpg';
    try {
      final persisted = await persistPhotoBytes(jpgBytes, fileName: name);
      return File(persisted);
    } catch (e) {
      debugPrint('[PhotoFrame] persistPhotoBytes failed, using temp: $e');
      final out = File('${Directory.systemTemp.path}/$name');
      await out.writeAsBytes(jpgBytes, flush: true);
      return out;
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final sf = GoogleFonts.urbanist();
    final hasGhost = (_localReference ?? '').isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          SizedBox(height: top + 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        'Frame ${widget.label}',
                        style: sf.copyWith(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Drag to move · pinch to zoom',
                        style: sf.copyWith(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: (_loading || _saving || _localSource == null) ? null : _confirm,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          'Done',
                          style: sf.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Colors.white54))
                : _error != null
                    ? Center(
                        child: Text(_error!, style: sf.copyWith(color: Colors.white70)),
                      )
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: AspectRatio(
                            aspectRatio: _aspect,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    blurRadius: 28,
                                    offset: const Offset(0, 12),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(17),
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    return _FrameViewport(
                                      boundaryKey: _boundaryKey,
                                      transform: _transform,
                                      onInteraction: _onInteraction,
                                      frameW: constraints.maxWidth,
                                      frameH: constraints.maxHeight,
                                      imageSize: _imageSize!,
                                      sourcePath: _localSource!,
                                      referencePath: _showGhost ? _localReference : null,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + bottom),
            child: Column(
              children: [
                if (hasGhost)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.compare_rounded,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Show other photo as guide',
                            style: sf.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: _showGhost,
                          activeTrackColor: Colors.white54,
                          onChanged: (v) => setState(() => _showGhost = v),
                        ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Text(
                      'Zoom',
                      style: sf.copyWith(fontSize: 12, color: Colors.white54),
                    ),
                    Expanded(
                      child: Slider(
                        value: _scale.clamp(1.0, 4.0),
                        min: 1,
                        max: 4,
                        onChanged: _loading ? null : _setScale,
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    TextButton(
                      onPressed: _loading ? null : _reset,
                      child: Text(
                        'Reset',
                        style: sf.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  hasGhost
                      ? 'Line up the same spot with the faint guide — face or body.'
                      : 'Use the same zoom and position for Before and After.',
                  textAlign: TextAlign.center,
                  style: sf.copyWith(fontSize: 12, color: Colors.white.withValues(alpha: 0.45), height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FrameViewport extends StatelessWidget {
  const _FrameViewport({
    required this.boundaryKey,
    required this.transform,
    required this.onInteraction,
    required this.frameW,
    required this.frameH,
    required this.imageSize,
    required this.sourcePath,
    this.referencePath,
  });

  final GlobalKey boundaryKey;
  final TransformationController transform;
  final VoidCallback onInteraction;
  final double frameW;
  final double frameH;
  final Size imageSize;
  final String sourcePath;
  final String? referencePath;

  Size _coverSize(Size img, double fw, double fh) {
    final imgAspect = img.width / img.height;
    final frameAspect = fw / fh;
    if (imgAspect > frameAspect) {
      final h = fh;
      return Size(h * imgAspect, h);
    }
    final w = fw;
    return Size(w, w / imgAspect);
  }

  @override
  Widget build(BuildContext context) {
    final cover = _coverSize(imageSize, frameW, frameH);
    final ref = (referencePath ?? '').trim();
    final origin = Offset((frameW - cover.width) / 2, (frameH - cover.height) / 2);

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Capture only the adjustable photo — never bake the ghost guide in.
          RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: Colors.black,
              child: ClipRect(
                child: InteractiveViewer(
                  transformationController: transform,
                  constrained: false,
                  alignment: Alignment.center,
                  boundaryMargin: EdgeInsets.symmetric(
                    horizontal: cover.width,
                    vertical: cover.height,
                  ),
                  minScale: 1,
                  maxScale: 4,
                  onInteractionUpdate: (_) => onInteraction(),
                  onInteractionEnd: (_) => onInteraction(),
                  child: Transform.translate(
                    offset: origin,
                    child: SizedBox(
                      width: cover.width,
                      height: cover.height,
                      child: Image.file(
                        File(sourcePath),
                        fit: BoxFit.cover,
                        width: cover.width,
                        height: cover.height,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (ref.isNotEmpty)
            IgnorePointer(
              child: Opacity(
                opacity: 0.34,
                child: Image.file(
                  File(ref),
                  fit: BoxFit.cover,
                  width: frameW,
                  height: frameH,
                ),
              ),
            ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: frameW * 0.72,
                height: 1,
                color: Colors.white.withValues(alpha: 0.22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
