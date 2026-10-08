import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/clinic_catalog_store.dart';
import '../services/google_places_service.dart';
import '../services/openai_service.dart';
import '../services/saved_bookmarks_store.dart';
import 'book_contact_sheet.dart';
import 'procedure_icon_resolver.dart';
import 'procedure_selection_theme.dart';
import 'widgets/procedure_selection_widgets.dart';
import 'widgets/step2_warm_background.dart';

/// Procedure-focused clinic detail page. Shown when a user taps a clinic in
/// the clinics-for-procedure list.
class ClinicDetailScreen extends StatefulWidget {
  const ClinicDetailScreen({
    super.key,
    required this.clinic,
    required this.city,
    required this.procedureContext,
    this.aliases = const [],
    this.websiteUrl,
    this.knownRating = 0.0,
    this.knownReviews = 0,
  });

  /// The clinic the user tapped on (used to render the hero immediately while
  /// the AI profile loads in the background).
  final OpenAIClinic clinic;
  final String city;

  /// The procedure the user was searching for (e.g. "Lip filler").
  final String procedureContext;

  /// Multilingual synonyms forwarded so the AI can match the procedure under
  /// any language.
  final List<String> aliases;

  /// Website from list area string (e.g. https://drestetix.ro/) for HTTP scrape + AI search.
  final String? websiteUrl;

  /// Feed list rating/reviews — preferred over AI when greater than 0.
  final double knownRating;
  final int knownReviews;

  @override
  State<ClinicDetailScreen> createState() => _ClinicDetailScreenState();
}

class _ClinicDetailScreenState extends State<ClinicDetailScreen> {
  static const _heartRed = Color(0xFFE53935);
  static const _yellow = Color(0xFFF5C842);
  static const _verifiedBg = Color(0x1F2E9B57);
  static const _verifiedFg = Color(0xFF1E7A42);
  static const _softDivider = Color(0x1A1A1A1F);

  final _openAI = OpenAIService();
  final _places = GooglePlacesService();
  bool _isLoading = false;
  String? _error;
  OpenAIClinicProfile? _profile;
  GooglePlacesResult? _placesResult;
  bool _favorited = false;

  final _bookmarks = SavedBookmarksStore.instance;

  @override
  void initState() {
    super.initState();
    _bookmarks.addListener(_onBookmarksChanged);
    _favorited = _bookmarks.containsClinic(widget.clinic.name);
    _load();
  }

  @override
  void dispose() {
    _bookmarks.removeListener(_onBookmarksChanged);
    super.dispose();
  }

  void _onBookmarksChanged() {
    if (!mounted) return;
    setState(() {
      _favorited = _bookmarks.containsClinic(widget.clinic.name);
    });
  }

  Future<void> _toggleClinicFavorite() async {
    await _bookmarks.toggleClinic(
      clinicName: widget.clinic.name,
      city: widget.city,
      area: widget.clinic.area,
      rating: widget.knownRating > 0 ? widget.knownRating : widget.clinic.rating,
    );
  }
  String get _phone {
    final p = _placesResult?.phone ?? '';
    return p.isNotEmpty ? p : (_profile?.contact.phone ?? '');
  }
  String get _website {
    final w = _placesResult?.website ?? '';
    return w.isNotEmpty ? w : (_profile?.contact.website ?? '');
  }
  String get _address {
    final a = _placesResult?.address ?? '';
    return a.isNotEmpty ? a : (_profile?.contact.address ?? '');
  }
  String get _hours {
    final lines = _placesResult?.openingHoursLines ?? [];
    return lines.isNotEmpty
        ? lines.join(' · ')
        : (_profile?.contact.openingHours ?? '');
  }
  bool get _isOpenNow => _placesResult?.isOpenNow ?? (_profile?.contact.isOpenNow ?? false);
  String? get _directionsUrl => _placesResult?.googleMapsUrl;

  double get _displayRating {
    if (widget.knownRating > 0) return widget.knownRating;
    return _profile?.rating ?? widget.clinic.rating;
  }

  int get _displayReviews {
    if (widget.knownReviews > 0) return widget.knownReviews;
    return _profile?.reviewsCount ?? widget.clinic.reviews;
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final catalog = await ClinicCatalogStore.instance.get(
        clinicName: widget.clinic.name,
        city: widget.city,
        websiteUrl: widget.websiteUrl,
      );

      if (!mounted) return;

      if (catalog != null && catalog.page.procedures.isNotEmpty) {
        final cachedProfile = ClinicCatalogStore.profileFromPage(
          catalog.page,
          procedureContext: widget.procedureContext,
        );
        setState(() {
          _profile = cachedProfile;
          _isLoading = false;
        });

        // Places is cheap — always refresh contact/hours.
        unawaited(_refreshPlaces());

        // Fresh catalog: skip AI. Stale: refresh quietly in background.
        if (catalog.isFresh) return;

        unawaited(_refreshProfileInBackground());
        return;
      }

      final results = await Future.wait([
        _openAI.buildClinicProfile(
          clinicName: widget.clinic.name,
          city: widget.city,
          procedureContext: widget.procedureContext,
          aliases: widget.aliases,
          websiteUrl: widget.websiteUrl,
        ),
        _places.lookupClinic(
          clinicName: widget.clinic.name,
          city: widget.city,
          includeReviews: true,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as OpenAIClinicProfile;
        _placesResult = results[1] as GooglePlacesResult?;
        _isLoading = false;
      });
      final w = (widget.websiteUrl ?? '').trim();
      if (w.isNotEmpty) {
        unawaited(_loadStreamedTreatments());
      } else {
        _persistDetailCatalogIfReady();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _refreshPlaces() async {
    try {
      final places = await _places.lookupClinic(
        clinicName: widget.clinic.name,
        city: widget.city,
        includeReviews: true,
      );
      if (!mounted) return;
      setState(() => _placesResult = places);
    } catch (_) {}
  }

  Future<void> _refreshProfileInBackground() async {
    try {
      final profile = await _openAI.buildClinicProfile(
        clinicName: widget.clinic.name,
        city: widget.city,
        procedureContext: widget.procedureContext,
        aliases: widget.aliases,
        websiteUrl: widget.websiteUrl,
      );
      if (!mounted) return;
      setState(() => _profile = profile);
      final w = (widget.websiteUrl ?? '').trim();
      if (w.isNotEmpty) {
        await _loadStreamedTreatments();
      } else {
        _persistDetailCatalogIfReady();
      }
    } catch (_) {}
  }

  void _persistDetailCatalogIfReady() {
    final profile = _profile;
    if (profile == null || profile.treatments.isEmpty) return;

    // Rehydrate into the shared page shape so profile + detail share one catalog.
    final page = OpenAIClinicProfilePage(
      clinicName: profile.clinicName.isNotEmpty
          ? profile.clinicName
          : widget.clinic.name,
      city: profile.city.isNotEmpty ? profile.city : widget.city,
      clinicTypeLabel: 'Clinic',
      area: profile.area,
      distanceMi: profile.distanceMi,
      lat: 0,
      lng: 0,
      rating: profile.rating,
      reviewsTotal: profile.reviewsCount,
      googlePlaceUrl: '',
      procedureCount: profile.treatments.length,
      doctorCount: 0,
      isVerified: profile.isVerified,
      isDoctorLed: profile.isDoctorLed,
      heroTags: const [],
      about: profile.about,
      currency: profile.currency,
      priceRangeLabel: '',
      priceMin: 0,
      priceMax: 0,
      categories: const [],
      procedures: [
        for (final t in profile.treatments)
          OpenAIProfileProcedureRow(
            name: t.name,
            detail: t.description,
            category: '',
            iconKind: 'inject',
            priceMin: _parseLabelMin(t.priceLabel),
            priceMax: _parseLabelMin(t.priceLabel),
            priceLabel: t.priceLabel,
            tags: t.tags,
            featured: t.featured,
          ),
      ],
      doctors: const [],
      contact: profile.contact,
      reviews: profile.reviews,
    );

    unawaited(
      ClinicCatalogStore.instance.savePage(
        page: page,
        websiteUrl: widget.websiteUrl ?? profile.contact.website,
      ),
    );
  }

  static double _parseLabelMin(String raw) {
    final nums = RegExp(r'(\d+(?:[.,]\d+)?)')
        .allMatches(raw)
        .map((m) {
          final t = m.group(1)!;
          if (t.contains(',') && !t.contains('.')) {
            final last = t.lastIndexOf(',');
            final decimals = t.length - last - 1;
            if (decimals == 3) return double.tryParse(t.replaceAll(',', ''));
            return double.tryParse(t.replaceAll(',', '.'));
          }
          return double.tryParse(t.replaceAll(',', ''));
        })
        .whereType<double>()
        .toList();
    if (nums.isEmpty) return 0;
    return nums.reduce((a, b) => a < b ? a : b);
  }

  Future<void> _loadStreamedTreatments() async {
    try {
      await for (final partial in _openAI.buildClinicProfilePageStream(
        clinicName: widget.clinic.name,
        city: widget.city,
        websiteUrl: widget.websiteUrl,
      )) {
        if (!mounted || partial.procedures.isEmpty) continue;
        setState(() {
          final cur = _profile;
          if (cur != null) {
            _profile = _mergeStreamProcedures(cur, partial);
          }
        });
      }
      _persistDetailCatalogIfReady();
    } catch (_) {
      _persistDetailCatalogIfReady();
    }
  }

  OpenAIClinicTreatment _procedureRowToTreatment(OpenAIProfileProcedureRow r) {
    var brand = '';
    for (final tag in r.tags) {
      final lower = tag.toLowerCase();
      if (lower.contains('juvederm') ||
          lower.contains('restylane') ||
          lower.contains('botox') ||
          lower.contains('dysport') ||
          lower.contains('sculptra')) {
        brand = tag;
        break;
      }
    }
    return OpenAIClinicTreatment(
      name: r.name,
      brand: brand,
      dose: '',
      description: r.detail,
      priceLabel: r.priceLabel,
      badge: '',
      tags: r.tags,
      featured: r.featured,
    );
  }

  OpenAIClinicProfile _mergeStreamProcedures(
    OpenAIClinicProfile base,
    OpenAIClinicProfilePage page,
  ) {
    if (page.procedures.isEmpty) return base;

    final treatments =
        page.procedures.map(_procedureRowToTreatment).toList(growable: false);

    final rating = widget.knownRating > 0
        ? widget.knownRating
        : (page.rating > 0 ? page.rating : base.rating);
    final reviewsCount = widget.knownReviews > 0
        ? widget.knownReviews
        : (page.reviewsTotal > 0 ? page.reviewsTotal : base.reviewsCount);

    final c = base.contact;
    final pc = page.contact;
    final mergedContact = OpenAIClinicContact(
      address: c.address.isNotEmpty ? c.address : pc.address,
      phone: c.phone.isNotEmpty ? c.phone : pc.phone,
      website: c.website.isNotEmpty ? c.website : pc.website,
      instagram: c.instagram.isNotEmpty ? c.instagram : pc.instagram,
      openingHours:
          c.openingHours.isNotEmpty ? c.openingHours : pc.openingHours,
      isOpenNow: c.isOpenNow || pc.isOpenNow,
    );

    return OpenAIClinicProfile(
      clinicName: base.clinicName,
      city: base.city,
      area: base.area,
      distanceMi: base.distanceMi,
      rating: rating,
      reviewsCount: reviewsCount,
      isTopRated: base.isTopRated || rating >= 4.7,
      isDoctorLed: base.isDoctorLed || page.isDoctorLed,
      isVerified: base.isVerified || page.isVerified,
      about: base.about.isNotEmpty ? base.about : page.about,
      currency: base.currency.isNotEmpty ? base.currency : page.currency,
      procedureFocus: base.procedureFocus,
      procedureFocusLocal: base.procedureFocusLocal,
      treatments: treatments,
      contact: mergedContact,
      reviews: base.reviews,
    );
  }

  Future<void> _launch(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _copyToClipboard(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$label copied'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  Future<void> _onBookAppointment() async {
    final displayName = _profile?.clinicName ?? widget.clinic.name;
    final phone = await ensureBookingPhoneWithGooglePlaces(
      context: context,
      places: _places,
      clinicName: widget.clinic.name,
      city: widget.city,
      mergedPhoneFromProfile: _phone,
    );
    if (!mounted) return;
    final trimmed = phone?.trim() ?? '';
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No phone number found. Try the contact section or Google Maps.',
          ),
        ),
      );
      return;
    }
    final profile = _profile;
    await showBookAppointmentSheet(
      context,
      clinicName: displayName,
      phone: trimmed,
      rating: _displayRating > 0 ? _displayRating : null,
      procedureCount:
          profile != null && profile.treatments.isNotEmpty
              ? profile.treatments.length
              : null,
      isOpenNow: profile?.contact.isOpenNow,
      openingHoursOneLine: profile?.contact.openingHours,
      websiteUrl:
          _website.trim().isNotEmpty ? _website.trim() : null,
      instagramHandle: profile == null
          ? null
          : profile.contact.instagram.trim().isEmpty
              ? null
              : profile.contact.instagram.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Step2WarmBackground(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                _isLoading
                    ? _buildLoading()
                    : _error != null
                        ? _buildError()
                        : _buildContent(),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildBookBar(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Loading & Error states ────────────────────────────────────────────────

  Widget _buildLoading() {
    return Column(
      children: [
        _buildTopNav(),
        const SizedBox(height: 18),
        _buildHero(),
        const Expanded(
          child: Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ProcedureSelectionTheme.ink,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      children: [
        _buildTopNav(),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline_rounded, size: 40, color: Color(0xFFDD4444)),
                  const SizedBox(height: 12),
                  Text(
                    'Couldn\'t load clinic',
                    style: ProcedureSelectionTypography.label(
                      size: 14,
                      weight: FontWeight.w700,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _error!,
                    style: ProcedureSelectionTypography.body(
                      size: 11,
                      color: ProcedureSelectionTheme.muted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _load,
                      child: ProcedureGlassSurface(
                        borderRadius: BorderRadius.circular(999),
                        compact: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          child: Text(
                            'Try again',
                            style: ProcedureSelectionTypography.label(
                              size: 13,
                              weight: FontWeight.w700,
                              color: ProcedureSelectionTheme.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Main scrollable content ───────────────────────────────────────────────

  Widget _buildContent() {
    final p = _profile!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 130),
      children: [
        _buildTopNav(),
        const SizedBox(height: 18),
        _buildHero(),
        const SizedBox(height: 16),
        _buildRatingRow(p),
        const SizedBox(height: 16),
        _buildQuickActions(p),
        const SizedBox(height: 20),
        _buildTreatmentsSection(p),
        const SizedBox(height: 20),
        _buildContactSection(p),
        const SizedBox(height: 20),
        _buildReviewsSection(p),
      ],
    );
  }

  // ── Top nav: back + share + favorite ──────────────────────────────────────

  Widget _buildTopNav() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _CircleIcon(
            icon: Icons.chevron_left_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
          Row(
            children: [
              _CircleIcon(
                icon: Icons.ios_share_rounded,
                onTap: () {
                  final c = widget.clinic;
                  _copyToClipboard(
                    '${c.name} · ${widget.city}',
                    'Clinic',
                  );
                },
              ),
              const SizedBox(width: 8),
              _CircleIcon(
                icon: _favorited ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                iconColor: _heartRed,
                onTap: _toggleClinicFavorite,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Hero: eyebrow + name + badge + location ───────────────────────────────

  Widget _buildHero() {
    final c = widget.clinic;
    final p = _profile;
    final heroArea = (p?.area.isNotEmpty ?? false) ? p!.area : c.area;
    final heroDistanceMi = p?.distanceMi ?? c.distanceMi;
    final heroLocationLine = heroDistanceMi > 0
        ? '$heroArea · ${heroDistanceMi.toStringAsFixed(1)} mi'
        : heroArea;
    final eyebrow = '${(p?.procedureFocus.isNotEmpty ?? false) ? p!.procedureFocus : widget.procedureContext} clinic';
    final heroRating = _displayRating;
    final isTopRated = p?.isTopRated ?? (heroRating >= 4.7);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProcedureSectionLabel(eyebrow),
          const SizedBox(height: 8),
          Text(
            c.name,
            style: ProcedureSelectionTypography.display(
              size: 26,
              color: ProcedureSelectionTheme.ink,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (isTopRated)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '★ Top rated',
                    style: ProcedureSelectionTypography.label(
                      size: 11,
                      weight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.place_rounded, size: 13, color: ProcedureSelectionTheme.sectionLabel),
                  const SizedBox(width: 4),
                  Text(
                    heroLocationLine,
                    style: ProcedureSelectionTypography.body(
                      size: 13,
                      color: ProcedureSelectionTheme.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Rating + verified row ─────────────────────────────────────────────────

  Widget _buildRatingRow(OpenAIClinicProfile p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(18),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                _starsForRating(_displayRating),
                style: const TextStyle(color: _yellow, fontSize: 16, letterSpacing: -1),
              ),
              Text(
                _displayRating.toStringAsFixed(1),
                style: ProcedureSelectionTypography.display(
                  size: 20,
                  color: ProcedureSelectionTheme.ink,
                ),
              ),
              Text(
                '$_displayReviews reviews',
                style: ProcedureSelectionTypography.body(
                  size: 12,
                  color: ProcedureSelectionTheme.muted,
                ),
              ),
              if (p.isDoctorLed) const _RatingChip(text: 'Doctor-led ✓'),
              if (p.isVerified)
                const _RatingChip(
                  text: 'Verified ✓',
                  bg: _verifiedBg,
                  fg: _verifiedFg,
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Quick actions: Call / Directions / Website / Instagram ────────────────

  Widget _buildQuickActions(OpenAIClinicProfile p) {
    final phone = _phone.replaceAll(RegExp(r'\s+'), '');
    final website = _website;
    final instagram = p.contact.instagram.replaceAll('@', '');
    final directionsUri = _directionsUrl != null
        ? Uri.parse(_directionsUrl!)
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${_address.isNotEmpty ? _address : widget.clinic.name}, ${widget.city}')}',
          );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ProcedureGlassSurface(
        borderRadius: BorderRadius.circular(18),
        compact: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Row(
            children: [
              Expanded(
                child: _QuickAction(
                  icon: Icons.call_rounded,
                  label: 'Call',
                  onTap: phone.isEmpty
                      ? null
                      : () => _launch(Uri(scheme: 'tel', path: phone)),
                ),
              ),
              Expanded(
                child: _QuickAction(
                  icon: Icons.near_me_rounded,
                  label: 'Directions',
                  onTap: () => _launch(directionsUri),
                ),
              ),
              Expanded(
                child: _QuickAction(
                  icon: Icons.public_rounded,
                  label: 'Website',
                  onTap: website.isEmpty
                      ? null
                      : () => _launch(Uri.parse(_normalizeUrl(website))),
                ),
              ),
              Expanded(
                child: _QuickAction(
                  icon: Icons.camera_alt_outlined,
                  label: 'Instagram',
                  onTap: instagram.isEmpty
                      ? null
                      : () => _launch(Uri.parse('https://instagram.com/$instagram')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _normalizeUrl(String url) {
    final t = url.trim();
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    return 'https://$t';
  }

  // ── Treatments section ────────────────────────────────────────────────────

  Widget _buildTreatmentsSection(OpenAIClinicProfile p) {
    final focus = p.procedureFocus.isNotEmpty ? p.procedureFocus : widget.procedureContext;
    final title = focus.isNotEmpty ? 'Treatments · $focus highlighted' : 'All treatments';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProcedureSectionLabel(title),
          const SizedBox(height: 12),
          for (var i = 0; i < p.treatments.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == p.treatments.length - 1 ? 0 : 10),
              child: _TreatmentCard(treatment: p.treatments[i]),
            ),
        ],
      ),
    );
  }

  // ── Contact section ───────────────────────────────────────────────────────

  Widget _buildContactSection(OpenAIClinicProfile p) {
    final address = _address;
    final phone = _phone;
    final website = _website;
    final hours = _hours;
    final openNow = _isOpenNow;
    final directionsUri = _directionsUrl != null
        ? Uri.parse(_directionsUrl!)
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${address.isNotEmpty ? address : widget.clinic.name}, ${widget.city}')}',
          );

    final rows = <Widget>[
      if (address.isNotEmpty)
        _InfoRow(
          icon: Icons.place_rounded,
          label: 'Address',
          value: address,
          showArrow: true,
          onTap: () => _launch(directionsUri),
        ),
      if (phone.isNotEmpty)
        _InfoRow(
          icon: Icons.call_rounded,
          label: 'Phone',
          value: phone,
          isLink: true,
          showArrow: true,
          onTap: () => _launch(Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'\s+'), ''))),
        ),
      if (website.isNotEmpty)
        _InfoRow(
          icon: Icons.public_rounded,
          label: 'Website',
          value: website,
          isLink: true,
          showArrow: true,
          onTap: () => _launch(Uri.parse(_normalizeUrl(website))),
        ),
      if (hours.isNotEmpty)
        _InfoRow(
          icon: Icons.schedule_rounded,
          label: 'Opening hours',
          value: hours,
          trailing: openNow
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _verifiedBg,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Open now',
                    style: ProcedureSelectionTypography.label(
                      size: 11,
                      weight: FontWeight.w700,
                      color: _verifiedFg,
                    ),
                  ),
                )
              : null,
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ProcedureSectionLabel('Clinic information'),
          const SizedBox(height: 12),
          ProcedureGlassSurface(
            borderRadius: BorderRadius.circular(18),
            compact: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    rows[i],
                    if (i != rows.length - 1)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Divider(height: 1, thickness: 1, color: _softDivider),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Reviews section ───────────────────────────────────────────────────────

  Widget _buildReviewsSection(OpenAIClinicProfile p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ProcedureSectionLabel('Recent reviews'),
          const SizedBox(height: 12),
          for (final r in p.reviews) ...[
            _ReviewCard(review: r),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  // ── Sticky bottom: Book appointment ───────────────────────────────────────

  Widget _buildBookBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: _BookAppointmentButton(onPressed: _onBookAppointment),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _starsForRating(double r) {
    final full = r.floor().clamp(0, 5);
    final hasHalf = (r - full) >= 0.5;
    final filled = '★' * full + (hasHalf ? '★' : '');
    final empty = '☆' * (5 - filled.length);
    return '$filled$empty';
  }
}

class _CircleIcon extends StatelessWidget {
  const _CircleIcon({
    required this.icon,
    required this.onTap,
    this.iconColor = ProcedureSelectionTheme.ink,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;

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
            child: Icon(icon, size: 18, color: iconColor),
          ),
        ),
      ),
    );
  }
}

class _RatingChip extends StatelessWidget {
  const _RatingChip({
    required this.text,
    this.bg = ProcedureSelectionTheme.fieldFill,
    this.fg = ProcedureSelectionTheme.ink,
  });

  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        style: ProcedureSelectionTypography.label(
          size: 11,
          weight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.fieldFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
                  ),
                  child: Icon(icon, size: 18, color: ProcedureSelectionTheme.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: ProcedureSelectionTypography.body(
                    size: 10,
                    weight: FontWeight.w600,
                    color: ProcedureSelectionTheme.muted,
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

class _TreatmentCard extends StatelessWidget {
  const _TreatmentCard({required this.treatment});

  final OpenAIClinicTreatment treatment;

  @override
  Widget build(BuildContext context) {
    final featured = treatment.featured;
    final icon = procedureIconForTitle(treatment.name);
    final asset = icon.asset ?? 'assets/staricon.png';

    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(18),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (featured)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'BEST MATCH FOR YOUR SEARCH',
                    style: ProcedureSelectionTypography.chip(
                      size: 9,
                      weight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: ProcedureGlassDecorations.iconBadge(selected: false),
                  alignment: Alignment.center,
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.mode(
                      ProcedureSelectionTheme.ink,
                      BlendMode.srcIn,
                    ),
                    child: Image.asset(
                      asset,
                      width: 28,
                      height: 28,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    treatment.name,
                    style: ProcedureSelectionTypography.label(
                      size: 15,
                      weight: FontWeight.w700,
                      color: ProcedureSelectionTheme.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  treatment.priceLabel,
                  style: ProcedureSelectionTypography.label(
                    size: 13,
                    weight: FontWeight.w700,
                    color: ProcedureSelectionTheme.ink,
                  ),
                ),
              ],
            ),
            if (treatment.description.isNotEmpty || treatment.dose.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 54),
                child: Text(
                  [if (treatment.dose.isNotEmpty) treatment.dose, if (treatment.description.isNotEmpty) treatment.description].join(' · '),
                  style: ProcedureSelectionTypography.body(
                    size: 11,
                    color: ProcedureSelectionTheme.muted,
                  ),
                ),
              ),
            ],
            if (treatment.tags.isNotEmpty || treatment.badge.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 54),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (treatment.badge.isNotEmpty)
                      _Tag(text: treatment.badge, dark: true),
                    for (final t in treatment.tags) _Tag(text: t),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.dark = false});
  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: dark ? ProcedureSelectionTheme.buttonPrimary : ProcedureSelectionTheme.fieldFill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: ProcedureSelectionTypography.chip(
          size: 11,
          weight: FontWeight.w600,
          color: dark ? Colors.white : ProcedureSelectionTheme.muted,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.isLink = false,
    this.showArrow = false,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool isLink;
  final bool showArrow;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: ProcedureSelectionTheme.fieldFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 16, color: ProcedureSelectionTheme.muted),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        weight: FontWeight.w500,
                        color: ProcedureSelectionTheme.sectionLabel,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            value,
                            style: ProcedureSelectionTypography.label(
                              size: 14,
                              weight: FontWeight.w600,
                              color: ProcedureSelectionTheme.ink,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (trailing != null) ...[
                          const SizedBox(width: 8),
                          trailing!,
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (showArrow)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: ProcedureSelectionTheme.muted.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});
  final OpenAIClinicReview review;

  @override
  Widget build(BuildContext context) {
    return ProcedureGlassSurface(
      borderRadius: BorderRadius.circular(18),
      compact: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: ProcedureSelectionTheme.buttonPrimary,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    review.initials,
                    style: ProcedureSelectionTypography.label(
                      size: 11,
                      weight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      review.authorName,
                      style: ProcedureSelectionTypography.label(
                        size: 13,
                        weight: FontWeight.w700,
                        color: ProcedureSelectionTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      review.date,
                      style: ProcedureSelectionTypography.body(
                        size: 11,
                        color: ProcedureSelectionTheme.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _stars(review.rating),
              style: const TextStyle(color: Color(0xFFF5C842), fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              review.text,
              style: ProcedureSelectionTypography.body(
                size: 13,
                color: ProcedureSelectionTheme.muted,
              ).copyWith(height: 1.6),
            ),
          ],
        ),
      ),
    );
  }

  String _stars(double r) {
    final full = r.floor().clamp(0, 5);
    final hasHalf = (r - full) >= 0.5;
    final filled = '★' * full + (hasHalf ? '★' : '');
    final empty = '☆' * (5 - filled.length);
    return '$filled$empty';
  }
}

/// Sticky pill CTA — matches [ProcedurePremiumContinueButton] styling but
/// keeps the calendar icon used for booking.
class _BookAppointmentButton extends StatelessWidget {
  const _BookAppointmentButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    const radius = 32.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          ...ProcedureGlassDecorations.neonFrameGlow(),
          ...ProcedureGlassDecorations.depthShadow(elevated: true, selected: true),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.calendar_month_rounded, size: 18),
          label: Text(
            'Book appointment',
            style: ProcedureSelectionTypography.label(
              size: 15,
              weight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: ProcedureSelectionTheme.buttonPrimary,
            foregroundColor: Colors.white,
            disabledBackgroundColor: ProcedureSelectionTheme.buttonPrimary.withValues(alpha: 0.42),
            disabledForegroundColor: Colors.white.withValues(alpha: 0.78),
            elevation: 0,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          ),
        ),
      ),
    );
  }
}
