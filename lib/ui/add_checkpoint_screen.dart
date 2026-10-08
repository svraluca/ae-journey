import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/checkpoint.dart';
import '../data/procedure_repository.dart';
import '../services/photo_processor.dart';
import 'photo_frame_adjust_screen.dart';
import 'photo_storage.dart';
import 'procedure_ba_capture_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/black_photo_source_sheet.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

class AddCheckpointScreen extends StatefulWidget {
  const AddCheckpointScreen({
    super.key,
    required this.repo,
    required this.procedureId,
    required this.procedureTitle,
    required this.procedureDate,
    this.referencePhotoPath,
  });

  final ProcedureRepository repo;
  final String procedureId;
  final String procedureTitle;
  final DateTime procedureDate;
  /// Optional before/after photo used as a framing ghost (same as BA upload).
  final String? referencePhotoPath;

  @override
  State<AddCheckpointScreen> createState() => _AddCheckpointScreenState();
}

class _CheckpointOption {
  const _CheckpointOption({
    required this.key,
    required this.iconText,
    required this.title,
    required this.offsetDays,
  });

  final String key;
  final String iconText;
  final String title;
  final int offsetDays;
}

class _AddCheckpointScreenState extends State<AddCheckpointScreen> {
  static const _options = <_CheckpointOption>[
    _CheckpointOption(key: 'treatment', iconText: '✓', title: 'Treatment day', offsetDays: 0),
    _CheckpointOption(key: 'd1', iconText: '1d', title: 'Day 1', offsetDays: 1),
    _CheckpointOption(key: 'd3', iconText: '3d', title: 'Day 3', offsetDays: 3),
    _CheckpointOption(key: 'w1', iconText: '1w', title: '1 Week', offsetDays: 7),
    _CheckpointOption(key: 'm1', iconText: '1m', title: '1 Month', offsetDays: 31),
    _CheckpointOption(key: 'm3', iconText: '3m', title: '3 Months', offsetDays: 92),
    _CheckpointOption(key: 'm6', iconText: '6m', title: '6 Months', offsetDays: 184),
    _CheckpointOption(key: 'y1', iconText: '1y', title: '1 Year', offsetDays: 365),
  ];

  String _selectedKey = 'w1';
  String _mood = 'good'; // bad | okay | good | love
  String? _photoPath;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _noteCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  DateTime _at(int offsetDays) {
    final d = widget.procedureDate.add(Duration(days: offsetDays));
    return DateTime(d.year, d.month, d.day);
  }

  String _fmt(DateTime d) {
    const mos = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${mos[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _weekdayDate(DateTime d) {
    const wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
  }

  Future<void> _pickPhoto() async {
    // Same flow as procedure form / detail before-after:
    // black source sheet → in-app capture or gallery → 3:4 frame adjust → persist/upload.
    final source = await showBlackPhotoSourceSheet(
      context,
      title: 'Add progress photo',
      subtitle:
          'Match the same distance and angle as your before/after shots (face or body).',
    );
    if (source == null || !mounted) return;

    final reference = (widget.referencePhotoPath ?? '').trim();
    final refPath = reference.isEmpty ? null : reference;

    try {
      late final String rawPath;
      if (source == ImageSource.camera) {
        final captured = await openProcedureBaCapture(
          context,
          label: 'Progress',
          referencePath: refPath,
        );
        if (captured == null || !mounted) return;
        rawPath = captured;
      } else {
        final img = await ImagePicker().pickImage(source: source, imageQuality: 88);
        if (img == null || !mounted) return;
        rawPath = img.path;
      }

      final framed = await openPhotoFrameAdjust(
        context,
        sourcePath: rawPath,
        label: 'Progress',
        referencePath: refPath,
      );
      if (framed == null || !mounted) return;

      var local = await persistPhotoPath(framed);
      try {
        local = await resizePickForStudioMaxSide(local);
      } catch (e) {
        debugPrint('[AddCheckpoint] pick resize skipped: $e');
      }
      if (!mounted) return;
      setState(() => _photoPath = local);

      unawaited(
        persistAndUploadPhotoPath(local).then((stored) async {
          if (!isRemoteUrl(stored) || !mounted) return;
          try {
            await precacheImage(NetworkImage(stored), context);
          } catch (_) {}
          if (!mounted) return;
          setState(() => _photoPath = stored);
        }),
      );
    } on PlatformException catch (e) {
      debugPrint('[AddCheckpoint] pick cancelled: ${e.code} ${e.message}');
    } catch (e, st) {
      debugPrint('[AddCheckpoint] pick failed: $e\n$st');
    }
  }

  Future<void> _adjustPhoto() async {
    final path = (_photoPath ?? '').trim();
    if (path.isEmpty) return;
    final reference = (widget.referencePhotoPath ?? '').trim();
    try {
      final framed = await openPhotoFrameAdjust(
        context,
        sourcePath: path,
        label: 'Progress',
        referencePath: reference.isEmpty ? null : reference,
      );
      if (framed == null || !mounted) return;

      var local = await persistPhotoPath(framed);
      try {
        local = await resizePickForStudioMaxSide(local);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _photoPath = local);

      unawaited(
        persistAndUploadPhotoPath(local).then((stored) async {
          if (!isRemoteUrl(stored) || !mounted) return;
          try {
            await precacheImage(NetworkImage(stored), context);
          } catch (_) {}
          if (!mounted) return;
          setState(() => _photoPath = stored);
        }),
      );
    } catch (e, st) {
      debugPrint('[AddCheckpoint] adjust failed: $e\n$st');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final sel = _options.firstWhere((o) => o.key == _selectedKey);
    final date = _at(sel.offsetDays);
    final photo = (_photoPath ?? '').trim();

    final checkpoint = Checkpoint(
      optionKey: sel.key,
      title: '${sel.title} checkpoint',
      date: date,
      photoPath: photo.isEmpty ? null : photo,
      moodKey: _mood,
      note: (_noteCtrl.text).trim().isEmpty ? null : _noteCtrl.text.trim(),
    );

    try {
      await widget.repo.upsertCheckpoint(widget.procedureId, checkpoint);

      // Keep the procedure After photo intact; only upgrade this checkpoint's
      // local path to a remote URL once upload finishes.
      if (photo.isNotEmpty && !isRemoteUrl(photo)) {
        unawaited(
          persistAndUploadPhotoPath(photo).then((stored) async {
            if (!isRemoteUrl(stored)) return;
            await widget.repo.upsertCheckpoint(
              widget.procedureId,
              Checkpoint(
                id: checkpoint.id,
                optionKey: checkpoint.optionKey,
                title: checkpoint.title,
                date: checkpoint.date,
                photoPath: stored,
                moodKey: checkpoint.moodKey,
                note: checkpoint.note,
                createdAt: checkpoint.createdAt,
              ),
            );
          }),
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = e.code == 'permission-denied'
          ? 'Permission denied while saving checkpoint. Please deploy Firestore rules for your project.'
          : 'Could not save checkpoint. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save checkpoint. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sel = _options.firstWhere((o) => o.key == _selectedKey);
    final selDate = _at(sel.offsetDays);
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final procedureLabel = widget.procedureTitle.trim().isEmpty
        ? 'Procedure'
        : widget.procedureTitle.trim();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Step2WarmBackground(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      _GlassCircleButton(
                        icon: Icons.close_rounded,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          'Add checkpoint',
                          textAlign: TextAlign.center,
                          style: ProcedureSelectionTypography.display(
                            size: 16,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              ProcedureSelectionTheme.buttonPrimary.withValues(alpha: 0.42),
                          disabledForegroundColor: Colors.white.withValues(alpha: 0.78),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        child: Text(
                          _saving ? 'Saving…' : 'Save',
                          style: ProcedureSelectionTypography.chip(size: 12, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 28 + bottomPad),
                  children: [
                    ProcedureSectionLabel(_weekdayDate(DateTime.now())),
                    const SizedBox(height: 8),
                    Text(
                      procedureLabel,
                      style: ProcedureSelectionTypography.display(
                        size: 18,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Track your results at key recovery milestones.',
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 18),
                    ProcedureSelectionPanel(
                      title: 'When is this checkpoint?',
                      subtitle: 'Pick the milestone that matches this update.',
                      compactTitle: true,
                      child: Column(
                        children: [
                          for (var i = 0; i < _options.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            _CheckpointOptionTile(
                              title: _options[i].title,
                              date: _fmt(_at(_options[i].offsetDays)),
                              iconText: _options[i].iconText,
                              selected: _selectedKey == _options[i].key,
                              done: _options[i].key == 'treatment',
                              onTap: _options[i].key == 'treatment'
                                  ? null
                                  : () => setState(() => _selectedKey = _options[i].key),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ProcedureSelectionPanel(
                      title: '${sel.title} checkpoint',
                      subtitle: _fmt(selDate),
                      compactTitle: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _PhotoPicker(
                            photoPath: _photoPath,
                            onTap: _pickPhoto,
                            onAdjust: (_photoPath ?? '').trim().isEmpty ? null : _adjustPhoto,
                            onClear: (_photoPath ?? '').trim().isEmpty
                                ? null
                                : () => setState(() => _photoPath = null),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'How do you feel?',
                            style: ProcedureSelectionTypography.label(
                              size: 12,
                              weight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _MoodChip(
                                  emoji: '😣',
                                  label: 'Bad',
                                  selected: _mood == 'bad',
                                  onTap: () => setState(() => _mood = 'bad'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MoodChip(
                                  emoji: '😐',
                                  label: 'Okay',
                                  selected: _mood == 'okay',
                                  onTap: () => setState(() => _mood = 'okay'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MoodChip(
                                  emoji: '😊',
                                  label: 'Good',
                                  selected: _mood == 'good',
                                  onTap: () => setState(() => _mood = 'good'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MoodChip(
                                  emoji: '🤩',
                                  label: 'Love',
                                  selected: _mood == 'love',
                                  onTap: () => setState(() => _mood = 'love'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _noteCtrl,
                            maxLines: 3,
                            cursorColor: ProcedureSelectionTheme.ink,
                            style: ProcedureSelectionTypography.label(
                              size: 14,
                              weight: FontWeight.w500,
                              color: ProcedureSelectionTheme.ink,
                            ),
                            decoration: InputDecoration(
                              hintText: 'How do you feel at this stage?',
                              hintStyle: ProcedureSelectionTypography.body(
                                size: 13,
                                color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
                              ),
                              prefixIcon: Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
                              ),
                              filled: true,
                              fillColor: ProcedureSelectionTheme.fieldFillLight,
                              contentPadding: const EdgeInsets.fromLTRB(4, 14, 14, 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(color: ProcedureSelectionTheme.cardBorder),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.2),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    ProcedurePremiumContinueButton(
                      label: _saving ? 'Saving…' : 'Save checkpoint',
                      onPressed: _saving ? null : _save,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  const _GlassCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _CheckpointOptionTile extends StatelessWidget {
  const _CheckpointOptionTile({
    required this.iconText,
    required this.title,
    required this.date,
    required this.selected,
    required this.done,
    required this.onTap,
  });

  final String iconText;
  final String title;
  final String date;
  final bool selected;
  final bool done;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = selected && !done;

    return Opacity(
      opacity: done ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(16),
            selected: active,
            compact: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: done
                          ? const Color(0xFFE8F5EE)
                          : active
                              ? Colors.white.withValues(alpha: 0.14)
                              : ProcedureSelectionTheme.fieldFillLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: done
                            ? const Color(0xFFB8E0C8)
                            : active
                                ? Colors.white.withValues(alpha: 0.22)
                                : ProcedureSelectionTheme.cardBorder,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      iconText,
                      style: ProcedureSelectionTypography.label(
                        size: 11,
                        weight: FontWeight.w800,
                        color: done
                            ? const Color(0xFF2D7A4A)
                            : active
                                ? Colors.white
                                : ProcedureSelectionTheme.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: ProcedureSelectionTypography.label(
                            size: 14,
                            weight: FontWeight.w700,
                            color: active ? Colors.white : ProcedureSelectionTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          date,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: active
                                ? Colors.white.withValues(alpha: 0.65)
                                : ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (done)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5EE),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Logged',
                        style: ProcedureSelectionTypography.chip(
                          size: 10,
                          color: const Color(0xFF2D7A4A),
                        ),
                      ),
                    )
                  else
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? Colors.white : Colors.transparent,
                        border: Border.all(
                          color: active
                              ? Colors.white
                              : ProcedureSelectionTheme.muted.withValues(alpha: 0.35),
                          width: 1.5,
                        ),
                      ),
                      child: active
                          ? Center(
                              child: Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: ProcedureSelectionTheme.buttonPrimary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null,
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

class _MoodChip extends StatelessWidget {
  const _MoodChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          selected: selected,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(emoji, style: const TextStyle(fontSize: 18, height: 1)),
                const SizedBox(height: 4),
                Text(
                  label.toUpperCase(),
                  style: ProcedureSelectionTypography.chip(
                    size: 9,
                    color: selected
                        ? Colors.white.withValues(alpha: 0.72)
                        : ProcedureSelectionTheme.muted,
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

class _PhotoPicker extends StatelessWidget {
  const _PhotoPicker({
    required this.photoPath,
    required this.onTap,
    this.onAdjust,
    this.onClear,
  });

  final String? photoPath;
  final VoidCallback onTap;
  final VoidCallback? onAdjust;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final path = (photoPath ?? '').trim();
    final hasPhoto = path.isNotEmpty && (isRemoteUrl(path) || File(path).existsSync());
    const radius = 12.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 72).clamp(140.0, 180.0),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: AspectRatio(
            aspectRatio: 3 / 4,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: ProcedureSelectionTheme.cardBorder),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: hasPhoto
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(radius - 4),
                            child: isRemoteUrl(path)
                                ? Image.network(
                                    path,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => ColoredBox(
                                      color: Colors.white.withValues(alpha: 0.52),
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: ProcedureSelectionTheme.muted,
                                      ),
                                    ),
                                  )
                                : Image.file(File(path), fit: BoxFit.cover),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Progress photo',
                                style: ProcedureSelectionTypography.label(
                                  size: 11,
                                  weight: FontWeight.w700,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const Spacer(),
                              Row(
                                children: [
                                  Icon(
                                    Icons.add_a_photo_outlined,
                                    size: 16,
                                    color: ProcedureSelectionTheme.muted,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      'Camera or gallery',
                                      style: ProcedureSelectionTypography.label(
                                        size: 11,
                                        weight: FontWeight.w600,
                                        color: ProcedureSelectionTheme.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                  ),
                  if (hasPhoto) ...[
                    if (onAdjust != null)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: onAdjust,
                            borderRadius: BorderRadius.circular(999),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.crop_rounded, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    if (onClear != null)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Material(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: onClear,
                            borderRadius: BorderRadius.circular(999),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.close_rounded, size: 14, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
