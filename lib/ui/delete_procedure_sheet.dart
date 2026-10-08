import 'package:flutter/material.dart';

import '../data/procedure.dart';
import 'formatters.dart';
import 'procedure_icon_resolver.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Bottom sheet aligned with the dark-glass custom procedure sheet in [procedure_form_screen.dart].
///
/// Returns `true` when the user confirms delete, `false` on Cancel, `null` if dismissed.
Future<bool?> showDeleteProcedureSheet(
  BuildContext context, {
  required Procedure procedure,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: _DeleteProcedureSheetBody(procedure: procedure),
    ),
  );
}

class _DeleteProcedureSheetBody extends StatelessWidget {
  const _DeleteProcedureSheetBody({required this.procedure});

  final Procedure procedure;

  static const _deleteRed = Color(0xFFE85C5C);
  static const _inkText = Color(0xFFFFFFFF);
  static const _muted = Color(0xB3FFFFFF);
  static const _stroke = Color(0x24FFFFFF);

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final title = procedure.title.trim();
    final cat = (procedure.category ?? 'Treatment').trim();
    final doctor = (procedure.practitioner ?? '').trim().isEmpty ? '—' : procedure.practitioner!.trim();
    final costMeta = procedure.cost != null ? formatMoney(procedure.cost!, procedure.currency) : '—';
    final dateStr = formatDate(procedure.date);
    final meta = [doctor, dateStr, costMeta].join(' · ');
    final icon = procedureIconFor(procedure);

    final maxH = MediaQuery.sizeOf(context).height * 0.92;

    Widget bullet(String text, {bool last = false}) {
      return Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: _deleteRed.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: ProcedureSelectionTypography.body(
                  size: 12,
                  color: Colors.white.withValues(alpha: 0.62),
                ).copyWith(height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Material(
          color: const Color(0xFF000000),
          elevation: 24,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: bottomPad > 16 ? bottomPad : 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          'Delete procedure?',
                          style: ProcedureSelectionTypography.display(size: 18, color: _inkText),
                        ),
                      ),
                      Material(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(context).pop(false),
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 0),
                  child: Text.rich(
                    TextSpan(
                      style: ProcedureSelectionTypography.body(size: 11, color: _muted).copyWith(height: 1.55),
                      children: [
                        const TextSpan(text: 'This will permanently remove '),
                        TextSpan(
                          text: title,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            weight: FontWeight.w700,
                            color: Colors.white.withValues(alpha: 0.92),
                          ).copyWith(height: 1.55),
                        ),
                        const TextSpan(text: ' and all its data from your passport.'),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (icon.asset != null)
                          ProcedureCategoryIconBadge(
                            iconAsset: icon.asset!,
                            selected: true,
                            size: 36,
                            iconScale: 0.72,
                          )
                        else
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _stroke, width: 0.8),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              icon.emoji ?? '✦',
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ProcedureSelectionTypography.label(
                                  size: 13,
                                  weight: FontWeight.w700,
                                  color: Colors.white.withValues(alpha: 0.94),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                meta,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: ProcedureSelectionTypography.body(
                                  size: 11,
                                  color: Colors.white.withValues(alpha: 0.52),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
                          ),
                          child: Text(
                            cat,
                            style: ProcedureSelectionTypography.chip(
                              size: 10,
                              weight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.72),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    decoration: BoxDecoration(
                      color: _deleteRed.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _deleteRed.withValues(alpha: 0.28), width: 0.8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'THIS WILL ALSO DELETE',
                          style: ProcedureSelectionTypography.label(
                            size: 10,
                            weight: FontWeight.w800,
                            color: _deleteRed,
                          ).copyWith(letterSpacing: 2.2),
                        ),
                        const SizedBox(height: 8),
                        bullet('All recovery checkpoints and progress photos'),
                        bullet('Before & after photos for this procedure'),
                        bullet('Glow points earned from this session'),
                        bullet('Associated appointment reminders', last: true),
                      ],
                    ),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.10),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                  child: Column(
                    children: [
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text(
                          'Yes, delete procedure',
                          style: ProcedureSelectionTypography.label(size: 14, weight: FontWeight.w700),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _deleteRed,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 52),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                          elevation: 0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Material(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.of(context).pop(false),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            child: Text(
                              'Cancel',
                              textAlign: TextAlign.center,
                              style: ProcedureSelectionTypography.label(
                                size: 14,
                                weight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.92),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'This action cannot be undone',
                        textAlign: TextAlign.center,
                        style: ProcedureSelectionTypography.body(
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
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
}
