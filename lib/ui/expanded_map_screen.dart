import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/openai_service.dart';
import '../services/worldwide_curated_clinics.dart';
import '../services/filter_currency.dart';
import 'glow_map_style.dart';
import 'map_price_pin_bitmap.dart';
import 'clinic_profile_screen.dart';
import 'filter_compare_screen.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';

/// Full-screen explore map styled to match procedure-form warm glass.
class ExpandedMapScreen extends StatefulWidget {
  const ExpandedMapScreen({
    super.key,
    required this.comparison,
    required this.city,
    this.initialFilters = CompareFilterResult.defaults,
  });

  final OpenAIComparisonResult comparison;
  final String city;
  final CompareFilterResult initialFilters;

  @override
  State<ExpandedMapScreen> createState() => _ExpandedMapScreenState();
}

enum _MapPill { all, bestPrice, topRated, nearest }

class _ExpandedMapScreenState extends State<ExpandedMapScreen> {
  static const _ink = ProcedureSelectionTheme.ink;
  static const _bg = ProcedureSelectionTheme.pageBackground;
  static const _bestTagBg = Color(0xFFE1F5EE);
  static const _bestTagFg = Color(0xFF0F6E56);
  static const _popTagBg = Color(0xFFEDE8F8);
  static const _popTagFg = Color(0xFF534AB7);
  static const _premTagBg = Color(0xFFFFF0F5);
  static const _premTagFg = Color(0xFFC4607A);

  GoogleMapController? _controller;
  OpenAIClinic? _selected;
  _MapPill _pill = _MapPill.all;
  Map<MarkerId, Marker> _markers = {};
  bool _mapAlive = false;
  int _markerLoadGen = 0;
  late CompareFilterResult _filters;
  late OpenAIComparisonResult _comparison;

  TextStyle get _urban => GoogleFonts.urbanist();

  FilterCurrency? get _displayCurrency => _filters.currency;

  @override
  void initState() {
    super.initState();
    _filters = widget.initialFilters;
    _comparison = widget.comparison;
    // No clinic selected until the user taps a pin — sheet stays hidden.
    _selected = null;
  }

  LatLng _positionFor(OpenAIClinic cl, int index) {
    final base = LatLng(_comparison.mapCenter.lat, _comparison.mapCenter.lng);
    return clinicMapLatLng(cl, base, index);
  }

  List<OpenAIClinic> get _sorted {
    final list = List<OpenAIClinic>.from(_comparison.clinics);
    switch (_pill) {
      case _MapPill.all:
        list.sort((a, b) => a.rank.compareTo(b.rank));
        break;
      case _MapPill.bestPrice:
        list.sort((a, b) {
          final pa = _priceSortKey(a);
          final pb = _priceSortKey(b);
          return pa.compareTo(pb);
        });
        break;
      case _MapPill.topRated:
        list.sort((a, b) {
          final rc = b.rating.compareTo(a.rating);
          if (rc != 0) return rc;
          return b.reviews.compareTo(a.reviews);
        });
        break;
      case _MapPill.nearest:
        list.sort((a, b) {
          final da = _nearestSortKey(a);
          final db = _nearestSortKey(b);
          return da.compareTo(db);
        });
        break;
    }
    return list;
  }

  double _priceSortKey(OpenAIClinic c) {
    if (!c.hasProcedure) return double.infinity;
    // Compare in USD so mixed Worldwide currencies sort fairly.
    final amount = c.priceMin > 0
        ? c.priceMin
        : (c.priceGbp > 0 ? c.priceGbp.toDouble() : 0);
    if (amount <= 0) return double.infinity;
    final code = FilterFx.detectCodeFromLabel(
      c.priceLabel,
      fallback: c.currency.trim().isNotEmpty ? c.currency : r'$',
    );
    final units = FilterFx.unitsPerUsdForCode(code);
    return amount / units; // USD
  }

  /// Prefer published distance; fall back to distance from map center (Worldwide).
  double _nearestSortKey(OpenAIClinic c) {
    if (c.distanceMi > 0) return c.distanceMi;
    final center = _comparison.mapCenter;
    final pos = LatLng(c.coord.lat, c.coord.lng);
    if (pos.latitude.abs() < 1e-5 && pos.longitude.abs() < 1e-5) {
      return double.infinity;
    }
    return _haversineMi(
      center.lat,
      center.lng,
      pos.latitude,
      pos.longitude,
    );
  }

  static double _haversineMi(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const r = 3958.8; // Earth radius miles
    final dLat = _degToRad(lat2 - lat1);
    final dLng = _degToRad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) *
            math.cos(_degToRad(lat2)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  static double _degToRad(double d) => d * math.pi / 180.0;

  String _chipLabel(OpenAIClinic c) {
    final v = c.badgeVariant.toLowerCase();
    if (c.badge.toLowerCase().contains('top rated')) return 'Top rated';
    if (v == 'best' || c.badge.toLowerCase().contains('best')) return 'Best price';
    if (v == 'hi' || c.badge.toLowerCase().contains('premium')) return 'Premium';
    if (c.badge.trim().isNotEmpty) return c.badge;
    return 'Popular';
  }

  (Color bg, Color fg) _chipColors(OpenAIClinic c) {
    final chipText = _chipLabel(c).toLowerCase();
    final v = c.badgeVariant.toLowerCase();
    if (chipText.contains('premium') || v == 'hi') {
      return (_premTagBg, _premTagFg);
    }
    if (chipText.contains('best')) {
      return (_bestTagBg, _bestTagFg);
    }
    return (_popTagBg, _popTagFg);
  }

  Future<void> _loadMarkers(List<OpenAIClinic> list) async {
    final gen = ++_markerLoadGen;
    if (list.isEmpty) {
      if (mounted && _mapAlive) setState(() => _markers = {});
      return;
    }
    final dpr = mounted
        ? math.max(MediaQuery.devicePixelRatioOf(context), 2.0)
        : 2.0;
    final next = <MarkerId, Marker>{};
    for (var i = 0; i < list.length; i++) {
      if (!mounted || !_mapAlive || gen != _markerLoadGen) return;
      final cl = list[i];
      final pos = _positionFor(cl, i);
      final desc = await buildMapPricePinDescriptor(
        clinic: cl,
        isSelected: _selected?.rank == cl.rank,
        pixelRatio: dpr,
        layout: MapPricePinLayout.standard,
        displayCurrency: _displayCurrency,
      );
      if (!mounted || !_mapAlive || gen != _markerLoadGen) return;
      next[MarkerId('c-${cl.rank}')] = Marker(
        markerId: MarkerId('c-${cl.rank}'),
        position: pos,
        anchor: const Offset(0.5, 1.0),
        zIndexInt: _selected?.rank == cl.rank ? 2 : 1,
        icon: desc,
        // Avoid Maps “lifted” selected marker cast that reads as a black shadow.
        flat: true,
        onTap: () => _onSelectClinic(cl),
      );
    }
    if (!mounted || !_mapAlive || gen != _markerLoadGen) return;
    setState(() => _markers = next);
  }

  Future<void> _onSelectClinic(OpenAIClinic c) async {
    if (!mounted || !_mapAlive) return;
    setState(() => _selected = c);
    await _loadMarkers(_sorted);
    await _animateTo(c);
  }

  Future<void> _clearSelection() async {
    if (!mounted || !_mapAlive || _selected == null) return;
    setState(() => _selected = null);
    await _loadMarkers(_sorted);
  }

  bool _sameTypes(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final e in a) {
      if (!b.contains(e)) return false;
    }
    return true;
  }

  Future<void> _animateTo(OpenAIClinic c) async {
    if (!mounted || !_mapAlive || _controller == null) return;
    final i = _comparison.clinics.indexWhere((x) => x.rank == c.rank);
    final pos = _positionFor(c, i >= 0 ? i : 0);
    // Worldwide pins are continents apart — don't city-zoom on select.
    final zoom = WorldwideCuratedClinics.isWorldwide(widget.city) ? 4.2 : 13.2;
    try {
      await _controller!.animateCamera(
        CameraUpdate.newLatLngZoom(pos, zoom),
      );
    } catch (_) {}
  }

  Future<void> _fitWorldwideBounds() async {
    if (!mounted || !_mapAlive || _controller == null) return;
    final list = _sorted;
    if (list.isEmpty) return;
    var minLat = 90.0;
    var maxLat = -90.0;
    var minLng = 180.0;
    var maxLng = -180.0;
    for (var i = 0; i < list.length; i++) {
      final p = _positionFor(list[i], i);
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    try {
      if (minLat >= maxLat || minLng >= maxLng) {
        await _controller!.moveCamera(
          CameraUpdate.newLatLngZoom(
            WorldwideCuratedClinics.mapCenter,
            WorldwideCuratedClinics.mapZoom,
          ),
        );
        return;
      }
      await _controller!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          48,
        ),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    // Mark dead first so in-flight marker/camera work aborts before the
    // platform view tears down (prevents iOS pigeon channel-error spam).
    _mapAlive = false;
    _markerLoadGen++;
    _markers = {};
    _controller = null;
    super.dispose();
  }

  Future<void> _popSafely() async {
    if (!_mapAlive && _controller == null && _markers.isEmpty) {
      if (mounted) Navigator.of(context).pop(_filters);
      return;
    }
    _mapAlive = false;
    _markerLoadGen++;
    if (mounted) {
      setState(() {
        _markers = {};
        _controller = null;
      });
    }
    // Give the platform a beat to apply empty overlays before the view dies.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (mounted) Navigator.of(context).pop(_filters);
  }

  void _onPill(_MapPill p) {
    setState(() => _pill = p);
    final list = _sorted;
    if (list.isEmpty) {
      _selected = null;
      if (_mapAlive) unawaited(_loadMarkers(list));
      return;
    }

    // All keeps the map overview; other pills jump to the winning clinic.
    if (p == _MapPill.all) {
      _selected = null;
      if (_mapAlive) {
        unawaited(_loadMarkers(list));
        if (WorldwideCuratedClinics.isWorldwide(widget.city)) {
          unawaited(_fitWorldwideBounds());
        }
      }
      return;
    }

    final top = list.first;
    _selected = top;
    if (_mapAlive) {
      unawaited(() async {
        await _loadMarkers(list);
        await _animateTo(top);
      }());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cmp = _comparison;
    final center = LatLng(cmp.mapCenter.lat, cmp.mapCenter.lng);
    final serif = GoogleFonts.dmSerifDisplay();

    final topSafe = MediaQuery.paddingOf(context).top;
    // Top chrome: back + search strip (+ filter) — pills sit below with air.
    const topRowHeight = 48.0;
    const searchBarBottomGap = 22.0;
    final pillsTop = topSafe + topRowHeight + searchBarBottomGap;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_popSafely());
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            GoogleMap(
            style: GlowMapStyle.json,
            initialCameraPosition: CameraPosition(
              target: center,
              zoom: WorldwideCuratedClinics.isWorldwide(widget.city)
                  ? WorldwideCuratedClinics.mapZoom
                  : 12,
            ),
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            buildingsEnabled: true,
            onMapCreated: (c) {
              if (!mounted) return;
              _controller = c;
              _mapAlive = true;
              unawaited(_loadMarkers(_sorted));
              if (WorldwideCuratedClinics.isWorldwide(widget.city)) {
                unawaited(_fitWorldwideBounds());
              } else if (_selected != null) {
                unawaited(_animateTo(_selected!));
              }
            },
            onTap: (_) => unawaited(_clearSelection()),
            markers: _mapAlive ? _markers.values.toSet() : const <Marker>{},
          ),
          // Top overlays — keep above GoogleMap (implicit z-order).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: SizedBox(
                  height: topRowHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: ProcedureGlassSurface(
                      borderRadius: BorderRadius.circular(999),
                      compact: true,
                      child: IconButton(
                        tooltip: 'Back',
                        padding: EdgeInsets.zero,
                        onPressed: () => unawaited(_popSafely()),
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          size: 22,
                          color: _ink,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ProcedureGlassSurface(
                      borderRadius: BorderRadius.circular(14),
                      compact: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search_rounded,
                              size: 16,
                              color: ProcedureSelectionTheme.muted
                                  .withValues(alpha: 0.75),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _mapHeaderTitle(cmp),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ProcedureSelectionTypography.label(
                                  size: 13,
                                  weight: FontWeight.w700,
                                  color: _ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        final picked = await showFilterCompareSheet(
                          context,
                          initial: _filters,
                        );
                        if (!mounted || picked == null) return;
                        final changed = picked.currency != _filters.currency ||
                            picked.priceMin != _filters.priceMin ||
                            picked.priceMax != _filters.priceMax ||
                            picked.priceMaxOpen != _filters.priceMaxOpen ||
                            picked.minRating != _filters.minRating ||
                            picked.doctorLedOnly != _filters.doctorLedOnly ||
                            picked.verifiedOnly != _filters.verifiedOnly ||
                            !_sameTypes(
                              picked.procedureTypes,
                              _filters.procedureTypes,
                            );
                        if (!changed) return;

                        setState(() {
                          _filters = picked;
                          _selected = null;
                          if (WorldwideCuratedClinics.isWorldwide(widget.city)) {
                            _comparison =
                                WorldwideCuratedClinics.buildComparisonForFilters(
                              types: picked.procedureTypes,
                              currency: picked.currency,
                              priceMin: picked.priceMin,
                              priceMax: picked.priceMax,
                              priceMaxOpen: picked.priceMaxOpen,
                              minRating: picked.minRating,
                              doctorLedOnly: picked.doctorLedOnly,
                              verifiedOnly: picked.verifiedOnly,
                            );
                          }
                        });
                        if (_mapAlive) {
                          unawaited(_loadMarkers(_sorted));
                          if (WorldwideCuratedClinics.isWorldwide(widget.city)) {
                            unawaited(_fitWorldwideBounds());
                          }
                        }
                      },
                      child: const SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(Icons.tune_rounded,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: pillsTop,
            left: 14,
            right: 90,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _mapPill('All', _pill == _MapPill.all, () => _onPill(_MapPill.all)),
                  _mapPill('Best price', _pill == _MapPill.bestPrice,
                      () => _onPill(_MapPill.bestPrice)),
                  _mapPill('Top rated', _pill == _MapPill.topRated,
                      () => _onPill(_MapPill.topRated)),
                  _mapPill('Nearest', _pill == _MapPill.nearest,
                      () => _onPill(_MapPill.nearest)),
                ],
              ),
            ),
          ),
          Positioned(
            top: pillsTop + 2,
            right: 14,
            child: ProcedureGlassSurface(
              borderRadius: BorderRadius.circular(20),
              compact: true,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  '${cmp.clinics.length} clinics',
                  style: ProcedureSelectionTypography.label(
                    size: 12,
                    weight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ),
            ),
          ),
          // Bottom sheet — only when a pin is selected (edge-to-edge).
          if (_selected != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: ProcedureGlassSurface(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(ProcedureSelectionTheme.cardRadius),
                ),
                compact: true,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 14),
                    child: Builder(
                        builder: (context) {
                          final cl = _selected!;
                          final chip = switch (_pill) {
                            _MapPill.bestPrice => 'Best price',
                            _MapPill.topRated => 'Top rated',
                            _MapPill.nearest => 'Nearest',
                            _MapPill.all => _chipLabel(cl),
                          };
                          final chipPair = switch (_pill) {
                            _MapPill.bestPrice => (_bestTagBg, _bestTagFg),
                            _MapPill.topRated => (_popTagBg, _popTagFg),
                            _MapPill.nearest => (_popTagBg, _popTagFg),
                            _MapPill.all => _chipColors(cl),
                          };
                          final tagBg = chipPair.$1;
                          final tagFg = chipPair.$2;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 36,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: ProcedureSelectionTheme.muted
                                      .withValues(alpha: 0.28),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: ProcedureSelectionTheme.cardBorder,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (cl.brand.trim().isNotEmpty) ...[
                                                  Text(
                                                    cl.brand.trim(),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style:
                                                        ProcedureSelectionTypography
                                                            .label(
                                                      size: 15,
                                                      weight: FontWeight.w800,
                                                      color: _ink,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    cl.name,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style:
                                                        ProcedureSelectionTypography
                                                            .body(
                                                      size: 13,
                                                      color:
                                                          ProcedureSelectionTheme
                                                              .muted,
                                                    ),
                                                  ),
                                                ] else
                                                  Text(
                                                    cl.name,
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style:
                                                        ProcedureSelectionTypography
                                                            .label(
                                                      size: 15,
                                                      weight: FontWeight.w800,
                                                      color: _ink,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (!cl.hasProcedure)
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: ProcedureSelectionTheme
                                                    .fieldFill,
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                'Procedure not listed',
                                                style:
                                                    ProcedureSelectionTypography
                                                        .body(
                                                  size: 10,
                                                  color: ProcedureSelectionTheme
                                                      .muted,
                                                ),
                                              ),
                                            )
                                          else
                                            Text(
                                              mapPricePinShortLabel(
                                                cl,
                                                displayCurrency:
                                                    _displayCurrency,
                                              ),
                                              style: serif.copyWith(
                                                fontSize: 18,
                                                color: _ink,
                                                height: 1,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.place_outlined,
                                            size: 12,
                                            color: ProcedureSelectionTheme.muted,
                                          ),
                                          const SizedBox(width: 3),
                                          Expanded(
                                            child: Text(
                                              cl.distanceMi > 0
                                                  ? '${cl.distanceMi.toStringAsFixed(1)} mi · ${cl.area}'
                                                  : cl.area,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  ProcedureSelectionTypography
                                                      .body(
                                                size: 12,
                                                color: ProcedureSelectionTheme
                                                    .muted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: tagBg,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: Text(
                                              chip,
                                              style: ProcedureSelectionTypography
                                                  .label(
                                                size: 10,
                                                weight: FontWeight.w600,
                                                color: tagFg,
                                              ),
                                            ),
                                          ),
                                          const Spacer(),
                                          Text(
                                            '★',
                                            style: _urban.copyWith(
                                              fontSize: 11,
                                              color: const Color(0xFFF5C842),
                                            ),
                                          ),
                                          const SizedBox(width: 3),
                                          Text(
                                            cl.rating.toStringAsFixed(1),
                                            style: ProcedureSelectionTypography
                                                .label(
                                              size: 12,
                                              weight: FontWeight.w700,
                                              color: _ink,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(18, 12, 18, 0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: FilledButton(
                                        onPressed: () {
                                          Navigator.of(context).push<void>(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  ClinicProfileScreen(
                                                clinicName: cl.name,
                                                city: widget.city,
                                              ),
                                            ),
                                          );
                                        },
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              ProcedureSelectionTheme
                                                  .buttonPrimary,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 13),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                        ),
                                        child: Text(
                                          'Book at ${cl.name}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: ProcedureSelectionTypography
                                              .label(
                                            size: 13,
                                            weight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton(
                                    onPressed: () =>
                                        Navigator.of(context).pop(_filters),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: _ink,
                                        backgroundColor: Colors.white
                                            .withValues(alpha: 0.55),
                                        side: BorderSide(
                                          color: ProcedureSelectionTheme
                                              .cardBorder,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 13,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: Text(
                                        'List view',
                                        style: ProcedureSelectionTypography
                                            .label(
                                          size: 13,
                                          weight: FontWeight.w700,
                                          color: _ink,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
      ),
    );
  }

  String _mapHeaderTitle(OpenAIComparisonResult cmp) {
    final topic = cmp.topic.trim();
    final city = widget.city.trim();
    if (city.isEmpty) return topic;
    if (topic.toLowerCase().contains(city.toLowerCase())) return topic;
    return '$topic · $city';
  }

  Widget _mapPill(String label, bool on, VoidCallback tap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: tap,
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(999),
            selected: on,
            compact: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                label,
                style: ProcedureSelectionTypography.chip(
                  size: 11,
                  color: on ? Colors.white : ProcedureSelectionTheme.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
