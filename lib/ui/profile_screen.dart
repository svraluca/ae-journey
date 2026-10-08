import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import 'explore_procedure_interests_screen.dart';
import 'formatters.dart';
import 'manage_subscription_screen.dart';
import 'notifications_screen.dart';
import 'photo_storage.dart';
import 'procedure_detail_screen.dart';
import 'procedure_form_screen.dart';
import 'procedure_icon_resolver.dart';
import 'procedure_selection_theme.dart';
import 'restore_subscription_screen.dart';
import 'soft_auth_swap_route.dart';
import 'subscription_screen.dart';
import 'timeline_screen.dart';
import 'welcome_screen2.dart';
import 'widgets/black_profile_photo_sheet.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';
import '../data/procedure.dart';
import '../data/procedure_repository.dart';
import '../services/auth_service.dart';
import '../services/explore_procedure_interests.dart';
import '../services/session_prefs.dart';

const Color _profileDivider = Color(0x241A1A1F);

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  static String _strip(String? s) => (s ?? '').trim();

  static String _displayNameFromEmail(User? user) {
    final email = (user?.email ?? '').trim();
    if (email.isEmpty) return 'Account';
    final at = email.indexOf('@');
    if (at <= 0) return email;
    return email.substring(0, at);
  }

  static String _initialsFallback(User user) {
    final email = (user.email ?? '').trim();
    if (email.isEmpty) return 'A';
    return email[0].toUpperCase();
  }

  static String _fullName(Map<String, dynamic>? data, User user) {
    final first = _strip(data?['firstName'] as String?);
    final last = _strip(data?['lastName'] as String?);
    final combined = '$first $last'.trim();
    if (combined.isNotEmpty) return combined;
    return _displayNameFromEmail(user);
  }

  static String _initials(Map<String, dynamic>? data, User user) {
    final first = _strip(data?['firstName'] as String?);
    final last = _strip(data?['lastName'] as String?);
    if (first.isNotEmpty && last.isNotEmpty) return '${first[0]}${last[0]}'.toUpperCase();
    if (first.isNotEmpty) return first.substring(0, math.min(2, first.length)).toUpperCase();
    if (last.isNotEmpty) return last[0].toUpperCase();
    return _initialsFallback(user);
  }

  static String _formatDayMonthYear(dynamic raw) {
    if (raw is Timestamp) {
      final d = raw.toDate();
      const mos = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${d.day} ${mos[d.month - 1]} ${d.year}';
    }
    return '';
  }

  static bool _isPaidPlan(Map<String, dynamic>? data) {
    final plan = _strip(data?['subscriptionPlan'] as String?).toLowerCase();
    return plan == 'monthly' || plan == 'yearly' || plan == 'lifetime';
  }

  static String _planBadgeLabel(Map<String, dynamic>? data) {
    final title = _strip(data?['subscriptionPlanTitle'] as String?);
    if (title.isNotEmpty) return title;
    final plan = _strip(data?['subscriptionPlan'] as String?).toLowerCase();
    return switch (plan) {
      'monthly' => 'Monthly Pro',
      'yearly' => 'Yearly Pro',
      'lifetime' => 'Lifetime Pro',
      _ => 'Free plan',
    };
  }

  static String _planShortLabel(Map<String, dynamic>? data) {
    if (!_isPaidPlan(data)) return 'Free';
    final plan = _strip(data?['subscriptionPlan'] as String?).toLowerCase();
    return switch (plan) {
      'monthly' => 'Monthly',
      'yearly' => 'Yearly',
      'lifetime' => 'Lifetime',
      _ => 'Pro',
    };
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Stack(
        children: [
          const Step2WarmBackground(),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Text(
                  'Sign in to view your profile.',
                  style: ProcedureSelectionTypography.body(size: 14, color: ProcedureSelectionTheme.ink),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: AuthService().userProfileStream(user.uid),
            builder: (context, snap) {
              final doc = snap.data;
              Map<String, dynamic>? data;
              if (doc != null && doc.exists) {
                data = doc.data();
              }
              final titleName = _fullName(data, user);
              final initials = _initials(data, user);
              final photoUrl = _strip(data?['photoUrl'] as String?).isNotEmpty
                  ? _strip(data?['photoUrl'] as String?)
                  : _strip(user.photoURL);
              final dobText = _formatDayMonthYear(data?['dob']);
              final dobRow = dobText.isEmpty ? '—' : dobText;
              final joinedText = _formatDayMonthYear(data?['createdAt']);
              final joinedRow = joinedText.isEmpty ? '—' : joinedText;
              final isFreePlan = !_isPaidPlan(data);
              final planBadge = _planBadgeLabel(data);
              final planShort = _planShortLabel(data);
              final planKey = _strip(data?['subscriptionPlan'] as String?).toLowerCase();
              final planTitle = _strip(data?['subscriptionPlanTitle'] as String?);

              void openTimeline() {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TimelineScreen(repo: repo),
                  ),
                );
              }

              void openPersonalDetails() {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _PersonalDetailsScreen(
                      repo: repo,
                      titleName: titleName,
                      dobRow: dobRow,
                      joinedRow: joinedRow,
                      isFreePlan: isFreePlan,
                      planBadge: planBadge,
                      planShort: planShort,
                      planKey: planKey,
                      planTitle: planTitle,
                    ),
                  ),
                );
              }

              return SafeArea(
                child: ListenableBuilder(
                  listenable: repo,
                  builder: (context, _) {
                    final done = repo.allDone().toList()
                      ..sort(compareProceduresNewestFirst);
                    final preview = done.take(2).toList();
                    final glow = _profileGlowScore(done);
                    final monthly = _profileMonthlyGlowDelta(done);
                    final spend = _profileTotalSpend(done);
                    final mostDone = _profileMostDone(done);
                    final topSpend = _profileHighestSpend(done);

                    return ListView(
                      padding: const EdgeInsets.only(bottom: 120),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ProfileAvatar(
                                initials: initials,
                                photoUrl: photoUrl.isEmpty ? null : photoUrl,
                                size: 72,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        titleName,
                                        style:
                                            ProcedureSelectionTypography.display(
                                          size: 20,
                                          color: ProcedureSelectionTheme.ink,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _PlanChip(
                                        label: planBadge,
                                        paid: !isFreePlan,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              _ProfileCircleButton(
                                icon: Icons.settings_outlined,
                                onTap: openPersonalDetails,
                              ),
                              const SizedBox(width: 8),
                              _ProfileCircleButton(
                                icon: Icons.notifications_none_rounded,
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          NotificationsScreen(repo: repo),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                          child: _JourneyCard(
                            procedureCount: done.length,
                            totalSpend: spend,
                            glowScore: glow,
                            monthlyDelta: monthly,
                            onViewInsights: openTimeline,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                          child: _TimelinePreviewCard(
                            procedures: preview,
                            onViewAll: openTimeline,
                            onAdd: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ProcedureFormScreen(repo: repo),
                                ),
                              );
                            },
                            onOpen: (p) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => ProcedureDetailScreen(
                                    repo: repo,
                                    procedureId: p.id,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                          child: _InsightsPreviewCard(
                            mostDoneTitle: mostDone.$1,
                            mostDoneSub: mostDone.$2,
                            spendTitle: topSpend.$1,
                            spendSub: topSpend.$2,
                            onViewAll: openTimeline,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                          child: FutureBuilder<List<String>>(
                            future: SessionPrefs.exploreInterestPills(),
                            builder: (context, snap) {
                              final pills = exploreComparePillsForSelection(
                                snap.data,
                              );
                              return _InterestsPreviewCard(
                                pills: pills,
                                onManage: () async {
                                  await Navigator.of(context).push<bool>(
                                    MaterialPageRoute<bool>(
                                      builder: (_) =>
                                          ExploreProcedureInterestsScreen(
                                        repo: repo,
                                        editing: true,
                                      ),
                                    ),
                                  );
                                  if (context.mounted) {
                                    (context as Element).markNeedsBuild();
                                  }
                                },
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                          child: _ProfileCard(
                            child: _RowItem(
                              icon: Icons.settings_outlined,
                              title: 'Personal details',
                              sub: 'Your information and settings',
                              onTap: openPersonalDetails,
                              showDivider: false,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ProfileCircleButton extends StatelessWidget {
  const _ProfileCircleButton({required this.icon, required this.onTap});

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
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({required this.label, required this.paid});

  final String label;
  final bool paid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: paid
            ? ProcedureSelectionTheme.buttonPrimary
            : ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: paid ? ProcedureSelectionTheme.buttonPrimary : _profileDivider,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            paid ? Icons.workspace_premium_rounded : Icons.verified_outlined,
            size: 13,
            color: paid ? Colors.white : ProcedureSelectionTheme.muted,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: ProcedureSelectionTypography.label(
              size: 11,
              weight: FontWeight.w700,
              color: paid ? Colors.white : ProcedureSelectionTheme.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  const _SectionHeaderRow({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: ProcedureSelectionTypography.display(
                  size: 16,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: ProcedureSelectionTypography.body(
                  size: 12,
                  color: ProcedureSelectionTheme.muted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _LinkPill(label: actionLabel, onTap: onAction),
      ],
    );
  }
}

class _LinkPill extends StatelessWidget {
  const _LinkPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: ProcedureSelectionTheme.fieldFill,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: ProcedureSelectionTypography.label(
                  size: 11,
                  weight: FontWeight.w700,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: ProcedureSelectionTheme.ink,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JourneyCard extends StatelessWidget {
  const _JourneyCard({
    required this.procedureCount,
    required this.totalSpend,
    required this.glowScore,
    required this.monthlyDelta,
    required this.onViewInsights,
  });

  final int procedureCount;
  final String totalSpend;
  final int glowScore;
  final int monthlyDelta;
  final VoidCallback onViewInsights;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: 'My journey',
              subtitle: 'Your progress at a glance.',
              actionLabel: 'View insights',
              onAction: onViewInsights,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    icon: Icons.vaccines_outlined,
                    value: '$procedureCount',
                    label: 'Procedures',
                    hint: 'Total',
                  ),
                ),
                Expanded(
                  child: _StatTile(
                    icon: Icons.account_balance_wallet_outlined,
                    value: totalSpend,
                    label: 'Total spent',
                    hint: 'All time',
                  ),
                ),
                Expanded(
                  child: _StatTile(
                    icon: Icons.auto_awesome_rounded,
                    value: '$glowScore',
                    label: 'GlowScore',
                    hint: 'Total',
                  ),
                ),
                Expanded(
                  child: _StatTile(
                    icon: Icons.trending_up_rounded,
                    value: monthlyDelta >= 0 ? '+$monthlyDelta' : '$monthlyDelta',
                    label: 'GlowScore',
                    hint: 'This month',
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

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    required this.hint,
  });

  final IconData icon;
  final String value;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 18, color: ProcedureSelectionTheme.muted),
        const SizedBox(height: 8),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ProcedureSelectionTypography.display(
            size: 15,
            color: ProcedureSelectionTheme.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: ProcedureSelectionTypography.label(
            size: 9,
            weight: FontWeight.w600,
            color: ProcedureSelectionTheme.ink,
          ),
        ),
        Text(
          hint,
          style: ProcedureSelectionTypography.body(
            size: 9,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
      ],
    );
  }
}

class _TimelinePreviewCard extends StatelessWidget {
  const _TimelinePreviewCard({
    required this.procedures,
    required this.onViewAll,
    required this.onAdd,
    required this.onOpen,
  });

  final List<Procedure> procedures;
  final VoidCallback onViewAll;
  final VoidCallback onAdd;
  final ValueChanged<Procedure> onOpen;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: 'Treatment timeline',
              subtitle: 'Your procedures, progress and notes.',
              actionLabel: 'View all',
              onAction: onViewAll,
            ),
            const SizedBox(height: 14),
            if (procedures.isEmpty)
              Text(
                'No procedures yet. Add your first treatment.',
                style: ProcedureSelectionTypography.body(
                  size: 12,
                  color: ProcedureSelectionTheme.muted,
                ),
              )
            else
              for (var i = 0; i < procedures.length; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                _ProfileTimelineRow(
                  procedure: procedures[i],
                  dateLabel: _profileDateLabel(
                    DateTime(
                      procedures[i].date.year,
                      procedures[i].date.month,
                      procedures[i].date.day,
                    ),
                  ),
                  showLineBelow: i < procedures.length - 1,
                  onTap: () => onOpen(procedures[i]),
                ),
              ],
            const SizedBox(height: 14),
            _DashedAddButton(onTap: onAdd),
          ],
        ),
      ),
    );
  }
}

class _ProfileTimelineRow extends StatelessWidget {
  const _ProfileTimelineRow({
    required this.procedure,
    required this.dateLabel,
    required this.showLineBelow,
    required this.onTap,
  });

  final Procedure procedure;
  final String dateLabel;
  final bool showLineBelow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final zones = procedure.zones.where((z) => z.trim().isNotEmpty).join(' & ');
    final price = procedure.cost != null
        ? formatMoney(procedure.cost!, procedure.currency)
        : null;
    final glow = _profileGlowPointsFor(procedure);
    final meta = [
      'GlowScore +$glow',
      if (price != null) price,
    ].join(' · ');
    final icon = procedureIconFor(procedure);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Column(
              children: [
                Text(
                  dateLabel,
                  textAlign: TextAlign.right,
                  style: ProcedureSelectionTypography.label(
                    size: 9,
                    weight: FontWeight.w600,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    shape: BoxShape.circle,
                  ),
                ),
                if (showLineBelow)
                  Container(
                    width: 1.5,
                    height: 54,
                    margin: const EdgeInsets.only(top: 4),
                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                      color: ProcedureSelectionTheme.buttonPrimary,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: icon.asset != null
                        ? Image.asset(
                            icon.asset!,
                            width: 18,
                            height: 18,
                            color: Colors.white,
                            errorBuilder: (_, __, ___) => Text(
                              icon.emoji ?? '✨',
                              style: const TextStyle(fontSize: 14),
                            ),
                          )
                        : Text(
                            icon.emoji ?? '✨',
                            style: const TextStyle(fontSize: 14),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          procedure.title,
                          style: ProcedureSelectionTypography.label(
                            size: 13,
                            weight: FontWeight.w700,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                        if (zones.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            zones,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ProcedureSelectionTypography.body(
                              size: 11,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Text(
                          meta,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashedAddButton extends StatelessWidget {
  const _DashedAddButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: CustomPaint(
          painter: _DashedRRectPainter(
            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.18),
            radius: 14,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.add_rounded,
                  size: 18,
                  color: ProcedureSelectionTheme.ink,
                ),
                const SizedBox(width: 6),
                Text(
                  'Add procedure',
                  style: ProcedureSelectionTypography.label(
                    size: 13,
                    weight: FontWeight.w700,
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

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 5.0;
      const gap = 4.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

class _InsightsPreviewCard extends StatelessWidget {
  const _InsightsPreviewCard({
    required this.mostDoneTitle,
    required this.mostDoneSub,
    required this.spendTitle,
    required this.spendSub,
    required this.onViewAll,
  });

  final String mostDoneTitle;
  final String mostDoneSub;
  final String spendTitle;
  final String spendSub;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: 'Your insights',
              subtitle: 'What you do most — and where spend goes.',
              actionLabel: 'View all',
              onAction: onViewAll,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MiniInsight(
                    icon: Icons.repeat_rounded,
                    eyebrow: 'Most done',
                    title: mostDoneTitle,
                    subtitle: mostDoneSub,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MiniInsight(
                    icon: Icons.account_balance_wallet_outlined,
                    eyebrow: 'Highest total spend',
                    title: spendTitle,
                    subtitle: spendSub,
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

class _MiniInsight extends StatelessWidget {
  const _MiniInsight({
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
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: ProcedureSelectionTheme.muted),
          const SizedBox(height: 8),
          Text(
            eyebrow,
            style: ProcedureSelectionTypography.label(
              size: 10,
              weight: FontWeight.w600,
              color: ProcedureSelectionTheme.muted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.label(
              size: 13,
              weight: FontWeight.w700,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
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

class _InterestsPreviewCard extends StatelessWidget {
  const _InterestsPreviewCard({
    required this.pills,
    required this.onManage,
  });

  final List<String> pills;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final shown = pills.take(5).toList();
    final more = math.max(0, pills.length - shown.length) +
        math.max(0, kExploreLockedInterestLabels.length - 2);

    return _ProfileCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeaderRow(
              title: 'Your procedure interests',
              subtitle: 'Personalise your experience.',
              actionLabel: 'Manage',
              onAction: onManage,
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final pill in shown) ...[
                    _InterestAvatar(label: exploreInterestTabLabel(pill)),
                    const SizedBox(width: 10),
                  ],
                  _InterestAvatar(
                    label: more > 0 ? '+$more more' : 'More',
                    locked: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InterestAvatar extends StatelessWidget {
  const _InterestAvatar({required this.label, this.locked = false});

  final String label;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final info = procedureIconForTitle(label);
    return Column(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: locked
                ? ProcedureSelectionTheme.fieldFill
                : Colors.white.withValues(alpha: 0.7),
            border: Border.all(
              color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
            ),
          ),
          alignment: Alignment.center,
          child: locked
              ? Icon(
                  Icons.lock_outline_rounded,
                  size: 18,
                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.45),
                )
              : (info.asset != null
                  ? Image.asset(
                      info.asset!,
                      width: 24,
                      height: 24,
                      errorBuilder: (_, __, ___) =>
                          Text(info.emoji ?? '✨', style: const TextStyle(fontSize: 18)),
                    )
                  : Text(info.emoji ?? '✨', style: const TextStyle(fontSize: 18))),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: 64,
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ProcedureSelectionTypography.label(
              size: 9,
              weight: FontWeight.w600,
              color: locked
                  ? ProcedureSelectionTheme.muted
                  : ProcedureSelectionTheme.ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonalDetailsScreen extends StatelessWidget {
  const _PersonalDetailsScreen({
    required this.repo,
    required this.titleName,
    required this.dobRow,
    required this.joinedRow,
    required this.isFreePlan,
    required this.planBadge,
    required this.planShort,
    required this.planKey,
    required this.planTitle,
  });

  final ProcedureRepository repo;
  final String titleName;
  final String dobRow;
  final String joinedRow;
  final bool isFreePlan;
  final String planBadge;
  final String planShort;
  final String planKey;
  final String planTitle;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ProfileCircleButton(
                    icon: Icons.chevron_left_rounded,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Personal details',
                  style: ProcedureSelectionTypography.display(
                    size: 22,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(height: 18),
                _Section(
                  label: 'Personal info',
                  labelBottom: 12,
                  bottom: 16,
                  child: _ProfileCard(
                    child: Column(
                      children: [
                        _RowItem(
                          icon: Icons.person_outline_rounded,
                          title: 'Full name',
                          sub: titleName,
                          onTap: () {},
                          showArrow: false,
                        ),
                        _RowItem(
                          icon: Icons.calendar_month_rounded,
                          title: 'Date of birth',
                          sub: dobRow,
                          onTap: () {},
                          showArrow: false,
                        ),
                        _RowItem(
                          icon: Icons.event_available_outlined,
                          title: 'Member since',
                          sub: joinedRow,
                          onTap: () {},
                          showArrow: false,
                        ),
                        _RowItem(
                          icon: Icons.place_outlined,
                          title: 'Location',
                          sub: 'Bucharest, Romania',
                          onTap: () {},
                          showArrow: false,
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                ),
                _Section(
                  label: 'Subscription',
                  top: 8,
                  labelBottom: 12,
                  bottom: 16,
                  child: _ProfileCard(
                    child: Column(
                      children: [
                        _RowItem(
                          icon: Icons.star_border_rounded,
                          title: 'Current plan',
                          sub: planShort,
                          trailing: _TagPill(
                            text: planShort,
                            active: !isFreePlan,
                          ),
                          onTap: () {
                            if (isFreePlan) {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      SubscriptionScreen(repo: repo),
                                ),
                              );
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ManageSubscriptionScreen(
                                  planKey: planKey,
                                  planTitle: planTitle.isEmpty
                                      ? planBadge
                                      : planTitle,
                                ),
                              ),
                            );
                          },
                        ),
                        _RowItem(
                          icon: Icons.credit_card_rounded,
                          title: 'Restore subscription',
                          sub: 'Recover purchases on this device',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    const RestoreSubscriptionScreen(),
                              ),
                            );
                          },
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                ),
                _Section(
                  label: 'Legal',
                  top: 8,
                  labelBottom: 12,
                  bottom: 16,
                  child: _ProfileCard(
                    child: Column(
                      children: [
                        _RowItem(
                          icon: Icons.description_outlined,
                          title: 'Terms & conditions',
                          onTap: () {},
                        ),
                        _RowItem(
                          icon: Icons.shield_outlined,
                          title: 'Privacy policy',
                          onTap: () {},
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                ),
                _ProfileCard(
                  child: _RowItem(
                    icon: Icons.logout_rounded,
                    title: 'Log out',
                    titleColor: const Color(0xFFE85C5C),
                    iconColor: const Color(0xFFE85C5C),
                    onTap: () async {
                      await AuthService().signOut();
                      if (!context.mounted) return;
                      Navigator.of(context).pushAndRemoveUntil(
                        SoftWelcomeRoute<void>(
                          page: WelcomeScreen2(repo: repo),
                        ),
                        (_) => false,
                      );
                    },
                    showDivider: false,
                    showArrow: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

int _profileGlowScore(List<Procedure> items) {
  if (items.isEmpty) return 0;
  return (items.length * 94).clamp(0, 999);
}

int _profileMonthlyGlowDelta(List<Procedure> items) {
  final now = DateTime.now();
  final thisMonth = items
      .where((p) => p.date.year == now.year && p.date.month == now.month)
      .length;
  return thisMonth * 15;
}

String _profileTotalSpend(List<Procedure> items) {
  if (items.isEmpty) return '—';
  final sum = items.fold<num>(0, (acc, p) => acc + (p.cost ?? 0));
  if (sum <= 0) return '—';
  final currency = items
      .firstWhere((p) => p.cost != null, orElse: () => items.first)
      .currency;
  return formatMoney(sum, currency);
}

int _profileGlowPointsFor(Procedure p) {
  final seed = p.id.codeUnits.fold<int>(0, (a, b) => a + b);
  return 40 + (seed % 35);
}

(String, String) _profileMostDone(List<Procedure> items) {
  if (items.isEmpty) return ('—', 'No data yet');
  final counts = <String, int>{};
  for (final p in items) {
    final key = p.title.trim().isEmpty ? 'Other' : p.title.trim();
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final best = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final n = best.first.value;
  return (best.first.key, '$n session${n == 1 ? '' : 's'}');
}

(String, String) _profileHighestSpend(List<Procedure> items) {
  if (items.isEmpty) return ('—', 'No costs logged');
  final spend = <String, num>{};
  final counts = <String, int>{};
  var currency = 'EUR';
  for (final p in items) {
    final key = p.title.trim().isEmpty ? 'Other' : p.title.trim();
    counts[key] = (counts[key] ?? 0) + 1;
    final c = p.cost;
    if (c != null && c > 0) {
      spend[key] = (spend[key] ?? 0) + c;
      currency = p.currency;
    }
  }
  if (spend.isEmpty) return ('—', 'No costs logged');
  final best = spend.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final n = counts[best.first.key] ?? 0;
  return (
    formatMoney(best.first.value, currency),
    '$n session${n == 1 ? '' : 's'}',
  );
}

bool _isToday(DateTime day) {
  final now = DateTime.now();
  return day.year == now.year && day.month == now.month && day.day == now.day;
}

String _profileDateLabel(DateTime day) {
  if (_isToday(day)) return 'Today';
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  if (day.year == yesterday.year &&
      day.month == yesterday.month &&
      day.day == yesterday.day) {
    return 'Yesterday';
  }
  return formatDate(day);
}

class _ProfileAvatar extends StatefulWidget {
  const _ProfileAvatar({
    required this.initials,
    required this.photoUrl,
    this.size = 96,
  });

  final String initials;
  final String? photoUrl;
  final double size;

  @override
  State<_ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends State<_ProfileAvatar> {
  final _picker = ImagePicker();
  bool _busy = false;

  Future<String?> _cropSquare(String path) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressQuality: 90,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop photo',
          toolbarColor: ProcedureSelectionTheme.ink,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: ProcedureSelectionTheme.ink,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          hideBottomControls: true,
        ),
        IOSUiSettings(
          title: 'Crop photo',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    return cropped?.path;
  }

  Future<void> _onEditTap() async {
    if (_busy) return;
    final hasPhoto = (widget.photoUrl ?? '').trim().isNotEmpty;

    final action = await showBlackProfilePhotoSheet(context, hasPhoto: hasPhoto);

    if (action == null || !mounted) return;

    if (action == ProfilePhotoSheetAction.remove) {
      setState(() => _busy = true);
      try {
        await deleteProfilePhotoFromStorage();
        await AuthService().updateProfilePhotoUrl(null);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo removed')),
        );
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t remove photo. Try again.')),
        );
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    final source = action == ProfilePhotoSheetAction.camera
        ? ImageSource.camera
        : ImageSource.gallery;
    setState(() => _busy = true);
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 90);
      if (picked == null) return;
      final cropped = await _cropSquare(picked.path);
      if (cropped == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw StateError('Must be signed in to upload a profile photo');
      }
      final url = await uploadProfilePhotoPath(cropped);
      await AuthService().updateProfilePhotoUrl(
        url,
        photoStoragePath: profilePhotoStoragePath(user.uid),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated')),
      );
    } catch (e) {
      debugPrint('[Profile] photo upload failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t update photo. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = (widget.photoUrl ?? '').trim();
    final hasPhoto = url.isNotEmpty;

    final size = widget.size;
    final fontSize = size >= 90 ? 28.0 : 22.0;
    final cam = size >= 90 ? 30.0 : 26.0;

    return GestureDetector(
      onTap: _busy ? null : _onEditTap,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(999),
              compact: true,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                child: hasPhoto
                    ? ClipOval(
                        child: Image.network(
                          url,
                          width: size,
                          height: size,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Text(
                            widget.initials,
                            style: ProcedureSelectionTypography.display(
                              size: fontSize,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                        ),
                      )
                    : Text(
                        widget.initials,
                        style: ProcedureSelectionTypography.display(
                          size: fontSize,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
              ),
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: cam,
                height: cam,
                decoration: BoxDecoration(
                  color: ProcedureSelectionTheme.buttonPrimary,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: _busy
                    ? Padding(
                        padding: EdgeInsets.all(cam * 0.22),
                        child: const CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        Icons.camera_alt_rounded,
                        size: cam * 0.45,
                        color: Colors.white,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.child,
    this.top = 0,
    this.bottom = 0,
    this.labelBottom = 10,
  });

  final String label;
  final Widget child;
  final double top;
  final double bottom;
  final double labelBottom;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top, 20, bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(2, 0, 2, labelBottom),
            child: ProcedureSectionLabel(label),
          ),
          child,
        ],
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: child,
    );
  }
}

class _ProfileIconBadge extends StatelessWidget {
  const _ProfileIconBadge({required this.icon, this.iconColor});

  final IconData icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      clipBehavior: Clip.antiAlias,
      decoration: ProcedureGlassDecorations.iconBadge(selected: false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: ProcedureGlassDecorations.polishSheenGradient(
                opacity: 0.12,
              ),
            ),
          ),
          Center(
            child: Icon(
              icon,
              size: 17,
              color: iconColor ?? ProcedureSelectionTheme.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _RowItem extends StatelessWidget {
  const _RowItem({
    required this.icon,
    required this.title,
    this.sub,
    this.onTap,
    this.trailing,
    this.showDivider = true,
    this.showArrow = true,
    this.titleColor,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? sub;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool showDivider;
  final bool showArrow;
  final Color? titleColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          border: showDivider
              ? const Border(bottom: BorderSide(color: _profileDivider))
              : null,
        ),
        child: Row(
          children: [
            _ProfileIconBadge(icon: icon, iconColor: iconColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ProcedureSelectionTypography.label(
                      size: 14,
                      weight: FontWeight.w600,
                      color: titleColor ?? ProcedureSelectionTheme.ink,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub!,
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              trailing!,
              const SizedBox(width: 6),
            ],
            if (showArrow)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
              ),
          ],
        ),
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: active
            ? ProcedureSelectionTheme.buttonPrimary
            : ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active
              ? ProcedureSelectionTheme.buttonPrimary
              : _profileDivider,
        ),
      ),
      child: Text(
        text,
        style: ProcedureSelectionTypography.label(
          size: 11,
          weight: FontWeight.w600,
          color: active ? Colors.white : ProcedureSelectionTheme.muted,
        ),
      ),
    );
  }
}
