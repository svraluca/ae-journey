import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Light restore-purchases screen — matches Timeline / manage-subscription vibe.
class RestoreSubscriptionScreen extends StatefulWidget {
  const RestoreSubscriptionScreen({super.key});

  @override
  State<RestoreSubscriptionScreen> createState() => _RestoreSubscriptionScreenState();
}

class _RestoreSubscriptionScreenState extends State<RestoreSubscriptionScreen> {
  bool _restoring = false;

  String _labelFor(String plan) => switch (plan.toLowerCase()) {
        'monthly' => 'Monthly Pro',
        'yearly' => 'Yearly Pro',
        'lifetime' => 'Lifetime Pro',
        _ => 'ÆSTHETIC JOURNEY Pro',
      };

  Future<void> _restore() async {
    if (_restoring) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _restoring = true);

    try {
      // Brief pause so the UI reads as a real store check.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final result = await AuthService().restoreSubscription();
      if (!mounted) return;

      switch (result.kind) {
        case RestoreSubscriptionKind.none:
          setState(() => _restoring = false);
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'No purchases found for this Apple ID.',
                style: ProcedureSelectionTypography.body(size: 13, color: Colors.white),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        case RestoreSubscriptionKind.alreadyActive:
          Navigator.of(context).pop();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'You’re already on ${_labelFor(result.plan!)}.',
                style: ProcedureSelectionTypography.body(size: 13, color: Colors.white),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        case RestoreSubscriptionKind.restored:
          Navigator.of(context).pop();
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Restored ${_labelFor(result.plan!)}. Welcome back.',
                style: ProcedureSelectionTypography.body(size: 13, color: Colors.white),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _restoring = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Couldn’t restore right now. Try again.',
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
                        'Restore',
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
                        child: const SizedBox(
                          width: 88,
                          height: 88,
                          child: Icon(
                            Icons.credit_card_rounded,
                            size: 36,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Restore subscription',
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.display(
                        size: 24,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'If you previously bought ÆSTHETIC JOURNEY Pro on this Apple ID, we can recover it on this device.',
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.body(
                        size: 13,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const ProcedureSelectionPanel(
                      title: 'How it works',
                      compactTitle: true,
                      child: Column(
                        children: [
                          _DetailRow(
                            icon: Icons.search_rounded,
                            title: 'Check purchases',
                            value: 'This Apple ID',
                          ),
                          SizedBox(height: 12),
                          _DetailRow(
                            icon: Icons.sync_rounded,
                            title: 'Reactivate Pro',
                            value: 'If found',
                          ),
                          SizedBox(height: 12),
                          _DetailRow(
                            icon: Icons.lock_outline_rounded,
                            title: 'Access',
                            value: 'Full passport',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    ProcedurePremiumContinueButton(
                      label: _restoring ? 'Restoring…' : 'Restore purchases',
                      onPressed: _restoring ? null : _restore,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Nothing will be charged. Restore only recovers an existing purchase.',
                      textAlign: TextAlign.center,
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
