import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/explore_city_identity.dart';
import '../services/explore_provider_interfaces.dart';
import '../services/filter_currency.dart';
import '../services/google_places_service.dart';
import '../services/session_prefs.dart';

/// Built-in Explore location chips (always shown under Popular).
const kExplorePopularCities = <String>[
  'Worldwide',
  'London',
  'Paris',
  'Dubai',
  'București',
  'New York',
  'Miami',
  'Los Angeles',
  'Milan',
  'Seoul',
  'Istanbul',
  'Beirut',
  'Moscow',
  'Barcelona',
];

bool isExploreBuiltInPopularCity(String city) {
  final key = city.trim().toLowerCase();
  return kExplorePopularCities.any((c) => c.toLowerCase() == key);
}

/// Opens the location picker as a full-screen page (black nav-matched chrome).
///
/// Returns a Places-resolved [ExploreCityIdentity] so Explore discovery / map
/// tabs are wired to the chosen locality (placeId + lat/lng + country).
Future<ExploreCityIdentity?> showLocationChangeSheet(
  BuildContext context, {
  required String selectedCity,
}) async {
  final route = MaterialPageRoute<ExploreCityIdentity>(
    builder: (_) => LocationChangeScreen(selectedCity: selectedCity),
  );
  final picked = await Navigator.of(context).push<ExploreCityIdentity>(route);
  // Pop resolves before its animation finishes. Keep cache validation and
  // map work out of the transition frames.
  await route.completed;
  return picked;
}

/// Tokens aligned with [BottomNav] dark pill (Instagram-style chrome).
abstract final class _LocTheme {
  static const bg = Color(0xFF0B0B0D);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceLift = Color(0xFF2C2C2E);
  static const border = Color(0x14FFFFFF);
  static const ink = Color(0xFFFFFFFF);
  static const muted = Color(0x99FFFFFF);
  static const faint = Color(0x66FFFFFF);
  static const accent = Color(0xFF1A1A2E);

  static TextStyle label({
    double size = 13,
    FontWeight weight = FontWeight.w700,
    Color? color,
  }) => GoogleFonts.plusJakartaSans(
    fontSize: size,
    fontWeight: weight,
    color: color ?? ink,
    height: 1.15,
  );

  static TextStyle body({
    double size = 11,
    FontWeight weight = FontWeight.w500,
    Color? color,
  }) => GoogleFonts.plusJakartaSans(
    fontSize: size,
    fontWeight: weight,
    color: color ?? muted,
    height: 1.35,
  );

  static TextStyle section({double size = 11}) => GoogleFonts.plusJakartaSans(
    fontSize: size,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.6,
    color: faint,
    height: 1.1,
  );
}

class _RecentPlace {
  const _RecentPlace({required this.name, required this.subtitle});

  final String name;
  final String subtitle;

  bool matchesQuery(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return true;
    return name.toLowerCase().contains(s) || subtitle.toLowerCase().contains(s);
  }
}

class LocationChangeScreen extends StatefulWidget {
  const LocationChangeScreen({
    super.key,
    required this.selectedCity,
    this.cityResolver,
  });

  final String selectedCity;
  final CityResolver? cityResolver;

  static const _defaultRecent = <_RecentPlace>[
    _RecentPlace(name: 'Worldwide', subtitle: 'International curated clinics'),
    _RecentPlace(name: 'London', subtitle: 'United Kingdom'),
    _RecentPlace(name: 'Dubai', subtitle: 'United Arab Emirates'),
  ];

  @override
  State<LocationChangeScreen> createState() => _LocationChangeScreenState();
}

class _LocationChangeScreenState extends State<LocationChangeScreen> {
  late final TextEditingController _query;
  final FocusNode _searchFocus = FocusNode();
  final GooglePlacesService _places = GooglePlacesService();
  List<String> _savedCities = const [];
  List<String> _recentCities = const [];
  List<GooglePlacesLocalityHit> _placesHits = const [];
  bool _loaded = false;
  bool _recentExpanded = false;
  bool _locating = false;
  bool _suggesting = false;
  bool _selecting = false;
  Timer? _suggestDebounce;
  int _suggestGen = 0;

  static const _kRecentPreviewCount = 2;

  @override
  void initState() {
    super.initState();
    _query = TextEditingController();
    _query.addListener(_onQueryChanged);
    _searchFocus.addListener(() => setState(() {}));
    unawaited(_loadLists());
  }

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _searchFocus.dispose();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {});
    _schedulePlacesSuggest(_query.text);
  }

  void _schedulePlacesSuggest(String raw) {
    _suggestDebounce?.cancel();
    final q = raw.trim();
    if (q.length < 2) {
      if (_placesHits.isNotEmpty || _suggesting) {
        setState(() {
          _placesHits = const [];
          _suggesting = false;
        });
      }
      return;
    }
    final gen = ++_suggestGen;
    setState(() => _suggesting = true);
    _suggestDebounce = Timer(const Duration(milliseconds: 320), () async {
      final hits = await _places.suggestLocalities(query: q, maxResults: 6);
      if (!mounted || gen != _suggestGen) return;
      setState(() {
        _placesHits = hits;
        _suggesting = false;
      });
    });
  }

  Future<void> _loadLists() async {
    try {
      final saved = await SessionPrefs.exploreSavedCities();
      final recent = await SessionPrefs.exploreRecentCities();
      if (!mounted) return;
      setState(() {
        _savedCities = saved;
        _recentCities = recent;
        _loaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  String _titleCaseCity(String raw) {
    final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return t;
    return t
        .split(' ')
        .map((w) {
          if (w.isEmpty) return w;
          if (w.length == 1) return w.toUpperCase();
          return '${w[0].toUpperCase()}${w.substring(1)}';
        })
        .join(' ');
  }

  Future<void> _pickCity(
    String city, {
    bool addToSavedList = false,
    GooglePlacesLocalityHit? placesHit,
  }) async {
    final normalized = normalizeExploreCity(_titleCaseCity(city));
    if (normalized.isEmpty || _selecting) return;

    setState(() => _selecting = true);
    _suggestDebounce?.cancel();
    _suggestGen++;

    HapticFeedback.selectionClick();

    ExploreCityIdentity? identity;
    if (placesHit != null) {
      identity = ExploreCityIdentity.resolve(
        rawCity: placesHit.name.isNotEmpty ? placesHit.name : normalized,
        countryCode: placesHit.countryCode,
        adminArea: placesHit.adminArea,
        placeId: placesHit.placeId,
        latitude: placesHit.lat,
        longitude: placesHit.lng,
      );
    } else {
      try {
        identity = await resolveExploreCitySelection(
          rawCity: normalized,
          resolver: widget.cityResolver ?? PlacesCityResolver(places: _places),
        );
      } catch (_) {
        identity = ExploreCityIdentity.resolve(rawCity: normalized);
      }
    }
    var resolved = identity ?? ExploreCityIdentity.resolve(rawCity: normalized);
    // Places 429 / timeout must not downgrade a previously resolved placeId
    // to unresolved_* / geo_* — that forks the Firestore cache key.
    if (!resolved.isResolved || resolved.placeId.trim().isEmpty) {
      try {
        final saved = await SessionPrefs.compareSearchCityIdentity();
        if (saved != null &&
            saved.isResolved &&
            saved.placeId.trim().isNotEmpty &&
            saved.matchesAliasLabel(normalized)) {
          resolved = saved;
        }
      } catch (_) {}
    }
    final display = resolved.displayName.trim().isNotEmpty
        ? resolved.displayName.trim()
        : normalized;

    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    // The comparison screen persists the selection after painting it. Only
    // the explicit "save" action for built-in cities belongs to the picker.
    if (addToSavedList &&
        isExploreBuiltInPopularCity(display) &&
        display.toLowerCase() != 'worldwide') {
      unawaited(
        SessionPrefs.addExploreSavedCity(display).catchError((Object _) {}),
      );
    }
    Navigator.of(context).pop(resolved);
  }

  Future<void> _addOnly(String city) async {
    final normalized = normalizeExploreCity(_titleCaseCity(city));
    if (normalized.isEmpty) return;
    try {
      await SessionPrefs.addExploreSavedCity(normalized);
      await SessionPrefs.pushExploreRecentCity(normalized);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _savedCities = [
        normalized,
        ..._savedCities.where(
          (c) => c.toLowerCase() != normalized.toLowerCase(),
        ),
      ];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$normalized added to your cities',
          style: _LocTheme.label(size: 13, color: _LocTheme.ink),
        ),
        backgroundColor: _LocTheme.surfaceLift,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _removeSaved(String city) async {
    try {
      await SessionPrefs.removeExploreSavedCity(city);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _savedCities = _savedCities
          .where((c) => c.toLowerCase() != city.toLowerCase())
          .toList();
    });
  }

  Future<void> _onUseCurrent() async {
    if (_selecting) return;
    if (_locating) return;
    HapticFeedback.selectionClick();
    setState(() => _locating = true);
    try {
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      if (!serviceOn) {
        _toast('Turn on Location Services to detect your city.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _toast('Location permission is needed to find clinics near you.');
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final hit = await _places.resolveLocalityFromLatLng(
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      if (hit != null) {
        await _pickCity(hit.name, placesHit: hit);
        return;
      }
      // Still wire geo even without a named locality.
      final fallback = ExploreCityIdentity.resolve(
        rawCity: 'Near me',
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      try {
        await SessionPrefs.setCompareSearchCityIdentity(fallback);
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(fallback);
    } on TimeoutException {
      _toast('Couldn’t get your location in time. Try searching a city.');
    } catch (_) {
      _toast('Couldn’t detect your location. Try searching a city.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: _LocTheme.label(size: 13)),
        backgroundColor: _LocTheme.surfaceLift,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  List<_RecentPlace> get _recentRows {
    if (_recentCities.isNotEmpty) {
      return _recentCities
          .map(
            (name) => _RecentPlace(
              name: name,
              subtitle: isExploreBuiltInPopularCity(name)
                  ? 'Popular city'
                  : 'Recently used',
            ),
          )
          .toList();
    }
    return LocationChangeScreen._defaultRecent;
  }

  bool _queryMatchesKnown(String q) {
    final key = q.trim().toLowerCase();
    if (key.isEmpty) return true;
    final known = <String>{
      ...kExplorePopularCities,
      ..._savedCities,
      ..._recentCities,
      for (final h in _placesHits) h.name,
    };
    return known.any((c) => c.toLowerCase() == key);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    final qRaw = _query.text.trim();
    final q = qRaw.toLowerCase();
    final filteredRecent = _recentRows
        .where((p) => p.matchesQuery(_query.text))
        .toList();
    final visibleRecent = (_recentExpanded || q.isNotEmpty)
        ? filteredRecent
        : filteredRecent.take(_kRecentPreviewCount).toList();
    final canExpandRecent =
        q.isEmpty && filteredRecent.length > _kRecentPreviewCount;
    final savedForChips = _savedCities
        .where((c) => !isExploreBuiltInPopularCity(c))
        .where((c) => q.isEmpty || c.toLowerCase().contains(q))
        .toList();
    final filteredPopular = q.isEmpty
        ? kExplorePopularCities
        : kExplorePopularCities
              .where((c) => c.toLowerCase().contains(q))
              .toList();
    final customQuery = qRaw.isNotEmpty && !_queryMatchesKnown(qRaw)
        ? normalizeExploreCity(_titleCaseCity(qRaw))
        : null;
    final customAlreadySaved =
        customQuery != null &&
        _savedCities.any((c) => c.toLowerCase() == customQuery.toLowerCase());
    final showPlaces = q.length >= 2 && (_placesHits.isNotEmpty || _suggesting);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _LocTheme.bg,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_selecting)
                const LinearProgressIndicator(
                  minHeight: 2,
                  color: Colors.white,
                  backgroundColor: _LocTheme.surface,
                ),
              SafeArea(
                bottom: false,
                child: _TopBar(onClose: () => Navigator.of(context).maybePop()),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(22, 6, 22, 32 + bottomPad),
                  children: [
                    _SearchField(
                      controller: _query,
                      focusNode: _searchFocus,
                      onSubmitted: (v) {
                        final t = v.trim();
                        if (t.isNotEmpty) {
                          unawaited(_pickCity(t, addToSavedList: true));
                        }
                      },
                      onClear: () => _query.clear(),
                    ),
                    if (showPlaces) ...[
                      const SizedBox(height: 14),
                      Text('GOOGLE MAPS', style: _LocTheme.section()),
                      const SizedBox(height: 8),
                      if (_suggesting && _placesHits.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white.withValues(alpha: 0.55),
                              ),
                            ),
                          ),
                        )
                      else
                        for (final hit in _placesHits)
                          _PlacesSuggestionRow(
                            hit: hit,
                            onTap: () => unawaited(
                              _pickCity(
                                hit.name,
                                addToSavedList: true,
                                placesHit: hit,
                              ),
                            ),
                          ),
                    ],
                    if (customQuery != null && !showPlaces) ...[
                      const SizedBox(height: 8),
                      _LocationActionRow(
                        icon: Icons.travel_explore_rounded,
                        filledIcon: false,
                        title: 'Search in $customQuery',
                        subtitle: customAlreadySaved
                            ? 'See clinics & prices · already in your list'
                            : 'See clinics & prices · adds to your cities',
                        onTap: () => unawaited(
                          _pickCity(customQuery, addToSavedList: true),
                        ),
                        trailing: customAlreadySaved
                            ? null
                            : IconButton(
                                tooltip: 'Add to your cities',
                                onPressed: () =>
                                    unawaited(_addOnly(customQuery)),
                                icon: Icon(
                                  Icons.add_location_alt_outlined,
                                  size: 20,
                                  color: Colors.white.withValues(alpha: 0.88),
                                ),
                              ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    _LocationActionRow(
                      icon: Icons.near_me_rounded,
                      filledIcon: true,
                      title: _locating
                          ? 'Detecting location…'
                          : 'Use current location',
                      subtitle:
                          'Google Maps · automatically detect where you are',
                      onTap: _locating
                          ? () {}
                          : () => unawaited(_onUseCurrent()),
                      trailing: _locating
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white.withValues(alpha: 0.7),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 28),
                    Text('RECENT', style: _LocTheme.section()),
                    const SizedBox(height: 6),
                    if (filteredRecent.isNotEmpty)
                      Column(
                        children: [
                          for (var i = 0; i < visibleRecent.length; i++)
                            _RecentRow(
                              place: visibleRecent[i],
                              showDivider: i < visibleRecent.length - 1,
                              onTap: () =>
                                  unawaited(_pickCity(visibleRecent[i].name)),
                            ),
                          if (canExpandRecent)
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () => setState(
                                  () => _recentExpanded = !_recentExpanded,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  child: Center(
                                    child: Text(
                                      _recentExpanded
                                          ? 'Show less'
                                          : 'Load more',
                                      style: _LocTheme.label(
                                        size: 12,
                                        weight: FontWeight.w700,
                                        color: _LocTheme.ink,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    if (savedForChips.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Text('YOUR CITIES', style: _LocTheme.section()),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final city in savedForChips)
                            _CityChip(
                              city: city,
                              selected:
                                  city.toLowerCase() ==
                                  widget.selectedCity.toLowerCase(),
                              showRemove: true,
                              onTap: () => unawaited(_pickCity(city)),
                              onRemove: () => unawaited(_removeSaved(city)),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 28),
                    Text('POPULAR CITIES', style: _LocTheme.section()),
                    const SizedBox(height: 12),
                    if (filteredPopular.isEmpty &&
                        customQuery == null &&
                        !showPlaces)
                      Text(
                        _loaded
                            ? 'No popular match — use search above, or type a city and press Search.'
                            : 'Loading…',
                        style: _LocTheme.body(size: 11),
                      )
                    else
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final city in filteredPopular)
                            _CityChip(
                              city: city,
                              selected:
                                  city.toLowerCase() ==
                                  widget.selectedCity.toLowerCase(),
                              onTap: () => unawaited(_pickCity(city)),
                            ),
                        ],
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
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _SoftCircleIconButton(icon: Icons.close_rounded, onTap: onClose),
      ),
    );
  }
}

class _SoftCircleIconButton extends StatelessWidget {
  const _SoftCircleIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _LocTheme.surface,
            border: Border.all(color: _LocTheme.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: _LocTheme.ink),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: _LocTheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _LocTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 20,
            color: Colors.white.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onSubmitted: onSubmitted,
              textCapitalization: TextCapitalization.words,
              cursorColor: Colors.white,
              style: _LocTheme.label(
                size: 13,
                weight: FontWeight.w600,
                color: _LocTheme.ink,
              ),
              decoration: InputDecoration(
                hintText: 'Search any city…',
                hintStyle: _LocTheme.body(
                  size: 13,
                  weight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.38),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (hasText)
            GestureDetector(
              onTap: onClear,
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlacesSuggestionRow extends StatelessWidget {
  const _PlacesSuggestionRow({required this.hit, required this.onTap});

  final GooglePlacesLocalityHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = hit.formattedAddress.trim().isNotEmpty
        ? hit.formattedAddress.trim()
        : [
            if (hit.adminArea.trim().isNotEmpty) hit.adminArea.trim(),
            if (hit.countryCode.trim().isNotEmpty) hit.countryCode.trim(),
          ].join(', ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _LocTheme.surfaceLift,
                  border: Border.all(color: _LocTheme.border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.place_outlined,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hit.name,
                      style: _LocTheme.label(size: 13, weight: FontWeight.w700),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _LocTheme.body(size: 10),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.35),
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationActionRow extends StatelessWidget {
  const _LocationActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.filledIcon = false,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool filledIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filledIcon ? _LocTheme.accent : _LocTheme.surfaceLift,
                  border: Border.all(
                    color: filledIcon
                        ? Colors.white.withValues(alpha: 0.12)
                        : _LocTheme.border,
                  ),
                  boxShadow: filledIcon
                      ? [
                          BoxShadow(
                            color: _LocTheme.accent.withValues(alpha: 0.45),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ]
                      : null,
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: _LocTheme.label(size: 13, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: _LocTheme.body(size: 10)),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 22,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CityChip extends StatelessWidget {
  const _CityChip({
    required this.city,
    required this.selected,
    required this.onTap,
    this.showRemove = false,
    this.onRemove,
  });

  final String city;
  final bool selected;
  final VoidCallback onTap;
  final bool showRemove;
  final VoidCallback? onRemove;

  bool get _isWorldwide => city.trim().toLowerCase() == 'worldwide';

  IconData get _icon =>
      _isWorldwide ? Icons.public_rounded : Icons.location_on_outlined;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        onLongPress: showRemove ? onRemove : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.only(
            left: 14,
            right: showRemove ? 8 : 16,
            top: 10,
            bottom: 10,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            color: selected ? Colors.white : _LocTheme.surface,
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : Colors.white.withValues(alpha: 0.08),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: selected ? 0.28 : 0.18),
                blurRadius: selected ? 18 : 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _icon,
                size: 15,
                color: selected
                    ? const Color(0xFF0B0B0D)
                    : Colors.white.withValues(alpha: 0.78),
              ),
              const SizedBox(width: 6),
              Text(
                city,
                style: _LocTheme.label(
                  size: 11,
                  weight: FontWeight.w700,
                  color: selected
                      ? const Color(0xFF0B0B0D)
                      : Colors.white.withValues(alpha: 0.92),
                ),
              ),
              if (showRemove) ...[
                const SizedBox(width: 2),
                InkWell(
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: selected
                          ? const Color(0xFF0B0B0D).withValues(alpha: 0.55)
                          : Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.place,
    required this.showDivider,
    required this.onTap,
  });

  final _RecentPlace place;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _LocTheme.surfaceLift,
                      shape: BoxShape.circle,
                      border: Border.all(color: _LocTheme.border),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.location_on_outlined,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          style: _LocTheme.label(
                            size: 13,
                            weight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(place.subtitle, style: _LocTheme.body(size: 10)),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.35),
                    size: 22,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            color: Colors.white.withValues(alpha: 0.06),
          ),
      ],
    );
  }
}
