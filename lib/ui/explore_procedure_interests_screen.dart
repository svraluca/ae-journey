import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import '../services/explore_procedure_interests.dart';
import '../services/openai_service.dart';
import '../services/session_prefs.dart';
import 'procedure_selection_theme.dart';
import 'subscription_screen.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// First-run personalization: pick which procedures become Compare tabs.
class ExploreProcedureInterestsScreen extends StatefulWidget {
  const ExploreProcedureInterestsScreen({
    super.key,
    required this.repo,
    this.onFinished,
    this.homeBuilder,
    this.editing = false,
  });

  final ProcedureRepository repo;

  /// Called after Save / Skip / Continue — typically navigates to home.
  final VoidCallback? onFinished;

  /// When set (first-run), replace the stack with this home after finish.
  final WidgetBuilder? homeBuilder;

  /// Profile re-edit: no Skip, title tweaked, pops on save.
  final bool editing;

  @override
  State<ExploreProcedureInterestsScreen> createState() =>
      _ExploreProcedureInterestsScreenState();
}

class _ExploreProcedureInterestsScreenState
    extends State<ExploreProcedureInterestsScreen> {
  final Set<String> _selectedIds = {};
  String? _lockedTapHint;
  bool _saving = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final saved = await SessionPrefs.exploreInterestPills();
    if (!mounted) return;
    setState(() {
      if (saved.isEmpty && !widget.editing) {
        _selectedIds.addAll(const ['botox', 'rhinoplasty']);
      } else {
        for (final interest in kExploreSelectableInterests) {
          if (saved.any(
            (p) => exploreCanonicalComparePill(p) == interest.pill,
          )) {
            _selectedIds.add(interest.id);
          }
        }
      }
      _loaded = true;
    });
  }

  List<String> get _selectedPills =>
      exploreInterestPillsFromIds(_selectedIds);

  List<String> get _visibleLockedLabels => kExploreLockedInterestLabels
      .take(kExploreLockedInterestsPreviewCount)
      .toList();

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  Future<void> _finish({required bool skip}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (skip) {
        await SessionPrefs.setExploreInterestPills(
          List<String>.from(kExploreComparePills),
        );
      } else {
        final pills = _selectedPills;
        if (pills.isEmpty) {
          setState(() => _saving = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pick at least one procedure for your tabs.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        await SessionPrefs.setExploreInterestPills(pills);
      }
      exploreInterestRevision.value++;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    if (widget.homeBuilder != null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: widget.homeBuilder!),
        (_) => false,
      );
      return;
    }
    if (widget.onFinished != null) {
      widget.onFinished!();
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: ProcedureSelectionTheme.pageBackground,
      body: Stack(
        children: [
          const Step2WarmBackground(),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: Row(
                    children: [
                      if (widget.editing)
                        _TopGlassButton(
                          icon: Icons.close_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        )
                      else
                        const SizedBox(width: 44),
                      const Spacer(),
                      if (!widget.editing)
                        TextButton(
                          onPressed:
                              _saving ? null : () => _finish(skip: true),
                          child: Text(
                            'Skip',
                            style: ProcedureSelectionTypography.body(
                              size: 15,
                              weight: FontWeight.w600,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        )
                      else
                        const SizedBox(width: 44),
                    ],
                  ),
                ),
                Expanded(
                  child: !_loaded
                      ? Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: ProcedureSelectionTheme.ink
                                  .withValues(alpha: 0.45),
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                          children: [
                            const ProcedureSectionLabel('Personalize'),
                            const SizedBox(height: 12),
                            Text(
                              'What are you interested in?',
                              style: ProcedureSelectionTypography.display(
                                size: 26,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Choose procedures to personalize your explore '
                              'page. You can change this anytime.',
                              style: ProcedureSelectionTypography.body(
                                size: 14,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                for (final interest
                                    in kExploreSelectableInterests)
                                  _InterestChip(
                                    label: interest.label,
                                    selected:
                                        _selectedIds.contains(interest.id),
                                    onTap: () {
                                      if (_lockedTapHint != null) {
                                        setState(() => _lockedTapHint = null);
                                      }
                                      _toggle(interest.id);
                                    },
                                  ),
                                for (final label in _visibleLockedLabels)
                                  _LockedInterestChip(
                                    label: label,
                                    highlighted: _lockedTapHint == label,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      setState(() => _lockedTapHint = label);
                                    },
                                  ),
                                _LockedInterestChip(
                                  label: '+143 procedures more',
                                  highlighted:
                                      _lockedTapHint == '+143 procedures more',
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    setState(
                                      () => _lockedTapHint =
                                          '+143 procedures more',
                                    );
                                  },
                                ),
                              ],
                            ),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: _lockedTapHint == null
                                  ? const SizedBox(width: double.infinity)
                                  : Padding(
                                      padding: const EdgeInsets.only(top: 14),
                                      child: _SubscribeHintBanner(
                                        key: ValueKey(_lockedTapHint),
                                        procedureLabel: _lockedTapHint!,
                                        onViewPlans: () {
                                          Navigator.of(context).push<void>(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  SubscriptionScreen(
                                                repo: widget.repo,
                                              ),
                                            ),
                                          );
                                        },
                                        onDismiss: () => setState(
                                          () => _lockedTapHint = null,
                                        ),
                                      ),
                                    ),
                            ),
                            const SizedBox(height: 24),
                            _LiveTabPreview(pills: _selectedPills),
                          ],
                        ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16 + bottom),
                  child: ProcedurePremiumContinueButton(
                    label: _saving
                        ? (widget.editing ? 'Saving…' : 'Continuing…')
                        : (widget.editing ? 'Save' : 'Continue'),
                    onPressed: _saving ? null : () => _finish(skip: false),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopGlassButton extends StatelessWidget {
  const _TopGlassButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(999),
        compact: true,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: ProcedureSelectionTheme.ink,
          ),
        ),
      ),
    );
  }
}

class _InterestChip extends StatelessWidget {
  const _InterestChip({
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
      child: AnimatedScale(
        scale: selected ? 1.0 : 0.98,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          selected: selected,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              label,
              style: ProcedureSelectionTypography.chip(
                size: 12,
                weight: FontWeight.w700,
                color: selected
                    ? Colors.white
                    : ProcedureSelectionTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mini Compare tab strip so the user sees what will appear in Explore.
class _LiveTabPreview extends StatelessWidget {
  const _LiveTabPreview({required this.pills});

  final List<String> pills;

  @override
  Widget build(BuildContext context) {
    final shown = pills.isEmpty
        ? const <String>[]
        : pills.map(exploreInterestTabLabel).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ProcedureSectionLabel('Your explore tabs'),
        const SizedBox(height: 12),
        ProcedureGlassSurface(
          borderRadius:
              BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          illuminated: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: shown.isEmpty
                ? Text(
                    'Select procedures to build your tab strip.',
                    style: ProcedureSelectionTypography.body(
                      size: 13,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  )
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < shown.length; i++) ...[
                          if (i > 0) const SizedBox(width: 16),
                          _PreviewTab(
                            label: shown[i],
                            selected: i == 0,
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _PreviewTab extends StatelessWidget {
  const _PreviewTab({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: selected ? 2 : 1,
            color: selected
                ? ProcedureSelectionTheme.ink
                : ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Text(
        label,
        style: ProcedureSelectionTypography.chip(
          size: 12,
          weight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? ProcedureSelectionTheme.ink
              : ProcedureSelectionTheme.muted,
        ),
      ),
    );
  }
}

class _LockedInterestChip extends StatefulWidget {
  const _LockedInterestChip({
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  State<_LockedInterestChip> createState() => _LockedInterestChipState();
}

class _LockedInterestChipState extends State<_LockedInterestChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _lock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final Animation<Offset> _lockSlide = Tween<Offset>(
    begin: const Offset(1.2, 0),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _lock, curve: Curves.easeOutCubic));
  late final Animation<double> _lockFade = CurvedAnimation(
    parent: _lock,
    curve: Curves.easeOut,
  );

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) _lock.value = 1;
  }

  @override
  void didUpdateWidget(covariant _LockedInterestChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlighted == oldWidget.highlighted) return;
    if (widget.highlighted) {
      _lock.forward(from: 0);
    } else {
      _lock.reverse();
    }
  }

  @override
  void dispose() {
    _lock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.highlighted;
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(
          highlighted ? 12 : 14,
          10,
          14,
          10,
        ),
        decoration: BoxDecoration(
          color: highlighted
              ? ProcedureSelectionTheme.ink.withValues(alpha: 0.07)
              : Colors.white.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: highlighted
                ? ProcedureSelectionTheme.ink.withValues(alpha: 0.22)
                : ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRect(
              child: SizeTransition(
                sizeFactor: _lockFade,
                axis: Axis.horizontal,
                axisAlignment: 1,
                child: FadeTransition(
                  opacity: _lockFade,
                  child: SlideTransition(
                    position: _lockSlide,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Icon(
                        Icons.lock_outline_rounded,
                        size: 12,
                        color: ProcedureSelectionTheme.ink
                            .withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Text(
              widget.label,
              style: ProcedureSelectionTypography.chip(
                size: 12,
                weight: FontWeight.w600,
                color: ProcedureSelectionTheme.ink.withValues(
                  alpha: highlighted ? 0.55 : 0.38,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscribeHintBanner extends StatefulWidget {
  const _SubscribeHintBanner({
    super.key,
    required this.procedureLabel,
    required this.onViewPlans,
    required this.onDismiss,
  });

  final String procedureLabel;
  final VoidCallback onViewPlans;
  final VoidCallback onDismiss;

  @override
  State<_SubscribeHintBanner> createState() => _SubscribeHintBannerState();
}

class _SubscribeHintBannerState extends State<_SubscribeHintBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.55),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.0, 0.9, curve: Curves.easeOut),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bodyStyle = GoogleFonts.plusJakartaSans(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.4,
      color: Colors.white.withValues(alpha: 0.58),
    );

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(18),
          compact: true,
          selected: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lock_rounded,
                            size: 15,
                            color: Colors.white.withValues(alpha: 0.92),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              'Unlock ${widget.procedureLabel}',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                height: 1.25,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text.rich(
                        TextSpan(
                          style: bodyStyle,
                          children: [
                            const TextSpan(
                              text:
                                  'This procedure is part of a paid plan. ',
                            ),
                            TextSpan(
                              text: 'Subscribe',
                              style: bodyStyle.copyWith(
                                fontWeight: FontWeight.w800,
                                color: Colors.white.withValues(alpha: 0.92),
                              ),
                            ),
                            const TextSpan(
                              text: ' to add it to your Explore tabs.',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: widget.onViewPlans,
                        child: Text(
                          'View subscription plans',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            decoration: TextDecoration.underline,
                            decorationColor:
                                Colors.white.withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: widget.onDismiss,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.55),
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
