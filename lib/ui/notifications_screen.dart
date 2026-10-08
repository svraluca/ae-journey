import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../data/procedure_repository.dart';
import '../services/notification_navigation.dart';
import '../services/notifications_store.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

enum _NotifKind { checkpoint, ai, glow, redo, tip, report, export }

class _Notif {
  const _Notif({
    required this.id,
    required this.kind,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.unread,
    this.procedureId,
  });

  final String id;
  final _NotifKind kind;
  final String type;
  final String title;
  final String subtitle;
  final bool unread;
  final String? procedureId;
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  Future<void> _markAllRead() => NotificationsStore.markAllRead();

  _NotifKind _kindFromType(String raw, {required String title, required String body}) {
    final t = raw.toLowerCase().trim();
    final text = '${title.toLowerCase()} ${body.toLowerCase()}';
    if (t.contains('checkpoint')) return _NotifKind.checkpoint;
    if (t.contains('reminder') || text.contains('glowpass reminder')) return _NotifKind.redo;
    if (t.contains('glow') && t.contains('report')) return _NotifKind.report;
    if (t.contains('glow') && t.contains('studio')) return _NotifKind.glow;
    if (t.contains('glow')) return _NotifKind.glow;
    if (t.contains('redo') || t.contains('topup')) return _NotifKind.redo;
    if (t.contains('tip')) return _NotifKind.tip;
    if (t.contains('report')) return _NotifKind.report;
    if (t.contains('export')) return _NotifKind.export;
    if (t.contains('ai')) return _NotifKind.ai;
    return _NotifKind.ai;
  }

  _Notif _notifFromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final n = doc.data();
    final unread = (n['isRead'] == false);
    final title = (n['title'] as String?)?.trim().isNotEmpty == true
        ? (n['title'] as String).trim()
        : 'Notification';
    final body = (n['body'] as String?)?.trim() ?? '';
    final type = (n['type'] as String?)?.trim() ?? '';
    final procedureId = (n['procedureId'] as String?)?.trim();
    final subtitle = body.isNotEmpty ? body : type;
    return _Notif(
      id: doc.id,
      kind: _kindFromType(type, title: title, body: body),
      type: type,
      unread: unread,
      title: title,
      subtitle: subtitle,
      procedureId: procedureId?.isNotEmpty == true ? procedureId : null,
    );
  }

  Future<void> _openNotification(_Notif notif) async {
    await NotificationsStore.markAsRead(notif.id);
    if (!mounted) return;
    NotificationNavigation.navigateFrom(
      type: notif.type,
      title: notif.title,
      body: notif.subtitle,
      procedureId: notif.procedureId,
      repo: widget.repo,
      context: context,
      popCurrentRoute: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: user == null
                ? Padding(
                    padding: const EdgeInsets.all(22),
                    child: Text(
                      'Sign in to see your notifications.',
                      style: ProcedureSelectionTypography.body(
                        size: 12,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                  )
                : StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                    stream: NotificationsStore.streamDocsForCurrentUser(),
                    builder: (context, snap) {
                      final docs = snap.data ?? const [];
                      final notifs = docs.map(_notifFromDoc).toList();
                      final newCount = notifs.where((n) => n.unread).length;

                      return ListView(
                        padding: const EdgeInsets.only(bottom: 40),
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _NotificationsCircleButton(
                                  icon: Icons.chevron_left_rounded,
                                  onTap: () => Navigator.of(context).maybePop(),
                                ),
                                Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(999),
                                    onTap: _markAllRead,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      child: Text(
                                        'Mark all read',
                                        style: ProcedureSelectionTypography.label(
                                          size: 11,
                                          weight: FontWeight.w600,
                                          color: ProcedureSelectionTheme.sectionLabel,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const ProcedureSectionLabel('Inbox'),
                                const SizedBox(height: 8),
                                Text(
                                  'Notifications',
                                  style: ProcedureSelectionTypography.display(
                                    size: 18,
                                    color: ProcedureSelectionTheme.ink,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text.rich(
                                  TextSpan(
                                    style: ProcedureSelectionTypography.body(
                                      size: 11,
                                      color: ProcedureSelectionTheme.muted,
                                    ),
                                    children: [
                                      const TextSpan(text: 'You have '),
                                      TextSpan(
                                        text: '$newCount new',
                                        style: ProcedureSelectionTypography.label(
                                          size: 11,
                                          weight: FontWeight.w700,
                                          color: ProcedureSelectionTheme.ink,
                                        ),
                                      ),
                                      const TextSpan(text: ' unread.'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          if (snap.connectionState == ConnectionState.waiting)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: ProcedureSelectionPanel(
                                title: 'Loading',
                                compactTitle: true,
                                child: Text(
                                  'Fetching your notifications…',
                                  style: ProcedureSelectionTypography.body(
                                    size: 11,
                                    color: ProcedureSelectionTheme.muted,
                                  ),
                                ),
                              ),
                            )
                          else if (snap.hasError)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: ProcedureSelectionPanel(
                                title: 'Something went wrong',
                                compactTitle: true,
                                child: Text(
                                  'Could not load notifications.',
                                  style: ProcedureSelectionTypography.body(
                                    size: 11,
                                    color: const Color(0xFFE8502A),
                                  ),
                                ),
                              ),
                            )
                          else if (notifs.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: ProcedureSelectionPanel(
                                title: 'All caught up',
                                compactTitle: true,
                                child: Text(
                                  'No notifications yet.',
                                  style: ProcedureSelectionTypography.body(
                                    size: 11,
                                    color: ProcedureSelectionTheme.muted,
                                  ),
                                ),
                              ),
                            )
                          else ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                              child: const ProcedureSectionLabel('All'),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                children: [
                                  for (final n in notifs) ...[
                                    _NotifRow(
                                      notif: n,
                                      onTap: () => _openNotification(n),
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _NotificationsCircleButton extends StatelessWidget {
  const _NotificationsCircleButton({required this.icon, required this.onTap});

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

class _NotifRow extends StatelessWidget {
  const _NotifRow({required this.notif, required this.onTap});

  final _Notif notif;
  final VoidCallback onTap;

  static (IconData icon, Color iconColor, bool darkBadge) _palette(_NotifKind kind) {
    return switch (kind) {
      _NotifKind.checkpoint => (Icons.shield_outlined, const Color(0xFF6B5FA8), false),
      _NotifKind.ai => (Icons.auto_awesome_rounded, Colors.white, true),
      _NotifKind.glow => (Icons.star_outline_rounded, const Color(0xFFC4607A), false),
      _NotifKind.redo => (Icons.notifications_none_rounded, const Color(0xFFE8502A), false),
      _NotifKind.tip => (Icons.lightbulb_outline_rounded, const Color(0xFF2D7A4A), false),
      _NotifKind.report => (Icons.bar_chart_rounded, const Color(0xFFC47040), false),
      _NotifKind.export => (Icons.file_upload_outlined, const Color(0xFF3A6AB0), false),
    };
  }

  @override
  Widget build(BuildContext context) {
    final read = !notif.unread;
    final (icon, iconColor, darkBadge) = _palette(notif.kind);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (notif.unread)
                  Padding(
                    padding: const EdgeInsets.only(top: 14, right: 8),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: ProcedureSelectionTheme.buttonPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 15),
                Opacity(
                  opacity: read ? 0.72 : 1,
                  child: _NotifIconBadge(
                    icon: icon,
                    iconColor: iconColor,
                    dark: darkBadge,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notif.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.label(
                          size: 12,
                          weight: read ? FontWeight.w500 : FontWeight.w700,
                          color: read ? ProcedureSelectionTheme.muted : ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notif.subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.body(
                          size: 10,
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
      ),
    );
  }
}

class _NotifIconBadge extends StatelessWidget {
  const _NotifIconBadge({
    required this.icon,
    required this.iconColor,
    required this.dark,
  });

  final IconData icon;
  final Color iconColor;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    if (dark) {
      return Container(
        width: 38,
        height: 38,
        decoration: const BoxDecoration(
          color: ProcedureSelectionTheme.buttonPrimary,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 17, color: iconColor),
      );
    }

    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: ProcedureGlassDecorations.iconBadge(selected: false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: ProcedureGlassDecorations.polishSheenGradient(opacity: 0.12),
            ),
          ),
          Center(child: Icon(icon, size: 17, color: iconColor)),
        ],
      ),
    );
  }
}
