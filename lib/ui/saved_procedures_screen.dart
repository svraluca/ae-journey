import 'package:flutter/material.dart';

import '../services/saved_bookmarks_store.dart';
import '../services/saved_procedures_store.dart';
import 'saved_compare_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// Saved screen — light glass vibe matching Timeline.
class SavedProceduresScreen extends StatefulWidget {
  const SavedProceduresScreen({super.key});

  @override
  State<SavedProceduresScreen> createState() => _SavedProceduresScreenState();
}

class _SavedProceduresScreenState extends State<SavedProceduresScreen> {
  final _bookmarks = SavedBookmarksStore.instance;
  final _procStore = SavedProceduresStore.instance;

  /// 0 = procedures, 1 = clinics
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _bookmarks.addListener(_onBookmarksChanged);
  }

  @override
  void dispose() {
    _bookmarks.removeListener(_onBookmarksChanged);
    super.dispose();
  }

  void _onBookmarksChanged() {
    if (mounted) setState(() {});
  }

  String _weekdayDate(DateTime d) {
    const wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
  }

  List<SavedBookmarkEntry> get _procedureEntries =>
      _bookmarks.items.where((e) => e.procedureName.trim().isNotEmpty).toList();

  List<SavedBookmarkEntry> get _clinicEntries =>
      _bookmarks.items.where((e) => e.procedureName.trim().isEmpty).toList();

  List<SavedBookmarkEntry> get _visible =>
      _tab == 0 ? _procedureEntries : _clinicEntries;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final now = DateTime.now();
    final visible = _visible;
    final compareCount = _procStore.items.length;
    final procedureCount = _procedureEntries.length;
    final clinicCount = _clinicEntries.length;

    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _GlassCircleButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ProcedureSectionLabel(_weekdayDate(now)),
                              const SizedBox(height: 8),
                              Text(
                                'Saved',
                                style: ProcedureSelectionTypography.display(
                                  size: 18,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Bookmarks and compare pool for clinics & treatments.',
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: _ComparePanel(
                      count: compareCount,
                      onCompare: () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => const SavedCompareScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: _SavedTabs(
                      tab: _tab,
                      procedureCount: procedureCount,
                      clinicCount: clinicCount,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: ProcedureSectionLabel(
                            _tab == 0 ? 'Saved procedures' : 'Saved clinics',
                          ),
                        ),
                        Text(
                          '${visible.length} saved',
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_bookmarks.isLoading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 24, 20, 0),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  )
                else if (visible.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                        compact: true,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                          child: Column(
                            children: [
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: ProcedureSelectionTheme.fieldFill,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.favorite_border_rounded,
                                  size: 24,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                _tab == 0 ? 'No saved procedures' : 'No saved clinics',
                                style: ProcedureSelectionTypography.display(
                                  size: 15,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _tab == 0
                                    ? 'Save a treatment from a clinic profile to compare prices here.'
                                    : 'Save a clinic from search or a clinic profile to find it here.',
                                textAlign: TextAlign.center,
                                style: ProcedureSelectionTypography.body(
                                  size: 12,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 32 + bottomPad),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final entry = visible[index];
                          return Padding(
                            padding: EdgeInsets.only(
                              bottom: index == visible.length - 1 ? 0 : 10,
                            ),
                            child: _SavedBookmarkCard(
                              entry: entry,
                              onUnsave: () => _bookmarks.remove(
                                entry.clinicName,
                                procedureName: entry.procedureName,
                              ),
                            ),
                          );
                        },
                        childCount: visible.length,
                      ),
                    ),
                  ),
                if (visible.isEmpty && !_bookmarks.isLoading)
                  SliverToBoxAdapter(child: SizedBox(height: 40 + bottomPad)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SavedTabs extends StatelessWidget {
  const _SavedTabs({
    required this.tab,
    required this.procedureCount,
    required this.clinicCount,
    required this.onChanged,
  });

  final int tab;
  final int procedureCount;
  final int clinicCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(14),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            Expanded(
              child: _TabChip(
                label: 'Procedures',
                count: procedureCount,
                selected: tab == 0,
                onTap: () => onChanged(0),
              ),
            ),
            Expanded(
              child: _TabChip(
                label: 'Clinics',
                count: clinicCount,
                selected: tab == 1,
                onTap: () => onChanged(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? ProcedureSelectionTheme.buttonPrimary : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: ProcedureSelectionTypography.label(
                  size: 13,
                  weight: FontWeight.w700,
                  color: selected ? Colors.white : ProcedureSelectionTheme.ink,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.18)
                      : ProcedureSelectionTheme.fieldFill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: ProcedureSelectionTypography.label(
                    size: 11,
                    weight: FontWeight.w700,
                    color: selected
                        ? Colors.white.withValues(alpha: 0.92)
                        : ProcedureSelectionTheme.muted,
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
            width: 36,
            height: 36,
            child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _ComparePanel extends StatelessWidget {
  const _ComparePanel({required this.count, required this.onCompare});

  final int count;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    return ProcedureSelectionPanel(
      title: 'Compare',
      compactTitle: true,
      subtitle: count == 0
          ? 'Save procedures to build your compare pool.'
          : '$count procedure${count == 1 ? '' : 's'} ready to compare prices.',
      child: Material(
        color: ProcedureSelectionTheme.buttonPrimary,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onCompare,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.compare_arrows_rounded, size: 18, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Open compare',
                  style: ProcedureSelectionTypography.label(
                    size: 14,
                    weight: FontWeight.w700,
                    color: Colors.white,
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

class _SavedBookmarkCard extends StatelessWidget {
  const _SavedBookmarkCard({
    required this.entry,
    required this.onUnsave,
  });

  final SavedBookmarkEntry entry;
  final VoidCallback onUnsave;

  @override
  Widget build(BuildContext context) {
    final hasProcedure = entry.procedureName.trim().isNotEmpty;
    final title = hasProcedure ? entry.procedureName.trim() : entry.clinicName.trim();
    final price = entry.priceLabel.trim();
    final clinicLine = hasProcedure ? entry.clinicName.trim() : '';

    Widget ratingChip() {
      if (entry.rating <= 0) return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 12, color: ProcedureSelectionTheme.ink),
          const SizedBox(width: 2),
          Text(
            entry.rating.toStringAsFixed(1),
            style: ProcedureSelectionTypography.label(
              size: 11,
              weight: FontWeight.w700,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
        ],
      );
    }

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Color(entry.avatarColor),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Text(
                entry.initials,
                style: ProcedureSelectionTypography.display(
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasProcedure)
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ProcedureSelectionTypography.label(
                        size: 12,
                        weight: FontWeight.w700,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    )
                  else
                    Row(
                      children: [
                        ratingChip(),
                        if (entry.rating > 0) const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: ProcedureSelectionTypography.display(
                              size: 14,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (clinicLine.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        ratingChip(),
                        if (entry.rating > 0) const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            clinicLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ProcedureSelectionTypography.label(
                              size: 11,
                              weight: FontWeight.w600,
                              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.place_outlined, size: 12, color: ProcedureSelectionTheme.muted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          entry.locationLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (entry.tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: entry.tags
                          .take(4)
                          .map(
                            (t) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: ProcedureSelectionTheme.fieldFill,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                t,
                                style: ProcedureSelectionTypography.label(
                                  size: 10,
                                  weight: FontWeight.w600,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (price.isNotEmpty)
                  Text(
                    price,
                    textAlign: TextAlign.right,
                    style: ProcedureSelectionTypography.label(
                      size: 13,
                      weight: FontWeight.w700,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                SizedBox(height: price.isNotEmpty ? 10 : 0),
                Material(
                  color: ProcedureSelectionTheme.buttonPrimary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onUnsave,
                    child: const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(Icons.favorite_rounded, size: 15, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
