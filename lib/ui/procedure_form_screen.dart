import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dotted_border/dotted_border.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

import '../services/photo_processor.dart';
import 'photo_storage.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/auth_service.dart';
import '../services/openai_service.dart';
import 'formatters.dart';
import 'widgets/app_background.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step1_background.dart';
import 'widgets/step2_warm_background.dart';
import 'procedure_icon_resolver.dart';
import 'photo_frame_adjust_screen.dart';
import 'procedure_ba_capture_screen.dart';
import 'widgets/black_date_picker_sheet.dart';
import 'widgets/black_photo_source_sheet.dart';

const _kInk = Color(0xFF1A1A2E);
const _kMuted = Color(0xFF9B96B8);
const _kSurface = Color(0xFFFFFFFF);
const _kSurface2 = Color(0xFFF4F6FA);
const _kStroke = Color(0x261A1A2E);

// Step 1 — Choose Type & Area design tokens (light glass)
const _kStep1Bg = Color(0xFFEBEBF0);
const _kStep1Navy = Color(0xFF0D0D2B);
const _kStep1Muted = Color(0xFF9999AA);
const _kStep1Accent = Color(0xFF5C5CFF);
const _kStep1CardRadius = 14.0;
const _kStep1CardInset = 22.0;
const _kStep1Glass = Color(0x73000000);
const _kStep1HeroGlass = Color(0xE0000000);
const _kStep1OnGlass = Color(0xFFFFFFFF);
const _kStep1OnGlassMuted = Color(0xB3FFFFFF);
const _kStep1FaceHeroAsset = 'assets/facefirststep.png';
const _kStep1BodyHeroAsset = 'assets/bodyfirststep.png';

// Step 2 tokens live in [ProcedureSelectionTheme].

// Step 3 — Who & where dark-field design
const _kStep3FieldBg = Color(0xFF1A1A1F);
const _kStep3FieldRadius = 16.0;
const _kStep3Label = Color(0xFF3A3A48);

enum _FlowTab { aesthetic, surgery }
enum _BodyScope { face, body }
enum GlowFeel { painless, mild, moderate, intense }

GlowFeel? glowFeelFromStoredName(String? name) {
  if (name == null || name.isEmpty) return null;
  for (final v in GlowFeel.values) {
    if (v.name == name) return v;
  }
  return null;
}

class ProcedureFormScreen extends StatefulWidget {
  const ProcedureFormScreen({
    super.key,
    required this.repo,
    this.existing,
  });

  final ProcedureRepository repo;
  final Procedure? existing;

  @override
  State<ProcedureFormScreen> createState() => _ProcedureFormScreenState();
}

class _ProcedureFormScreenState extends State<ProcedureFormScreen> {
  final _formKey = GlobalKey<FormState>();

  // step: 0=Face/Body, 1=Aesthetic/Surgery, 2=Procedure, 3=Details, 4=Recovery, 5=Reveal
  int _step = 0;
  int _lastStep = 0;
  int _step1RevealGeneration = 0;
  int _step2RevealGeneration = 0;
  int _step3RevealGeneration = 0;
  int _step4RevealGeneration = 0;
  int _step5RevealGeneration = 0;

  _FlowTab? _tab;
  _BodyScope? _scope;

  _ProcPreset? _preset;

  late final TextEditingController _title;
  late final TextEditingController _category;
  late final TextEditingController _clinic;
  late final TextEditingController _practitioner;
  late final TextEditingController _product;
  late final TextEditingController _cost;
  late final TextEditingController _currency;
  late final TextEditingController _recoveryDays;
  late final TextEditingController _tags;
  late final TextEditingController _notes;
  late final TextEditingController _aftercare;

  late DateTime _date;

  final Set<String> _zones = <String>{};
  double _volumeMl = 1.0;
  String? _beforePhotoPath;
  String? _afterPhotoPath;

  int _redoAfterValue = 2;
  String? _redoAfterUnit; // null = unselected until user picks a unit
  bool _redoAfterNeedsUnitHint = false;
  bool _aiRedoLoading = false;
  bool _aiRedoDone = false;
  DateTime? _aiRedoSuggestedDate;

  bool _aiRecoveryLoading = false;
  bool _aiRecoveryDone = false;

  bool get _hasStep2ProcedureSelected => _preset != null || _title.text.trim().isNotEmpty;
  bool get _hasStep2ZoneSelected => _zones.isNotEmpty;

  static int _unitToDays(int value, String unit) {
    switch (unit) {
      case 'days':
        return value;
      case 'weeks':
        return value * 7;
      case 'months':
        return value * 30;
      case 'years':
        return value * 365;
    }
    return value * 30;
  }

  static ({int value, String unit}) _aiRedoSuggestionForPreset(_ProcPreset? preset) {
    if (preset == null) return (value: 1, unit: 'months');
    final name = preset.name.trim().toLowerCase();

    // Simple, deterministic “AI-like” heuristic based on common redo intervals.
    if (name.contains('botox')) return (value: 3, unit: 'months');
    if (name.contains('filler')) return (value: 9, unit: 'months');
    if (name.contains('polynucleotide')) return (value: 6, unit: 'months');
    if (name.contains('biostimulator') || name.contains('biostim')) return (value: 12, unit: 'months');
    if (name.contains('microneedling')) return (value: 1, unit: 'months');
    if (name.contains('rf microneedling') || name.contains('rf')) return (value: 2, unit: 'months');

    // If the preset tagline contains a “mo” hint, pick the first number.
    final tag = preset.tagline.toLowerCase();
    final moIndex = tag.indexOf('mo');
    if (moIndex != -1) {
      final digits = RegExp(r'(\d{1,2})').allMatches(tag).map((m) => int.tryParse(m.group(1) ?? '')).whereType<int>().toList();
      if (digits.isNotEmpty) return (value: digits.first.clamp(1, 24), unit: 'months');
    }

    return (value: 1, unit: 'months');
  }

  Future<void> _runAiRedoSuggestion() async {
    if (_aiRedoLoading) return;
    setState(() {
      _aiRedoLoading = true;
      _aiRedoDone = false;
    });

    // Show a short loading animation for UX.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final rec = _aiRedoSuggestionForPreset(_preset);
    final days = _unitToDays(rec.value, rec.unit);
    final suggested = _date.add(Duration(days: days));

    setState(() {
      _redoAfterValue = rec.value;
      _redoAfterUnit = rec.unit;
      _redoAfterNeedsUnitHint = false;
      _aiRedoSuggestedDate = suggested;
      _aiRedoLoading = false;
      _aiRedoDone = true;
    });
  }

  static ({int value, String unit}) _daysToUnitValue(int days) {
    if (days <= 0) return (value: 0, unit: 'days');
    if (days <= 14) return (value: days, unit: 'days');
    if (days <= 56) return (value: (days / 7).round().clamp(1, 12), unit: 'weeks');
    if (days <= 365) return (value: (days / 30).round().clamp(1, 24), unit: 'months');
    return (value: (days / 365).round().clamp(1, 10), unit: 'years');
  }

  static int _fallbackRecoveryDaysForCategory(String category) {
    final c = category.trim().toLowerCase();
    if (c.contains('surgery')) return 21;
    if (c.contains('inject')) return 3;
    if (c.contains('skin')) return 5;
    return 3;
  }

  Future<void> _runAiRecoverySuggestion() async {
    if (_aiRecoveryLoading) return;
    setState(() {
      _aiRecoveryLoading = true;
      _aiRecoveryDone = false;
    });

    final name = _title.text.trim().isEmpty ? (_preset?.name ?? 'Custom procedure') : _title.text.trim();
    final category = _category.text.trim().isEmpty ? (_preset?.category ?? 'Other') : _category.text.trim();

    try {
      final openAI = OpenAIService(model: 'gpt-4o-mini');
      final rec = await openAI.suggestRecoveryDuration(procedureName: name, category: category);

      setState(() {
        _recoveryValue = rec.value.clamp(1, 60);
        _recoveryUnit = rec.unit;
        _recoveryDays.text = _recoveryDaysFromDuration(_recoveryValue, _recoveryUnit!).toString();
        _aiRecoveryDone = true;
        _aiRecoveryLoading = false;
      });
    } catch (_) {
      // Fallback: preset recoveryDays, then category-based default.
      final days = (_preset != null && _preset!.recoveryDays > 0)
          ? _preset!.recoveryDays
          : _fallbackRecoveryDaysForCategory(category);
      final rec = _daysToUnitValue(days);
      setState(() {
        _recoveryValue = (rec.value <= 0 ? 1 : rec.value);
        _recoveryUnit = rec.unit;
        _recoveryDays.text = _recoveryDaysFromDuration(_recoveryValue, _recoveryUnit!).toString();
        _aiRecoveryDone = true;
        _aiRecoveryLoading = false;
      });
    }
  }

  int _recoveryValue = 2;
  String? _recoveryUnit; // null = unselected until user picks a unit

  String? _pain; // none|mild|moderate|intense
  GlowFeel? _feel;

  bool _saving = false;
  /// When true, saves with the `community_live` tag (visible on community).
  bool _postLive = false;
  static const _liveTag = 'community_live';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;

    _date = e?.date ?? DateTime.now();
    // New procedure: leave redo unit unselected until the user picks one.
    if (e != null) {
      _redoAfterValue = e.redoAfterValue ?? 2;
      final redoUnit = (e.redoAfterUnit ?? '').trim();
      _redoAfterUnit = redoUnit.isEmpty ? null : redoUnit;
    }
    _title = TextEditingController(text: e?.title ?? '');
    _category = TextEditingController(text: e?.category ?? '');
    _clinic = TextEditingController(text: e?.clinic ?? '');
    _practitioner = TextEditingController(text: e?.practitioner ?? '');
    _product = TextEditingController(text: e?.product ?? '');
    _volumeMl = (e?.volumeMl ?? 1.0).clamp(0.5, 5.0);
    _beforePhotoPath = (e?.beforePhotoPath ?? '').trim().isEmpty ? null : e?.beforePhotoPath;
    _afterPhotoPath = (e?.afterPhotoPath ?? '').trim().isEmpty ? null : e?.afterPhotoPath;
    _cost = TextEditingController(text: e?.cost?.toString() ?? '');
    _currency = TextEditingController(text: e?.currency ?? 'EUR');
    _recoveryDays = TextEditingController(text: e?.recoveryDays?.toString() ?? '');
    final existingTags = e?.tags ?? const <String>[];
    _postLive = existingTags.contains(_liveTag);
    _tags = TextEditingController(
      text: existingTags.where((t) => t != _liveTag).join(', '),
    );
    _notes = TextEditingController(text: e?.notes ?? '');
    _aftercare = TextEditingController(text: e?.aftercare ?? '');

    _zones.addAll(e?.zones ?? const []);

    _pain = e?.painLevel;
    _feel = glowFeelFromStoredName(e?.feelLevel);

    if (e != null) {
      _recoveryValue = e.recoveryValue ?? 2;
      final recUnit = (e.recoveryUnit ?? '').trim();
      _recoveryUnit = recUnit.isEmpty ? null : recUnit;
    }
    // New procedure: leave recovery unit unselected until the user picks one.
    if (e != null) {
      _hydrateWizardFromExisting(e);
    }
  }

  void _hydrateWizardFromExisting(Procedure e) {
    final preset = _procPresetMatchingTitle(e.title);
    _preset = preset;
    _tab = _flowTabForProcedure(e, preset);
    _scope = _bodyScopeForProcedure(e, preset);

    if ((e.recoveryValue == null || (e.recoveryUnit ?? '').trim().isEmpty) &&
        e.recoveryDays != null &&
        e.recoveryDays! > 0) {
      final rec = _daysToUnitValue(e.recoveryDays!);
      _recoveryValue = rec.value <= 0 ? 1 : rec.value;
      _recoveryUnit = rec.unit;
      if (_recoveryDays.text.trim().isEmpty) {
        _recoveryDays.text = _recoveryDaysFromDuration(_recoveryValue, _recoveryUnit!).toString();
      }
    }

    final suggestedRedo = e.suggestedRedoAppointmentDate;
    if (suggestedRedo != null &&
        (e.redoAfterValue != null && (e.redoAfterUnit ?? '').trim().isNotEmpty)) {
      _aiRedoSuggestedDate = suggestedRedo;
      _aiRedoDone = true;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _clinic.dispose();
    _practitioner.dispose();
    _product.dispose();
    _cost.dispose();
    _currency.dispose();
    _recoveryDays.dispose();
    _tags.dispose();
    _notes.dispose();
    _aftercare.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showBlackDatePickerSheet(
      context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      title: 'Procedure date',
      subtitle: 'When did this treatment happen?',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    num? parseCost(String v) {
      final cleaned = v.trim().replaceAll(',', '.');
      if (cleaned.isEmpty) return null;
      return num.tryParse(cleaned);
    }

    int? parseInt(String v) {
      final cleaned = v.trim();
      if (cleaned.isEmpty) return null;
      return int.tryParse(cleaned);
    }

    final tags = _tags.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && e != _liveTag)
        .toSet()
        .toList();
    if (_postLive) tags.add(_liveTag);

    final base = widget.existing;
    final isSurgery = _tab == _FlowTab.surgery;
    final hasImplantZone =
        _zones.contains('Breasts') || _zones.contains('Buttocks') || _zones.contains('Butt') || _zones.contains('Buttocks');
    final productText = _product.text.trim();
    final volumeForSave = isSurgery
        ? (hasImplantZone ? _volumeMl : null)
        : (productText.isEmpty ? null : _volumeMl);

    // Live posts need remote photo URLs so community can show before/after.
    var beforePath = _beforePhotoPath;
    var afterPath = _afterPhotoPath;
    if (_postLive) {
      try {
        if ((beforePath ?? '').trim().isNotEmpty && !isRemoteUrl(beforePath)) {
          beforePath = await persistAndUploadPhotoPath(beforePath!);
          if (mounted) setState(() => _beforePhotoPath = beforePath);
        }
        if ((afterPath ?? '').trim().isNotEmpty && !isRemoteUrl(afterPath)) {
          afterPath = await persistAndUploadPhotoPath(afterPath!);
          if (mounted) setState(() => _afterPhotoPath = afterPath);
        }
      } catch (e) {
        debugPrint('[ProcedureForm] live photo upload before save: $e');
      }
    }

    final procedure = (base ?? Procedure(title: _title.text.trim(), date: _date)).copyWith(
      title: _title.text.trim(),
      date: _date,
      category: _category.text.trim().isEmpty ? null : _category.text.trim(),
      clinic: _clinic.text.trim().isEmpty ? null : _clinic.text.trim(),
      practitioner: _practitioner.text.trim().isEmpty ? null : _practitioner.text.trim(),
      product: productText.isEmpty ? null : productText,
      volumeMl: volumeForSave,
      beforePhotoPath: beforePath,
      afterPhotoPath: afterPath,
      zones: _zones.toList()..sort(),
      cost: parseCost(_cost.text),
      currency: _currency.text.trim().isEmpty ? 'EUR' : _currency.text.trim().toUpperCase(),
      recoveryDays: parseInt(_recoveryDays.text) ??
          (_recoveryUnit == null ? null : _recoveryDaysFromDuration(_recoveryValue, _recoveryUnit!)),
      recoveryValue: _recoveryUnit == null ? null : _recoveryValue,
      recoveryUnit: _recoveryUnit,
      painLevel: _pain,
      feelLevel: _feel?.name,
      followUpDate: base?.followUpDate,
      redoAfterValue: _redoAfterUnit == null ? null : _redoAfterValue,
      redoAfterUnit: _redoAfterUnit,
      tags: tags,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      aftercare: _aftercare.text.trim().isEmpty ? null : _aftercare.text.trim(),
    );

    try {
      await widget.repo.upsertDone(procedure);
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.of(context).pop(procedure);
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      final msg = e.code == 'permission-denied'
          ? 'Can’t save yet: Firestore rules deny writes. Deploy the rules for `users/{uid}/procedure_done`.'
          : 'Couldn’t save (${e.code}).';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn’t save. Please try again.')));
    }
  }

  static int _recoveryDaysFromDuration(int value, String unit) {
    final v = value < 1 ? 1 : value;
    return switch (unit) {
      'weeks' => v * 7,
      'months' => v * 30,
      'years' => v * 365,
      _ => v,
    };
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final serif = GoogleFonts.dmSerifDisplay();
    final ui = GoogleFonts.urbanist();
    final wizardStyle = _step <= 4;

    int footerRevealGeneration() => switch (_step) {
          0 => _step1RevealGeneration,
          1 => _step2RevealGeneration,
          2 => _step3RevealGeneration,
          3 => _step4RevealGeneration,
          _ => _step5RevealGeneration,
        };

    void next() {
      if (_saving) return;
      if (_step == 0 && (_tab == null || _scope == null)) return;
      if (_step == 1) {
        final missingProcedure = !_hasStep2ProcedureSelected;
        final missingZone = !_hasStep2ZoneSelected;
        if (missingProcedure || missingZone) {
          final msg = missingProcedure && missingZone
              ? 'Select a procedure and a treatment zone to continue.'
              : missingProcedure
                  ? 'Select a procedure to continue.'
                  : 'Select a treatment zone to continue.';
          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: Colors.black.withValues(alpha: 0.92),
              behavior: SnackBarBehavior.floating,
              margin: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.paddingOf(context).bottom + 96,
              ),
              duration: const Duration(seconds: 2),
            ),
          );
          return;
        }
      }
      if (_step >= 2 && _step <= 3 && !(_formKey.currentState?.validate() ?? false)) return;
      if (_step < 4) {
        setState(() {
          _lastStep = _step;
          if (_step == 0) _step2RevealGeneration++;
          if (_step == 1) _step3RevealGeneration++;
          if (_step == 2) _step4RevealGeneration++;
          if (_step == 3) _step5RevealGeneration++;
          _step++;
        });
      } else {
        _save();
      }
    }

    void back() {
      if (_saving || _step == 0) return;
      final replayStep1 = _step == 1;
      final replayStep2 = _step == 2;
      final replayStep3 = _step == 3;
      final replayStep4 = _step == 4;
      setState(() {
        _lastStep = _step;
        _step--;
        if (replayStep1) _step1RevealGeneration++;
        if (replayStep2) {
          _step2RevealGeneration++;
          _step3RevealGeneration++;
        }
        if (replayStep3) {
          _step3RevealGeneration++;
          _step4RevealGeneration++;
        }
        if (replayStep4) {
          _step4RevealGeneration++;
          _step5RevealGeneration++;
        }
      });
    }

    return Scaffold(
      // Keep true so the focused field can scroll above the keyboard, but do
      // NOT read viewInsets in this build — that rebuilt the whole wizard
      // every keyboard animation frame and made focus feel laggy.
      resizeToAvoidBottomInset: true,
      backgroundColor: wizardStyle
          ? (_step == 0
              ? const Color(0xFFF9F9FB)
              : ProcedureSelectionTheme.pageBackground)
          : const Color(0xFFE9EDF3),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Stack(
        children: [
          if (_step == 0)
            const Step1Background()
          else if (_step >= 1 && _step <= 4)
            const Step2WarmBackground()
          else
            const AppBackground(),
          SafeArea(
            top: !wizardStyle,
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        ListView(
                          padding: EdgeInsets.fromLTRB(wizardStyle ? 0 : 16, wizardStyle ? 0 : 8, wizardStyle ? 0 : 16, wizardStyle ? 72 : 8),
                          children: [
                  if (!wizardStyle) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _TopCircleButton(icon: Icons.close, onTap: () => Navigator.of(context).maybePop()),
                        Text(isEdit ? 'Edit procedure' : 'Add procedure',
                            style: ui.copyWith(fontSize: 18, fontWeight: FontWeight.w800, color: _kInk)),
                        _TopCircleButton(icon: _step == 4 ? Icons.check : Icons.arrow_forward, onTap: next, filled: true),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _StepBars(step: _step, total: 5),
                    const SizedBox(height: 14),
                  ],
                  AnimatedSwitcher(
                    // Avoid a visible "flash" of step-1 content during the
                    // step-1 -> step-2 transition (background swaps instantly).
                    duration: (_lastStep == 0 && _step == 1) ? Duration.zero : const Duration(milliseconds: 220),
                    transitionBuilder: (child, animation) {
                      if (_lastStep == 0 && _step == 1) return child;
                      final key = child.key;
                      if (key is ValueKey && key.value is String && (key.value as String).startsWith('start')) {
                        return child;
                      }
                      return FadeTransition(opacity: animation, child: child);
                    },
                    child: switch (_step) {
                      0 => _Step1ChooseTypeArea(
                          key: ValueKey('start-$_step1RevealGeneration'),
                          serif: serif,
                          tab: _tab,
                          scope: _scope,
                          revealGeneration: _step1RevealGeneration,
                          onTabChanged: (t) => setState(() => _tab = t),
                          onScopeChanged: (s) => setState(() => _scope = s),
                        ),
                      1 => ProcedureSelectionScreen(
                          key: ValueKey('proc-$_step2RevealGeneration'),
                          revealGeneration: _step2RevealGeneration,
                          selected: _preset?.name ?? _title.text.trim(),
                          tab: _tab!,
                          scope: _scope!,
                          isSurgery: _tab == _FlowTab.surgery,
                          preset: _preset,
                          product: _product,
                          zones: _zones,
                          volumeMl: _volumeMl,
                          onPick: (p) => setState(() {
                            final alreadySelected =
                                _preset?.name.toLowerCase() == p.name.toLowerCase() ||
                                _title.text.trim().toLowerCase() == p.name.toLowerCase();
                            if (alreadySelected) {
                              _preset = null;
                              _title.clear();
                              _category.clear();
                              return;
                            }
                            _preset = p;
                            _title.text = p.name;
                            _category.text = p.category;
                          }),
                          onCustom: () async {
                            final created = await _showCustomProcedureSheet(context);
                            if (created == null) return;
                            setState(() {
                              _preset = created;
                              _title.text = created.name;
                              _category.text = created.category;
                            });
                          },
                          onToggleZone: (z) => setState(() {
                            _toggleTreatmentZone(_zones, _scope, z);
                          }),
                          onAddZone: () async {
                            final z = await _showAddZoneDialog(context);
                            if (z == null) return;
                            setState(() {
                              _zones.add(_normalizeZone(z));
                            });
                          },
                          onPickBrand: (v) => setState(() => _product.text = v),
                          onVolumeChanged: (v) => setState(() => _volumeMl = v),
                        ),
                      2 => _DetailsStep(
                          key: ValueKey('details-$_step3RevealGeneration'),
                          revealGeneration: _step3RevealGeneration,
                          practitioner: _practitioner,
                          clinic: _clinic,
                          cost: _cost,
                          date: _date,
                          redoAfterValue: _redoAfterValue,
                          redoAfterUnit: _redoAfterUnit,
                          onPickDate: _pickDate,
                          onRedoChanged: (v, u) => setState(() {
                            _redoAfterValue = v;
                            _redoAfterUnit = u;
                            if (u != null) _redoAfterNeedsUnitHint = false;
                          }),
                          redoAfterNeedsUnitHint: _redoAfterNeedsUnitHint,
                          onRedoAfterUnitRequired: () => setState(() => _redoAfterNeedsUnitHint = true),
                          aiRedoLoading: _aiRedoLoading,
                          aiRedoDone: _aiRedoDone,
                          aiRedoSuggestedDate: _aiRedoSuggestedDate,
                          onAiChooseRedo: _runAiRedoSuggestion,
                          onAiDismissDone: () => setState(() => _aiRedoDone = false),
                        ),
                      3 => _RecoveryStep(
                          key: ValueKey('recovery-$_step4RevealGeneration'),
                          revealGeneration: _step4RevealGeneration,
                          recoveryValue: _recoveryValue,
                          recoveryUnit: _recoveryUnit,
                          beforePhotoPath: _beforePhotoPath,
                          afterPhotoPath: _afterPhotoPath,
                          pain: _pain,
                          notes: _notes,
                          onRecoveryChanged: (v, u) => setState(() {
                            _recoveryValue = v;
                            _recoveryUnit = u;
                            if (u != null) _recoveryDays.text = _recoveryDaysFromDuration(v, u).toString();
                          }),
                          onPainChanged: (v) => setState(() => _pain = v),
                          onBeforeChanged: (p) => setState(() => _beforePhotoPath = p),
                          onAfterChanged: (p) => setState(() => _afterPhotoPath = p),
                          aiRecoveryLoading: _aiRecoveryLoading,
                          aiRecoveryDone: _aiRecoveryDone,
                          onAiChooseRecovery: _runAiRecoverySuggestion,
                          onAiDismissDone: () => setState(() => _aiRecoveryDone = false),
                        ),
                      _ => _RevealStep(
                          key: ValueKey('reveal-$_step5RevealGeneration'),
                          revealGeneration: _step5RevealGeneration,
                          title: _title.text.trim().isEmpty ? 'Untitled' : _title.text.trim(),
                          meta: [
                            if (_practitioner.text.trim().isNotEmpty) _practitioner.text.trim(),
                            if (_clinic.text.trim().isNotEmpty) _clinic.text.trim(),
                            formatDate(_date),
                          ].where((e) => e.trim().isNotEmpty).join(' · '),
                          zone: _zones.isEmpty ? 'Face' : _zones.take(2).join(', '),
                          cost: _cost.text.trim(),
                          currency: _currency.text.trim(),
                          recoveryValue: _recoveryUnit == null ? null : _recoveryValue,
                          recoveryUnit: _recoveryUnit,
                          category: (_category.text.trim().isEmpty ? (_preset?.category ?? '') : _category.text.trim()),
                          product: _product.text.trim(),
                          volumeMl: _product.text.trim().isEmpty ? null : _volumeMl,
                          pain: _pain,
                          note: _notes.text.trim(),
                          postLive: _postLive,
                          onPostLiveChanged: (v) => setState(() => _postLive = v),
                          nextAppointmentLabel: () {
                            final d = computeSuggestedRedoAppointment(
                              procedureDate: _date,
                              redoAfterValue: _redoAfterUnit == null ? null : _redoAfterValue,
                              redoAfterUnit: _redoAfterUnit,
                            );
                            return d == null ? null : formatDate(d);
                          }(),
                        ),
                    },
                  ),
                      ],
                        ),
                        if (wizardStyle)
                          Positioned(
                            top: MediaQuery.paddingOf(context).top + 8,
                            left: 16,
                            child: _TopCircleButton(
                              icon: _step == 0 ? Icons.close_rounded : Icons.chevron_left_rounded,
                              onTap: _step == 0 ? () => Navigator.of(context).maybePop() : back,
                              glassStyle: _step > 0,
                              blackStyle: _step == 0,
                            ),
                          ),
                        if (wizardStyle && _step > 0)
                          Positioned(
                            top: MediaQuery.paddingOf(context).top + 8,
                            right: 16,
                            child: _TopCircleButton(
                              icon: Icons.close_rounded,
                              onTap: _saving ? null : () => Navigator.of(context).maybePop(),
                              glassStyle: true,
                            ),
                          ),
                        if (wizardStyle)
                          Positioned(
                            left: 16,
                            right: 16,
                            bottom: 20,
                            child: _HideWhenKeyboard(
                              child: _Step1StaggerReveal(
                              key: ValueKey('s$_step-footer-${footerRevealGeneration()}'),
                              delay: const Duration(milliseconds: 520),
                              slide: 0.1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(_step == 0 ? 14 : 32),
                                  boxShadow: _step == 0
                                      ? [
                                          BoxShadow(
                                            color: _kInk.withValues(alpha: 0.28),
                                            blurRadius: 24,
                                            offset: const Offset(0, 10),
                                          ),
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.08),
                                            blurRadius: 8,
                                            offset: const Offset(0, 2),
                                          ),
                                        ]
                                      : ProcedureGlassDecorations.shadows(selected: true),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    _step == 0
                                        ? SizedBox(
                                            width: double.infinity,
                                            height: 48,
                                            child: FilledButton(
                                              onPressed: _saving
                                                  ? null
                                                  : (_tab == null || _scope == null)
                                                      ? null
                                                      : next,
                                              style: FilledButton.styleFrom(
                                                backgroundColor: Colors.black,
                                                foregroundColor: Colors.white,
                                                disabledBackgroundColor: Colors.black.withValues(alpha: 0.35),
                                                disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
                                                elevation: 0,
                                                shadowColor: Colors.transparent,
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                              ),
                                              child: Text(
                                                _saving ? 'Saving…' : 'Continue',
                                                style: GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w700),
                                              ),
                                            ),
                                          )
                                        : ProcedurePremiumContinueButton(
                                            label: _saving ? 'Saving…' : (_step == 4 ? 'Save' : 'Continue'),
                                            onPressed: _saving ? null : next,
                                          ),
                                  ],
                                ),
                              ),
                            ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!wizardStyle)
                    _HideWhenKeyboard(
                      child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                      decoration: BoxDecoration(
                        color: _kSurface.withValues(alpha: 0.78),
                        border: Border(top: BorderSide(color: _kStroke)),
                      ),
                      child: Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: _saving ? null : back,
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: _kStroke),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                    ),
                                    child: const Text('Back'),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: _saving ? null : next,
                                    style: FilledButton.styleFrom(
                                      backgroundColor: _kInk,
                                      foregroundColor: _kSurface,
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    ),
                                    child: Text(_saving ? 'Saving…' : (_step == 4 ? 'Save' : 'Continue')),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    ),
                ],
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

/// Hides [child] while the keyboard is open without rebuilding ancestors.
///
/// Only this widget depends on [MediaQuery.viewInsetsOf], so keyboard
/// animation frames do not rebuild the whole procedure form.
class _HideWhenKeyboard extends StatelessWidget {
  const _HideWhenKeyboard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final open = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Offstage(
      offstage: open,
      child: IgnorePointer(
        ignoring: open,
        child: child,
      ),
    );
  }
}

// ---------- Step widgets ----------

class _WizardCard extends StatelessWidget {
  const _WizardCard({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String eyebrow;
  final TextSpan title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _kSurface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kStroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(eyebrow, style: GoogleFonts.urbanist(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 2.2, color: _kMuted)),
          const SizedBox(height: 6),
          RichText(text: title),
          const SizedBox(height: 6),
          Text(subtitle, style: GoogleFonts.urbanist(fontSize: 13, color: _kMuted, height: 1.5)),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _Step1StaggerReveal extends StatefulWidget {
  const _Step1StaggerReveal({
    super.key,
    required this.delay,
    required this.child,
    this.slide = 0.08,
  });

  final Duration delay;
  final Widget child;
  final double slide;

  @override
  State<_Step1StaggerReveal> createState() => _Step1StaggerRevealState();
}

class _Step1StaggerRevealState extends State<_Step1StaggerReveal> {
  static const _duration = Duration(milliseconds: 650);
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleReveal());
  }

  @override
  void didUpdateWidget(covariant _Step1StaggerReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.key != widget.key) {
      _visible = false;
      _scheduleReveal();
    }
  }

  void _scheduleReveal() {
    if (!mounted) return;
    if (widget.delay == Duration.zero) {
      setState(() => _visible = true);
      return;
    }
    Future<void>.delayed(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: _duration,
      curve: Curves.easeOutCubic,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : Offset(0, widget.slide),
        duration: _duration,
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: double.infinity,
          child: widget.child,
        ),
      ),
    );
  }
}

class _Step1ChooseTypeArea extends StatelessWidget {
  const _Step1ChooseTypeArea({
    super.key,
    required this.serif,
    required this.tab,
    required this.scope,
    required this.revealGeneration,
    required this.onTabChanged,
    required this.onScopeChanged,
  });

  final TextStyle serif;
  final _FlowTab? tab;
  final _BodyScope? scope;
  final int revealGeneration;
  final ValueChanged<_FlowTab?> onTabChanged;
  final ValueChanged<_BodyScope?> onScopeChanged;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Step1StaggerReveal(
          key: ValueKey('s1-hero-$revealGeneration'),
          delay: Duration.zero,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const _Step1HeroCard(
                lightTypography: true,
                minHeight: 540,
              ),
              Positioned(
                left: 12,
                right: 12,
                top: topInset + 118,
                bottom: 28,
                child: _Step1RadialVisual(
                  tab: tab,
                  scope: scope,
                  onTabChanged: onTabChanged,
                  onScopeChanged: onScopeChanged,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tab == _FlowTab.aesthetic)
                _Step1StaggerReveal(
                  key: ValueKey('s1-tab-aesthetic-$revealGeneration'),
                  delay: const Duration(milliseconds: 280),
                  child: _Step1SummaryCard(
                    title: 'Aesthetic',
                    subtitle: 'Non-surgical procedures',
                    iconAsset: 'assets/staricon.png',
                    onTap: () => onTabChanged(null),
                  ),
                ),
              if (tab == _FlowTab.surgery)
                Padding(
                  padding: EdgeInsets.only(top: tab == _FlowTab.aesthetic ? 8 : 0),
                  child: _Step1StaggerReveal(
                    key: ValueKey('s1-tab-surgery-$revealGeneration'),
                    delay: const Duration(milliseconds: 280),
                    child: _Step1SummaryCard(
                      title: 'Surgery',
                      subtitle: 'Surgical procedures',
                      iconAsset: 'assets/knifeicon.png',
                      iconScale: 1.35,
                      onTap: () => onTabChanged(null),
                    ),
                  ),
                ),
              if (scope == _BodyScope.face)
                Padding(
                  padding: EdgeInsets.only(top: tab != null ? 8 : 0),
                  child: _Step1StaggerReveal(
                    key: ValueKey('s1-scope-face-$revealGeneration'),
                    delay: const Duration(milliseconds: 360),
                    child: _Step1SummaryCard(
                      title: 'Face',
                      subtitle: 'Procedures for the face',
                      iconAsset: 'assets/faceicon.png',
                      iconScale: 1.35,
                      onTap: () => onScopeChanged(null),
                    ),
                  ),
                ),
              if (scope == _BodyScope.body)
                Padding(
                  padding: EdgeInsets.only(top: tab != null || scope == _BodyScope.face ? 8 : 0),
                  child: _Step1StaggerReveal(
                    key: ValueKey('s1-scope-body-$revealGeneration'),
                    delay: const Duration(milliseconds: 360),
                    child: _Step1SummaryCard(
                      title: 'Body',
                      subtitle: 'Procedures for the body',
                      iconAsset: 'assets/bodyicon.png',
                      iconScale: 1.35,
                      onTap: () => onScopeChanged(null),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Step1RadialVisual extends StatelessWidget {
  const _Step1RadialVisual({
    required this.tab,
    required this.scope,
    required this.onTabChanged,
    required this.onScopeChanged,
  });

  final _FlowTab? tab;
  final _BodyScope? scope;
  final ValueChanged<_FlowTab?> onTabChanged;
  final ValueChanged<_BodyScope?> onScopeChanged;

  // Bottom arc of the ring (π/2 = bottom). Left → right, spaced farther apart.
  static const _slots = <_Step1RadialSlotData>[
    _Step1RadialSlotData(
      label: 'Aesthetic',
      iconAsset: 'assets/staricon.png',
      kind: _Step1RadialSlotKind.aesthetic,
      iconScale: 1.45,
      angle: 2.28,
    ),
    _Step1RadialSlotData(
      label: 'Surgery',
      iconAsset: 'assets/knifeicon.png',
      iconScale: 1.28,
      kind: _Step1RadialSlotKind.surgery,
      angle: 1.78,
    ),
    _Step1RadialSlotData(
      label: 'Face',
      iconAsset: 'assets/faceicon.png',
      iconScale: 1.28,
      kind: _Step1RadialSlotKind.face,
      angle: 1.36,
    ),
    _Step1RadialSlotData(
      label: 'Body',
      iconAsset: 'assets/bodyicon.png',
      iconScale: 1.28,
      kind: _Step1RadialSlotKind.body,
      angle: 0.86,
    ),
  ];

  bool _isSelected(_Step1RadialSlotData slot) {
    return switch (slot.kind) {
      _Step1RadialSlotKind.aesthetic => tab == _FlowTab.aesthetic,
      _Step1RadialSlotKind.surgery => tab == _FlowTab.surgery,
      _Step1RadialSlotKind.face => scope == _BodyScope.face,
      _Step1RadialSlotKind.body => scope == _BodyScope.body,
    };
  }

  void _onTap(_Step1RadialSlotData slot) {
    switch (slot.kind) {
      case _Step1RadialSlotKind.aesthetic:
        onTabChanged(tab == _FlowTab.aesthetic ? null : _FlowTab.aesthetic);
      case _Step1RadialSlotKind.surgery:
        onTabChanged(tab == _FlowTab.surgery ? null : _FlowTab.surgery);
      case _Step1RadialSlotKind.face:
        onScopeChanged(scope == _BodyScope.face ? null : _BodyScope.face);
      case _Step1RadialSlotKind.body:
        onScopeChanged(scope == _BodyScope.body ? null : _BodyScope.body);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = math.min(width * 1.18, 400.0);
        // Button arc sits under the chin; aura circle frames the head.
        final buttonCenter = Offset(width * 0.5, height * 0.55);
        final buttonRadius = width * 0.38;
        final auraCenter = Offset(width * 0.5, height * 0.32);
        final auraRadius = width * 0.40;

        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: _Step1AuraCircle(
                  center: auraCenter,
                  radius: auraRadius,
                ),
              ),
              Positioned(
                left: width * -0.04,
                right: width * -0.04,
                top: height * -0.02,
                bottom: height * 0.24,
                child: _Step1HeroFigure(
                  showBody: scope == _BodyScope.body,
                ),
              ),
              for (final slot in _slots)
                _Step1RadialSlotButton(
                  center: buttonCenter,
                  radius: buttonRadius + 4,
                  angle: slot.angle,
                  label: slot.label,
                  iconAsset: slot.iconAsset,
                  iconScale: slot.iconScale,
                  selected: _isSelected(slot),
                  onTap: () => _onTap(slot),
                ),
            ],
          ),
        );
      },
    );
  }
}

enum _Step1RadialSlotKind { aesthetic, surgery, face, body }

/// Face ↔ body hero crossfade — both layers stay mounted (avoids AnimatedSwitcher
/// + ImageFiltered semantics crashes that can poison the whole route tree).
class _Step1HeroFigure extends StatefulWidget {
  const _Step1HeroFigure({required this.showBody});

  final bool showBody;

  @override
  State<_Step1HeroFigure> createState() => _Step1HeroFigureState();
}

class _Step1HeroFigureState extends State<_Step1HeroFigure> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
      value: widget.showBody ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant _Step1HeroFigure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showBody == widget.showBody) return;
    if (widget.showBody) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _maskedHero({
    required String asset,
    required double fadeStart,
  }) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        return ui.Gradient.linear(
          Offset(0, bounds.height * fadeStart),
          Offset(0, bounds.height),
          const [
            Color(0xFFFFFFFF),
            Color(0xCCFFFFFF),
            Color(0x00FFFFFF),
          ],
          const [0.0, 0.55, 1.0],
        );
      },
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        filterQuality: FilterQuality.high,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final bodyT = Curves.easeInOutCubic.transform(_ctrl.value);
        final faceT = 1.0 - bodyT;
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.topCenter,
          children: [
            IgnorePointer(
              child: Opacity(
                opacity: faceT.clamp(0.0, 1.0),
                child: _maskedHero(
                  asset: _kStep1FaceHeroAsset,
                  fadeStart: 0.62,
                ),
              ),
            ),
            IgnorePointer(
              child: Opacity(
                opacity: bodyT.clamp(0.0, 1.0),
                child: _maskedHero(
                  asset: _kStep1BodyHeroAsset,
                  fadeStart: 0.72,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Step1RadialSlotData {
  const _Step1RadialSlotData({
    required this.label,
    required this.iconAsset,
    required this.kind,
    required this.angle,
    this.iconScale = 0.9,
  });

  final String label;
  final String iconAsset;
  final _Step1RadialSlotKind kind;
  final double angle;
  final double iconScale;
}

class _Step1RadialSlotButton extends StatelessWidget {
  const _Step1RadialSlotButton({
    required this.center,
    required this.radius,
    required this.angle,
    required this.label,
    required this.iconAsset,
    required this.iconScale,
    required this.selected,
    required this.onTap,
  });

  final Offset center;
  final double radius;
  final double angle;
  final String label;
  final String iconAsset;
  final double iconScale;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const buttonSize = 46.0;
    const slotWidth = 72.0;
    final anchor = Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
    final labelStyle = GoogleFonts.plusJakartaSans(
      fontSize: selected ? 11.5 : 10.5,
      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      color: selected ? ProcedureSelectionTheme.ink : ProcedureSelectionTheme.muted,
      height: 1.0,
    );

    return Positioned(
      left: anchor.dx - slotWidth / 2,
      top: anchor.dy - buttonSize / 2,
      width: slotWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: buttonSize,
                height: buttonSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: selected
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            ProcedureSelectionTheme.cardSelectedTop,
                            ProcedureSelectionTheme.cardSelectedMid,
                            ProcedureSelectionTheme.cardSelectedBottom,
                          ],
                          stops: [0.0, 0.48, 1.0],
                        )
                      : null,
                  color: selected ? null : Colors.white.withValues(alpha: 0.55),
                  border: selected
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(alpha: 0.72),
                          width: 1.2,
                        ),
                  boxShadow: selected
                      ? [
                          // Soft cream diffuse bloom — no hard edge / line.
                          BoxShadow(
                            color: const Color(0xFFEAE6E5).withValues(alpha: 0.55),
                            blurRadius: 22,
                            spreadRadius: 2,
                          ),
                          BoxShadow(
                            color: const Color(0xFFEAE6E5).withValues(alpha: 0.28),
                            blurRadius: 36,
                            spreadRadius: 4,
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.06),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                ),
                alignment: Alignment.center,
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    selected ? Colors.white : ProcedureSelectionTheme.muted,
                    BlendMode.srcIn,
                  ),
                  child: Image.asset(
                    iconAsset,
                    width: buttonSize * iconScale * 0.42,
                    height: buttonSize * iconScale * 0.42,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center, style: labelStyle, maxLines: 1),
        ],
      ),
    );
  }
}

class _Step1AuraCircle extends StatefulWidget {
  const _Step1AuraCircle({required this.center, required this.radius});

  final Offset center;
  final double radius;

  @override
  State<_Step1AuraCircle> createState() => _Step1AuraCircleState();
}

class _Step1AuraCircleState extends State<_Step1AuraCircle> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 9000))..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => CustomPaint(
        painter: _Step1AuraCirclePainter(
          center: widget.center,
          radius: widget.radius,
          progress: _anim.value,
        ),
      ),
    );
  }
}

class _Step1AuraCirclePainter extends CustomPainter {
  const _Step1AuraCirclePainter({
    required this.center,
    required this.radius,
    required this.progress,
  });

  final Offset center;
  final double radius;
  final double progress;

  static const _cream = Color(0xFFEAE6E5);
  static const _movingPoints = 5;
  static const _trail = 7;

  Offset _pointOnRing(double angle) {
    return Offset(
      center.dx + radius * math.cos(angle),
      center.dy + radius * math.sin(angle),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Soft aura ring without MaskFilter.blur (crashes iOS Simulator Impeller).
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = _cream.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = _cream.withValues(alpha: 0.32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.78)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );

    // Traveling light points — soft stacked discs, no Gaussian blur.
    for (var i = 0; i < _movingPoints; i++) {
      final base = progress + i / _movingPoints;
      final speed = 1.0 + (i % 3) * 0.12;
      final headT = (base * speed) % 1.0;
      final headAngle = headT * math.pi * 2 - math.pi / 2;

      for (var t = 0; t < _trail; t++) {
        final trailT = t / (_trail - 1);
        final angle = headAngle - trailT * 0.42;
        final p = _pointOnRing(angle);
        final fade = 1.0 - trailT;

        canvas.drawCircle(
          p,
          5.5 * fade + 1.5,
          Paint()..color = Colors.white.withValues(alpha: 0.10 + 0.22 * fade),
        );
        canvas.drawCircle(
          p,
          2.8 * fade + 0.8,
          Paint()..color = _cream.withValues(alpha: 0.22 + 0.35 * fade),
        );
        canvas.drawCircle(
          p,
          1.0 + 1.8 * fade,
          Paint()..color = Colors.white.withValues(alpha: 0.45 + 0.50 * fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Step1AuraCirclePainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.progress != progress;
  }
}

class _Step1SummaryCard extends StatelessWidget {
  const _Step1SummaryCard({
    required this.title,
    required this.subtitle,
    required this.iconAsset,
    required this.onTap,
    this.iconScale = 0.88,
  });

  final String title;
  final String subtitle;
  final String iconAsset;
  final VoidCallback onTap;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    const badgeSize = 40.0;
    final radius = BorderRadius.circular(20);
    const cream = Color(0xFFEAE6E5);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [
              // Compact cream diffuse bloom.
              BoxShadow(
                color: cream.withValues(alpha: 0.32),
                blurRadius: 14,
                spreadRadius: 0,
                offset: const Offset(0, -1),
              ),
              BoxShadow(
                color: cream.withValues(alpha: 0.16),
                blurRadius: 22,
                spreadRadius: 1,
              ),
              ...ProcedureGlassDecorations.depthShadow(compact: true),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              children: [
                ProcedureGlassSurface(
                  borderRadius: radius,
                  selected: true,
                  blur: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Row(
                      children: [
                        ProcedureCategoryIconBadge(
                          iconAsset: iconAsset,
                          selected: true,
                          size: badgeSize,
                          iconScale: iconScale,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  height: 1.1,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white.withValues(alpha: 0.82),
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 24,
                          height: 24,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.check_rounded, size: 14, color: Colors.black),
                        ),
                      ],
                    ),
                  ),
                ),
                // Small soft top light wash.
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 12,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.only(
                          topLeft: radius.topLeft,
                          topRight: radius.topRight,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            cream.withValues(alpha: 0.22),
                            cream.withValues(alpha: 0.06),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
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

class ProcedureSelectionScreen extends StatelessWidget {
  const ProcedureSelectionScreen({
    super.key,
    required this.revealGeneration,
    required this.selected,
    required this.tab,
    required this.scope,
    required this.isSurgery,
    required this.preset,
    required this.product,
    required this.zones,
    required this.volumeMl,
    required this.onPick,
    required this.onCustom,
    required this.onToggleZone,
    required this.onAddZone,
    required this.onPickBrand,
    required this.onVolumeChanged,
  });

  final int revealGeneration;
  final String selected;
  final _FlowTab tab;
  final _BodyScope scope;
  final bool isSurgery;
  final _ProcPreset? preset;
  final TextEditingController product;
  final Set<String> zones;
  final double volumeMl;
  final ValueChanged<_ProcPreset> onPick;
  final VoidCallback onCustom;
  final ValueChanged<String> onToggleZone;
  final Future<void> Function() onAddZone;
  final ValueChanged<String> onPickBrand;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final titleStyle = ProcedureSelectionTypography.display(
      size: 18,
      color: ProcedureSelectionTheme.ink,
    );
    final subtitleStyle = ProcedureSelectionTypography.body(
      size: 11,
      color: ProcedureSelectionTheme.muted,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topInset + 68, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step1StaggerReveal(
            key: ValueKey('s2-header-$revealGeneration'),
            delay: Duration.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('What did you get done?', style: titleStyle)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(999),
                        compact: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                          child: Text(
                            'Required',
                            style: GoogleFonts.urbanist(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.86),
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Tap your procedure — you can always edit details.',
                  style: subtitleStyle,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _Step1StaggerReveal(
            key: ValueKey('s2-picker-$revealGeneration'),
            delay: const Duration(milliseconds: 200),
            child: _ProcedurePicker(
              warmStyle: true,
              selected: selected,
              tab: tab,
              scope: scope,
              onPick: onPick,
              onCustom: onCustom,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.center,
            child: Text(
              'Required: choose procedure and treatment zone',
              textAlign: TextAlign.center,
              style: ProcedureSelectionTypography.body(
                size: 11,
                weight: FontWeight.w600,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _Step1StaggerReveal(
            key: ValueKey('s2-zones-$revealGeneration'),
            delay: const Duration(milliseconds: 320),
            child: _TreatmentZoneProductSection(
              warmStyle: true,
              scope: scope,
              isSurgery: isSurgery,
              preset: preset,
              product: product,
              zones: zones,
              volumeMl: volumeMl,
              onToggleZone: onToggleZone,
              onAddZone: onAddZone,
              onPickBrand: onPickBrand,
              onVolumeChanged: onVolumeChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _WarmWizardHeader extends StatelessWidget {
  const _WarmWizardHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: ProcedureSelectionTypography.display(size: 18, color: ProcedureSelectionTheme.ink),
        ),
        const SizedBox(height: 10),
        Text(
          subtitle,
          style: ProcedureSelectionTypography.body(
            size: 11,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
      ],
    );
  }
}

class _WarmSectionLabel extends StatelessWidget {
  const _WarmSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 2.2,
        height: 1.0,
        color: ProcedureSelectionTheme.sectionLabel,
      ),
    );
  }
}

class _TreatmentZoneProductSection extends StatelessWidget {
  const _TreatmentZoneProductSection({
    required this.scope,
    required this.isSurgery,
    required this.preset,
    required this.product,
    required this.zones,
    required this.volumeMl,
    required this.onToggleZone,
    required this.onAddZone,
    required this.onPickBrand,
    required this.onVolumeChanged,
    this.warmStyle = false,
  });

  final _BodyScope scope;
  final bool isSurgery;
  final _ProcPreset? preset;
  final TextEditingController product;
  final Set<String> zones;
  final double volumeMl;
  final ValueChanged<String> onToggleZone;
  final Future<void> Function() onAddZone;
  final ValueChanged<String> onPickBrand;
  final ValueChanged<double> onVolumeChanged;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    final hasImplantZone = zones.contains('Breasts') || zones.contains('Buttocks') || zones.contains('Butt') || zones.contains('Buttocks');

    return Column(
      children: [
        if (warmStyle && scope == _BodyScope.face)
          _WarmTreatmentZoneCard(
            selected: zones,
            onToggle: onToggleZone,
            entireFaceSelected: zones.contains(_kFullFaceZone),
            onEntireFaceTap: () => onToggleZone(_kFullFaceZone),
            onAddCustomZone: () => onAddZone(),
          )
        else if (warmStyle && scope == _BodyScope.body)
          _WarmBodyTreatmentZoneCard(
            zones: (() {
              final p = preset;
              if (p != null && p.scope == scope) return p.zones;
              return _kCommonBodyZones;
            })(),
            selected: zones,
            onToggle: onToggleZone,
            onAddCustomZone: () => onAddZone(),
          )
        else
          _Step2GlassPanel(
            warmStyle: warmStyle,
            title: 'Treatment zone',
            subtitle: scope == _BodyScope.face ? 'Tap the areas you want to treat' : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (scope == _BodyScope.face) ...[
                  _FacePointsMap(
                    selected: zones,
                    onToggle: onToggleZone,
                    entireFaceSelected: zones.contains(_kFullFaceZone),
                    onEntireFaceTap: () => onToggleZone(_kFullFaceZone),
                  ),
                  if (!warmStyle && zones.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Selected areas',
                      style: GoogleFonts.urbanist(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: _kStep1OnGlassMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _SelectedZoneChips(
                      zones: zones.toList()..sort(),
                      onRemove: onToggleZone,
                    ),
                  ],
                ] else ...[
                  _ZoneMultiPicker(
                    zones: (() {
                      final p = preset;
                      if (p != null && p.scope == scope) return p.zones;
                      return _kCommonBodyZones;
                    })(),
                    selected: zones,
                    onToggle: onToggleZone,
                    onAddCustom: onAddZone,
                    glassStyle: !warmStyle,
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 10),
        _Step2GlassPanel(
          warmStyle: warmStyle,
          title: isSurgery ? 'Product / Brand (optional)' : 'Product / Brand',
          child: Column(
            children: [
              if (warmStyle)
                ProcedureProductField(
                  controller: product,
                  label: isSurgery ? 'Implant / filler (optional)' : 'Product name',
                )
              else
                _Field(
                  controller: product,
                  label: isSurgery ? 'Implant / filler (optional)' : 'Product name',
                  icon: 'assets/icons/tag.svg',
                  glassStyle: !warmStyle,
                  warmStyle: warmStyle,
                ),
              const SizedBox(height: 10),
              _ProductChips(
                chips: preset?.productChips ?? const [],
                value: product.text.trim(),
                onPick: onPickBrand,
                glassStyle: !warmStyle,
                warmStyle: warmStyle,
              ),
              if (!isSurgery || hasImplantZone) ...[
                const SizedBox(height: 14),
                _VolumeMlStrip(
                  value: volumeMl,
                  onChanged: onVolumeChanged,
                  label: isSurgery ? 'Implant volume (cc)' : 'Volume (ml)',
                  min: isSurgery ? 50 : 0.5,
                  max: isSurgery ? 1000 : 5.0,
                  step: isSurgery ? 25 : 0.5,
                  valueFormatter: (v) => isSurgery ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
                  glassStyle: !warmStyle,
                  warmStyle: warmStyle,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Step2GlassPanel extends StatelessWidget {
  const _Step2GlassPanel({required this.title, required this.child, this.subtitle, this.warmStyle = false});

  final String title;
  final String? subtitle;
  final Widget child;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return ProcedureSelectionPanel(title: title, subtitle: subtitle, child: child, compactTitle: true);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: _kStep1Glass,
        borderRadius: BorderRadius.circular(_kStep1CardRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w800, color: _kStep1OnGlass, height: 1.1),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w500, color: _kStep1OnGlassMuted, height: 1.3),
              ),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Step1HeroCard extends StatefulWidget {
  const _Step1HeroCard({
    this.title = 'Choose type and area',
    this.subtitle = "Pick the procedure you've done",
    this.showGreeting = true,
    this.solidBackground = false,
    this.lightTypography = false,
    this.minHeight = 360.0,
  });

  final String title;
  final String subtitle;
  final bool showGreeting;
  final bool solidBackground;
  final bool lightTypography;
  final double minHeight;

  static const _bottomRadius = Radius.elliptical(180, 120);

  static String _greetingName(Map<String, dynamic>? profile, User? user) {
    final first = (profile?['firstName'] as String? ?? '').trim();
    if (first.isNotEmpty) return first;
    final email = (user?.email ?? '').trim();
    if (email.isEmpty) return 'there';
    final at = email.indexOf('@');
    if (at <= 0) return email;
    return email.substring(0, at);
  }

  @override
  State<_Step1HeroCard> createState() => _Step1HeroCardState();
}

class _Step1HeroCardState extends State<_Step1HeroCard> with SingleTickerProviderStateMixin {
  late final AnimationController _borderAnim;

  @override
  void initState() {
    super.initState();
    _borderAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 8000))..repeat();
  }

  @override
  void dispose() {
    _borderAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final height = topInset + widget.minHeight;
    final greetingStyle = GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w500, color: _kStep1OnGlassMuted);
    final titleStyle = GoogleFonts.urbanist(
      fontSize: 18,
      fontWeight: FontWeight.w800,
      color: widget.lightTypography ? _kStep1Navy : _kStep1OnGlass,
      height: 1.2,
    );
    final subtitleStyle = GoogleFonts.urbanist(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: widget.lightTypography ? _kStep3Label.withValues(alpha: 0.82) : _kStep1OnGlassMuted,
      height: 1.35,
    );

    return SizedBox(
      width: double.infinity,
      height: height,
      child: Stack(
        children: [
          if (widget.solidBackground)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _kStep1Navy,
                      _kStep1Navy.withValues(alpha: 0.92),
                      _kStep1Bg,
                    ],
                    stops: const [0.0, 0.72, 1.0],
                  ),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: _Step1HeroCard._bottomRadius,
                    bottomRight: _Step1HeroCard._bottomRadius,
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipper: const _Step1HeroFrameClipper(
                  bottomRadius: _Step1HeroCard._bottomRadius,
                ),
                child: const _Step1HeroDiffuseLight(),
              ),
            ),
          ),
          Positioned(
            top: topInset + (widget.showGreeting ? 28 : 22),
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.showGreeting) ...[
                    _Step1Greeting(style: greetingStyle),
                    const SizedBox(height: 4),
                  ],
                  Text(widget.title, textAlign: TextAlign.center, style: titleStyle),
                  const SizedBox(height: 4),
                  Text(
                    widget.subtitle,
                    textAlign: TextAlign.center,
                    style: subtitleStyle,
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _borderAnim,
                builder: (context, _) => CustomPaint(
                  painter: _Step1HeroBorderPainter(
                    progress: _borderAnim.value,
                    bottomRadius: _Step1HeroCard._bottomRadius,
                    lightSurface: widget.lightTypography,
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

class _Step1HeroFrameClipper extends CustomClipper<Path> {
  const _Step1HeroFrameClipper({required this.bottomRadius});

  final Radius bottomRadius;

  @override
  Path getClip(Size size) {
    return Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, 0, size.width, size.height),
          bottomLeft: bottomRadius,
          bottomRight: bottomRadius,
        ),
      );
  }

  @override
  bool shouldReclip(covariant _Step1HeroFrameClipper oldClipper) {
    return oldClipper.bottomRadius != bottomRadius;
  }
}

/// Soft cream diffuse light along the curved bottom of the step-1 hero frame.
/// No [ImageFiltered] / Gaussian blur — those crash iOS Simulator Impeller.
class _Step1HeroDiffuseLight extends StatelessWidget {
  const _Step1HeroDiffuseLight();

  static const _cream = Color(0xFFEAE6E5);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: const Alignment(0, 0.85),
          child: FractionallySizedBox(
            widthFactor: 1.35,
            heightFactor: 0.58,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, 0.35),
                  radius: 1.05,
                  colors: [
                    Color(0xD9EAE6E5),
                    Color(0x8CEAE6E5),
                    Color(0x33EAE6E5),
                    Color(0x00EAE6E5),
                  ],
                  stops: [0.0, 0.35, 0.68, 1.0],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 1.1,
            heightFactor: 0.36,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, 0.55),
                  radius: 1.0,
                  colors: [
                    Colors.white.withValues(alpha: 0.72),
                    _cream.withValues(alpha: 0.42),
                    _cream.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.48, 1.0],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 1.0,
            heightFactor: 0.18,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    _cream.withValues(alpha: 0.50),
                    _cream.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.50, 1.0],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Step1HeroBorderPainter extends CustomPainter {
  const _Step1HeroBorderPainter({
    required this.progress,
    required this.bottomRadius,
    this.lightSurface = false,
  });

  final double progress;
  final Radius bottomRadius;
  final bool lightSurface;

  static const _snakeLength = 0.38;
  static const _segments = 30;

  Path _framePath(Size size) {
    return Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, 0, size.width, size.height),
          bottomLeft: bottomRadius,
          bottomRight: bottomRadius,
        ),
      );
  }

  Path _extractLoop(ui.PathMetric metric, double start, double length) {
    final total = metric.length;
    if (length <= 0) return Path();
    final end = start + length;
    if (end <= total) return metric.extractPath(start, end);
    return Path()
      ..addPath(metric.extractPath(start, total), Offset.zero)
      ..addPath(metric.extractPath(0, end - total), Offset.zero);
  }

  /// Path offset at the bottom-left rounded corner where the border turns upward.
  double _bottomLeftTurnOffset(ui.PathMetric metric, Size size) {
    final rx = bottomRadius.x;
    final ry = bottomRadius.y;
    // End of the bottom edge / start of the bottom-left arc (path turns up the left side).
    final target = Offset(rx, size.height);
    final brArc = math.pi * (rx + ry) / 2;
    final linearBeforeBlArc = size.width + (size.height - ry) + brArc + (size.width - 2 * rx);
    final arcSpan = brArc;
    final windowStart = math.max(0.0, linearBeforeBlArc - 4);
    final windowEnd = math.min(metric.length, linearBeforeBlArc + arcSpan + 4);

    var bestOffset = windowStart;
    var bestDist = double.infinity;
    const samples = 200;
    for (var i = 0; i <= samples; i++) {
      final offset = windowStart + (windowEnd - windowStart) * i / samples;
      final tangent = metric.getTangentForOffset(offset);
      if (tangent == null) continue;
      final dist = (tangent.position - target).distanceSquared;
      if (dist < bestDist) {
        bestDist = dist;
        bestOffset = offset;
      }
    }
    return bestOffset;
  }

  void _drawSnake(Canvas canvas, ui.PathMetric metric, double headPos) {
    final total = metric.length;
    final snakeLen = total * _snakeLength;
    final pieceLen = snakeLen / _segments;

    for (var i = 0; i < _segments; i++) {
      final t = i / (_segments - 1);
      final distFromHead = (1 - t) * snakeLen;
      var pieceStart = (headPos - distFromHead) % total;
      if (pieceStart < 0) pieceStart += total;

      final piecePath = _extractLoop(metric, pieceStart, pieceLen);
      final alpha = 0.1 + 0.9 * t;
      final strokeW = 1.1 + 2.2 * t;

      if (t > 0.72) {
        canvas.drawPath(
          piecePath,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.18 * alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeW + 4
            ..strokeCap = StrokeCap.round,
        );
      }

      canvas.drawPath(
        piecePath,
        Paint()
          ..color = Colors.white.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _framePath(size);

    // Soft cream rim without MaskFilter.blur (Impeller / iOS Simulator safe).
    const cream = Color(0xFFEAE6E5);
    canvas.drawPath(
      path,
      Paint()
        ..color = cream.withValues(alpha: lightSurface ? 0.28 : 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = cream.withValues(alpha: lightSurface ? 0.22 : 0.14)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: lightSurface ? 0.18 : 0.12)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );

    for (final metric in path.computeMetrics()) {
      final start = _bottomLeftTurnOffset(metric, size);
      var headPos = (start + progress * metric.length) % metric.length;
      _drawSnake(canvas, metric, headPos);
    }
  }

  @override
  bool shouldRepaint(covariant _Step1HeroBorderPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.lightSurface != lightSurface;
  }
}

class _Step1Greeting extends StatelessWidget {
  const _Step1Greeting({required this.style});

  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Text('Hi, there!', textAlign: TextAlign.center, style: style);
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: AuthService().userProfileStream(user.uid),
      builder: (context, snap) {
        Map<String, dynamic>? profile;
        if (snap.hasData && snap.data!.exists) {
          profile = snap.data!.data();
        }
        final name = _Step1HeroCard._greetingName(profile, user);
        return Text('Hi, $name!', textAlign: TextAlign.center, style: style);
      },
    );
  }
}

class _DetailsStep extends StatelessWidget {
  const _DetailsStep({
    super.key,
    required this.revealGeneration,
    required this.practitioner,
    required this.clinic,
    required this.cost,
    required this.date,
    required this.redoAfterValue,
    required this.redoAfterUnit,
    required this.onPickDate,
    required this.onRedoChanged,
    required this.redoAfterNeedsUnitHint,
    required this.onRedoAfterUnitRequired,
    required this.aiRedoLoading,
    required this.aiRedoDone,
    required this.aiRedoSuggestedDate,
    required this.onAiChooseRedo,
    required this.onAiDismissDone,
  });

  final int revealGeneration;
  final TextEditingController practitioner;
  final TextEditingController clinic;
  final TextEditingController cost;
  final DateTime date;
  final int redoAfterValue;
  final String? redoAfterUnit;
  final VoidCallback onPickDate;
  final void Function(int, String?) onRedoChanged;
  final bool redoAfterNeedsUnitHint;
  final VoidCallback onRedoAfterUnitRequired;
  final bool aiRedoLoading;
  final bool aiRedoDone;
  final DateTime? aiRedoSuggestedDate;
  final Future<void> Function() onAiChooseRedo;
  final VoidCallback onAiDismissDone;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topInset + 82, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step1StaggerReveal(
            key: ValueKey('s3-hero-$revealGeneration'),
            delay: Duration.zero,
            child: const _WarmWizardHeader(
              title: 'Who & where?',
              subtitle: 'Add details about your procedure',
            ),
          ),
          const SizedBox(height: 20),
          _Step1StaggerReveal(
            key: ValueKey('s3-doctor-$revealGeneration'),
            delay: const Duration(milliseconds: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Step3TextField(
                  label: 'Doctor',
                  controller: practitioner,
                  icon: 'assets/icons/user.svg',
                  warmStyle: true,
                ),
                const SizedBox(height: 12),
                _Step3TextField(
                  label: 'Clinic',
                  controller: clinic,
                  icon: 'assets/icons/clinic.svg',
                  warmStyle: true,
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _Step3DateField(date: date, onTap: onPickDate, warmStyle: true),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Step3TextField(
                        label: 'Cost',
                        controller: cost,
                        icon: 'assets/icons/cost.svg',
                        hint: 'Add cost',
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        warmStyle: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _RedoAfterPicker(
                  value: redoAfterValue,
                  unit: redoAfterUnit,
                  onChanged: onRedoChanged,
                  warmStyle: true,
                  showUnitHint: redoAfterNeedsUnitHint,
                  onUnitRequired: onRedoAfterUnitRequired,
                  promo: ProcedureGlassSurface(
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: ProcedureGlassDecorations.iconBadge(),
                          alignment: Alignment.center,
                          child: aiRedoLoading
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2.0, color: ProcedureSelectionTheme.ink),
                                )
                              : Icon(Icons.auto_awesome, size: 18, color: ProcedureSelectionTheme.ink),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Let AI choose it for you',
                                style: ProcedureSelectionTypography.label(
                                  size: 12,
                                  weight: FontWeight.w700,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                aiRedoDone && aiRedoSuggestedDate != null
                                    ? 'Suggested redo date: ${MaterialLocalizations.of(context).formatMediumDate(aiRedoSuggestedDate!)}'
                                    : 'Based on your procedure, we’ll suggest the best redo time.',
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  weight: FontWeight.w500,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: aiRedoLoading
                              ? null
                              : (aiRedoDone ? onAiDismissDone : onAiChooseRedo),
                          style: FilledButton.styleFrom(
                            backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: Text(
                            aiRedoLoading ? 'Choosing…' : (aiRedoDone ? 'Done' : 'Choose'),
                            style: ProcedureSelectionTypography.label(
                              size: 12,
                              weight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step3FieldLabel extends StatelessWidget {
  const _Step3FieldLabel(this.text, {this.warmStyle = false});

  final String text;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return Text(
        text,
        style: ProcedureSelectionTypography.label(
          size: 10,
          weight: FontWeight.w600,
          color: ProcedureSelectionTheme.muted,
        ),
      );
    }
    return Text(
      text,
      style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w600, color: _kStep3Label),
    );
  }
}

class _Step3TextField extends StatelessWidget {
  const _Step3TextField({
    required this.label,
    required this.controller,
    required this.icon,
    this.hint,
    this.keyboardType,
    this.warmStyle = false,
  });

  final String label;
  final TextEditingController controller;
  final String icon;
  final String? hint;
  final TextInputType? keyboardType;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step3FieldLabel(label, warmStyle: true),
          const SizedBox(height: 6),
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ProcedureSelectionTheme.cardBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _SvgIcon(icon, size: 16, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.75)),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: controller,
                    keyboardType: keyboardType,
                    keyboardAppearance: Brightness.dark,
                    textCapitalization: TextCapitalization.sentences,
                    style: ProcedureSelectionTypography.label(
                      size: 13,
                      weight: FontWeight.w600,
                      color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                    ),
                    decoration: InputDecoration(
                      hintText: hint ?? label,
                      hintStyle: ProcedureSelectionTypography.body(
                        size: 13,
                        color: ProcedureSelectionTheme.muted.withValues(alpha: 0.85),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Step3FieldLabel(label),
        const SizedBox(height: 6),
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: _kStep3FieldBg,
            borderRadius: BorderRadius.circular(_kStep3FieldRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              _SvgIcon(icon, size: 18, color: Colors.white.withValues(alpha: 0.72)),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: controller,
                  keyboardType: keyboardType,
                  keyboardAppearance: Brightness.dark,
                  textCapitalization: TextCapitalization.sentences,
                  style: GoogleFonts.urbanist(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: hint ?? label,
                    hintStyle: GoogleFonts.urbanist(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.88),
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 22, color: Colors.white.withValues(alpha: 0.45)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Step3DateField extends StatelessWidget {
  const _Step3DateField({required this.date, required this.onTap, this.warmStyle = false});

  final DateTime date;
  final VoidCallback onTap;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Step3FieldLabel('Date', warmStyle: true),
          const SizedBox(height: 6),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.52),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ProcedureSelectionTheme.cardBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _SvgIcon('assets/icons/calendar.svg', size: 16, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.75)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        formatDate(date),
                        style: ProcedureSelectionTypography.label(
                          size: 13,
                          weight: FontWeight.w600,
                          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                        ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Step3FieldLabel('Date'),
        const SizedBox(height: 6),
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(_kStep3FieldRadius),
            onTap: onTap,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: _kStep3FieldBg,
                borderRadius: BorderRadius.circular(_kStep3FieldRadius),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  _SvgIcon('assets/icons/calendar.svg', size: 18, color: Colors.white.withValues(alpha: 0.72)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      formatDate(date),
                      style: GoogleFonts.urbanist(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 22, color: Colors.white.withValues(alpha: 0.45)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecoveryStep extends StatelessWidget {
  const _RecoveryStep({
    super.key,
    required this.revealGeneration,
    required this.recoveryValue,
    required this.recoveryUnit,
    required this.beforePhotoPath,
    required this.afterPhotoPath,
    required this.pain,
    required this.notes,
    required this.onRecoveryChanged,
    required this.onPainChanged,
    required this.onBeforeChanged,
    required this.onAfterChanged,
    required this.aiRecoveryLoading,
    required this.aiRecoveryDone,
    required this.onAiChooseRecovery,
    required this.onAiDismissDone,
  });

  final int revealGeneration;
  final int recoveryValue;
  final String? recoveryUnit;
  final String? beforePhotoPath;
  final String? afterPhotoPath;
  final String? pain;
  final TextEditingController notes;
  final void Function(int, String?) onRecoveryChanged;
  final ValueChanged<String?> onPainChanged;
  final ValueChanged<String?> onBeforeChanged;
  final ValueChanged<String?> onAfterChanged;
  final bool aiRecoveryLoading;
  final bool aiRecoveryDone;
  final Future<void> Function() onAiChooseRecovery;
  final VoidCallback onAiDismissDone;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topInset + 68, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step1StaggerReveal(
            key: ValueKey('s4-header-$revealGeneration'),
            delay: Duration.zero,
            child: const _WarmWizardHeader(
              title: 'Recovery & experience',
              subtitle: 'Log what happened — your future self will thank you.',
            ),
          ),
          const SizedBox(height: 20),
          _Step1StaggerReveal(
            key: ValueKey('s4-photos-$revealGeneration'),
            delay: const Duration(milliseconds: 120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _WarmSectionLabel('Before / After'),
                const SizedBox(height: 8),
                _BeforeAfterPhotos(
                  beforePath: beforePhotoPath,
                  afterPath: afterPhotoPath,
                  onBeforeChanged: onBeforeChanged,
                  onAfterChanged: onAfterChanged,
                  warmStyle: true,
                  showTitle: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Step1StaggerReveal(
            key: ValueKey('s4-recovery-$revealGeneration'),
            delay: const Duration(milliseconds: 220),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Step3FieldLabel('Recovery time suggested by doctor', warmStyle: true),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  child: ProcedureGlassSurface(
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: ProcedureGlassDecorations.iconBadge(),
                        alignment: Alignment.center,
                        child: aiRecoveryLoading
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2.0, color: ProcedureSelectionTheme.ink),
                              )
                            : Icon(Icons.auto_awesome, size: 18, color: ProcedureSelectionTheme.ink),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Let AI choose it for you',
                              style: ProcedureSelectionTypography.label(
                                size: 12,
                                weight: FontWeight.w700,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Based on your treatment, we’ll suggest a recovery duration.',
                              style: ProcedureSelectionTypography.body(
                                size: 11,
                                weight: FontWeight.w500,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: aiRecoveryLoading
                            ? null
                            : (aiRecoveryDone ? onAiDismissDone : onAiChooseRecovery),
                        style: FilledButton.styleFrom(
                          backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          aiRecoveryLoading ? 'Choosing…' : (aiRecoveryDone ? 'Done' : 'Choose'),
                          style: ProcedureSelectionTypography.label(
                            size: 12,
                            weight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                  ),
                ),
                const SizedBox(height: 10),
                _RecoveryDurationPicker(
                  value: recoveryValue,
                  unit: recoveryUnit,
                  onChanged: onRecoveryChanged,
                  warmStyle: true,
                ),
                const SizedBox(height: 14),
                const _Step3FieldLabel('Pain during treatment', warmStyle: true),
                const SizedBox(height: 8),
                _PainRow(
                  value: pain,
                  onPick: (v) => onPainChanged(v.isEmpty ? null : v),
                  warmStyle: true,
                ),
                const SizedBox(height: 14),
                const _Step3FieldLabel("Doctor's note / your observations", warmStyle: true),
                const SizedBox(height: 8),
                _Step4NotesField(controller: notes, warmStyle: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Step4NotesField extends StatefulWidget {
  const _Step4NotesField({required this.controller, this.warmStyle = false});

  final TextEditingController controller;
  final bool warmStyle;
  static const _maxLength = 1000;

  @override
  State<_Step4NotesField> createState() => _Step4NotesFieldState();
}

class _Step4NotesFieldState extends State<_Step4NotesField> {
  @override
  Widget build(BuildContext context) {
    final fieldBg = widget.warmStyle ? Colors.white.withValues(alpha: 0.52) : _kStep3FieldBg;
    final radius = widget.warmStyle ? 12.0 : _kStep3FieldRadius;
    final textStyle = widget.warmStyle
        ? ProcedureSelectionTypography.body(size: 13, weight: FontWeight.w500, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88))
        : GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white, height: 1.45);
    final hintStyle = widget.warmStyle
        ? ProcedureSelectionTypography.body(size: 13, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.75))
        : GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.42));
    final counterStyle = widget.warmStyle
        ? ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted.withValues(alpha: 0.65))
        : GoogleFonts.urbanist(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.38));

    return Container(
      decoration: BoxDecoration(
        color: fieldBg,
        borderRadius: BorderRadius.circular(radius),
        border: widget.warmStyle ? Border.all(color: ProcedureSelectionTheme.cardBorder) : null,
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        children: [
          TextFormField(
            controller: widget.controller,
            maxLines: 5,
            maxLength: _Step4NotesField._maxLength,
            maxLengthEnforcement: MaxLengthEnforcement.enforced,
            keyboardAppearance: Brightness.dark,
            textCapitalization: TextCapitalization.sentences,
            style: textStyle,
            decoration: InputDecoration(
              hintText: 'Write anything important…',
              hintStyle: hintStyle,
              border: InputBorder.none,
              counterText: '',
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final length = widget.controller.text.characters.length;
                return Text(
                  '$length/${_Step4NotesField._maxLength}',
                  style: counterStyle,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RevealStep extends StatelessWidget {
  const _RevealStep({
    super.key,
    required this.revealGeneration,
    required this.title,
    required this.meta,
    required this.zone,
    required this.cost,
    required this.currency,
    required this.recoveryValue,
    required this.recoveryUnit,
    required this.category,
    required this.product,
    required this.volumeMl,
    required this.pain,
    required this.note,
    required this.postLive,
    required this.onPostLiveChanged,
    this.nextAppointmentLabel,
  });

  final int revealGeneration;
  final String title;
  final String meta;
  final String zone;
  final String cost;
  final String currency;
  final int? recoveryValue;
  final String? recoveryUnit;
  final String category;
  final String product;
  final double? volumeMl;
  final String? pain;
  final String note;
  final bool postLive;
  final ValueChanged<bool> onPostLiveChanged;
  final String? nextAppointmentLabel;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topInset + 68, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step1StaggerReveal(
            key: ValueKey('s5-header-$revealGeneration'),
            delay: Duration.zero,
            child: const _WarmWizardHeader(
              title: 'All set?',
              subtitle: 'Preview your entry before saving.',
            ),
          ),
          const SizedBox(height: 20),
          _Step1StaggerReveal(
            key: ValueKey('s5-card-$revealGeneration'),
            delay: const Duration(milliseconds: 200),
            child: ProcedureSelectionPanel(
              title: 'Summary',
              compactTitle: true,
              child: _GlowRevealCard(
                title: title,
                meta: meta,
                zone: zone,
                cost: cost,
                currency: currency,
                recoveryValue: recoveryValue,
                recoveryUnit: recoveryUnit,
                category: category,
                product: product,
                volumeMl: volumeMl,
                pain: pain,
                note: note,
                nextAppointmentLabel: nextAppointmentLabel,
                warmStyle: true,
              ),
            ),
          ),
          const SizedBox(height: 14),
          _Step1StaggerReveal(
            key: ValueKey('s5-live-$revealGeneration'),
            delay: const Duration(milliseconds: 320),
            child: _FormPostLiveCard(
              value: postLive,
              onChanged: onPostLiveChanged,
            ),
          ),
        ],
      ),
    );
  }
}

class _FormPostLiveCard extends StatelessWidget {
  const _FormPostLiveCard({
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
                      fontSize: 13,
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
                      fontSize: 11,
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

// ---------- Building blocks ----------

class _SmartPanel extends StatelessWidget {
  const _SmartPanel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _kSurface.withValues(alpha: 0.82), borderRadius: BorderRadius.circular(16), border: Border.all(color: _kStroke)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: _kInk, borderRadius: BorderRadius.circular(99))),
              const SizedBox(width: 8),
              Text(title, style: GoogleFonts.urbanist(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.6, color: _kInk)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.icon,
    this.keyboardType,
    this.glassStyle = false,
    this.warmStyle = false,
  });
  final TextEditingController controller;
  final String label;
  final String icon;
  final TextInputType? keyboardType;
  final bool glassStyle;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    final labelColor = warmStyle ? ProcedureSelectionTheme.muted : (glassStyle ? _kStep1OnGlassMuted : _kMuted);
    final iconColor = warmStyle ? ProcedureSelectionTheme.muted : (glassStyle ? _kStep1OnGlassMuted : _kMuted);
    final fill = warmStyle ? ProcedureSelectionTheme.fieldFill : (glassStyle ? _kStep1HeroGlass : _kSurface);
    final border = warmStyle ? ProcedureSelectionTheme.ink.withValues(alpha: 0.08) : (glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke);
    final focusBorder = warmStyle ? ProcedureSelectionTheme.ink : (glassStyle ? Colors.white.withValues(alpha: 0.45) : _kInk);
    final textStyle = warmStyle
        ? ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w600, color: ProcedureSelectionTheme.ink)
        : (glassStyle ? GoogleFonts.urbanist(color: _kStep1OnGlass, fontWeight: FontWeight.w600) : null);

    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      keyboardAppearance: glassStyle && !warmStyle ? Brightness.dark : Brightness.light,
      style: textStyle,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: warmStyle
            ? ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w600, color: labelColor)
            : GoogleFonts.urbanist(color: labelColor, fontWeight: FontWeight.w600),
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: _SvgIcon(icon, size: 16, color: iconColor),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: focusBorder, width: 1.5)),
      ),
    );
  }
}

class _SvgIcon extends StatelessWidget {
  const _SvgIcon(this.asset, {required this.size, this.color = _kMuted});
  final String asset;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(asset, width: size, height: size, colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
  }
}

class _TopCircleButton extends StatelessWidget {
  const _TopCircleButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
    this.glassStyle = false,
    this.blackStyle = false,
  });
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  final bool glassStyle;
  final bool blackStyle;

  @override
  Widget build(BuildContext context) {
    if (blackStyle) {
      return _BlackCircleButton(icon: icon, onTap: onTap);
    }
    if (glassStyle) {
      return _GlassCircleButton(icon: icon, onTap: onTap);
    }

    final bg = filled ? _kInk : _kSurface.withValues(alpha: 0.92);
    final fg = filled ? _kSurface : _kInk;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: _kStroke)),
        child: Icon(icon, color: fg, size: 20),
      ),
    );
  }
}

class _BlackCircleButton extends StatelessWidget {
  const _BlackCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

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
          splashColor: Colors.white.withValues(alpha: 0.12),
          highlightColor: Colors.white.withValues(alpha: 0.06),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: onTap == null ? Colors.black.withValues(alpha: 0.28) : Colors.black.withValues(alpha: 0.55),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Center(
              child: Icon(
                icon,
                size: 22,
                color: Colors.white.withValues(alpha: onTap == null ? 0.7 : 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  const _GlassCircleButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

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
                  // Solid frosted fill — no BackdropFilter (Impeller / iOS Simulator safe).
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
  bool shouldRepaint(covariant _GlassCircleRimPainter oldDelegate) => false;
}

class _StepBars extends StatelessWidget {
  const _StepBars({required this.step, required this.total, this.onVideo = false});
  final int step;
  final int total;
  final bool onVideo;

  @override
  Widget build(BuildContext context) {
    Color c(int i) {
      if (step >= i) return onVideo ? _kStep1OnGlass : _kInk;
      return onVideo ? Colors.white.withValues(alpha: 0.28) : const Color(0x261A1A2E);
    }
    return Row(
      children: [
        for (int i = 0; i < total; i++) ...[
          Expanded(child: Container(height: 4, decoration: BoxDecoration(color: c(i), borderRadius: BorderRadius.circular(2)))),
          if (i != total - 1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

class _FlowTabs extends StatelessWidget {
  const _FlowTabs({required this.value, required this.onChanged});
  final _FlowTab value;
  final ValueChanged<_FlowTab> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(_FlowTab t, String label) {
      final sel = value == t;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onChanged(t),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(color: sel ? _kInk : _kSurface2, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kStroke)),
            child: Center(
              child: Text(label, style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w900, color: sel ? _kSurface : _kInk)),
            ),
          ),
        ),
      );
    }

    return Row(children: [tab(_FlowTab.aesthetic, 'Aesthetic'), const SizedBox(width: 10), tab(_FlowTab.surgery, 'Surgery')]);
  }
}

class _ScopeTabs extends StatelessWidget {
  const _ScopeTabs({required this.value, required this.onChanged});
  final _BodyScope value;
  final ValueChanged<_BodyScope> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(_BodyScope t, String label) {
      final sel = value == t;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onChanged(t),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(color: sel ? _kInk : _kSurface2, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kStroke)),
            child: Center(
              child: Text(label, style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w900, color: sel ? _kSurface : _kInk)),
            ),
          ),
        ),
      );
    }

    return Row(children: [tab(_BodyScope.face, 'Face'), const SizedBox(width: 10), tab(_BodyScope.body, 'Body')]);
  }
}

// ── Step 1: Type & area cards ─────────────────────────────────────────────────

class _TypeLogoPicker extends StatelessWidget {
  const _TypeLogoPicker({required this.value, required this.onChanged});

  final _FlowTab? value;
  final ValueChanged<_FlowTab?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Step1CategoryCard(
            selected: value == _FlowTab.aesthetic,
            title: 'Aesthetic',
            subtitle: 'Non-surgical procedures',
            iconAsset: 'assets/staricon.png',
            onTap: () => onChanged(value == _FlowTab.aesthetic ? null : _FlowTab.aesthetic),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Step1CategoryCard(
            selected: value == _FlowTab.surgery,
            title: 'Surgery',
            subtitle: 'Surgical procedures',
            iconAsset: 'assets/knifeicon.png',
            iconScale: 1.35,
            onTap: () => onChanged(value == _FlowTab.surgery ? null : _FlowTab.surgery),
          ),
        ),
      ],
    );
  }
}

class _AreaLogoPicker extends StatelessWidget {
  const _AreaLogoPicker({required this.value, required this.onChanged});

  final _BodyScope? value;
  final ValueChanged<_BodyScope?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Step1CategoryCard(
            selected: value == _BodyScope.face,
            title: 'Face',
            subtitle: 'Procedures for the face',
            iconAsset: 'assets/faceicon.png',
            iconScale: 1.35,
            onTap: () => onChanged(value == _BodyScope.face ? null : _BodyScope.face),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Step1CategoryCard(
            selected: value == _BodyScope.body,
            title: 'Body',
            subtitle: 'Procedures for the body',
            iconAsset: 'assets/bodyicon.png',
            iconScale: 1.35,
            onTap: () => onChanged(value == _BodyScope.body ? null : _BodyScope.body),
          ),
        ),
      ],
    );
  }
}

// ---------- Procedures ----------

class _ProcPreset {
  const _ProcPreset({
    required this.name,
    required this.category,
    required this.emoji,
    required this.tagline,
    required this.recoveryDays,
    required this.productChips,
    required this.zones,
    required this.scope,
    this.iconAsset,
  });

  final String name;
  final String category;
  final String emoji;
  final String tagline;
  final int recoveryDays;
  final List<String> productChips;
  final List<String> zones;
  final _BodyScope scope;
  final String? iconAsset;

  bool get isSurgery => category.toLowerCase() == 'surgery';
}

const _kFullFaceZone = 'Entire face';

/// Face-map zones that stay individually togglable while [Entire face] is selected.
const _kEntireFaceExcludedZones = {'Neck', 'Ears'};

bool _faceDotSelected(String zone, Set<String> selected) {
  if (selected.contains(_kFullFaceZone)) {
    if (_kEntireFaceExcludedZones.contains(zone)) {
      return selected.contains(zone);
    }
    return true;
  }
  return selected.contains(zone);
}

const _kCommonZones = <String>[
  _kFullFaceZone,
  'Forehead',
  'Scalp',
  'Upper eyes',
  'Under-eyes',
  'Cheeks',
  'Nose',
  'Lips',
  'Jawline',
  'Chin',
  'Temples',
  'Nasolabial folds',
  'Marionette lines',
  'Ears',
  'Neck',
];

const _kCommonBodyZones = <String>[
  'Abdomen',
  'Flanks',
  'Waist',
  'Hips',
  'Thighs',
  'Buttocks',
  'Arms',
  'Knees',
  'Back',
  'Breasts',
  'Neck',
  'Chest',
  'Hands',
  'Intimate',
];

String _normalizeZone(String z) {
  final s = z.trim();
  if (s.isEmpty) return s;
  final lower = s.toLowerCase();
  if (lower == 'under-eye' || lower == 'under eye' || lower == 'under-eyes' || lower == 'under eyes') return 'Under-eyes';
  if (lower == 'upper-eye' || lower == 'upper eye' || lower == 'upper-eyes' || lower == 'upper eyes') return 'Upper eyes';
  if (lower == 'nasolabial fold' || lower == 'nasolabial folds' || lower == 'nlf') return 'Nasolabial folds';
  if (lower == 'marionette line' || lower == 'marionette lines' || lower == 'marionette') return 'Marionette lines';
  if (lower == 'cheek' || lower == 'cheeks') return 'Cheeks';
  if (lower == 'lip' || lower == 'lips') return 'Lips';
  if (lower == 'jaw' || lower == 'jawline') return 'Jawline';
  if (lower == 'forehead') return 'Forehead';
  if (lower == 'scalp') return 'Scalp';
  if (lower == 'temple' || lower == 'temples') return 'Temples';
  if (lower == 'nose') return 'Nose';
  if (lower == 'chin') return 'Chin';
  if (lower == 'neck') return 'Neck';
  if (lower == 'ear' || lower == 'ears') return 'Ears';
  if (lower == 'intimate' ||
      lower == 'intimate zone' ||
      lower == 'genital' ||
      lower == 'genitals' ||
      lower == 'labia' ||
      lower == 'vulva' ||
      lower == 'penis' ||
      lower == 'pubic' ||
      lower == 'pubic area') {
    return 'Intimate';
  }
  if (lower == 'full face' || lower == 'entire face' || lower == 'whole face') return _kFullFaceZone;
  return s;
}

void _toggleTreatmentZone(Set<String> zones, _BodyScope? scope, String z) {
  final nz = _normalizeZone(z);
  final isFace = scope == _BodyScope.face;

  if (isFace && nz == _kFullFaceZone) {
    if (zones.contains(_kFullFaceZone)) {
      zones.remove(_kFullFaceZone);
    } else {
      zones.removeWhere(
        (zone) => !_kEntireFaceExcludedZones.contains(zone) && _zoneMatchesScope(zone, _BodyScope.face),
      );
      zones.add(_kFullFaceZone);
    }
    return;
  }

  if (isFace && zones.contains(_kFullFaceZone)) {
    if (_kEntireFaceExcludedZones.contains(nz)) {
      if (zones.contains(nz)) {
        zones.remove(nz);
      } else {
        zones.add(nz);
      }
      return;
    }

    // Entire face is on — tapping a highlighted zone removes just that zone.
    zones.remove(_kFullFaceZone);
    for (final zone in _kFaceMapZoneNames) {
      if (zone != nz) {
        zones.add(zone);
      }
    }
    return;
  }

  if (zones.contains(nz)) {
    zones.remove(nz);
  } else {
    zones.add(nz);
  }
}

bool _zoneMatchesScope(String zone, _BodyScope scope) {
  final nz = _normalizeZone(zone);
  final face = _kCommonZones.map(_normalizeZone).toSet();
  final body = _kCommonBodyZones.map(_normalizeZone).toSet();
  return scope == _BodyScope.face ? face.contains(nz) : body.contains(nz);
}

final _kPresets = <String, List<_ProcPreset>>{
  'Injectables': [
    _ProcPreset(
      name: 'Filler',
      category: 'Injectables',
      emoji: '💉',
      iconAsset: 'assets/injection.png',
      tagline: 'HA / CaHA / PLLA',
      recoveryDays: 7,
      productChips: ['Juvederm', 'Restylane', 'Teosyal', 'Belotero', 'Radiesse'],
      zones: ['Lips', 'Cheeks', 'Jawline', 'Chin', 'Nose', 'Temples', 'Nasolabial folds', 'Marionette lines', 'Under-eyes'],
      scope: _BodyScope.face,
    ),
    _ProcPreset(
      name: 'Botox',
      category: 'Injectables',
      emoji: '✨',
      iconAsset: 'assets/botoxicon.png',
      tagline: 'Toxin · 3–4 mo',
      recoveryDays: 0,
      productChips: ['Botox (Allergan)', 'Dysport', 'Xeomin', 'Bocouture', 'Nuceiva'],
      zones: ['Forehead', 'Temples', 'Under-eyes', 'Jawline', 'Chin', 'Neck bands'],
      scope: _BodyScope.face,
    ),
    _ProcPreset(
      name: 'Polynucleotides',
      category: 'Injectables',
      emoji: '🧬',
      iconAsset: 'assets/polynucleotidesicon.png',
      tagline: 'Skin quality',
      recoveryDays: 3,
      productChips: ['Nucleofill', 'PhilArt', 'Plinest', 'Rejuran'],
      zones: ['Under-eyes', 'Cheeks', 'Neck', 'Full face'],
      scope: _BodyScope.face,
    ),
    _ProcPreset(
      name: 'Biostimulator',
      category: 'Injectables',
      emoji: '🌙',
      iconAsset: 'assets/biostimulatorsicon.png',
      tagline: 'Collagen boost',
      recoveryDays: 5,
      productChips: ['Sculptra (PLLA)', 'Radiesse (CaHA)', 'Ellansé', 'HarmonyCa'],
      zones: ['Cheeks', 'Jawline', 'Temples', 'Chin', 'Neck'],
      scope: _BodyScope.face,
    ),
  ],
  'Skin treatments': [
    _ProcPreset(
      name: 'Microneedling',
      category: 'Skin treatments',
      emoji: '📍',
      iconAsset: 'assets/microneedelingicon.png',
      tagline: 'CIT · 3–6 mo',
      recoveryDays: 3,
      productChips: ['SkinPen', 'Dermapen 4', 'Collagen PIN'],
      zones: ['Full face', 'Cheeks', 'Forehead', 'Under-eyes'],
      scope: _BodyScope.face,
    ),
    _ProcPreset(
      name: 'RF Microneedling',
      category: 'Skin treatments',
      emoji: '⚡',
      iconAsset: 'assets/microneedeling.png',
      tagline: 'Tightening · 6–9 mo',
      recoveryDays: 5,
      productChips: ['Morpheus8', 'Vivace', 'Genius RF', 'Scarlet SRF'],
      zones: ['Full face', 'Jowls', 'Under-eyes'],
      scope: _BodyScope.face,
    ),
  ],
  'Energy & devices (body)': [
    _ProcPreset(
      name: 'Morpheus8 (body)',
      category: 'Energy & devices',
      emoji: '⚡',
      iconAsset: 'assets/morpheus8.png',
      tagline: 'RF microneedling',
      recoveryDays: 5,
      productChips: ['Morpheus8', 'Genius RF', 'Scarlet SRF'],
      zones: ['Abdomen', 'Arms', 'Thighs', 'Knees', 'Buttocks'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'CO₂ Laser (body)',
      category: 'Energy & devices',
      emoji: '🔥',
      iconAsset: 'assets/co2laser.png',
      tagline: 'Resurfacing',
      recoveryDays: 14,
      productChips: ['UltraPulse', 'SmartXide DOT', 'Fraxel Re:pair'],
      zones: ['Neck', 'Chest', 'Hands', 'Scars'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'HIFU (body)',
      category: 'Energy & devices',
      emoji: '📡',
      iconAsset: 'assets/hifu.png',
      tagline: 'Tightening',
      recoveryDays: 1,
      productChips: ['Ultherapy', 'Ultraformer', 'Doublo Gold'],
      zones: ['Arms', 'Abdomen', 'Knees', 'Thighs'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'ONDA Coolwaves',
      category: 'Energy & devices',
      emoji: '〰️',
      iconAsset: 'assets/onda.png',
      tagline: 'Cellulite & fat',
      recoveryDays: 2,
      productChips: ['ONDA'],
      zones: ['Abdomen', 'Flanks', 'Thighs', 'Buttocks', 'Arms'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Laser hair removal',
      category: 'Hair removal',
      emoji: '✨',
      iconAsset: 'assets/hifu.png',
      tagline: 'Smooth skin',
      recoveryDays: 0,
      productChips: ['GentleMax Pro', 'Soprano Ice', 'LightSheer', 'Candela', 'IPL'],
      zones: ['Arms', 'Thighs', 'Chest', 'Abdomen', 'Back', 'Intimate', 'Hands', 'Neck'],
      scope: _BodyScope.body,
    ),
  ],
  'Massage & recovery (body)': [
    _ProcPreset(
      name: 'Lymphatic drainage massage',
      category: 'Massage & recovery',
      emoji: '💆',
      iconAsset: 'assets/lymphatic.png',
      tagline: 'Swelling reduction',
      recoveryDays: 0,
      productChips: const [],
      zones: ['Full body', 'Abdomen', 'Legs', 'Arms'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Post-op massage',
      category: 'Massage & recovery',
      emoji: '🫧',
      iconAsset: 'assets/post-op.png',
      tagline: 'Fibrosis care',
      recoveryDays: 0,
      productChips: const [],
      zones: ['Abdomen', 'Flanks', 'Thighs', 'Buttocks'],
      scope: _BodyScope.body,
    ),
  ],
  'Surgery': [
    _ProcPreset(
      name: 'Rhinoplasty',
      category: 'Surgery',
      emoji: '👃',
      tagline: 'Nose surgery',
      recoveryDays: 21,
      productChips: [],
      zones: ['Nose'],
      scope: _BodyScope.face,
      iconAsset: 'assets/noseicon.png',
    ),
    _ProcPreset(
      name: 'Blepharoplasty',
      category: 'Surgery',
      emoji: '👁️',
      tagline: 'Eyelid surgery',
      recoveryDays: 14,
      productChips: [],
      zones: ['Upper lids', 'Lower lids', 'Both'],
      scope: _BodyScope.face,
      iconAsset: 'assets/blapheroicon.png',
    ),
    _ProcPreset(
      name: 'Otoplasty',
      category: 'Surgery',
      emoji: '👂',
      tagline: 'Ear reshaping',
      recoveryDays: 14,
      productChips: [],
      zones: ['Ears'],
      scope: _BodyScope.face,
      iconAsset: 'assets/otaplasty.png',
    ),
    _ProcPreset(
      name: 'Breast augmentation',
      category: 'Surgery',
      emoji: '🎀',
      iconAsset: 'assets/breasticon.png',
      tagline: 'Implants',
      recoveryDays: 42,
      productChips: [],
      zones: ['Breasts'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'BBL (booty job)',
      category: 'Surgery',
      emoji: '🍑',
      iconAsset: 'assets/bbl.png',
      tagline: 'Fat transfer',
      recoveryDays: 60,
      productChips: [],
      zones: ['Buttocks'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Facelift',
      category: 'Surgery',
      emoji: '✨',
      tagline: 'Full lift',
      recoveryDays: 21,
      productChips: [],
      zones: ['Lower face', 'Neck', 'Midface'],
      scope: _BodyScope.face,
      iconAsset: 'assets/facelifticon.png',
    ),
    _ProcPreset(
      name: 'Mini facelift',
      category: 'Surgery',
      emoji: '✨',
      tagline: 'Short-scar lift',
      recoveryDays: 14,
      productChips: [],
      zones: ['Lower face', 'Jawline'],
      scope: _BodyScope.face,
      iconAsset: 'assets/facelifticon.png',
    ),
    _ProcPreset(
      name: 'Hair transplant',
      category: 'Surgery',
      emoji: '💇',
      iconAsset: 'assets/hairtransplant.png',
      tagline: 'Scalp grafts',
      recoveryDays: 180,
      productChips: [],
      zones: ['Scalp'],
      scope: _BodyScope.face,
    ),
    _ProcPreset(
      name: 'Abdominoplasty (tummy tuck)',
      category: 'Surgery',
      emoji: '🩹',
      iconAsset: 'assets/abdominoplasty.png',
      tagline: 'Abdomen',
      recoveryDays: 60,
      productChips: [],
      zones: ['Abdomen'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Liposuction',
      category: 'Surgery',
      emoji: '🌀',
      iconAsset: 'assets/liposuction.png',
      tagline: 'Body contour',
      recoveryDays: 30,
      productChips: [],
      zones: ['Abdomen', 'Flanks', 'Thighs', 'Arms', 'Chin'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Breast lift',
      category: 'Surgery',
      emoji: '🎀',
      iconAsset: 'assets/breasticon.png',
      tagline: 'Mastopexy',
      recoveryDays: 42,
      productChips: [],
      zones: ['Breasts'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Labiaplasty',
      category: 'Surgery',
      emoji: '◇',
      tagline: 'Intimate reshape',
      recoveryDays: 42,
      productChips: [],
      zones: ['Intimate'],
      scope: _BodyScope.body,
    ),
    _ProcPreset(
      name: 'Penile enlargement',
      category: 'Surgery',
      emoji: '◇',
      tagline: 'Length / girth',
      recoveryDays: 60,
      productChips: [],
      zones: ['Intimate'],
      scope: _BodyScope.body,
    ),
  ],
};

_ProcPreset? _procPresetMatchingTitle(String title) {
  final needle = title.trim().toLowerCase();
  if (needle.isEmpty) return null;
  for (final presets in _kPresets.values) {
    for (final preset in presets) {
      if (preset.name.toLowerCase() == needle) return preset;
    }
  }
  return null;
}

_FlowTab _flowTabForProcedure(Procedure e, _ProcPreset? preset) {
  if (preset != null) return preset.isSurgery ? _FlowTab.surgery : _FlowTab.aesthetic;
  final cat = (e.category ?? '').trim().toLowerCase();
  if (cat.contains('surgery')) return _FlowTab.surgery;
  return _FlowTab.aesthetic;
}

_BodyScope _bodyScopeForProcedure(Procedure e, _ProcPreset? preset) {
  if (preset != null) return preset.scope;
  const bodyHints = {
    'abdomen',
    'thigh',
    'arm',
    'breast',
    'butt',
    'buttocks',
    'flank',
    'body',
    'leg',
    'chest',
    'knee',
    'back',
    'waist',
    'hips',
    'arms',
    'hands',
    'intimate',
    'labia',
    'penile',
    'penis',
    'genital',
  };
  for (final zone in e.zones) {
    final lower = zone.toLowerCase();
    for (final hint in bodyHints) {
      if (lower.contains(hint)) return _BodyScope.body;
    }
  }
  return _BodyScope.face;
}

class _ProcedurePicker extends StatelessWidget {
  const _ProcedurePicker({
    required this.selected,
    required this.tab,
    required this.scope,
    required this.onPick,
    required this.onCustom,
    this.glassStyle = false,
    this.onLightSurface = false,
    this.warmStyle = false,
  });

  final String selected;
  final _FlowTab tab;
  final _BodyScope scope;
  final ValueChanged<_ProcPreset> onPick;
  final VoidCallback onCustom;
  final bool glassStyle;
  final bool onLightSurface;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    final sections = <MapEntry<String, List<_ProcPreset>>>[];
    for (final e in _kPresets.entries) {
      final filtered = e.value.where((p) {
        if (tab == _FlowTab.surgery && !p.isSurgery) return false;
        if (tab == _FlowTab.aesthetic && p.isSurgery) return false;
        if (p.scope != scope) return false;
        return true;
      }).toList();
      if (filtered.isNotEmpty) sections.add(MapEntry(e.key, filtered));
    }

    if (sections.isEmpty) {
      return Column(
        children: [
          Text(
            'No presets here yet.',
            style: GoogleFonts.urbanist(
              color: glassStyle && onLightSurface ? _kStep1Muted : (glassStyle ? _kStep1OnGlassMuted : _kMuted),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          warmStyle
              ? ProcedureCustomButton(onPressed: onCustom)
              : _CustomProcedureButton(glassStyle: glassStyle, onPressed: onCustom),
        ],
      );
    }

    Widget presetGrid(List<_ProcPreset> items) {
      final rows = <Widget>[];
      for (var i = 0; i < items.length; i += 2) {
        if (i > 0) rows.add(const SizedBox(height: 8));
        rows.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ProcCard(
                  preset: items[i],
                  selected: selected.trim().toLowerCase() == items[i].name.toLowerCase(),
                  glassStyle: glassStyle && !warmStyle,
                  warmStyle: warmStyle,
                  onTap: () => onPick(items[i]),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: i + 1 < items.length
                    ? _ProcCard(
                        preset: items[i + 1],
                        selected: selected.trim().toLowerCase() == items[i + 1].name.toLowerCase(),
                        glassStyle: glassStyle && !warmStyle,
                        warmStyle: warmStyle,
                        onTap: () => onPick(items[i + 1]),
                      )
                    : const SizedBox(),
              ),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rows,
      );
    }

    Widget glassGrid(List<_ProcPreset> items) => presetGrid(items);

    Widget section(String label, List<_ProcPreset> items, {required bool isFirst}) {
      final labelStyle = GoogleFonts.urbanist(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 2.2,
        height: 1.0,
        color: warmStyle
            ? ProcedureSelectionTheme.sectionLabel
            : (glassStyle && onLightSurface ? _kStep1Muted : (glassStyle ? _kStep1OnGlassMuted : _kMuted)),
      );

      if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isFirst) const SizedBox(height: 14),
          ProcedureSectionLabel(label),
          const SizedBox(height: 10),
          presetGrid(items),
        ],
      );
    }

      if (glassStyle) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isFirst) const SizedBox(height: 14),
            Text(label.toUpperCase(), style: labelStyle),
            const SizedBox(height: 10),
            glassGrid(items),
          ],
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 10),
            child: Text(label.toUpperCase(), style: labelStyle),
          ),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final p in items)
                _ProcCard(
                  preset: p,
                  selected: selected.trim().toLowerCase() == p.name.toLowerCase(),
                  onTap: () => onPick(p),
                ),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        for (var i = 0; i < sections.length; i++)
          section(sections[i].key, sections[i].value, isFirst: i == 0),
        const SizedBox(height: 12),
        warmStyle ? ProcedureCustomButton(onPressed: onCustom) : _CustomProcedureButton(glassStyle: glassStyle, onPressed: onCustom),
      ],
    );
  }
}

class _CustomProcedureButton extends StatelessWidget {
  const _CustomProcedureButton({required this.glassStyle, required this.onPressed});

  final bool glassStyle;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!glassStyle) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: const Text('Add custom procedure'),
      );
    }

    return InkWell(
      borderRadius: BorderRadius.circular(_kStep1CardRadius),
      onTap: onPressed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _kStep1Glass,
          borderRadius: BorderRadius.circular(_kStep1CardRadius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add, size: 18, color: _kStep1OnGlass),
              const SizedBox(width: 8),
              Text(
                'Add custom procedure',
                style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w700, color: _kStep1OnGlass),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProcCard extends StatelessWidget {
  const _ProcCard({
    required this.preset,
    required this.selected,
    required this.onTap,
    this.glassStyle = false,
    this.warmStyle = false,
  });
  final _ProcPreset preset;
  final bool selected;
  final VoidCallback onTap;
  final bool glassStyle;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return ProcedureCard(
        title: preset.name,
        subtitle: preset.tagline,
        emoji: preset.emoji,
        iconAsset: preset.iconAsset ?? presetIconByName[preset.name],
        selected: selected,
        onTap: onTap,
      );
    }

    if (glassStyle) {
      return SizedBox(
        width: double.infinity,
        child: AnimatedScale(
          scale: selected ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: InkWell(
            borderRadius: BorderRadius.circular(_kStep1CardRadius),
            onTap: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? _kStep1HeroGlass : _kStep1Glass,
                borderRadius: BorderRadius.circular(_kStep1CardRadius),
                border: Border.all(
                  color: selected ? Colors.white.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.12),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: selected ? 0.24 : 0.16),
                    blurRadius: selected ? 12 : 10,
                    offset: Offset(0, selected ? 5 : 4),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 84),
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 34, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            preset.name,
                            style: GoogleFonts.urbanist(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: _kStep1OnGlass,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            preset.tagline,
                            style: GoogleFonts.urbanist(
                              fontSize: 10,
                              fontWeight: FontWeight.w400,
                              color: _kStep1OnGlassMuted,
                              height: 1.3,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (selected)
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: const BoxDecoration(
                            color: _kStep1OnGlass,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.check, size: 12, color: _kStep1Navy),
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

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? _kInk : _kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _kInk : _kStroke),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(preset.emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(height: 6),
                Text(preset.name,
                    style: GoogleFonts.urbanist(fontSize: 13, fontWeight: FontWeight.w900, color: selected ? _kSurface : _kInk)),
                const SizedBox(height: 2),
                Text(preset.tagline,
                    style: GoogleFonts.urbanist(fontSize: 10, fontWeight: FontWeight.w700, color: selected ? const Color(0xCCFFFFFF) : _kMuted)),
              ],
            ),
            if (selected)
              Positioned(
                top: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: _kSurface2, borderRadius: BorderRadius.circular(999)),
                  child: Text('✓', style: GoogleFonts.urbanist(fontSize: 11, fontWeight: FontWeight.w900, color: _kInk)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductChips extends StatelessWidget {
  const _ProductChips({
    required this.chips,
    required this.value,
    required this.onPick,
    this.glassStyle = false,
    this.warmStyle = false,
  });
  final List<String> chips;
  final String value;
  final ValueChanged<String> onPick;
  final bool glassStyle;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in chips)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onPick(c),
              child: warmStyle
                  ? ProcedureGlassSurface(
                      borderRadius: BorderRadius.circular(10),
                      selected: value.toLowerCase() == c.toLowerCase(),
                      compact: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                        child: Text(
                          c,
                          style: ProcedureSelectionTypography.chip(
                            size: 10,
                            weight: FontWeight.w600,
                            color: value.toLowerCase() == c.toLowerCase()
                                ? Colors.white
                                : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                          ),
                        ),
                      ),
                    )
                  : Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                decoration: BoxDecoration(
                  color: value.toLowerCase() == c.toLowerCase()
                      ? (glassStyle ? _kStep1HeroGlass : _kInk)
                      : (glassStyle ? _kStep1Glass : _kSurface2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: glassStyle
                            ? Colors.white.withValues(alpha: value.toLowerCase() == c.toLowerCase() ? 0.35 : 0.12)
                            : _kStroke,
                  ),
                ),
                child: Text(
                  c,
                  style: GoogleFonts.urbanist(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: glassStyle
                              ? _kStep1OnGlass
                              : (value.toLowerCase() == c.toLowerCase() ? _kSurface : _kInk),
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VolumeMlStrip extends StatelessWidget {
  const _VolumeMlStrip({
    required this.value,
    required this.onChanged,
    this.label = 'Volume (ml)',
    this.min = 0.5,
    this.max = 5.0,
    this.step = 0.5,
    this.valueFormatter,
    this.glassStyle = false,
    this.warmStyle = false,
  });
  final double value;
  final ValueChanged<double> onChanged;
  final String label;
  final double min;
  final double max;
  final double step;
  final String Function(double v)? valueFormatter;
  final bool glassStyle;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    void setVal(double v) => onChanged(v.clamp(min, max));
    final fmt = valueFormatter ?? (double v) => v.toStringAsFixed(1);

    if (warmStyle) {
      return ProcedureStepperControl(
        label: label,
        value: fmt(value),
        valueText: fmt(value),
        onDecrement: () => setVal(value - step),
        onIncrement: () => setVal(value + step),
      );
    }

    final labelColor = glassStyle ? _kStep1OnGlassMuted : _kMuted;
    final valueColor = glassStyle ? _kStep1OnGlass : _kInk;
    final iconColor = glassStyle ? _kStep1OnGlass : _kInk;
    final dotColor = glassStyle ? _kStep1OnGlass : _kInk;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: glassStyle ? _kStep1HeroGlass : _kSurface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke),
      ),
      child: Row(
        children: [
          Text(label, style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w800, color: labelColor)),
          const Spacer(),
          IconButton(onPressed: () => setVal(value - step), icon: Icon(Icons.remove_circle_outline, color: iconColor)),
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dotColor, borderRadius: BorderRadius.circular(99))),
          const SizedBox(width: 10),
          Text(fmt(value), style: GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w900, color: valueColor)),
          IconButton(onPressed: () => setVal(value + step), icon: Icon(Icons.add_circle_outline, color: iconColor)),
        ],
      ),
    );
  }
}

class _BeforeAfterPhotos extends StatelessWidget {
  const _BeforeAfterPhotos({
    required this.beforePath,
    required this.afterPath,
    required this.onBeforeChanged,
    required this.onAfterChanged,
    this.glassStyle = false,
    this.step4Style = false,
    this.warmStyle = false,
    this.showTitle = true,
  });

  final String? beforePath;
  final String? afterPath;
  final ValueChanged<String?> onBeforeChanged;
  final ValueChanged<String?> onAfterChanged;
  final bool glassStyle;
  final bool step4Style;
  final bool warmStyle;
  final bool showTitle;

  Future<void> _pick(BuildContext context, {required String label, required String? current, required ValueChanged<String?> onChanged}) async {
    final isBefore = label.toLowerCase().contains('before');

    // Chooser only — never pick/crop while the sheet is open. On iOS the
    // picker/cropper often dismisses the modal (or rebuilds its builder and
    // wipes local vars), so upload succeeds but the tile never gets a path.
    final source = await showBlackPhotoSourceSheet(context, isBefore: isBefore);

    if (source == null || !context.mounted) return;

    try {
      late final String rawPath;
      if (source == ImageSource.camera) {
        // In-app 3:4 capture with optional ghost — no face ML, works for body too.
        final captured = await openProcedureBaCapture(
          context,
          label: isBefore ? 'Before' : 'After',
          referencePath: isBefore ? afterPath : beforePath,
        );
        if (captured == null || !context.mounted) return;
        rawPath = captured;
      } else {
        final img = await ImagePicker().pickImage(source: source, imageQuality: 88);
        if (img == null || !context.mounted) return;
        rawPath = img.path;
      }

      // Fine-tune pan/zoom so Before/After line up (ghost guide when available).
      final framed = await openPhotoFrameAdjust(
        context,
        sourcePath: rawPath,
        label: isBefore ? 'Before' : 'After',
        referencePath: isBefore ? afterPath : beforePath,
      );
      if (framed == null || !context.mounted) return;

      var local = await persistPhotoPath(framed);
      try {
        local = await resizePickForStudioMaxSide(local);
      } catch (e) {
        debugPrint('[ProcedureForm] pick resize skipped: $e');
      }
      if (!context.mounted) return;

      debugPrint('[ProcedureForm] photo ready → $local');
      onChanged(local);

      unawaited(
        persistAndUploadPhotoPath(local).then((stored) async {
          if (!isRemoteUrl(stored) || !context.mounted) return;
          try {
            await precacheImage(NetworkImage(stored), context);
          } catch (_) {}
          if (!context.mounted) return;
          onChanged(stored);
        }),
      );
    } on PlatformException catch (e) {
      debugPrint('[ProcedureForm] pick cancelled: ${e.code} ${e.message}');
    } catch (e, st) {
      debugPrint('[ProcedureForm] pick failed: $e\n$st');
    }
  }

  Future<void> _adjustExisting(
    BuildContext context, {
    required String label,
    required String path,
    required String? referencePath,
    required ValueChanged<String?> onChanged,
  }) async {
    final isBefore = label.toLowerCase().contains('before');
    try {
      final framed = await openPhotoFrameAdjust(
        context,
        sourcePath: path,
        label: isBefore ? 'Before' : 'After',
        referencePath: referencePath,
      );
      if (framed == null || !context.mounted) return;

      var local = await persistPhotoPath(framed);
      try {
        local = await resizePickForStudioMaxSide(local);
      } catch (_) {}
      if (!context.mounted) return;
      onChanged(local);
      unawaited(
        persistAndUploadPhotoPath(local).then((stored) async {
          if (!isRemoteUrl(stored) || !context.mounted) return;
          try {
            await precacheImage(NetworkImage(stored), context);
          } catch (_) {}
          if (!context.mounted) return;
          onChanged(stored);
        }),
      );
    } catch (e, st) {
      debugPrint('[ProcedureForm] adjust failed: $e\n$st');
    }
  }

  Widget _tile(
    BuildContext context, {
    required String label,
    required String? path,
    required VoidCallback onTap,
    required VoidCallback onClear,
    VoidCallback? onAdjust,
  }) {
    final p = (path ?? '').trim();
    final canShow = p.isNotEmpty && (isRemoteUrl(p) || File(p).existsSync());
    final tileBg = warmStyle
        ? Colors.white.withValues(alpha: 0.52)
        : (step4Style ? _kStep3FieldBg : (glassStyle ? _kStep1HeroGlass : _kSurface2));
    final tileBorder = warmStyle
        ? ProcedureSelectionTheme.cardBorder
        : (step4Style
            ? Colors.transparent
            : (glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke));
    final labelColor = warmStyle
        ? ProcedureSelectionTheme.ink
        : (step4Style || glassStyle ? Colors.white : _kInk);
    final mutedColor = warmStyle
        ? ProcedureSelectionTheme.muted
        : (step4Style
            ? Colors.white.withValues(alpha: 0.52)
            : (glassStyle ? _kStep1OnGlassMuted : _kMuted));
    final radius = warmStyle ? 12.0 : (step4Style ? _kStep3FieldRadius : 14.0);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tileBg,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: tileBorder),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: canShow
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(radius - 4),
                      child: isRemoteUrl(p)
                          ? Image.network(
                              p,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => ColoredBox(
                                color: tileBg,
                                child: Icon(Icons.broken_image_outlined, color: mutedColor),
                              ),
                            )
                          : Image.file(File(p), fit: BoxFit.cover),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: warmStyle
                            ? ProcedureSelectionTypography.label(size: 11, weight: FontWeight.w700, color: labelColor)
                            : GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w700, color: labelColor)),
                        const Spacer(),
                        Row(
                          children: [
                            Icon(Icons.add_photo_alternate_outlined, size: 18, color: mutedColor),
                            const SizedBox(width: 8),
                            Text('Add photo', style: warmStyle
                                ? ProcedureSelectionTypography.body(size: 11, weight: FontWeight.w600, color: mutedColor)
                                : GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w600, color: mutedColor)),
                          ],
                        ),
                      ],
                    ),
            ),
            if (canShow && onAdjust != null)
              Positioned(
                top: 0,
                left: 0,
                child: InkWell(
                  onTap: onAdjust,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _kInk.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _kSurface.withValues(alpha: 0.7)),
                    ),
                    child: const Icon(Icons.crop_free_rounded, size: 14, color: _kSurface),
                  ),
                ),
              ),
            if (canShow)
              Positioned(
                top: 0,
                right: 0,
                child: InkWell(
                  onTap: onClear,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _kInk.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: _kSurface.withValues(alpha: 0.7)),
                    ),
                    child: const Icon(Icons.close, size: 14, color: _kSurface),
                  ),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(
            'Before / After',
            style: GoogleFonts.urbanist(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: step4Style ? _kStep3Label : (glassStyle ? _kStep1OnGlassMuted : _kMuted),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: _tile(
                context,
                label: 'Before',
                path: beforePath,
                onTap: () => _pick(context, label: 'Before photo', current: beforePath, onChanged: onBeforeChanged),
                onClear: () => onBeforeChanged(null),
                onAdjust: (beforePath ?? '').trim().isEmpty
                    ? null
                    : () => _adjustExisting(
                          context,
                          label: 'Before',
                          path: beforePath!,
                          referencePath: afterPath,
                          onChanged: onBeforeChanged,
                        ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _tile(
                context,
                label: 'After',
                path: afterPath,
                onTap: () => _pick(context, label: 'After photo', current: afterPath, onChanged: onAfterChanged),
                onClear: () => onAfterChanged(null),
                onAdjust: (afterPath ?? '').trim().isEmpty
                    ? null
                    : () => _adjustExisting(
                          context,
                          label: 'After',
                          path: afterPath!,
                          referencePath: beforePath,
                          onChanged: onAfterChanged,
                        ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Normalized bounding box of the head inside [assets/headleft.png] (black margins excluded).
abstract final class _FaceHeadLayout {
  static const bounds = Rect.fromLTWH(0.11, 0.06, 0.78, 0.86);
  static const imageSize = Size(1024, 1536);

  static Offset toImageNorm(double hx, double hy) {
    return Offset(
      bounds.left + hx.clamp(0.0, 1.0) * bounds.width,
      bounds.top + hy.clamp(0.0, 1.0) * bounds.height,
    );
  }
}

/// Maps head dots to canvas pixels for [BoxFit.cover] (matches Flutter [Image] layout).
abstract final class _FaceImageCanvasLayout {
  static Rect coverRect({
    required double canvasW,
    required double canvasH,
    Alignment alignment = Alignment.center,
  }) {
    final imageW = _FaceHeadLayout.imageSize.width;
    final imageH = _FaceHeadLayout.imageSize.height;
    final scale = math.max(canvasW / imageW, canvasH / imageH);
    final displayW = imageW * scale;
    final displayH = imageH * scale;
    final slackX = displayW - canvasW;
    final slackY = displayH - canvasH;
    final alignX = (alignment.x + 1) / 2;
    final alignY = (alignment.y + 1) / 2;
    return Rect.fromLTWH(-slackX * alignX, -slackY * alignY, displayW, displayH);
  }

  static Offset headToCanvas({
    required double hx,
    required double hy,
    required double canvasW,
    required double canvasH,
    Alignment alignment = Alignment.center,
  }) {
    final norm = _FaceHeadLayout.toImageNorm(hx, hy);
    final rect = coverRect(canvasW: canvasW, canvasH: canvasH, alignment: alignment);
    return Offset(
      rect.left + norm.dx * rect.width,
      rect.top + norm.dy * rect.height,
    );
  }
}

class _FaceDotPos {
  const _FaceDotPos(this.zone, this.hx, this.hy, {this.size = 22});
  final String zone;
  /// 0–1 within the head silhouette (not the full PNG).
  final double hx;
  final double hy;
  final double size;

  Offset get imageNorm => _FaceHeadLayout.toImageNorm(hx, hy);

  // Step-2 face map tap targets: slightly larger for easier selection.
  double get warmSize => size <= 16 ? 18 : 20;
}

/// Dots in head-relative space (hx/hy 0–1 on the face silhouette).
const _kFaceMapDots = <_FaceDotPos>[
  _FaceDotPos('Forehead', 0.66, 0.20),
  _FaceDotPos('Scalp', 0.48, 0.13),
  _FaceDotPos('Temples', 0.35, 0.27),
  _FaceDotPos('Ears', 0.22, 0.40),
  _FaceDotPos('Upper eyes', 0.56, 0.34),
  _FaceDotPos('Under-eyes', 0.56, 0.42),
  _FaceDotPos('Cheeks', 0.40, 0.44),
  _FaceDotPos('Nose', 0.73, 0.43),
  _FaceDotPos('Lips', 0.75, 0.55),
  _FaceDotPos('Marionette lines', 0.68, 0.52, size: 16),
  _FaceDotPos('Jawline', 0.45, 0.60),
  _FaceDotPos('Chin', 0.70, 0.65),
  _FaceDotPos('Neck', 0.58, 0.80, size: 18),
];

/// Face zones shown on the map and in the toggle list below the legend.
const _kFaceMapZoneNames = <String>[
  'Forehead',
  'Scalp',
  'Temples',
  'Ears',
  'Upper eyes',
  'Under-eyes',
  'Cheeks',
  'Nose',
  'Lips',
  'Marionette lines',
  'Jawline',
  'Chin',
  'Neck',
];

/// Reference-matched treatment zone card for wizard step 2.
class _WarmTreatmentZoneCard extends StatelessWidget {
  const _WarmTreatmentZoneCard({
    required this.selected,
    required this.onToggle,
    required this.entireFaceSelected,
    required this.onEntireFaceTap,
    required this.onAddCustomZone,
  });

  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final bool entireFaceSelected;
  final VoidCallback onEntireFaceTap;
  final VoidCallback onAddCustomZone;

  @override
  Widget build(BuildContext context) {
    final titleStyle = ProcedureSelectionTypography.display(size: 13);
    final subtitleStyle = ProcedureSelectionTypography.body(size: 10);

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      illuminated: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardW = constraints.maxWidth;
            // Make the treatment-zone section taller so the face map is easier to tap.
            final mapH = cardW * 0.92;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Treatment zone', style: titleStyle),
                          const SizedBox(height: 6),
                          Text('Tap the areas you want to treat', style: subtitleStyle),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _EntireFaceOption(
                      selected: entireFaceSelected,
                      onTap: onEntireFaceTap,
                      warmStyle: true,
                      overlay: true,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: mapH,
                  width: cardW,
                  child: Center(
                    child: SizedBox(
                      width: cardW * 0.82,
                      height: mapH,
                      child: _WarmFaceMapLayer(
                        selected: selected,
                        onToggle: onToggle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const ProcedureFaceMapLegend(),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final zone in _kFaceMapZoneNames)
                      _WarmFaceZoneChip(
                        label: zone,
                        selected: _faceDotSelected(zone, selected),
                        onTap: () => onToggle(zone),
                      ),
                    _WarmFaceZoneAddChip(onTap: onAddCustomZone),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Image-normalized body map dots (0–1 across [assets/bodyfirststep.png]).
class _BodyDotPos {
  const _BodyDotPos(this.zone, this.ix, this.iy, {this.size = 20});
  final String zone;
  final double ix;
  final double iy;
  final double size;

  double get warmSize => size <= 16 ? 17 : 19;
}

/// Maps body image coords to canvas pixels for [BoxFit.contain].
abstract final class _BodyImageCanvasLayout {
  static const imageSize = Size(696, 1010);

  static Rect containRect({
    required double canvasW,
    required double canvasH,
  }) {
    final imageW = imageSize.width;
    final imageH = imageSize.height;
    final scale = math.min(canvasW / imageW, canvasH / imageH);
    final displayW = imageW * scale;
    final displayH = imageH * scale;
    return Rect.fromLTWH(
      (canvasW - displayW) / 2,
      (canvasH - displayH) / 2,
      displayW,
      displayH,
    );
  }

  static Offset imageToCanvas({
    required double ix,
    required double iy,
    required double canvasW,
    required double canvasH,
  }) {
    final rect = containRect(canvasW: canvasW, canvasH: canvasH);
    return Offset(
      rect.left + ix.clamp(0.0, 1.0) * rect.width,
      rect.top + iy.clamp(0.0, 1.0) * rect.height,
    );
  }
}

/// Interactive dots placed on the front body silhouette.
/// Bilateral zones (breasts, arms, …) use a left + right pair that share one zone name.
const _kBodyMapDots = <_BodyDotPos>[
  _BodyDotPos('Neck', 0.50, 0.09, size: 17),
  _BodyDotPos('Chest', 0.50, 0.21),
  _BodyDotPos('Breasts', 0.40, 0.27),
  _BodyDotPos('Breasts', 0.60, 0.27),
  _BodyDotPos('Arms', 0.22, 0.33),
  _BodyDotPos('Arms', 0.78, 0.33),
  _BodyDotPos('Hands', 0.17, 0.58, size: 17),
  _BodyDotPos('Hands', 0.83, 0.58, size: 17),
  _BodyDotPos('Abdomen', 0.50, 0.43),
  _BodyDotPos('Flanks', 0.31, 0.40),
  _BodyDotPos('Flanks', 0.69, 0.40),
  _BodyDotPos('Waist', 0.50, 0.49, size: 17),
  _BodyDotPos('Hips', 0.34, 0.56),
  _BodyDotPos('Hips', 0.66, 0.56),
  _BodyDotPos('Buttocks', 0.30, 0.61, size: 17),
  _BodyDotPos('Buttocks', 0.70, 0.61, size: 17),
  _BodyDotPos('Intimate', 0.50, 0.64),
  _BodyDotPos('Thighs', 0.40, 0.74),
  _BodyDotPos('Thighs', 0.60, 0.74),
  _BodyDotPos('Knees', 0.42, 0.93, size: 17),
  _BodyDotPos('Knees', 0.58, 0.93, size: 17),
];

const _kBodyMapZoneNames = <String>[
  'Neck',
  'Chest',
  'Breasts',
  'Arms',
  'Hands',
  'Abdomen',
  'Flanks',
  'Waist',
  'Hips',
  'Buttocks',
  'Intimate',
  'Thighs',
  'Knees',
];

/// Body treatment zone card — body map + dots, matching face warm UI.
class _WarmBodyTreatmentZoneCard extends StatelessWidget {
  const _WarmBodyTreatmentZoneCard({
    required this.zones,
    required this.selected,
    required this.onToggle,
    required this.onAddCustomZone,
  });

  final List<String> zones;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onAddCustomZone;

  @override
  Widget build(BuildContext context) {
    final titleStyle = ProcedureSelectionTypography.display(size: 13);
    final subtitleStyle = ProcedureSelectionTypography.body(size: 10);
    final mapZoneSet = _kBodyMapZoneNames.toSet();
    final chipZones = <String>[
      ..._kBodyMapZoneNames,
      for (final z in zones)
        if (!mapZoneSet.contains(z)) z,
    ];

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      illuminated: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cardW = constraints.maxWidth;
            // Taller than the face map so the full torso stays readable.
            final mapH = cardW * 1.18;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Treatment zone', style: titleStyle),
                const SizedBox(height: 6),
                Text('Tap the areas you want to treat', style: subtitleStyle),
                const SizedBox(height: 12),
                SizedBox(
                  height: mapH,
                  width: cardW,
                  child: Center(
                    child: SizedBox(
                      width: cardW * 0.88,
                      height: mapH,
                      child: _WarmBodyMapLayer(
                        selected: selected,
                        onToggle: onToggle,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const ProcedureFaceMapLegend(),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final zone in chipZones)
                      _WarmFaceZoneChip(
                        label: zone,
                        selected: selected.contains(zone),
                        onTap: () => onToggle(zone),
                      ),
                    _WarmFaceZoneAddChip(onTap: onAddCustomZone),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WarmBodyMapLayer extends StatelessWidget {
  const _WarmBodyMapLayer({
    required this.selected,
    required this.onToggle,
  });

  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Opacity(
                opacity: 0.96,
                child: Image.asset(
                  _kStep1BodyHeroAsset,
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  filterQuality: FilterQuality.high,
                ),
              ),
              for (final spec in _kBodyMapDots)
                Builder(
                  builder: (context) {
                    final pt = _BodyImageCanvasLayout.imageToCanvas(
                      ix: spec.ix,
                      iy: spec.iy,
                      canvasW: width,
                      canvasH: height,
                    );
                    return Positioned(
                      left: pt.dx - spec.warmSize / 2,
                      top: pt.dy - spec.warmSize / 2,
                      child: _FaceZoneDot(
                        selected: selected.contains(spec.zone),
                        size: spec.warmSize,
                        warmStyle: true,
                        onTap: () => onToggle(spec.zone),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _WarmFaceZoneChip extends StatelessWidget {
  const _WarmFaceZoneChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          selected: selected,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 14, color: Colors.white.withValues(alpha: 0.92)),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
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

class _WarmFaceZoneAddChip extends StatelessWidget {
  const _WarmFaceZoneAddChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 14, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88)),
                const SizedBox(width: 4),
                Text(
                  'Custom zone',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
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

class _WarmFaceMapLayer extends StatelessWidget {
  const _WarmFaceMapLayer({
    required this.selected,
    required this.onToggle,
  });

  final Set<String> selected;
  final ValueChanged<String> onToggle;

  static const _imageAlignment = Alignment.center;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;

        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              const ProcedureFaceAmbientGlow(),
              Opacity(
                opacity: 0.94,
                child: Image.asset(
                  'assets/headleft.png',
                  fit: BoxFit.cover,
                  alignment: _imageAlignment,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const Positioned.fill(
                child: ProcedureFaceUnderNeonGlow(),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xFFF5F5F5).withValues(alpha: 0.10),
                          const Color(0xFFEFEFEF).withValues(alpha: 0.04),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.32, 0.62],
                      ),
                    ),
                  ),
                ),
              ),
              CustomPaint(
                painter: _FaceContourPainter(
                  canvasW: width,
                  canvasH: height,
                  dots: _kFaceMapDots,
                  warmStyle: true,
                  imageAlignment: _imageAlignment,
                ),
                size: Size(width, height),
              ),
              for (final spec in _kFaceMapDots)
                Builder(
                  builder: (context) {
                    final pt = _FaceImageCanvasLayout.headToCanvas(
                      hx: spec.hx,
                      hy: spec.hy,
                      canvasW: width,
                      canvasH: height,
                      alignment: _imageAlignment,
                    );
                    return Positioned(
                      left: pt.dx - spec.warmSize / 2,
                      top: pt.dy - spec.warmSize / 2,
                      child: _FaceZoneDot(
                        selected: _faceDotSelected(spec.zone, selected),
                        size: spec.warmSize,
                        warmStyle: true,
                        onTap: () => onToggle(spec.zone),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Dashed zone outlines derived from live dot positions on the head map.
class _FaceContourPainter extends CustomPainter {
  _FaceContourPainter({
    required this.canvasW,
    required this.canvasH,
    required this.dots,
    this.warmStyle = false,
    this.imageAlignment = Alignment.center,
  });

  final double canvasW;
  final double canvasH;
  final List<_FaceDotPos> dots;
  final bool warmStyle;
  final Alignment imageAlignment;

  Offset? _canvasPt(String zone, [int index = 0]) {
    final matches = dots.where((d) => d.zone == zone).toList();
    if (matches.isEmpty || index >= matches.length) return null;
    final spec = matches[index];
    return _FaceImageCanvasLayout.headToCanvas(
      hx: spec.hx,
      hy: spec.hy,
      canvasW: canvasW,
      canvasH: canvasH,
      alignment: imageAlignment,
    );
  }

  Offset _canvasControl(double hx, double hy) {
    return _FaceImageCanvasLayout.headToCanvas(
      hx: hx,
      hy: hy,
      canvasW: canvasW,
      canvasH: canvasH,
      alignment: imageAlignment,
    );
  }

  /// Smooth segment pulled slightly outward along the face profile (left on 3/4 view).
  void _curveTo(Path path, Offset from, Offset to, {double bulgeX = -14}) {
    final mid = Offset((from.dx + to.dx) * 0.5, (from.dy + to.dy) * 0.5);
    path.quadraticBezierTo(mid.dx + bulgeX, mid.dy, to.dx, to.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = warmStyle
          ? Colors.white.withValues(alpha: 0.88)
          : ProcedureSelectionTheme.ink.withValues(alpha: 0.5)
      ..strokeWidth = warmStyle ? 1.1 : 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final temple = _canvasPt('Temples');
    final forehead = _canvasPt('Forehead');
    final upperEye = _canvasPt('Upper eyes');
    final underEye = _canvasPt('Under-eyes');
    final cheek = _canvasPt('Cheeks', 0);
    final nose = _canvasPt('Nose');
    final lips = _canvasPt('Lips');
    final jawline = _canvasPt('Jawline');
    final chin = _canvasPt('Chin');

    if (temple == null || forehead == null || upperEye == null) return;

    // Forehead band — open arc along the brow (no loop behind the head).
    final foreheadBand = Path()
      ..moveTo(temple.dx, temple.dy)
      ..quadraticBezierTo(
        _canvasControl(0.58, 0.12).dx,
        _canvasControl(0.58, 0.12).dy,
        forehead.dx,
        forehead.dy,
      )
      ..quadraticBezierTo(
        _canvasControl(0.62, 0.28).dx,
        _canvasControl(0.62, 0.28).dy,
        upperEye.dx,
        upperEye.dy,
      );
    _drawDashedPath(canvas, foreheadBand, paint);

    // Profile: temple → cheek → jawline → chin → lips (through real dot positions).
    if (cheek != null && jawline != null && chin != null && lips != null) {
      final profileBand = Path()
        ..moveTo(temple.dx, temple.dy);
      _curveTo(profileBand, temple, cheek);
      _curveTo(profileBand, cheek, jawline);
      _curveTo(profileBand, jawline, chin, bulgeX: -10);
      _curveTo(profileBand, chin, lips, bulgeX: 8);
      _drawDashedPath(canvas, profileBand, paint);
    }

    // Mid-face: under-eye → nose → lips (open arc only).
    if (underEye != null && nose != null && lips != null) {
      final midFace = Path()
        ..moveTo(underEye.dx, underEye.dy)
        ..quadraticBezierTo(
          _canvasControl(0.64, 0.42).dx,
          _canvasControl(0.64, 0.42).dy,
          nose.dx,
          nose.dy,
        )
        ..quadraticBezierTo(
          _canvasControl(0.76, 0.49).dx,
          _canvasControl(0.76, 0.49).dy,
          lips.dx,
          lips.dy,
        );
      _drawDashedPath(canvas, midFace, paint);
    }
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FaceContourPainter oldDelegate) {
    return oldDelegate.canvasW != canvasW ||
        oldDelegate.canvasH != canvasH ||
        oldDelegate.warmStyle != warmStyle ||
        oldDelegate.imageAlignment != imageAlignment ||
        oldDelegate.dots != dots;
  }
}

class _FacePointsMap extends StatelessWidget {
  const _FacePointsMap({
    required this.selected,
    required this.onToggle,
    required this.entireFaceSelected,
    required this.onEntireFaceTap,
  });
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final bool entireFaceSelected;
  final VoidCallback onEntireFaceTap;

  static const _kMapBg = Color(0xFFE8E8E8);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mapW = constraints.maxWidth;
        final mapH = mapW * (1536 / 1024);

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _kMapBg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              width: mapW,
              height: mapH,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/headleft.png',
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                  ),
                  CustomPaint(
                    painter: _FaceContourPainter(
                      canvasW: mapW,
                      canvasH: mapH,
                      dots: _kFaceMapDots,
                    ),
                    size: Size(mapW, mapH),
                  ),
                  for (final spec in _kFaceMapDots)
                    Builder(
                      builder: (context) {
                        final pt = _FaceImageCanvasLayout.headToCanvas(
                          hx: spec.hx,
                          hy: spec.hy,
                          canvasW: mapW,
                          canvasH: mapH,
                        );
                        return Positioned(
                          left: pt.dx - spec.size / 2,
                          top: pt.dy - spec.size / 2,
                          child: _FaceZoneDot(
                            selected: _faceDotSelected(spec.zone, selected),
                            size: spec.size,
                            onTap: () => onToggle(spec.zone),
                          ),
                        );
                      },
                    ),
                  Positioned(
                    left: 12,
                    top: 10,
                    child: _EntireFaceOption(
                      selected: entireFaceSelected,
                      onTap: onEntireFaceTap,
                      overlay: true,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: _FaceMapLegend(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FaceZoneDot extends StatefulWidget {
  const _FaceZoneDot({
    required this.selected,
    required this.size,
    required this.onTap,
    this.warmStyle = false,
  });
  final bool selected;
  final double size;
  final VoidCallback onTap;
  final bool warmStyle;

  @override
  State<_FaceZoneDot> createState() => _FaceZoneDotState();
}

class _FaceZoneDotState extends State<_FaceZoneDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    if (widget.selected && widget.warmStyle) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _FaceZoneDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && widget.warmStyle) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.warmStyle) {
      return _buildLegacyDot();
    }

    final glow = widget.selected ? 0.35 + (_pulse.value * 0.25) : 0.0;
    final scale = widget.selected ? 1.0 + (_pulse.value * 0.08) : 1.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: scale,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.selected
                  ? Colors.black.withValues(alpha: 0.62)
                  : Colors.black.withValues(alpha: 0.28),
              border: Border.all(
                color: Colors.white.withValues(alpha: widget.selected ? 0.95 : 0.88),
                width: 1.6,
              ),
              boxShadow: [
                BoxShadow(
                  color: ProcedureSelectionTheme.ambientShadow,
                  blurRadius: widget.selected ? 10 : 6,
                  offset: const Offset(0, 2),
                ),
                if (widget.selected)
                  BoxShadow(
                    color: Colors.white.withValues(alpha: glow),
                    blurRadius: 12,
                    spreadRadius: 1.5,
                  ),
              ],
            ),
            alignment: Alignment.center,
            child: widget.selected
                ? Icon(Icons.check, size: widget.size * 0.55, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildLegacyDot() {
    final unselectedFill = Colors.white.withValues(alpha: 0.38);
    final borderColor = Colors.white.withValues(alpha: widget.selected ? 0.9 : 0.75);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onTap,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.selected ? ProcedureSelectionTheme.ink : unselectedFill,
            border: Border.all(color: borderColor, width: 1.5),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.45),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: widget.selected ? Icon(Icons.check, size: 13, color: Colors.white) : null,
        ),
      ),
    );
  }
}

class _FaceMapLegend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Widget item({required Widget icon, required String label}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.urbanist(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          item(
            icon: Container(
              width: 15,
              height: 15,
              decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: const Icon(Icons.check, size: 10, color: Colors.white),
            ),
            label: 'Selected',
          ),
          const SizedBox(width: 22),
          item(
            icon: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.8)),
              ),
            ),
            label: 'Tap to select',
          ),
        ],
      ),
    );
  }
}

class _EntireFaceOption extends StatelessWidget {
  const _EntireFaceOption({
    required this.selected,
    required this.onTap,
    this.overlay = false,
    this.warmStyle = false,
  });
  final bool selected;
  final VoidCallback onTap;
  final bool overlay;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    final warmTile = warmStyle && !overlay;

    Widget circleIndicator() {
      if (warmStyle) {
        return Container(
          width: warmTile ? 16 : 18,
          height: warmTile ? 16 : 18,
          decoration: BoxDecoration(
            color: selected
                ? (warmTile ? Colors.white : ProcedureSelectionTheme.ink)
                : Colors.white.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Colors.white.withValues(alpha: 0.9)
                  : ProcedureSelectionTheme.ink.withValues(alpha: 0.22),
              width: 1.2,
            ),
          ),
          alignment: Alignment.center,
          child: selected
              ? Icon(Icons.check, size: 11, color: warmTile ? Colors.black : Colors.white)
              : null,
        );
      }

      return Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.24),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: selected ? 0.9 : 0.75),
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? const Icon(Icons.check, size: 11, color: Colors.black)
            : null,
      );
    }

    final content = Row(
      mainAxisAlignment: warmTile ? MainAxisAlignment.start : (overlay ? MainAxisAlignment.center : MainAxisAlignment.start),
      mainAxisSize: warmTile ? MainAxisSize.max : (overlay ? MainAxisSize.min : MainAxisSize.max),
      children: [
        circleIndicator(),
        SizedBox(width: warmTile ? 8 : 8),
        Text(
          'Entire face',
          style: (warmTile || warmStyle)
              ? ProcedureSelectionTypography.chip(
                  size: warmTile ? 9 : (overlay ? 11 : 13),
                  color: warmTile
                      ? (selected ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88))
                      : (overlay
                          ? (selected ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88))
                          : _kStep1OnGlass),
                )
              : GoogleFonts.urbanist(
                  fontSize: overlay ? 11 : 13,
                  fontWeight: FontWeight.w700,
                  color: overlay ? Colors.white.withValues(alpha: 0.9) : _kStep1OnGlass,
                ),
        ),
      ],
    );

    if (warmTile) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(10),
            selected: selected,
            compact: true,
            child: SizedBox(
              height: 42,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: content,
              ),
            ),
          ),
        ),
      );
    }

    if (overlay) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(10),
            selected: selected,
            compact: true,
            child: SizedBox(
              height: 50,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: content,
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? _kStep1HeroGlass : _kStep1Glass,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: selected ? 0.28 : 0.12),
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

class _SelectedZoneChips extends StatelessWidget {
  const _SelectedZoneChips({
    required this.zones,
    required this.onRemove,
    this.warmStyle = false,
    this.glassStyle = false,
    this.centered = false,
  });
  final List<String> zones;
  final ValueChanged<String> onRemove;
  final bool warmStyle;
  final bool glassStyle;
  final bool centered;

  BoxDecoration _chipDecoration() {
    if (glassStyle) {
      return BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      );
    }
    return BoxDecoration(
      color: warmStyle ? ProcedureSelectionTheme.cardSelected : _kStep1HeroGlass,
      borderRadius: BorderRadius.circular(999),
      border: warmStyle ? null : Border.all(color: Colors.white.withValues(alpha: 0.12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: (warmStyle && centered) ? WrapAlignment.center : WrapAlignment.start,
      children: [
        for (final zone in zones)
          Container(
            padding: EdgeInsets.only(
              left: glassStyle ? 12 : 14,
              right: glassStyle ? 6 : (warmStyle ? 6 : 4),
              top: glassStyle ? 7 : (warmStyle ? 8 : 6),
              bottom: glassStyle ? 7 : (warmStyle ? 8 : 6),
            ),
            decoration: _chipDecoration(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  zone,
                  style: glassStyle
                      ? ProcedureSelectionTypography.chip(size: 11, color: Colors.white.withValues(alpha: 0.95))
                      : (warmStyle
                          ? ProcedureSelectionTypography.chip(size: 12, color: Colors.white)
                          : GoogleFonts.urbanist(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: _kStep1OnGlass,
                            )),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onRemove(zone),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close,
                      size: 13,
                      color: glassStyle
                          ? Colors.white.withValues(alpha: 0.82)
                          : (warmStyle ? Colors.white.withValues(alpha: 0.9) : _kStep1OnGlassMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (warmStyle && centered) {
      return Center(child: chips);
    }
    return chips;
  }
}

class _ZoneMultiPicker extends StatelessWidget {
  const _ZoneMultiPicker({
    required this.zones,
    required this.selected,
    required this.onToggle,
    required this.onAddCustom,
    this.glassStyle = false,
  });
  final List<String> zones;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final Future<void> Function() onAddCustom;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final z in zones)
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => onToggle(z),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected.contains(z)
                    ? (glassStyle ? _kStep1HeroGlass : _kInk)
                    : (glassStyle ? _kStep1Glass : _kSurface2),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: glassStyle
                      ? Colors.white.withValues(alpha: selected.contains(z) ? 0.35 : 0.12)
                      : _kStroke,
                ),
              ),
              child: Text(
                z,
                style: GoogleFonts.urbanist(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: glassStyle ? _kStep1OnGlass : (selected.contains(z) ? _kSurface : _kInk),
                ),
              ),
            ),
          ),
        InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onAddCustom,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: glassStyle ? _kStep1Glass : _kSurface2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: glassStyle ? Colors.white.withValues(alpha: 0.22) : _kInk),
            ),
            child: Text(
              '+ custom',
              style: GoogleFonts.urbanist(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: glassStyle ? _kStep1OnGlass : _kInk,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WarmDurationUnitChips extends StatelessWidget {
  const _WarmDurationUnitChips({
    required this.unit,
    required this.value,
    required this.onChanged,
  });

  final String? unit;
  final int value;
  final void Function(int value, String? unit) onChanged;

  @override
  Widget build(BuildContext context) {
    Widget unitChip(String u, String label) {
      final sel = unit == u;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onChanged(value, sel ? null : u),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(10),
              selected: sel,
              compact: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sel) ...[
                        Icon(Icons.check_rounded, size: 14, color: Colors.white.withValues(alpha: 0.92)),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        label,
                        style: ProcedureSelectionTypography.chip(
                          size: 10,
                          weight: FontWeight.w600,
                          color: sel ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        unitChip('days', 'Days'),
        const SizedBox(width: 6),
        unitChip('weeks', 'Weeks'),
        const SizedBox(width: 6),
        unitChip('months', 'Months'),
        const SizedBox(width: 6),
        unitChip('years', 'Years'),
      ],
    );
  }
}

class _RecoveryDurationPicker extends StatelessWidget {
  const _RecoveryDurationPicker({
    required this.value,
    required this.unit,
    required this.onChanged,
    this.glassStyle = false,
    this.step4Style = false,
    this.warmStyle = false,
  });
  final int value;
  final String? unit;
  final void Function(int value, String? unit) onChanged;
  final bool glassStyle;
  final bool step4Style;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _WarmDurationUnitChips(unit: unit, value: value, onChanged: onChanged),
          const SizedBox(height: 10),
          ProcedureStepperControl(
            label: 'Duration',
            value: '$value',
            onWarmBackground: true,
            onDecrement: () {
              if (unit == null || value <= 1) return;
              onChanged(value - 1, unit);
            },
            onIncrement: () {
              if (unit == null) return;
              onChanged(value + 1, unit);
            },
          ),
        ],
      );
    }

    if (step4Style) {
      return _buildStep4(context);
    }

    final chipSelectedBg = glassStyle ? _kStep1HeroGlass : _kInk;
    final chipUnselectedBg = glassStyle ? _kStep1Glass : _kSurface2;
    final chipSelectedText = glassStyle ? _kStep1OnGlass : _kSurface;
    final chipUnselectedText = glassStyle ? _kStep1OnGlassMuted : _kMuted;
    final chipBorder = glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke;
    final chipSelectedBorder = glassStyle ? Colors.white.withValues(alpha: 0.35) : _kStroke;
    final stepperBg = glassStyle ? (unit == null ? _kStep1Glass : _kStep1HeroGlass) : (unit == null ? _kSurface2 : _kSurface);
    final stepperBorder = glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke;
    final stepperText = glassStyle ? _kStep1OnGlass : _kInk;
    final stepperIcon = glassStyle ? _kStep1OnGlassMuted : null;

    Widget unitChip(String u, String label) {
      final sel = unit == u;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onChanged(value, sel ? null : u),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? chipSelectedBg : chipUnselectedBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? chipSelectedBorder : chipBorder),
            ),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.urbanist(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: sel ? chipSelectedText : chipUnselectedText,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            unitChip('days', 'Days'),
            const SizedBox(width: 6),
            unitChip('weeks', 'Weeks'),
            const SizedBox(width: 6),
            unitChip('months', 'Months'),
            const SizedBox(width: 6),
            unitChip('years', 'Years'),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: stepperBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: stepperBorder),
          ),
          child: Row(
            children: [
              Text('Duration', style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w900, color: stepperText)),
              const Spacer(),
              IconButton(
                onPressed: unit == null || value <= 1 ? null : () => onChanged(value - 1, unit),
                icon: Icon(Icons.remove_circle_outline, color: stepperIcon),
              ),
              Text(
                '$value',
                style: glassStyle
                    ? GoogleFonts.urbanist(fontSize: 18, fontWeight: FontWeight.w800, color: stepperText)
                    : GoogleFonts.dmSerifDisplay(fontSize: 18, color: stepperText),
              ),
              IconButton(
                onPressed: unit == null ? null : () => onChanged(value + 1, unit),
                icon: Icon(Icons.add_circle_outline, color: stepperIcon),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStep4(BuildContext context) {
    Widget unitChip(String u, String label) {
      final sel = unit == u;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(value, sel ? null : u),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: sel ? Colors.black : Colors.white.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: sel ? Colors.black : Colors.white.withValues(alpha: 0.72),
                ),
              ),
              child: Center(
                child: Text(
                  label,
                  style: GoogleFonts.urbanist(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: sel ? Colors.white : _kStep1Navy,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            unitChip('days', 'Days'),
            const SizedBox(width: 8),
            unitChip('weeks', 'Weeks'),
            const SizedBox(width: 8),
            unitChip('months', 'Months'),
            const SizedBox(width: 8),
            unitChip('years', 'Years'),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(_kStep3FieldRadius),
          // No BackdropFilter — Impeller Gaussian blur crashes iOS Simulator.
          child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(_kStep3FieldRadius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Text(
                    'Duration',
                    style: GoogleFonts.urbanist(fontSize: 14, fontWeight: FontWeight.w600, color: _kStep1Navy),
                  ),
                  const Spacer(),
                  _Step3StepperButton(
                    icon: Icons.remove_rounded,
                    enabled: unit != null && value > 1,
                    onTap: () => onChanged(value - 1, unit),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '$value',
                      style: GoogleFonts.urbanist(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: _kStep1Navy,
                      ),
                    ),
                  ),
                  _Step3StepperButton(
                    icon: Icons.add_rounded,
                    enabled: unit != null,
                    onTap: () => onChanged(value + 1, unit),
                  ),
                ],
              ),
            ),
        ),
      ],
    );
  }
}

class _RedoAfterPicker extends StatelessWidget {
  const _RedoAfterPicker({
    required this.value,
    required this.unit,
    required this.onChanged,
    this.glassStyle = false,
    this.step3Style = false,
    this.warmStyle = false,
    this.showUnitHint = false,
    this.onUnitRequired,
    this.promo,
  });
  final int value;
  final String? unit;
  final void Function(int value, String? unit) onChanged;
  final bool glassStyle;
  final bool step3Style;
  final bool warmStyle;
  final bool showUnitHint;
  final VoidCallback? onUnitRequired;
  final Widget? promo;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Step3FieldLabel('Redo appointment (optional)', warmStyle: true),
          const SizedBox(height: 14),
          if (promo != null) ...[
            promo!,
            const SizedBox(height: 14),
          ],
          _WarmDurationUnitChips(unit: unit, value: value, onChanged: onChanged),
          if (showUnitHint) ...[
            const SizedBox(height: 8),
            Text(
              'Choose Days / Weeks / Months / Years first',
              style: ProcedureSelectionTypography.body(size: 11, color: ProcedureSelectionTheme.muted),
            ),
          ],
          const SizedBox(height: 16),
          ProcedureStepperControl(
            label: 'In',
            value: '$value',
            onWarmBackground: true,
            onDecrement: () {
              if (unit == null) {
                onUnitRequired?.call();
                return;
              }
              if (value <= 1) return;
              onChanged(value - 1, unit);
            },
            onIncrement: () {
              if (unit == null) {
                onUnitRequired?.call();
                return;
              }
              onChanged(value + 1, unit);
            },
          ),
        ],
      );
    }

    if (step3Style) {
      return _buildStep3(context);
    }

    final labelColor = glassStyle ? _kStep1OnGlassMuted : _kMuted;
    final chipSelectedBg = glassStyle ? _kStep1HeroGlass : _kInk;
    final chipUnselectedBg = glassStyle ? _kStep1Glass : _kSurface2;
    final chipSelectedText = glassStyle ? _kStep1OnGlass : _kSurface;
    final chipUnselectedText = glassStyle ? _kStep1OnGlassMuted : _kMuted;
    final chipBorder = glassStyle
        ? Colors.white.withValues(alpha: 0.14)
        : _kStroke;
    final chipSelectedBorder = glassStyle
        ? Colors.white.withValues(alpha: 0.35)
        : _kStroke;
    final stepperBg = glassStyle
        ? (unit == null ? _kStep1Glass : _kStep1HeroGlass)
        : (unit == null ? _kSurface2 : _kSurface);
    final stepperBorder = glassStyle
        ? Colors.white.withValues(alpha: 0.14)
        : _kStroke;
    final stepperText = glassStyle ? _kStep1OnGlass : _kInk;
    final stepperIcon = glassStyle ? _kStep1OnGlassMuted : null;

    Widget unitChip(String u, String label) {
      final sel = unit == u;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onChanged(value, sel ? null : u),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? chipSelectedBg : chipUnselectedBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? chipSelectedBorder : chipBorder),
            ),
            child: Center(
              child: Text(
                label,
                style: GoogleFonts.urbanist(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: sel ? chipSelectedText : chipUnselectedText,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Redo appointment (optional)',
          style: GoogleFonts.urbanist(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.8, color: labelColor),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            unitChip('days', 'Days'),
            const SizedBox(width: 6),
            unitChip('weeks', 'Weeks'),
            const SizedBox(width: 6),
            unitChip('months', 'Months'),
            const SizedBox(width: 6),
            unitChip('years', 'Years'),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: stepperBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: stepperBorder),
          ),
          child: Row(
            children: [
              Text('In', style: GoogleFonts.urbanist(fontSize: 12, fontWeight: FontWeight.w900, color: stepperText)),
              const Spacer(),
              IconButton(
                onPressed: unit == null || value <= 1 ? null : () => onChanged(value - 1, unit),
                icon: Icon(Icons.remove_circle_outline, color: stepperIcon),
              ),
              Text(
                '$value',
                style: glassStyle
                    ? GoogleFonts.urbanist(fontSize: 18, fontWeight: FontWeight.w800, color: stepperText)
                    : GoogleFonts.dmSerifDisplay(fontSize: 18, color: stepperText),
              ),
              IconButton(
                onPressed: unit == null ? null : () => onChanged(value + 1, unit),
                icon: Icon(Icons.add_circle_outline, color: stepperIcon),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStep3(BuildContext context) {
    Widget unitChip(String u, String label) {
      final sel = unit == u;
      return Expanded(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(value, sel ? null : u),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: sel ? Colors.black : Colors.white.withValues(alpha: 0.52),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: sel ? Colors.black : Colors.white.withValues(alpha: 0.72),
                ),
              ),
              child: Center(
                child: Text(
                  label,
                  style: GoogleFonts.urbanist(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: sel ? Colors.white : _kStep1Navy,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Step3FieldLabel('Redo appointment (optional)'),
        const SizedBox(height: 10),
        Row(
          children: [
            unitChip('days', 'Days'),
            const SizedBox(width: 8),
            unitChip('weeks', 'Weeks'),
            const SizedBox(width: 8),
            unitChip('months', 'Months'),
            const SizedBox(width: 8),
            unitChip('years', 'Years'),
          ],
        ),
        const SizedBox(height: 14),
        const _Step3FieldLabel('In'),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(_kStep3FieldRadius),
          // No BackdropFilter — Impeller Gaussian blur crashes iOS Simulator.
          child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(_kStep3FieldRadius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  _Step3StepperButton(
                    icon: Icons.remove_rounded,
                    enabled: unit != null && value > 1,
                    onTap: () => onChanged(value - 1, unit),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '$value',
                        style: GoogleFonts.urbanist(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _kStep1Navy,
                        ),
                      ),
                    ),
                  ),
                  _Step3StepperButton(
                    icon: Icons.add_rounded,
                    enabled: unit != null,
                    onTap: () => onChanged(value + 1, unit),
                  ),
                ],
              ),
            ),
        ),
      ],
    );
  }
}

class _Step3StepperButton extends StatelessWidget {
  const _Step3StepperButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: enabled ? 0.72 : 0.35),
          ),
          child: Icon(
            icon,
            size: 20,
            color: enabled ? _kStep1Navy : _kStep1Muted,
          ),
        ),
      ),
    );
  }
}

class _PainRow extends StatelessWidget {
  const _PainRow({required this.value, required this.onPick, this.glassStyle = false, this.step4Style = false, this.warmStyle = false});
  final String? value;
  final ValueChanged<String> onPick;
  final bool glassStyle;
  final bool step4Style;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    if (warmStyle) {
      Widget btn(String v, String emoji, String label) {
        final sel = value == v;
        return Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onPick(sel ? '' : v),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(10),
                selected: sel,
                compact: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(emoji, style: const TextStyle(fontSize: 18)),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (sel) ...[
                            Icon(Icons.check_rounded, size: 12, color: Colors.white.withValues(alpha: 0.92)),
                            const SizedBox(width: 3),
                          ],
                          Text(
                            label,
                            style: ProcedureSelectionTypography.chip(
                              size: 9,
                              weight: FontWeight.w600,
                              color: sel ? Colors.white : ProcedureSelectionTheme.ink.withValues(alpha: 0.88),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return Row(
        children: [
          btn('none', '😌', 'None'),
          const SizedBox(width: 6),
          btn('mild', '😐', 'Mild'),
          const SizedBox(width: 6),
          btn('moderate', '😬', 'Moderate'),
          const SizedBox(width: 6),
          btn('intense', '😤', 'Intense'),
        ],
      );
    }

    if (step4Style) {
      Widget btn(String v, String emoji, String label) {
        final sel = value == v;
        return Expanded(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onPick(sel ? '' : v),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _kStep3FieldBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: sel ? Colors.white.withValues(alpha: 0.35) : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(emoji, style: const TextStyle(fontSize: 22)),
                          const SizedBox(height: 6),
                          Text(
                            label,
                            style: GoogleFonts.urbanist(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (sel)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          alignment: Alignment.center,
                          child: const Icon(Icons.check_rounded, size: 12, color: Colors.black),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      return Row(
        children: [
          btn('none', '😌', 'None'),
          const SizedBox(width: 8),
          btn('mild', '😐', 'Mild'),
          const SizedBox(width: 8),
          btn('moderate', '😬', 'Moderate'),
          const SizedBox(width: 8),
          btn('intense', '😤', 'Intense'),
        ],
      );
    }

    final chipSelectedBg = glassStyle ? _kStep1HeroGlass : _kInk;
    final chipUnselectedBg = glassStyle ? _kStep1Glass : _kSurface2;
    final chipSelectedText = glassStyle ? _kStep1OnGlass : _kSurface;
    final chipUnselectedText = glassStyle ? _kStep1OnGlassMuted : _kMuted;
    final chipBorder = glassStyle ? Colors.white.withValues(alpha: 0.14) : _kStroke;
    final chipSelectedBorder = glassStyle ? Colors.white.withValues(alpha: 0.35) : _kStroke;

    Widget btn(String v, String emoji, String label) {
      final sel = value == v;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onPick(sel ? '' : v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: sel ? chipSelectedBg : chipUnselectedBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sel ? chipSelectedBorder : chipBorder),
            ),
            child: Column(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: GoogleFonts.urbanist(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: sel ? chipSelectedText : chipUnselectedText,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        btn('none', '😌', 'None'),
        const SizedBox(width: 6),
        btn('mild', '😐', 'Mild'),
        const SizedBox(width: 6),
        btn('moderate', '😬', 'Moderate'),
        const SizedBox(width: 6),
        btn('intense', '😤', 'Intense'),
      ],
    );
  }
}

class _GlowRevealCard extends StatelessWidget {
  const _GlowRevealCard({
    required this.title,
    required this.meta,
    required this.zone,
    required this.cost,
    required this.currency,
    required this.recoveryValue,
    required this.recoveryUnit,
    required this.category,
    required this.product,
    required this.volumeMl,
    required this.pain,
    required this.note,
    this.nextAppointmentLabel,
    this.warmStyle = false,
  });

  final String title;
  final String meta;
  final String zone;
  final String cost;
  final String currency;
  final int? recoveryValue;
  final String? recoveryUnit;
  final String category;
  final String product;
  final double? volumeMl;
  final String? pain;
  final String note;
  final String? nextAppointmentLabel;
  final bool warmStyle;

  @override
  Widget build(BuildContext context) {
    final recText = recoveryUnit == null ? '—' : '${recoveryValue ?? 0}${_unitShort(recoveryUnit!)}';
    String painShort(String? v) {
      final k = (v ?? '').trim().toLowerCase();
      return switch (k) {
        '' => '—',
        'none' => 'none',
        'mild' => 'mild',
        'moderate' => 'mod',
        'intense' => 'int',
        _ => v!,
      };
    }

    if (warmStyle) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: ProcedureSelectionTypography.display(size: 16),
          ),
          if (meta.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(meta, style: ProcedureSelectionTypography.body(size: 11)),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _WarmMiniStat(val: cost.isEmpty ? '—' : '$cost ${currency.trim()}'.trim(), label: 'Cost')),
              const SizedBox(width: 8),
              Expanded(child: _WarmMiniStat(val: recText, label: 'Recovery')),
              const SizedBox(width: 8),
              Expanded(child: _WarmMiniStat(val: painShort(pain), label: 'Pain')),
            ],
          ),
          if ((nextAppointmentLabel ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: ProcedureSelectionTheme.fieldFillLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NEXT APPOINTMENT',
                    style: ProcedureSelectionTypography.label(size: 9, weight: FontWeight.w700, color: ProcedureSelectionTheme.muted),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    nextAppointmentLabel!.trim(),
                    style: ProcedureSelectionTypography.display(size: 14),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _WarmGlowTag(text: category.isEmpty ? 'Procedure' : category),
              _WarmGlowTag(text: zone),
              if (product.trim().isNotEmpty) _WarmGlowTag(text: product),
              if (volumeMl != null) _WarmGlowTag(text: '${volumeMl!.toStringAsFixed(1)}ml'),
            ],
          ),
          if (note.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              '"$note"',
              style: ProcedureSelectionTypography.body(size: 11, weight: FontWeight.w500).copyWith(fontStyle: FontStyle.italic),
            ),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF1A1A2E), Color(0xFF2D2748)], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('GLOW JOURNAL', style: GoogleFonts.urbanist(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 2.2, color: _kSurface.withValues(alpha: 0.7))),
          const SizedBox(height: 10),
          Text(title, style: GoogleFonts.dmSerifDisplay(fontSize: 20, color: _kSurface, height: 1.2)),
          const SizedBox(height: 4),
          Text(meta, style: GoogleFonts.urbanist(fontSize: 11, color: const Color(0xFF7B7398))),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _MiniStat(val: cost.isEmpty ? '—' : '$cost ${currency.trim()}'.trim(), label: 'COST')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat(val: recText, label: 'RECOVERY')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat(val: painShort(pain), label: 'PAIN')),
            ],
          ),
          if ((nextAppointmentLabel ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: _kSurface.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'NEXT APPOINTMENT (OPTIONAL)',
                    style: GoogleFonts.urbanist(fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 1.4, color: const Color(0xFF7B7398)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    nextAppointmentLabel!.trim(),
                    style: GoogleFonts.dmSerifDisplay(fontSize: 17, color: const Color(0xFFC8BCE8), height: 1.15),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'From your redo-after guidance',
                    style: GoogleFonts.urbanist(fontSize: 10, color: const Color(0xFF6B6278), height: 1.35),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _GlowTag(text: category.isEmpty ? 'Procedure' : category),
              _GlowTag(text: zone),
              if (product.trim().isNotEmpty) _GlowTag(text: product),
              if (volumeMl != null) _GlowTag(text: '${volumeMl!.toStringAsFixed(1)}ml'),
            ],
          ),
          if (note.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _kSurface.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border(left: BorderSide(color: _kSurface.withValues(alpha: 0.2), width: 2)),
              ),
              child: Text('"$note"', style: GoogleFonts.urbanist(fontSize: 11, color: const Color(0xFF7B7398), height: 1.6, fontStyle: FontStyle.italic)),
            ),
          ],
        ],
      ),
    );
  }

  static String _unitShort(String u) => switch (u) {
        'weeks' => 'w',
        'months' => 'mo',
        'years' => 'y',
        _ => 'd',
      };
}

class _WarmMiniStat extends StatelessWidget {
  const _WarmMiniStat({required this.val, required this.label});

  final String val;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.fieldFillLight,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(
            val,
            style: ProcedureSelectionTypography.display(size: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: ProcedureSelectionTypography.label(size: 8, weight: FontWeight.w700, color: ProcedureSelectionTheme.muted),
          ),
        ],
      ),
    );
  }
}

class _WarmGlowTag extends StatelessWidget {
  const _WarmGlowTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.fieldFillLight,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06)),
      ),
      child: Text(
        text,
        style: ProcedureSelectionTypography.chip(size: 10, weight: FontWeight.w600, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.78)),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.val, required this.label});
  final String val;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: _kSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          Text(val, style: GoogleFonts.dmSerifDisplay(fontSize: 16, color: const Color(0xFFC8BCE8))),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.urbanist(fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: const Color(0xFF4A4468))),
        ],
      ),
    );
  }
}

class _GlowTag extends StatelessWidget {
  const _GlowTag({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: _kSurface.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(999), border: Border.all(color: _kSurface.withValues(alpha: 0.08))),
      child: Text(text, style: GoogleFonts.urbanist(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6, color: const Color(0xFFB7B0CC))),
    );
  }
}

// ---------- Dialogs & sheets ----------

int _defaultRecoveryDaysForCustomCategory(String category) {
  switch (category) {
    case 'Surgery':
      return 30;
    case 'Skin treatments':
      return 7;
    case 'Injectables':
      return 5;
    default:
      return 5;
  }
}

List<String> _zonesForCustomCategorySelection(String category) {
  return category == 'Surgery'
      ? List<String>.from(_kCommonBodyZones)
      : List<String>.from(_kCommonZones);
}

_BodyScope _scopeForCustomCategory(String category) {
  return category == 'Surgery' ? _BodyScope.body : _BodyScope.face;
}

Future<_ProcPreset?> _showCustomProcedureSheet(BuildContext context) {
  return showModalBottomSheet<_ProcPreset>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => const _CustomProcedureSheet(),
  );
}

/// Bottom sheet aligned with design reference `add_custom_procedure_sheet.html`.
class _CustomProcedureSheet extends StatefulWidget {
  const _CustomProcedureSheet();

  // Dark-glass tokens (matches the new all-black wizard UI).
  static const accent = Color(0xFFFFFFFF);
  static const inkText = Color(0xFFFFFFFF);
  static const muted = Color(0xB3FFFFFF);
  static const subtle = Color(0x80FFFFFF);
  static const hint = Color(0x99FFFFFF);
  static const fieldBg = Color(0x14FFFFFF);
  static const stroke = Color(0x24FFFFFF);

  static const categories = ['Injectables', 'Skin treatments', 'Surgery', 'Other'];
  static const suggestions = [
    'PRP therapy',
    'Skin booster',
    'Lip flip',
    'Nano needling',
    'Mesotherapy',
    'Thread lift',
  ];

  @override
  State<_CustomProcedureSheet> createState() => _CustomProcedureSheetState();
}

class _CustomProcedureSheetState extends State<_CustomProcedureSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();
  String _category = _CustomProcedureSheet.categories.first;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_onFocus);
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _nameFocus.removeListener(_onFocus);
    _nameCtrl.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _nameCtrl.text.trim();
    if (n.isEmpty) return;
    Navigator.pop(
      context,
      _ProcPreset(
        name: n,
        category: _category,
        emoji: '✦',
        tagline: 'Custom',
        recoveryDays: _defaultRecoveryDaysForCustomCategory(_category),
        productChips: const [],
        zones: _zonesForCustomCategorySelection(_category),
        scope: _scopeForCustomCategory(_category),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final focused = _nameFocus.hasFocus;

    return Material(
      color: const Color(0xFF000000),
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPad > 16 ? bottomPad : 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Custom procedure',
                        style: ProcedureSelectionTypography.display(size: 18, color: _CustomProcedureSheet.inkText),
                      ),
                    ),
                    Material(
                      color: Colors.white.withValues(alpha: 0.10),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => Navigator.pop(context),
                        child: const SizedBox(
                          width: 32,
                          height: 32,
                          child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
                child: Text(
                  'Name your procedure — you can edit all details on the next screen.',
                  style: ProcedureSelectionTypography.body(size: 11, color: _CustomProcedureSheet.muted),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PROCEDURE NAME',
                      style: ProcedureSelectionTypography.label(
                        size: 10,
                        weight: FontWeight.w800,
                        color: _CustomProcedureSheet.muted,
                      ).copyWith(letterSpacing: 2.2),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _nameCtrl,
                      focusNode: _nameFocus,
                      onChanged: (_) => setState(() {}),
                      keyboardAppearance: Brightness.dark,
                      textCapitalization: TextCapitalization.words,
                      style: ProcedureSelectionTypography.body(
                        size: 16,
                        weight: FontWeight.w600,
                        color: _CustomProcedureSheet.inkText,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Procedure name',
                        hintStyle: ProcedureSelectionTypography.body(
                          size: 16,
                          color: _CustomProcedureSheet.subtle,
                        ),
                        prefixIcon:
                            Icon(Icons.edit_outlined, size: 18, color: _CustomProcedureSheet.subtle.withValues(alpha: 0.9)),
                        filled: true,
                        fillColor: focused ? Colors.white.withValues(alpha: 0.16) : _CustomProcedureSheet.fieldBg,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: _CustomProcedureSheet.stroke, width: 1.2),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.55), width: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        'e.g. “PRP therapy”, “Skin booster”, “Lip flip”',
                        style: ProcedureSelectionTypography.body(
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'QUICK SUGGESTIONS',
                      style: ProcedureSelectionTypography.label(
                        size: 10,
                        weight: FontWeight.w800,
                        color: _CustomProcedureSheet.subtle,
                      ).copyWith(letterSpacing: 2.2),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final s in _CustomProcedureSheet.suggestions)
                          Material(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => setState(() => _nameCtrl.text = s),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
                                ),
                                child: Text(
                                  s,
                                  style: ProcedureSelectionTypography.chip(
                                    size: 11,
                                    weight: FontWeight.w600,
                                    color: Colors.white.withValues(alpha: 0.86),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CATEGORY',
                      style: ProcedureSelectionTypography.label(
                        size: 10,
                        weight: FontWeight.w800,
                        color: _CustomProcedureSheet.muted,
                      ).copyWith(letterSpacing: 2.2),
                    ),
                    const SizedBox(height: 10),
                    LayoutBuilder(
                      builder: (context, c) {
                        final gap = 8.0;
                        final w = (c.maxWidth - gap) / 2;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final cat in _CustomProcedureSheet.categories)
                              SizedBox(
                                width: w,
                                child: _CategoryPickTile(
                                  label: cat,
                                  selected: _category == cat,
                                  onTap: () => setState(() => _category = cat),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                height: 1,
                color: Colors.white.withValues(alpha: 0.10),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                child: Column(
                  children: [
                    FilledButton.icon(
                      onPressed: _nameCtrl.text.trim().isEmpty ? null : _submit,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: Text(
                        'Continue to details',
                        style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700),
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        backgroundColor: Colors.white.withValues(alpha: 0.16),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.white.withValues(alpha: 0.10),
                        disabledForegroundColor: Colors.white.withValues(alpha: 0.55),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'You’ll fill in doctor, date, cost and more next',
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.body(
                        size: 12,
                        color: Colors.white.withValues(alpha: 0.60),
                      ),
                    ),
                  ],
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

class _CategoryPickTile extends StatelessWidget {
  const _CategoryPickTile({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.white.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? Colors.white.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.14),
              width: 1.2,
            ),
          ),
          child: Row(
            children: [
              if (selected)
                Icon(Icons.check_rounded, size: 16, color: Colors.white.withValues(alpha: 0.92))
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ProcedureSelectionTypography.chip(
                    size: 11,
                    weight: FontWeight.w600,
                    color: selected ? Colors.white : Colors.white.withValues(alpha: 0.78),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> _showAddZoneDialog(BuildContext context) async {
  // Bottom sheet aligned with `custom_zone_sheet.html`.
  final ctrl = TextEditingController();
  final focus = FocusNode();

  const suggestions = <String>[
    'Neck',
    'Décolletage',
    'Scalp',
    'Hands',
    'Back',
    'Shoulders',
    'Abdomen',
    'Arms',
  ];

  Future<void> closeWith(String? value, BuildContext sheetContext) async {
    Navigator.of(sheetContext).pop(value);
  }

  final res = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
      final bottomSafe = MediaQuery.paddingOf(sheetContext).bottom;

      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          padding: EdgeInsets.fromLTRB(22, 0, 22, 18 + bottomSafe),
          decoration: BoxDecoration(
            color: const Color(0xFF000000),
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
            border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Custom zone',
                        style: ProcedureSelectionTypography.display(size: 18, color: Colors.white),
                      ),
                    ),
                    InkWell(
                      onTap: () => closeWith(null, sheetContext),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.10), shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Name the treatment zone not listed above.',
                  style: ProcedureSelectionTypography.body(size: 11, color: Colors.white.withValues(alpha: 0.65)),
                ),
                const SizedBox(height: 18),
                Text(
                  'ZONE NAME',
                  style: ProcedureSelectionTypography.label(
                    size: 10,
                    weight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.55),
                  ).copyWith(letterSpacing: 2.2),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  focusNode: focus,
                  keyboardAppearance: Brightness.dark,
                  textCapitalization: TextCapitalization.words,
                  cursorColor: Colors.white,
                  style: ProcedureSelectionTypography.body(
                    size: 16,
                    weight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Neck',
                    hintStyle: ProcedureSelectionTypography.body(
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.30),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.only(bottom: 10),
                    border: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.35), width: 2)),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.28), width: 2)),
                    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.55), width: 2)),
                  ),
                  onSubmitted: (_) {
                    final v = ctrl.text.trim();
                    if (v.isEmpty) return;
                    closeWith(v, sheetContext);
                  },
                ),
                const SizedBox(height: 7),
                Text(
                  'e.g. Neck, Décolletage, Scalp, Hands',
                  style: ProcedureSelectionTypography.body(size: 11, color: Colors.white.withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 18),
                Text(
                  'SUGGESTIONS',
                  style: ProcedureSelectionTypography.label(
                    size: 10,
                    weight: FontWeight.w800,
                    color: Colors.white.withValues(alpha: 0.55),
                  ).copyWith(letterSpacing: 2.2),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final s in suggestions)
                      InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () {
                          ctrl.text = s;
                          ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
                          focus.requestFocus();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
                          ),
                          child: Text(
                            s,
                            style: ProcedureSelectionTypography.chip(
                              size: 11,
                              weight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.86),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () {
                    final v = ctrl.text.trim();
                    if (v.isEmpty) return;
                    closeWith(v, sheetContext);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.16),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    textStyle: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700),
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add zone'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  ctrl.dispose();
  focus.dispose();
  return res;
}

