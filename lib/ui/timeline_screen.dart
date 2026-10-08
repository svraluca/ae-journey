import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import 'formatters.dart';
import 'procedure_detail_screen.dart';
import 'procedure_form_screen.dart';
import 'procedure_icon_resolver.dart';
import 'procedure_selection_theme.dart';
import 'timeline_filter_sheet.dart';
import 'widgets/apple_empty_procedures.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

const _tlProcedureCardMinHeight = 84.0;
const _tlProcedureCardGap = 5.0;

class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  final ValueNotifier<TimelineFilterCriteria> _criteria =
      ValueNotifier<TimelineFilterCriteria>(TimelineFilterCriteria.empty);

  @override
  void dispose() {
    _criteria.dispose();
    super.dispose();
  }

  List<Procedure> _applyFilter(List<Procedure> items, List<String> savedTypes) {
    final effective = effectiveTimelineFilterCriteria(_criteria.value, savedTypes);
    return items.where(effective.matches).toList();
  }

  Future<void> _openFilters(List<Procedure> all) async {
    final savedTypes = timelineSavedProcedureTypes(all);
    final currency = all.firstWhere((p) => p.cost != null, orElse: () => all.first).currency;
    final result = await showTimelineFilterSheet(
      context,
      initial: effectiveTimelineFilterCriteria(_criteria.value, savedTypes),
      procedureTypes: savedTypes,
      currency: currency,
    );
    if (result == null || !mounted) return;
    _criteria.value = result;
  }

  List<({DateTime day, List<Procedure> items})> _groupByDay(List<Procedure> items) {
    final map = <DateTime, List<Procedure>>{};
    for (final p in items) {
      final day = DateTime(p.date.year, p.date.month, p.date.day);
      (map[day] ??= []).add(p);
    }
    for (final e in map.entries) {
      e.value.sort(compareProceduresNewestFirst);
    }
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final k in keys) (day: k, items: map[k]!)];
  }

  int _glowScore(List<Procedure> items) {
    if (items.isEmpty) return 0;
    return (items.length * 94).clamp(0, 999);
  }

  int _monthlyGlowDelta(List<Procedure> items) {
    final now = DateTime.now();
    final thisMonth = items.where((p) => p.date.year == now.year && p.date.month == now.month).length;
    return thisMonth * 15;
  }

  String _totalSpend(List<Procedure> items) {
    if (items.isEmpty) return '—';
    final sum = items.fold<num>(0, (acc, p) => acc + (p.cost ?? 0));
    if (sum <= 0) return '—';
    final currency = items.firstWhere((p) => p.cost != null, orElse: () => items.first).currency;
    return formatMoney(sum, currency);
  }

  String _weekdayDate(DateTime d) {
    const wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.repo, _criteria]),
      builder: (context, _) {
        final all = widget.repo.allDone().toList()..sort(compareProceduresNewestFirst);
        final savedTypes = timelineSavedProcedureTypes(all);
        final effectiveCriteria = effectiveTimelineFilterCriteria(_criteria.value, savedTypes);
        final visible = _applyFilter(all, savedTypes);
        final byDay = _groupByDay(visible);
        final bottomPad = MediaQuery.paddingOf(context).bottom;
        final filterHasNoResults = visible.isEmpty && all.isNotEmpty;
        final now = DateTime.now();

        if (all.isEmpty) {
          Future<void> add() async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ProcedureFormScreen(repo: widget.repo)),
            );
          }

          return Scaffold(
            backgroundColor: ProcedureSelectionTheme.pageBackground,
            body: Stack(
              children: [
                const Step2WarmBackground(),
                SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (Navigator.of(context).canPop())
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _TimelineCircleButton(
                              icon: Icons.chevron_left_rounded,
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                          ),
                        ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return Padding(
                              padding: EdgeInsets.fromLTRB(
                                22,
                                8,
                                22,
                                100 + bottomPad,
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.topCenter,
                                child: SizedBox(
                                  width: (constraints.maxWidth - 44)
                                      .clamp(0.0, 520),
                                  child: AppleEmptyProcedures(
                                    headerTitle: 'Timeline',
                                    onAddProcedure: add,
                                    onBrowseTypes: () =>
                                        showBrowseProcedureTypesSheet(context),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          backgroundColor: ProcedureSelectionTheme.pageBackground,
          body: Stack(
            children: [
              const Step2WarmBackground(),
              SafeArea(
                bottom: false,
                child: CustomScrollView(
              slivers: [
                if (Navigator.of(context).canPop())
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _TimelineCircleButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ProcedureSectionLabel(_weekdayDate(now)),
                              const SizedBox(height: 8),
                              Text(
                                'Timeline',
                                style: ProcedureSelectionTypography.display(
                                  size: 18,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Track your procedures, progress and GlowScore.',
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  color: ProcedureSelectionTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _TimelineCircleButton(
                          icon: Icons.tune_rounded,
                          showBadge: effectiveCriteria.isActive,
                          onTap: () => _openFilters(all),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: ProcedureSelectionPanel(
                      title: 'Overview',
                      compactTitle: true,
                      child: _SummaryRow(
                        procedureCount: all.length,
                        totalSpend: _totalSpend(all),
                        glowScore: _glowScore(all),
                        monthlyDelta: _monthlyGlowDelta(all),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: ProcedureSelectionPanel(
                      title: 'Insights',
                      compactTitle: true,
                      subtitle: 'What you do most — and where spend goes.',
                      child: _InsightsCard(procedures: all),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: ProcedureSectionLabel('History'),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 0, 0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _TimelineFilterChip(
                            text: 'All',
                            active: effectiveCriteria.procedureTitle == null,
                            onTap: () => _criteria.value = _criteria.value.copyWith(clearProcedureTitle: true),
                          ),
                          for (final title in savedTypes)
                            _TimelineFilterChip(
                              text: title,
                              active: effectiveCriteria.procedureTitle != null &&
                                  effectiveCriteria.procedureTitle!.toLowerCase() == title.toLowerCase(),
                              onTap: () => _criteria.value = _criteria.value.copyWith(procedureTitle: title),
                            ),
                          const SizedBox(width: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                if (filterHasNoResults)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 28, 20, 88 + bottomPad),
                      child: Column(
                        children: [
                          const Spacer(flex: 2),
                          const _ProcedureHistoryEmpty(),
                          const Spacer(flex: 3),
                          _SharePassportButton(onPressed: () {}),
                        ],
                      ),
                    ),
                  )
                else ...[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, groupIndex) {
                          final group = byDay[groupIndex];
                          return Column(
                            children: List.generate(group.items.length, (itemIndex) {
                              final p = group.items[itemIndex];
                              final isFirstInGroup = itemIndex == 0;
                              final isLastInGroup = itemIndex == group.items.length - 1;
                              final isLastOverall = groupIndex == byDay.length - 1 && isLastInGroup;
                              final isLatest = groupIndex == 0 && itemIndex == 0;
                              return _TimelineEntry(
                                procedure: p,
                                dateLabel: isFirstInGroup ? _dateLabel(group.day) : null,
                                isToday: _isToday(group.day),
                                highlightedIcon: isLatest,
                                showLineAbove: !isFirstInGroup || groupIndex > 0,
                                showLineBelow: !isLastOverall,
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ProcedureDetailScreen(
                                        repo: widget.repo,
                                        procedureId: p.id,
                                      ),
                                    ),
                                  );
                                },
                              );
                            }),
                          );
                        },
                        childCount: byDay.length,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 20, 20, 100 + bottomPad),
                      child: _SharePassportButton(onPressed: () {}),
                    ),
                  ),
                ],
              ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

bool _isToday(DateTime day) {
  final now = DateTime.now();
  return day.year == now.year && day.month == now.month && day.day == now.day;
}

String _dateLabel(DateTime day) {
  if (_isToday(day)) return 'Today';
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  if (day.year == yesterday.year && day.month == yesterday.month && day.day == yesterday.day) {
    return 'Yesterday';
  }
  return DateFormat('MMM d, yyyy').format(day);
}

int _glowPointsFor(Procedure p) {
  final seed = p.id.codeUnits.fold<int>(0, (a, b) => a + b);
  return 40 + (seed % 35);
}

class _TimelineCircleButton extends StatelessWidget {
  const _TimelineCircleButton({
    required this.icon,
    required this.onTap,
    this.showBadge = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ProcedureGlassSurface(
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
        ),
        if (showBadge)
          Positioned(
            top: 2,
            right: 2,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: ProcedureSelectionTheme.buttonPrimary,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

class _TimelineFilterChip extends StatelessWidget {
  const _TimelineFilterChip({required this.text, required this.active, required this.onTap});

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            selected: active,
            compact: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                text,
                style: ProcedureSelectionTypography.chip(
                  size: 11,
                  color: active ? Colors.white : ProcedureSelectionTheme.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProcedureTimelineIcon extends StatelessWidget {
  const _ProcedureTimelineIcon({
    required this.procedure,
    this.highlighted = false,
  });

  final Procedure procedure;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final icon = procedureIconFor(procedure);
    const size = 36.0;
    const scale = 0.72;

    if (icon.asset != null) {
      return Container(
        width: size,
        height: size,
        decoration: highlighted
            ? const BoxDecoration(
                color: ProcedureSelectionTheme.buttonPrimary,
                shape: BoxShape.circle,
              )
            : ProcedureGlassDecorations.iconBadge(selected: false),
        alignment: Alignment.center,
        child: ColorFiltered(
          colorFilter: ColorFilter.mode(
            highlighted ? Colors.white : ProcedureSelectionTheme.ink,
            BlendMode.srcIn,
          ),
          child: Image.asset(
            icon.asset!,
            width: size * scale,
            height: size * scale,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: highlighted
          ? const BoxDecoration(
              color: ProcedureSelectionTheme.buttonPrimary,
              shape: BoxShape.circle,
            )
          : ProcedureGlassDecorations.iconBadge(selected: false),
      alignment: Alignment.center,
      child: Text(
        icon.emoji ?? '✨',
        style: TextStyle(fontSize: 15, color: highlighted ? Colors.white : ProcedureSelectionTheme.ink),
      ),
    );
  }
}

String _zonesLabel(Procedure p) {
  if (p.zones.isNotEmpty) return p.zones.join(' & ');
  if ((p.product ?? '').trim().isNotEmpty) return p.product!.trim();
  return p.category ?? 'Treatment session';
}

class _ProcedureHistoryEmpty extends StatelessWidget {
  const _ProcedureHistoryEmpty();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          compact: true,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(Icons.assignment_outlined, size: 22, color: ProcedureSelectionTheme.muted),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'No procedures in this category',
          textAlign: TextAlign.center,
          style: ProcedureSelectionTypography.display(size: 13, color: ProcedureSelectionTheme.ink),
        ),
        const SizedBox(height: 4),
        Text(
          'Try selecting a different filter.',
          textAlign: TextAlign.center,
          style: ProcedureSelectionTypography.body(size: 11, color: ProcedureSelectionTheme.muted),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.procedureCount,
    required this.totalSpend,
    required this.glowScore,
    required this.monthlyDelta,
  });

  final int procedureCount;
  final String totalSpend;
  final int glowScore;
  final int monthlyDelta;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        children: [
          Expanded(child: _SummaryStat(icon: Icons.account_balance_wallet_outlined, label: 'Total spent', value: totalSpend, sublabel: 'All time')),
          _summaryDivider(),
          Expanded(child: _SummaryStat(icon: Icons.vaccines_outlined, label: 'Procedures', value: '$procedureCount', sublabel: 'Total')),
          _summaryDivider(),
          Expanded(child: _SummaryStat(icon: Icons.auto_awesome_outlined, label: 'GlowScore', value: '$glowScore', sublabel: 'Total')),
          _summaryDivider(),
          Expanded(child: _SummaryStat(icon: Icons.trending_up_rounded, label: 'GlowScore', value: monthlyDelta > 0 ? '+$monthlyDelta' : '—', sublabel: 'This month')),
        ],
      ),
    );
  }

  Widget _summaryDivider() {
    return Container(
      width: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.sublabel,
  });

  final IconData icon;
  final String label;
  final String value;
  final String sublabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: ProcedureSelectionTheme.fieldFill,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: ProcedureSelectionTheme.ink),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          style: ProcedureSelectionTypography.label(size: 8, color: ProcedureSelectionTheme.sectionLabel),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: ProcedureSelectionTypography.display(size: 14, color: ProcedureSelectionTheme.ink),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          sublabel,
          style: ProcedureSelectionTypography.body(size: 8, color: ProcedureSelectionTheme.muted),
        ),
      ],
    );
  }
}

class _InsightsCard extends StatelessWidget {
  const _InsightsCard({required this.procedures});

  final List<Procedure> procedures;

  static const _sliceColors = <Color>[
    Color(0xFF1A1A1F),
    Color(0xFF4A4A52),
    Color(0xFF8A8A93),
    Color(0xFFB8B4AE),
    Color(0xFFD4D0CA),
  ];

  String _labelFor(Procedure p) {
    final title = p.title.trim();
    if (title.isNotEmpty) return title;
    final cat = (p.category ?? '').trim();
    if (cat.isNotEmpty) return cat;
    return 'Other';
  }

  @override
  Widget build(BuildContext context) {
    if (procedures.isEmpty) {
      return Text(
        'Add procedures to unlock insights.',
        style: ProcedureSelectionTypography.body(size: 12, color: ProcedureSelectionTheme.muted),
      );
    }

    final counts = <String, int>{};
    final spend = <String, num>{};
    final displayName = <String, String>{};
    var currency = 'EUR';

    for (final p in procedures) {
      final raw = _labelFor(p);
      final key = raw.toLowerCase();
      // Prefer a clean title for display (first non-empty wins, then longer).
      final existing = displayName[key];
      if (existing == null || raw.length > existing.length) {
        displayName[key] = raw;
      }
      counts[key] = (counts[key] ?? 0) + 1;
      final c = p.cost;
      if (c != null && c > 0) {
        spend[key] = (spend[key] ?? 0) + c;
        currency = p.currency;
      }
    }

    final countEntries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    // Highest all-time spend by procedure type (sum of every session).
    final spendEntries = spend.entries.toList()
      ..sort((a, b) {
        final bySpend = b.value.compareTo(a.value);
        if (bySpend != 0) return bySpend;
        return a.key.compareTo(b.key);
      });

    final mostDone = countEntries.isEmpty ? null : countEntries.first;
    final mostCostly = spendEntries.isEmpty ? null : spendEntries.first;
    final mostCostlySessions = mostCostly == null ? 0 : (counts[mostCostly.key] ?? 0);

    // Build pie slices: top 4 + Other.
    final slices = <({String label, int count, Color color})>[];
    final top = countEntries.take(4).toList();
    final rest = countEntries.skip(4).fold<int>(0, (acc, e) => acc + e.value);
    for (var i = 0; i < top.length; i++) {
      slices.add((
        label: displayName[top[i].key] ?? top[i].key,
        count: top[i].value,
        color: _sliceColors[i],
      ));
    }
    if (rest > 0) {
      slices.add((label: 'Other', count: rest, color: _sliceColors.last));
    }
    final total = slices.fold<int>(0, (acc, s) => acc + s.count);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 108,
              height: 108,
              child: CustomPaint(
                painter: _DonutChartPainter(
                  slices: [
                    for (final s in slices) (value: s.count.toDouble(), color: s.color),
                  ],
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$total',
                        style: ProcedureSelectionTypography.display(
                          size: 18,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      Text(
                        'sessions',
                        style: ProcedureSelectionTypography.label(
                          size: 9,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                children: [
                  for (var i = 0; i < slices.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _InsightLegendRow(
                      color: slices[i].color,
                      label: slices[i].label,
                      value: '${slices[i].count}',
                      share: total == 0 ? 0 : slices[i].count / total,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          height: 1,
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _InsightHighlight(
                icon: Icons.repeat_rounded,
                eyebrow: 'Most done',
                title: mostDone == null ? '—' : (displayName[mostDone.key] ?? mostDone.key),
                subtitle: mostDone == null
                    ? 'No data yet'
                    : '${mostDone.value} time${mostDone.value == 1 ? '' : 's'}',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _InsightHighlight(
                icon: Icons.payments_outlined,
                eyebrow: 'Highest total spend',
                title: mostCostly == null ? '—' : (displayName[mostCostly.key] ?? mostCostly.key),
                subtitle: mostCostly == null
                    ? 'No costs logged'
                    : '${formatMoney(mostCostly.value, currency)} · $mostCostlySessions session${mostCostlySessions == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _InsightLegendRow extends StatelessWidget {
  const _InsightLegendRow({
    required this.color,
    required this.label,
    required this.value,
    required this.share,
  });

  final Color color;
  final String label;
  final String value;
  final double share;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.body(
              size: 11,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
        ),
        Text(
          '${(share * 100).round()}%',
          style: ProcedureSelectionTypography.label(
            size: 10,
            weight: FontWeight.w700,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: ProcedureSelectionTypography.label(
            size: 11,
            weight: FontWeight.w700,
            color: ProcedureSelectionTheme.ink,
          ),
        ),
      ],
    );
  }
}

class _InsightHighlight extends StatelessWidget {
  const _InsightHighlight({
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: ProcedureSelectionTheme.ink),
              const SizedBox(width: 6),
              Text(
                eyebrow.toUpperCase(),
                style: ProcedureSelectionTypography.label(
                  size: 8,
                  color: ProcedureSelectionTheme.sectionLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.display(
              size: 13,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.body(
              size: 11,
              color: ProcedureSelectionTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _DonutChartPainter extends CustomPainter {
  const _DonutChartPainter({required this.slices});

  final List<({double value, Color color})> slices;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (acc, s) => acc + s.value);
    if (total <= 0) {
      final paint = Paint()
        ..color = ProcedureSelectionTheme.ink.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14;
      canvas.drawCircle(size.center(Offset.zero), size.shortestSide / 2 - 8, paint);
      return;
    }

    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;
    var start = -1.57079632679; // top

    for (final slice in slices) {
      final sweep = (slice.value / total) * 6.28318530718;
      final paint = Paint()
        ..color = slice.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 7),
        start,
        sweep,
        false,
        paint,
      );
      start += sweep;
    }

    // Soft inner track.
    canvas.drawCircle(
      center,
      radius - 18,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) {
    if (oldDelegate.slices.length != slices.length) return true;
    for (var i = 0; i < slices.length; i++) {
      if (oldDelegate.slices[i].value != slices[i].value ||
          oldDelegate.slices[i].color != slices[i].color) {
        return true;
      }
    }
    return false;
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.procedure,
    required this.dateLabel,
    required this.isToday,
    required this.highlightedIcon,
    required this.showLineAbove,
    required this.showLineBelow,
    required this.onTap,
  });

  final Procedure procedure;
  final String? dateLabel;
  final bool isToday;
  final bool highlightedIcon;
  final bool showLineAbove;
  final bool showLineBelow;
  final VoidCallback onTap;

  static const _dotSize = 8.0;
  static const _dotColWidth = 14.0;
  static const _dateColWidth = 64.0;
  static const _railWidth = _dateColWidth + _dotColWidth;

  @override
  Widget build(BuildContext context) {
    final glowPts = _glowPointsFor(procedure);
    final clinic = (procedure.clinic ?? '').trim();
    final practitioner = (procedure.practitioner ?? '').trim();
    final doctorLine = [practitioner, clinic].where((s) => s.isNotEmpty).join(' · ');
    final price = procedure.cost != null ? formatMoney(procedure.cost!, procedure.currency) : null;
    final zonesText = _zonesLabel(procedure);
    final manyPlaces = procedure.zones.length > 2 || zonesText.length > 34;
    final dotHighlighted = highlightedIcon || isToday;
    final dotDiameter = dotHighlighted ? 10.0 : _dotSize;

    return RepaintBoundary(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _railWidth,
            child: Column(
              children: [
                if (showLineAbove)
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: _dotColWidth,
                      height: 12,
                      child: CustomPaint(painter: _DottedLinePainter()),
                    ),
                  )
                else
                  const SizedBox(height: 12),
                SizedBox(
                  height: dotDiameter,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: _dateColWidth,
                        child: dateLabel != null
                            ? Text(
                                dateLabel!,
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ProcedureSelectionTypography.body(
                                  size: 8,
                                  color: dotHighlighted ? ProcedureSelectionTheme.ink : ProcedureSelectionTheme.muted,
                                ).copyWith(height: 1),
                              )
                            : null,
                      ),
                      SizedBox(
                        width: _dotColWidth,
                        child: Center(
                          child: Container(
                            width: dotDiameter,
                            height: dotDiameter,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: dotHighlighted
                                  ? ProcedureSelectionTheme.buttonPrimary
                                  : ProcedureSelectionTheme.muted.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showLineBelow)
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: _dotColWidth,
                      height: _tlProcedureCardMinHeight + _tlProcedureCardGap,
                      child: CustomPaint(painter: _DottedLinePainter()),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: _tlProcedureCardGap),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                  onTap: onTap,
                  child: ProcedureGlassSurface(
                    borderRadius: BorderRadius.circular(16),
                    compact: true,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: _tlProcedureCardMinHeight),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Align(
                                alignment: Alignment.topCenter,
                                child: _ProcedureTimelineIcon(procedure: procedure, highlighted: highlightedIcon),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.max,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      procedure.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ProcedureSelectionTypography.display(
                                        size: 12,
                                        color: ProcedureSelectionTheme.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      zonesText,
                                      maxLines: manyPlaces ? 4 : 1,
                                      overflow: manyPlaces ? TextOverflow.visible : TextOverflow.ellipsis,
                                      style: ProcedureSelectionTypography.body(size: 10, color: ProcedureSelectionTheme.muted),
                                    ),
                                    const Spacer(),
                                    Text(
                                      [
                                        'GlowScore +$glowPts',
                                        if (doctorLine.isNotEmpty) doctorLine,
                                      ].join(' • '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: ProcedureSelectionTypography.body(
                                        size: 9,
                                        color: ProcedureSelectionTheme.sectionLabel,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  if (price != null) ...[
                                    const SizedBox(width: 4),
                                    Text(
                                      price,
                                      style: ProcedureSelectionTypography.display(
                                        size: 11,
                                        color: ProcedureSelectionTheme.ink,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(width: 2),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 15,
                                    color: ProcedureSelectionTheme.muted.withValues(alpha: 0.6),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
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

class _DottedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ProcedureSelectionTheme.muted.withValues(alpha: 0.35)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    const dashHeight = 4.0;
    const gap = 4.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, y + dashHeight), paint);
      y += dashHeight + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SharePassportButton extends StatelessWidget {
  const _SharePassportButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ProcedureSelectionTheme.buttonPrimary,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.ios_share_rounded, size: 18, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                'Share my passport',
                style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
