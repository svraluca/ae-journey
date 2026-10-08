import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/checkpoint.dart';
import 'formatters.dart';

/// Returns `true` when the user confirms delete, `false` on Cancel, `null` if dismissed.
Future<bool?> showDeleteCheckpointSheet(
  BuildContext context, {
  required Checkpoint checkpoint,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: _DeleteCheckpointSheetBody(checkpoint: checkpoint),
    ),
  );
}

class _DeleteCheckpointSheetBody extends StatelessWidget {
  const _DeleteCheckpointSheetBody({required this.checkpoint});

  final Checkpoint checkpoint;

  static const _deleteRed = Color(0xFFDD4444);
  static const _ink = Color(0xFF1A1A1A);
  static const _hero = Color(0xFF1A1A2E);

  @override
  Widget build(BuildContext context) {
    final serif = GoogleFonts.dmSerifDisplay();
    final sf = GoogleFonts.urbanist();
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    final title = checkpoint.title.trim().isEmpty ? 'Checkpoint' : checkpoint.title.trim();
    final dateStr = formatDate(checkpoint.date);

    final maxH = MediaQuery.sizeOf(context).height * 0.92;

    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Material(
          color: Colors.white,
          elevation: 16,
          shadowColor: Colors.black26,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(bottom: 20 + bottomPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: const Color(0xFFE5E5E5), borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(color: const Color(0xFFFEF0F0), borderRadius: BorderRadius.circular(20)),
                    alignment: Alignment.center,
                    child: const Icon(Icons.delete_outline_rounded, size: 28, color: _deleteRed),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 16, 28, 0),
                  child: Column(
                    children: [
                      Text(
                        'Delete checkpoint?',
                        textAlign: TextAlign.center,
                        style: serif.copyWith(fontSize: 24, color: _ink, height: 1.15),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This will permanently remove this checkpoint and its progress photo from your procedure.',
                        textAlign: TextAlign.center,
                        style: sf.copyWith(fontSize: 14, color: const Color(0xFF999999), height: 1.6),
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F8F8),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFF0F0F0)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: _hero, borderRadius: BorderRadius.circular(12)),
                        alignment: Alignment.center,
                        child: Icon(Icons.flag_outlined, size: 18, color: Colors.white.withValues(alpha: 0.6)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: sf.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: _ink)),
                            const SizedBox(height: 2),
                            Text(dateStr, style: sf.copyWith(fontSize: 12, color: const Color(0xFFBBBBBB))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
                  child: Column(
                    children: [
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text('Yes, delete checkpoint', style: sf.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                        style: FilledButton.styleFrom(
                          backgroundColor: _deleteRed,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 54),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF777777),
                          side: const BorderSide(color: Color(0xFFE5E5E5)),
                          minimumSize: const Size(double.infinity, 54),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Text('Cancel', style: sf.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
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

