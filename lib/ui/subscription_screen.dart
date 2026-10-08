import 'package:flutter/material.dart';

import '../data/procedure_repository.dart';
import 'procedure_selection_theme.dart';
import 'subscription_success_screen.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Paywall / subscription screen — light glass vibe matching Timeline.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({
    super.key,
    this.repo,
    this.onSubscribe,
    this.onClose,
  });

  /// Used to route to the home shell after a successful (simulated) purchase.
  final ProcedureRepository? repo;

  /// Called when the user taps the CTA with the chosen plan.
  final ValueChanged<SubscriptionPlan>? onSubscribe;

  /// Called when the user dismisses the screen. Defaults to popping the route.
  final VoidCallback? onClose;

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

enum SubscriptionPlan { monthly, yearly, lifetime }

class _PlanInfo {
  const _PlanInfo({
    required this.plan,
    required this.label,
    required this.price,
    required this.cardTitle,
    required this.cardSub,
    this.offBadge,
    this.oldPrice,
    this.bestValue = false,
  });

  final SubscriptionPlan plan;
  final String label;
  final String price;
  final String cardTitle;
  final String cardSub;
  final String? offBadge;
  final String? oldPrice;
  final bool bestValue;
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  static const _plans = <_PlanInfo>[
    _PlanInfo(
      plan: SubscriptionPlan.monthly,
      label: 'Monthly',
      price: r'$4.99',
      cardTitle: 'Monthly plan',
      cardSub: 'Billed monthly · cancel anytime',
    ),
    _PlanInfo(
      plan: SubscriptionPlan.yearly,
      label: 'Yearly',
      price: r'$24.99',
      cardTitle: 'Yearly plan',
      cardSub: r'Just $2.08 / month',
      offBadge: '30% off',
      oldPrice: r'$35.99 / yr',
      bestValue: true,
    ),
  ];

  static const _features = <({IconData icon, String text})>[
    (icon: Icons.vaccines_outlined, text: 'Log procedures & treatments'),
    (icon: Icons.photo_library_outlined, text: 'Before & after photo timeline'),
    (icon: Icons.auto_awesome_outlined, text: 'Glow-up score & stats'),
    (icon: Icons.lock_outline_rounded, text: 'Private & secure passport'),
  ];

  SubscriptionPlan _selected = SubscriptionPlan.yearly;

  _PlanInfo get _selectedInfo => _plans.firstWhere((p) => p.plan == _selected);

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _handleSubscribe() {
    if (widget.onSubscribe != null) {
      widget.onSubscribe!(_selected);
      return;
    }
    final info = _selectedInfo;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SubscriptionProcessingScreen(
          repo: widget.repo,
          planKey: info.plan.name,
          planTitle: '${info.label} Pro',
          priceLine: '${info.label.toLowerCase()} plan · ${info.price} · 3-day trial',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              ProcedureSelectionTheme.pageBackgroundTop,
              ProcedureSelectionTheme.pageBackground,
              ProcedureSelectionTheme.pageBackgroundBottom,
            ],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: SizedBox(
                          height: 36,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Text(
                                'Subscription',
                                style: ProcedureSelectionTypography.display(
                                  size: 18,
                                  color: ProcedureSelectionTheme.ink,
                                ),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: _CircleButton(
                                  icon: Icons.close_rounded,
                                  onTap: _close,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(20, 22, 20, 0),
                        child: Center(child: _LogoOrb()),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 18, 28, 0),
                        child: Column(
                          children: [
                            Text(
                              'Track your glow-up\njourney',
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.display(
                                size: 22,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Your aesthetic passport for every\nprocedure, transformation & milestone',
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.body(
                                size: 13,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: ProcedureSelectionPanel(
                          title: 'Included',
                          compactTitle: true,
                          child: Column(
                            children: [
                              for (var i = 0; i < _features.length; i++) ...[
                                if (i > 0) const SizedBox(height: 12),
                                _FeatureRow(
                                  icon: _features[i].icon,
                                  text: _features[i].text,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: ProcedureSectionLabel('Choose a plan'),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                        child: Row(
                          children: [
                            for (var i = 0; i < _plans.length; i++) ...[
                              if (i > 0) const SizedBox(width: 8),
                              Expanded(
                                child: _PlanChip(
                                  info: _plans[i],
                                  active: _plans[i].plan == _selected,
                                  onTap: () => setState(() => _selected = _plans[i].plan),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: _SelectedPlanCard(info: _selectedInfo),
                      ),
                    ),
                    SliverToBoxAdapter(child: SizedBox(height: 24 + bottomPad)),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + bottomPad),
                child: Column(
                  children: [
                    _SubscribeButton(onPressed: _handleSubscribe),
                    const SizedBox(height: 12),
                    Text(
                      '3-day free trial · cancel anytime',
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const _FooterLinks(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});

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

class _LogoOrb extends StatelessWidget {
  const _LogoOrb();

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: SizedBox(
        width: 96,
        height: 96,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Image.asset('assets/logoapp.PNG', fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: ProcedureSelectionTheme.fieldFill,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16, color: ProcedureSelectionTheme.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: ProcedureSelectionTypography.body(
              size: 13,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
        ),
        Icon(
          Icons.check_rounded,
          size: 18,
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.45),
        ),
      ],
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.info,
    required this.active,
    required this.onTap,
  });

  final _PlanInfo info;
  final bool active;
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
          selected: active,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
            child: Column(
              children: [
                Text(
                  info.label,
                  style: ProcedureSelectionTypography.chip(
                    size: 11,
                    color: active ? Colors.white.withValues(alpha: 0.72) : ProcedureSelectionTheme.muted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  info.price,
                  style: ProcedureSelectionTypography.display(
                    size: 16,
                    color: active ? Colors.white : ProcedureSelectionTheme.ink,
                  ),
                ),
                if (info.bestValue) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Best value',
                    style: ProcedureSelectionTypography.label(
                      size: 9,
                      color: active ? Colors.white.withValues(alpha: 0.7) : ProcedureSelectionTheme.sectionLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedPlanCard extends StatelessWidget {
  const _SelectedPlanCard({required this.info});

  final _PlanInfo info;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          info.cardTitle,
                          style: ProcedureSelectionTypography.display(
                            size: 13,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                      ),
                      if (info.offBadge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: ProcedureSelectionTheme.buttonPrimary,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            info.offBadge!,
                            style: ProcedureSelectionTypography.label(
                              size: 9,
                              weight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    info.cardSub,
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  info.price,
                  style: ProcedureSelectionTypography.display(
                    size: 18,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                if (info.oldPrice != null)
                  Text(
                    info.oldPrice!,
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
                    ).copyWith(decoration: TextDecoration.lineThrough),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscribeButton extends StatelessWidget {
  const _SubscribeButton({required this.onPressed});

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
              Text(
                'Start your glow journey',
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
    );
  }
}

class _FooterLinks extends StatelessWidget {
  const _FooterLinks();

  @override
  Widget build(BuildContext context) {
    Widget link(String label) => InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              label,
              style: ProcedureSelectionTypography.body(
                size: 11,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ),
        );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        link('Terms'),
        Text(
          ' · ',
          style: ProcedureSelectionTypography.body(
            size: 11,
            color: ProcedureSelectionTheme.muted.withValues(alpha: 0.5),
          ),
        ),
        link('Privacy'),
        Text(
          ' · ',
          style: ProcedureSelectionTypography.body(
            size: 11,
            color: ProcedureSelectionTheme.muted.withValues(alpha: 0.5),
          ),
        ),
        link('Restore'),
      ],
    );
  }
}
