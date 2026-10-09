import 'package:flutter/foundation.dart';

import 'explore_clinic_identity.dart';
import 'explore_compare_mix.dart';
import 'explore_pipeline_config.dart';
import 'explore_price_sanity.dart';
import 'explore_price_verification.dart';
import 'explore_procedure_relation.dart';
import 'openai_service.dart';

/// How many Firestore vs live-Google cards to show for a verified pool size.
///
/// Pool is per city + canonical procedure and only holds verified
/// exact/variant procedure prices (cap [kExploreFirestorePoolMax]).
class ExplorePoolMixPlan {
  const ExplorePoolMixPlan({
    required this.firestoreShow,
    required this.googleLiveTarget,
    required this.backgroundDiscoverMax,
    required this.skipLiveGoogle,
  });

  /// Random verified clinics from the Firestore pool to paint immediately.
  final int firestoreShow;

  /// New Google clinics that may appear on screen this visit.
  final int googleLiveTarget;

  /// Optional silent pool growth (not shown, no loading UI).
  final int backgroundDiscoverMax;

  /// When true, do not wait on live Google for the visible set.
  final bool skipLiveGoogle;

  bool get waitsOnGoogle => !skipLiveGoogle && googleLiveTarget > 0;
}

/// Mature pool: optional extra discovery in addition to the visible live mix.
const kExploreFirestorePoolMature = 20;

/// Legacy threshold retained for callers; it never disables normal live search.
const kExploreFirestorePoolSaturated = 25;

/// Decide visible mix from the current verified pool size.
///
/// Target composition for every city / pill worldwide:
/// - up to [kExploreFirestoreSeedClinics] saved clinics from the Firestore pool
/// - up to [kExploreGoogleClinics] (2) newly verified from live search
/// Live finds are persisted into the pool so the next open can seed Firestore.
///
/// Cold start hunts the full display target; a mature pool prefers two saved
/// and two fresh clinics. A short pool uses live results to fill empty slots.
ExplorePoolMixPlan planExplorePoolMix(
  int verifiedPoolCount, {
  int? liveVerifiedCount,
}) {
  final n = verifiedPoolCount < 0 ? 0 : verifiedPoolCount;
  assert(liveVerifiedCount == null || liveVerifiedCount >= -1);

  if (n <= 0) {
    return const ExplorePoolMixPlan(
      firestoreShow: 0,
      googleLiveTarget: kExploreCompareMaxClinics,
      backgroundDiscoverMax: 0,
      skipLiveGoogle: false,
    );
  }
  if (n == 1) {
    return const ExplorePoolMixPlan(
      firestoreShow: 1,
      googleLiveTarget: kExploreCompareMaxClinics - 1,
      backgroundDiscoverMax: 0,
      skipLiveGoogle: false,
    );
  }
  // A full saved pool still searches for two new verified providers per visit.
  final silentGrow = n >= kExploreFirestorePoolMature ? 1 : 0;
  final targets = exploreCompareTargets(n);
  return ExplorePoolMixPlan(
    firestoreShow: targets.saved,
    googleLiveTarget: targets.live,
    backgroundDiscoverMax: silentGrow,
    skipLiveGoogle: false,
  );
}

/// All-tab preview fills one slot per pill (`googleLiveTargetOverride: 1`).
/// Joining that in-flight search from a focused pill freezes Compare at 1–2
/// cards instead of filling to [kExploreCompareMinClinics].
bool exploreShouldJoinInFlightTopUp({
  required bool joinInFlight,
  int? googleLiveTargetOverride,
  int pricedOnScreen = 0,
}) {
  if (!joinInFlight) return false;
  final want = googleLiveTargetOverride ?? kExploreCompareMinClinics;
  if (want >= kExploreCompareMinClinics &&
      pricedOnScreen < kExploreCompareMinClinics) {
    return false;
  }
  return true;
}

/// How many website candidates to verify for the current Google target.
/// Focused pills inspect up to [ExplorePipelineConfig.candidateVerifyLimit];
/// All preview stays cheap (scaled).
int exploreLiveDiscoveryCandidateCap(int liveGoogleTarget) {
  if (liveGoogleTarget <= 0) return 0;
  final focusedCap = ExplorePipelineConfig.candidateVerifyLimit;
  if (liveGoogleTarget >= kExploreCompareMinClinics) return focusedCap;
  final scaled = liveGoogleTarget * 3;
  final plusOne = liveGoogleTarget + 1;
  final cap = scaled > plusOne ? scaled : plusOne;
  return cap > focusedCap ? focusedCap : cap;
}

/// All preview must not burn the daily Places SearchText quota — four pills
/// in parallel exhaust it and the focused Botox list then cannot fill to 4.
bool exploreLiveSearchUsesPlaces({
  required int liveGoogleTarget,
  int? googleLiveTargetOverride,
}) {
  if (googleLiveTargetOverride != null &&
      googleLiveTargetOverride < kExploreCompareMinClinics) {
    return false;
  }
  return liveGoogleTarget > 0;
}

/// Visible seed candidates for the Firestore half.
///
/// Returns curated rows first (full audit set), then other verified pool
/// clinics that are not the same provider. [ExploreSeedCatalog.mixSeedsWithFresh]
/// shuffles and rotates from this list — collapsing to a fixed curated top-N
/// here is what made every pill look identical.
List<OpenAIClinic> explorePaintPool({
  required List<OpenAIClinic> verifiedPool,
  List<OpenAIClinic> curated = const [],
  required int want,
}) {
  if (want <= 0) return const [];
  final fromAudit = [
    for (final c in curated)
      if (exploreCuratedPriceIsTrusted(c)) c,
  ];
  if (fromAudit.isEmpty) return verifiedPool;

  final out = List<OpenAIClinic>.of(fromAudit);
  for (final c in verifiedPool) {
    if (out.any((e) => exploreClinicsAreSameProvider(e, c))) continue;
    out.add(c);
  }
  return out;
}

const _kHardStoredRelations = {
  'bundle',
  'add_on',
  'different_procedure',
  'market_information',
  'ambiguous',
};

ProcedureRelationResult exploreCurrentProcedureRelation(
  OpenAIClinic c, {
  required String procedure,
}) {
  return classifyProcedureRelation(
    requestedProcedure: procedure,
    label: c.rawProcedureText.trim().isNotEmpty ? c.rawProcedureText : c.brand,
    evidence: '${c.rawPriceText}\n${c.priceEvidenceText}',
    sourceUrl: c.priceSourceUrl,
  );
}

/// Persist exact/variant after a successful current classification.
OpenAIClinic withCanonicalExploreProcedureRelation(
  OpenAIClinic c, {
  required String procedure,
}) {
  final current = exploreCurrentProcedureRelation(c, procedure: procedure);
  if (!current.eligibleForFromPrice) return c;
  return c.copyWith(procedureRelation: current.logToken);
}

/// Only verified exact/variant procedure prices may grow the shared pool.
/// Current deterministic relation is authoritative. A stale/unknown stored
/// relation must not veto an eligible exact/variant row.
final _poolEligibilityMemo =
    Expando<Map<String, ({DateTime at, bool valid})>>();

bool exploreClinicEligibleForVerifiedPool(
  OpenAIClinic c, {
  required String procedure,
  required String city,
}) {
  final key = '$city|$procedure';
  final memo = _poolEligibilityMemo[c] ??= {};
  final hit = memo[key];
  final now = DateTime.now();
  if (hit != null && now.difference(hit.at) < const Duration(seconds: 5))
    return hit.valid;
  final valid = _clinicEligibleForVerifiedPool(
    c,
    procedure: procedure,
    city: city,
  );
  memo[key] = (at: now, valid: valid);
  return valid;
}

typedef _SavedPriceValidationInput = ({
  List<OpenAIClinic> rows,
  String city,
  String procedure,
});

List<OpenAIClinic> _validateSavedPrices(_SavedPriceValidationInput input) =>
    input.rows
        .where(
          (c) =>
              exploreClinicEligibleForVerifiedPool(
                c,
                procedure: input.procedure,
                city: input.city,
              ) &&
              isJustifiedProcedurePrice(c, procedure: input.procedure),
        )
        .map(withExploreClinicDisplayName)
        .where(
          (c) =>
              exploreClinicEligibleForVerifiedPool(
                c,
                procedure: input.procedure,
                city: input.city,
              ) &&
              isJustifiedProcedurePrice(c, procedure: input.procedure),
        )
        .toList();

/// Native/server cache batches use the same strict validator on a worker
/// isolate. Only accepted immutable records receive the short repaint memo.
Future<List<OpenAIClinic>> validateExploreSavedComparisonClinics({
  required List<OpenAIClinic> rows,
  required String city,
  required String procedure,
}) async {
  if (rows.isEmpty) return const [];
  final accepted = await compute(_validateSavedPrices, (
    rows: rows,
    city: city,
    procedure: procedure,
  ), debugLabel: 'explore-cache-validation');
  final now = DateTime.now();
  for (final row in accepted) {
    memoizeExploreWorkerValidatedClinic(
      row,
      city: city,
      procedure: procedure,
      at: now,
    );
    (_poolEligibilityMemo[row] ??= {})['$city|$procedure'] = (
      at: now,
      valid: true,
    );
  }
  return accepted;
}

bool _clinicEligibleForVerifiedPool(
  OpenAIClinic c, {
  required String procedure,
  required String city,
}) {
  if (!c.hasProcedure || c.priceMin <= 0 || c.pricePending) return false;
  if (!explorePriceIsVerified(c)) return false;
  if (!isUsableExploreClinicIdentity(
    name: c.name,
    websiteHost: c.priceSourceUrl,
    providerClinic: c.providerClinic,
    sourceType: c.sourceType,
  )) {
    return false;
  }
  if (_isPriceOnRequestLabel(c.priceLabel)) return false;
  // City is not optional for a curated row. A Tiranë price must not fill a
  // Budapest slot just because the audit trusted the amount.
  if (!exploreClinicFitsSearchCity(c, city)) return false;
  // A curated row was bucketed into its family and city key at import time by
  // the same normalizer the rest of the pipeline uses, and the Firestore query
  // filters on those two keys — so the match is already established. Re-deriving
  // it from the display label would only lose information: "Gummy Smile Tox" is
  // a botox row, and a Coral Gables address answers a Miami search because the
  // audit covers the whole metro. Identity and price checks above still apply.
  if (exploreCuratedPriceIsTrusted(c)) return true;
  if (!exploreClinicMatchesProcedure(c, procedure)) return false;
  if (!isJustifiedProcedurePrice(c, procedure: procedure)) return false;
  final current = exploreCurrentProcedureRelation(c, procedure: procedure);
  if (current.eligibleForFromPrice) {
    final stored = c.procedureRelation.trim().toLowerCase();
    if (_kHardStoredRelations.contains(stored) && stored == current.logToken) {
      return false;
    }
    return true;
  }
  // Accept-time exact/variant with page witness must not vanish on UI recheck
  // when the stored row is still an inheritable area/ml/zone label (e.g.
  // "Global Action 1 ml" on /price-list-medical/). Missing pageHasFamilyWitness
  // on the slim recheck path used to Drop every progressive fill card.
  final stored = c.procedureRelation.trim().toLowerCase();
  if (stored != 'exact' && stored != 'variant') return false;
  final want = exploreRelationRequestedFamily(procedure);
  final label = c.rawProcedureText.trim().isNotEmpty
      ? c.rawProcedureText
      : c.brand;
  // A price menu lists several treatments. Hair on the same page must not
  // turn an exact "Breast Augmentation" line into a bundle.
  final labelSignals = detectProcedureTreatmentSignals(label);
  if (labelSignals.matchesRequested(want) &&
      labelSignals.extrasBeside(want).isEmpty) {
    return true;
  }
  if (looksLikeInheritableAreaOnlyLabel(label: label, requestedFamily: want) ||
      (want == 'filler' &&
          exploreSourceUrlLooksLikePriceMenu(c.priceSourceUrl) &&
          RegExp(
            r'\b\d+(?:[.,]\d+)?\s*ml\b',
            caseSensitive: false,
          ).hasMatch(label.toLowerCase()))) {
    return true;
  }
  return false;
}

/// When the curated dataset and the live pipeline describe the same clinic and
/// procedure, keep the price that is both trusted and more recently confirmed.
///
/// The ordering that matters, highest first: a fresh live website verification,
/// then recent curated public-site data, then an older verified cache, then
/// anything unverified. An unverified row — an AI guess or a search snippet —
/// can never displace a curated price, however new it is.
OpenAIClinic explorePreferFresherTrustedPrice(
  OpenAIClinic existing,
  OpenAIClinic incoming, {
  String procedure = '',
}) {
  final existingCurated = exploreCuratedPriceIsTrusted(existing);
  final incomingCurated = exploreCuratedPriceIsTrusted(incoming);
  if (existingCurated != incomingCurated) {
    final curated = existingCurated ? existing : incoming;
    final live = existingCurated ? incoming : existing;
    return _liveOfficialBeatsCurated(live, curated, procedure: procedure)
        ? live
        : curated;
  }
  final existingTrusted = explorePriceIsVerified(existing);
  final incomingTrusted = explorePriceIsVerified(incoming);
  if (existingTrusted != incomingTrusted) {
    return existingTrusted ? existing : incoming;
  }
  if (!existingTrusted) return existing;
  final a = _priceConfirmedAt(existing);
  final b = _priceConfirmedAt(incoming);
  if (a == null && b == null) return existing;
  if (a == null) return incoming;
  if (b == null) return existing;
  return b.isAfter(a) ? incoming : existing;
}

/// A live website quote may replace the audit only when it is an official
/// page, still passes the compare filter, and was checked more recently.
bool _liveOfficialBeatsCurated(
  OpenAIClinic live,
  OpenAIClinic curated, {
  required String procedure,
}) {
  if (live.priceVerificationStatus != PriceVerificationStatus.officialWebsite) {
    return false;
  }
  if (!explorePriceIsVerified(live)) return false;
  if (!isJustifiedProcedurePrice(live, procedure: procedure)) return false;
  final liveAt = live.priceVerifiedAt;
  final curatedAt = curated.lastCheckedAt;
  if (liveAt == null || curatedAt == null) return false;
  return liveAt.isAfter(curatedAt);
}

/// When this row's price was last confirmed. A live verification stamps
/// [OpenAIClinic.priceVerifiedAt]; a curated row only has a check date.
DateTime? _priceConfirmedAt(OpenAIClinic c) =>
    c.priceVerifiedAt ?? c.lastCheckedAt;

bool _isPriceOnRequestLabel(String label) {
  final t = label.toLowerCase();
  return t.contains('on request') ||
      t.contains('su richiesta') ||
      t.contains('a richiesta') ||
      t.contains('price on') ||
      t.contains('prezzo su') ||
      t.contains('la cerere') ||
      t.contains('preț personalizat') ||
      t.contains('pret personalizat') ||
      t.contains('contact the clinic') ||
      t.contains('contactați') ||
      t.contains('contactati') ||
      t.contains('contact for price') ||
      t.contains('ask for quote') ||
      t.trim().isEmpty;
}

/// Visible mix is Firestore seeds + new Google. Prefer up to
/// [kExploreGoogleClinics] fresh names, then fill the rest from cached so a
/// 4-clinic pool never paints only 2 while Google is still verifying.
///
/// Do not pass leftover pool names as [poolForPad] until live search has
/// finished — padding while Google is in flight used to fill search slots
/// before websites could appear. Callers that already painted 4 cached rows
/// pass them via [cachedShown] instead.
List<OpenAIClinic> mixExploreVisibleClinics({
  required List<OpenAIClinic> cachedShown,
  required List<OpenAIClinic> googleShown,
  required List<OpenAIClinic> poolForPad,
  int maxVisible = kExploreCompareMaxClinics,
  int preferredCachedWithFresh = kExploreFirestoreSeedClinics,
}) {
  final out = <OpenAIClinic>[];
  final keys = <String>{};

  void add(OpenAIClinic c) {
    if (out.length >= maxVisible) return;
    if (exploreClinicHitsKeys(c, keys)) return;
    out.add(c);
    keys.addAll(exploreClinicIdentityKeys(c));
  }

  // Desired final composition is ~2 Google + 2 Firestore, but empty Google
  // slots must stay filled with verified cache so the card count never dips.
  final googleCap = kExploreGoogleClinics < googleShown.length
      ? kExploreGoogleClinics
      : googleShown.length;
  final googleTake = googleShown.take(googleCap).toList();
  final cachedBudget = maxVisible - googleTake.length;
  // Prefer the caller's preferredCachedWithFresh when Google already filled
  // its slots; otherwise paint every available cached row up to budget.
  final cachedCap = googleTake.isEmpty
      ? (cachedShown.length < cachedBudget ? cachedShown.length : cachedBudget)
      : (preferredCachedWithFresh < cachedBudget
            ? preferredCachedWithFresh
            : cachedBudget);
  for (final c in cachedShown.take(cachedCap > 0 ? cachedCap : 0)) {
    add(c);
  }
  // If Google is still empty/short, keep filling from the rest of the cache
  // so a 4-verified pool paints 4 immediately.
  if (out.length < maxVisible && googleTake.length < kExploreGoogleClinics) {
    for (final c in cachedShown.skip(cachedCap)) {
      add(c);
      if (out.length >= maxVisible) break;
    }
  }
  for (final c in googleTake) {
    add(c);
  }
  if (out.length < maxVisible) {
    for (final c in poolForPad) {
      add(c);
    }
  }
  // Extra Google beyond the diversity cap still paints if slots remain.
  if (out.length < maxVisible) {
    for (final c in googleShown.skip(googleCap)) {
      add(c);
    }
  }
  return out;
}

/// Session-visible comparison is monotonic by valid clinic count.
OpenAIComparisonResult putBestComparison({
  OpenAIComparisonResult? previous,
  required OpenAIComparisonResult incoming,
  bool Function(OpenAIClinic clinic)? isStillValid,
  int maxVisible = kExploreCompareMaxClinics,
}) {
  final valid = isStillValid ?? ((OpenAIClinic c) => c.priceMin > 0);
  if (previous == null || previous.clinics.isEmpty) {
    final next = [
      for (final c in incoming.clinics)
        if (valid(c)) c,
    ];
    return incoming.copyWith(
      clinics: next.length <= maxVisible
          ? next
          : next.take(maxVisible).toList(),
    );
  }

  final keptPrev = [
    for (final c in previous.clinics)
      if (valid(c)) c,
  ];
  final merged = mergeExploreClinicIdentities([
    ...keptPrev,
    ...incoming.clinics.where(valid),
  ]);
  final out = merged.length <= maxVisible
      ? merged
      : merged.take(maxVisible).toList();
  return incoming.copyWith(clinics: out);
}

List<OpenAIClinic> mergeExploreClinicIdentities(List<OpenAIClinic> clinics) {
  final out = <OpenAIClinic>[];
  for (final c in clinics) {
    var mergedInto = false;
    for (var i = 0; i < out.length; i++) {
      if (!exploreClinicsAreSameProvider(out[i], c)) continue;
      out[i] = mergeExploreClinicRecord(out[i], c);
      mergedInto = true;
      break;
    }
    if (!mergedInto) out.add(c);
  }
  return out;
}

bool exploreClinicsAreSameProvider(OpenAIClinic a, OpenAIClinic b) {
  final aId = a.placeId.trim();
  final bId = b.placeId.trim();
  if (aId.isNotEmpty && bId.isNotEmpty && aId == bId) return true;
  if (exploreClinicHitsKeys(a, exploreClinicIdentityKeys(b))) return true;
  return namesLookLikeSameProvider(a.name, b.name);
}

/// Copy public provider names and Places ratings onto cards already on screen.
/// Name corrections do not require a changed fee or a positive Maps rating.
/// Matches by website /
/// place identity so a host-only row still receives the Maps rating after a
/// `placeId` and a different Google name are attached.
List<OpenAIClinic> overlayExploreClinicRatings({
  required List<OpenAIClinic> shown,
  required List<OpenAIClinic> enriched,
}) {
  if (shown.isEmpty || enriched.isEmpty) return shown;
  var changed = false;
  final next = <OpenAIClinic>[];
  for (final prev in shown) {
    OpenAIClinic? match;
    var name = prev.name;
    for (final c in enriched) {
      if (!exploreClinicsAreSameProvider(prev, c)) continue;
      if (exploreClinicNameNeedsMapsRefresh(prev) &&
          !exploreClinicNameNeedsMapsRefresh(c) &&
          !isInvalidClinicIdentity(c.name)) name = c.name;
      if (match == null && (c.rating > 0 || c.reviews > 0)) match = c;
    }
    if (match == null && name == prev.name) {
      next.add(prev);
      continue;
    }
    final rating = (match?.rating ?? 0) > 0 ? match!.rating : prev.rating;
    final reviews = (match?.reviews ?? 0) > 0 ? match!.reviews : prev.reviews;
    final placeId = (match?.placeId.trim().isNotEmpty ?? false)
        ? match!.placeId
        : prev.placeId;
    if (rating == prev.rating &&
        reviews == prev.reviews &&
        placeId == prev.placeId && name == prev.name) {
      next.add(prev);
      continue;
    }
    changed = true;
    next.add(prev.copyWith(name: name, placeId: placeId, rating: rating, reviews: reviews));
  }
  return changed ? next : shown;
}

OpenAIClinic mergeExploreClinicRecord(OpenAIClinic prev, OpenAIClinic next) {
  final nextNameOk =
      !isMarketplaceBrandName(next.name) && !isGenericShopIdentity(next.name);
  final prevNameOk =
      !isMarketplaceBrandName(prev.name) && !isGenericShopIdentity(prev.name);
  final preferPublicPreviousName = prevNameOk &&
      !exploreClinicNameNeedsMapsRefresh(prev) &&
      exploreClinicNameNeedsMapsRefresh(next);
  final name = preferPublicPreviousName ? prev.name : nextNameOk
      ? (next.name.trim().isNotEmpty ? next.name : prev.name)
      : (prevNameOk ? prev.name : next.name);
  final nextE12 =
      next.priceExtractRevision.trim() == kExplorePriceExtractRevision;
  final prevE12 =
      prev.priceExtractRevision.trim() == kExplorePriceExtractRevision;
  var preferNextPrice =
      next.priceMin > 0 &&
      nextE12 &&
      (!prevE12 ||
          prev.priceMin <= 0 ||
          (next.priceVerifiedAt != null &&
              (prev.priceVerifiedAt == null ||
                  !next.priceVerifiedAt!.isBefore(prev.priceVerifiedAt!))));
  // A Google cache row with today's extract revision must not strip a
  // curated public-site price. That is how Boob job went 4 curated → 2.
  if (preferNextPrice &&
      exploreCuratedPriceIsTrusted(prev) &&
      !exploreCuratedPriceIsTrusted(next)) {
    preferNextPrice = false;
  }
  final prevPackage = explorePricedLineIsIncomparablePackage(
    procedure: prev.procedureCanonical.isNotEmpty
        ? prev.procedureCanonical
        : prev.brand,
    evidence:
        '${prev.rawProcedureText}\n${prev.procedureDetail}\n${prev.rawPriceText}\n${prev.priceEvidenceText}',
    priceMin: prev.priceMin,
  );
  final nextPackage = explorePricedLineIsIncomparablePackage(
    procedure: next.procedureCanonical.isNotEmpty
        ? next.procedureCanonical
        : next.brand,
    evidence:
        '${next.rawProcedureText}\n${next.procedureDetail}\n${next.rawPriceText}\n${next.priceEvidenceText}',
    priceMin: next.priceMin,
  );
  if (prevPackage && !nextPackage && next.priceMin > 0) {
    preferNextPrice = true;
  }
  return prev.copyWith(
    name: name,
    placeId: next.placeId.trim().isNotEmpty ? next.placeId : prev.placeId,
    rating: next.rating > prev.rating ? next.rating : prev.rating,
    reviews: next.reviews > prev.reviews ? next.reviews : prev.reviews,
    priceMin: preferNextPrice ? next.priceMin : prev.priceMin,
    priceMax: preferNextPrice ? next.priceMax : prev.priceMax,
    priceLabel: preferNextPrice ? next.priceLabel : prev.priceLabel,
    priceGbp: preferNextPrice ? next.priceGbp : prev.priceGbp,
    currency: preferNextPrice ? next.currency : prev.currency,
    brand: preferNextPrice ? next.brand : prev.brand,
    priceSourceUrl: preferNextPrice ? next.priceSourceUrl : prev.priceSourceUrl,
    priceEvidenceText: preferNextPrice
        ? next.priceEvidenceText
        : prev.priceEvidenceText,
    priceVerificationStatus: preferNextPrice
        ? next.priceVerificationStatus
        : prev.priceVerificationStatus,
    rawProcedureText: preferNextPrice
        ? next.rawProcedureText
        : prev.rawProcedureText,
    rawPriceText: preferNextPrice ? next.rawPriceText : prev.rawPriceText,
    extractionMethod: preferNextPrice
        ? next.extractionMethod
        : prev.extractionMethod,
    evidenceHash: preferNextPrice ? next.evidenceHash : prev.evidenceHash,
    priceType: preferNextPrice ? next.priceType : prev.priceType,
    priceUnit: preferNextPrice ? next.priceUnit : prev.priceUnit,
    priceQuantity: preferNextPrice ? next.priceQuantity : prev.priceQuantity,
    sourceType: preferNextPrice ? next.sourceType : prev.sourceType,
    // Persist extract revision with the price — dropping it made the next
    // load strip the quote and the pool never grew past the first scrape.
    priceExtractRevision: preferNextPrice
        ? (next.priceExtractRevision.trim().isNotEmpty
              ? next.priceExtractRevision
              : prev.priceExtractRevision)
        : prev.priceExtractRevision,
    procedureRelation: preferNextPrice
        ? (next.procedureRelation.trim().isNotEmpty
              ? next.procedureRelation
              : prev.procedureRelation)
        : prev.procedureRelation,
    currencyConfirmed: preferNextPrice
        ? next.currencyConfirmed
        : prev.currencyConfirmed,
    sourcePlatform: next.sourcePlatform.trim().isNotEmpty
        ? next.sourcePlatform
        : prev.sourcePlatform,
    providerClinic: next.providerClinic.trim().isNotEmpty
        ? next.providerClinic
        : prev.providerClinic,
    area: next.area.trim().length >= prev.area.trim().length
        ? next.area
        : prev.area,
  );
}

String explorePersistFingerprint(Iterable<OpenAIClinic> clinics) {
  final parts = [
    for (final c in clinics)
      [
        exploreClinicDedupKey(c),
        c.placeId.trim(),
        c.name.trim().toLowerCase(),
        c.priceMin.toStringAsFixed(2),
        c.priceSourceUrl.trim(),
        c.priceVerificationStatus.wire,
        c.brand.trim(),
      ].join('|'),
  ]..sort();
  return parts.join(';;');
}

bool explorePersistPayloadUnchanged(String previous, String next) {
  return previous.isNotEmpty && previous == next;
}

bool cachedRowHasUsablePrice(Map<String, Object?> row) {
  final min = (row['price_min'] as num?)?.toDouble() ?? 0;
  if (min <= 0) return false;
  final status = '${row['price_verification_status'] ?? ''}'
      .trim()
      .toLowerCase();
  if (status == 'legacy_untrusted' ||
      status == 'legacy_unverified' ||
      row['needs_reverification'] == true) {
    return false;
  }
  final marketplaceOk =
      row['marketplace_identity_verified'] == true &&
      (status == 'fresha_marketplace' ||
          status == 'booksy_marketplace' ||
          '${row['source_type'] ?? ''}' == 'marketplace');
  final verified =
      row['price_verified'] == true ||
      row['verified'] == true ||
      status == 'official_website' ||
      marketplaceOk;
  if (!verified) return false;
  final raw = '${row['raw_price_text'] ?? ''}'.trim();
  final rawProc = '${row['raw_procedure_text'] ?? row['brand'] ?? ''}'.trim();
  final source = '${row['price_source_url'] ?? row['source_url'] ?? ''}'.trim();
  final method = '${row['extraction_method'] ?? ''}'.trim();
  if (raw.isEmpty || rawProc.isEmpty || source.isEmpty || method.isEmpty) {
    return false;
  }
  return '${row['price_extract_revision'] ?? ''}'.trim() ==
      kExplorePriceExtractRevision;
}

class ExploreBackendAcceptedClinic {
  const ExploreBackendAcceptedClinic({
    required this.clinic,
    required this.source,
  });

  final OpenAIClinic clinic;
  final ExploreClinicSource source;
}

/// Filter backend cached + fresh rows with the same eligibility as a pill.
List<ExploreBackendAcceptedClinic> consumeExploreBackendRows({
  required Iterable<Map<String, Object?>> cached,
  required Iterable<Map<String, Object?>> fresh,
  required String procedure,
  required String city,
}) {
  final out = <ExploreBackendAcceptedClinic>[];
  final seen = <String>{};

  void add(Map<String, Object?> row, ExploreClinicSource source) {
    final clinic = OpenAIClinic.fromJson(row);
    if (!exploreClinicEligibleForVerifiedPool(
      clinic,
      procedure: procedure,
      city: city,
    )) {
      return;
    }
    if (!explorePriceIsVerified(clinic)) return;
    final key = exploreClinicDedupKey(clinic);
    if (key.isEmpty || !seen.add(key)) return;
    out.add(ExploreBackendAcceptedClinic(clinic: clinic, source: source));
  }

  for (final row in cached) {
    add(row, ExploreClinicSource.googleCache);
  }
  for (final row in fresh) {
    add(row, ExploreClinicSource.googleLive);
  }
  return out;
}

/// Live discovery may skip a clinic only when it is already known for THIS
/// procedure. Cross-pill sibling identities must never be included.
Set<String> exploreCurrentProcedureExclusionKeys({
  Iterable<String> shownKeys = const [],
  Iterable<String> lastShownKeys = const [],
  Iterable<String> poolKeys = const [],
}) {
  return <String>{...shownKeys, ...lastShownKeys, ...poolKeys}
    ..removeWhere((k) => k.isEmpty);
}

bool exploreClinicBlockedFromCurrentProcedureDiscovery(
  OpenAIClinic clinic, {
  required Set<String> currentProcedureExclusionKeys,
}) {
  return exploreClinicHitsKeys(clinic, currentProcedureExclusionKeys);
}

String exploreCanonicalProcedureFamilyKey(String procedure) {
  final fam = exploreTreatmentFamily(procedure);
  return fam == ExploreTreatmentFamily.other ? '' : fam.name;
}

/// Price-opportunity identity: one clinic may have independent quotes per family.
String exploreClinicProcedureOpportunityKey(
  OpenAIClinic c, {
  required String procedure,
}) {
  final clinic = exploreClinicDedupKey(c);
  if (clinic.isEmpty) return '';
  var family = exploreCanonicalProcedureFamilyKey(procedure);
  if (family.isEmpty) {
    family = exploreCanonicalProcedureFamilyKey(c.procedureFamily);
  }
  if (family.isEmpty) {
    family = exploreCanonicalProcedureFamilyKey(
      '${c.brand} ${c.rawProcedureText}',
    );
  }
  if (family.isEmpty) return clinic;
  return '$clinic|$family';
}

/// All-tab aggregation identity. Same clinic may occupy Botox and Peels slots.
String exploreAllTabSlotOpportunityKey(OpenAIClinic c, {required String pill}) {
  return exploreClinicProcedureOpportunityKey(
    c,
    procedure: explorePillAiSearchQuery(pill),
  );
}

String? exploreSiblingFamilyForClinic(
  OpenAIClinic clinic,
  Map<String, String> familyByIdentityKey,
) {
  for (final k in exploreClinicIdentityKeys(clinic)) {
    final fam = familyByIdentityKey[k];
    if (fam != null && fam.isNotEmpty) return fam;
  }
  return null;
}

void maybeLogExploreMultiProcedureReuse({
  required OpenAIClinic clinic,
  required String procedure,
  required Map<String, String> siblingFamilyByKey,
  required Set<String> currentProcedureExclusionKeys,
}) {
  if (exploreClinicBlockedFromCurrentProcedureDiscovery(
    clinic,
    currentProcedureExclusionKeys: currentProcedureExclusionKeys,
  )) {
    return;
  }
  final existing = exploreSiblingFamilyForClinic(clinic, siblingFamilyByKey);
  if (existing == null) return;
  final verifying = exploreCanonicalProcedureFamilyKey(procedure);
  if (verifying.isEmpty || existing == verifying) return;
  logExploreMultiProcedureReuse(
    name: clinic.name,
    existingFamily: existing,
    verifyingFamily: verifying,
  );
}
