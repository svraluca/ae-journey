import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/glow_up_history_store.dart';
import 'glow_up_result_screen.dart';
import 'photo_storage.dart';

const _bg = Color(0xFF0C0C0E);
const _surface = Color(0xFF111115);
const _border = Color(0xFF1E1E24);
const _cyan = Color(0xFF22D3EE);

/// Past Glow Up transformations — before/after thumbnails and dates.
class GlowUpHistoryScreen extends StatefulWidget {
  const GlowUpHistoryScreen({super.key});

  @override
  State<GlowUpHistoryScreen> createState() => _GlowUpHistoryScreenState();
}

class _GlowUpHistoryScreenState extends State<GlowUpHistoryScreen> {
  List<GlowUpHistoryEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await GlowUpHistoryStore.list();
    if (!mounted) return;
    setState(() {
      _entries = items;
      _loading = false;
    });
  }

  void _openEntry(GlowUpHistoryEntry entry) {
    final analysis = entry.toAnalysisResult();
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => GlowUpResultScreen(
          photoPath: entry.beforeForDisplay,
          analysis: analysis,
          fromHistory: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  _NavCircleBtn(
                    icon: Icons.chevron_left,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          'GLOW UP AI',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.2,
                            color: Colors.white.withValues(alpha: 0.28),
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Transformation history',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _cyan,
                      ),
                    )
                  : _entries.isEmpty
                      ? const _EmptyHistory()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            return _HistoryCard(
                              entry: _entries[index],
                              onTap: () => _openEntry(_entries[index]),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 40,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 14),
            Text(
              'No transformations yet',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Complete a Glow Up scan and your before/after results will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.onTap});

  final GlowUpHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('d MMM yyyy · HH:mm').format(entry.createdAt.toLocal());
    final after = entry.afterForDisplay;

    return Material(
      color: _surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border, width: 0.5),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ThumbColumn(
                      label: 'Before',
                      path: entry.sliderBeforeForDisplay ?? entry.beforeForDisplay,
                      fallbackPath: entry.sliderBeforeLocalPath ?? entry.beforeLocalPath,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 16,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ThumbColumn(
                      label: 'After',
                      path: entry.sliderAfterForDisplay ??
                          after ??
                          entry.beforeForDisplay,
                      fallbackPath: entry.sliderAfterLocalPath ?? entry.afterLocalPath,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.calendar_today_outlined,
                    size: 12,
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      date,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  Text(
                    '${entry.glowScore} → ${entry.potentialScore}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: _cyan.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbColumn extends StatelessWidget {
  const _ThumbColumn({
    required this.label,
    required this.path,
    this.fallbackPath,
  });

  final String label;
  final String path;
  final String? fallbackPath;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label.toUpperCase(),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 4 / 5,
            child: _HistoryImage(path: path, fallbackPath: fallbackPath),
          ),
        ),
      ],
    );
  }
}

class _HistoryImage extends StatelessWidget {
  const _HistoryImage({required this.path, this.fallbackPath});

  final String path;
  final String? fallbackPath;

  @override
  Widget build(BuildContext context) {
    final primary = path.trim();
    final fallback = (fallbackPath ?? '').trim();
    final display = _resolveDisplayPath(primary, fallback);
    if (display == null) {
      return ColoredBox(
        color: const Color(0xFF1A1A1F),
        child: Icon(
          Icons.image_not_supported_outlined,
          color: Colors.white.withValues(alpha: 0.2),
        ),
      );
    }
    return Image(
      image: isRemoteUrl(display)
          ? NetworkImage(display)
          : FileImage(File(display)),
      fit: BoxFit.contain,
      alignment: Alignment.center,
      errorBuilder: (context, error, stackTrace) {
        final alt = _resolveDisplayPath(fallback, null);
        if (alt != null && alt != display) {
          return Image(
            image: isRemoteUrl(alt) ? NetworkImage(alt) : FileImage(File(alt)),
            fit: BoxFit.contain,
            alignment: Alignment.center,
            errorBuilder: (_, _a, _b) => _brokenThumb(),
          );
        }
        return _brokenThumb();
      },
    );
  }

  static Widget _brokenThumb() {
    return ColoredBox(
      color: const Color(0xFF1A1A1F),
      child: Icon(
        Icons.broken_image_outlined,
        color: Colors.white.withValues(alpha: 0.2),
      ),
    );
  }
}

String? _resolveDisplayPath(String primary, String? fallback) {
  final p = primary.trim();
  if (p.isNotEmpty) {
    if (isRemoteUrl(p)) return p;
    if (File(p).existsSync()) return p;
  }
  final f = (fallback ?? '').trim();
  if (f.isNotEmpty) {
    if (isRemoteUrl(f)) return f;
    if (File(f).existsSync()) return f;
  }
  return null;
}

class _NavCircleBtn extends StatelessWidget {
  const _NavCircleBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.85)),
        ),
      ),
    );
  }
}
