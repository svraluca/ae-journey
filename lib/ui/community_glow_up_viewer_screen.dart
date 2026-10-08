import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/progress_share_service.dart';
import '../services/saved_glow_ups_store.dart';
import 'formatters.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// Public community post payload for the viewer journey screen.
class CommunityGlowUpView {
  const CommunityGlowUpView({
    required this.procedure,
    required this.area,
    required this.duration,
    required this.daysAgo,
    required this.userName,
    required this.iconAsset,
    this.clinic,
    this.doctor,
    this.product,
    this.volumeMl,
    this.beforePhotoUrl,
    this.afterPhotoUrl,
    this.procedureDate,
  });

  final String procedure;
  final String area;
  final String duration;
  final int daysAgo;
  final String userName;
  final String iconAsset;
  final String? clinic;
  final String? doctor;
  final String? product;
  final double? volumeMl;
  final String? beforePhotoUrl;
  final String? afterPhotoUrl;
  final DateTime? procedureDate;

  String get id => '$procedure|$area|$userName|$daysAgo';

  String? get productLine {
    final prod = (product ?? '').trim();
    if (prod.isEmpty && volumeMl == null) return null;
    if (prod.isNotEmpty && volumeMl != null) {
      final v = volumeMl!;
      final vs = v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
      return '$prod / $vs ml';
    }
    if (volumeMl != null) {
      final v = volumeMl!;
      return v == v.roundToDouble() ? '${v.toInt()} ml' : '${v.toStringAsFixed(1)} ml';
    }
    return prod;
  }
}

/// Procedure journey UI from a community viewer perspective (read-only).
class CommunityGlowUpViewerScreen extends StatefulWidget {
  const CommunityGlowUpViewerScreen({super.key, required this.post});

  final CommunityGlowUpView post;

  @override
  State<CommunityGlowUpViewerScreen> createState() =>
      _CommunityGlowUpViewerScreenState();
}

enum _ViewerTab { milestones, about }

class _CommunityGlowUpViewerScreenState extends State<CommunityGlowUpViewerScreen> {
  _ViewerTab _tab = _ViewerTab.milestones;
  double _slider = 0.5;
  bool _useSlider = true;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final post = widget.post;

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
                        child: _ViewerHeader(
                          title: post.procedure,
                          subtitle: post.area,
                          userName: post.userName,
                          duration: post.duration,
                          iconAsset: post.iconAsset,
                          onBack: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 14, 10, 0),
                      child: _ViewerBeforeAfterHero(
                        procedureName: post.procedure,
                        beforeUrl: post.beforePhotoUrl,
                        afterUrl: post.afterPhotoUrl,
                        useSlider: _useSlider,
                        onUseSliderChanged: (v) => setState(() => _useSlider = v),
                        slider: _slider,
                        onSlider: (v) => setState(() => _slider = v),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Column(
                        children: [
                          _ViewerTabBar(
                            tab: _tab,
                            onChanged: (t) => setState(() => _tab = t),
                          ),
                          const SizedBox(height: 14),
                        ],
                      ),
                    ),
                  ),
                  if (_tab == _ViewerTab.milestones)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      sliver: SliverToBoxAdapter(
                        child: _ViewerMilestones(daysAgo: post.daysAgo),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      sliver: SliverToBoxAdapter(
                        child: _ViewerAbout(post: post),
                      ),
                    ),
                  SliverToBoxAdapter(child: SizedBox(height: bottomPad + 100)),
                ],
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: bottomPad + 16,
                child: _ViewerShareFab(
                  onShare: () async {
                    final origin = ProgressShareService.originFromContext(context);
                    try {
                      await ProgressShareService.instance.shareCommunityView(
                        post,
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
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({
    required this.title,
    required this.subtitle,
    required this.userName,
    required this.duration,
    required this.iconAsset,
    required this.onBack,
  });

  final String title;
  final String subtitle;
  final String userName;
  final String duration;
  final String iconAsset;
  final VoidCallback onBack;

  SavedGlowUpEntry get _entry => SavedGlowUpEntry(
        procedure: title,
        duration: duration,
        area: subtitle,
        userName: userName,
        iconAsset: iconAsset,
      );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _GlassCircleButton(icon: Icons.chevron_left_rounded, onTap: onBack),
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
        AnimatedBuilder(
          animation: SavedGlowUpsStore.instance,
          builder: (context, _) {
            final saved = SavedGlowUpsStore.instance.contains(_entry);
            return SizedBox(
              width: 42,
              child: IconButton(
                onPressed: () => SavedGlowUpsStore.instance.toggle(_entry),
                padding: EdgeInsets.zero,
                icon: Icon(
                  saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  size: 22,
                  color: saved
                      ? const Color(0xFFE2556B)
                      : ProcedureSelectionTheme.ink,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  const _GlassCircleButton({required this.icon, required this.onTap});

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
                  Center(
                    child: Icon(icon, size: 22, color: ProcedureSelectionTheme.ink),
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

class _ViewerBeforeAfterHero extends StatelessWidget {
  const _ViewerBeforeAfterHero({
    required this.procedureName,
    required this.useSlider,
    required this.onUseSliderChanged,
    required this.slider,
    required this.onSlider,
    this.beforeUrl,
    this.afterUrl,
  });

  final String procedureName;
  final bool useSlider;
  final ValueChanged<bool> onUseSliderChanged;
  final double slider;
  final ValueChanged<double> onSlider;
  final String? beforeUrl;
  final String? afterUrl;

  bool _isHttp(String? u) {
    final v = (u ?? '').trim();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  Widget _photoOrFallback({required bool before}) {
    final url = before ? beforeUrl : afterUrl;
    if (!_isHttp(url)) {
      return ColoredBox(
        color: before ? const Color(0xFF8A8A93) : const Color(0xFF2A2A30),
      );
    }
    return Image.network(
      url!.trim(),
      fit: BoxFit.cover,
      alignment: Alignment.center,
      errorBuilder: (_, __, ___) => ColoredBox(
        color: before ? const Color(0xFF8A8A93) : const Color(0xFF2A2A30),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = w * 0.72;
        final split = (slider.clamp(0.08, 0.92)) * w;

        return ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (useSlider) ...[
                  Positioned.fill(child: _photoOrFallback(before: false)),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: split,
                    child: ClipRect(child: _photoOrFallback(before: true)),
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
                        onSlider(((slider * w) + d.delta.dx) / w);
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
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: _photoOrFallback(before: true)),
                      Container(width: 1.5, color: Colors.white.withValues(alpha: 0.85)),
                      Expanded(child: _photoOrFallback(before: false)),
                    ],
                  ),
                const Positioned(
                  top: 12,
                  left: 12,
                  child: _BaTag('BEFORE'),
                ),
                const Positioned(
                  top: 12,
                  right: 12,
                  child: _BaTag('AFTER'),
                ),
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: _DarkPill(
                    icon: Icons.water_drop_outlined,
                    label: procedureName,
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _CompareModeToggle(
                    useSlider: useSlider,
                    onChanged: onUseSliderChanged,
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

class _BaTag extends StatelessWidget {
  const _BaTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _DarkPill extends StatelessWidget {
  const _DarkPill({required this.icon, required this.label});

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
          _chip(Icons.swap_horiz_rounded, useSlider, () => onChanged(true)),
          _chip(Icons.view_column_outlined, !useSlider, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, bool selected, VoidCallback onTap) {
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

class _ViewerTabBar extends StatelessWidget {
  const _ViewerTabBar({required this.tab, required this.onChanged});

  final _ViewerTab tab;
  final ValueChanged<_ViewerTab> onChanged;

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
                selected: tab == _ViewerTab.milestones,
                onTap: () => onChanged(_ViewerTab.milestones),
              ),
            ),
            Expanded(
              child: _TabPill(
                label: 'About procedure',
                selected: tab == _ViewerTab.about,
                onTap: () => onChanged(_ViewerTab.about),
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

class _ViewerMilestone {
  const _ViewerMilestone({
    required this.timeLabel,
    required this.title,
    required this.body,
    this.isToday = false,
  });

  final String timeLabel;
  final String title;
  final String body;
  final bool isToday;
}

class _ViewerMilestones extends StatelessWidget {
  const _ViewerMilestones({required this.daysAgo});

  final int daysAgo;

  List<_ViewerMilestone> get _items {
    const defaults = <({int days, String time, String title, String body})>[
      (days: 1, time: 'Day 1', title: 'The beginning', body: 'Swelling and bruising are normal after treatment.'),
      (days: 7, time: 'Day 7', title: 'First improvements', body: 'Early healing — bruising should start to fade.'),
      (days: 31, time: '1 Month', title: 'Visible changes', body: 'Shape settles and swelling continues to ease.'),
      (days: 92, time: '3 Months', title: 'Refining results', body: 'Results look more natural and refined.'),
    ];

    return [
      const _ViewerMilestone(
        timeLabel: 'Today',
        title: 'Current progress',
        body: 'This is where their journey stands now.',
        isToday: true,
      ),
      for (final d in defaults)
        if (daysAgo >= d.days)
          _ViewerMilestone(
            timeLabel: d.time,
            title: d.title,
            body: d.body,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          _MilestoneRow(
            item: items[i],
            isFirst: i == 0,
            isLast: i == items.length - 1,
          ),
          if (i < items.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _MilestoneRow extends StatelessWidget {
  const _MilestoneRow({
    required this.item,
    required this.isFirst,
    required this.isLast,
  });

  final _ViewerMilestone item;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final nodeColor = item.isToday
        ? const Color(0xFFD0D0D4)
        : ProcedureSelectionTheme.ink;
    final nodeBorder = item.isToday
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
                  width: item.isToday ? 12 : 10,
                  height: item.isToday ? 12 : 10,
                  decoration: BoxDecoration(
                    color: nodeColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: nodeBorder, width: 1.5),
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
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(18),
              compact: true,
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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: ColoredBox(
                          color: const Color(0xFFE4E4E8),
                          child: Icon(
                            Icons.image_outlined,
                            size: 18,
                            color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewerAbout extends StatelessWidget {
  const _ViewerAbout({required this.post});

  final CommunityGlowUpView post;

  @override
  Widget build(BuildContext context) {
    final doctor = (post.doctor ?? '').trim();
    final clinic = (post.clinic ?? '').trim();
    final productLine = post.productLine ?? '—';
    final dateLabel = post.procedureDate != null
        ? formatDate(post.procedureDate!)
        : post.duration;

    return SizedBox(
      width: double.infinity,
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(18),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              _AboutRow(label: 'Doctor', value: doctor.isEmpty ? '—' : doctor),
              _AboutRow(label: 'Clinic', value: clinic.isEmpty ? '—' : clinic),
              _AboutRow(label: 'Date', value: dateLabel),
              _AboutRow(label: 'Product', value: productLine, isLast: true),
            ],
          ),
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

class _ViewerShareFab extends StatelessWidget {
  const _ViewerShareFab({required this.onShare});

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
        padding: const EdgeInsets.all(12),
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
