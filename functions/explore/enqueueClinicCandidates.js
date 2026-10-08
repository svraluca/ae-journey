'use strict';

const {cityDisplayName, countryCodeForCity} =
    require('./marketplaces/locationFormat');
const {upsertCandidates} = require('./clinicCandidateStore');
const {
  clinicIdentityRejectReason,
  isMarketplaceOrDirectoryHost,
} = require('./identity');
const {hostOf} = require('./parsePrice');
const {buildCityId, isResolvedCityId, canonicalCityName} =
    require('./cityIdentity');
const {
  EXPLORE_DISCOVERY_PIPELINE_VERSION,
} = require('./explorePipelineVersion');

function looksLikeGuideOrDirectory(urlOrHost) {
  const h = hostOf(urlOrHost || '');
  if (!h) return false;
  if (isMarketplaceOrDirectoryHost(h)) return true;
  const needles = [
    'trueclinic', 'mymeditravel', 'whatclinic', 'bookimed',
    'medigence', 'mediglobus', 'qunomedic', 'getclearbeauty',
  ];
  return needles.some((n) => h.includes(n));
}

function normalizeEnqueueCandidate(raw) {
  const name = String(raw && raw.name || '').trim();
  const officialWebsite = String(
      raw && (raw.officialWebsite || raw.website) || '').trim();
  const sourceUrl = String(raw && raw.sourceUrl || '').trim();
  const placeId = String(raw && raw.placeId || '').trim();
  const address = String(raw && raw.address || '').trim();
  const discoveryProvider = String(
      raw && raw.discoveryProvider || 'client_discovery').trim();
  const lat = raw && raw.lat != null ? Number(raw.lat) : undefined;
  const lng = raw && raw.lng != null ? Number(raw.lng) : undefined;
  return {
    name,
    website: officialWebsite || sourceUrl,
    officialWebsite,
    sourceUrl,
    placeId,
    address,
    lat,
    lng,
    discovery_provider: discoveryProvider,
    priceStatus: 'no_public_price',
    procedureOffered: true,
  };
}

function rejectEnqueueReason(c) {
  if (!c.name && !c.placeId && !c.website) return 'empty_candidate';
  if (looksLikeGuideOrDirectory(c.website) ||
      looksLikeGuideOrDirectory(c.sourceUrl)) {
    return 'guide_or_directory';
  }
  const identity = clinicIdentityRejectReason(c.name || '', {
    websiteHost: hostOf(c.website || c.sourceUrl || ''),
  });
  if (identity) return identity;
  return null;
}

/**
 * Persist client-discovered official clinic identities for later verification.
 * Revalidates; never stores fabricated prices.
 */
async function handleEnqueueExploreClinicCandidates(request) {
  const data = (request && request.data) || {};
  const city = cityDisplayName(data.city || '');
  const procedure = String(data.procedure || '').trim();
  const countryCode = String(data.countryCode || '').trim() ||
      (city ? countryCodeForCity(city) : '');
  const placeId = String(data.placeId || '').trim();
  const latitude = data.latitude != null ? Number(data.latitude) : undefined;
  const longitude = data.longitude != null ? Number(data.longitude) : undefined;
  let cityId = String(data.cityId || '').trim();
  const rawList = Array.isArray(data.candidates) ? data.candidates : [];

  if (!city || !procedure) {
    return {
      ok: false,
      reason: 'invalid_args',
      pipelineVersion: EXPLORE_DISCOVERY_PIPELINE_VERSION,
      cityId: cityId || '',
      status: 'failed',
      candidatesDiscovered: 0,
      candidatesStored: 0,
      verifiedVisibleCount: 0,
      noPublicPriceCount: 0,
      rejectedByReason: {invalid_args: 1},
      jobId: null,
    };
  }

  if (!isResolvedCityId(cityId)) {
    cityId = buildCityId({
      placeId,
      countryCode,
      canonicalName: canonicalCityName(city),
      latitude,
      longitude,
    });
  }

  const rejectedByReason = {};
  const accepted = [];
  const seen = new Set();
  for (const raw of rawList.slice(0, 40)) {
    const c = normalizeEnqueueCandidate(raw);
    const reason = rejectEnqueueReason(c);
    if (reason) {
      rejectedByReason[reason] = (rejectedByReason[reason] || 0) + 1;
      continue;
    }
    const host = hostOf(c.website || '');
    const dedupeKeys = [
      c.placeId && `id:${c.placeId}`,
      host && `host:${host}`,
      c.name && cityId &&
          `idname:${cityId}|${c.name.toLowerCase().replace(/\s+/g, ' ')}`,
    ].filter(Boolean);
    if (dedupeKeys.some((k) => seen.has(k))) {
      rejectedByReason.duplicate = (rejectedByReason.duplicate || 0) + 1;
      continue;
    }
    for (const k of dedupeKeys) seen.add(k);
    accepted.push(c);
  }

  let stored = 0;
  if (accepted.length) {
    stored = await upsertCandidates({
      city,
      procedure,
      clinics: accepted,
      provider: 'client_enqueue',
    });
  }

  console.log(
      `[ENQUEUE CANDIDATES] pipeline=${EXPLORE_DISCOVERY_PIPELINE_VERSION} · ` +
      `${city} · ${procedure} · in=${rawList.length} · ` +
      `accepted=${accepted.length} · stored=${stored} · cityId=${cityId}`);

  return {
    ok: true,
    pipelineVersion: EXPLORE_DISCOVERY_PIPELINE_VERSION,
    cityId: cityId || '',
    status: stored > 0 ? 'partial' : 'thin',
    candidatesDiscovered: accepted.length,
    candidatesStored: stored,
    verifiedVisibleCount: 0,
    noPublicPriceCount: accepted.length,
    rejectedByReason,
    jobId: null,
  };
}

module.exports = {
  handleEnqueueExploreClinicCandidates,
  looksLikeGuideOrDirectory,
  rejectEnqueueReason,
};
