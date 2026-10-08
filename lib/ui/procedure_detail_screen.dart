import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../data/checkpoint.dart';
import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/photo_processor.dart';
import '../services/progress_share_service.dart';
import 'add_checkpoint_screen.dart';
import 'delete_checkpoint_sheet.dart';
import 'delete_procedure_sheet.dart';
import 'formatters.dart';
import 'photo_storage.dart';
import 'photo_frame_adjust_screen.dart';
import 'procedure_ba_capture_screen.dart';
import 'procedure_form_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/black_photo_source_sheet.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

enum _DetailTab { milestones, about }

class ProcedureDetailScreen extends StatefulWidget {
  const ProcedureDetailScreen({
    super.key,
    required this.repo,
    required this.procedureId,
  });

  final ProcedureRepository repo;
  final String procedureId;

  @override
  State<ProcedureDetailScreen> createState() => _ProcedureDetailScreenState();
}

class _ProcedureDetailScreenState extends State<ProcedureDetailScreen> {
  final ImagePicker _photoPicker = ImagePicker();

  String _combinedNotes(Procedure p) {
    final n = (p.notes ?? '').trim();
    final a = (p.aftercare ?? '').trim();
    if (n.isEmpty && a.isEmpty) return '';
    if (n.isEmpty) return a;
    if (a.isEmpty) return n;
    return '$n\n\n$a';
  }

  String _productLine(Procedure p) {
    final prod = (p.product ?? '').trim();
    if (prod.isEmpty && p.volumeMl == null) return '—';
    if (prod.isNotEmpty && p.volumeMl != null) {
      final v = p.volumeMl!;
      final vs = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
      return '$prod / $vs ml';
    }
    if (p.volumeMl != null) {
      final v = p.volumeMl!;
      return v == v.roundToDouble() ? '${v.toInt()} ml' : '${v.toStringAsFixed(1)} ml';
    }
    return prod;
  }

  String _shortRedo(Procedure p) {
    if (p.redoAfterValue != null && (p.redoAfterUnit ?? '').isNotEmpty) {
      final v = p.redoAfterValue!;
      return switch (p.redoAfterUnit!) {
        'days' => '${v}d',
        'weeks' => '${v}w',
        'months' => '${v}mo',
        'years' => '${v}y',
        _ => '$v',
      };
    }
    return '—';
  }

  Future<void> _edit(Procedure procedure) async {
    final latest = widget.repo.getDoneById(procedure.id) ?? procedure;
    final updated = await Navigator.of(context).push<Procedure>(
      MaterialPageRoute(builder: (_) => ProcedureFormScreen(repo: widget.repo, existing: latest)),
    );
    if (updated != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Updated')));
    }
  }

  Future<void> _confirmDelete(Procedure procedure) async {
    final ok = await showDeleteProcedureSheet(context, procedure: procedure);
    if (ok == true && mounted) {
      await widget.repo.deleteDone(procedure.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<ImageSource?> _choosePhotoSource(bool isBefore) {
    return showBlackPhotoSourceSheet(context, isBefore: isBefore);
  }

  Future<void> _addBeforeAfterPhoto(Procedure procedure, {required bool isBefore}) async {
    final source = await _choosePhotoSource(isBefore);
    if (source == null || !mounted) return;

    final other = isBefore ? procedure.afterPhotoPath : procedure.beforePhotoPath;

    late final String rawPath;
    if (source == ImageSource.camera) {
      final captured = await openProcedureBaCapture(
        context,
        label: isBefore ? 'Before' : 'After',
        referencePath: other,
      );
      if (captured == null || !mounted) return;
      rawPath = captured;
    } else {
      final picked = await _photoPicker.pickImage(source: source, imageQuality: 88);
      if (picked == null || !mounted) return;
      rawPath = picked.path;
    }

    final framed = await openPhotoFrameAdjust(
      context,
      sourcePath: rawPath,
      label: isBefore ? 'Before' : 'After',
      referencePath: other,
    );
    if (framed == null || !mounted) return;

    var local = await persistPhotoPath(framed);
    try {
      local = await resizePickForStudioMaxSide(local);
    } catch (e) {
      debugPrint('[ProcedureDetail] pick resize skipped: $e');
    }

    final withLocal = isBefore
        ? procedure.copyWith(beforePhotoPath: local)
        : procedure.copyWith(afterPhotoPath: local);
    await widget.repo.upsertDone(withLocal);

    final stored = await persistAndUploadPhotoPath(local);
    if (!isRemoteUrl(stored) || !mounted) return;
    try {
      await precacheImage(NetworkImage(stored), context);
    } catch (e) {
      debugPrint('[ProcedureDetail] precache upload URL failed: $e');
      return;
    }
    if (!mounted) return;
    final latest = widget.repo.getDoneById(procedure.id) ?? withLocal;
    final withUrl = isBefore
        ? latest.copyWith(beforePhotoPath: stored)
        : latest.copyWith(afterPhotoPath: stored);
    await widget.repo.upsertDone(withUrl);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, _) {
        final procedure = widget.repo.getDoneById(widget.procedureId);
        if (procedure == null) {
          return const Stack(
            children: [
              Step2WarmBackground(),
              Scaffold(
                backgroundColor: Colors.transparent,
                body: Center(child: Text('Not found')),
              ),
            ],
          );
        }

        return _ProcedureJourneyBody(
          repo: widget.repo,
          procedure: procedure,
          onEdit: _edit,
          onConfirmDelete: _confirmDelete,
          onAddBeforeAfterPhoto: _addBeforeAfterPhoto,
          productLine: _productLine,
          shortRedo: _shortRedo,
          combinedNotes: _combinedNotes,
        );
      },
    );
  }
}

class _ProcedureJourneyBody extends StatefulWidget {
  const _ProcedureJourneyBody({
    required this.repo,
    required this.procedure,
    required this.onEdit,
    required this.onConfirmDelete,
    required this.onAddBeforeAfterPhoto,
    required this.productLine,
    required this.shortRedo,
    required this.combinedNotes,
  });

  final ProcedureRepository repo;
  final Procedure procedure;
  final Future<void> Function(Procedure procedure) onEdit;
  final Future<void> Function(Procedure procedure) onConfirmDelete;
  final Future<void> Function(Procedure procedure, {required bool isBefore}) onAddBeforeAfterPhoto;
  final String Function(Procedure p) productLine;
  final String Function(Procedure p) shortRedo;
  final String Function(Procedure p) combinedNotes;

  @override
  State<_ProcedureJourneyBody> createState() => _ProcedureJourneyBodyState();
}

class _ProcedureJourneyBodyState extends State<_ProcedureJourneyBody> {
  _DetailTab _tab = _DetailTab.milestones;
  double _slider = 0.5;
  bool _useSlider = true;

  /// `treatment` = original After; otherwise a checkpoint id.
  String _selectedMilestoneKey = 'treatment';
  String? _previewAfterPath;

  static const _liveTag = 'community_live';

  String get _zoneSubtitle {
    if (widget.procedure.zones.isNotEmpty) return widget.procedure.zones.first;
    final cat = (widget.procedure.category ?? '').trim();
    return cat.isEmpty ? 'Procedure' : cat;
  }

  bool get _postLive => widget.procedure.tags.contains(_liveTag);

  Future<void> _setPostLive(bool value) async {
    final tags = List<String>.from(widget.procedure.tags);
    if (value) {
      if (!tags.contains(_liveTag)) tags.add(_liveTag);
    } else {
      tags.remove(_liveTag);
    }
    await widget.repo.upsertDone(widget.procedure.copyWith(tags: tags));
  }

  void _selectMilestone({required String key, String? photoPath}) {
    final path = (photoPath ?? '').trim();
    setState(() {
      _selectedMilestoneKey = key;
      _previewAfterPath = path.isEmpty ? null : path;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final p = widget.procedure;
    final originalAfter = (p.afterPhotoPath ?? '').trim();

    return StreamBuilder<List<Checkpoint>>(
      stream: widget.repo.checkpointsStream(p.id),
      builder: (context, snap) {
        final checkpoints = snap.data ?? const <Checkpoint>[];

        // Hero After: selected milestone photo, else the original After.
        final preview = (_previewAfterPath ?? '').trim();
        final afterForHero = preview.isNotEmpty
            ? preview
            : (originalAfter.isEmpty ? null : originalAfter);
        final heroProcedure = afterForHero == null
            ? p
            : p.copyWith(afterPhotoPath: afterForHero);

        return Stack(
          children: [
            const Step2WarmBackground(),
            Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: Column(
                              children: [
                                _JourneyHeader(
                                  title: p.title,
                                  subtitle: _zoneSubtitle,
                                  onBack: () => Navigator.of(context).maybePop(),
                                  onEdit: () => widget.onEdit(p),
                                ),
                                const SizedBox(height: 14),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: _BeforeAfterHero(
                            procedure: heroProcedure,
                            useSlider: _useSlider,
                            onUseSliderChanged: (v) => setState(() => _useSlider = v),
                            slider: _slider,
                            onSlider: (v) => setState(() => _slider = v),
                            onTapBefore: () => widget.onAddBeforeAfterPhoto(p, isBefore: true),
                            onTapAfter: () => widget.onAddBeforeAfterPhoto(p, isBefore: false),
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                          child: Column(
                            children: [
                              _JourneyTabBar(
                                tab: _tab,
                                onChanged: (t) => setState(() => _tab = t),
                              ),
                              if (_tab == _DetailTab.milestones) ...[
                                const SizedBox(height: 12),
                                _PostLiveSwitcher(
                                  value: _postLive,
                                  onChanged: _setPostLive,
                                ),
                              ],
                              const SizedBox(height: 14),
                            ],
                          ),
                        ),
                      ),
                      if (_tab == _DetailTab.milestones)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          sliver: SliverToBoxAdapter(
                            child: _MilestonesTimeline(
                              repo: widget.repo,
                              procedure: p,
                              checkpoints: checkpoints,
                              selectedKey: _selectedMilestoneKey,
                              onSelect: _selectMilestone,
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          sliver: SliverToBoxAdapter(
                            child: _AboutProcedurePanel(
                              procedure: p,
                              productLine: widget.productLine(p),
                              shortRedo: widget.shortRedo(p),
                              notes: widget.combinedNotes(p),
                              onDelete: () => widget.onConfirmDelete(p),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(child: SizedBox(height: bottomPad + 100)),
                    ],
                  ),
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: bottomPad + 16,
                    child: _ShareProgressFab(
                      onShare: () async {
                        final origin = ProgressShareService.originFromContext(context);
                        try {
                          await ProgressShareService.instance.shareProcedure(
                            procedure: p,
                            areaFallback: _zoneSubtitle,
                            sharePositionOrigin: origin,
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                e is StateError
                                    ? e.message
                                    : 'Could not share right now. Try again.',
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _JourneyHeader extends StatelessWidget {
  const _JourneyHeader({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onEdit,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SoftIconButton(icon: Icons.chevron_left_rounded, onTap: onBack),
        Expanded(
          child: Column(
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: ProcedureSelectionTheme.ink,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: ProcedureSelectionTheme.muted,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 42,
          child: TextButton(
            onPressed: onEdit,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: ProcedureSelectionTheme.ink,
            ),
            child: Text(
              'Edit',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SoftIconButton extends StatelessWidget {
  const _SoftIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  static const _size = 42.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _size,
      height: _size,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          splashColor: Colors.white.withValues(alpha: 0.18),
          highlightColor: Colors.white.withValues(alpha: 0.10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: ProcedureGlassDecorations.shadows(compact: true),
            ),
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.72),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.88),
                          Colors.white.withValues(alpha: 0.55),
                        ],
                      ),
                    ),
                  ),
                  const CustomPaint(painter: _GlassCircleRimPainter()),
                  Center(
                    child: Icon(
                      icon,
                      size: 22,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassCircleRimPainter extends CustomPainter {
  const _GlassCircleRimPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 0.75;
    final oval = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.white.withValues(alpha: 0.42),
    );

    canvas.drawArc(
      oval,
      -math.pi * 0.82,
      math.pi * 0.52,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35
        ..color = Colors.white.withValues(alpha: 0.78)
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawArc(
      oval,
      math.pi * 0.32,
      math.pi * 0.48,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.black.withValues(alpha: 0.22)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BeforeAfterHero extends StatefulWidget {
  const _BeforeAfterHero({
    required this.procedure,
    required this.useSlider,
    required this.onUseSliderChanged,
    required this.slider,
    required this.onSlider,
    required this.onTapBefore,
    required this.onTapAfter,
  });

  final Procedure procedure;
  final bool useSlider;
  final ValueChanged<bool> onUseSliderChanged;
  final double slider;
  final ValueChanged<double> onSlider;
  final VoidCallback onTapBefore;
  final VoidCallback onTapAfter;

  @override
  State<_BeforeAfterHero> createState() => _BeforeAfterHeroState();
}

class _BeforeAfterHeroState extends State<_BeforeAfterHero> {
  String? get _beforePath => widget.procedure.beforePhotoPath;
  String? get _afterPath => widget.procedure.afterPhotoPath;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final screenH = MediaQuery.sizeOf(context).height;
        // Match form 3:4 crop so the full framed photo shows (not re-cropped).
        final h = math.min(w * 4 / 3, screenH * 0.52);
        final split = (widget.slider.clamp(0.08, 0.92)) * w;

        if (!widget.useSlider) {
          // Side-by-side: two real 3:4 tiles so each photo stays readable
          // (splitting one tall frame made each half a thin strip).
          return Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _SidePhotoCard(
                      path: _beforePath,
                      label: 'BEFORE',
                      placeholderLabel: 'Add before',
                      fallback: const Color(0xFF8A8A93).withValues(alpha: 0.28),
                      onTap: widget.onTapBefore,
                      alignLabelLeft: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SidePhotoCard(
                      path: _afterPath,
                      label: 'AFTER',
                      placeholderLabel: 'Add after',
                      fallback: const Color(0xFF1A1A1F).withValues(alpha: 0.22),
                      onTap: widget.onTapAfter,
                      alignLabelLeft: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _GlassPill(
                        icon: Icons.water_drop_outlined,
                        label: widget.procedure.title,
                      ),
                    ),
                  ),
                  _CompareModeToggle(
                    useSlider: widget.useSlider,
                    onChanged: widget.onUseSliderChanged,
                  ),
                ],
              ),
            ],
          );
        }

        return ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: widget.onTapAfter,
                    child: _ZoomedPhotoFill(
                      path: _afterPath,
                      placeholderLabel: 'Add after',
                      fallback: const Color(0xFF1A1A1F).withValues(alpha: 0.22),
                      zoom: 1,
                      focal: Offset.zero,
                      frameW: w,
                      frameH: h,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: split,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      maxWidth: w,
                      minWidth: w,
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: GestureDetector(
                          onTap: widget.onTapBefore,
                          child: _ZoomedPhotoFill(
                            path: _beforePath,
                            placeholderLabel: 'Add before',
                            fallback: const Color(0xFF8A8A93).withValues(alpha: 0.28),
                            zoom: 1,
                            focal: Offset.zero,
                            frameW: w,
                            frameH: h,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: split - 0.75,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 1.5, color: Colors.white.withValues(alpha: 0.85)),
                ),
                Positioned(
                  left: split - 18,
                  top: (h / 2) - 18,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      widget.onSlider(((widget.slider * w) + d.delta.dx) / w);
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chevron_left_rounded,
                            size: 14,
                            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 14,
                            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Positioned(
                  top: 12,
                  left: 12,
                  child: _BaTag(label: 'BEFORE', dark: true),
                ),
                const Positioned(
                  top: 12,
                  right: 12,
                  child: _BaTag(label: 'AFTER', dark: true),
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _GlassPill(
                    icon: Icons.water_drop_outlined,
                    label: widget.procedure.title,
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _CompareModeToggle(
                    useSlider: widget.useSlider,
                    onChanged: widget.onUseSliderChanged,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SidePhotoCard extends StatelessWidget {
  const _SidePhotoCard({
    required this.path,
    required this.label,
    required this.placeholderLabel,
    required this.fallback,
    required this.onTap,
    required this.alignLabelLeft,
  });

  final String? path;
  final String label;
  final String placeholderLabel;
  final Color fallback;
  final VoidCallback onTap;
  final bool alignLabelLeft;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, c) => _ZoomedPhotoFill(
                  path: path,
                  placeholderLabel: placeholderLabel,
                  fallback: fallback,
                  zoom: 1,
                  focal: Offset.zero,
                  frameW: c.maxWidth,
                  frameH: c.maxHeight,
                ),
              ),
              Positioned(
                top: 10,
                left: alignLabelLeft ? 10 : null,
                right: alignLabelLeft ? null : 10,
                child: _BaTag(label: label, dark: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompareModeToggle extends StatelessWidget {
  const _CompareModeToggle({
    required this.useSlider,
    required this.onChanged,
  });

  final bool useSlider;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _chip(
            icon: Icons.swap_horiz_rounded,
            selected: useSlider,
            onTap: () => onChanged(true),
          ),
          _chip(
            icon: Icons.view_column_outlined,
            selected: !useSlider,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          icon,
          size: 14,
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _BaTag extends StatelessWidget {
  const _BaTag({required this.label, required this.dark});

  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: dark
            ? Colors.black.withValues(alpha: 0.55)
            : Colors.white.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: dark ? Colors.white : ProcedureSelectionTheme.ink,
        ),
      ),
    );
  }
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomedPhotoFill extends StatelessWidget {
  const _ZoomedPhotoFill({
    required this.path,
    required this.placeholderLabel,
    required this.fallback,
    required this.zoom,
    required this.focal,
    required this.frameW,
    required this.frameH,
  });

  final String? path;
  final String placeholderLabel;
  final Color fallback;
  final double zoom;
  final Offset focal;
  final double frameW;
  final double frameH;

  @override
  Widget build(BuildContext context) {
    final p = (path ?? '').trim();
    final canShow = p.isNotEmpty && (isRemoteUrl(p) || File(p).existsSync());
    if (!canShow) {
      return ColoredBox(
        color: fallback,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_a_photo_outlined, size: 22, color: Colors.white.withValues(alpha: 0.7)),
              const SizedBox(height: 6),
              Text(
                placeholderLabel,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final z = zoom.clamp(1.0, 2.8);
    final childW = frameW * z;
    final childH = frameH * z;
    final image = isRemoteUrl(p)
        ? Image.network(
            p,
            fit: BoxFit.cover,
            width: childW,
            height: childH,
            alignment: Alignment(focal.dx, focal.dy),
          )
        : Image.file(
            File(p),
            fit: BoxFit.cover,
            width: childW,
            height: childH,
            alignment: Alignment(focal.dx, focal.dy),
          );

    // Larger child + clip = zoom in. Focal shifts which region stays centered.
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment(focal.dx, focal.dy),
        minWidth: childW,
        maxWidth: childW,
        minHeight: childH,
        maxHeight: childH,
        child: SizedBox(width: childW, height: childH, child: image),
      ),
    );
  }
}

class _JourneyTabBar extends StatelessWidget {
  const _JourneyTabBar({required this.tab, required this.onChanged});

  final _DetailTab tab;
  final ValueChanged<_DetailTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _TabPill(
                label: 'Milestones',
                selected: tab == _DetailTab.milestones,
                onTap: () => onChanged(_DetailTab.milestones),
              ),
            ),
            Expanded(
              child: _TabPill(
                label: 'About procedure',
                selected: tab == _DetailTab.about,
                onTap: () => onChanged(_DetailTab.about),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  const _TabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? ProcedureSelectionTheme.ink : ProcedureSelectionTheme.muted,
          ),
        ),
      ),
    );
  }
}

class _MilestoneItem {
  const _MilestoneItem({
    required this.key,
    required this.timeLabel,
    required this.title,
    required this.body,
    required this.date,
    this.photoPath,
    this.checkpoint,
    this.isTreatmentDay = false,
  });

  final String key;
  final String timeLabel;
  final String title;
  final String body;
  final DateTime date;
  final String? photoPath;
  final Checkpoint? checkpoint;
  final bool isTreatmentDay;
}

class _MilestonesTimeline extends StatelessWidget {
  const _MilestonesTimeline({
    required this.repo,
    required this.procedure,
    required this.checkpoints,
    required this.selectedKey,
    required this.onSelect,
  });

  final ProcedureRepository repo;
  final Procedure procedure;
  final List<Checkpoint> checkpoints;
  final String selectedKey;
  final void Function({required String key, String? photoPath}) onSelect;

  List<_MilestoneItem> _buildItems(List<Checkpoint> checkpoints) {
    if (checkpoints.isEmpty && (procedure.afterPhotoPath ?? '').trim().isEmpty) {
      return const [];
    }

    final procedureDay = DateTime(
      procedure.date.year,
      procedure.date.month,
      procedure.date.day,
    );

    return [
      _MilestoneItem(
        key: 'treatment',
        timeLabel: 'Day 0',
        title: 'Treatment day',
        body: 'Your after photo from the procedure day.',
        date: procedureDay,
        photoPath: procedure.afterPhotoPath,
        isTreatmentDay: true,
      ),
      for (final c in [...checkpoints]..sort((a, b) => b.date.compareTo(a.date)))
        _MilestoneItem(
          key: c.id,
          timeLabel: _timeLabelFor(c),
          title: c.title.trim().isEmpty ? 'Checkpoint' : c.title.trim(),
          body: (c.note ?? '').trim().isEmpty ? 'Checkpoint logged.' : c.note!.trim(),
          date: c.date,
          photoPath: c.photoPath,
          checkpoint: c,
        ),
    ];
  }

  String _timeLabelFor(Checkpoint c) {
    final key = c.optionKey.trim().toLowerCase();
    return switch (key) {
      'treatment' => 'Day 0',
      'd1' => 'Day 1',
      'd3' => 'Day 3',
      'w1' => 'Day 7',
      'm1' => '1 Month',
      'm3' => '3 Months',
      'm6' => '6 Months',
      'y1' => '1 Year',
      _ => formatDate(c.date),
    };
  }

  void _openAdd(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddCheckpointScreen(
          repo: repo,
          procedureId: procedure.id,
          procedureTitle: procedure.title,
          procedureDate: procedure.date,
          referencePhotoPath: (procedure.afterPhotoPath ?? '').trim().isNotEmpty
              ? procedure.afterPhotoPath
              : procedure.beforePhotoPath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems(checkpoints);

    if (items.isEmpty) {
      return _EmptyCheckpointsCard(onAdd: () => _openAdd(context));
    }

    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          _MilestoneRow(
            item: items[i],
            isFirst: i == 0,
            isLast: i == items.length - 1,
            selected: selectedKey == items[i].key,
            onTap: () => onSelect(key: items[i].key, photoPath: items[i].photoPath),
            onLongPress: items[i].checkpoint == null
                ? null
                : () async {
                    final c = items[i].checkpoint!;
                    final confirm = await showDeleteCheckpointSheet(context, checkpoint: c);
                    if (confirm != true) return;
                    try {
                      await repo.deleteCheckpoint(procedure.id, c.id);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Could not delete checkpoint.')),
                        );
                      }
                    }
                  },
          ),
          if (i < items.length - 1) const SizedBox(height: 10),
        ],
        const SizedBox(height: 14),
        _AddCheckpointButton(onTap: () => _openAdd(context)),
      ],
    );
  }
}

class _EmptyCheckpointsCard extends StatelessWidget {
  const _EmptyCheckpointsCard({required this.onAdd});

  final VoidCallback onAdd;

  static final _radius = BorderRadius.circular(20);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onAdd,
        borderRadius: _radius,
        child: ProcedureGlassSurface(
          borderRadius: _radius,
          compact: true,
          illuminated: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 22),
            child: Column(
              children: [
                ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(14),
                  compact: true,
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.add_rounded,
                      size: 24,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Add checkpoint',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Track your recovery milestones as you heal.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: ProcedureSelectionTheme.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  const _MilestoneRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final _MilestoneItem item;
  final bool isFirst;
  final bool isLast;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final nodeColor = item.isTreatmentDay
        ? const Color(0xFFD0D0D4)
        : (isFirst || item.checkpoint != null)
            ? ProcedureSelectionTheme.ink
            : Colors.transparent;
    final nodeBorder = item.isTreatmentDay
        ? Colors.transparent
        : ProcedureSelectionTheme.ink.withValues(alpha: 0.35);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: 1.5,
                    color: isFirst ? Colors.transparent : const Color(0xFFD8D8DC),
                  ),
                ),
                Container(
                  width: item.isTreatmentDay ? 12 : 10,
                  height: item.isTreatmentDay ? 12 : 10,
                  decoration: BoxDecoration(
                    color: selected ? ProcedureSelectionTheme.ink : nodeColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? ProcedureSelectionTheme.ink
                          : nodeBorder,
                      width: 1.5,
                    ),
                    boxShadow: item.isTreatmentDay || selected
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.10),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                ),
                Expanded(
                  child: Container(
                    width: 1.5,
                    color: isLast ? Colors.transparent : const Color(0xFFD8D8DC),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                borderRadius: BorderRadius.circular(18),
                child: ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(18),
                  compact: true,
                  illuminated: selected,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                    child: Row(
                      children: [
                        ProcedureGlassSurface(
                          borderRadius: BorderRadius.circular(11),
                          compact: true,
                          child: SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              Icons.calendar_today_rounded,
                              size: 15,
                              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.timeLabel,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                item.body,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w500,
                                  color: ProcedureSelectionTheme.muted,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _MilestoneThumb(path: item.photoPath),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestoneThumb extends StatelessWidget {
  const _MilestoneThumb({this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final p = (path ?? '').trim();
    final canShow = p.isNotEmpty && (isRemoteUrl(p) || File(p).existsSync());
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 48,
        height: 48,
        child: canShow
            ? (isRemoteUrl(p)
                ? Image.network(p, fit: BoxFit.cover)
                : Image.file(File(p), fit: BoxFit.cover))
            : ColoredBox(
                color: const Color(0xFFE4E4E8),
                child: Icon(
                  Icons.image_outlined,
                  size: 18,
                  color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
                ),
              ),
      ),
    );
  }
}

class _AddCheckpointButton extends StatelessWidget {
  const _AddCheckpointButton({required this.onTap});

  final VoidCallback onTap;

  static final _radius = BorderRadius.circular(16);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: _radius,
        child: ProcedureGlassSurface(
          borderRadius: _radius,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, size: 18, color: ProcedureSelectionTheme.ink),
                const SizedBox(width: 6),
                Text(
                  'Add checkpoint',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AboutProcedurePanel extends StatelessWidget {
  const _AboutProcedurePanel({
    required this.procedure,
    required this.productLine,
    required this.shortRedo,
    required this.notes,
    required this.onDelete,
  });

  final Procedure procedure;
  final String productLine;
  final String shortRedo;
  final String notes;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cost = procedure.cost != null
        ? formatMoney(procedure.cost!, procedure.currency)
        : '—';
    final painKey = (procedure.painLevel ?? '').trim().toLowerCase();
    final hasPain = painKey == 'none' ||
        painKey == 'mild' ||
        painKey == 'moderate' ||
        painKey == 'intense';

    return Column(
      children: [
        _SoftCard(
          child: Column(
            children: [
              _AboutRow(label: 'Doctor', value: procedure.practitioner ?? '—'),
              _AboutRow(label: 'Clinic', value: procedure.clinic ?? '—'),
              _AboutRow(label: 'Date', value: formatDate(procedure.date)),
              _AboutRow(label: 'Product', value: productLine),
              _AboutRow(label: 'Cost', value: cost),
              _AboutRow(label: 'Redo in', value: shortRedo, isLast: true),
            ],
          ),
        ),
        if (procedure.zones.isNotEmpty) ...[
          const SizedBox(height: 10),
          _SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Treatment zones',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final z in procedure.zones)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          z,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        if (hasPain) ...[
          const SizedBox(height: 10),
          _SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pain during treatment',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 10),
                _PainLevelDisplay(value: painKey),
              ],
            ),
          ),
        ],
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          _SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Doctor's note",
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  notes,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: ProcedureSelectionTheme.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Material(
          color: const Color(0xFFE85C5C).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFFE85C5C)),
                  const SizedBox(width: 8),
                  Text(
                    'Delete procedure',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFFE85C5C),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Read-only pain chips — same layout as the form `_PainRow` warm style.
class _PainLevelDisplay extends StatelessWidget {
  const _PainLevelDisplay({required this.value});

  final String value;

  static const _options = <(String key, String emoji, String label)>[
    ('none', '😌', 'None'),
    ('mild', '😐', 'Mild'),
    ('moderate', '😬', 'Moderate'),
    ('intense', '😤', 'Intense'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _options.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(10),
              selected: value == _options[i].$1,
              compact: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_options[i].$2, style: const TextStyle(fontSize: 18)),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (value == _options[i].$1) ...[
                          Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: Colors.white.withValues(alpha: 0.92),
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          _options[i].$3,
                          style: ProcedureSelectionTypography.chip(
                            size: 9,
                            weight: FontWeight.w600,
                            color: value == _options[i].$1
                                ? Colors.white
                                : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SoftCard extends StatelessWidget {
  const _SoftCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(18),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: child,
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Post live switcher — community visibility toggle.
class _PostLiveSwitcher extends StatelessWidget {
  const _PostLiveSwitcher({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  static final _radius = BorderRadius.circular(22);

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: _radius,
      compact: true,
      illuminated: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(12),
              compact: true,
              child: const SizedBox(
                width: 36,
                height: 36,
                child: Icon(
                  Icons.visibility_outlined,
                  size: 18,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Post live',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ProcedureSelectionTheme.ink,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Your result will be visible on the community.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: ProcedureSelectionTheme.muted,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: ProcedureSelectionTheme.buttonPrimary,
              activeThumbColor: Colors.white,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating share card — matches the light share-progress mockup.
class _ShareProgressFab extends StatelessWidget {
  const _ShareProgressFab({required this.onShare});

  final VoidCallback onShare;

  static final _radius = BorderRadius.circular(28);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.ink,
        borderRadius: _radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const SizedBox(
                width: 42,
                height: 42,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Share your progress',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Inspire others on their journey.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.65),
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: onShare,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Share result',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 14,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
