import 'package:flutter/material.dart';

import '../procedure_selection_theme.dart';

enum ProfilePhotoSheetAction { camera, gallery, remove }

/// Black profile-photo chooser matching the custom procedure sheet aesthetic.
Future<ProfilePhotoSheetAction?> showBlackProfilePhotoSheet(
  BuildContext context, {
  required bool hasPhoto,
}) {
  return showModalBottomSheet<ProfilePhotoSheetAction>(
    context: context,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.50),
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final bottomInset = MediaQuery.viewInsetsOf(sheetContext).bottom;
      final bottomSafe = MediaQuery.paddingOf(sheetContext).bottom;

      const inkText = Color(0xFFFFFFFF);
      const muted = Color(0xB3FFFFFF);
      const destructive = Color(0xFFE85C5C);

      Widget actionButton({
        required IconData icon,
        required String title,
        required String subtitle,
        required ProfilePhotoSheetAction action,
        Color? titleColor,
        Color? iconColor,
      }) {
        final resolvedTitleColor = titleColor ?? inkText;
        final resolvedIconColor = iconColor ?? Colors.white.withValues(alpha: 0.90);

        return Material(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: () => Navigator.of(sheetContext).pop(action),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              decoration: BoxDecoration(
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
                    child: Icon(icon, size: 18, color: resolvedIconColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: ProcedureSelectionTypography.label(
                            size: 13,
                            weight: FontWeight.w700,
                            color: resolvedTitleColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: muted,
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

      return Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Material(
          color: const Color(0xFF000000),
          elevation: 24,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(22, 0, 22, 16 + bottomSafe),
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
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          'Profile photo',
                          style: ProcedureSelectionTypography.display(size: 18, color: inkText),
                        ),
                      ),
                      Material(
                        color: Colors.white.withValues(alpha: 0.10),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(sheetContext).pop(),
                          child: const SizedBox(
                            width: 32,
                            height: 32,
                            child: Icon(Icons.close_rounded, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Update your profile picture — take a new photo or choose one from your library.',
                    style: ProcedureSelectionTypography.body(size: 11, color: muted),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'OPTIONS',
                    style: ProcedureSelectionTypography.label(
                      size: 10,
                      weight: FontWeight.w800,
                      color: muted,
                    ).copyWith(letterSpacing: 2.2),
                  ),
                  const SizedBox(height: 10),
                  actionButton(
                    icon: Icons.photo_camera_outlined,
                    title: 'Take photo',
                    subtitle: 'Use your camera now',
                    action: ProfilePhotoSheetAction.camera,
                  ),
                  const SizedBox(height: 8),
                  actionButton(
                    icon: Icons.photo_outlined,
                    title: 'Choose from library',
                    subtitle: 'Pick an existing photo',
                    action: ProfilePhotoSheetAction.gallery,
                  ),
                  if (hasPhoto) ...[
                    const SizedBox(height: 8),
                    actionButton(
                      icon: Icons.delete_outline_rounded,
                      title: 'Remove photo',
                      subtitle: 'Clear your current profile picture',
                      action: ProfilePhotoSheetAction.remove,
                      titleColor: destructive,
                      iconColor: destructive,
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
