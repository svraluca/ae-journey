import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class BottomNav extends StatelessWidget {
  const BottomNav({
    super.key,
    required this.index,
    required this.onChanged,
    required this.onAddPressed,
  });

  /// Active tab: 0 Home · 1 Explore · 2 Community · 3 Profile.
  final int index;
  final ValueChanged<int> onChanged;
  final VoidCallback onAddPressed;

  static const _ink = Color(0xFF1A1A1A);
  static const _muted = Color(0xFFB0B0B0);
  static const _barHeight = 72.0;
  static const _trackSize = 48.0;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 0, 18, bottomPad + 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(_barHeight / 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: SizedBox(
          height: _barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Expanded(
                  child: _NavItem(
                    icon: Icons.home_rounded,
                    label: 'Home',
                    active: index == 0,
                    onTap: () => onChanged(0),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.explore_outlined,
                    label: 'Explore',
                    active: index == 1,
                    onTap: () => onChanged(1),
                  ),
                ),
                Expanded(
                  child: _TrackItem(onTap: onAddPressed),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.people_outline_rounded,
                    label: 'Community',
                    active: index == 2,
                    onTap: () => onChanged(2),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.person_outline_rounded,
                    label: 'Profile',
                    active: index == 3,
                    onTap: () => onChanged(3),
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? BottomNav._ink : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              icon,
              size: 22,
              color: active ? Colors.white : BottomNav._muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? BottomNav._ink : BottomNav._muted,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackItem extends StatelessWidget {
  const _TrackItem({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: BottomNav._trackSize,
            height: BottomNav._trackSize,
            decoration: BoxDecoration(
              color: BottomNav._ink,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: BottomNav._ink.withValues(alpha: 0.22),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: const Icon(Icons.add_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 2),
          Text(
            'Track',
            style: GoogleFonts.plusJakartaSans(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: BottomNav._muted,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
