import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Light manage / cancel subscription screen — matches Timeline glass vibe.
class ManageSubscriptionScreen extends StatefulWidget {
  const ManageSubscriptionScreen({
    super.key,
    required this.planTitle,
    required this.planKey,
    this.priceLine,
  });

  final String planTitle;
  final String planKey;
  final String? priceLine;

  @override
  State<ManageSubscriptionScreen> createState() => _ManageSubscriptionScreenState();
}

class _ManageSubscriptionScreenState extends State<ManageSubscriptionScreen> {
  bool _cancelling = false;

  String get _planLabel {
    final title = widget.planTitle.trim();
    if (title.isNotEmpty) return title;
    return switch (widget.planKey.toLowerCase()) {
      'monthly' => 'Monthly Pro',
      'yearly' => 'Yearly Pro',
      'lifetime' => 'Lifetime Pro',
      _ => 'ÆSTHETIC JOURNEY Pro',
    };
  }

  String get _billingLine {
    final custom = (widget.priceLine ?? '').trim();
    if (custom.isNotEmpty) return custom;
    return switch (widget.planKey.toLowerCase()) {
      'monthly' => r'Billed monthly · $4.99',
      'yearly' => r'Billed yearly · $24.99',
      'lifetime' => 'One-time purchase',
      _ => 'Active subscription',
    };
  }

  Future<void> _confirmCancel() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Cancel subscription?',
          style: ProcedureSelectionTypography.display(size: 18, color: ProcedureSelectionTheme.ink),
        ),
        content: Text(
          'You’ll keep Pro access until the end of the current period, then move to the Free plan.',
          style: ProcedureSelectionTypography.body(size: 13, color: ProcedureSelectionTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Keep plan',
              style: ProcedureSelectionTypography.label(
                size: 13,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Cancel plan',
              style: ProcedureSelectionTypography.label(
                size: 13,
                weight: FontWeight.w700,
                color: const Color(0xFFE85C5C),
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _cancelling = true);
    try {
      await AuthService().cancelSubscription();
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Subscription cancelled. You’re on Free plan.',
            style: ProcedureSelectionTypography.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn’t cancel right now. Try again.',
            style: ProcedureSelectionTypography.body(size: 13, color: Colors.white),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        'Your plan',
                        style: ProcedureSelectionTypography.display(
                          size: 18,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _CircleButton(
                          icon: Icons.chevron_left_rounded,
                          onTap: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(20, 24, 20, 24 + bottomPad),
                  children: [
                    Center(
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(999),
                        compact: true,
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Image.asset('assets/logoapp.PNG', fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _planLabel,
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.display(
                        size: 24,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _billingLine,
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.body(
                        size: 13,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 22),
                    ProcedureSelectionPanel(
                      title: 'Plan details',
                      compactTitle: true,
                      child: Column(
                        children: [
                          const _DetailRow(
                            icon: Icons.workspace_premium_rounded,
                            title: 'Status',
                            value: 'Active',
                          ),
                          const SizedBox(height: 12),
                          _DetailRow(
                            icon: Icons.event_available_outlined,
                            title: 'Billing',
                            value: switch (widget.planKey.toLowerCase()) {
                              'monthly' => 'Monthly',
                              'yearly' => 'Yearly',
                              'lifetime' => 'Lifetime',
                              _ => 'Pro',
                            },
                          ),
                          const SizedBox(height: 12),
                          const _DetailRow(
                            icon: Icons.lock_outline_rounded,
                            title: 'Access',
                            value: 'Full passport',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    ProcedureSelectionPanel(
                      title: 'Need a change?',
                      compactTitle: true,
                      subtitle: 'Cancel anytime. You can resubscribe from profile.',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _cancelling ? null : _confirmCancel,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: const Color(0x14E85C5C),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0x33E85C5C)),
                            ),
                            alignment: Alignment.center,
                            child: _cancelling
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                      color: Color(0xFFE85C5C),
                                    ),
                                  )
                                : Text(
                                    'Cancel subscription',
                                    style: ProcedureSelectionTypography.label(
                                      size: 14,
                                      weight: FontWeight.w700,
                                      color: const Color(0xFFE85C5C),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
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
            child: Icon(icon, size: 20, color: ProcedureSelectionTheme.ink),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

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
            title,
            style: ProcedureSelectionTypography.body(
              size: 13,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
        ),
        Text(
          value,
          style: ProcedureSelectionTypography.label(
            size: 12,
            weight: FontWeight.w700,
            color: ProcedureSelectionTheme.muted,
          ),
        ),
      ],
    );
  }
}
