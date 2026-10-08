import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../data/community_post.dart';
import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/app_navigator.dart';
import '../services/glow_up_job.dart';
import 'community_glow_up_viewer_screen.dart';
import 'procedure_detail_screen.dart';
import 'procedure_form_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/apple_empty_procedures.dart';
import '../services/auth_service.dart';
import '../services/notifications_store.dart';
import 'notifications_screen.dart';
import 'reminders_screen.dart';
import 'add_reminder_screen.dart';
import 'before_after_comparison_screen.dart';
import 'glow_up_photo_source_screen.dart';
import 'glow_up_results_community_screen.dart';
import '../services/saved_glow_ups_store.dart';
import 'procedure_icon_resolver.dart';
import 'timeline_screen.dart';
import 'photo_storage.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _ink = ProcedureSelectionTheme.ink;
  static const _muted = ProcedureSelectionTheme.muted;
  static const int _journeyPreviewMax = 4;

  static String _strip(String? s) => (s ?? '').trim();

  /// Prefer Firestore `firstName` + `lastName`; otherwise email local part; else "there".
  String _displayNameFromProfile(Map<String, dynamic>? profile, User? user) {
    final first = _strip(profile?['firstName'] as String?);
    final last = _strip(profile?['lastName'] as String?);
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    final email = (user?.email ?? '').trim();
    if (email.isEmpty) return 'there';
    final at = email.indexOf('@');
    if (at <= 0) return email;
    return email.substring(0, at);
  }

  Widget _homeScrollView(
    BuildContext context, {
    required Map<String, dynamic>? profile,
  }) {
    final user = FirebaseAuth.instance.currentUser;
    final procedures = widget.repo.allDone().toList();
    final journey = _journeyNodes(procedures, max: _journeyPreviewMax);
    final next = _nextFollowUp(procedures);
    final displayName = _displayNameFromProfile(profile, user);
    final progressPairs = procedures
        .where(
          (p) =>
              _homePhotoExists(p.beforePhotoPath) &&
              _homePhotoExists(p.afterPhotoPath),
        )
        .toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        if (byDate != 0) return byDate;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    final latestProgress = progressPairs.isEmpty ? null : progressPairs.first;

    return Scaffold(
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
                    Expanded(
                      child: _HomeHeader(name: displayName, partOfDay: _partOfDay()),
                    ),
                    const SizedBox(width: 12),
                    _NotificationButton(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NotificationsScreen(repo: widget.repo),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 10),
                    _RemindersHeaderButton(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => RemindersScreen(repo: widget.repo),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _GlowScoreCard(procedureCount: procedures.length),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ProgressPhotosCard(
                          procedure: latestProgress,
                          onOpen: () {
                            final id = latestProgress?.id;
                            if (id != null && id.isNotEmpty) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProcedureDetailScreen(
                                    repo: widget.repo,
                                    procedureId: id,
                                  ),
                                ),
                              );
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => BeforeAfterComparisonScreen(repo: widget.repo),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: _TreatmentJourneyCard(
                  nodes: journey,
                  onViewAll: _openTimeline,
                  onEmptyAdd: _openAdd,
                  onTapNode: (id) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProcedureDetailScreen(repo: widget.repo, procedureId: id),
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: _SectionHeader(
                  title: 'Glow Up results community',
                  actionLabel: 'See all',
                  onAction: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            GlowUpResultsCommunityScreen(repo: widget.repo),
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _CommunityResultsRow(
                  repo: widget.repo,
                  onSeeAll: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            GlowUpResultsCommunityScreen(repo: widget.repo),
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: _FollowUpAppointmentCard(
                  next: next,
                  onViewCalendar: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => RemindersScreen(repo: widget.repo),
                      ),
                    );
                  },
                  onAddDate: _openAddReminder,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 14),
                child: Text('AI FEATURES', style: _sectionTitleStyle),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                child: _AiCard(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => BeforeAfterComparisonScreen(repo: widget.repo),
                      ),
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                child: _GlowUpCard(
                  onTap: () async {
                    final job = GlowUpJobController.instance;
                    final nav = Navigator.of(context);
                    nav.popUntil(
                      (route) => route.settings.name != glowUpFlowRoute,
                    );
                    if (job.hasActiveFlow) {
                      job.pushFlow(context);
                    } else {
                      await job.reset();
                      nav.push(
                        MaterialPageRoute<void>(
                          settings: const RouteSettings(name: glowUpFlowRoute),
                          builder: (_) => const GlowUpPhotoSourceScreen(),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  String _partOfDay() {
    final h = DateTime.now().hour;
    if (h < 12) return 'morning';
    if (h < 18) return 'afternoon';
    return 'evening';
  }

  ({Procedure procedure, int daysLeft})? _nextFollowUp(List<Procedure> procedures) {
    final now = DateTime.now();
    final upcoming = procedures
        .where((p) => p.followUpDate != null)
        .map((p) => (procedure: p, date: p.followUpDate!))
        .where((x) => !x.date.isBefore(DateTime(now.year, now.month, now.day)))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    if (upcoming.isEmpty) return null;
    final first = upcoming.first;
    final daysLeft = first.date.difference(DateTime(now.year, now.month, now.day)).inDays;
    return (procedure: first.procedure, daysLeft: daysLeft);
  }

  List<_JourneyNode> _journeyNodes(List<Procedure> procedures, {int max = 4}) {
    final completed = [...procedures]..sort(compareProceduresNewestFirst);
    final nodes = <_JourneyNode>[];

    for (final p in completed.take(max - 1)) {
      nodes.add(_JourneyNode(
        id: p.id,
        date: p.date,
        title: p.title,
        completed: true,
      ));
    }

    // Oldest → newest for left-to-right journey reading.
    nodes.sort((a, b) => a.date.compareTo(b.date));

    final next = _nextFollowUp(procedures);
    if (next != null && nodes.length < max) {
      nodes.add(_JourneyNode(
        id: next.procedure.id,
        date: next.procedure.followUpDate!,
        title: next.procedure.title,
        completed: false,
      ));
    } else if (nodes.isNotEmpty && nodes.length < max) {
      // Placeholder upcoming slot when no follow-up is scheduled.
      final last = nodes.last;
      nodes.add(_JourneyNode(
        id: last.id,
        date: last.date.add(const Duration(days: 28)),
        title: 'Next session',
        completed: false,
        isPlaceholder: true,
      ));
    }

    return nodes.take(max).toList();
  }

  Future<void> _openAdd() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProcedureFormScreen(repo: widget.repo)),
    );
  }

  Future<void> _openAddReminder() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AddReminderScreen(repo: widget.repo)),
    );
  }

  Future<void> _openTimeline() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TimelineScreen(repo: widget.repo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return ListenableBuilder(
      listenable: widget.repo,
      builder: (context, child) {
        if (user == null) {
          return _homeScrollView(context, profile: null);
        }
        return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: AuthService().userProfileStream(user.uid),
          builder: (context, snap) {
            Map<String, dynamic>? profile;
            if (snap.hasData && snap.data!.exists) profile = snap.data!.data();
            return _homeScrollView(context, profile: profile);
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared models / helpers
// ---------------------------------------------------------------------------

class _JourneyNode {
  const _JourneyNode({
    required this.id,
    required this.date,
    required this.title,
    required this.completed,
    this.isPlaceholder = false,
  });

  final String id;
  final DateTime date;
  final String title;
  final bool completed;
  final bool isPlaceholder;
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Padding(padding: padding, child: child),
    );
  }
}

TextStyle _capsLabel({double size = 10, Color? color}) => GoogleFonts.plusJakartaSans(
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.6,
      height: 1.1,
      color: color ?? ProcedureSelectionTheme.sectionLabel,
    );

String _shortDate(DateTime d) {
  const mo = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
  return '${d.day} ${mo[d.month - 1]}';
}

String _weekdayDateCaps(DateTime d) {
  const wd = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
  const mo = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
  return '${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]}';
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({required this.name, required this.partOfDay});

  final String name;
  final String partOfDay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ProcedureSectionLabel(_weekdayDateCaps(DateTime.now())),
        const SizedBox(height: 8),
        Text(
          'Good $partOfDay,',
          style: ProcedureSelectionTypography.body(
            size: 15,
            color: ProcedureSelectionTheme.muted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                name,
                style: GoogleFonts.dmSerifDisplay(
                  fontSize: 26,
                  fontWeight: FontWeight.w400,
                  height: 1.1,
                  color: ProcedureSelectionTheme.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '✦',
              style: TextStyle(
                fontSize: 13,
                color: ProcedureSelectionTheme.ink.withValues(alpha: 0.85),
                height: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Track your progress. Enhance your best.',
          style: ProcedureSelectionTypography.body(
            size: 11,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
      ],
    );
  }
}

class _NotificationButton extends StatelessWidget {
  const _NotificationButton({required this.onTap});

  final VoidCallback onTap;

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
                width: 40,
                height: 40,
                child: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                  stream: NotificationsStore.streamDocsForCurrentUser(),
                  builder: (context, snap) {
                    final docs = snap.data ?? const [];
                    final unread = docs.where((d) => d.data()['isRead'] != true).length;
                    return Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Icon(Icons.notifications_none_rounded, size: 20, color: ProcedureSelectionTheme.ink),
                        if (unread > 0)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
                              padding: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: const BoxDecoration(
                                color: ProcedureSelectionTheme.buttonPrimary,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                unread > 9 ? '9+' : '$unread',
                                style: ProcedureSelectionTypography.chip(size: 8, color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RemindersHeaderButton extends StatelessWidget {
  const _RemindersHeaderButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Reminders',
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(999),
        compact: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: const SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                Icons.calendar_month_rounded,
                size: 20,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    this.leadingAction,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;
  final Widget? leadingAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title.toUpperCase(), style: _sectionTitleStyle)),
        if (leadingAction != null) ...[
          leadingAction!,
          const SizedBox(width: 4),
        ],
        InkWell(
          onTap: onAction,
          borderRadius: BorderRadius.circular(8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                actionLabel,
                style: ProcedureSelectionTypography.label(
                  size: 11,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(Icons.arrow_forward_rounded, size: 13, color: ProcedureSelectionTheme.ink),
            ],
          ),
        ),
      ],
    );
  }
}

TextStyle get _sectionTitleStyle => GoogleFonts.plusJakartaSans(
      fontSize: 8,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.8,
      height: 1.0,
      color: ProcedureSelectionTheme.sectionLabel,
    );

// ---------------------------------------------------------------------------
// Glow Score
// ---------------------------------------------------------------------------

class _GlowScoreCard extends StatelessWidget {
  const _GlowScoreCard({required this.procedureCount});

  final int procedureCount;

  int get _glowScore {
    if (procedureCount <= 0) return 0;
    return math.min(100, procedureCount * 8);
  }

  String get _levelLabel {
    if (procedureCount <= 0) return 'New';
    if (procedureCount < 5) return 'Building';
    if (procedureCount < 12) return 'Growing';
    return 'Radiant';
  }

  int get _trendPct {
    if (procedureCount <= 0) return 0;
    return math.min(24, 4 + procedureCount * 2);
  }

  @override
  Widget build(BuildContext context) {
    final score = _glowScore;
    final trend = _trendPct;
    return _HomeCard(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('GLOW SCORE', style: _capsLabel(size: 9)),
              const SizedBox(width: 4),
              Icon(Icons.info_outline_rounded, size: 12, color: _HomeScreenState._muted.withValues(alpha: 0.75)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$score',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  letterSpacing: -1.2,
                  color: _HomeScreenState._ink,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 4),
                child: Text(
                  '/100',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _HomeScreenState._muted,
                    height: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (trend > 0)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '↑ $trend% ',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _HomeScreenState._ink,
                      height: 1.2,
                    ),
                  ),
                  TextSpan(
                    text: 'this month',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: _HomeScreenState._muted,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            )
          else
            Text(
              'Start tracking to unlock',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: _HomeScreenState._muted,
                height: 1.2,
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            width: double.infinity,
            child: _GlowScoreChart(score: score),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, thickness: 1, color: Color(0x14FFFFFF)),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: ProcedureGlassDecorations.iconBadge(selected: false),
                alignment: Alignment.center,
                child: const Text('✦', style: TextStyle(fontSize: 10, height: 1)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      procedureCount == 0
                          ? 'No sessions yet'
                          : '$procedureCount session${procedureCount == 1 ? '' : 's'} completed',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _HomeScreenState._ink,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Level — $_levelLabel',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: _HomeScreenState._muted,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(Icons.bar_chart_rounded, size: 12, color: _HomeScreenState._ink.withValues(alpha: 0.7)),
                      ],
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

/// Rising area chart from 0 → [score] / 100, with soft organic waves.
class _GlowScoreChart extends StatelessWidget {
  const _GlowScoreChart({required this.score});

  /// Current Glow Score (0–100). Chart ends at this value.
  final int score;

  List<FlSpot> _spotsForScore(double end) {
    const n = 12;
    if (end <= 0) {
      return [for (var i = 0; i < n; i++) FlSpot(i.toDouble(), 2)];
    }

    // Hand-tuned relative heights (0–1) — wavy climb that finishes at 1.0.
    const relative = <double>[
      0.00, // start
      0.14,
      0.08, // soft dip
      0.28,
      0.22, // soft dip
      0.42,
      0.36, // soft dip
      0.58,
      0.52, // soft dip
      0.74,
      0.68, // soft dip
      1.00, // ends at score
    ];

    return [
      for (var i = 0; i < relative.length; i++)
        FlSpot(i.toDouble(), end * relative[i]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final end = score.clamp(0, 100).toDouble();
    final spots = _spotsForScore(end);
    final ink = ProcedureSelectionTheme.ink;
    final lastX = (spots.length - 1).toDouble();

    return LineChart(
      LineChartData(
        minX: -0.15,
        maxX: lastX + 0.15,
        minY: 0,
        maxY: 100,
        clipData: const FlClipData.all(),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: const FlTitlesData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: 2,
              color: ink.withValues(alpha: 0.10),
              strokeWidth: 1,
            ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.42,
            preventCurveOverShooting: true,
            color: ink.withValues(alpha: 0.90),
            barWidth: 1.8,
            isStrokeCapRound: true,
            isStrokeJoinRound: true,
            shadow: Shadow(
              color: ink.withValues(alpha: 0.10),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) {
                final t = index / (spots.length - 1);
                final alpha = t < 0.25
                    ? 0.25
                    : (t < 0.5 ? 0.42 : (t < 0.75 ? 0.7 : 1.0));
                final r = t > 0.85 ? 3.2 : 2.3;
                return FlDotCirclePainter(
                  radius: r,
                  color: ink.withValues(alpha: alpha),
                  strokeWidth: 0,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  ink.withValues(alpha: 0.18),
                  ink.withValues(alpha: 0.06),
                  ink.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ],
      ),
      duration: Duration.zero,
    );
  }
}

// ---------------------------------------------------------------------------
// Progress Photos — latest procedure with before + after
// ---------------------------------------------------------------------------

bool _homePhotoExists(String? path) {
  final p = (path ?? '').trim();
  if (p.isEmpty) return false;
  return isRemoteUrl(p) || File(p).existsSync();
}

class _ProgressPhotosCard extends StatelessWidget {
  const _ProgressPhotosCard({
    required this.onOpen,
    this.procedure,
  });

  final VoidCallback onOpen;
  final Procedure? procedure;

  static const _grey = Color(0xFFC4C4C8);
  static const _black = Color(0xFF0E0E10);

  static const double _centerW = 86;
  static const double _centerH = 122;
  static const double _sideW = 66;
  static const double _sideH = 104;
  static const double _stackH = 132;
  static const double _peek = 28;

  @override
  Widget build(BuildContext context) {
    final beforePath = procedure?.beforePhotoPath;
    final afterPath = procedure?.afterPhotoPath;
    final hasPair = procedure != null &&
        _homePhotoExists(beforePath) &&
        _homePhotoExists(afterPath);
    final title = (procedure?.title ?? '').trim();
    final countLabel = hasPair ? 'Latest procedure' : 'No progress photos yet';
    final subtitle = hasPair && title.isNotEmpty
        ? title
        : 'Track real changes over time';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        child: _HomeCard(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text('PROGRESS PHOTOS', style: _capsLabel(size: 8))),
                  Icon(Icons.more_horiz_rounded, size: 16, color: _HomeScreenState._muted),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: _stackH,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: _centerW + _peek * 2 - _sideW,
                      top: (_stackH - _sideH) / 2 + 6,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _photoSlot(
                          color: _grey,
                          label: 'BEFORE',
                          width: _sideW,
                          height: _sideH,
                          photoPath: hasPair ? beforePath : null,
                        ),
                      ),
                    ),
                    Positioned(
                      left: _centerW + _peek * 2 - _sideW,
                      right: 0,
                      top: (_stackH - _sideH) / 2 + 6,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _photoSlot(
                          color: _grey,
                          label: 'AFTER',
                          width: _sideW,
                          height: _sideH,
                          photoPath: hasPair ? afterPath : null,
                        ),
                      ),
                    ),
                    _photoSlot(
                      color: _black,
                      label: 'AFTER',
                      width: _centerW,
                      height: _centerH,
                      elevated: true,
                      photoPath: hasPair ? afterPath : null,
                    ),
                    // Side chevrons — centered on the front card
                    Align(
                      alignment: const Alignment(-0.72, 0),
                      child: _circleNav(
                        icon: Icons.chevron_left_rounded,
                        onTap: onOpen,
                      ),
                    ),
                    Align(
                      alignment: const Alignment(0.72, 0),
                      child: _circleNav(
                        icon: Icons.chevron_right_rounded,
                        onTap: onOpen,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          countLabel,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: _HomeScreenState._ink,
                            height: 1.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 9,
                            fontWeight: FontWeight.w500,
                            color: _HomeScreenState._muted,
                            height: 1.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  _circleNav(
                    icon: Icons.arrow_forward_rounded,
                    onTap: onOpen,
                    size: 24,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoSlot({
    required Color color,
    required String label,
    required double width,
    required double height,
    bool elevated = false,
    String? photoPath,
  }) {
    final path = (photoPath ?? '').trim();
    final canShow = _homePhotoExists(path);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
        boxShadow: elevated
            ? const [
                BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 8)),
                BoxShadow(color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2)),
              ]
            : const [
                BoxShadow(color: Color(0x18000000), blurRadius: 10, offset: Offset(0, 4)),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (canShow)
            Image(
              image: isRemoteUrl(path) ? NetworkImage(path) : FileImage(File(path)),
              fit: BoxFit.cover,
              errorBuilder: (_, error, stackTrace) => const SizedBox.shrink(),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 7,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    color: _HomeScreenState._ink,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleNav({
    required IconData icon,
    required VoidCallback onTap,
    double size = 28,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          compact: true,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: size * 0.48, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Treatment Journey
// ---------------------------------------------------------------------------

class _TreatmentJourneyCard extends StatelessWidget {
  const _TreatmentJourneyCard({
    required this.nodes,
    required this.onViewAll,
    required this.onEmptyAdd,
    required this.onTapNode,
  });

  final List<_JourneyNode> nodes;
  final VoidCallback onViewAll;
  final VoidCallback onEmptyAdd;
  final ValueChanged<String> onTapNode;

  @override
  Widget build(BuildContext context) {
    return _HomeCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(
            title: 'Your treatment journey',
            actionLabel: 'View all',
            onAction: onViewAll,
          ),
          const SizedBox(height: 20),
          if (nodes.isEmpty)
            AppleEmptyProcedures(
              compact: true,
              headerTitle: 'Journey',
              onAddProcedure: onEmptyAdd,
              onBrowseTypes: () => showBrowseProcedureTypesSheet(context),
            )
          else
            _JourneyTimeline(nodes: nodes, onTapNode: onTapNode),
        ],
      ),
    );
  }
}

class _JourneyTimeline extends StatelessWidget {
  const _JourneyTimeline({required this.nodes, required this.onTapNode});

  final List<_JourneyNode> nodes;
  final ValueChanged<String> onTapNode;

  static const double _dotSize = 18;

  @override
  Widget build(BuildContext context) {
    final n = nodes.length;
    if (n == 0) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: _dotSize + 4,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _JourneyLinePainter(
                        completedCount: nodes.where((e) => e.completed).length,
                        total: n,
                        inset: constraints.maxWidth / (n * 2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(
                          child: Center(
                            child: _JourneyDot(
                              completed: nodes[i].completed,
                              size: _dotSize,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < n; i++)
              Expanded(
                child: InkWell(
                  onTap: nodes[i].isPlaceholder ? null : () => onTapNode(nodes[i].id),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      children: [
                        Text(
                          _shortDate(nodes[i].date),
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 8,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: ProcedureSelectionTheme.muted,
                            height: 1.1,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          nodes[i].title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: ProcedureSelectionTheme.ink,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: ProcedureSelectionTheme.fieldFill,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            nodes[i].completed ? 'Completed' : 'Upcoming',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 8,
                              fontWeight: FontWeight.w500,
                              color: ProcedureSelectionTheme.muted,
                              height: 1.1,
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
      ],
    );
  }
}

class _JourneyDot extends StatelessWidget {
  const _JourneyDot({required this.completed, this.size = 18});

  final bool completed;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (completed) {
      return Container(
        width: size + 6,
        height: size + 6,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.55),
          shape: BoxShape.circle,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            color: ProcedureSelectionTheme.buttonPrimary,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_rounded, size: size * 0.58, color: Colors.white),
        ),
      );
    }
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DashedCirclePainter(
              color: ProcedureSelectionTheme.muted.withValues(alpha: 0.55),
            ),
          ),
        ),
      ),
    );
  }
}

class _JourneyLinePainter extends CustomPainter {
  const _JourneyLinePainter({
    required this.completedCount,
    required this.total,
    required this.inset,
  });

  final int completedCount;
  final int total;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    if (total < 2) return;
    final y = size.height / 2;
    final startX = inset;
    final endX = size.width - inset;
    final span = endX - startX;

    // Track behind: light grey full length
    final base = Paint()
      ..color = const Color(0xFFE2E2E6)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(startX, y), Offset(endX, y), base);

    // Solid completed segment
    if (completedCount > 1) {
      final t = ((completedCount - 1) / (total - 1)).clamp(0.0, 1.0);
      final active = Paint()
        ..color = ProcedureSelectionTheme.buttonPrimary
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(startX, y), Offset(startX + span * t, y), active);
    }
  }

  @override
  bool shouldRepaint(covariant _JourneyLinePainter oldDelegate) =>
      oldDelegate.completedCount != completedCount ||
      oldDelegate.total != total ||
      oldDelegate.inset != inset;
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final r = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);
    const dash = 3.0;
    const gap = 2.5;
    final path = Path()..addOval(r);
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = math.min(dist + dash, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) => oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// GlowUp Results Community (live posts)
// ---------------------------------------------------------------------------

class _CommunityResultsRow extends StatelessWidget {
  const _CommunityResultsRow({
    required this.repo,
    required this.onSeeAll,
  });

  final ProcedureRepository repo;
  final VoidCallback onSeeAll;

  static String _durationLabel(DateTime when) {
    final days = DateTime.now().difference(when).inDays;
    if (days <= 0) return 'Today';
    if (days < 7) return days == 1 ? '1 day' : '$days days';
    final weeks = (days / 7).floor();
    if (weeks < 5) return weeks == 1 ? '1 week' : '$weeks weeks';
    final months = (days / 30).floor().clamp(1, 24);
    return months == 1 ? '1 month' : '$months months';
  }

  void _openPost(BuildContext context, CommunityPost post) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final procedureId = post.procedureId.trim();
    final isOwnUpload = uid != null &&
        uid == post.ownerUid &&
        procedureId.isNotEmpty &&
        repo.getDoneById(procedureId) != null;

    if (isOwnUpload) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProcedureDetailScreen(
            repo: repo,
            procedureId: procedureId,
          ),
        ),
      );
      return;
    }

    final uidMe = FirebaseAuth.instance.currentUser?.uid;
    final isMine = uidMe != null && uidMe == post.ownerUid;
    final name = (post.ownerDisplayName ?? '').trim();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityGlowUpViewerScreen(
          post: CommunityGlowUpView(
            procedure: post.title,
            area: post.zoneLabel,
            duration: _durationLabel(post.postedAt),
            daysAgo: DateTime.now().difference(post.postedAt).inDays.clamp(0, 9999),
            userName: isMine ? 'You' : (name.isEmpty ? 'Member' : name),
            iconAsset: presetIconByName[post.title] ?? 'assets/staricon.png',
            clinic: post.clinic,
            doctor: post.practitioner,
            product: post.product,
            volumeMl: post.volumeMl,
            beforePhotoUrl: post.beforePhotoUrl,
            afterPhotoUrl: post.afterPhotoUrl,
            procedureDate: post.date,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final cardW = (screenW - 40 - 12) / 2;
    final cardH = cardW * 0.92;

    return SizedBox(
      height: cardH,
      child: StreamBuilder<List<CommunityPost>>(
        stream: repo.communityPostsStream(limit: 12),
        builder: (context, snap) {
          final posts = snap.data ?? const <CommunityPost>[];

          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: 2,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, __) => ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                compact: true,
                child: SizedBox(width: cardW, height: cardH),
              ),
            );
          }

          if (posts.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                compact: true,
                child: InkWell(
                  onTap: onSeeAll,
                  borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.visibility_outlined,
                          size: 18,
                          color: ProcedureSelectionTheme.muted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'No live results yet. Turn on Post live when you save a procedure.',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: ProcedureSelectionTheme.muted,
                              height: 1.3,
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

          return ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: posts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final post = posts[i];
              return _CommunityResultCard(
                width: cardW,
                title: post.title,
                durationLabel: _durationLabel(post.postedAt),
                beforeUrl: post.beforePhotoUrl,
                afterUrl: post.afterPhotoUrl,
                onTap: () => _openPost(context, post),
              );
            },
          );
        },
      ),
    );
  }
}

class _CommunityResultCard extends StatelessWidget {
  const _CommunityResultCard({
    required this.width,
    required this.title,
    required this.durationLabel,
    required this.onTap,
    this.beforeUrl,
    this.afterUrl,
  });

  final double width;
  final String title;
  final String durationLabel;
  final VoidCallback onTap;
  final String? beforeUrl;
  final String? afterUrl;

  static final _cardRadius = BorderRadius.circular(ProcedureSelectionTheme.cardRadius);

  bool _isHttp(String? u) {
    final v = (u ?? '').trim();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  Widget _half({required String? url, required bool before}) {
    final has = _isHttp(url);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (has)
          Image.network(
            url!.trim(),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => ColoredBox(
              color: before
                  ? const Color(0xFF8A8A93).withValues(alpha: 0.22)
                  : const Color(0xFF1A1A1F).withValues(alpha: 0.28),
            ),
          )
        else
          ColoredBox(
            color: before
                ? const Color(0xFF8A8A93).withValues(alpha: 0.22)
                : const Color(0xFF1A1A1F).withValues(alpha: 0.28),
          ),
        Positioned(
          top: 10,
          left: 0,
          right: 0,
          child: Align(
            alignment: Alignment.topCenter,
            child: _baLabel(before ? 'BEFORE' : 'AFTER'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: _cardRadius,
        child: ProcedureGlassSurface(
          borderRadius: _cardRadius,
          compact: true,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(ProcedureSelectionTheme.cardRadius),
                      topRight: Radius.circular(ProcedureSelectionTheme.cardRadius),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _half(url: beforeUrl, before: true)),
                            Expanded(child: _half(url: afterUrl, before: false)),
                          ],
                        ),
                        Center(
                          child: Container(
                            width: 1,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                        Center(
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.88),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.10),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chevron_left_rounded,
                                  size: 10,
                                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 10,
                                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Builder(
                                  builder: (context) {
                                    final iconAsset = presetIconByName[title] ??
                                        'assets/staricon.png';
                                    return Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.78),
                                        shape: BoxShape.circle,
                                      ),
                                      alignment: Alignment.center,
                                      child: ColorFiltered(
                                        colorFilter: const ColorFilter.mode(
                                          ProcedureSelectionTheme.ink,
                                          BlendMode.srcIn,
                                        ),
                                        child: Image.asset(
                                          iconAsset,
                                          width: 11,
                                          height: 11,
                                          fit: BoxFit.contain,
                                          filterQuality: FilterQuality.high,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: ProcedureSelectionTheme.ink,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  width: 18,
                                  height: 18,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.78),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    Icons.calendar_today_outlined,
                                    size: 10,
                                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.85),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    durationLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.plusJakartaSans(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: ProcedureSelectionTheme.ink,
                                      height: 1.1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedBuilder(
                        animation: SavedGlowUpsStore.instance,
                        builder: (context, _) {
                          final iconAsset =
                              presetIconByName[title] ?? 'assets/staricon.png';
                          final entry = SavedGlowUpEntry(
                            procedure: title,
                            duration: durationLabel,
                            iconAsset: iconAsset,
                          );
                          final saved = SavedGlowUpsStore.instance.contains(entry);
                          return GestureDetector(
                            onTap: () => SavedGlowUpsStore.instance.toggle(entry),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.85),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.08),
                                    blurRadius: 5,
                                    offset: const Offset(0, 1),
                                  ),
                                ],
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                saved
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                size: 14,
                                color: saved
                                    ? const Color(0xFFE2556B)
                                    : ProcedureSelectionTheme.ink.withValues(alpha: 0.85),
                              ),
                            ),
                          );
                        },
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

  Widget _baLabel(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 7,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
          height: 1,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Follow-up appointment
// ---------------------------------------------------------------------------

class _FollowUpAppointmentCard extends StatelessWidget {
  const _FollowUpAppointmentCard({
    required this.next,
    required this.onViewCalendar,
    required this.onAddDate,
  });

  final ({Procedure procedure, int daysLeft})? next;
  final VoidCallback onViewCalendar;
  final VoidCallback onAddDate;

  @override
  Widget build(BuildContext context) {
    final hasNext = next != null;
    final p = next?.procedure;
    final date = p?.followUpDate;
    final daysLeft = next?.daysLeft;

    return _HomeCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_today_outlined, size: 12, color: _HomeScreenState._muted),
              const SizedBox(width: 5),
              Text('FOLLOW-UP APPOINTMENT', style: _capsLabel(size: 9)),
              if (hasNext && daysLeft != null) ...[
                const Spacer(),
                Text(
                  daysLeft == 0
                      ? 'Today'
                      : daysLeft == 1
                          ? 'In 1 day'
                          : 'In $daysLeft days',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.buttonPrimary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            hasNext ? p!.title : 'Add follow-up',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _HomeScreenState._ink,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          if (hasNext && date != null) ...[
            _metaRow(Icons.schedule_rounded, '${_shortDate(date)} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}'),
            const SizedBox(height: 4),
            _metaRow(
              Icons.location_on_outlined,
              ((p!.clinic ?? '').trim().isEmpty) ? 'Your clinic' : p.clinic!.trim(),
            ),
          ] else
            Text(
              'Schedule your next session and stay consistent.',
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _HomeScreenState._muted,
                height: 1.35,
              ),
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 38,
            child: TextButton(
              onPressed: hasNext ? onViewCalendar : onAddDate,
              style: TextButton.styleFrom(
                backgroundColor: ProcedureSelectionTheme.fieldFill,
                foregroundColor: ProcedureSelectionTheme.ink,
                elevation: 0,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                hasNext ? 'View calendar →' : 'Add date →',
                style: ProcedureSelectionTypography.label(size: 12, weight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 13, color: _HomeScreenState._muted),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: _HomeScreenState._muted,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// AI Features (kept at bottom)
// ---------------------------------------------------------------------------

class _AiCard extends StatelessWidget {
  const _AiCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          selected: true,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Row(
                  children: [
                    const _AiPhoto(),
                    Transform.translate(
                      offset: const Offset(-8, 0),
                      child: _AiPhoto(
                        borderColor: Colors.white.withValues(alpha: 0.18),
                        fill: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI ANALYSIS',
                          style: ProcedureSelectionTypography.label(
                            size: 9,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Before & after comparison',
                          style: ProcedureSelectionTypography.display(size: 15, color: Colors.white),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Upload photos · see your progress',
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                  ),
                  child: const Icon(Icons.arrow_forward, size: 16, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AiPhoto extends StatelessWidget {
  const _AiPhoto({
    this.borderColor = const Color(0xFF353555),
    this.fill = const Color(0xFF2A2A42),
  });

  final Color borderColor;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 58,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
    );
  }
}

class _GlowUpCard extends StatelessWidget {
  const _GlowUpCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          compact: true,
          illuminated: true,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 58,
                      decoration: BoxDecoration(
                        color: ProcedureSelectionTheme.fieldFill,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: ProcedureSelectionTheme.cardBorder),
                      ),
                      child: Icon(Icons.person_outline, color: ProcedureSelectionTheme.ink.withValues(alpha: 0.7)),
                    ),
                    Transform.translate(
                      offset: const Offset(-10, 0),
                      child: Container(
                        width: 48,
                        height: 58,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              ProcedureSelectionTheme.buttonPrimary,
                              ProcedureSelectionTheme.ink,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                        ),
                        child: const Stack(
                          children: [
                            Center(child: Icon(Icons.person_outline, color: Colors.white)),
                            Positioned(
                              top: 6,
                              right: 6,
                              child: Icon(Icons.star, size: 12, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: ProcedureSelectionTheme.buttonPrimary,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, size: 10, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              'AI GLOW UP',
                              style: ProcedureSelectionTypography.chip(size: 9, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'See your potential look',
                        style: ProcedureSelectionTypography.display(size: 15, color: ProcedureSelectionTheme.ink),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'AI previews your face with our recommended procedures applied',
                        style: ProcedureSelectionTypography.body(size: 11, color: ProcedureSelectionTheme.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: ProcedureSelectionTheme.buttonPrimary,
                  ),
                  child: const Icon(Icons.arrow_forward, size: 16, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
