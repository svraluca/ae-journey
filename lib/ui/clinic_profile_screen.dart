import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/clinic_catalog_store.dart';
import '../services/google_places_service.dart';
import '../services/openai_service.dart';
import '../services/saved_bookmarks_store.dart';
import '../services/saved_procedures_store.dart';
import 'book_contact_sheet.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';
import 'widgets/thinking_orb.dart';

// ── Colors ────────────────────────────────────────────────────────────────────
// Aliased to the shared light-glass design tokens — kept as short local names
// since they are threaded through dozens of widgets below.
const _heroInk = ProcedureSelectionTheme.buttonPrimary;
const _ink = ProcedureSelectionTheme.ink;
const _muted = ProcedureSelectionTheme.muted;
const _soft = ProcedureSelectionTheme.sectionLabel;
const _heartRed = Color(0xFFE0577A);
const _surface = ProcedureSelectionTheme.fieldFill;
const _yellow = Color(0xFFE8B84B);
const _verifiedGreen = Color(0xFF2D7A4A);
const _verifiedBg = Color(0xFFE8F5EE);

/// Full clinic profile reached from the AI search tile (no procedure context).
class ClinicProfileScreen extends StatefulWidget {
  const ClinicProfileScreen({
    super.key,
    required this.clinicName,
    required this.city,
    this.websiteUrl,
  });

  final String clinicName;
  final String city;

  /// Optional URL from the clinics list (e.g. domain parsed from area).
  final String? websiteUrl;

  @override
  State<ClinicProfileScreen> createState() => _ClinicProfileScreenState();
}

class _ClinicProfileScreenState extends State<ClinicProfileScreen> {
  final _openAI = OpenAIService();
  final _places = GooglePlacesService();
  final _saved = SavedProceduresStore.instance;
  final _bookmarks = SavedBookmarksStore.instance;
  late String _city;
  bool _loading = true;
  bool _proceduresLoading = false;
  bool _loadingMoreProcedures = false;
  String? _error;
  OpenAIClinicProfilePage? _page;
  int _catIndex = 0;
  final _procedureSearchController = TextEditingController();
  String _procedureQuery = '';

  StreamSubscription<OpenAIClinicProfilePage>? _streamSub;
  /// True once the HTTP scrape has emitted at least one procedure with a real price.
  bool _hasRealData = false;

  // Progressive procedure loading — runs in parallel with the page stream
  // and pushes individual procedures into the UI as the model emits them.
  final List<OpenAIProfileProcedureRow> _streamedProcedures = [];
  bool _progressiveStreamActive = false;
  bool _procedureStreamStarted = false;

  /// When there are both priced and unpriced rows in the current filter, show
  /// priced first; user expands to see the rest.
  bool _showUnpricedExtras = false;

  List<String> get _tabs {
    final p = _page;
    if (p == null) return const ['All'];
    return ['All', ...p.categories];
  }

  /// Merged view: full HTTP scrape from [buildClinicProfilePageStream] wins
  /// when it has more rows than the early progressive stream (which only
  /// sees one price URL and can under-count or hallucinate).
  List<OpenAIProfileProcedureRow> get _activeProcedures {
    final p = _page;
    final pageProcs = p?.procedures ?? const <OpenAIProfileProcedureRow>[];
    if (_streamedProcedures.isEmpty) return pageProcs;
    if (pageProcs.length > _streamedProcedures.length) return pageProcs;
    final seen = _streamedProcedures
        .map((e) => e.name.trim().toLowerCase())
        .toSet();
    final extras = pageProcs.where(
      (e) => !seen.contains(e.name.trim().toLowerCase()),
    );
    return [..._streamedProcedures, ...extras];
  }

  List<OpenAIProfileProcedureRow> get _filteredProcedures {
    if (_page == null && _streamedProcedures.isEmpty) return const [];
    final all = _activeProcedures;
    final inCategory = () {
      if (_catIndex == 0) return all;
      final label = _tabs[_catIndex];
      return all.where((e) {
        final a = e.category.toLowerCase();
        final b = label.toLowerCase();
        return a == b || a.contains(b) || b.contains(a);
      }).toList();
    }();

    final q = _procedureQuery.trim().toLowerCase();
    if (q.isEmpty) return inCategory;
    return inCategory.where((p) {
      final name = p.name.toLowerCase();
      final detail = p.detail.toLowerCase();
      return name.contains(q) || detail.contains(q);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _city = widget.city;
    _bookmarks.addListener(_onBookmarksChanged);
    _load();
  }

  @override
  void dispose() {
    _bookmarks.removeListener(_onBookmarksChanged);
    _streamSub?.cancel();
    _procedureSearchController.dispose();
    super.dispose();
  }

  void _onBookmarksChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleClinicFavorite() async {
    final page = _page;
    await _bookmarks.toggleClinic(
      clinicName: widget.clinicName,
      city: _city,
      area: page?.area ?? '',
      rating: page?.rating ?? 0,
    );
  }

  Future<void> _toggleProcedureSaved(
    OpenAIClinicProfilePage page,
    OpenAIProfileProcedureRow proc,
  ) async {
    await _saved.toggleAtClinic(
      clinicName: widget.clinicName,
      procedureName: proc.name,
      city: _city,
      area: page.area,
      priceLabel: _pricePrimary(page, proc) ?? '',
      rating: page.rating,
    );
  }

  Future<void> _load() async {
    _streamSub?.cancel();
    _streamSub = null;
    setState(() {
      _loading = true;
      _proceduresLoading = false;
      _loadingMoreProcedures = false;
      _error = null;
      _page = null;
      _catIndex = 0;
      _hasRealData = false;
      _showUnpricedExtras = false;
      _streamedProcedures.clear();
      _progressiveStreamActive = false;
      _procedureStreamStarted = false;
    });
    try {
      // Cache-first: paint shared catalog instantly when another user (or this
      // device) already scraped this clinic.
      final cached = await ClinicCatalogStore.instance.get(
        clinicName: widget.clinicName,
        city: _city,
        websiteUrl: widget.websiteUrl,
      );

      if (!mounted) return;

      if (cached != null && cached.page.procedures.isNotEmpty) {
        setState(() {
          _page = cached.page;
          _loading = false;
          _hasRealData = cached.pricedCount > 0;
          _proceduresLoading = cached.isStale || cached.isHardExpired;
        });

        // Fresh catalog → only refresh Places contact; skip AI scrape.
        if (cached.isFresh) {
          unawaited(_refreshPlacesOnly());
          return;
        }

        // Stale / hard-expired → keep cached UI, refresh AI quietly.
        final placesRes = await _places.lookupClinic(
          clinicName: widget.clinicName,
          city: _city,
          includeReviews: true,
        );
        if (!mounted) return;
        setState(() {
          _page = _mergeWithPlaces(_page!, placesRes);
        });
        final websiteHint = _resolveWebsiteHint(placesRes);
        unawaited(_loadProceduresFromPricePage(websiteHint));
        _startStream(websiteHint);
        return;
      }

      // Phase 1 — fast (~5 s): hero/about/doctors + Google Places contact.
      final results = await Future.wait<Object?>([
        _openAI.buildClinicProfilePageMeta(
            clinicName: widget.clinicName, city: _city),
        _places.lookupClinic(
            clinicName: widget.clinicName, city: _city, includeReviews: true),
      ]);
      if (!mounted) return;
      final aiMeta = results[0] as OpenAIClinicProfilePage;
      final placesRes = results[1] as GooglePlacesResult?;
      setState(() {
        _page = _mergeWithPlaces(aiMeta, placesRes);
        _loading = false;
        _proceduresLoading = true;
      });

      // Phase 2 — streaming treatments: yields first batch ~8 s, full ~15 s.
      final websiteHint = _resolveWebsiteHint(placesRes);
      // Progressive procedure stream — fetches the price page directly and
      // yields procedures one-by-one. Runs in parallel; does not block the
      // existing page stream below.
      unawaited(_loadProceduresFromPricePage(websiteHint));
      _startStream(websiteHint);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _proceduresLoading = false;
      });
    }
  }

  Future<void> _refreshPlacesOnly() async {
    try {
      final placesRes = await _places.lookupClinic(
        clinicName: widget.clinicName,
        city: _city,
        includeReviews: true,
      );
      if (!mounted || _page == null) return;
      setState(() {
        _page = _mergeWithPlaces(_page!, placesRes);
        _proceduresLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _proceduresLoading = false);
    }
  }

  void _persistCatalogIfReady() {
    final page = _page;
    if (page == null) return;

    // Prefer the merged UI list (page scrape + progressive stream).
    final procs = _activeProcedures;
    final toSave = procs.isEmpty
        ? page
        : OpenAIClinicProfilePage(
            clinicName: page.clinicName,
            city: page.city,
            clinicTypeLabel: page.clinicTypeLabel,
            area: page.area,
            distanceMi: page.distanceMi,
            lat: page.lat,
            lng: page.lng,
            rating: page.rating,
            reviewsTotal: page.reviewsTotal,
            googlePlaceUrl: page.googlePlaceUrl,
            procedureCount: procs.length,
            doctorCount: page.doctors.length,
            isVerified: page.isVerified,
            isDoctorLed: page.isDoctorLed,
            heroTags: page.heroTags,
            about: page.about,
            currency: page.currency,
            priceRangeLabel: page.priceRangeLabel,
            priceMin: page.priceMin,
            priceMax: page.priceMax,
            categories: page.categories.isNotEmpty
                ? page.categories
                : procs
                    .map((e) => e.category.trim())
                    .where((e) => e.isNotEmpty)
                    .toSet()
                    .toList(),
            procedures: procs,
            doctors: page.doctors,
            contact: page.contact,
            reviews: page.reviews,
          );

    final website = _resolveWebsiteHint(null) ?? widget.websiteUrl;
    unawaited(
      ClinicCatalogStore.instance.savePage(
        page: toSave,
        websiteUrl: website,
      ),
    );
  }

  String? _resolveWebsiteHint(GooglePlacesResult? g) {
    final w = (g?.website ?? '').trim();
    if (w.isNotEmpty) return w;
    final pw = (_page?.contact.website ?? '').trim();
    return pw.isNotEmpty ? pw : null;
  }

  Future<void> _loadProceduresFromPricePage(String? websiteUrl) async {
    final url = (websiteUrl ?? '').trim();
    if (url.isEmpty) return;
    final base = url.replaceAll(RegExp(r'/+$'), '');

    final pricePageUrls = [
      '$base/preturi/',
      '$base/lista-preturi/',
      '$base/tarife/',
      '$base/prices/',
      '$base/price-list/',
    ];

    String bestText = '';
    for (final priceUrl in pricePageUrls) {
      final text = await _openAI.fetchPageText(priceUrl);
      if (text.length > bestText.length) bestText = text;
      if (bestText.length > 3000) break;
    }
    if (bestText.length < 500) {
      bestText = await _openAI.fetchPageText(base);
    }
    if (bestText.isEmpty || !mounted) return;
    await _startProcedureStream(
      pageText: bestText,
      clinicName: widget.clinicName,
      city: _city,
    );
  }

  Future<void> _startProcedureStream({
    required String pageText,
    required String clinicName,
    required String city,
  }) async {
    if (_procedureStreamStarted || pageText.isEmpty) return;
    _procedureStreamStarted = true;
    if (!mounted) return;
    setState(() => _progressiveStreamActive = true);

    await for (final proc in _openAI.extractProceduresStream(
      text: pageText,
      clinicName: clinicName,
      city: city,
    )) {
      if (!mounted) return;
      final key = proc.name.trim().toLowerCase();
      final dup = _streamedProcedures.any(
        (p) => p.name.trim().toLowerCase() == key,
      );
      if (!dup && proc.name.isNotEmpty) {
        setState(() => _streamedProcedures.add(proc));
      }
    }

    if (mounted) {
      setState(() => _progressiveStreamActive = false);
      _persistCatalogIfReady();
    }
  }

  void _startStream(String? websiteHint) {
    _streamSub?.cancel();
    _hasRealData = false;

    final websiteUrl = (widget.websiteUrl != null &&
            widget.websiteUrl!.trim().isNotEmpty)
        ? widget.websiteUrl!.trim()
        : websiteHint;

    _streamSub = _openAI
        .buildClinicProfilePageStream(
          clinicName: widget.clinicName,
          city: _city,
          websiteUrl: websiteUrl,
        )
        .listen(
      (page) {
        if (!mounted) return;
        final newRealPrices =
            page.procedures.where((p) => p.priceMin > 0).length;
        final currentRealPrices =
            _page?.procedures.where((p) => p.priceMin > 0).length ?? 0;

        setState(() {
          if (_page == null) {
            _page = page;
            _hasRealData = newRealPrices > 0;
          } else if (!_hasRealData && newRealPrices > 0) {
            _page = _mergeProcedures(_page!, page);
            _hasRealData = true;
          } else if (_hasRealData && newRealPrices >= currentRealPrices) {
            _page = _mergeProcedures(_page!, page);
          } else if (_hasRealData && newRealPrices < currentRealPrices) {
            _page = _mergePage(existing: _page!, incoming: page);
          }
          if (_hasRealData) {
            _loadingMoreProcedures = false;
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _proceduresLoading = false;
          _loadingMoreProcedures = false;
        });
        _persistCatalogIfReady();
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _proceduresLoading = false;
          _loadingMoreProcedures = false;
        });
        _persistCatalogIfReady();
      },
    );
  }

  /// Keeps existing procedures but updates clinic meta from incoming page.
  OpenAIClinicProfilePage _mergePage({
    required OpenAIClinicProfilePage existing,
    required OpenAIClinicProfilePage incoming,
  }) {
    final ic = incoming.contact;
    final ec = existing.contact;
    final mergedContact = OpenAIClinicContact(
      address: ic.address.isNotEmpty ? ic.address : ec.address,
      phone: ic.phone.isNotEmpty ? ic.phone : ec.phone,
      website: ic.website.isNotEmpty ? ic.website : ec.website,
      instagram: ic.instagram.isNotEmpty ? ic.instagram : ec.instagram,
      openingHours:
          ic.openingHours.isNotEmpty ? ic.openingHours : ec.openingHours,
      isOpenNow: ic.isOpenNow || ec.isOpenNow,
    );

    return OpenAIClinicProfilePage(
      clinicName: incoming.clinicName.isNotEmpty
          ? incoming.clinicName
          : existing.clinicName,
      city: incoming.city,
      clinicTypeLabel: incoming.clinicTypeLabel.isNotEmpty
          ? incoming.clinicTypeLabel
          : existing.clinicTypeLabel,
      area: incoming.area.isNotEmpty ? incoming.area : existing.area,
      distanceMi: incoming.distanceMi != 0
          ? incoming.distanceMi
          : existing.distanceMi,
      lat: incoming.lat != 0 ? incoming.lat : existing.lat,
      lng: incoming.lng != 0 ? incoming.lng : existing.lng,
      rating: incoming.rating > 0 ? incoming.rating : existing.rating,
      reviewsTotal: incoming.reviewsTotal > 0
          ? incoming.reviewsTotal
          : existing.reviewsTotal,
      googlePlaceUrl: incoming.googlePlaceUrl.isNotEmpty
          ? incoming.googlePlaceUrl
          : existing.googlePlaceUrl,
      procedureCount: existing.procedures.length,
      doctorCount: incoming.doctorCount > 0
          ? incoming.doctorCount
          : existing.doctorCount,
      isVerified: incoming.isVerified || existing.isVerified,
      isDoctorLed: incoming.isDoctorLed || existing.isDoctorLed,
      heroTags: incoming.heroTags.isNotEmpty
          ? incoming.heroTags
          : existing.heroTags,
      about: incoming.about.isNotEmpty ? incoming.about : existing.about,
      currency: incoming.currency.isNotEmpty
          ? incoming.currency
          : existing.currency,
      priceRangeLabel: existing.priceRangeLabel,
      priceMin: existing.priceMin,
      priceMax: existing.priceMax,
      categories: incoming.categories.isNotEmpty
          ? incoming.categories
          : existing.categories,
      procedures: existing.procedures,
      doctors: incoming.doctors.isNotEmpty
          ? incoming.doctors
          : existing.doctors,
      contact: mergedContact,
      reviews: incoming.reviews.isNotEmpty
          ? incoming.reviews
          : existing.reviews,
    );
  }

  OpenAIClinicProfilePage _mergeProcedures(
    OpenAIClinicProfilePage current,
    OpenAIClinicProfilePage withProcs,
  ) {
    return OpenAIClinicProfilePage(
      clinicName: current.clinicName,
      city: current.city,
      clinicTypeLabel: current.clinicTypeLabel,
      area: current.area,
      distanceMi: current.distanceMi,
      lat: current.lat,
      lng: current.lng,
      rating: current.rating,
      reviewsTotal: current.reviewsTotal,
      googlePlaceUrl: current.googlePlaceUrl,
      procedureCount: withProcs.procedures.length,
      doctorCount: withProcs.doctors.isNotEmpty
          ? withProcs.doctors.length
          : current.doctorCount,
      isVerified: current.isVerified,
      isDoctorLed: current.isDoctorLed,
      heroTags: current.heroTags,
      about: current.about,
      currency: current.currency.isNotEmpty
          ? current.currency
          : withProcs.currency,
      priceRangeLabel: withProcs.priceRangeLabel,
      priceMin: withProcs.priceMin,
      priceMax: withProcs.priceMax,
      categories: withProcs.categories.isNotEmpty
          ? withProcs.categories
          : current.categories,
      procedures: withProcs.procedures,
      doctors: withProcs.doctors.isNotEmpty
          ? withProcs.doctors
          : current.doctors,
      contact: current.contact,
      reviews: current.reviews,
    );
  }

  OpenAIClinicProfilePage _mergeWithPlaces(
      OpenAIClinicProfilePage ai, GooglePlacesResult? g) {
    // Rating, review count, and review text come from Google Places only.
    // Never fall back to AI values for these fields — the AI invents numbers
    // ("4.7 / 150 reviews") that don't match real Google data.
    final realRating = g?.rating ?? 0;
    final realReviewsTotal = g?.reviewsTotal ?? 0;
    final realReviews = (g?.reviews ?? const [])
        .map((r) => OpenAIClinicReview(
              authorName: r.authorName,
              initials: r.initials,
              date: r.relativeTime,
              dateIso: r.isoDate,
              rating: r.rating,
              text: r.text,
            ))
        .toList(growable: false);

    if (g == null) {
      // No Places match — strip AI's invented rating/reviewsTotal/reviews.
      return OpenAIClinicProfilePage(
        clinicName: ai.clinicName,
        city: ai.city,
        clinicTypeLabel: ai.clinicTypeLabel,
        area: ai.area,
        distanceMi: ai.distanceMi,
        lat: ai.lat,
        lng: ai.lng,
        rating: 0,
        reviewsTotal: 0,
        googlePlaceUrl: ai.googlePlaceUrl,
        procedureCount: ai.procedureCount,
        doctorCount: ai.doctorCount,
        isVerified: ai.isVerified,
        isDoctorLed: ai.isDoctorLed,
        heroTags: ai.heroTags,
        about: ai.about,
        currency: ai.currency,
        priceRangeLabel: ai.priceRangeLabel,
        priceMin: ai.priceMin,
        priceMax: ai.priceMax,
        categories: ai.categories,
        procedures: ai.procedures,
        doctors: ai.doctors,
        contact: ai.contact,
        reviews: const [],
      );
    }
    final contact = OpenAIClinicContact(
      address: g.address.isNotEmpty ? g.address : ai.contact.address,
      phone: g.phone.isNotEmpty ? g.phone : ai.contact.phone,
      website: g.website.isNotEmpty ? g.website : ai.contact.website,
      instagram: ai.contact.instagram,
      openingHours: g.openingHoursOneLine.isNotEmpty
          ? g.openingHoursOneLine
          : ai.contact.openingHours,
      isOpenNow: g.isOpenNow,
    );
    return OpenAIClinicProfilePage(
      clinicName: g.name.isNotEmpty ? g.name : ai.clinicName,
      city: ai.city,
      clinicTypeLabel: ai.clinicTypeLabel,
      area: g.area.isNotEmpty ? g.area : ai.area,
      distanceMi: ai.distanceMi,
      lat: g.lat != 0 ? g.lat : ai.lat,
      lng: g.lng != 0 ? g.lng : ai.lng,
      rating: realRating,
      reviewsTotal: realReviewsTotal,
      googlePlaceUrl: g.googleMapsUrl.isNotEmpty
          ? g.googleMapsUrl
          : ai.googlePlaceUrl,
      procedureCount: ai.procedureCount,
      doctorCount: ai.doctorCount,
      isVerified: ai.isVerified,
      isDoctorLed: ai.isDoctorLed,
      heroTags: ai.heroTags,
      about: g.editorialSummary.isNotEmpty
          ? g.editorialSummary
          : ai.about,
      currency: ai.currency,
      priceRangeLabel: ai.priceRangeLabel,
      priceMin: ai.priceMin,
      priceMax: ai.priceMax,
      categories: ai.categories,
      procedures: ai.procedures,
      doctors: ai.doctors,
      contact: contact,
      reviews: realReviews,
    );
  }

  Future<void> _launch(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open ${uri.scheme}')));
    }
  }

  Future<void> _onBookAppointment() async {
    final p = _page;
    if (p == null) return;

    final phone = await ensureBookingPhoneWithGooglePlaces(
      context: context,
      places: _places,
      clinicName: widget.clinicName,
      city: _city,
      mergedPhoneFromProfile: p.contact.phone,
    );

    if (!mounted) return;
    final trimmed = phone?.trim() ?? '';
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No phone number found. Open the clinic website or Google Maps from details above.',
          ),
        ),
      );
      return;
    }
    await showBookAppointmentSheet(
      context,
      clinicName: p.clinicName,
      phone: trimmed,
      rating: p.rating > 0 ? p.rating : null,
      procedureCount: p.procedureCount > 0
          ? p.procedureCount
          : (p.procedures.isNotEmpty ? p.procedures.length : null),
      isOpenNow: p.contact.isOpenNow,
      openingHoursOneLine: p.contact.openingHours,
      websiteUrl: () {
        final w = _url(p.contact.website);
        return w.isNotEmpty ? w : null;
      }(),
      instagramHandle:
          p.contact.instagram.trim().isEmpty ? null : p.contact.instagram.trim(),
    );
  }

  String _url(String w) {
    final t = w.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('http')) return t;
    return 'https://$t';
  }

  String _stars(double r) {
    final full = r.floor().clamp(0, 5);
    final half = (r - full) >= 0.5;
    final f = '★' * full + (half ? '★' : '');
    return '$f${'☆' * (5 - f.length)}';
  }

  bool _procedureHasListedPrice(OpenAIProfileProcedureRow proc) {
    if (proc.priceMin > 0 || proc.priceMax > 0) return true;
    final label = proc.priceLabel.trim();
    if (label.isEmpty) return false;
    return RegExp(r'\d').hasMatch(label);
  }

  String _tabLabel(String raw) => raw;

  String _formatIntPrice(double v) {
    final r = v.roundToDouble();
    return (v - r).abs() < 0.001 ? r.toInt().toString() : v.toStringAsFixed(0);
  }

  String? _pricePrimary(OpenAIClinicProfilePage page, OpenAIProfileProcedureRow proc) {
    // Prefer the label extracted directly from the website — it already has
    // the correct currency and format (e.g. "1050 RON", "£250", "659–1071 RON").
    var label = proc.priceLabel.trim();
    // Currency-only leftovers ("RON", "€") must not block numeric fallback.
    if (label.isNotEmpty && !RegExp(r'\d').hasMatch(label)) {
      label = '';
    }
    if (label.isNotEmpty) {
      // Strip dual-currency conversions like "650 € (3250 lei)".
      label = label
          .replaceAll(
            RegExp(r'\(\s*[\d.,]+\s*(?:lei|RON|ron)\s*\)', caseSensitive: false),
            '',
          )
          .trim();
      if (!RegExp(r'\d').hasMatch(label)) {
        label = '';
      }
      // If label looks like "€650–3250" where 3250 is a ~5× RON conversion, collapse to "€650".
      if (label.contains('€')) {
        final nums = RegExp(r'(\d+)')
            .allMatches(label)
            .map((m) => double.tryParse(m.group(1) ?? '') ?? 0)
            .where((n) => n > 0)
            .toList();
        if (nums.length >= 2) {
          final lo = nums.reduce((a, b) => a < b ? a : b);
          final hi = nums.reduce((a, b) => a > b ? a : b);
          final ratio = hi / lo;
          if (ratio >= 4.5 && ratio <= 5.5) label = '€${_formatIntPrice(lo)}';
        }
      }
    }
    if (label.isNotEmpty) return label;
    // Fallback: format from parsed numbers when no label was extracted.
    if (proc.priceMin > 0) {
      final lo = _formatIntPrice(proc.priceMin);
      final cur = page.currency.trim();
      if (cur.toUpperCase() == 'RON' || cur.toUpperCase() == 'LEI') return '$lo RON';
      if (cur == '£' || cur == r'$' || cur == '€') return '$cur$lo';
      if (cur.isEmpty) return lo;
      return '$lo $cur';
    }
    return null;
  }

  String? _priceUpTo(OpenAIClinicProfilePage page, OpenAIProfileProcedureRow proc) {
    // When a priceLabel is present it already encodes the full range — no
    // separate "Up to" line needed.
    if (proc.priceLabel.trim().isNotEmpty) return null;
    if (proc.priceMax <= proc.priceMin || proc.priceMax <= 0) return null;
    final hi = _formatIntPrice(proc.priceMax);
    final cur = page.currency.trim();
    if (cur.toUpperCase() == 'RON' || cur.toUpperCase() == 'LEI') return 'Up to RON $hi';
    if (cur == '£' || cur == r'$' || cur == '€') return 'Up to $cur$hi';
    if (cur.isEmpty) return 'Up to $hi';
    return 'Up to $cur $hi';
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sf = GoogleFonts.plusJakartaSans();
    final serif = GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800);

    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          // Fixed nav + Expanded body — structure never changes on setState so
          // the semantics tree stays stable across loading/content transitions.
          body: Column(
            children: [
              SafeArea(bottom: false, child: _buildNav(sf)),
              Expanded(
                child: Stack(
                  children: [
                    _buildBody(sf, serif),
                    if (!_loading && _error == null && _page != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _bookBar(),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Fixed nav ─────────────────────────────────────────────────────────────

  Widget _buildNav(TextStyle sf) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _circleBtn(Icons.chevron_left_rounded,
              () => Navigator.pop(context)),
          Row(
            children: [
              _circleBtn(Icons.ios_share_rounded, () {
                Clipboard.setData(ClipboardData(
                    text: '${widget.clinicName} · $_city'));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')));
              }),
              const SizedBox(width: 8),
              _circleBtn(
                _bookmarks.containsClinic(widget.clinicName)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                _toggleClinicFavorite,
                iconColor: _bookmarks.containsClinic(widget.clinicName) ? _heartRed : _ink,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap,
      {Color iconColor = _ink}) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(999),
      compact: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, size: 18, color: iconColor)),
        ),
      ),
    );
  }

  // ── Body (loading / error / content) ──────────────────────────────────────

  Widget _buildBody(TextStyle sf, TextStyle serif) {
    if (_loading) return _buildLoading(sf, serif);
    if (_error != null) return _buildError(sf);
    return _buildContent(sf, serif);
  }

  Widget _buildLoading(TextStyle sf, TextStyle serif) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
              strokeWidth: 2, color: _heroInk),
          const SizedBox(height: 16),
          Text(widget.clinicName,
              style: serif.copyWith(fontSize: 20, color: _ink),
              textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('Loading profile…',
              style: sf.copyWith(fontSize: 12, color: _muted)),
        ],
      ),
    );
  }

  Widget _buildProcedureSkeleton() {
    return Column(
      children: List.generate(
        4,
        (i) => Container(
          margin: const EdgeInsets.fromLTRB(0, 0, 0, 8),
          height: 72,
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Container(
                margin: const EdgeInsets.all(14),
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 13,
                      width: 120,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 11,
                      width: 80,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                margin: const EdgeInsets.only(right: 16),
                height: 13,
                width: 70,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(TextStyle sf) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 40, color: Color(0xFFDD4444)),
            const SizedBox(height: 12),
            Text('Couldn\'t load clinic',
                style: sf.copyWith(fontWeight: FontWeight.w700, color: _ink)),
            const SizedBox(height: 4),
            Text(_error!,
                style:
                    sf.copyWith(fontSize: 11, color: _muted),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }

  // ── Full content as flat keyed ListView ───────────────────────────────────

  Widget _buildContent(TextStyle sf, TextStyle serif) {
    final p = _page!;
    final contact = p.contact;
    final phone = contact.phone.replaceAll(RegExp(r'\s+'), '');
    final insta = contact.instagram.replaceAll('@', '');
    final mapQ = Uri.encodeComponent('${contact.address}, ${p.city}');
    final hasCoords = p.lat != 0 && p.lng != 0;
    final mapsUrl = hasCoords
        ? 'https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lng}'
        : (p.googlePlaceUrl.isNotEmpty
            ? p.googlePlaceUrl
            : 'https://www.google.com/maps/search/?api=1&query=$mapQ');

    final filteredAll = _filteredProcedures;
    final pricedFiltered =
        filteredAll.where(_procedureHasListedPrice).toList(growable: false);
    final hasHiddenUnpriced = pricedFiltered.isNotEmpty &&
        filteredAll.length > pricedFiltered.length;
    final proceduresVisible =
        (!hasHiddenUnpriced || _showUnpricedExtras) ? filteredAll : pricedFiltered;
    final anyProceduresLoaded = _activeProcedures.isNotEmpty;

    // Build a flat list — every item is a direct ListView child with a Key.
    // No Column-with-for-loop; no nested ListView.
    final items = <Widget>[
      _HeroSection(key: const ValueKey('hero'), page: p, clinicName: widget.clinicName, sf: sf, serif: serif),
      _StatsRow(
        key: const ValueKey('stats'),
        page: p,
        procedureCount: _activeProcedures.length,
        sf: sf,
        serif: serif,
        stars: _stars,
      ),
      const SizedBox(key: ValueKey('gap-actions'), height: 4),
      _QuickActions(
        key: const ValueKey('actions'),
        sf: sf,
        phone: phone,
        mapsUrl: mapsUrl,
        website: contact.website,
        instagram: insta,
        onLaunch: _launch,
        urlNormalize: _url,
      ),
      _softDivider('div1'),
      // Category tabs + section title — tab changes only update _catIndex
      _ProcedureHeader(
        key: ValueKey('proc-header-$_catIndex'),
        tabs: _tabs,
        catIndex: _catIndex,
        totalCount: _activeProcedures.length,
        shownCount: filteredAll.length,
        loadingMore: _loadingMoreProcedures || _progressiveStreamActive,
        sf: sf,
        onTabTap: (i) => setState(() {
          _catIndex = i;
          _showUnpricedExtras = false;
        }),
        tabLabel: _tabLabel,
      ),
      Padding(
        key: const ValueKey('proc-search'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
        child: ProcedureGlassSurface(
          borderRadius: BorderRadius.circular(14),
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 18, color: _muted.withValues(alpha: 0.7)),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _procedureSearchController,
                    onChanged: (v) => setState(() {
                      _procedureQuery = v;
                      _showUnpricedExtras = false;
                    }),
                    textInputAction: TextInputAction.search,
                    style: sf.copyWith(
                      fontSize: 13,
                      color: _ink,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: 'Search in this clinic…',
                      hintStyle: sf.copyWith(
                        fontSize: 13,
                        color: _muted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                if (_procedureQuery.trim().isNotEmpty)
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() {
                      _procedureQuery = '';
                      _procedureSearchController.clear();
                      _showUnpricedExtras = false;
                    }),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(Icons.close_rounded, size: 16, color: _muted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];

    // Do not blanket-hide rows while waiting for numeric `priceMin` — the price-page
    // stream often yields rows with `priceLabel` only until the main page stream merges.
    // Use unfiltered `_activeProcedures` so a category chip with zero matches shows
    // "No procedures" instead of this skeleton.
    final awaitingFirstBatch =
        !anyProceduresLoaded && !_hasRealData && _proceduresLoading;

    if (_page == null || awaitingFirstBatch) {
      items.add(Padding(
        key: const ValueKey('procs-skeleton-block'),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _heroInk,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Loading treatments…',
                  style: sf.copyWith(fontSize: 13, color: _muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildProcedureSkeleton(),
          ],
        ),
      ));
    } else if ((_proceduresLoading || _progressiveStreamActive) &&
        proceduresVisible.isEmpty &&
        !anyProceduresLoaded) {
      items.add(Padding(
        key: const ValueKey('procs-loading-row'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
        child: Row(children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: _heroInk),
          ),
          const SizedBox(width: 10),
          Text('Loading treatments…',
              style: sf.copyWith(fontSize: 13, color: _muted)),
        ]),
      ));
      for (var i = 0; i < 3; i++) {
        items.add(Padding(
          key: ValueKey('proc-skel-$i'),
          padding: EdgeInsets.fromLTRB(20, 0, 20, i < 2 ? 8 : 0),
          child: _SkeletonProcCard(),
        ));
      }
    } else if (proceduresVisible.isEmpty) {
      items.add(Padding(
        key: const ValueKey('no-procs'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text('No procedures in this category.',
            style: sf.copyWith(color: _muted, fontSize: 13)),
      ));
    } else {
      final pricesLoading =
          _proceduresLoading || _progressiveStreamActive || _loadingMoreProcedures;
      for (var i = 0; i < proceduresVisible.length; i++) {
        final proc = proceduresVisible[i];
        items.add(Padding(
          key: ValueKey('proc-${proc.name}'),
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, i == proceduresVisible.length - 1 ? 0 : 8),
          child: _ProcCard(
            page: p,
            proc: proc,
            clinicName: widget.clinicName,
            saved: _bookmarks.containsProcedure(widget.clinicName, proc.name),
            onToggleSaved: () => _toggleProcedureSaved(p, proc),
            sf: sf,
            serif: serif,
            pricesLoading: pricesLoading,
            pricePrimary: _pricePrimary,
            priceUpTo: _priceUpTo,
          ),
        ));
      }
      // "Loading more procedures" banner — visible between first and second stream emission.
      if (_loadingMoreProcedures || _progressiveStreamActive) {
        items.add(Padding(
          key: const ValueKey('loading-more-procs'),
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CupertinoActivityIndicator(radius: 8),
                const SizedBox(width: 8),
                Text(
                  'Finding more procedures…',
                  style: sf.copyWith(fontSize: 12, color: _muted),
                ),
              ],
            ),
          ),
        ));
      }
      if (hasHiddenUnpriced && !_showUnpricedExtras) {
        final n = filteredAll.length - pricedFiltered.length;
        final line = n == 1
            ? 'One more treatment has no scraped price yet'
            : '$n more treatments have no scraped price yet';
        items.add(Padding(
          key: const ValueKey('unpriced-reveal'),
          padding: EdgeInsets.fromLTRB(
            20, (_loadingMoreProcedures || _progressiveStreamActive) ? 6 : 0, 20, 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _showUnpricedExtras = true),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(14),
                compact: true,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.layers_outlined, size: 20, color: _ink),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(line,
                                style: sf.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _ink)),
                            const SizedBox(height: 3),
                            Text(
                              'We lead with verified prices · tap to browse the rest',
                              style: sf.copyWith(
                                  fontSize: 11, color: _muted, height: 1.35),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.keyboard_arrow_down_rounded,
                          color: _muted, size: 20),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
      }
      final web = contact.website.trim();
      if (web.isNotEmpty && filteredAll.isNotEmpty) {
        items.add(Padding(
          key: const ValueKey('catalog-website-footer'),
          padding:
              EdgeInsets.fromLTRB(20, hasHiddenUnpriced && _showUnpricedExtras ? 0 : 4, 20, 0),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => _launch(Uri.parse(_url(web))),
              child: ProcedureGlassSurface(
                borderRadius: BorderRadius.circular(14),
                compact: true,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.travel_explore_rounded,
                          size: 20, color: _ink),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Full catalog & freshest prices',
                                style: sf.copyWith(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _ink)),
                            const SizedBox(height: 3),
                            Text(
                              'Clinics sometimes update tariffs on their website first.',
                              style: sf.copyWith(
                                  fontSize: 11,
                                  color: _muted,
                                  height: 1.35),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.open_in_new_rounded,
                          size: 16, color: _muted.withValues(alpha: 0.7)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
      }
    }

    items.add(const SizedBox(key: ValueKey('gap1'), height: 16));
    items.add(_softDivider('div2'));

    if (p.about.isNotEmpty) {
      items.add(Padding(
        key: const ValueKey('about'),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Text(p.about,
            style: sf.copyWith(fontSize: 14, color: _muted, height: 1.7)),
      ));
      items.add(const SizedBox(key: ValueKey('gap2'), height: 16));
      items.add(_softDivider('div3'));
    }

    items.add(_ClinicDetailsSection(
      key: const ValueKey('details'),
      page: p,
      sf: sf,
      onLaunch: _launch,
      urlNormalize: _url,
    ));
    items.add(const SizedBox(key: ValueKey('gap4'), height: 16));
    items.add(_softDivider('div5'));

    final reviews = p.reviews.take(4).toList();
    if (reviews.isNotEmpty) {
      items.add(_ReviewsHeader(
          key: const ValueKey('rev-header'), page: p, sf: sf));
      for (var i = 0; i < reviews.length; i++) {
        items.add(Padding(
          key: ValueKey('rev-${reviews[i].authorName}-$i'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: _ReviewCard(review: reviews[i], sf: sf, stars: _stars),
        ));
      }
    }

    items.add(const SizedBox(key: ValueKey('bottom-pad'), height: 110));

    return ListView(padding: EdgeInsets.zero, children: items);
  }

  Widget _softDivider(String key) {
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 1,
        color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
      ),
    );
  }

  // ── Book bar ──────────────────────────────────────────────────────────────

  Widget _bookBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: ProcedurePremiumContinueButton(
          label: 'Book appointment',
          onPressed: _onBookAppointment,
        ),
      ),
    );
  }
}

// ── Skeleton card shown while procedures are loading ─────────────────────────

class _SkeletonProcCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 11,
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Hero section ──────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  const _HeroSection({
    super.key,
    required this.page,
    required this.clinicName,
    required this.sf,
    required this.serif,
  });
  final OpenAIClinicProfilePage page;
  final String clinicName;
  final TextStyle sf;
  final TextStyle serif;

  @override
  Widget build(BuildContext context) {
    final p = page;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(ProcedureSelectionTheme.cardRadius),
        illuminated: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  p.clinicTypeLabel,
                  p.city,
                  if (p.priceRangeLabel.isNotEmpty) p.priceRangeLabel,
                ]
                    .where((e) => e.isNotEmpty)
                    .join(' · ')
                    .toUpperCase(),
                style: sf.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.8,
                  color: _soft,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                p.clinicName.isNotEmpty ? p.clinicName : clinicName,
                style: serif.copyWith(fontSize: 22, color: _ink, height: 1.15),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.place_rounded, size: 12, color: _muted),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      p.distanceMi > 0
                          ? '${p.area} · ${p.distanceMi.toStringAsFixed(1)} mi away'
                          : p.area,
                      style: sf.copyWith(fontSize: 13, color: _muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  if (p.isVerified)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: _verifiedBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text('✓ Verified',
                          style: sf.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: _verifiedGreen)),
                    ),
                  if (p.isDoctorLed) _heroChip('Doctor-led', sf),
                  for (final t in p.heroTags.take(6)) _heroChip(t, sf),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroChip(String text, TextStyle sf) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: sf.copyWith(
              fontSize: 11, fontWeight: FontWeight.w600, color: _muted)),
    );
  }
}

// ── Stats row ─────────────────────────────────────────────────────────────────

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    super.key,
    required this.page,
    required this.procedureCount,
    required this.sf,
    required this.serif,
    required this.stars,
  });
  final OpenAIClinicProfilePage page;
  final int procedureCount;
  final TextStyle sf;
  final TextStyle serif;
  final String Function(double) stars;

  @override
  Widget build(BuildContext context) {
    Widget col({
      required Widget top,
      required String val,
      required String label,
    }) {
      return Expanded(
        child: Column(
          children: [
            top,
            const SizedBox(height: 3),
            Text(val, style: serif.copyWith(fontSize: 20, color: _ink, height: 1)),
            const SizedBox(height: 3),
            Text(
              label.toUpperCase(),
              style: sf.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _soft,
                  letterSpacing: 0.6),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(18),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: IntrinsicHeight(
            child: Row(
              children: [
                col(
                  top: Text(stars(page.rating),
                      style: const TextStyle(
                          color: _yellow, fontSize: 14, letterSpacing: -1)),
                  val: page.rating.toStringAsFixed(1),
                  label: 'Rating',
                ),
                Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08),
                ),
                col(
                  top: const SizedBox(height: 14),
                  val: '$procedureCount',
                  label: 'Procedures',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Quick actions ─────────────────────────────────────────────────────────────

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    super.key,
    required this.sf,
    required this.phone,
    required this.mapsUrl,
    required this.website,
    required this.instagram,
    required this.onLaunch,
    required this.urlNormalize,
  });
  final TextStyle sf;
  final String phone;
  final String mapsUrl;
  final String website;
  final String instagram;
  final Future<void> Function(Uri) onLaunch;
  final String Function(String) urlNormalize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Expanded(
            child: _QA(
                icon: Icons.call_rounded,
                label: 'Call',
                sf: sf,
                onTap: phone.isEmpty
                    ? null
                    : () => onLaunch(Uri(scheme: 'tel', path: phone))),
          ),
          Expanded(
            child: _QA(
                icon: Icons.near_me_rounded,
                label: 'Directions',
                sf: sf,
                onTap: () => onLaunch(Uri.parse(mapsUrl))),
          ),
          Expanded(
            child: _QA(
                icon: Icons.public_rounded,
                label: 'Website',
                sf: sf,
                onTap: website.isEmpty
                    ? null
                    : () => onLaunch(Uri.parse(urlNormalize(website)))),
          ),
          Expanded(
            child: _QA(
                icon: Icons.camera_alt_outlined,
                label: 'Instagram',
                sf: sf,
                onTap: instagram.isEmpty
                    ? null
                    : () => onLaunch(Uri.parse(
                        'https://instagram.com/$instagram'))),
          ),
        ],
      ),
    );
  }
}

class _QA extends StatelessWidget {
  const _QA({
    required this.icon,
    required this.label,
    required this.sf,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final TextStyle sf;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.35 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Column(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: ProcedureGlassDecorations.iconBadge(),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: _ink),
              ),
              const SizedBox(height: 6),
              Text(label,
                  style: sf.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: _muted)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Procedure section header (title + category tabs) ─────────────────────────

class _ProcedureHeader extends StatelessWidget {
  const _ProcedureHeader({
    super.key,
    required this.tabs,
    required this.catIndex,
    required this.totalCount,
    required this.shownCount,
    required this.loadingMore,
    required this.sf,
    required this.onTabTap,
    required this.tabLabel,
  });
  final List<String> tabs;
  final int catIndex;
  final int totalCount;
  final int shownCount;
  final bool loadingMore;
  final TextStyle sf;
  final ValueChanged<int> onTabTap;
  final String Function(String) tabLabel;

  @override
  Widget build(BuildContext context) {
    final filterNote = catIndex == 0 ? '' : ' · $shownCount shown';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ProcedureSectionLabel('Procedures & prices'),
              ),
              if (loadingMore) ...[
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: _muted),
                ),
                const SizedBox(width: 5),
              ],
              Text('$totalCount$filterNote',
                  style: sf.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _muted)),
            ],
          ),
          const SizedBox(height: 12),
          // SingleChildScrollView + Row avoids nested ListView semantics conflict.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  _TabChip(
                    label: tabLabel(tabs[i]),
                    active: i == catIndex,
                    sf: sf,
                    onTap: () => onTabTap(i),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.sf,
    required this.onTap,
  });
  final String label;
  final bool active;
  final TextStyle sf;
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
          selected: active,
          compact: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(label,
                style: sf.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : _muted)),
          ),
        ),
      ),
    );
  }
}

// ── Procedure card ────────────────────────────────────────────────────────────

class _ProcCard extends StatelessWidget {
  const _ProcCard({
    required this.page,
    required this.proc,
    required this.clinicName,
    required this.saved,
    required this.onToggleSaved,
    required this.sf,
    required this.serif,
    required this.pricesLoading,
    required this.pricePrimary,
    required this.priceUpTo,
  });
  final OpenAIClinicProfilePage page;
  final OpenAIProfileProcedureRow proc;
  final String clinicName;
  final bool saved;
  final VoidCallback onToggleSaved;
  final TextStyle sf;
  final TextStyle serif;
  final bool pricesLoading;
  final String? Function(OpenAIClinicProfilePage, OpenAIProfileProcedureRow) pricePrimary;
  final String? Function(OpenAIClinicProfilePage, OpenAIProfileProcedureRow) priceUpTo;

  @override
  Widget build(BuildContext context) {
    final top = proc.featured;
    final primary = pricePrimary(page, proc);
    final upTo = priceUpTo(page, proc);
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      illuminated: top,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(proc.name,
                            style: sf.copyWith(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _ink)),
                      ),
                      if (top) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: ProcedureSelectionTheme.buttonPrimary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('FEATURED',
                              style: sf.copyWith(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  color: Colors.white)),
                        ),
                      ],
                    ],
                  ),
                  if (proc.tags.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 5,
                      children: [
                        for (final tag in proc.tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _surface,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(tag,
                                style: sf.copyWith(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: _muted)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (primary != null) ...[
                  Text('FROM',
                      style: sf.copyWith(
                          fontSize: 9, color: _soft, letterSpacing: 0.6)),
                  const SizedBox(height: 4),
                  Text(primary,
                      style: serif.copyWith(
                          fontSize: 13, color: _ink, height: 1)),
                  if (upTo != null) ...[
                    const SizedBox(height: 2),
                    Text(upTo,
                        style: sf.copyWith(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: _muted)),
                  ],
                ] else if (pricesLoading)
                  const AgentBreathingIndicator(mutedColor: _soft)
                else
                  Text('On request',
                      style: sf.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _muted,
                          letterSpacing: 0.44)),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onToggleSaved,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      size: 18,
                      color: _heartRed,
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

// ── Doctors section ───────────────────────────────────────────────────────────

class _DoctorsSection extends StatelessWidget {
  const _DoctorsSection(
      {super.key,
      required this.page,
      required this.sf,
      required this.serif});
  final OpenAIClinicProfilePage page;
  final TextStyle sf;
  final TextStyle serif;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: ProcedureSectionLabel('Our doctors'),
        ),
        // SingleChildScrollView + Row avoids nested ListView semantics conflict.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < page.doctors.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                _DoctorCard(
                    doctor: page.doctors[i],
                    index: i,
                    sf: sf,
                    serif: serif),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DoctorCard extends StatelessWidget {
  const _DoctorCard({
    required this.doctor,
    required this.index,
    required this.sf,
    required this.serif,
  });
  final OpenAIProfileDoctor doctor;
  final int index;
  final TextStyle sf;
  final TextStyle serif;

  @override
  Widget build(BuildContext context) {
    final spec = [
      if (doctor.specialty.isNotEmpty) doctor.specialty,
      if (doctor.yearsExperience > 0) '${doctor.yearsExperience}y exp.',
    ].join(' · ');
    return SizedBox(
      width: 112,
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(16),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(doctor.initials,
                    style:
                        serif.copyWith(fontSize: 16, color: Colors.white)),
              ),
              const SizedBox(height: 8),
              Text(doctor.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sf.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _ink)),
              const SizedBox(height: 2),
              Text(spec,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: sf.copyWith(fontSize: 10, color: _soft)),
              if (doctor.badge.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                      color: _verifiedBg,
                      borderRadius: BorderRadius.circular(20)),
                  child: Text(doctor.badge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sf.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: _verifiedGreen)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Clinic details section ────────────────────────────────────────────────────

class _ClinicDetailsSection extends StatelessWidget {
  const _ClinicDetailsSection({
    super.key,
    required this.page,
    required this.sf,
    required this.onLaunch,
    required this.urlNormalize,
  });
  final OpenAIClinicProfilePage page;
  final TextStyle sf;
  final Future<void> Function(Uri) onLaunch;
  final String Function(String) urlNormalize;

  @override
  Widget build(BuildContext context) {
    final c = page.contact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: ProcedureSectionLabel('Clinic details'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(16),
            compact: true,
            child: Column(
              children: [
                if (c.address.isNotEmpty)
                  _InfoRow(
                    icon: Icons.place_outlined,
                    label: 'Address',
                    value: c.address,
                    sf: sf,
                    onTap: () => onLaunch(Uri.parse(
                        'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${c.address}, ${page.city}')}')),
                  ),
                if (c.phone.isNotEmpty)
                  _InfoRow(
                    icon: Icons.call_outlined,
                    label: 'Phone',
                    value: c.phone,
                    sf: sf,
                    link: true,
                    onTap: () => onLaunch(Uri(
                        scheme: 'tel',
                        path: c.phone
                            .replaceAll(RegExp(r'\s+'), ''))),
                  ),
                if (c.website.isNotEmpty)
                  _InfoRow(
                    icon: Icons.public,
                    label: 'Website',
                    value: c.website,
                    sf: sf,
                    link: true,
                    onTap: () =>
                        onLaunch(Uri.parse(urlNormalize(c.website))),
                  ),
                _InfoRow(
                  icon: Icons.schedule,
                  label: 'Hours',
                  value: c.openingHours,
                  sf: sf,
                  trailing: c.isOpenNow
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                              color: const Color(0xFFE8F5EE),
                              borderRadius: BorderRadius.circular(20)),
                          child: Text('Open now',
                              style: sf.copyWith(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF2D7A4A))),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.sf,
    this.onTap,
    this.link = false,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final String value;
  final TextStyle sf;
  final VoidCallback? onTap;
  final bool link;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    color: ProcedureSelectionTheme.ink.withValues(alpha: 0.08)))),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(icon, size: 15, color: _muted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: sf.copyWith(
                          fontSize: 11,
                          color: _soft,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Text(value,
                            style: sf.copyWith(
                                fontSize: 13,
                                fontWeight:
                                    link ? FontWeight.w700 : FontWeight.w600,
                                color: _ink)),
                      ),
                      ?trailing,
                    ],
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: _muted.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

// ── Reviews ───────────────────────────────────────────────────────────────────

class _ReviewsHeader extends StatelessWidget {
  const _ReviewsHeader({super.key, required this.page, required this.sf});
  final OpenAIClinicProfilePage page;
  final TextStyle sf;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: ProcedureSectionLabel('Reviews'),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.review,
    required this.sf,
    required this.stars,
  });
  final OpenAIClinicReview review;
  final TextStyle sf;
  final String Function(double) stars;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(16),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                      color: ProcedureSelectionTheme.buttonPrimary,
                      shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: Text(review.initials,
                      style: sf.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(review.authorName,
                          style: sf.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _ink)),
                      Text(review.date,
                          style:
                              sf.copyWith(fontSize: 11, color: _soft)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(stars(review.rating),
                style: const TextStyle(color: _yellow, fontSize: 12)),
            const SizedBox(height: 5),
            Text(review.text,
                style: sf.copyWith(fontSize: 13, color: _muted, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
