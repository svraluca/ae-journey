import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/procedure_repository.dart';
import '../services/saved_glow_ups_store.dart';
import 'glow_up_results_community_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

class SavedGlowUpsScreen extends StatelessWidget {
  const SavedGlowUpsScreen({super.key, required this.repo});

  final ProcedureRepository repo;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final store = SavedGlowUpsStore.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Step2WarmBackground(),
          AnimatedBuilder(
            animation: store,
            builder: (context, _) {
              final items = store.items;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: topPad + 6)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                            color: ProcedureSelectionTheme.ink,
                            visualDensity: VisualDensity.compact,
                          ),
                          Expanded(
                            child: Text(
                              'Saved Glow Ups',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: ProcedureSelectionTheme.ink,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                          Text(
                            '${items.length}',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        'Glow Up results you saved from the community.',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  if (items.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ProcedureGlassSurface(
                              borderRadius: BorderRadius.circular(24),
                              compact: true,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.favorite_border_rounded,
                                      size: 28,
                                      color: ProcedureSelectionTheme.ink.withValues(alpha: 0.55),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      'No saved Glow Ups yet',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: ProcedureSelectionTheme.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Tap the heart on a community result to save it here.',
                                      textAlign: TextAlign.center,
                                      style: GoogleFonts.plusJakartaSans(
                                        fontSize: 11,
                                        height: 1.4,
                                        color: ProcedureSelectionTheme.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 18),
                                    FilledButton(
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) =>
                                                GlowUpResultsCommunityScreen(repo: repo),
                                          ),
                                        );
                                      },
                                      style: FilledButton.styleFrom(
                                        backgroundColor: ProcedureSelectionTheme.buttonPrimary,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                      ),
                                      child: Text(
                                        'Browse community',
                                        style: GoogleFonts.plusJakartaSans(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: bottomPad + 40),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomPad + 24),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          mainAxisExtent: 172,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final e = items[i];
                            return _SavedGlowUpCard(
                              entry: e,
                              onOpen: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        GlowUpResultsCommunityScreen(repo: repo),
                                  ),
                                );
                              },
                              onUnsave: () => store.remove(e),
                            );
                          },
                          childCount: items.length,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SavedGlowUpCard extends StatelessWidget {
  const _SavedGlowUpCard({
    required this.entry,
    required this.onOpen,
    required this.onUnsave,
  });

  final SavedGlowUpEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onUnsave;

  static final _radius = BorderRadius.circular(ProcedureSelectionTheme.cardRadius);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        borderRadius: _radius,
        child: ProcedureGlassSurface(
          borderRadius: _radius,
          compact: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(ProcedureSelectionTheme.cardRadius),
                    topRight: Radius.circular(ProcedureSelectionTheme.cardRadius),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ColoredBox(
                              color: const Color(0xFF8A8A93).withValues(alpha: 0.22),
                            ),
                          ),
                          Expanded(
                            child: ColoredBox(
                              color: const Color(0xFF1A1A1F).withValues(alpha: 0.28),
                            ),
                          ),
                        ],
                      ),
                      Center(
                        child: Container(
                          width: 1,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: _label('BEFORE'),
                                ),
                              ),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: _label('AFTER'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.78),
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: ColorFiltered(
                                  colorFilter: const ColorFilter.mode(
                                    ProcedureSelectionTheme.ink,
                                    BlendMode.srcIn,
                                  ),
                                  child: Image.asset(
                                    entry.iconAsset,
                                    width: 11,
                                    height: 11,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  entry.procedure,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: ProcedureSelectionTheme.ink,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.78),
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.calendar_today_outlined,
                                  size: 10,
                                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.85),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  entry.duration,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: ProcedureSelectionTheme.ink,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: onUnsave,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.85),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 5,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.favorite_rounded,
                          size: 14,
                          color: Color(0xFFE2556B),
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

  Widget _label(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 7,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
          height: 1,
        ),
      ),
    );
  }
}
