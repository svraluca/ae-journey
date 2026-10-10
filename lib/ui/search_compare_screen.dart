import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'saved_procedures_screen.dart';

import '../data/community_post.dart';
import '../data/procedure_repository.dart';
import 'expanded_map_screen.dart';
import 'filter_compare_screen.dart';
import 'location_change_sheet.dart';
import 'clinics_for_procedure_screen.dart';
import 'clinic_profile_screen.dart';
import 'clinic_compare_price_display.dart';
import '../services/auth_service.dart';
import '../services/explore_backend_service.dart';
import '../services/explore_seed_catalog.dart';
import '../services/explore_curated_price_store.dart';
import '../services/explore_google_price_store.dart';
import '../services/filter_currency.dart';
import '../services/explore_price_discovery_tool.dart';
import '../services/openai_service.dart';
import '../services/explore_clinic_identity.dart';
import '../services/explore_search_locale.dart';
import '../services/explore_price_sanity.dart';
import '../services/explore_procedure_family.dart';
import '../services/explore_comparison_session.dart';
import '../services/explore_request_coordinator.dart';
import '../services/saved_procedures_store.dart';
import '../services/session_prefs.dart';
import '../services/explore_procedure_interests.dart';
import '../services/explore_city_identity.dart';
import '../services/worldwide_curated_clinics.dart';
import 'glow_map_style.dart';
import 'map_price_pin_bitmap.dart';
import 'procedure_selection_theme.dart';
import 'subscription_screen.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/thinking_orb.dart';
import 'widgets/explore_clinic_loading.dart';

const Color _searchDivider = Color(0x241A1A1F);

class SearchCompareScreen extends StatefulWidget {
  const SearchCompareScreen({super.key, this.active = true});

  /// False while another bottom-nav tab is selected. IndexedStack keeps this
  /// widget alive off-stage; hosting GoogleMap then paints a white/broken map.
  final bool active;

  @override
  State<SearchCompareScreen> createState() => _SearchCompareScreenState();
}

class _SearchCompareScreenState extends State<SearchCompareScreen>
    with SingleTickerProviderStateMixin {
  String _city = WorldwideCuratedClinics.cityName;
  ExploreCityIdentity? _cityIdentity;

  /// False until [SharedPreferences] restores the last compare-tab city so we
  /// do not paint the default city label or map center for one frame.
  bool _cityBootstrapped = false;
  String _pill = 'Botox';
  List<String> _comparePills = List<String>.from(kExploreComparePills);
  CompareFilterResult _filters = CompareFilterResult.defaults;

  FilterCurrency? get _displayCurrency => _filters.currency;

  FilterCurrency? _priceDisplayCurrencyFor(List<OpenAIClinic> _) {
    // Only FX-convert when the user picked a currency filter.
    return _displayCurrency;
  }

  // Approximate city centres — used to animate the map on city change.
  static const _cityCoords = <String, LatLng>{
    WorldwideCuratedClinics.cityName: WorldwideCuratedClinics.mapCenter,
    'London': LatLng(51.5072, -0.1276),
    'Paris': LatLng(48.8566, 2.3522),
    'Dubai': LatLng(25.2048, 55.2708),
    'București': LatLng(44.4268, 26.1025),
    'New York': LatLng(40.7128, -74.0060),
    'Milan': LatLng(45.4654, 9.1859),
    'Istanbul': LatLng(41.0082, 28.9784),
    'Barcelona': LatLng(41.3851, 2.1734),
    'Miami': LatLng(25.7617, -80.1918),
    'Los Angeles': LatLng(34.0522, -118.2437),
    'Houston': LatLng(29.7604, -95.3698),
    'Dallas': LatLng(32.7767, -96.7970),
    'Atlanta': LatLng(33.7490, -84.3880),
    'Austin': LatLng(30.2672, -97.7431),
    'Boston': LatLng(42.3601, -71.0589),
    'Charlotte': LatLng(35.2271, -80.8431),
    'Chicago': LatLng(41.8781, -87.6298),
    'Denver': LatLng(39.7392, -104.9903),
    'Las Vegas': LatLng(36.1699, -115.1398),
    'Nashville': LatLng(36.1627, -86.7816),
    'Orlando': LatLng(28.5383, -81.3792),
    'Phoenix': LatLng(33.4484, -112.0740),
    'Washington DC': LatLng(38.9072, -77.0369),
    'Tampa': LatLng(27.9506, -82.4572),
    'San Diego': LatLng(32.7157, -117.1611),
    'Toronto': LatLng(43.6532, -79.3832),
    'Markham': LatLng(43.8561, -79.3370),
    'Mississauga': LatLng(43.5890, -79.6441),
    'Oakville': LatLng(43.4675, -79.6877),
    'Richmond Hill': LatLng(43.8828, -79.4403),
    'Vaughan': LatLng(43.8372, -79.5083),
    'Vancouver': LatLng(49.2827, -123.1207),
    'Burnaby': LatLng(49.2488, -122.9805),
    'Surrey': LatLng(49.1913, -122.8490),
    'Calgary': LatLng(51.0447, -114.0719),
    'Edmonton': LatLng(53.5461, -113.4938),
    'Halifax': LatLng(44.6488, -63.5752),
    'Hamilton': LatLng(43.2557, -79.8711),
    'Kelowna': LatLng(49.8880, -119.4960),
    'Montreal': LatLng(45.5017, -73.5673),
    'Montréal': LatLng(45.5017, -73.5673),
    'Ottawa': LatLng(45.4215, -75.6972),
    'Quebec City': LatLng(46.8139, -71.2080),
    'Québec': LatLng(46.8139, -71.2080),
    'Saskatoon': LatLng(52.1332, -106.6700),
    'Victoria': LatLng(48.4284, -123.3656),
    'Winnipeg': LatLng(49.8954, -97.1385),
    'Chisinau': LatLng(47.0105, 28.8638),
    'Chișinău': LatLng(47.0105, 28.8638),
    'Beirut': LatLng(33.8938, 35.5018),
    'Moscow': LatLng(55.7558, 37.6173),
    'Ankara': LatLng(39.9334, 32.8597),
    'Izmir': LatLng(38.4237, 27.1428),
    'Antalya': LatLng(36.8969, 30.7133),
  };

  LatLng get _cityCenter {
    final id = _cityIdentity;
    if (id != null &&
        id.latitude != null &&
        id.longitude != null &&
        _isValidMapCoord(id.latitude!, id.longitude!)) {
      return LatLng(id.latitude!, id.longitude!);
    }
    return _cityCoords[_city] ?? WorldwideCuratedClinics.mapCenter;
  }

  double get _mapZoomForCity => WorldwideCuratedClinics.isWorldwide(_city)
      ? WorldwideCuratedClinics.mapZoom
      : 12.0;

  bool get _isWorldwide => WorldwideCuratedClinics.isWorldwide(_city);

  String get _backgroundNoteForCurrentPill {
    if (_visibleCompareComplete) return '';
    final note = _openAI.backgroundHuntNote.value;
    if (note == null || note.city != _city || note.pill != _pill) return '';
    return note.message;
  }

  bool get _discoveryActiveForCurrentPill {
    if (_visibleCompareComplete) return false;
    final note = _openAI.backgroundHuntNote.value;
    return note != null &&
        note.city == _city &&
        note.pill == _pill &&
        (note.isSearching || note.jobId.isNotEmpty);
  }

  bool get _visibleCompareComplete =>
      clinicsForCompareDisplay(
        _comparison?.clinics ?? const [],
        procedure: exploreVisibleComparePill(_pill),
        city: _city,
      ).length >=
      kExploreCompareMaxClinics;

  static bool _isValidMapCoord(double lat, double lng) {
    if (lat.abs() < 0.5 && lng.abs() < 0.5) return false;
    if (lat < -85 || lat > 85 || lng < -180 || lng > 180) return false;
    return true;
  }

  /// Prefer a real city/clinic center — AI sometimes returns 0,0 which
  /// leaves the styled map looking blank (Null Island / empty ocean).
  LatLng _resolvedMapCenter([OpenAIComparisonResult? cmp]) {
    final result = cmp ?? _comparison;
    if (result != null) {
      final mc = result.mapCenter;
      if (_isValidMapCoord(mc.lat, mc.lng)) {
        return LatLng(mc.lat, mc.lng);
      }
      for (final c in result.clinics) {
        if (_isValidMapCoord(c.coord.lat, c.coord.lng)) {
          return LatLng(c.coord.lat, c.coord.lng);
        }
      }
    }
    return _cityCenter;
  }

  OpenAIComparisonResult _withResolvedMapCenter(OpenAIComparisonResult res) {
    final center = _resolvedMapCenter(res);
    if (_isValidMapCoord(res.mapCenter.lat, res.mapCenter.lng)) return res;
    return OpenAIComparisonResult(
      city: res.city,
      topic: res.topic,
      topicType: res.topicType,
      summary: res.summary,
      rangeLabel: res.rangeLabel,
      mapCenter: OpenAICoord(center.latitude, center.longitude),
      clinics: res.clinics,
    );
  }

  String get _effectiveCountryCode {
    final id = _cityIdentity;
    if (id != null && id.countryCode.trim().isNotEmpty) {
      return id.countryCode.trim().toUpperCase();
    }
    return exploreCountryCodeForCity(_city);
  }

  String get _localityCacheSeg {
    final id = _cityIdentity;
    if (id != null && id.cityId.trim().isNotEmpty) return id.cityId.trim();
    return _city;
  }

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _openAI = OpenAIService();
  Timer? _debounce;
  Timer? _backgroundPoll;
  DateTime? _backgroundPollStartedAt;

  /// Monotonically increased so stale [search] responses cannot call [setState].
  int _searchRequestId = 0;

  /// Bumped on every Explore pill / city comparison build so late AI / All-mixed
  /// / enrichment results cannot overwrite the tab the user is viewing now.
  int _comparisonBuildId = 0;

  late final AnimationController _trendShimmerCtrl;
  bool _trendingLoading = true;
  List<TrendingProcedure>? _trendingProcedures;
  final _prewarmQueued = <String>{};

  @override
  void initState() {
    super.initState();
    _trendShimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    unawaited(_bootstrapCity());
    _openAI.backgroundHuntNote.addListener(_onBackgroundHunt);
    exploreInterestRevision.addListener(_onInterestRevision);
    _syncMapHostForTabVisibility(wasActive: false);
  }

  @override
  void didUpdateWidget(covariant SearchCompareScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _syncMapHostForTabVisibility(wasActive: oldWidget.active);
      if (mounted) setState(() {});
    }
  }

  void _onInterestRevision() {
    unawaited(_reloadInterestPills());
  }

  Future<void> _reloadInterestPills() async {
    List<String> interestPills = const [];
    try {
      interestPills = await SessionPrefs.exploreInterestPills();
    } catch (_) {}
    if (!mounted) return;
    final pills = exploreComparePillsForSelection(interestPills);
    final nextPill = pills.contains(exploreVisibleComparePill(_pill))
        ? exploreVisibleComparePill(_pill)
        : pills.first;
    setState(() {
      _comparePills = pills;
      _pill = nextPill;
    });
    unawaited(_buildComparisonFromPill(_pill));
  }

  void _onBackgroundHunt() {
    if (!mounted) return;
    final note = _openAI.backgroundHuntNote.value;
    // Other city/pill jobs must not rebuild and revalidate the visible list.
    if (note != null && (note.pill != _pill || note.city != _city)) return;
    // Job progress is hidden once four cards are visible. Rebuilding the
    // entire map/list for invisible status updates caused scroll stalls.
    if (_comparison != null &&
        _comparison!.clinics.length >= kExploreCompareMaxClinics &&
        !_isLoadingMoreClinics)
      return;
    setState(() {});
    if (note == null || note.pill != _pill || note.city != _city) return;
    // Automatic jobs are watched by OpenAIService. Manual jobs use the
    // status poll below; avoid running two crawlers or two poll loops.
  }

  void _scheduleBackgroundPoll(String pill) {
    _backgroundPoll?.cancel();
    final buildId = _comparisonBuildId;
    _backgroundPoll = Timer(const Duration(seconds: 5), () {
      unawaited(_quietFirestoreReload(pill, buildId));
    });
  }

  Future<void> _quietFirestoreReload(String pill, int buildId) async {
    if (!mounted ||
        pill == 'All' ||
        !_isCurrentComparisonBuild(buildId, pill)) {
      return;
    }
    if (_pill != pill) return;
    final note = _openAI.backgroundHuntNote.value;
    if (note == null || note.city != _city || note.pill != pill) return;
    final startedAt = _backgroundPollStartedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) > const Duration(minutes: 11)) {
      _openAI.backgroundHuntNote.value = ExploreBackgroundHunt(
        city: _city,
        pill: pill,
        message: 'Discovery is still running. You can check again later.',
      );
      return;
    }
    if (note.jobId.isNotEmpty) {
      final state = await ExplorePriceDiscoveryTool.instance.readDiscoveryJob(
        note.jobId,
      );
      if (!mounted || !_isCurrentComparisonBuild(buildId, pill)) return;
      if (state != null && state.rows.isNotEmpty) {
        final partial = await _openAI.comparisonWithDiscoveryRowsAsync(
          city: _city,
          procedure: explorePillAiSearchQuery(pill),
          rows: state.rows,
          previous: _comparison,
        );
        if (!mounted || !_isCurrentComparisonBuild(buildId, pill)) return;
        setState(() {
          _comparison = _withResolvedMapCenter(partial);
          _isMapLoading = false;
        });
      }
      if (state == null || !state.isFinished) {
        if (state != null) {
          _openAI.backgroundHuntNote.value = ExploreBackgroundHunt(
            city: _city,
            pill: pill,
            jobId: note.jobId,
            message: state.message,
          );
        }
        _scheduleBackgroundPoll(pill);
        return;
      }
      // The terminal job already supplied its final verified rows. Starting
      // buildComparison here can launch another hunt and keep three-card
      // results in a perpetual "Checking more" state after a failure.
      _backgroundPoll?.cancel();
      _backgroundPollStartedAt = null;
      _openAI.backgroundHuntNote.value = ExploreBackgroundHunt(
        city: _city,
        pill: pill,
        message: state.message,
      );
      setState(() {
        _isMapLoading = false;
        _isLoadingMoreClinics = false;
      });
      final completedComparison = _comparison;
      if (completedComparison != null &&
          completedComparison.clinics.isNotEmpty) {
        _storePillComparison(pill, completedComparison);
        _kickRatingBackfill(pill: pill, shown: completedComparison);
      }
      return;
    }
    final selection = explorePillAiSearchQuery(pill);
    final res = await _openAI.buildComparison(
      queryOrSelection: selection,
      city: _city,
      mode: _modeString,
      categoryPill: pill,
      searchNewGoogle: true,
      forceRefresh: false,
      backgroundRefresh: false,
    );
    if (!mounted ||
        !_isCurrentComparisonBuild(buildId, pill) ||
        _pill != pill) {
      return;
    }
    final shown = _exploreShownCount(res, procedure: selection);
    _openAI.backgroundHuntNote.value = ExploreBackgroundHunt(
      city: _city,
      pill: pill,
      message: shown == 0
          ? 'No verified public prices found yet.'
          : shown < kExploreCompareMaxClinics
          ? 'Search finished. No more verified public prices found this time.'
          : '',
    );
    setState(() {
      _comparison = res;
      _isMapLoading = false;
      _isLoadingMoreClinics = false;
    });
    if (shown > 0) {
      _storePillComparison(pill, res);
    }
  }

  Future<void> _findMoreClinics() async {
    if (_pill == 'All' || _isWorldwide) return;
    final city = _city;
    final pill = _pill;
    final buildId = _comparisonBuildId;
    final key =
        'comparison|$kExploreComparisonCacheRevision|'
        '${explorePillAiSearchQuery(pill)}|$_localityCacheSeg|$_modeString';
    final rotated = _openAI.rotateCachedExploreComparison(key);
    if (rotated != null) {
      setState(() => _comparison = _withResolvedMapCenter(rotated));
      _storePillComparison(pill, _comparison!);
      unawaited(_loadPreviewMapMarkers(_comparison!));
      _kickRatingBackfill(pill: pill, shown: _comparison!);
    }
    final job = await ExplorePriceDiscoveryTool.instance.enqueueDiscoveryJob(
      city: city,
      procedure: explorePillAiSearchQuery(pill),
      pill: pill,
      countryCode: _effectiveCountryCode,
      reason: 'user',
      clientStoredCount: _comparison?.clinics.length ?? 0,
      knownClinicHosts: [
        for (final c in _comparison?.clinics ?? const <OpenAIClinic>[])
          if (exploreClinicWebsiteHost(c).isNotEmpty)
            exploreClinicWebsiteHost(c),
      ],
      knownClinicNames: [
        for (final c in _comparison?.clinics ?? const <OpenAIClinic>[]) c.name,
      ],
    );
    if (!mounted || city != _city || !_isCurrentComparisonBuild(buildId, pill))
      return;
    if (job != null && job.rows.isNotEmpty) {
      final result = await _openAI.comparisonWithDiscoveryRowsAsync(
        city: city,
        procedure: explorePillAiSearchQuery(pill),
        rows: job.rows,
        previous: _comparison,
      );
      if (!mounted || !_isCurrentComparisonBuild(buildId, pill)) return;
      setState(() {
        _comparison = _withResolvedMapCenter(result);
        _isMapLoading = false;
      });
    }
    _openAI.backgroundHuntNote.value = ExploreBackgroundHunt(
      city: city,
      pill: pill,
      jobId: job != null && !job.isFinished ? job.id : '',
      message: job == null
          ? 'Search could not connect. Please try again.'
          : job.message,
    );
    if (job != null && !job.isFinished) {
      _backgroundPollStartedAt = DateTime.now();
      _scheduleBackgroundPoll(pill);
    } else {
      _backgroundPoll?.cancel();
      _backgroundPoll = null;
      _backgroundPollStartedAt = null;
    }
  }

  Future<void> _bootstrapCity() async {
    const resolved = WorldwideCuratedClinics.cityName;
    List<String> interestPills = const [];
    try {
      // Always open Explore on Worldwide — ignore any previously saved city.
      await SessionPrefs.setCompareSearchCity(resolved);
      interestPills = await SessionPrefs.exploreInterestPills();
    } catch (_) {
      // Prefs unavailable — keep in-memory Worldwide default.
    }
    if (!mounted) return;
    final pills = exploreComparePillsForSelection(interestPills);
    final nextPill = pills.contains(exploreVisibleComparePill(_pill))
        ? exploreVisibleComparePill(_pill)
        : pills.first;
    setState(() {
      _city = resolved;
      _cityBootstrapped = true;
      _comparePills = pills;
      _pill = nextPill;
    });
    unawaited(_loadTrendingProcedures());
    if (OpenAIService.disableClinicPreload) {
      debugPrint(
        '[GP] Clinic preload disabled — skipping compare-tab AI '
        '(GP_DISABLE_CLINIC_PRELOAD=true)',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _buildComparisonFromPill(_pill);
      });
      return;
    }
    if (!mounted) return;
    debugPrint('[GP] Explore opened on Worldwide curated clinics');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _buildComparisonFromPill(_pill);
    });
  }

  Future<void> _loadTrendingProcedures() async {
    if (!mounted) return;
    final cc = _effectiveCountryCode;

    final fallback = _openAI.getFallbackTrending(city: _city);
    if (!mounted) return;
    setState(() {
      _trendingProcedures = fallback;
      _trendingLoading = false;
    });

    if (OpenAIService.disableClinicPreload || _isWorldwide) return;

    try {
      final list = await _openAI.fetchTrendingProcedures(
        city: _city,
        countryCode: cc,
      );

      final sanitized = list
          .map(
            (p) =>
                p.name.length > 20 ||
                    p.name.contains(' pentru ') ||
                    p.name.contains(' cu ') ||
                    p.name.contains('injectabil') ||
                    p.name.contains('pentru') ||
                    p.name.contains('Tratamente') ||
                    p.name.contains('Remodelare')
                ? p.copyWith(name: _openAI.sanitizeProcedureName(p.name))
                : p,
          )
          .toList();

      if (!mounted) return;
      if (sanitized.isNotEmpty) {
        setState(() {
          _trendingProcedures = sanitized;
        });
        debugPrint(
          '[GP] Trending updated: ${sanitized.length} '
          'procedures for $_city',
        );
      }
    } catch (_) {
      // Keep showing fallback — already set above
    }
  }

  bool _isLoading = false;
  bool _hasSearched = false;
  String? _error;
  List<OpenAISearchItem> _items = const [];

  bool _isMapLoading = false;

  /// True while Firestore seeds are on screen and AI is still fetching more.
  bool _isLoadingMoreClinics = false;
  String? _mapError;
  OpenAIComparisonResult? _comparison;

  /// Last loaded list per procedure tab so switching Botox → Laser → Botox
  /// does not wipe cards and wait for a full reload.
  final Map<String, OpenAIComparisonResult> _comparisonByPill = {};
  GoogleMapController? _mapController;
  bool _mapReady = false;
  Completer<void> _mapReadyCompleter = Completer<void>();
  Map<MarkerId, Marker> _previewMapMarkers = const {};

  /// Bumped when remounting the preview GoogleMap after ExpandedMap pops.
  int _previewMapEpoch = 0;

  /// When false, the preview [GoogleMap] is removed from the tree so only one
  /// iOS map platform view is alive (avoids pigeon channel-error on pop).
  bool _previewMapHosted = false;

  void _syncMapHostForTabVisibility({required bool wasActive}) {
    if (!widget.active) {
      if (!_previewMapHosted && _mapController == null) return;
      _mapController = null;
      _mapReady = false;
      _mapReadyCompleter = Completer<void>();
      _previewMapHosted = false;
      _previewMapMarkers = const {};
      return;
    }
    // Tab just became visible — remount after layout so the platform view
    // gets a real size (fixes white Worldwide map after first signup).
    if (wasActive && _previewMapHosted) return;
    _previewMapHosted = false;
    _mapController = null;
    _mapReady = false;
    _mapReadyCompleter = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.active) return;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted || !widget.active) return;
      setState(() {
        _previewMapEpoch++;
        _previewMapHosted = true;
      });
      final current = _comparison;
      if (current != null) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted || !widget.active) return;
        await _loadPreviewMapMarkers(current);
      }
    });
  }

  Future<void> _openExpandedMap(OpenAIComparisonResult cmp) async {
    // Fully remove the preview platform view before pushing ExpandedMap.
    // Remounting (epoch++) while still visible leaves two iOS maps overlapping
    // and the channel dies when the expanded route pops.
    setState(() {
      _previewMapHosted = false;
      _previewMapMarkers = const {};
      _mapController = null;
      _mapReady = false;
      _mapReadyCompleter = Completer<void>();
    });

    // Let the platform view finish tearing down before the next GoogleMap mounts.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;

    final returned = await Navigator.of(context).push<CompareFilterResult>(
      MaterialPageRoute<CompareFilterResult>(
        builder: (_) => ExpandedMapScreen(
          comparison: cmp,
          city: _city,
          initialFilters: _filters,
        ),
      ),
    );
    if (!mounted) return;
    if (returned != null) {
      _filters = returned;
      if (_isWorldwide) {
        await _applyWorldwideFilters(returned);
      } else {
        setState(() {});
        final current = _comparison;
        if (current != null) await _loadPreviewMapMarkers(current);
      }
    }

    // Brief gap after expanded map dispose before hosting preview again.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    setState(() {
      _previewMapEpoch++;
      _previewMapHosted = true;
      _mapController = null;
      _mapReady = false;
      _mapReadyCompleter = Completer<void>();
      _previewMapMarkers = const {};
    });
    final current = _comparison;
    if (current != null) {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      await _loadPreviewMapMarkers(current);
    }
  }

  void _openFavorites() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const SavedProceduresScreen()),
    );
  }

  Future<void> _openLocationSheet() async {
    final subscribed = await AuthService().hasPaidSubscription();
    if (!mounted) return;
    if (!subscribed) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const SubscriptionScreen()),
      );
      return;
    }

    final picked = await showLocationChangeSheet(context, selectedCity: _city);
    if (picked == null || !mounted) return;

    final city = normalizeExploreCity(picked.displayName);

    ExploreBackendService.instance.setActiveCityIdentity(picked);
    _openAI.setActiveCityIdentity(picked);
    final cachedVisit =
        _pill == 'All' || WorldwideCuratedClinics.isWorldwide(city)
        ? null
        : _openAI.rotateCachedExploreComparison(
            'comparison|$kExploreComparisonCacheRevision|${explorePillAiSearchQuery(_pill)}|'
            '${picked.storageKey.isNotEmpty ? picked.storageKey : city}|$_modeString',
          );

    _cancelBackgroundAiWarm();
    _mapReadyCompleter = Completer<void>();

    setState(() {
      _city = city;
      _cityIdentity = picked;
      _comparisonBuildId++;
      _comparison = cachedVisit;
      _comparisonByPill.clear();
      _previewMapMarkers = const {};
      _mapError = null;
      _mapReady = false;
      _isLoadingMoreClinics = true;
      // Stale search results belong to the previous city — clear them.
      _items = const [];
      _error = null;
      _hasSearched = false;
    });
    _prewarmQueued.clear();

    // Paint first and serialize writes independently of navigation. Starting
    // every pill's Firestore aliases here starved the foreground selection.
    _locationPersistence = _locationPersistence.then((_) async {
      try {
        await SessionPrefs.setCompareSearchCity(city);
        await SessionPrefs.setCompareSearchCityIdentity(picked);
        await SessionPrefs.pushExploreRecentCity(city);
        if (city.toLowerCase() != 'worldwide' &&
            city.toLowerCase() != 'near me' &&
            !isExploreBuiltInPopularCity(city)) {
          await SessionPrefs.addExploreSavedCity(city);
        }
      } catch (_) {}
    });

    // Card reads run immediately; map initialization is independent of them.
    unawaited(_loadTrendingProcedures());
    final comparisonBuild = _buildComparisonFromPill(
      _pill,
      clearExisting: cachedVisit == null,
    );

    // Move the map camera to the new city once the map channel is ready.
    try {
      await _mapReadyCompleter.future.timeout(const Duration(seconds: 3));
      if (_mapReady) {
        await _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(_cityCenter, _mapZoomForCity),
        );
      }
    } catch (_) {}

    if (!mounted) return;

    await comparisonBuild;

    if (_searchController.text.trim().isNotEmpty) {
      await _runSearch(q: _searchController.text);
    }
  }

  Future<void> _openFilterScreen() async {
    final picked = await showFilterCompareSheet(context, initial: _filters);
    if (!mounted || picked == null) return;
    _filters = picked;
    if (_isWorldwide) {
      await _applyWorldwideFilters(picked);
      return;
    }
    setState(() {});
    final current = _comparison;
    if (current != null) {
      await _loadPreviewMapMarkers(current);
    }
  }

  /// Sync Explore pill + curated clinic list from Filters.
  Future<void> _applyWorldwideFilters(CompareFilterResult filters) async {
    final selected = filters.procedureTypes
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    String nextPill = _pill;
    if (selected.length == 1) {
      final only = selected.first;
      if (only == 'Botox' || only == 'Injectables') {
        nextPill = 'Botox';
      } else if (only == 'Fillers') {
        nextPill = 'Fillers';
      } else if (only == 'Laser' ||
          only == 'Skin laser' ||
          only == 'Hair removal') {
        nextPill = 'Hair';
      } else if (only == 'Peels') {
        nextPill = 'Peels';
      } else if (only == 'Skin treatments' || only == 'Skin boosters') {
        nextPill = 'Peels';
      } else if (only == 'Surgery') {
        nextPill = 'Rhinoplasty';
      } else if (only == 'Body treatments') {
        nextPill = 'Boob job';
      } else {
        nextPill = 'Botox';
      }
    } else if (selected.contains('Injectables') &&
        selected.contains('Botox') &&
        selected.length == 2) {
      nextPill = 'Botox';
    } else {
      nextPill = 'Botox';
    }

    if (mounted) {
      setState(() {
        _filters = filters;
        _pill = nextPill;
        _comparison = null;
        _isMapLoading = true;
        _isLoadingMoreClinics = false;
        _mapError = null;
        _previewMapMarkers = const {};
      });
    }

    final res = WorldwideCuratedClinics.buildComparisonForFilters(
      types: selected,
      currency: filters.currency,
      priceMin: filters.priceMin,
      priceMax: filters.priceMax,
      priceMaxOpen: filters.priceMaxOpen,
      minRating: filters.minRating,
      doctorLedOnly: filters.doctorLedOnly,
      verifiedOnly: filters.verifiedOnly,
    );
    if (!mounted) return;
    setState(() {
      _comparison = res;
      _isMapLoading = false;
    });
    await _loadPreviewMapMarkers(res);
    if (!mounted) return;
    await _animateMapCameraIfReady(
      CameraUpdate.newLatLngZoom(
        WorldwideCuratedClinics.mapCenter,
        WorldwideCuratedClinics.mapZoom,
      ),
    );
  }

  /// Returns true if the query string looks like a clinic/brand name rather than a procedure.
  bool _looksLikeClinic(String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return false;
    // Common clinic-name signals: "Dr ...", "Dr.SomeName", "DrSkin", "Dr-Skin", "Drs ..."
    if (RegExp(r'^dr[\s\.\-]?[a-z]').hasMatch(q)) return true;
    if (q.startsWith('drs ') || q.startsWith('drs.')) return true;
    const clinicWords = [
      'clinic',
      'clinica',
      'clinique',
      'studio',
      'aesthetics',
      'aesthetic',
      'medical',
      'beauty',
      'spa',
      'salon',
      'centre',
      'center',
      'lounge',
      'institute',
      'practice',
      'estetica',
      'polyclinic',
      'derma',
      'glow',
    ];
    return clinicWords.any((w) => q.contains(w));
  }

  /// Opens the correct screen based on whether the query is a clinic name or a procedure.
  /// Priority: (1) first AI result type → (2) majority clinic tiles → (3) client-side keyword heuristic.
  void _openSearchResults(String query) {
    final q = query.trim();
    if (q.isEmpty) return;

    final firstIsClinic =
        _items.isNotEmpty && _items.first.type == OpenAISearchItemType.clinic;
    final clinicTileCount = _items
        .where((e) => e.type == OpenAISearchItemType.clinic)
        .length;
    final majorityClinic =
        _items.isNotEmpty && clinicTileCount * 2 >= _items.length;
    final isClinicSearch =
        firstIsClinic || majorityClinic || _looksLikeClinic(q);

    if (isClinicSearch) {
      final seeds = <String>{q};
      for (final it in _items) {
        seeds.add(it.title);
        seeds.addAll(it.aliases);
      }
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ClinicsForProcedureScreen(
            procedureName: q,
            city: _city,
            isClinicNameSearch: true,
            seedNames: seeds.where((e) => e.trim().isNotEmpty).toList(),
          ),
        ),
      );
    } else {
      // Multilingual hint: pass the user's typed query + the AI's canonical
      // English name + any aliases the AI returned, deduplicated. This lets
      // the clinics-list AI match clinics under either language.
      OpenAISearchItem? firstProc;
      for (final it in _items) {
        if (it.type == OpenAISearchItemType.procedure) {
          firstProc = it;
          break;
        }
      }
      final aliases = <String>{
        q,
        if (firstProc != null) firstProc.title,
        if (firstProc != null) ...firstProc.aliases,
      }.where((e) => e.trim().isNotEmpty).toList();

      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ClinicsForProcedureScreen(
            procedureName: q,
            city: _city,
            aliases: aliases,
          ),
        ),
      );
    }
  }

  /// Always navigates to the clinics-for-procedure screen (used by trending cards and pills).
  void _openClinicsForProcedure(
    String procedureName, {
    String? nameLocal,
    List<String>? extraAliases,
  }) {
    final aliases = <String>{
      procedureName,
      if (nameLocal != null && nameLocal.isNotEmpty) nameLocal,
      if (extraAliases != null) ...extraAliases,
    }.where((e) => e.trim().isNotEmpty).toList();

    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ClinicsForProcedureScreen(
          procedureName: procedureName,
          city: _city,
          aliases: aliases,
        ),
      ),
    );
  }

  String get _modeString => 'procedure';

  void _storePillComparison(String pill, OpenAIComparisonResult cmp) {
    if (cmp.clinics.isEmpty) return;
    final incomingTool = cmp.clinics.any(
      (c) => c.sourceType == 'discovery_tool',
    );
    final prev = _comparisonByPill[pill];
    final prevTool =
        prev != null &&
        prev.clinics.isNotEmpty &&
        prev.clinics.any((c) => c.sourceType == 'discovery_tool');
    // The Python hunter's own 4-card mix replaces Firestore seeds.
    // A later cache warm must not mix those seeds back in.
    if (incomingTool) {
      _comparisonByPill[pill] = cmp;
      return;
    }
    if (prevTool) return;
    _comparisonByPill[pill] = putBestComparison(previous: prev, incoming: cmp);
  }

  /// Session-memory pills can be count-complete with `rating == 0` leftover.
  /// Show immediately; retry Places only for clinics that are not a confirmed miss.
  void _kickRatingBackfill({
    required String pill,
    required OpenAIComparisonResult shown,
  }) {
    if (_isWorldwide) return;
    // Cache warming must not launch rating searches for all hidden pills.
    if (pill != _pill && _pill != 'All') return;
    if (!_openAI.hasRetryableUnratedClinics(
      clinics: shown.clinics,
      city: _city,
    )) {
      return;
    }
    unawaited(_backfillMissingRatings(pill: pill, shown: shown));
  }

  Future<void> _backfillMissingRatings({
    required String pill,
    required OpenAIComparisonResult shown,
  }) async {
    final city = _city;
    final key = '$city|$pill|ratings';
    if (_preloadInFlight.contains(key)) return;
    _preloadInFlight.add(key);
    try {
      final procedure = pill == 'All' ? '' : explorePillAiSearchQuery(pill);
      final enriched = await _openAI.backfillMissingClinicRatings(
        base: shown,
        city: city,
        procedure: procedure,
        pill: pill,
      );
      if (!mounted || city != _city) return;

      final target =
          _comparisonByPill[pill] ??
          (_pill == pill ? _comparison : null) ??
          shown;
      final byName = <String, OpenAIClinic>{
        for (final c in enriched.clinics)
          if (c.name.trim().isNotEmpty && c.rating > 0)
            c.name.toLowerCase().trim(): c,
      };
      var changed = false;
      final next = <OpenAIClinic>[];
      for (final prev in target.clinics) {
        OpenAIClinic? match;
        for (final c in enriched.clinics) {
          if (c.rating > 0 &&
              exploreClinicHitsKeys(c, exploreClinicIdentityKeys(prev))) {
            match = c;
            break;
          }
        }
        match ??= byName[prev.name.toLowerCase().trim()];
        final displayName = prev.name;
        if (match == null ||
            (match.rating == prev.rating &&
                match.reviews == prev.reviews &&
                displayName == prev.name)) {
          if (displayName != prev.name) {
            changed = true;
            next.add(prev.copyWith(name: displayName));
          } else {
            next.add(prev);
          }
          continue;
        }
        changed = true;
        next.add(
          prev.copyWith(
            name: displayName.isNotEmpty ? displayName : prev.name,
            rating: match.rating > 0 ? match.rating : prev.rating,
            reviews: match.reviews > 0 ? match.reviews : prev.reviews,
          ),
        );
      }
      if (!changed) return;
      final merged = target.copyWith(clinics: next);
      _storePillComparison(pill, merged);
      final cacheKey = pill == 'All'
          ? 'comparison|$kExploreComparisonCacheRevision|All-mixed|$_localityCacheSeg|$_modeString'
          : 'comparison|$kExploreComparisonCacheRevision|$procedure|$_localityCacheSeg|$_modeString';
      _openAI.putCachedComparison(cacheKey, merged);
      if (_pill == pill) {
        setState(() => _comparison = merged);
      } else if (_pill == 'All' && _comparison != null) {
        final overlaid = overlayExploreClinicRatings(
          shown: _comparison!.clinics,
          enriched: merged.clinics,
        );
        if (overlaid != _comparison!.clinics) {
          setState(
            () => _comparison = _comparison!.copyWith(clinics: overlaid),
          );
        }
      }
    } catch (e) {
      debugPrint('[GP] Rating backfill error: $e');
    } finally {
      _preloadInFlight.remove(key);
    }
    if (!mounted || city != _city) return;
    final latest =
        _comparisonByPill[pill] ?? (_pill == pill ? _comparison : null);
    if (latest == null) return;
    final startedNames = {
      for (final c in shown.clinics) c.name.toLowerCase().trim(),
    }..removeWhere((n) => n.isEmpty);
    final hasNewcomer = latest.clinics.any((c) {
      if (c.rating > 0) return false;
      final name = c.name.toLowerCase().trim();
      return name.isNotEmpty && !startedNames.contains(name);
    });
    if (hasNewcomer) {
      _kickRatingBackfill(pill: pill, shown: latest);
    }
  }

  void _onPillSelected(String pill) {
    pill = exploreVisibleComparePill(pill);
    if (pill == _pill) return;
    if (_comparison != null && _comparison!.clinics.isNotEmpty) {
      _storePillComparison(_pill, _comparison!);
    }
    final selection = pill == 'All'
        ? 'All-mixed'
        : explorePillAiSearchQuery(pill);
    var cached = pill == 'All'
        ? _comparisonByPill[pill]
        : _openAI.rotateCachedExploreComparison(
            'comparison|$kExploreComparisonCacheRevision|$selection|$_localityCacheSeg|$_modeString',
          );
    cached ??= _comparisonByPill[pill];
    if (cached == null && pill != 'All') {
      cached = _openAI.getCachedComparison(
        'comparison|$kExploreComparisonCacheRevision|$selection|$_localityCacheSeg|$_modeString',
      );
    }
    final shown = cached == null
        ? 0
        : _exploreShownCount(
            cached,
            procedure: pill == 'All' ? null : selection,
          );
    // Paint underline + searching state on THIS frame. Waiting until a
    // post-frame callback left the previous procedure's cards on screen with
    // no AgentWorkingIndicator while the tab already said "Fillers".
    setState(() {
      _pill = pill;
      _filters = _filters.copyWith(
        procedureTypes: WorldwideCuratedClinics.filterTypesForPill(pill),
      );
      _mapError = null;
      if (cached != null && shown > 0) {
        _comparison = cached;
        _isMapLoading = false;
        // One verified card is a finished interactive result.
        _isLoadingMoreClinics = false;
      } else {
        _comparison = null;
        _isMapLoading = true;
        _isLoadingMoreClinics = true;
        _previewMapMarkers = const {};
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pill != pill) return;
      if (cached != null && shown > 0) {
        unawaited(_loadPreviewMapMarkers(cached));
      }
      if (cached != null && shown > 0) {
        _kickRatingBackfill(pill: pill, shown: cached);
      }
      unawaited(_buildComparisonFromPill(pill, clearExisting: false));
    });
  }

  Future<void> _loadPreviewMapMarkers(
    OpenAIComparisonResult res, {
    int? buildId,
    String? pill,
  }) async {
    if (!mounted) return;
    if (buildId != null &&
        pill != null &&
        !_isCurrentComparisonBuild(buildId, pill)) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    if (buildId != null &&
        pill != null &&
        !_isCurrentComparisonBuild(buildId, pill)) {
      return;
    }
    final dpr = math.max(MediaQuery.devicePixelRatioOf(context), 2.0);
    final base = _resolvedMapCenter(res);
    final next = <MarkerId, Marker>{};
    final source = exploreCompareClinics(
      res.clinics,
      procedure: res.topic,
      city: res.city,
      worldwide: WorldwideCuratedClinics.isWorldwide(res.city),
    );
    final sorted = source;
    final pinCurrency = _priceDisplayCurrencyFor(sorted);
    for (var i = 0; i < sorted.length; i++) {
      if (!mounted) return;
      if (buildId != null &&
          pill != null &&
          !_isCurrentComparisonBuild(buildId, pill)) {
        return;
      }
      final cl = sorted[i];
      final pos = clinicMapLatLng(cl, base, i);
      final icon = await buildMapPricePinDescriptor(
        clinic: cl,
        isSelected: false,
        pixelRatio: dpr,
        layout: MapPricePinLayout.compact,
        displayCurrency: pinCurrency,
      );
      final markerId = MarkerId('preview-${i + 1}');
      next[markerId] = Marker(
        markerId: markerId,
        position: pos,
        anchor: const Offset(0.5, 1.0),
        zIndexInt: 1,
        icon: icon,
        // Preview map is display-only — no price callouts / marker presses.
        consumeTapEvents: false,
        infoWindow: InfoWindow.noText,
      );
    }
    if (!mounted) return;
    if (buildId != null &&
        pill != null &&
        !_isCurrentComparisonBuild(buildId, pill)) {
      return;
    }
    if (buildId == null && !identical(_comparison, res)) return;
    try {
      setState(() => _previewMapMarkers = next);
    } catch (_) {}
  }

  Future<void> _animateMapCameraIfReady(
    CameraUpdate update, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Map may still be mounting (Explore opens before GoogleMap finishes
    // onMapCreated). Wait briefly; if it never becomes ready, skip quietly —
    // [initialCameraPosition] already covers the first paint.
    if (!_mapReady || _mapController == null) {
      try {
        await _mapReadyCompleter.future.timeout(timeout);
      } on TimeoutException {
        return;
      } catch (_) {
        return;
      }
    }
    if (!mounted || !_mapReady || _mapController == null) return;
    try {
      await _mapController!.animateCamera(update);
    } catch (e) {
      debugPrint('[GP] Map camera animation skipped: $e');
    }
  }

  /// Awaits the foreground Google top-up so the "Loading more clinics…"
  /// spinner clears once the 6s budget is done — even if Google found nothing.
  Future<void> _continueAiFillToMax(
    String cacheKey, {
    required String selection,
    required int buildId,
    required String pill,
  }) async {
    for (var pass = 0; pass < 2; pass++) {
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      if (_openAI.isComparisonTopUpExhausted(cacheKey)) break;
      final shown = _comparison == null
          ? 0
          : _exploreShownCount(_comparison!, procedure: selection);
      if (shown >= kExploreCompareMaxClinics) break;
      try {
        final more = await _openAI.buildComparison(
          queryOrSelection: selection,
          city: _city,
          mode: _modeString,
          categoryPill: pill,
          searchNewGoogle: true,
          onProgress: (partial) {
            if (!_isCurrentComparisonBuild(buildId, pill)) return;
            final fixed = _withResolvedMapCenter(partial);
            final n = _exploreShownCount(fixed, procedure: selection);
            if (n == 0) return;
            final prev = _comparison == null
                ? 0
                : _exploreShownCount(_comparison!, procedure: selection);
            if (n < prev) return;
            if (!mounted) return;
            final merged = _mergeComparisonProgress(_comparison, fixed);
            setState(() {
              _comparison = merged;
              _isMapLoading = false;
              _isLoadingMoreClinics =
                  n < kExploreCompareMaxClinics &&
                  _openAI.isComparisonSearchActive(cacheKey);
            });
            _storePillComparison(pill, merged);
          },
        );
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        final fixed = _withResolvedMapCenter(more);
        final n = _exploreShownCount(fixed, procedure: selection);
        if (n > 0 && mounted) {
          final merged = _mergeComparisonProgress(_comparison, fixed);
          setState(() {
            if (n >=
                (_comparison == null
                    ? 0
                    : _exploreShownCount(_comparison!, procedure: selection))) {
              _comparison = merged;
            }
            _isLoadingMoreClinics =
                n < kExploreCompareMaxClinics &&
                _openAI.isComparisonSearchActive(cacheKey);
          });
        }
        if (_openAI.isComparisonSearchActive(cacheKey) &&
            !_openAI.isExploreGoogleMixComplete(cacheKey)) {
          await _openAI.awaitComparisonAiTopUp(
            cacheKey,
            timeout: kExploreForegroundGoogleBudget,
          );
        }
      } catch (_) {
        break;
      }
    }
    if (!_isCurrentComparisonBuild(buildId, pill) || !mounted) return;
    final shown = _comparison == null
        ? 0
        : _exploreShownCount(_comparison!, procedure: selection);
    setState(() {
      _isLoadingMoreClinics = _compareStillFillingSlots(cacheKey, shown);
    });
  }

  /// True only while the screen has no verified card and a search is still
  /// inside its deadline. One verified card ends the interactive request.
  bool _compareStillFillingSlots(String cacheKey, int shown) {
    if (shown >= 1) return false;
    if (_openAI.isDiscoveryToolSettled(cacheKey)) return false;
    if (_openAI.isExploreGoogleMixComplete(cacheKey)) return false;
    if (_openAI.isComparisonTopUpExhausted(cacheKey)) return false;
    if (_openAI.isDiscoveryToolIncomplete(cacheKey)) return false;
    return _openAI.isComparisonSearchActive(cacheKey);
  }

  Future<void> _awaitComparisonAiTopUp(
    String cacheKey, {
    required int buildId,
    required String pill,
  }) async {
    try {
      final done = await _openAI.awaitComparisonAiTopUp(
        cacheKey,
        timeout: kExploreForegroundFillBudget,
      );
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      if (done != null) {
        final procedure = pill == 'All' ? null : explorePillAiSearchQuery(pill);
        final fixed = _withResolvedMapCenter(done);
        final newShown = _exploreShownCount(fixed, procedure: procedure);
        final currentShown = _comparison == null
            ? 0
            : _exploreShownCount(_comparison!, procedure: procedure);
        // A later filter pass must not delete cards the user already saw.
        if (newShown < currentShown && currentShown > 0) {
          setState(() {
            _isLoadingMoreClinics = _compareStillFillingSlots(
              cacheKey,
              currentShown,
            );
          });
          return;
        }
        final merged = _mergeComparisonProgress(_comparison, fixed);
        final shown = _exploreShownCount(merged, procedure: procedure);
        setState(() {
          _comparison = merged;
          _isLoadingMoreClinics = _compareStillFillingSlots(cacheKey, shown);
        });
        await _loadPreviewMapMarkers(merged, buildId: buildId, pill: pill);
      } else if (mounted) {
        final shown = _comparison == null
            ? 0
            : _exploreShownCount(
                _comparison!,
                procedure: pill == 'All'
                    ? null
                    : explorePillAiSearchQuery(pill),
              );
        setState(() {
          _isLoadingMoreClinics = _compareStillFillingSlots(cacheKey, shown);
        });
      }
    } catch (_) {
      if (mounted && _isCurrentComparisonBuild(buildId, pill)) {
        final shown = _comparison == null
            ? 0
            : _exploreShownCount(
                _comparison!,
                procedure: pill == 'All'
                    ? null
                    : explorePillAiSearchQuery(pill),
              );
        setState(() {
          _isLoadingMoreClinics = _compareStillFillingSlots(cacheKey, shown);
        });
      }
    }
  }

  Future<void> _applyComparisonEnrichment(
    String cacheKey, {
    required int buildId,
    required String pill,
  }) async {
    try {
      final enriched = await _openAI.awaitComparisonEnrichment(cacheKey);
      if (!_isCurrentComparisonBuild(buildId, pill) || enriched == null) {
        return;
      }
      final procedure = pill == 'All' ? null : explorePillAiSearchQuery(pill);
      final currentShown = _comparison == null
          ? 0
          : _exploreShownCount(_comparison!, procedure: procedure);
      final newShown = _exploreShownCount(enriched, procedure: procedure);
      if (newShown < currentShown && currentShown > 0) {
        debugPrint(
          '[GP] Enrichment removed rejected cards $currentShown → $newShown',
        );
        final fixed = _withResolvedMapCenter(enriched);
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        setState(() {
          _comparison = fixed;
          _isLoadingMoreClinics = _compareStillFillingSlots(cacheKey, newShown);
        });
        _storePillComparison(pill, fixed);
        return;
      }
      if (newShown > currentShown) {
        final merged = _withResolvedMapCenter(
          _mergeComparisonProgress(_comparison, enriched),
        );
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        setState(() {
          _comparison = merged;
        });
        await _loadPreviewMapMarkers(merged, buildId: buildId, pill: pill);
        return;
      }
      _overlayClinicRatings(enriched);
    } catch (_) {}
  }

  /// Patch rating/reviews onto clinics already on screen. Avoids replacing
  /// the whole comparison (and the map) when Places returns late.
  void _overlayClinicRatings(OpenAIComparisonResult enriched) {
    final current = _comparison;
    if (current == null || !mounted) return;
    final next = overlayExploreClinicRatings(
      shown: current.clinics,
      enriched: enriched.clinics,
    );
    if (identical(next, current.clinics)) return;
    final merged = current.copyWith(clinics: next);
    setState(() => _comparison = merged);
    _storePillComparison(_pill, merged);
  }

  bool _isCurrentComparisonBuild(int buildId, String pill) =>
      mounted && buildId == _comparisonBuildId && _pill == pill;

  int _exploreShownCount(OpenAIComparisonResult res, {String? procedure}) {
    return exploreCompareClinics(
      res.clinics,
      procedure: procedure ?? res.topic,
      city: res.city,
      worldwide: WorldwideCuratedClinics.isWorldwide(res.city),
    ).length;
  }

  bool _exploreSameClinicSet(
    OpenAIComparisonResult a,
    OpenAIComparisonResult b,
  ) {
    if (a.clinics.length != b.clinics.length) return false;
    final used = <int>{};
    for (final c in a.clinics) {
      var found = false;
      for (var i = 0; i < b.clinics.length; i++) {
        if (used.contains(i)) continue;
        if (exploreClinicsAreSameProvider(c, b.clinics[i])) {
          used.add(i);
          found = true;
          break;
        }
      }
      if (!found) return false;
    }
    return true;
  }

  List<OpenAIClinic> _exploreStableAppendClinics({
    required List<OpenAIClinic> previous,
    required List<OpenAIClinic> incoming,
  }) {
    final used = <String>{};
    final out = <OpenAIClinic>[];

    void add(OpenAIClinic c) {
      for (var i = 0; i < out.length; i++) {
        if (!exploreClinicsAreSameProvider(out[i], c)) continue;
        out[i] = mergeExploreClinicRecord(out[i], c);
        used.addAll(exploreClinicIdentityKeys(c));
        return;
      }
      if (exploreClinicHitsKeys(c, used)) return;
      if (out.length >= kExploreCompareMaxClinics) return;
      out.add(c);
      used.addAll(exploreClinicIdentityKeys(c));
    }

    for (final c in previous) {
      add(c);
    }
    for (final c in incoming) {
      add(c);
    }
    return out;
  }

  OpenAIComparisonResult _mergeComparisonProgress(
    OpenAIComparisonResult? previous,
    OpenAIComparisonResult incoming,
  ) {
    if (previous == null || previous.clinics.isEmpty) return incoming;
    if (ExplorePriceDiscoveryTool.instance.enabled ||
        (incoming.clinics.isNotEmpty &&
            incoming.clinics.any((c) => c.sourceType == 'discovery_tool'))) {
      // The tool stabilizes valid providers before publishing. Its snapshot
      // can also remove a source positively invalidated during rechecking.
      return incoming.copyWith(
        clinics: overlayExploreClinicRatings(
          shown: incoming.clinics,
          enriched: previous.clinics,
        ),
      );
    }
    final clinics = overlayExploreClinicRatings(
      shown: _exploreStableAppendClinics(
        previous: previous.clinics,
        incoming: incoming.clinics,
      ),
      enriched: incoming.clinics,
    );
    return incoming.copyWith(clinics: clinics);
  }

  Future<void> _buildComparisonFromPill(
    String pill, {
    bool clearExisting = true,
    bool forceRefresh = false,
  }) async {
    final buildId = ++_comparisonBuildId;
    _backgroundPoll?.cancel();
    _backgroundPollStartedAt = null;
    _cityDiscoveryGeneration++;
    _openAI.abandonInFlightDiscovery();
    _cancelBackgroundAiWarm();
    _openAI.focusLiveCompareSearch(
      pill == 'All'
          ? 'all|$_localityCacheSeg|$_modeString'
          : 'comparison|$kExploreComparisonCacheRevision|'
                '${explorePillAiSearchQuery(pill)}|$_localityCacheSeg|$_modeString',
      label: '$pill · $_city',
    );
    if (mounted && clearExisting) {
      setState(() {
        _comparison = null;
        _isMapLoading = true;
        _isLoadingMoreClinics = true;
        _mapError = null;
        _previewMapMarkers = const {};
      });
    } else if (mounted) {
      setState(() {
        _mapError = null;
        final hasCards = _comparison != null && _comparison!.clinics.isNotEmpty;
        _isMapLoading = !hasCards;
        _isLoadingMoreClinics = !hasCards;
      });
    }

    if (_isWorldwide) {
      final res = WorldwideCuratedClinics.buildComparison(pill: pill);
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      setState(() {
        _comparison = res;
        _isMapLoading = false;
        _isLoadingMoreClinics = false;
      });
      await _loadPreviewMapMarkers(res, buildId: buildId, pill: pill);
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      await _animateMapCameraIfReady(
        CameraUpdate.newLatLngZoom(
          WorldwideCuratedClinics.mapCenter,
          WorldwideCuratedClinics.mapZoom,
        ),
      );
      return;
    }

    if (pill == 'All') {
      const cacheKeySuffix = 'All-mixed';
      final cacheKey =
          'comparison|$kExploreComparisonCacheRevision|$cacheKeySuffix|$_localityCacheSeg|$_modeString';
      final cached = _openAI.getCachedComparison(cacheKey);
      if (cached != null &&
          cached.city.trim().toLowerCase() == _city.trim().toLowerCase() &&
          cached.clinics.isNotEmpty) {
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        final inMarket = [
          for (final c in cached.clinics)
            if (exploreClinicFitsSearchCity(c, _city)) c,
        ];
        if (inMarket.isEmpty) {
          // Fall through and rebuild All from per-pill caches.
        } else {
          final fixed = _withResolvedMapCenter(
            cached.copyWith(clinics: inMarket),
          );
          final shown = _exploreShownCount(fixed);
          final complete = shown >= kExploreCompareMinClinics;
          setState(() {
            _comparison = fixed;
            _isMapLoading = false;
            _isLoadingMoreClinics = !complete;
          });
          await _loadPreviewMapMarkers(fixed, buildId: buildId, pill: pill);
          if (!_isCurrentComparisonBuild(buildId, pill)) return;
          await _animateMapCameraIfReady(
            CameraUpdate.newLatLngZoom(_resolvedMapCenter(fixed), 12.2),
          );
          _kickRatingBackfill(pill: pill, shown: fixed);
          if (complete) return;
        }
      }

      try {
        final mixed = await _buildCityAllMixedComparison(buildId: buildId);
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        if (mixed == null || mixed.clinics.isEmpty) {
          if (!_isCurrentComparisonBuild(buildId, pill)) return;
          // Do not clobber a late onProgress / watch merge that already painted.
          final already = _comparison;
          final alreadyN =
              already != null &&
                  already.topic.toLowerCase().startsWith('all') &&
                  already.city.trim().toLowerCase() ==
                      _city.trim().toLowerCase()
              ? _exploreShownCount(already)
              : 0;
          if (alreadyN > 0) {
            setState(() {
              _isMapLoading = false;
              _isLoadingMoreClinics =
                  !ExplorePriceDiscoveryTool.instance.enabled &&
                  alreadyN < kExploreCompareMaxClinics;
              _mapError = null;
            });
            unawaited(_watchAllMissingPreferredSlots(buildId: buildId));
            return;
          }
          final empty = OpenAIComparisonResult(
            city: _city,
            topic: 'All · $_city',
            topicType: OpenAISearchItemType.procedure,
            summary: '',
            rangeLabel: '',
            mapCenter: OpenAICoord(_cityCenter.latitude, _cityCenter.longitude),
            clinics: const [],
          );
          setState(() {
            _comparison = empty;
            _isMapLoading = false;
            // Keep soft loading — preferred pill verifies often finish after
            // the All wall clock (Ankara Botox ~27s). Watch merges them in.
            _isLoadingMoreClinics = !ExplorePriceDiscoveryTool.instance.enabled;
            _mapError = null;
          });
          await _loadPreviewMapMarkers(empty, buildId: buildId, pill: pill);
          unawaited(_watchAllMissingPreferredSlots(buildId: buildId));
          return;
        }
        final fixed = _withResolvedMapCenter(mixed);
        // Do not clobber a richer progressive All paint with a stale return.
        final current = _comparison;
        final currentN =
            current != null &&
                current.topic.toLowerCase().startsWith('all') &&
                current.city.trim().toLowerCase() == _city.trim().toLowerCase()
            ? _exploreShownCount(current)
            : 0;
        final mixedN = _exploreShownCount(fixed);
        final best = mixedN >= currentN ? fixed : current!;
        final shown = _exploreShownCount(best);
        _openAI.putCachedComparison(cacheKey, best);
        setState(() {
          _comparison = best;
          _isMapLoading = false;
          _isLoadingMoreClinics =
              !ExplorePriceDiscoveryTool.instance.enabled &&
              shown < kExploreCompareMaxClinics;
        });
        await _loadPreviewMapMarkers(best, buildId: buildId, pill: pill);
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        await _animateMapCameraIfReady(
          CameraUpdate.newLatLngZoom(_resolvedMapCenter(best), 12.2),
        );
        _kickRatingBackfill(pill: pill, shown: best);
        if (shown < kExploreCompareMaxClinics) {
          unawaited(_watchAllMissingPreferredSlots(buildId: buildId));
        }
      } catch (e) {
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        setState(() {
          _isMapLoading = false;
          _isLoadingMoreClinics = false;
          _mapError = e.toString();
          _previewMapMarkers = const {};
        });
      }
      return;
    }

    final selection = explorePillAiSearchQuery(pill);
    final cacheKey =
        'comparison|$kExploreComparisonCacheRevision|$selection|$_localityCacheSeg|$_modeString';

    final cached = _openAI.getCachedComparison(cacheKey);
    final cachedShown = cached == null
        ? 0
        : _exploreShownCount(cached, procedure: selection);
    final cachedComplete =
        cached != null &&
        cached.city.trim().toLowerCase() == _city.trim().toLowerCase() &&
        cachedShown >= 1 &&
        _openAI.isExploreGoogleMixComplete(cacheKey);
    if (cachedComplete) {
      debugPrint('[GP] Comparison preview from memory: $selection');
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      final fixed = _withResolvedMapCenter(cached);
      setState(() {
        _comparison = fixed;
        _isMapLoading = false;
        _isLoadingMoreClinics = false;
      });
      _storePillComparison(pill, fixed);
      await _loadPreviewMapMarkers(fixed, buildId: buildId, pill: pill);
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      await _animateMapCameraIfReady(
        CameraUpdate.newLatLngZoom(_resolvedMapCenter(fixed), 12.2),
      );
      _kickRatingBackfill(pill: pill, shown: fixed);
    }

    try {
      // Live Places/Serper must start now. Waiting on ai_cache first left
      // empty cities (Chisinau, …) sitting on "Live search focus" with no
      // discovery — buildComparison already loads those same seeds.
      if (_isCurrentComparisonBuild(buildId, pill) &&
          (cached == null || cachedShown <= 0)) {
        setState(() => _isLoadingMoreClinics = true);
      }

      void applyProgress(OpenAIComparisonResult partialRes) {
        if (!_isCurrentComparisonBuild(buildId, pill)) return;
        final fixed = _withResolvedMapCenter(partialRes);
        final shown = _exploreShownCount(fixed, procedure: selection);
        final prevCount = _comparison == null
            ? 0
            : _exploreShownCount(_comparison!, procedure: selection);
        if (!mounted) return;
        // Empty emits must not replace the spinner — Google is still filling
        // remaining slots when Firestore had nothing for this procedure.
        if (shown == 0) {
          if (_openAI.isExploreGoogleMixComplete(cacheKey)) {
            setState(() {
              _comparison = fixed;
              _isMapLoading = false;
              _isLoadingMoreClinics = false;
            });
          } else {
            setState(() => _isLoadingMoreClinics = true);
          }
          return;
        }
        // Never shrink a list the user already saw (4 → 2 Firestore seeds
        // on tab return). Google can still append via merge when it lands.
        if (shown < prevCount &&
            prevCount > 0 &&
            !ExplorePriceDiscoveryTool.instance.enabled) {
          setState(() {
            _isLoadingMoreClinics = _compareStillFillingSlots(
              cacheKey,
              prevCount,
            );
          });
          return;
        }
        var toShow = fixed;
        if (prevCount > 0 && _comparison != null) {
          toShow = _withResolvedMapCenter(
            _mergeComparisonProgress(_comparison, fixed),
          );
        }
        setState(() {
          _comparison = toShow;
          _isMapLoading = false;
          _isLoadingMoreClinics = _compareStillFillingSlots(
            cacheKey,
            _exploreShownCount(toShow, procedure: selection),
          );
        });
        _storePillComparison(pill, toShow);
        _openAI.reportCompareDisplayCount(
          cacheKey,
          clinicsForCompareDisplay(
            toShow.clinics,
            procedure: selection,
            city: _city,
          ).length,
        );
        // The city-tab painter can apply this same partial first, so the
        // count often does not grow here. Still look up Maps scores for
        // any card that arrived with rating 0.
        _kickRatingBackfill(pill: pill, shown: toShow);
        if (shown != prevCount || prevCount == 0) {
          unawaited(
            _loadPreviewMapMarkers(toShow, buildId: buildId, pill: pill),
          );
        }
      }

      final res = await _openAI.buildComparison(
        queryOrSelection: selection,
        city: _city,
        mode: _modeString,
        categoryPill: pill,
        searchNewGoogle: true,
        forceRefresh: forceRefresh,
        backgroundRefresh: true,
        onProgress: applyProgress,
      );
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      final latest = _openAI.getCachedComparison(cacheKey) ?? res;
      final latestShown = _exploreShownCount(latest, procedure: selection);
      final prevShown = _comparison == null
          ? 0
          : _exploreShownCount(_comparison!, procedure: selection);
      final mixDone = _openAI.isExploreGoogleMixComplete(cacheKey);
      final best = latestShown >= prevShown || prevShown == 0
          ? latest
          : (_comparison ?? latest);
      final bestShown = _exploreShownCount(best, procedure: selection);
      final aiInFlight =
          !mixDone &&
          bestShown < kExploreCompareMaxClinics &&
          _openAI.isComparisonSearchActive(cacheKey);
      if (!mounted) return;
      if (bestShown == 0 && aiInFlight) {
        setState(() {
          _isMapLoading = true;
          _isLoadingMoreClinics = true;
        });
      } else {
        var toShow = best;
        if (prevShown > 0 && _comparison != null) {
          toShow = _withResolvedMapCenter(
            _mergeComparisonProgress(_comparison, best),
          );
        }
        setState(() {
          _comparison = toShow;
          _isMapLoading = false;
          _isLoadingMoreClinics = _compareStillFillingSlots(
            cacheKey,
            _exploreShownCount(toShow, procedure: selection),
          );
        });
        if (bestShown > 0) {
          _storePillComparison(pill, toShow);
          _openAI.reportCompareDisplayCount(
            cacheKey,
            clinicsForCompareDisplay(
              toShow.clinics,
              procedure: selection,
              city: _city,
            ).length,
          );
          _kickRatingBackfill(pill: pill, shown: toShow);
        }
      }
      await _loadPreviewMapMarkers(best, buildId: buildId, pill: pill);
      if (!_isCurrentComparisonBuild(buildId, pill)) return;

      await _animateMapCameraIfReady(
        CameraUpdate.newLatLngZoom(_resolvedMapCenter(best), 12.2),
      );

      if (bestShown == 0 &&
          !_openAI.isDiscoveryToolSettled(cacheKey) &&
          !mixDone) {
        unawaited(() async {
          if (!_openAI.isComparisonSearchActive(cacheKey)) {
            try {
              await _openAI.buildComparison(
                queryOrSelection: selection,
                city: _city,
                mode: _modeString,
                categoryPill: pill,
                searchNewGoogle: true,
                onProgress: applyProgress,
              );
            } catch (_) {}
          }
          await _awaitComparisonAiTopUp(cacheKey, buildId: buildId, pill: pill);
          final latest = _openAI.getCachedComparison(cacheKey);
          if (latest != null) {
            _openAI.kickComparisonEnrichmentIfNeeded(
              cacheKey: cacheKey,
              base: latest,
              queryOrSelection: selection,
              city: _city,
            );
          }
          await _applyComparisonEnrichment(
            cacheKey,
            buildId: buildId,
            pill: pill,
          );
          if (mounted && _isCurrentComparisonBuild(buildId, pill)) {
            final shown = _exploreShownCount(
              _comparison ?? best,
              procedure: selection,
            );
            setState(() {
              _isLoadingMoreClinics = _compareStillFillingSlots(
                cacheKey,
                shown,
              );
            });
          }
          unawaited(_preloadOtherPills(currentPill: pill, searchGoogle: false));
          unawaited(_preloadOtherPillsAiLowPriority(currentPill: pill));
          if (mounted) {
            final shownNow = _exploreShownCount(
              _comparison ?? best,
              procedure: selection,
            );
            _startCityTabsAfterVisiblePill(
              buildId: buildId,
              pill: pill,
              cacheKey: cacheKey,
              shown: shownNow,
            );
          }
        }());
      } else {
        setState(() => _isLoadingMoreClinics = false);
        unawaited(_preloadOtherPills(currentPill: pill, searchGoogle: false));
        unawaited(_preloadOtherPillsAiLowPriority(currentPill: pill));
        _startCityTabsAfterVisiblePill(
          buildId: buildId,
          pill: pill,
          cacheKey: cacheKey,
          shown: _exploreShownCount(best, procedure: selection),
        );
        final latest = _openAI.getCachedComparison(cacheKey) ?? best;
        final toolCards =
            latest.clinics.isNotEmpty &&
            latest.clinics.any((c) => c.sourceType == 'discovery_tool');
        if (!toolCards) {
          _openAI.kickComparisonEnrichmentIfNeeded(
            cacheKey: cacheKey,
            base: latest,
            queryOrSelection: selection,
            city: _city,
          );
          unawaited(
            _applyComparisonEnrichment(cacheKey, buildId: buildId, pill: pill),
          );
        }
      }
    } catch (e) {
      if (!_isCurrentComparisonBuild(buildId, pill)) return;
      setState(() {
        _isMapLoading = false;
        _isLoadingMoreClinics = false;
        _mapError = e.toString();
        _previewMapMarkers = const {};
      });
    }
  }

  /// After the open tab, ask the Python hunter for the other procedure tabs.
  /// Each tab keeps that tool's own mix, at most 4 cards.
  int _cityDiscoveryGeneration = 0;
  int? _cityTabsStartedForBuild;

  void _startCityTabsAfterVisiblePill({
    required int buildId,
    required String pill,
    required String cacheKey,
    required int shown,
  }) {
    if (_cityTabsStartedForBuild == buildId) return;
    if (!_isCurrentComparisonBuild(buildId, pill)) return;
    if (pill == 'All' || _isWorldwide) return;
    final settled = _openAI.isDiscoveryToolSettled(cacheKey);
    if (shown == 0 && !settled) return;
    _cityTabsStartedForBuild = buildId;
    unawaited(_searchRemainingCityTabsWithDiscoveryTool(_city));
  }

  Future<void> _searchRemainingCityTabsWithDiscoveryTool(String city) async {
    final generation = ++_cityDiscoveryGeneration;
    if (city.toLowerCase() == 'worldwide') return;
    if (!await ExplorePriceDiscoveryTool.instance.isReachable()) return;
    if (!mounted || city != _city || generation != _cityDiscoveryGeneration) {
      return;
    }
    final currentPill = _pill;
    final countryCode = _effectiveCountryCode;
    // The selected tab submits independently with foreground priority.
    // Queue warmups one at a time; stale city work must not flood acceptance.
    for (final pill in kDiscoveryToolCityPills.where(
      (pill) => pill != currentPill,
    )) {
      if (!mounted || city != _city || generation != _cityDiscoveryGeneration)
        return;
      try {
        final accepted = await ExplorePriceDiscoveryTool.instance
            .enqueueBackgroundDiscovery(
              city: city,
              countryCode: countryCode,
              procedure: explorePillAiSearchQuery(pill),
              pill: pill,
              reason: 'city_collection',
            );
        debugPrint(
          '[GP TOOL] city collection · $pill · $city · '
          '${accepted ? "accepted" : "unavailable"}',
        );
        if (!accepted) return;
      } catch (error) {
        debugPrint('[GP TOOL] city collection failed · $pill · $error');
      }
    }
  }

  /// Warms every other Compare pill in the background so switching tabs
  /// shows cached clinics immediately instead of waiting on a new search.
  final Set<String> _preloadInFlight = {};
  int _bgAiWarmGeneration = 0;
  Future<void> _locationPersistence = Future<void>.value();

  void _cancelBackgroundAiWarm() {
    _bgAiWarmGeneration++;
  }

  Future<void> _preloadOtherPills({
    required String currentPill,
    required bool searchGoogle,
  }) async {
    if (_isWorldwide) return;
    if (OpenAIService.disableClinicPreload) return;
    final live = searchGoogle && !OpenAIService.disableClinicPreload;
    final city = _city;
    final generation = _bgAiWarmGeneration;
    for (final pill in _comparePills) {
      if (pill == currentPill) continue;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || city != _city || generation != _bgAiWarmGeneration)
        return;
      await _warmComparePill(pill, city, searchGoogle: live);
    }
  }

  /// After the visible pill is done, cache-warm other pills.
  /// Never run Places / website / SerpApi / Translation / OpenAI in the
  /// background — that starved the selected pill and caused request storms.
  Future<void> _preloadOtherPillsAiLowPriority({
    required String currentPill,
  }) async {
    if (OpenAIService.disableClinicPreload) return;
    if (_isWorldwide) return;
    await _preloadOtherPills(currentPill: currentPill, searchGoogle: false);
  }

  Future<void> _warmComparePill(
    String pill,
    String city, {
    required bool searchGoogle,
  }) async {
    if (city != _city) return;
    final live = searchGoogle && !OpenAIService.disableClinicPreload;
    final key = '$city|$pill|${live ? "ai" : "cache"}';
    if (_preloadInFlight.contains(key)) return;
    final existing = _comparisonByPill[pill];
    final shown = existing == null
        ? 0
        : _exploreShownCount(
            existing,
            procedure: explorePillAiSearchQuery(pill),
          );
    if (!live && shown >= kExploreFirestoreSeedClinics) {
      if (existing != null) {
        _kickRatingBackfill(pill: pill, shown: existing);
      }
      return;
    }
    if (live &&
        shown >= kExploreCompareMaxClinics &&
        _openAI.isExploreGoogleMixComplete(
          'comparison|$kExploreComparisonCacheRevision|'
          '${explorePillAiSearchQuery(pill)}|$_localityCacheSeg|$_modeString',
        )) {
      debugPrint(
        '[GP] Compare timing: $pill · $city · source=mix-complete · 0ms',
      );
      if (existing != null) {
        _kickRatingBackfill(pill: pill, shown: existing);
      }
      return;
    }
    _preloadInFlight.add(key);
    try {
      debugPrint('[GP] Compare preload${live ? " AI" : ""}: $pill · $city');
      await _openAI.buildComparison(
        queryOrSelection: explorePillAiSearchQuery(pill),
        city: city,
        mode: _modeString,
        categoryPill: pill,
        awaitEmptyAi: false,
        searchNewGoogle: live,
        onProgress: (partial) {
          if (!mounted || city != _city) return;
          final n = _exploreShownCount(
            partial,
            procedure: explorePillAiSearchQuery(pill),
          );
          if (n == 0) return;
          final prev = _comparisonByPill[pill];
          final prevN = prev == null
              ? 0
              : _exploreShownCount(
                  prev,
                  procedure: explorePillAiSearchQuery(pill),
                );
          if (n < prevN) return;
          final stored = _withResolvedMapCenter(partial);
          _storePillComparison(pill, stored);
          if (n > prevN) {
            _kickRatingBackfill(pill: pill, shown: stored);
          }
        },
      );
      if (live && city == _city) {
        final cacheKey =
            'comparison|$kExploreComparisonCacheRevision|'
            '${explorePillAiSearchQuery(pill)}|$_localityCacheSeg|$_modeString';
        await _openAI.awaitComparisonAiTopUp(
          cacheKey,
          timeout: const Duration(seconds: 120),
        );
        if (city != _city) return;
        var warmed =
            _comparisonByPill[pill] ?? _openAI.getCachedComparison(cacheKey);
        var n = warmed == null
            ? 0
            : _exploreShownCount(
                warmed,
                procedure: explorePillAiSearchQuery(pill),
              );
        debugPrint('[GP] Warm pill done: $pill · $city · $n verified');
        if (warmed != null) {
          _kickRatingBackfill(pill: pill, shown: warmed);
        }
      }
    } catch (_) {
    } finally {
      _preloadInFlight.remove(key);
    }
  }

  /// After All preview returns under-filled, keep merging preferred pill
  /// caches (Fillers etc.) into the visible list so cards appear without
  /// switching tabs — live verify often finishes after the shared preview budget.
  Future<void> _watchAllMissingPreferredSlots({required int buildId}) async {
    final preferred = _cityAllProcedures
        .take(kExploreCompareMaxClinics)
        .toList();
    final until = DateTime.now().add(const Duration(seconds: 40));

    String clinicProcedureHint(OpenAIClinic c) {
      if (c.procedureCanonical.trim().isNotEmpty) return c.procedureCanonical;
      if (c.rawProcedureText.trim().isNotEmpty) return c.rawProcedureText;
      return c.brand;
    }

    bool clinicMatchesPill(OpenAIClinic c, String pill) {
      final query = explorePillAiSearchQuery(pill);
      final want = exploreTreatmentFamily(query);
      if (want == ExploreTreatmentFamily.other) return false;
      final hintFam = exploreTreatmentFamily(clinicProcedureHint(c));
      final brandFam = exploreTreatmentFamily(c.brand);
      final familyHit =
          hintFam == want ||
          brandFam == want ||
          (c.procedureFamily.trim().isNotEmpty &&
              c.procedureFamily.trim().toLowerCase() == want.name);
      if (!familyHit) return false;
      return exploreClinicEligibleForVerifiedPool(
        c,
        procedure: query,
        city: _city,
      );
    }

    while (_isCurrentComparisonBuild(buildId, 'All') &&
        DateTime.now().isBefore(until)) {
      final current = _comparison;
      if (current == null ||
          !current.topic.toLowerCase().startsWith('all') ||
          current.city.trim().toLowerCase() != _city.trim().toLowerCase()) {
        return;
      }

      bool allHasPill(String pill) =>
          current.clinics.any((c) => clinicMatchesPill(c, pill));

      String slotTitle(String pill) {
        for (final e in preferred) {
          if (e.pill == pill) return e.label;
        }
        return explorePillCardFallback(pill);
      }

      final picks = <String, OpenAIClinic>{};
      for (final entry in preferred) {
        if (allHasPill(entry.pill)) continue;
        final query = explorePillAiSearchQuery(entry.pill);
        final cacheKey =
            'comparison|$kExploreComparisonCacheRevision|$query|$_localityCacheSeg|$_modeString';
        final cached = _openAI.getCachedComparison(cacheKey);
        if (cached == null || cached.clinics.isEmpty) continue;
        for (final c in cached.clinics) {
          if (!exploreClinicEligibleForVerifiedPool(
            c,
            procedure: query,
            city: _city,
          )) {
            continue;
          }
          final named = withExploreClinicDisplayName(c);
          final brand = named.brand.trim();
          final keepSpecific =
              brand.isNotEmpty &&
              !looksLikeInternalProcedureId(brand) &&
              !isExploreTopicPlaceholder(brand) &&
              !isBroadExploreCategoryName(brand) &&
              !looksLikeRawScrapedProcedureTitle(brand) &&
              exploreTreatmentFamily(brand) == exploreTreatmentFamily(query);
          picks[entry.pill] = named.copyWith(
            brand: keepSpecific ? brand : slotTitle(entry.pill),
          );
          break;
        }
      }

      if (picks.isEmpty) {
        final stillMissing = preferred.any((e) => !allHasPill(e.pill));
        if (!stillMissing) {
          if (mounted && _isCurrentComparisonBuild(buildId, 'All')) {
            setState(() => _isLoadingMoreClinics = false);
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final usedKeys = <String>{};
      final merged = <OpenAIClinic>[];
      for (final entry in preferred) {
        if (merged.length >= kExploreCompareMaxClinics) break;
        OpenAIClinic? clinic = picks[entry.pill];
        if (clinic == null) {
          for (final c in current.clinics) {
            if (clinicMatchesPill(c, entry.pill)) {
              clinic = c;
              break;
            }
          }
        }
        if (clinic == null) continue;
        final key = exploreAllTabSlotOpportunityKey(clinic, pill: entry.pill);
        if (key.isEmpty || !usedKeys.add(key)) continue;
        merged.add(clinic.copyWith(rank: merged.length + 1));
      }

      if (merged.length <= current.clinics.length &&
          picks.keys.every(allHasPill)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }
      if (merged.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        continue;
      }

      final next = _withResolvedMapCenter(current.copyWith(clinics: merged));
      debugPrint(
        '[ALL PREVIEW] late merge · $_city · '
        '${[for (final c in merged) c.brand].join(", ")}',
      );
      if (!_isCurrentComparisonBuild(buildId, 'All')) return;
      setState(() {
        _comparison = next;
        _isMapLoading = false;
        _isLoadingMoreClinics =
            !ExplorePriceDiscoveryTool.instance.enabled &&
            (merged.length < kExploreCompareMaxClinics ||
                preferred.any(
                  (e) => !allHasPill(e.pill) && !picks.containsKey(e.pill),
                ));
      });
      _openAI.putCachedComparison(
        'comparison|$kExploreComparisonCacheRevision|All-mixed|$_localityCacheSeg|$_modeString',
        next,
      );
      await _loadPreviewMapMarkers(next, buildId: buildId, pill: 'All');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (mounted && _isCurrentComparisonBuild(buildId, 'All')) {
      setState(() {
        // Watch window ended — stop soft spinner even if still under 4.
        _isLoadingMoreClinics = false;
      });
    }
  }

  static const _cityAllProcedures = <({String pill, String label})>[
    // All shows 4 cards, one per pill. Order is the slot priority: the first
    // kExploreCompareMaxClinics entries are the preferred procedures and must
    // stay first, so a fast Peels/Hair fallback can borrow a leftover slot but
    // never displaces Botox once its quote lands.
    (pill: 'Botox', label: 'Botox'),
    (pill: 'Fillers', label: 'Lip filler'),
    (pill: 'Rhinoplasty', label: 'Rhinoplasty'),
    (pill: 'Boob job', label: 'Breast augmentation'),
    (pill: 'Peels', label: 'Chemical peel'),
    (pill: 'Hair', label: 'Hair transplant'),
  ];

  /// Shared budget for All preview — return UI within ~7s; background may merge.
  static const _kAllPreviewBudget = Duration(seconds: 7);
  static const _kAllPreviewGrace = Duration(seconds: 1);

  /// City Explore **All**: exactly one clinic per flagship procedure.
  ///
  /// This is a procedure-diversity preview, not a generic 4-clinic list. A
  /// pill that already holds a card never contributes a second one, so a
  /// missing Botox leaves its slot empty instead of being backfilled with a
  /// second Breast augmentation. Three unique procedures beat four cards with
  /// a duplicate category. Individual pill tabs are unaffected and still show
  /// up to 4 clinics of the same procedure.
  Future<OpenAIComparisonResult?> _buildCityAllMixedComparison({
    required int buildId,
  }) async {
    final allSw = Stopwatch()..start();
    var previewFinished = false;
    OpenAIComparisonResult? seed;
    final usedKeys = <String>{};
    final slotByPill = <String, OpenAIClinic>{};

    String allSlotTitle(String pill) {
      for (final e in _cityAllProcedures) {
        if (e.pill == pill) return e.label;
      }
      return explorePillCardFallback(pill);
    }

    OpenAIClinic labeled(OpenAIClinic pick, String pill) {
      final named = withExploreClinicDisplayName(pick);
      final fallback = allSlotTitle(pill);
      final cardBrand = named.brand.trim();
      final keepSpecific =
          cardBrand.isNotEmpty &&
          !looksLikeInternalProcedureId(cardBrand) &&
          !isExploreTopicPlaceholder(cardBrand) &&
          !isBroadExploreCategoryName(cardBrand) &&
          !looksLikeRawScrapedProcedureTitle(cardBrand) &&
          !looksLikePriceMenuHeadingOnly(cardBrand) &&
          !looksLikeCatalogSectionHeading(cardBrand) &&
          !looksLikeMarketAveragePriceBlurb(cardBrand) &&
          exploreTreatmentFamily(cardBrand) ==
              exploreTreatmentFamily(explorePillAiSearchQuery(pill));
      return named.copyWith(brand: keepSpecific ? cardBrand : fallback);
    }

    String opportunityKey(OpenAIClinic c, String pill) =>
        exploreAllTabSlotOpportunityKey(c, pill: pill);

    bool takeClinic(OpenAIClinic c, String pill) {
      final key = opportunityKey(c, pill);
      if (key.isEmpty || !usedKeys.add(key)) return false;
      return true;
    }

    bool fitsPillSlot(OpenAIClinic c, String pill) {
      final query = explorePillAiSearchQuery(pill);
      final host = c.priceSourceUrl.trim().isNotEmpty
          ? c.priceSourceUrl
          : exploreClinicWebsiteHost(c);
      if (looksLikePriceQuotedClinicName(c.name) ||
          !isUsableExploreClinicIdentity(
            name: c.name,
            websiteHost: host,
            providerClinic: c.providerClinic,
            sourceType: c.sourceType,
          )) {
        return false;
      }
      return exploreClinicEligibleForVerifiedPool(
        c,
        procedure: query,
        city: _city,
      );
    }

    /// The displayed set, paired with the pill each card fills.
    ///
    /// One card per pill, in `_cityAllProcedures` order, so the four preferred
    /// procedures always take the slots ahead of the Peels/Hair fallbacks even
    /// if a fallback verified first. Card count therefore equals unique pill
    /// count by construction — there is no path that adds a second card for an
    /// already occupied pill.
    List<({OpenAIClinic clinic, String pill})> slottedEntries() {
      final out = <({OpenAIClinic clinic, String pill})>[];
      final seen = <String>{};
      for (final entry in _cityAllProcedures) {
        if (out.length >= kExploreCompareMaxClinics) break;
        final c = slotByPill[entry.pill];
        if (c == null) continue;
        // Clinic identity dedupe: the same provider may legitimately hold two
        // slots when the families differ (Botox + Peels is not a duplicate).
        final key = opportunityKey(c, entry.pill);
        if (key.isEmpty || !seen.add(key)) continue;
        out.add((clinic: c.copyWith(rank: out.length + 1), pill: entry.pill));
      }
      return out;
    }

    List<OpenAIClinic> slottedClinics() => [
      for (final e in slottedEntries()) e.clinic,
    ];

    Future<void> publishSlots({required bool loadingMore}) async {
      if (!_isCurrentComparisonBuild(buildId, 'All')) return;
      final showLoading = loadingMore && !previewFinished;
      var clinics = slottedClinics();
      if (clinics.isEmpty && showLoading) return;
      final previousAll = _comparison;
      if (previousAll != null && previousAll.clinics.isNotEmpty) {
        clinics = overlayExploreClinicRatings(
          shown: clinics,
          enriched: previousAll.clinics,
        );
        for (final entry in _cityAllProcedures) {
          final occupying = slotByPill[entry.pill];
          if (occupying == null) continue;
          for (final c in clinics) {
            if (!exploreClinicsAreSameProvider(occupying, c)) continue;
            slotByPill[entry.pill] = occupying.copyWith(
              rating: occupying.rating > 0 ? occupying.rating : c.rating,
              reviews: occupying.reviews > 0 ? occupying.reviews : c.reviews,
              placeId: occupying.placeId.trim().isNotEmpty
                  ? occupying.placeId
                  : c.placeId,
            );
            break;
          }
        }
        clinics = slottedClinics();
        clinics = overlayExploreClinicRatings(
          shown: clinics,
          enriched: previousAll.clinics,
        );
      }
      seed ??= OpenAIComparisonResult(
        city: _city,
        topic: 'All · $_city',
        topicType: OpenAISearchItemType.procedure,
        summary: '',
        rangeLabel: 'Treatments',
        mapCenter: clinics.isNotEmpty
            ? clinics.first.coord
            : OpenAICoord(_cityCenter.latitude, _cityCenter.longitude),
        clinics: clinics,
      );
      final partial = _withResolvedMapCenter(
        OpenAIComparisonResult(
          city: _city,
          topic: 'All · $_city',
          topicType: seed!.topicType,
          summary: seed!.summary,
          rangeLabel: 'Treatments',
          mapCenter: seed!.mapCenter,
          clinics: clinics,
        ),
      );
      setState(() {
        _comparison = partial;
        _isMapLoading = false;
        _isLoadingMoreClinics = showLoading;
      });
      _kickRatingBackfill(pill: 'All', shown: partial);
      await _loadPreviewMapMarkers(partial, buildId: buildId, pill: 'All');
    }

    final loaded = await Future.wait([
      for (final entry in _cityAllProcedures)
        () async {
          final query = explorePillAiSearchQuery(entry.pill);
          final cacheKey =
              'comparison|$kExploreComparisonCacheRevision|$query|$_localityCacheSeg|$_modeString';
          final mem = _openAI.getCachedComparison(cacheKey);
          final storedRawFuture = ExploreGooglePriceStore.instance
              .load(city: _city, procedure: query)
              .timeout(const Duration(seconds: 3), onTimeout: () => const []);
          final firestoreFuture = _openAI
              .loadComparisonFromFirestore(
                cacheKey,
                queryOrSelection: query,
                city: _city,
                mode: _modeString,
              )
              .timeout(const Duration(seconds: 3), onTimeout: () => null);
          // Curated rows fill All's slots from Firestore, so a covered city
          // never needs four live searches before the first paint.
          final curatedFuture = ExploreCuratedPriceStore.instance
              .load(city: _city, procedure: query)
              .timeout(const Duration(seconds: 3), onTimeout: () => const []);
          final storedRaw = await storedRawFuture;
          final firestorePool = await firestoreFuture;
          final curated = await curatedFuture;
          return (
            entry: entry,
            query: query,
            clinics: <OpenAIClinic>[
              if (mem != null) ...mem.clinics,
              if (firestorePool != null)
                for (final c in firestorePool.clinics)
                  stripStaleExtractedClinicPrice(c),
              for (final m in storedRaw)
                stripStaleExtractedClinicPrice(OpenAIClinic.fromJson(m)),
              ...curated,
            ],
          );
        }(),
    ]);

    final preferred = _cityAllProcedures
        .take(kExploreCompareMaxClinics)
        .toList();
    final preferredPills = {for (final e in preferred) e.pill};

    bool trySlotFromStored(String pill, List<OpenAIClinic> stored) {
      if (slotByPill[pill] != null) return true;
      final shuffled = List<OpenAIClinic>.of(stored)..shuffle();
      final seen = <String>{};
      for (final c in shuffled) {
        final key = exploreClinicDedupKey(c);
        if (key.isEmpty || !seen.add(key)) continue;
        if (!fitsPillSlot(c, pill)) continue;
        if (!takeClinic(c, pill)) continue;
        slotByPill[pill] = labeled(c, pill);
        debugPrint('[GP] All slot · $pill · ${c.name}');
        return true;
      }
      return false;
    }

    for (final row in loaded) {
      // Do not let Peels/Laser cache consume All's 4 slots before surgery
      // has had a live search — those pools are usually empty.
      if (!preferredPills.contains(row.entry.pill)) continue;
      trySlotFromStored(row.entry.pill, row.clinics);
    }

    debugPrint(
      '[CURATED] $_city · All · slots=${slotByPill.keys.join(",")} · '
      '${allSw.elapsedMilliseconds}ms',
    );

    await publishSlots(
      loadingMore: slottedClinics().length < kExploreCompareMaxClinics,
    );

    OpenAIClinic keepMapsRating(OpenAIClinic incoming, OpenAIClinic? previous) {
      if (previous == null) return incoming;
      return incoming.copyWith(
        rating: incoming.rating > 0 ? incoming.rating : previous.rating,
        reviews: incoming.reviews > 0 ? incoming.reviews : previous.reviews,
        placeId: incoming.placeId.trim().isNotEmpty
            ? incoming.placeId
            : previous.placeId,
      );
    }

    /// Fills at most one slot — `slotByPill[pill]` — so a pill can never
    /// contribute a second All card no matter how many clinics it verified.
    void tryPickFromResult(String pill, OpenAIComparisonResult res) {
      bool sameClinic(OpenAIClinic a, OpenAIClinic b) =>
          exploreClinicHitsKeys(a, exploreClinicIdentityKeys(b));
      bool listed(OpenAIClinic c) => fitsPillSlot(c, pill);

      final occupying = slotByPill[pill];
      if (occupying != null) {
        OpenAIClinic? same;
        for (final c in res.clinics) {
          if (sameClinic(c, occupying)) {
            same = c;
            break;
          }
        }
        // Only replace/drop when this result actually re-lists the occupying
        // clinic. Empty mid-scrape progress must not wipe a good cache slot.
        if (same != null) {
          if (listed(same)) {
            slotByPill[pill] = labeled(keepMapsRating(same, occupying), pill);
          } else {
            usedKeys.remove(opportunityKey(occupying, pill));
            slotByPill.remove(pill);
          }
          if (slotByPill[pill] != null) return;
        } else {
          return;
        }
      }

      OpenAIClinic? pick;
      for (final c in res.clinics) {
        if (!listed(c)) continue;
        if (usedKeys.contains(opportunityKey(c, pill))) continue;
        pick = c;
        break;
      }
      if (pick != null) {
        takeClinic(pick, pill);
        slotByPill[pill] = labeled(pick, pill);
      }
    }

    OpenAIComparisonResult emptyComparison(String query) =>
        OpenAIComparisonResult(
          city: _city,
          topic: query,
          topicType: OpenAISearchItemType.procedure,
          summary: '',
          rangeLabel: '',
          mapCenter: const OpenAICoord(0, 0),
          clinics: const [],
        );

    // Shared wall clock for All — do not let each pill run a 30s scrape.
    final previewDeadline = DateTime.now().add(_kAllPreviewBudget);
    final graceDeadline = previewDeadline.add(_kAllPreviewGrace);
    final livePillSearches = <String, Future<void>>{};
    final startedLivePills = <String>{};
    // Claim All Serper budget before any live pill starts.
    ExploreRequestCoordinator.instance.beginAllVisit(
      'all|${_city.trim().toLowerCase()}|$buildId',
    );

    Future<void> fillPreviewSlot(({String pill, String label}) entry) async {
      if (!_isCurrentComparisonBuild(buildId, 'All')) return;
      if (slotByPill.length >= kExploreCompareMaxClinics &&
          slotByPill[entry.pill] != null) {
        return;
      }
      if (slotByPill[entry.pill] != null) return;
      if (!startedLivePills.add(entry.pill)) return;
      final query = explorePillAiSearchQuery(entry.pill);
      final cacheKey =
          'comparison|$kExploreComparisonCacheRevision|$query|$_localityCacheSeg|$_modeString';
      debugPrint('[ALL PREVIEW] ${entry.pill} · $_city · target=1');
      final painted = Completer<void>();
      try {
        // Kick search; do not await the full scrape — wait only until this
        // procedure paints one clinic or the shared All deadline hits.
        unawaited(
          _openAI
              .buildComparison(
                queryOrSelection: query,
                city: _city,
                mode: _modeString,
                categoryPill: entry.pill,
                awaitEmptyAi: false,
                searchNewGoogle: true,
                backgroundRefresh: true,
                googleLiveTargetOverride: 1,
                claimLiveSearch: false,
                joinInFlight: false,
                allowDeepFallbacks: false,
                onProgress: (partial) {
                  if (!_isCurrentComparisonBuild(buildId, 'All')) return;
                  tryPickFromResult(entry.pill, partial);
                  if (slotByPill[entry.pill] != null && !painted.isCompleted) {
                    painted.complete();
                  }
                  unawaited(
                    publishSlots(
                      loadingMore:
                          slottedClinics().length < kExploreCompareMaxClinics,
                    ),
                  );
                },
              )
              .then(
                (_) {
                  if (!painted.isCompleted) painted.complete();
                },
                onError: (Object error, StackTrace stack) {
                  if (!painted.isCompleted) painted.complete();
                },
              ),
        );
        // Also check memory/cache that may already have a card.
        tryPickFromResult(
          entry.pill,
          _openAI.getCachedComparison(cacheKey) ?? emptyComparison(query),
        );
        if (slotByPill[entry.pill] != null) {
          if (!painted.isCompleted) painted.complete();
        } else {
          final left = previewDeadline.difference(DateTime.now());
          if (left > Duration.zero) {
            await painted.future.timeout(left, onTimeout: () {});
          }
        }
        tryPickFromResult(
          entry.pill,
          _openAI.getCachedComparison(cacheKey) ?? emptyComparison(query),
        );
        await publishSlots(
          loadingMore: slottedClinics().length < kExploreCompareMaxClinics,
        );
      } catch (_) {}
    }

    Future<void> runLiveWave(
      List<({String pill, String label})> entries, {
      required DateTime until,
    }) async {
      if (entries.isEmpty) return;
      if (slottedClinics().length >= kExploreCompareMaxClinics) return;
      debugPrint(
        '[ALL PREVIEW] $_city live ${entries.map((e) => e.pill).join(", ")}',
      );
      final visitId = 'all|${_city.trim().toLowerCase()}|${buildId}';
      ExploreRequestCoordinator.instance.beginAllVisit(visitId);
      // Cold All preview: one procedure at a time so official verify starts
      // immediately and Serper stays within the shared budget of 4.
      const maxConcurrent = 1;
      final running = <Future<void>>[];
      var idx = 0;
      while (_isCurrentComparisonBuild(buildId, 'All') &&
          slottedClinics().length < kExploreCompareMaxClinics &&
          idx < entries.length) {
        if (DateTime.now().isAfter(until)) {
          debugPrint(
            '[UI DEADLINE] All · $_city · ${slottedClinics().length} slots',
          );
          break;
        }
        while (running.length >= maxConcurrent) {
          await Future.any(List<Future<void>>.of(running));
        }
        if (slottedClinics().length >= kExploreCompareMaxClinics) break;
        if (DateTime.now().isAfter(until)) break;
        final need = kExploreCompareMaxClinics - slottedClinics().length;
        if (running.length >= need) {
          await Future.any(List<Future<void>>.of(running));
          continue;
        }
        final entry = entries[idx++];
        if (slotByPill[entry.pill] != null) continue;
        late final Future<void> fut;
        fut = fillPreviewSlot(entry).whenComplete(() {
          running.remove(fut);
          livePillSearches.remove(entry.pill);
        });
        livePillSearches[entry.pill] = fut;
        running.add(fut);
      }
      if (running.isNotEmpty) {
        final left = until.difference(DateTime.now());
        if (left > Duration.zero) {
          await Future.wait(List<Future<void>>.of(running)).timeout(
            left,
            onTimeout: () {
              debugPrint(
                '[UI DEADLINE] All · $_city · preview wait cut · '
                '${slottedClinics().length} slots',
              );
              return <void>[];
            },
          );
        }
      }
    }

    final missingPreferred = [
      for (final entry in preferred)
        if (slotByPill[entry.pill] == null) entry,
    ].take(2).toList();
    if (missingPreferred.isNotEmpty) {
      debugPrint(
        '[ALL PREVIEW] $_city preferred empty '
        '${missingPreferred.map((e) => e.pill).join(", ")} '
        '— at most 2 live searches this visit',
      );
      await runLiveWave(missingPreferred, until: previewDeadline);
    }

    // Brief grace for already-started searches; then stop prominent loading.
    while (_isCurrentComparisonBuild(buildId, 'All') &&
        slottedClinics().length < kExploreCompareMaxClinics &&
        DateTime.now().isBefore(graceDeadline) &&
        livePillSearches.isNotEmpty) {
      await Future.any([
        ...livePillSearches.values,
        Future<void>.delayed(const Duration(milliseconds: 300)),
      ]);
      await publishSlots(
        loadingMore: slottedClinics().length < kExploreCompareMaxClinics,
      );
    }

    // Preferred late paints merge in background — do not hold All for 28s.
    // Remaining procedure families discover asynchronously after UI returns.
    if (_isCurrentComparisonBuild(buildId, 'All') &&
        slottedClinics().length < kExploreCompareMaxClinics) {
      for (final row in loaded) {
        if (slottedClinics().length >= kExploreCompareMaxClinics) break;
        if (preferredPills.contains(row.entry.pill)) continue;
        trySlotFromStored(row.entry.pill, row.clinics);
      }
      await publishSlots(loadingMore: false);
      final stillMissingPreferred = [
        for (final entry in preferred)
          if (slotByPill[entry.pill] == null) entry,
      ];
      // Kick preferred pills that never got a live search (concurrency=1 +
      // deadline used to skip Fillers after only Botox started). Cap at 2
      // detached starts so Serper stays within the All visit budget.
      if (stillMissingPreferred.isNotEmpty) {
        final rest = stillMissingPreferred
            .where((e) => !startedLivePills.contains(e.pill))
            .take(2)
            .toList();
        for (final entry in rest) {
          unawaited(fillPreviewSlot(entry));
        }
      }
    }

    // Completion is measured in unique procedure slots, never in raw cards:
    // 4 cards over 3 categories used to read as "done" and stop the search
    // for the empty pill. A preferred slot that is still being scraped keeps
    // the spinner alive so a late Botox can drop into place; once the
    // deadline has killed every live search there is nothing left to wait for.
    final missingPreferredPills = [
      for (final entry in preferred)
        if (slotByPill[entry.pill] == null) entry.pill,
    ];
    final preferredComplete = missingPreferredPills.isEmpty;
    // Stop prominent loading after the All deadline — background may still merge.
    previewFinished = true;
    await publishSlots(loadingMore: false);
    ExploreRequestCoordinator.instance.logPerfSnapshot(
      label: 'All · $_city',
      uiCompletedMs: allSw.elapsedMilliseconds,
      backgroundDetached: !preferredComplete,
    );
    ExploreRequestCoordinator.instance.endAllVisit(
      'all|${_city.trim().toLowerCase()}|$buildId',
    );
    if (!_isCurrentComparisonBuild(buildId, 'All')) return null;
    final entries = slottedEntries();
    final clinics = [for (final e in entries) e.clinic];
    final shownPills = [for (final e in entries) e.pill];
    if (clinics.isEmpty) return _comparison;
    assert(
      shownPills.toSet().length == clinics.length,
      'All preview must contain at most one clinic per procedure pill '
      '(pills=$shownPills)',
    );
    debugPrint(
      '[ALL PREVIEW] $_city ${preferredComplete ? "done" : "partial"} '
      '· cards=${clinics.length} · slots=${shownPills.toSet().length} '
      '· ${shownPills.join(",")}'
      '${preferredComplete ? "" : " · missing=${missingPreferredPills.join(",")}"}'
      ' · ${allSw.elapsedMilliseconds}ms',
    );
    return _withResolvedMapCenter(
      OpenAIComparisonResult(
        city: _city,
        topic: 'All · $_city',
        topicType: seed?.topicType ?? OpenAISearchItemType.procedure,
        summary: seed?.summary ?? '',
        rangeLabel: 'Treatments',
        mapCenter: seed?.mapCenter ?? clinics.first.coord,
        clinics: clinics,
      ),
    );
  }

  Future<void> _runSearch({required String q}) async {
    if (!mounted) return;
    final query = q.trim();
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _error = null;
        _isLoading = false;
        _hasSearched = false;
      });
      return;
    }

    final requestId = ++_searchRequestId;
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _hasSearched = true;
    });

    try {
      final res = _isWorldwide
          ? WorldwideCuratedClinics.search(query, pill: _pill)
          : await _openAI.search(
              query: query,
              city: _city,
              mode: _modeString,
              categoryPill: _pill,
            );
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _items = res;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _runSearch(q: q);
    });
  }

  @override
  void dispose() {
    _backgroundPoll?.cancel();
    _openAI.backgroundHuntNote.removeListener(_onBackgroundHunt);
    exploreInterestRevision.removeListener(_onInterestRevision);
    _cancelBackgroundAiWarm();
    _trendShimmerCtrl.dispose();
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    // Do not call [GoogleMapController.dispose] here — it can throw if the map
    // widget is already tearing down (see google_maps_flutter controller.dart).
    _mapController = null;
    _mapReady = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cmp = _comparison;
    final trendingStripH = _trendingCarouselHeight(context);
    final mapClinics = cmp == null
        ? const <OpenAIClinic>[]
        : exploreCompareClinics(
            cmp.clinics,
            procedure: cmp.topic.toLowerCase().startsWith('all')
                ? 'All'
                : cmp.topic,
            city: cmp.city,
            worldwide: WorldwideCuratedClinics.isWorldwide(cmp.city),
          );
    String? mapPriceSubtitle;
    if (cmp != null) {
      final isAll = cmp.topic.toLowerCase().startsWith('all');
      final rangePrice = isAll
          ? ''
          : clinicCompareAggregateRangeDisplay(
              mapClinics,
              procedure: cmp.topic,
            );
      var pricePart = rangePrice;
      if (pricePart.isEmpty && !isAll) {
        final fallback = cmp.rangeLabel.trim();
        final digits = fallback.replaceAll(RegExp(r'\D'), '');
        if (fallback.isNotEmpty && digits.length < 8) pricePart = fallback;
      }
      mapPriceSubtitle = pricePart.isEmpty
          ? _minMaxDistanceLabel(cmp)
          : '$pricePart · ${_minMaxDistanceLabel(cmp)}';
    }

    final visibleItems = _items.take(3).toList();
    final hiddenCount = _items.length - 3;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const ProcedureSectionLabel('Explore'),
                        const SizedBox(height: 8),
                        Text(
                          'Find & compare',
                          style: ProcedureSelectionTypography.display(
                            size: 22,
                            color: ProcedureSelectionTheme.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Search clinics and procedures near you.',
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: _openLocationSheet,
                          child: ProcedureGlassSurface(
                            borderRadius: BorderRadius.circular(999),
                            compact: true,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.place_rounded,
                                    size: 13,
                                    color: ProcedureSelectionTheme.ink,
                                  ),
                                  const SizedBox(width: 5),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _cityBootstrapped ? _city : '…',
                                        style:
                                            ProcedureSelectionTypography.label(
                                              size: 10,
                                              weight: FontWeight.w700,
                                              color:
                                                  ProcedureSelectionTheme.ink,
                                            ),
                                      ),
                                      Text(
                                        'Change',
                                        style:
                                            ProcedureSelectionTypography.body(
                                              size: 8,
                                              color: ProcedureSelectionTheme
                                                  .sectionLabel,
                                            ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SearchCircleButton(
                        icon: Icons.favorite_border_rounded,
                        onTap: _openFavorites,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(16),
                compact: true,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: ProcedureSelectionTheme.muted.withValues(
                          alpha: 0.7,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: _onQueryChanged,
                          onSubmitted: (v) => _runSearch(q: v),
                          textInputAction: TextInputAction.search,
                          style: ProcedureSelectionTypography.label(
                            size: 14,
                            weight: FontWeight.w600,
                            color: ProcedureSelectionTheme.ink,
                          ),
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: 'Search procedures, clinics...',
                            hintStyle: ProcedureSelectionTypography.body(
                              size: 14,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          ),
                        ),
                      ),
                      Material(
                        color: ProcedureSelectionTheme.buttonPrimary,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _openFilterScreen,
                          child: const SizedBox(
                            width: 36,
                            height: 36,
                            child: Icon(
                              Icons.tune_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isLoading ||
                _error != null ||
                _hasSearched ||
                _items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(
                    ProcedureSelectionTheme.cardRadius,
                  ),
                  compact: true,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'AI results',
                              style: ProcedureSelectionTypography.label(
                                size: 12,
                                weight: FontWeight.w800,
                                color: ProcedureSelectionTheme.ink,
                              ),
                            ),
                            const Spacer(),
                            if (!_openAI.canSearch)
                              Text(
                                'Search unavailable',
                                style: ProcedureSelectionTypography.label(
                                  size: 11,
                                  weight: FontWeight.w700,
                                  color: const Color(0xFFDD4444),
                                ),
                              ),
                            if (_isLoading) ...[
                              const SizedBox(width: 10),
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (!_openAI.canSearch)
                          Text(
                            'Search is temporarily unavailable. Please try again.',
                            style: ProcedureSelectionTypography.body(
                              size: 11,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          )
                        else if (_error != null)
                          Text(
                            _error!,
                            style: ProcedureSelectionTypography.body(
                              size: 11,
                              color: const Color(0xFFDD4444),
                            ),
                          )
                        else if (_items.isEmpty && !_hasSearched)
                          Text(
                            'Type to search. I\'ll suggest procedures/clinics'
                            '${_cityBootstrapped ? ' for $_city.' : ' for your area.'}',
                            style: ProcedureSelectionTypography.body(
                              size: 11,
                              color: ProcedureSelectionTheme.muted,
                            ),
                          )
                        else if (_items.isEmpty && _hasSearched) ...[
                          if (_looksLikeClinic(_searchController.text)) ...[
                            Text(
                              'No exact match — open this as a clinic:',
                              style: ProcedureSelectionTypography.body(
                                size: 11,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _AiResultTile(
                              item: OpenAISearchItem(
                                title: _searchController.text.trim(),
                                subtitle:
                                    '${_cityBootstrapped ? _city : '…'} · Open as clinic',
                                type: OpenAISearchItemType.clinic,
                                priceHint: null,
                              ),
                              onTap: () {
                                _searchFocusNode.unfocus();
                                Navigator.of(context).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) => ClinicProfileScreen(
                                      clinicName: _searchController.text.trim(),
                                      city: _city,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ] else
                            Text(
                              'No results found. Try a different name or check the spelling.',
                              style: ProcedureSelectionTypography.body(
                                size: 11,
                                color: ProcedureSelectionTheme.muted,
                              ),
                            ),
                        ] else ...[
                          ...visibleItems.map(
                            (it) => Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _AiResultTile(
                                item: it,
                                onTap: () {
                                  _searchFocusNode.unfocus();
                                  if (it.type == OpenAISearchItemType.clinic) {
                                    Navigator.of(context).push<void>(
                                      MaterialPageRoute<void>(
                                        builder: (_) => ClinicProfileScreen(
                                          clinicName: it.title,
                                          city: _city,
                                        ),
                                      ),
                                    );
                                  } else {
                                    Navigator.of(context).push<void>(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            ClinicsForProcedureScreen(
                                              procedureName: it.title,
                                              city: _city,
                                              aliases: it.aliases,
                                            ),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ),
                          ),
                          if (hiddenCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Material(
                                color: ProcedureSelectionTheme.fieldFill,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () => _openSearchResults(
                                    _searchController.text.trim(),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 11,
                                    ),
                                    child: Center(
                                      child: Text(
                                        'See more results',
                                        style:
                                            ProcedureSelectionTypography.label(
                                              size: 12,
                                              weight: FontWeight.w700,
                                              color:
                                                  ProcedureSelectionTheme.ink,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(
                  ProcedureSelectionTheme.cardRadius,
                ),
                compact: true,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    ProcedureSelectionTheme.cardRadius - 1,
                  ),
                  child: SizedBox(
                    height: 168,
                    child: Stack(
                      children: [
                        // Soft pearl wash behind the styled map tiles.
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                ProcedureSelectionTheme.pageBackgroundTop,
                                ProcedureSelectionTheme.pageBackground,
                                ProcedureSelectionTheme.pageBackgroundBottom,
                              ],
                            ),
                          ),
                        ),
                        if (_cityBootstrapped && _previewMapHosted)
                          GoogleMap(
                            key: ValueKey<String>('$_city-$_previewMapEpoch'),
                            style: GlowMapStyle.json,
                            initialCameraPosition: CameraPosition(
                              target: _resolvedMapCenter(cmp),
                              zoom: _mapZoomForCity,
                            ),
                            onMapCreated: (c) {
                              if (!mounted) return;
                              _mapController = c;
                              _mapReady = true;
                              if (!_mapReadyCompleter.isCompleted) {
                                _mapReadyCompleter.complete();
                              }
                              final center = _resolvedMapCenter(
                                _comparison ?? cmp,
                              );
                              unawaited(() async {
                                try {
                                  if (!mounted || !_mapReady) return;
                                  await c.moveCamera(
                                    CameraUpdate.newLatLngZoom(
                                      center,
                                      _mapZoomForCity,
                                    ),
                                  );
                                } catch (_) {}
                              }());
                            },
                            myLocationButtonEnabled: false,
                            zoomControlsEnabled: false,
                            compassEnabled: false,
                            buildingsEnabled: false,
                            rotateGesturesEnabled: false,
                            tiltGesturesEnabled: false,
                            // Price pins are visual-only on Explore; open Expand to interact.
                            scrollGesturesEnabled: false,
                            zoomGesturesEnabled: false,
                            markers: _previewMapMarkers.values.toSet(),
                          )
                        else
                          ColoredBox(
                            color: ProcedureSelectionTheme.pageBackground,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: ProcedureSelectionTheme.ink,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    _previewMapHosted
                                        ? 'Loading your area…'
                                        : 'Opening map…',
                                    style: ProcedureSelectionTypography.label(
                                      size: 12,
                                      weight: FontWeight.w600,
                                      color: ProcedureSelectionTheme.ink,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_cityBootstrapped &&
                            _previewMapHosted &&
                            _isMapLoading &&
                            // Cold pill search already shows the list searching
                            // card — stacking a second orb on the map made
                            // "0 clinics · Loading" + "Checking clinic prices…"
                            // appear at once (Boob job / Fillers cold start).
                            (_comparison?.clinics.isNotEmpty ?? false))
                          Positioned.fill(
                            child: Container(
                              color: Colors.white.withValues(alpha: 0.72),
                              alignment: Alignment.center,
                              child: const AgentWorkingIndicator(orbSize: 44),
                            ),
                          ),
                        if (_cityBootstrapped)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.white.withValues(alpha: 0.0),
                                    Colors.white.withValues(alpha: 0.82),
                                    Colors.white.withValues(alpha: 0.94),
                                  ],
                                  stops: const [0.0, 0.35, 1.0],
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          cmp == null ||
                                                  (_isLoadingMoreClinics &&
                                                      mapClinics.isEmpty)
                                              ? 'Searching verified clinics · $_city'
                                              : _isWorldwide
                                              ? '${mapClinics.length} clinics · $_pill · $_city'
                                              : '${mapClinics.length} clinics · $_pill · ${cmp.city}',
                                          style:
                                              ProcedureSelectionTypography.label(
                                                size: 10,
                                                weight: FontWeight.w600,
                                                color:
                                                    ProcedureSelectionTheme.ink,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          mapPriceSubtitle ??
                                              (_isWorldwide
                                                  ? 'Guide prices · tap a category'
                                                  : 'Tap a category pill to load AI top 5'),
                                          style:
                                              ProcedureSelectionTypography.body(
                                                size: 11,
                                                color: ProcedureSelectionTheme
                                                    .muted,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  FilledButton(
                                    onPressed:
                                        cmp == null || cmp.clinics.isEmpty
                                        ? null
                                        : () =>
                                              unawaited(_openExpandedMap(cmp)),
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          ProcedureSelectionTheme.buttonPrimary,
                                      foregroundColor: Colors.white,
                                      disabledBackgroundColor:
                                          ProcedureSelectionTheme.fieldFill,
                                      disabledForegroundColor:
                                          ProcedureSelectionTheme.muted,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: Text(
                                      'Expand',
                                      style: ProcedureSelectionTypography.label(
                                        size: 12,
                                        weight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
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
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: ProcedureSectionLabel(cmp?.topic ?? 'Top clinics'),
                  ),
                  if (!_cityBootstrapped || _isMapLoading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                ],
              ),
            ),
            if (_mapError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: ProcedureGlassSurface(
                  borderRadius: BorderRadius.circular(14),
                  compact: true,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _mapError!,
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: const Color(0xFFDD4444),
                      ),
                    ),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _cityBootstrapped
                    ? _ProcedureResultCard(
                        city: _city,
                        comparison: cmp,
                        procedureLabel: exploreVisibleComparePill(_pill),
                        selectedPill: exploreVisibleComparePill(_pill),
                        filterTags: _comparePills,
                        onSelectPill: _onPillSelected,
                        displayCurrency: _priceDisplayCurrencyFor(
                          cmp?.clinics ?? const [],
                        ),
                        loadingMore:
                            !_visibleCompareComplete &&
                            (_isLoadingMoreClinics ||
                                _discoveryActiveForCurrentPill),
                        backgroundNote: _backgroundNoteForCurrentPill,
                        onFindMore: _pill == 'All' || _isWorldwide
                            ? null
                            : _findMoreClinics,
                      )
                    : const SizedBox.shrink(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: const ProcedureSectionLabel('Trending procedures'),
            ),
            if (_trendingLoading)
              SizedBox(
                height: trendingStripH,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    for (var i = 0; i < 5; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: AnimatedBuilder(
                          animation: _trendShimmerCtrl,
                          builder: (_, _) {
                            final pulse =
                                Color.lerp(
                                  ProcedureSelectionTheme.fieldFill,
                                  Colors.white.withValues(alpha: 0.55),
                                  _trendShimmerCtrl.value,
                                ) ??
                                ProcedureSelectionTheme.fieldFill;
                            return ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: pulse),
                                child: SizedBox(
                                  width: 136,
                                  height: trendingStripH,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              )
            else
              SizedBox(
                height: trendingStripH,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    for (final proc
                        in (_trendingProcedures ?? const <TrendingProcedure>[]))
                      VisibilityDetector(
                        key: Key('trending-${proc.name}'),
                        onVisibilityChanged: (info) {
                          if (OpenAIService.disableClinicPreload) return;
                          if (_isWorldwide) return;
                          if (info.visibleFraction >= 0.5 &&
                              !_prewarmQueued.contains(proc.name)) {
                            _prewarmQueued.add(proc.name);
                            final index = (_trendingProcedures ?? [])
                                .indexWhere((p) => p.name == proc.name);
                            final staggerMs =
                                2000 + ((index < 0 ? 0 : index) * 8000);
                            Future<void>.delayed(
                              Duration(milliseconds: staggerMs),
                              () {
                                if (!mounted) return;
                                unawaited(
                                  _openAI.prewarmSingle(
                                    procedure: proc.name,
                                    city: _city,
                                  ),
                                );
                              },
                            );
                          }
                        },
                        child: _TrendingProcedureCard(
                          procedure: proc,
                          city: _city,
                          cardHeight: trendingStripH,
                          onTap: () => _openClinicsForProcedure(
                            proc.name,
                            nameLocal: proc.nameLocal,
                          ),
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
}

class _LiveResultsStrip extends StatelessWidget {
  const _LiveResultsStrip();

  static const _cardH = 168.0;
  static const _cardW = 148.0;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CommunityPost>>(
      stream: ProcedureRepository().communityPostsStream(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(16),
              compact: true,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  'Couldn’t load live results yet.',
                  style: ProcedureSelectionTypography.body(
                    size: 11,
                    color: ProcedureSelectionTheme.muted,
                  ),
                ),
              ),
            ),
          );
        }

        final posts = snap.data ?? const <CommunityPost>[];
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return SizedBox(
            height: _cardH,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: EdgeInsets.only(right: i == 2 ? 0 : 12),
                    child: ProcedureGlassSurface(
                      borderRadius: BorderRadius.circular(18),
                      compact: true,
                      child: SizedBox(width: _cardW, height: _cardH),
                    ),
                  ),
              ],
            ),
          );
        }

        if (posts.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(16),
              compact: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Row(
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      size: 18,
                      color: ProcedureSelectionTheme.muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Turn on Post live when you save a procedure to share your before & after here.',
                        style: ProcedureSelectionTypography.body(
                          size: 11,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SizedBox(
          height: _cardH,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: posts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => SizedBox(
              width: _cardW,
              child: _LiveResultCard(post: posts[i]),
            ),
          ),
        );
      },
    );
  }
}

class _LiveResultCard extends StatelessWidget {
  const _LiveResultCard({required this.post});

  final CommunityPost post;

  @override
  Widget build(BuildContext context) {
    final before = (post.beforePhotoUrl ?? '').trim();
    final after = (post.afterPhotoUrl ?? '').trim();
    final hasBefore = before.startsWith('http');
    final hasAfter = after.startsWith('http');

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(18),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _LivePhotoTile(
                      url: hasBefore ? before : null,
                      label: 'Before',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _LivePhotoTile(
                      url: hasAfter ? after : null,
                      label: 'After',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              post.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ProcedureSelectionTypography.label(
                size: 12,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              post.zoneLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ProcedureSelectionTypography.body(
                size: 10,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LivePhotoTile extends StatelessWidget {
  const _LivePhotoTile({required this.url, required this.label});

  final String? url;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: ProcedureSelectionTheme.ink.withValues(alpha: 0.06),
            child: url == null
                ? Icon(
                    Icons.image_outlined,
                    size: 18,
                    color: ProcedureSelectionTheme.muted,
                  )
                : Image.network(
                    url!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.broken_image_outlined,
                      size: 18,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
          ),
          Positioned(
            left: 5,
            bottom: 5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                label,
                style: ProcedureSelectionTypography.label(
                  size: 8,
                  weight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchCircleButton extends StatelessWidget {
  const _SearchCircleButton({required this.icon, required this.onTap});

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

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.active, required this.onTap});

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            selected: active,
            compact: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                text,
                style: ProcedureSelectionTypography.chip(
                  size: 11,
                  color: active ? Colors.white : ProcedureSelectionTheme.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Carousel row height: base 156, grows slightly under large text scales.
double _trendingCarouselHeight(BuildContext context) {
  final r = MediaQuery.textScalerOf(context).scale(13) / 13;
  final bump = ((r - 1.0).clamp(0.0, 0.55)) * 42;
  return 156 + bump;
}

String _minMaxDistanceLabel(OpenAIComparisonResult cmp) {
  final ds = cmp.clinics.map((e) => e.distanceMi).where((e) => e > 0).toList();
  if (ds.isEmpty) return '';
  ds.sort();
  return '${ds.first.toStringAsFixed(1)}–${ds.last.toStringAsFixed(1)} mi';
}

double _chartPriceAnchor(OpenAIClinic c) {
  if (c.pricePending || !explorePriceIsVerified(c)) return 0;
  if (c.priceMin > 0) return c.priceMin;
  if (c.priceGbp > 0) return c.priceGbp.toDouble();
  return 0;
}

class _ProcedureResultCard extends StatelessWidget {
  const _ProcedureResultCard({
    required this.city,
    required this.comparison,
    required this.procedureLabel,
    required this.selectedPill,
    required this.filterTags,
    required this.onSelectPill,
    required this.displayCurrency,
    this.loadingMore = false,
    this.backgroundNote = '',
    this.onFindMore,
  });

  final String city;
  final OpenAIComparisonResult? comparison;
  final String procedureLabel;
  final String selectedPill;
  final List<String> filterTags;
  final ValueChanged<String> onSelectPill;
  final FilterCurrency? displayCurrency;
  final bool loadingMore;
  final String backgroundNote;
  final VoidCallback? onFindMore;

  static int _avatarColor(String name) {
    // Match Saved compare cards: dark navy squircle + white initials.
    return 0xFF1A1A2E;
  }

  static String _initials(String name) {
    final parts = name.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).take(2);
    return parts.map((p) => p[0].toUpperCase()).join();
  }

  static String _cityOnly(String area) {
    var t = area.trim();
    t = t.replaceAll(RegExp(r'\s*·\s*src:https?://[^\s·]+'), '');
    t = t.replaceAll(RegExp(r'^src:https?://[^\s·]+'), '');
    t = t.replaceAll(RegExp(r'https?://[^\s·]+'), '');
    t = t.replaceAll(RegExp(r'\s*·\s*'), ' · ').trim();
    t = t.replaceAll(RegExp(r'^·\s*|\s*·$'), '').trim();
    // Drop leading regional-indicator flag emojis and other symbols.
    // `unicode: true` is REQUIRED here: `\u{...}` only denotes a code point in
    // Unicode mode, and without it this character-class range is invalid and
    // throws FormatException while building the card. These two patterns are
    // case-sensitive, so they avoid the slow caseInsensitive+unicode path.
    t = t.replaceAll(RegExp(r'^[\u{1F1E6}-\u{1F1FF}\s]+', unicode: true), '');
    t = t
        .replaceAll(RegExp(r'[\u{1F300}-\u{1FAFF}]', unicode: true), '')
        .trim();
    return t;
  }

  static String _cardProcedureLabel(
    OpenAIClinic clinic,
    String selectedPill, {
    String? topic,
  }) {
    return exploreCardProcedureLabel(
      clinic,
      selectedPill: selectedPill,
      topic: topic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cmp = comparison;
    final procedureName = procedureLabel.trim().isNotEmpty
        ? procedureLabel.trim()
        : (cmp?.topic.split('·').first.trim() ?? 'Botox');
    final filterProcedure = selectedPill == 'All'
        ? 'All'
        : explorePillAiSearchQuery(selectedPill);
    String displayRange = '';
    if (cmp != null && WorldwideCuratedClinics.isWorldwide(city)) {
      // Header shows the selected category — not "published price list".
      // On "All", each card already shows its own procedure for the price.
      displayRange = procedureName == 'All' ? '' : procedureName;
    } else if (cmp != null && selectedPill == 'All') {
      final n = exploreCompareClinics(
        cmp.clinics,
        procedure: 'All',
        city: city,
        worldwide: WorldwideCuratedClinics.isWorldwide(city),
      ).length;
      displayRange = n <= 0 ? '' : '$n procedures · verified prices';
    } else if (cmp != null && cmp.clinics.isNotEmpty) {
      displayRange = clinicCompareAggregateRangeDisplay(
        exploreCompareClinics(
          cmp.clinics,
          procedure: filterProcedure,
          city: city,
          worldwide: WorldwideCuratedClinics.isWorldwide(city),
        ),
        procedure: filterProcedure,
      );
    }
    final subtitleCity = cmp?.city ?? city;
    final sortedClinics = cmp == null
        ? const <OpenAIClinic>[]
        : exploreCompareClinics(
            cmp.clinics,
            procedure: filterProcedure,
            city: subtitleCity,
            worldwide: WorldwideCuratedClinics.isWorldwide(subtitleCity),
          );
    // One searching card for cold start (null cmp) and empty+still-filling —
    // never stack a bare "Loading" orb with a second "Checking clinic prices…"
    // card (Boob job / Fillers cold pill).
    final showInitialSearch = exploreShouldShowInitialSearch(
      hasComparison: cmp != null,
      verifiedCount: sortedClinics.length,
      loadingMore: loadingMore,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filters + summary stay above the procedure cards container.
        if (!WorldwideCuratedClinics.isWorldwide(city) &&
            !WorldwideCuratedClinics.isWorldwide(subtitleCity) &&
            (cmp == null || displayRange.trim().isNotEmpty)) ...[
          cmp == null
              ? Container(
                  height: 20,
                  width: 160,
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.fieldFill,
                    borderRadius: BorderRadius.circular(6),
                  ),
                )
              : _ExplorePriceSummaryBar(
                  priceRange: displayRange,
                  hideTypicalLabel: selectedPill == 'All',
                ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 36,
          child: _ExploreFilterPillStrip(
            tags: filterTags,
            selected: selectedPill,
            onSelect: onSelectPill,
          ),
        ),
        const SizedBox(height: 10),
        if (!showInitialSearch && sortedClinics.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${sortedClinics.length} clinics',
              style: ProcedureSelectionTypography.body(
                size: 11,
                color: ProcedureSelectionTheme.muted,
              ),
            ),
          ),
        if (!showInitialSearch && sortedClinics.isNotEmpty)
          const SizedBox(height: 12),
        if (showInitialSearch)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(16),
              compact: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
                child: ExploreClinicLoading(
                  city: subtitleCity.trim().isEmpty ? city : subtitleCity,
                ),
              ),
            ),
          )
        else if (sortedClinics.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(16),
              compact: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 22),
                child: Column(
                  children: [
                    Icon(
                      Icons.travel_explore_rounded,
                      size: 28,
                      color: ProcedureSelectionTheme.muted.withValues(
                        alpha: 0.85,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      exploreInsufficientDataMessage(
                        subtitleCity.trim().isEmpty ? city : subtitleCity,
                        procedure: procedureName,
                        cityHasCatalog: ExploreSeedCatalog.hasCityCoverage(
                          subtitleCity.trim().isEmpty ? city : subtitleCity,
                        ),
                        coverageStatus:
                            ExploreBackendService.instance
                                .lastCoverage(
                                  city: subtitleCity.trim().isEmpty
                                      ? city
                                      : subtitleCity,
                                  procedure: procedureName ?? '',
                                )
                                ?.discoveryStatus ??
                            '',
                      ),
                      textAlign: TextAlign.center,
                      style: ProcedureSelectionTypography.body(
                        size: 13,
                        color: ProcedureSelectionTheme.muted,
                      ).copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ListenableBuilder(
            listenable: SavedProceduresStore.instance,
            builder: (context, _) {
              return Column(
                children: [
                  for (var i = 0; i < sortedClinics.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    RepaintBoundary(
                      child: _ClinicCompareCard(
                        procedureName: _cardProcedureLabel(
                          sortedClinics[i],
                          selectedPill,
                          topic: cmp?.topic,
                        ),
                        clinic: sortedClinics[i],
                        location: _cityOnly(sortedClinics[i].area),
                        price: () {
                          final cl = sortedClinics[i];
                          final cardProc = _cardProcedureLabel(
                            cl,
                            selectedPill,
                            topic: cmp?.topic,
                          );
                          final converted = convertClinicPriceLabel(
                            cl,
                            displayCurrency,
                          );
                          if (converted != null) return converted;
                          if (WorldwideCuratedClinics.isWorldwide(
                            subtitleCity,
                          )) {
                            final label = cl.priceLabel.trim();
                            return label.isEmpty
                                ? 'On request'
                                : priceLabelCurrencyAfter(label);
                          }
                          final anchor = _chartPriceAnchor(cl);
                          final disp = clinicCompareProcedurePriceDisplay(
                            cl,
                            procedure: filterProcedure.isNotEmpty
                                ? filterProcedure
                                : cardProc,
                          );
                          return anchor > 0
                              ? (disp.isEmpty ? '—' : disp)
                              : 'On request';
                        }(),
                        avatarColor: _avatarColor(
                          exploreClinicDisplayName(sortedClinics[i]),
                        ),
                        initials: _initials(
                          exploreClinicDisplayName(sortedClinics[i]),
                        ),
                        saved: SavedProceduresStore.instance
                            .containsClinicProcedure(
                              exploreClinicDisplayName(sortedClinics[i]),
                              _cardProcedureLabel(
                                sortedClinics[i],
                                selectedPill,
                                topic: cmp?.topic,
                              ),
                            ),
                        onToggleSave: () {
                          final procTitle = _cardProcedureLabel(
                            sortedClinics[i],
                            selectedPill,
                            topic: cmp?.topic,
                          );
                          unawaited(
                            SavedProceduresStore.instance.toggleAtClinic(
                              clinicName: exploreClinicDisplayName(
                                sortedClinics[i],
                              ),
                              procedureName: procTitle,
                              city: _cityOnly(sortedClinics[i].area),
                              area: sortedClinics[i].area,
                              priceLabel: sortedClinics[i].priceLabel,
                              rating: sortedClinics[i].rating,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (loadingMore) ...[
                    const SizedBox(height: 16),
                    ExploreClinicLoading(
                      city: subtitleCity.trim().isEmpty ? city : subtitleCity,
                      compact: true,
                    ),
                  ],
                ],
              );
            },
          ),
        if (!showInitialSearch &&
            !loadingMore &&
            backgroundNote.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            backgroundNote,
            textAlign: TextAlign.center,
            style: ProcedureSelectionTypography.body(
              size: 12,
              color: ProcedureSelectionTheme.muted,
            ),
          ),
        ],
        if (!showInitialSearch && !loadingMore && onFindMore != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onFindMore,
              style: TextButton.styleFrom(
                foregroundColor: ProcedureSelectionTheme.muted,
                padding: const EdgeInsets.symmetric(horizontal: 0),
              ),
              child: const Text('Find more clinics'),
            ),
          ),
      ],
    );
  }
}

/// Horizontal procedure pills — keeps its own [ScrollController] so parent
/// rebuilds (clinic load) do not jump the strip back to the left.
class _ExploreFilterPillStrip extends StatefulWidget {
  const _ExploreFilterPillStrip({
    required this.tags,
    required this.selected,
    required this.onSelect,
  });

  final List<String> tags;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  State<_ExploreFilterPillStrip> createState() =>
      _ExploreFilterPillStripState();
}

class _ExploreFilterPillStripState extends State<_ExploreFilterPillStrip> {
  final ScrollController _controller = ScrollController();
  final Map<String, GlobalKey> _itemKeys = {};
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ExploreFilterPillStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != _selected && widget.selected != oldWidget.selected) {
      _selected = widget.selected;
    }
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSelectedVisible();
      });
    }
  }

  void _select(String tag) {
    if (tag == _selected) return;
    setState(() => _selected = tag);
    widget.onSelect(tag);
  }

  void _ensureSelectedVisible() {
    final key = _itemKeys[_selected];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const PageStorageKey<String>('explore_filter_pills'),
      controller: _controller,
      scrollDirection: Axis.horizontal,
      itemCount: widget.tags.length,
      separatorBuilder: (_, _) => const SizedBox(width: 14),
      itemBuilder: (context, i) {
        final tag = widget.tags[i];
        final itemKey = _itemKeys.putIfAbsent(tag, GlobalKey.new);
        return KeyedSubtree(
          key: itemKey,
          child: _SmallTag(
            text: tag,
            selected: _selected == tag,
            onTap: () => _select(tag),
          ),
        );
      },
    );
  }
}

/// Compact summary for city-level average price under the section title.
class _ExplorePriceSummaryBar extends StatelessWidget {
  const _ExplorePriceSummaryBar({
    required this.priceRange,
    this.hideTypicalLabel = false,
  });

  final String priceRange;
  final bool hideTypicalLabel;

  @override
  Widget build(BuildContext context) {
    final raw = compactExplorePriceRangeLabel(priceRange.trim());
    final hasFrom = raw.toLowerCase().startsWith('from ');
    final body = hasFrom ? raw.substring(5).trim() : raw;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (!hideTypicalLabel)
          Text(
            'Typical range',
            style: ProcedureSelectionTypography.body(
              size: 10,
              color: ProcedureSelectionTheme.sectionLabel,
            ),
          ),
        const Spacer(),
        Flexible(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: RichText(
                maxLines: 1,
                textAlign: TextAlign.right,
                text: TextSpan(
                  children: [
                    if (hasFrom)
                      TextSpan(
                        text: 'from ',
                        style: ProcedureSelectionTypography.body(
                          size: 10,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    TextSpan(
                      text: body,
                      style: ProcedureSelectionTypography.label(
                        size: 11,
                        weight: FontWeight.w700,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ClinicCompareCard extends StatelessWidget {
  const _ClinicCompareCard({
    required this.procedureName,
    required this.clinic,
    required this.location,
    required this.price,
    required this.avatarColor,
    required this.initials,
    required this.saved,
    required this.onToggleSave,
  });

  final String procedureName;
  final OpenAIClinic clinic;
  final String location;
  final String price;
  final int avatarColor;
  final String initials;
  final bool saved;
  final VoidCallback onToggleSave;

  @override
  Widget build(BuildContext context) {
    final rating = clinic.rating > 0 ? clinic.rating.toStringAsFixed(1) : '';
    final place = location.isEmpty ? 'Worldwide' : location;
    final sourceUrl = Uri.tryParse(clinic.priceSourceUrl);
    final canOpenSource =
        sourceUrl != null &&
        (sourceUrl.scheme == 'https' || sourceUrl.scheme == 'http');
    final platform = marketplacePlatformLabel(clinic.priceSourceUrl);
    final cardTitle = procedureName.startsWith('Breast augmentation · ')
        ? procedureName.replaceFirst(' · ', '\n')
        : procedureName;

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 14, 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Color(avatarColor),
                borderRadius: BorderRadius.circular(15),
              ),
              alignment: Alignment.center,
              child: Text(
                initials,
                style: ProcedureSelectionTypography.display(
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cardTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ProcedureSelectionTypography.label(
                      size: 11,
                      weight: FontWeight.w700,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 11,
                        color: Color(0xFFE6A817),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        rating.isNotEmpty ? rating : 'No rating',
                        style: ProcedureSelectionTypography.label(
                          size: 10,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.ink,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          exploreClinicDisplayName(clinic),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProcedureSelectionTypography.label(
                            size: 10,
                            weight: FontWeight.w600,
                            color: ProcedureSelectionTheme.ink.withValues(
                              alpha: 0.78,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 10,
                        color: ProcedureSelectionTheme.muted,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProcedureSelectionTypography.body(
                            size: 10,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (price.isNotEmpty) _PriceLabel(price: price),
                if (price.isNotEmpty && canOpenSource)
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: ProcedureSelectionTheme.muted,
                    ),
                    onPressed: () => launchUrl(
                      sourceUrl!,
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Text(
                      platform.isEmpty ? 'Published price' : '$platform price',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                if (price.isNotEmpty) const SizedBox(height: 12),
                Material(
                  color: saved
                      ? ProcedureSelectionTheme.buttonPrimary
                      : Colors.transparent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onToggleSave,
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: saved
                          ? null
                          : BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: ProcedureSelectionTheme.ink.withValues(
                                  alpha: 0.14,
                                ),
                              ),
                            ),
                      alignment: Alignment.center,
                      child: Icon(
                        saved
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 15,
                        color: saved
                            ? Colors.white
                            : ProcedureSelectionTheme.ink.withValues(
                                alpha: 0.75,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact price chip — amount stays small, never oversized.
class _PriceLabel extends StatelessWidget {
  const _PriceLabel({required this.price});

  final String price;

  @override
  Widget build(BuildContext context) {
    final raw = price.trim();
    final hasFrom = raw.toLowerCase().startsWith('from ');
    final body = hasFrom ? raw.substring(5).trim() : raw;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 110),
      child: RichText(
        textAlign: TextAlign.right,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          children: [
            if (hasFrom)
              TextSpan(
                text: 'from ',
                style: ProcedureSelectionTypography.body(
                  size: 9,
                  color: ProcedureSelectionTheme.muted,
                ),
              ),
            TextSpan(
              text: body,
              style: ProcedureSelectionTypography.label(
                size: 11,
                weight: FontWeight.w700,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.text, this.selected = false, this.onTap});

  final String text;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Underline-tab style — distinct from filled black pills.
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: selected ? 2 : 1,
            color: selected
                ? ProcedureSelectionTheme.ink
                : ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Text(
        text,
        style: ProcedureSelectionTypography.chip(
          size: 12,
          weight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected
              ? ProcedureSelectionTheme.ink
              : ProcedureSelectionTheme.muted,
        ),
      ),
    );

    if (onTap == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    );
  }
}

enum _ClinicBadgeVariant { best, mid, hi }

class _ClinicRow extends StatelessWidget {
  const _ClinicRow({
    required this.rank,
    required this.name,
    required this.dist,
    required this.area,
    required this.rating,
    required this.price,
    required this.badge,
    required this.badgeVariant,
  });

  final int rank;
  final String name;
  final String dist;
  final String area;
  final String rating;
  final String price;
  final String badge;
  final _ClinicBadgeVariant badgeVariant;

  @override
  Widget build(BuildContext context) {
    final badgeBg = switch (badgeVariant) {
      _ClinicBadgeVariant.best => ProcedureSelectionTheme.buttonPrimary,
      _ClinicBadgeVariant.mid => ProcedureSelectionTheme.fieldFill,
      _ClinicBadgeVariant.hi => const Color(0x22E85C5C),
    };
    final badgeFg = switch (badgeVariant) {
      _ClinicBadgeVariant.best => Colors.white,
      _ClinicBadgeVariant.mid => ProcedureSelectionTheme.muted,
      _ClinicBadgeVariant.hi => const Color(0xFFE85C5C),
    };
    final rankBg = switch (rank) {
      1 => ProcedureSelectionTheme.buttonPrimary,
      2 => ProcedureSelectionTheme.fieldFill,
      _ => ProcedureSelectionTheme.fieldFill,
    };
    final rankFg = switch (rank) {
      1 => Colors.white,
      2 => ProcedureSelectionTheme.muted,
      _ => ProcedureSelectionTheme.sectionLabel,
    };

    return InkWell(
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _searchDivider)),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: rankBg,
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: Alignment.center,
              child: Text(
                '$rank',
                style: ProcedureSelectionTypography.chip(
                  size: 10,
                  weight: FontWeight.w800,
                  color: rankFg,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ProcedureSelectionTypography.label(
                      size: 13,
                      weight: FontWeight.w600,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (dist.isNotEmpty) ...[
                        Text(
                          dist,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 2,
                          height: 2,
                          decoration: BoxDecoration(
                            color: ProcedureSelectionTheme.muted.withValues(
                              alpha: 0.45,
                            ),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ProcedureSelectionTypography.body(
                            size: 11,
                            color: ProcedureSelectionTheme.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('⭐', style: ProcedureSelectionTypography.body(size: 10)),
                const SizedBox(width: 3),
                Text(
                  rating,
                  style: ProcedureSelectionTypography.label(
                    size: 12,
                    weight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: ProcedureSelectionTypography.body(
                      size: 10,
                      weight: FontWeight.w600,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(20),
                      border: badgeVariant == _ClinicBadgeVariant.mid
                          ? Border.all(color: _searchDivider)
                          : null,
                    ),
                    child: Text(
                      badge.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ProcedureSelectionTypography.chip(
                        size: 9,
                        weight: FontWeight.w700,
                        color: badgeFg,
                      ),
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
}

class _TrendingProcedureCard extends StatelessWidget {
  const _TrendingProcedureCard({
    required this.procedure,
    required this.city,
    required this.cardHeight,
    required this.onTap,
  });

  final TrendingProcedure procedure;
  final String city;
  final double cardHeight;
  final VoidCallback onTap;

  static String _tagForProcedure(TrendingProcedure p) {
    final b = p.badge.trim().isEmpty ? 'Popular' : p.badge;
    final prefix = switch (b.toLowerCase()) {
      'trending' => '🔥 ',
      'popular' => '✨ ',
      'new' => '💜 ',
      'rising' => '⬆ ',
      'seasonal' => '☀️ ',
      _ => switch (p.trendDirection.trim().toLowerCase()) {
        'up' => '⬆ ',
        'down' => '⬇ ',
        _ => '→ ',
      },
    };
    return '$prefix$b'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final heroLine = procedure.name.trim().isNotEmpty ? procedure.name : '—';
    final categoryLine = procedure.category.trim();
    // Always English on the card — skip local-language aliases.
    final subLine = procedure.whyTrending.trim();
    final tag = _tagForProcedure(procedure);

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(16),
            compact: true,
            child: SizedBox(
              width: 136,
              height: cardHeight,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (categoryLine.isNotEmpty)
                      Text(
                        categoryLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.label(
                          size: 11,
                          weight: FontWeight.w600,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    if (categoryLine.isNotEmpty) const SizedBox(height: 4),
                    Text(
                      heroLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ProcedureSelectionTypography.display(
                        size: 14,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    if (subLine.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.body(
                          size: 10,
                          color: ProcedureSelectionTheme.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    // No star row here: this card is a procedure, not a
                    // clinic, and it has no rating to show. It used to print
                    // a hardcoded "⭐⭐⭐⭐⭐ 4.8" for every procedure in every
                    // city, which is a number we never measured.
                    Text(
                      city,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ProcedureSelectionTypography.body(
                        size: 10,
                        color: ProcedureSelectionTheme.sectionLabel,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: ProcedureSelectionTheme.fieldFill,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: _searchDivider),
                      ),
                      child: Text(
                        tag.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ProcedureSelectionTypography.chip(
                          size: 9,
                          weight: FontWeight.w700,
                          color: ProcedureSelectionTheme.sectionLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AiResultTile extends StatelessWidget {
  const _AiResultTile({required this.item, required this.onTap});

  final OpenAISearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isClinic = item.type == OpenAISearchItemType.clinic;
    final label = isClinic ? 'CLINIC' : 'PROCEDURE';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: ProcedureSelectionTheme.fieldFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _searchDivider),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 34,
              decoration: BoxDecoration(
                color: isClinic
                    ? ProcedureSelectionTheme.fieldFill
                    : ProcedureSelectionTheme.buttonPrimary,
                borderRadius: BorderRadius.circular(10),
                border: isClinic ? Border.all(color: _searchDivider) : null,
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: ProcedureSelectionTypography.chip(
                  size: 9,
                  weight: FontWeight.w900,
                  color: isClinic
                      ? ProcedureSelectionTheme.muted
                      : Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ProcedureSelectionTypography.label(
                      size: 12,
                      weight: FontWeight.w800,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if ((item.priceHint ?? '').trim().isNotEmpty)
              Text(
                item.priceHint!,
                style: ProcedureSelectionTypography.label(
                  size: 11,
                  weight: FontWeight.w800,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: ProcedureSelectionTheme.muted.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}
