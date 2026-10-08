import 'package:flutter/material.dart';

import '../procedure_selection_theme.dart';

/// Soft off-white gradient for wizard step 1 — matches the light glass mock.
class Step1Background extends StatelessWidget {
  const Step1Background({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF9F9FB),
              ProcedureSelectionTheme.pageBackgroundTop,
              ProcedureSelectionTheme.pageBackground,
              ProcedureSelectionTheme.pageBackgroundBottom,
            ],
            stops: [0.0, 0.35, 0.72, 1.0],
          ),
        ),
      ),
    );
  }
}
