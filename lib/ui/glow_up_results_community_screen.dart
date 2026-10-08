import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../data/community_post.dart';
import '../data/procedure_repository.dart';
import '../services/progress_share_service.dart';
import '../services/saved_glow_ups_store.dart';
import '../services/session_prefs.dart';
import 'community_glow_up_viewer_screen.dart';
import 'location_change_sheet.dart';
import 'procedure_detail_screen.dart';
import 'procedure_selection_theme.dart';
import 'saved_glow_ups_screen.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

enum _CommunityCategory { all, skin, injectables, face, body, breasts, hair }

enum _GenderFilter { all, women, men }

enum _SortMode { mostRecent, oldest, nameAsc }

class _CommunityPost {
  const _CommunityPost({
    required this.procedure,
    required this.area,
    required this.category,
    required this.duration,
    required this.daysAgo,
    required this.gender,
    required this.userName,
    required this.iconAsset,
    this.clinic,
    this.doctor,
    this.product,
    this.volumeMl,
    this.beforePhotoUrl,
    this.afterPhotoUrl,
    this.isLive = false,
    this.procedureId,
    this.ownerUid,
    this.procedureDate,
  });

  final String procedure;
  final String area;
  final _CommunityCategory category;
  final String duration;
  final int daysAgo;
  final _GenderFilter gender;
  final String userName;
  final String iconAsset;
  final String? clinic;
  final String? doctor;
  final String? product;
  final double? volumeMl;
  final String? beforePhotoUrl;
  final String? afterPhotoUrl;
  final bool isLive;
  final String? procedureId;
  final String? ownerUid;
  final DateTime? procedureDate;

  bool get hasPhotos {
    final b = (beforePhotoUrl ?? '').trim();
    final a = (afterPhotoUrl ?? '').trim();
    return (b.startsWith('http')) || (a.startsWith('http'));
  }
}

class GlowUpResultsCommunityScreen extends StatefulWidget {
  const GlowUpResultsCommunityScreen({
    super.key,
    required this.repo,
    this.embeddedInShell = false,
  });

  final ProcedureRepository repo;

  /// When true (bottom-nav tab), hide the back button.
  final bool embeddedInShell;

  @override
  State<GlowUpResultsCommunityScreen> createState() =>
      _GlowUpResultsCommunityScreenState();
}

class _GlowUpResultsCommunityScreenState
    extends State<GlowUpResultsCommunityScreen> {
  static const _ink = ProcedureSelectionTheme.ink;
  static const _muted = ProcedureSelectionTheme.muted;

  _CommunityCategory _category = _CommunityCategory.all;
  String _city = 'Worldwide';
  String? _procedureFilter;
  String? _areaFilter;
  _GenderFilter _genderFilter = _GenderFilter.all;
  _SortMode _sortMode = _SortMode.mostRecent;

  List<_CommunityPost> _livePosts = const [];
  StreamSubscription<List<CommunityPost>>? _liveSub;
  bool _liveLoading = true;

  static const _pageSize = 6;

  int _visibleCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _liveSub = widget.repo.communityPostsStream().listen(
      (posts) {
        if (!mounted) return;
        setState(() {
          _livePosts = posts.map(_fromLive).toList(growable: false);
          _liveLoading = false;
          _resetPage();
        });
      },
      onError: (e) {
        debugPrint('[Community] live stream failed: $e');
        if (!mounted) return;
        setState(() => _liveLoading = false);
      },
    );
  }

  @override
  void dispose() {
    _liveSub?.cancel();
    super.dispose();
  }

  static _CommunityCategory _categoryFrom(String? category, String title) {
    final s = '${category ?? ''} $title'.toLowerCase();
    if (s.contains('breast')) return _CommunityCategory.breasts;
    if (s.contains('hair')) return _CommunityCategory.hair;
    if (s.contains('lipo') ||
        s.contains('body') ||
        s.contains('abdomen') ||
        s.contains('butt') ||
        s.contains('arm')) {
      return _CommunityCategory.body;
    }
    if (s.contains('botox') ||
        s.contains('filler') ||
        s.contains('inject') ||
        s.contains('sculptra') ||
        s.contains('biostim')) {
      return _CommunityCategory.injectables;
    }
    if (s.contains('skin') ||
        s.contains('laser') ||
        s.contains('microneed') ||
        s.contains('poly') ||
        s.contains('peel')) {
      return _CommunityCategory.skin;
    }
    return _CommunityCategory.face;
  }

  static String _iconFor(_CommunityCategory category) {
    return switch (category) {
      _CommunityCategory.skin => 'assets/microneedeling.png',
      _CommunityCategory.injectables => 'assets/injection.png',
      _CommunityCategory.face => 'assets/faceicon.png',
      _CommunityCategory.body => 'assets/liposuction.png',
      _CommunityCategory.breasts => 'assets/breasticon.png',
      _CommunityCategory.hair => 'assets/hairtransplant.png',
      _CommunityCategory.all => 'assets/staricon.png',
    };
  }

  static String _relativeLabel(DateTime when) {
    final days = DateTime.now().difference(when).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return '1 day ago';
    if (days < 7) return '$days days ago';
    final weeks = (days / 7).floor();
    if (weeks < 5) return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
    final months = (days / 30).floor().clamp(1, 24);
    return months == 1 ? '1 month ago' : '$months months ago';
  }

  static _CommunityPost _fromLive(CommunityPost post) {
    final category = _categoryFrom(post.category, post.title);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final isMine = uid != null && uid == post.ownerUid;
    final name = (post.ownerDisplayName ?? '').trim();
    return _CommunityPost(
      procedure: post.title,
      area: post.zoneLabel,
      category: category,
      duration: _relativeLabel(post.postedAt),
      daysAgo: DateTime.now().difference(post.postedAt).inDays.clamp(0, 9999),
      gender: _GenderFilter.all,
      userName: isMine ? 'You' : (name.isEmpty ? 'Member' : name),
      iconAsset: _iconFor(category),
      clinic: post.clinic,
      doctor: post.practitioner,
      product: post.product,
      volumeMl: post.volumeMl,
      beforePhotoUrl: post.beforePhotoUrl,
      afterPhotoUrl: post.afterPhotoUrl,
      isLive: true,
      procedureId: post.procedureId,
      ownerUid: post.ownerUid,
      procedureDate: post.date,
    );
  }

  List<_CommunityPost> get _allPosts => _livePosts;

  List<String> get _procedureOptions =>
      (_allPosts.map((p) => p.procedure).toSet().toList()..sort());

  List<String> get _areaOptions =>
      (_allPosts.map((p) => p.area).toSet().toList()..sort());

  String get _procedureChipLabel => _procedureFilter ?? 'All procedures';
  String get _areaChipLabel => _areaFilter ?? 'All areas';
  String get _genderChipLabel => switch (_genderFilter) {
        _GenderFilter.all => 'All genders',
        _GenderFilter.women => 'Women',
        _GenderFilter.men => 'Men',
      };
  String get _sortChipLabel => switch (_sortMode) {
        _SortMode.mostRecent => 'Most recent',
        _SortMode.oldest => 'Oldest',
        _SortMode.nameAsc => 'A–Z',
      };

  bool get _filtersActive =>
      _procedureFilter != null ||
      _areaFilter != null ||
      _genderFilter != _GenderFilter.all ||
      _sortMode != _SortMode.mostRecent;

  List<_CommunityPost> get _filtered {
    var list = _allPosts.where((p) {
      if (_category != _CommunityCategory.all && p.category != _category) {
        return false;
      }
      if (_procedureFilter != null && p.procedure != _procedureFilter) {
        return false;
      }
      if (_areaFilter != null && p.area != _areaFilter) return false;
      // Live posts have no gender metadata — keep them visible for any gender chip.
      if (_genderFilter != _GenderFilter.all &&
          !p.isLive &&
          p.gender != _genderFilter) {
        return false;
      }
      return true;
    }).toList();

    switch (_sortMode) {
      case _SortMode.mostRecent:
        list.sort((a, b) {
          if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
          return a.daysAgo.compareTo(b.daysAgo);
        });
      case _SortMode.oldest:
        list.sort((a, b) {
          if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
          return b.daysAgo.compareTo(a.daysAgo);
        });
      case _SortMode.nameAsc:
        list.sort((a, b) {
          if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
          return a.procedure.compareTo(b.procedure);
        });
    }
    return list;
  }

  List<_CommunityPost> get _visiblePosts {
    final all = _filtered;
    return all.take(_visibleCount.clamp(0, all.length)).toList();
  }

  void _resetPage() => _visibleCount = _pageSize;

  void _loadMore() {
    setState(() => _visibleCount += _pageSize);
  }

  Future<_FilterPick?> _showPickSheet({
    required String title,
    required List<_FilterPick> options,
    required String currentId,
  }) {
    return showModalBottomSheet<_FilterPick>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) {
        final bottomPad = MediaQuery.paddingOf(ctx).bottom;
        return Material(
          color: const Color(0xFF000000),
          elevation: 24,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
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
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                    child: Text(
                      title,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final opt in options)
                          ListTile(
                            dense: true,
                            title: Text(
                              opt.label,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(
                                  alpha: opt.id == currentId ? 1 : 0.82,
                                ),
                              ),
                            ),
                            trailing: opt.id == currentId
                                ? Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: Colors.white.withValues(alpha: 0.92),
                                  )
                                : null,
                            onTap: () => Navigator.pop(ctx, opt),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickProcedure() async {
    final picked = await _showPickSheet(
      title: 'Procedure',
      currentId: _procedureFilter ?? '__all__',
      options: [
        const _FilterPick(id: '__all__', label: 'All procedures'),
        for (final p in _procedureOptions) _FilterPick(id: p, label: p),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _procedureFilter = picked.id == '__all__' ? null : picked.id;
      _resetPage();
    });
  }

  Future<void> _pickArea() async {
    final picked = await _showPickSheet(
      title: 'Area',
      currentId: _areaFilter ?? '__all__',
      options: [
        const _FilterPick(id: '__all__', label: 'All areas'),
        for (final a in _areaOptions) _FilterPick(id: a, label: a),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _areaFilter = picked.id == '__all__' ? null : picked.id;
      _resetPage();
    });
  }

  Future<void> _pickGender() async {
    final picked = await _showPickSheet(
      title: 'Gender',
      currentId: _genderFilter.name,
      options: const [
        _FilterPick(id: 'all', label: 'All genders'),
        _FilterPick(id: 'women', label: 'Women'),
        _FilterPick(id: 'men', label: 'Men'),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _genderFilter = switch (picked.id) {
        'women' => _GenderFilter.women,
        'men' => _GenderFilter.men,
        _ => _GenderFilter.all,
      };
      _resetPage();
    });
  }

  Future<void> _pickSort() async {
    final picked = await _showPickSheet(
      title: 'Sort by',
      currentId: _sortMode.name,
      options: const [
        _FilterPick(id: 'mostRecent', label: 'Most recent'),
        _FilterPick(id: 'oldest', label: 'Oldest'),
        _FilterPick(id: 'nameAsc', label: 'A–Z'),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _sortMode = switch (picked.id) {
        'oldest' => _SortMode.oldest,
        'nameAsc' => _SortMode.nameAsc,
        _ => _SortMode.mostRecent,
      };
      _resetPage();
    });
  }

  Future<void> _openFiltersSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (ctx) {
        final bottomPad = MediaQuery.paddingOf(ctx).bottom;
        final titleStyle = GoogleFonts.plusJakartaSans(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.92),
        );
        final subtitleStyle = GoogleFonts.plusJakartaSans(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.55),
        );
        final chevron = Icon(
          Icons.chevron_right_rounded,
          size: 18,
          color: Colors.white.withValues(alpha: 0.45),
        );

        return Material(
          color: const Color(0xFF000000),
          elevation: 24,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, 0, 8, bottomPad > 16 ? bottomPad : 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                    padding: const EdgeInsets.fromLTRB(14, 16, 6, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Filters',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _procedureFilter = null;
                              _areaFilter = null;
                              _genderFilter = _GenderFilter.all;
                              _sortMode = _SortMode.mostRecent;
                              _resetPage();
                            });
                            Navigator.pop(ctx);
                          },
                          child: Text(
                            'Reset',
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    dense: true,
                    title: Text('Procedure', style: titleStyle),
                    subtitle: Text(_procedureChipLabel, style: subtitleStyle),
                    trailing: chevron,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _pickProcedure();
                    },
                  ),
                  ListTile(
                    dense: true,
                    title: Text('Area', style: titleStyle),
                    subtitle: Text(_areaChipLabel, style: subtitleStyle),
                    trailing: chevron,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _pickArea();
                    },
                  ),
                  ListTile(
                    dense: true,
                    title: Text('Gender', style: titleStyle),
                    subtitle: Text(_genderChipLabel, style: subtitleStyle),
                    trailing: chevron,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _pickGender();
                    },
                  ),
                  ListTile(
                    dense: true,
                    title: Text('Sort', style: titleStyle),
                    subtitle: Text(_sortChipLabel, style: subtitleStyle),
                    trailing: chevron,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _pickSort();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openPost(_CommunityPost post) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final procedureId = (post.procedureId ?? '').trim();
    final isOwnUpload = uid != null &&
        uid == (post.ownerUid ?? '') &&
        procedureId.isNotEmpty &&
        widget.repo.getDoneById(procedureId) != null;

    // Your own live upload → full procedure detail (owner).
    // Anyone else's upload → read-only viewer perspective.
    if (isOwnUpload) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProcedureDetailScreen(
            repo: widget.repo,
            procedureId: procedureId,
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommunityGlowUpViewerScreen(
          post: _toShareView(post),
        ),
      ),
    );
  }

  CommunityGlowUpView _toShareView(_CommunityPost post) {
    return CommunityGlowUpView(
      procedure: post.procedure,
      area: post.area,
      duration: post.duration,
      daysAgo: post.daysAgo,
      userName: post.userName,
      iconAsset: post.iconAsset,
      clinic: post.clinic,
      doctor: post.doctor,
      product: post.product,
      volumeMl: post.volumeMl,
      beforePhotoUrl: post.beforePhotoUrl,
      afterPhotoUrl: post.afterPhotoUrl,
      procedureDate: post.procedureDate,
    );
  }

  Future<void> _sharePost(_CommunityPost post, BuildContext buttonContext) async {
    final origin = ProgressShareService.originFromContext(buttonContext);
    try {
      // Own live post → share the real procedure (includes BA photos from passport).
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final procedureId = (post.procedureId ?? '').trim();
      final own = uid != null &&
          uid == (post.ownerUid ?? '') &&
          procedureId.isNotEmpty;
      if (own) {
        final procedure = widget.repo.getDoneById(procedureId);
        if (procedure != null) {
          await ProgressShareService.instance.shareProcedure(
            procedure: procedure,
            areaFallback: post.area,
            sharePositionOrigin: origin,
          );
          return;
        }
      }

      await ProgressShareService.instance.shareCommunityView(
        _toShareView(post),
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is StateError ? e.message : 'Could not share right now. Try again.',
          ),
        ),
      );
    }
  }

  Future<void> _openLocationSheet() async {
    final picked = await showLocationChangeSheet(context, selectedCity: _city);
    if (picked == null || !mounted) return;
    try {
      await SessionPrefs.setCompareSearchCity(picked.displayName);
      await SessionPrefs.setCompareSearchCityIdentity(picked);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _city = picked.displayName);
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom +
        (widget.embeddedInShell ? 96 : 0);
    final allPosts = _filtered;
    final posts = _visiblePosts;
    final canLoadMore = posts.length < allPosts.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          if (!widget.embeddedInShell) const Step2WarmBackground(),
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: topPad + 6)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
                  child: Row(
                    children: [
                      if (!widget.embeddedInShell)
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 16,
                          ),
                          color: _ink,
                          visualDensity: VisualDensity.compact,
                        )
                      else
                        const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Glow Up results community',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _ink,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      AnimatedBuilder(
                        animation: SavedGlowUpsStore.instance,
                        builder: (context, _) {
                          final count = SavedGlowUpsStore.instance.items.length;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => SavedGlowUpsScreen(repo: widget.repo),
                                  ),
                                );
                              },
                              borderRadius: BorderRadius.circular(999),
                              child: ProcedureGlassSurface(
                                borderRadius: BorderRadius.circular(999),
                                compact: true,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 7,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        count > 0
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        size: 14,
                                        color: count > 0
                                            ? const Color(0xFFE2556B)
                                            : ProcedureSelectionTheme.ink,
                                      ),
                                      if (count > 0) ...[
                                        const SizedBox(width: 4),
                                        Text(
                                          '$count',
                                          style: GoogleFonts.plusJakartaSans(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: ProcedureSelectionTheme.ink,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      if (_livePosts.isNotEmpty) ...[
                        const _AvatarStack(),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          _liveLoading
                              ? 'Loading live results…'
                              : _livePosts.isEmpty
                                  ? 'No live results yet'
                                  : '${_livePosts.length} live · community',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _livePosts.isEmpty ? _muted : _ink,
                          ),
                        ),
                      ),
                      _LocationChip(
                        city: _city,
                        onTap: _openLocationSheet,
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 32,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _CategoryPill(
                        label: 'All',
                        iconAsset: 'assets/staricon.png',
                        selected: _category == _CommunityCategory.all,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.all;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Skin',
                        iconAsset: 'assets/microneedelingicon.png',
                        selected: _category == _CommunityCategory.skin,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.skin;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Injectables',
                        iconAsset: 'assets/injection.png',
                        selected: _category == _CommunityCategory.injectables,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.injectables;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Face',
                        iconAsset: 'assets/faceicon.png',
                        selected: _category == _CommunityCategory.face,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.face;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Body',
                        iconAsset: 'assets/bodyicon.png',
                        selected: _category == _CommunityCategory.body,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.body;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Breasts',
                        iconAsset: 'assets/breasticon.png',
                        selected: _category == _CommunityCategory.breasts,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.breasts;
                          _visibleCount = _pageSize;
                        }),
                      ),
                      const SizedBox(width: 6),
                      _CategoryPill(
                        label: 'Hair',
                        iconAsset: 'assets/hairtransplant.png',
                        selected: _category == _CommunityCategory.hair,
                        onTap: () => setState(() {
                          _category = _CommunityCategory.hair;
                          _visibleCount = _pageSize;
                        }),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 10)),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 28,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _FilterIconButton(
                        active: _filtersActive,
                        onTap: _openFiltersSheet,
                      ),
                      const SizedBox(width: 6),
                      _FilterChip(
                        label: _procedureChipLabel,
                        active: _procedureFilter != null,
                        onTap: _pickProcedure,
                      ),
                      const SizedBox(width: 6),
                      _FilterChip(
                        label: _areaChipLabel,
                        active: _areaFilter != null,
                        onTap: _pickArea,
                      ),
                      const SizedBox(width: 6),
                      _FilterChip(
                        label: _genderChipLabel,
                        active: _genderFilter != _GenderFilter.all,
                        onTap: _pickGender,
                      ),
                      const SizedBox(width: 6),
                      _FilterChip(
                        label: _sortChipLabel,
                        active: _sortMode != _SortMode.mostRecent,
                        onTap: _pickSort,
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              if (_liveLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 40, 20, 20),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                )
              else if (posts.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
                    child: ProcedureGlassSurface(
                      borderRadius: BorderRadius.circular(18),
                      compact: true,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                        child: Column(
                          children: [
                            Icon(
                              Icons.visibility_outlined,
                              size: 22,
                              color: _muted,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'No live procedures yet',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: _ink,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Turn on Post live when you save a passport entry to share your before & after here.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: _muted,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 8,
                      mainAxisExtent: 196,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        return _CommunityPostCard(
                          post: posts[i],
                          onTap: () => _openPost(posts[i]),
                          onShare: (btnCtx) => _sharePost(posts[i], btnCtx),
                        );
                      },
                      childCount: posts.length,
                    ),
                  ),
                ),
              if (!_liveLoading && canLoadMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(10, 12, 10, bottomPad + 20),
                    child: _LoadMoreButton(onTap: _loadMore),
                  ),
                )
              else
                SliverToBoxAdapter(child: SizedBox(height: bottomPad + 20)),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarStack extends StatelessWidget {
  const _AvatarStack();

  static const _colors = [
    Color(0xFFD4C4B0),
    Color(0xFFB8A99A),
    Color(0xFF9A8B7A),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 22,
      child: Stack(
        children: [
          for (var i = 0; i < _colors.length; i++)
            Positioned(
              left: i * 12.0,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _colors[i],
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.city, required this.onTap});

  final String city;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.place_rounded,
                  size: 13,
                  color: ProcedureSelectionTheme.ink,
                ),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      city,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: ProcedureSelectionTheme.ink,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      'Change',
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                        color: ProcedureSelectionTheme.sectionLabel,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({
    required this.label,
    required this.iconAsset,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String iconAsset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = selected ? Colors.white : ProcedureSelectionTheme.ink;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: selected
                ? ProcedureSelectionTheme.buttonPrimary
                : Colors.white.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? ProcedureSelectionTheme.buttonPrimary
                  : Colors.white.withValues(alpha: 0.9),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColorFiltered(
                colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
                child: Image.asset(
                  iconAsset,
                  width: 13,
                  height: 13,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterPick {
  const _FilterPick({required this.id, required this.label});

  final String id;
  final String label;
}

class _FilterIconButton extends StatelessWidget {
  const _FilterIconButton({required this.onTap, this.active = false});

  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(999),
          compact: true,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(
              Icons.tune_rounded,
              size: 14,
              color: active
                  ? ProcedureSelectionTheme.ink
                  : ProcedureSelectionTheme.ink.withValues(alpha: 0.85),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 10,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: ProcedureSelectionTheme.ink.withValues(
                      alpha: active ? 0.95 : 0.7,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 13,
                  color: ProcedureSelectionTheme.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommunityPostCard extends StatelessWidget {
  const _CommunityPostCard({
    required this.post,
    required this.onTap,
    required this.onShare,
  });

  final _CommunityPost post;
  final VoidCallback onTap;
  final void Function(BuildContext buttonContext) onShare;

  static final _radius = BorderRadius.circular(14);

  bool _isHttp(String? u) {
    final v = (u ?? '').trim();
    return v.startsWith('http://') || v.startsWith('https://');
  }

  Widget _halfPhoto({required String? url, required bool before}) {
    final has = _isHttp(url);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (has)
          Image.network(
            url!.trim(),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => ColoredBox(
              color: before
                  ? const Color(0xFF8A8A93).withValues(alpha: 0.22)
                  : const Color(0xFF1A1A1F).withValues(alpha: 0.28),
            ),
          )
        else
          ColoredBox(
            color: before
                ? const Color(0xFF8A8A93).withValues(alpha: 0.22)
                : const Color(0xFF1A1A1F).withValues(alpha: 0.28),
          ),
        Positioned(
          top: 6,
          left: before ? 6 : null,
          right: before ? null : 6,
          child: _BaLabel(before ? 'BEFORE' : 'AFTER'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: _radius,
        child: ProcedureGlassSurface(
          borderRadius: _radius,
          compact: true,
          illuminated: post.isLive,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ColorFiltered(
                      colorFilter: const ColorFilter.mode(
                        ProcedureSelectionTheme.ink,
                        BlendMode.srcIn,
                      ),
                      child: Image.asset(
                        post.iconAsset,
                        width: 14,
                        height: 14,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post.procedure,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            post.isLive ? '${post.area} · ${post.userName}' : post.area,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.plusJakartaSans(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w500,
                              color: ProcedureSelectionTheme.muted,
                              height: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (post.isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: ProcedureSelectionTheme.buttonPrimary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'LIVE',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: ProcedureSelectionTheme.buttonPrimary,
                          ),
                        ),
                      ),
                    Builder(
                      builder: (btnCtx) {
                        return IconButton(
                          onPressed: () => onShare(btnCtx),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          icon: Icon(
                            Icons.ios_share_rounded,
                            size: 15,
                            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                          ),
                          tooltip: 'Share',
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.55,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _halfPhoto(
                                  url: post.beforePhotoUrl,
                                  before: true,
                                ),
                              ),
                              Expanded(
                                child: _halfPhoto(
                                  url: post.afterPhotoUrl,
                                  before: false,
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
                          Center(
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.92),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.10),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.chevron_left_rounded,
                                    size: 10,
                                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    size: 10,
                                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 9,
                      color: ProcedureSelectionTheme.muted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        post.duration,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w500,
                          color: ProcedureSelectionTheme.muted,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BaLabel extends StatelessWidget {
  const _BaLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 7,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Load more transformations',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.75),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
