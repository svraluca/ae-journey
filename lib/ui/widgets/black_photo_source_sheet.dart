import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

/// Black camera/gallery chooser matching GlowPass modal sheets
/// (procedure form before/after, etc.).
Future<ImageSource?> showBlackPhotoSourceSheet(
  BuildContext context, {
  bool isBefore = true,
  String? title,
  String? subtitle,
}) {
  final resolvedTitle = (title ?? '').trim().isNotEmpty
      ? title!.trim()
      : (isBefore ? 'Add Before photo' : 'Add After photo');
  final resolvedSubtitle = (subtitle ?? '').trim().isNotEmpty
      ? subtitle!.trim()
      : (isBefore
          ? 'Baseline shot — same distance and angle you’ll use for after (face or body).'
          : 'Result shot — match the same distance, angle, and framing as before.');

  return showModalBottomSheet<ImageSource>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.50),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
      final bottomSafe = MediaQuery.paddingOf(sheetContext).bottom;
      final sf = GoogleFonts.urbanist();
      final serif = GoogleFonts.dmSerifDisplay();

      Widget sourceButton({
        required IconData icon,
        required String title,
        required String sub,
        required ImageSource source,
      }) {
        return InkWell(
          onTap: () => Navigator.of(sheetContext).pop(source),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14), width: 0.8),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.8),
                  ),
                  alignment: Alignment.center,
                  child: Icon(icon, size: 18, color: Colors.white.withValues(alpha: 0.90)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: sf.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.92),
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: sf.copyWith(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.65),
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }

      Widget tip(String t) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 4,
              height: 4,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t,
                style: sf.copyWith(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.62),
                  height: 1.4,
                ),
              ),
            ),
          ],
        );
      }

      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Container(
          padding: EdgeInsets.fromLTRB(22, 0, 22, 16 + bottomSafe),
          decoration: BoxDecoration(
            color: const Color(0xFF000000),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
          ),
          child: SafeArea(
            top: false,
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
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        resolvedTitle,
                        style: serif.copyWith(fontSize: 22, color: Colors.white, height: 1.15),
                      ),
                    ),
                    InkWell(
                      onTap: () => Navigator.of(sheetContext).pop(),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  resolvedSubtitle,
                  style: sf.copyWith(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.65),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: sourceButton(
                        icon: Icons.photo_camera_outlined,
                        title: 'Camera',
                        sub: 'Take now',
                        source: ImageSource.camera,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: sourceButton(
                        icon: Icons.photo_outlined,
                        title: 'Gallery',
                        sub: 'Choose existing',
                        source: ImageSource.gallery,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PHOTO TIPS',
                        style: sf.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.12 * 10,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                      const SizedBox(height: 8),
                      tip('Natural light, subject facing the camera'),
                      const SizedBox(height: 5),
                      tip('Same distance and angle for Before & After'),
                      const SizedBox(height: 5),
                      tip('Works for face or body — no filter'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white.withValues(alpha: 0.65),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  child: Text(
                    'Skip for now',
                    style: sf.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(height: bottomInset > 0 ? 8 : 0),
              ],
            ),
          ),
        ),
      );
    },
  );
}
