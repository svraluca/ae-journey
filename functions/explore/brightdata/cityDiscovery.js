'use strict';

const {discoverMapsClinics} = require('./brightDataMaps');
const {discoveryQueriesForProcedure, BACKGROUND_SEED_PROCEDURES} =
    require('./discoveryQueries');
const {
  shouldRunDiscovery,
  markDiscoveryRunning,
  markDiscoveryFinished,
  acquireDiscoveryLease,
  releaseDiscoveryLease,
} = require('./cityDiscoveryState');
const {useBrightData, useApifyFresha} = require('../featureFlags');
const {cityDisplayName, countryCodeForCity} =
    require('../marketplaces/locationFormat');
const {searchPlaces} = require('../discovery');
const {
  upsertCandidates,
  getCityCoverage,
  shouldExpandDiscovery,
  isVerifiedPoolHealthy,
} = require('../clinicCandidateStore');
const {buildCityId, isResolvedCityId, canonicalCityName, resolveCityIdWithFallback} =
    require('../cityIdentity');
const {
  EXPLORE_DISCOVERY_PIPELINE_VERSION,
} = require('../explorePipelineVersion');

function discoveryResponse(base = {}) {
  const rejected = base.rejectedByReason && typeof base.rejectedByReason === 'object'
      ? base.rejectedByReason
      : {};
  return {
    ok: base.ok === true,
    pipelineVersion: EXPLORE_DISCOVERY_PIPELINE_VERSION,
    cityId: base.cityId != null ? String(base.cityId) : '',
    status: base.status != null ? String(base.status) : '',
    candidatesDiscovered: Number(base.candidatesDiscovered) || 0,
    candidatesStored: Number(base.candidatesStored) || 0,
    verifiedVisibleCount: Number(base.verifiedVisibleCount) || 0,
    noPublicPriceCount: Number(base.noPublicPriceCount) || 0,
    rejectedByReason: rejected,
    jobId: base.jobId != null ? base.jobId : null,
    skipped: base.skipped === true,
    reason: base.reason != null ? String(base.reason) : '',
    needsLocationResolution: base.needsLocationResolution === true,
    failureType: base.failureType || undefined,
    procedure: base.procedure || undefined,
    city: base.city || undefined,
    coverage: base.coverage || undefined,
    results: base.results || undefined,
    // Legacy aliases for older clients.
    candidates: Number(
        base.candidatesStored != null
          ? base.candidatesStored
          : base.candidates) || 0,
  };
}

async function saveCandidates(city, procedure, clinics) {
  return upsertCandidates({
    city,
    procedure,
    clinics,
    provider: (clinics[0] && clinics[0].discovery_provider) || 'brightdata_maps',
  });
}

/**
 * Background city/procedure clinic discovery via Bright Data Maps
 * (Places fallback when Bright Data Maps is not configured).
 */
async function runCityProcedureDiscovery({
  city,
  procedure,
  force = false,
  cityId: cityIdIn = '',
  countryCode = '',
  adminArea = '',
  latitude,
  longitude,
  placeId = '',
} = {}) {
  const display = cityDisplayName(city);
  const proc = String(procedure || '').trim();
  if (!display || !proc) {
    return discoveryResponse({
      ok: false,
      reason: 'invalid_args',
      status: 'failed',
    });
  }
  const coverage = await getCityCoverage(display, proc);
  const inferredCc = String(countryCode || coverage.countryCode || '').trim() ||
      countryCodeForCity(display) ||
      '';
  let cityId = String(cityIdIn || coverage.cityId || '').trim();
  if (!isResolvedCityId(cityId)) {
    cityId = resolveCityIdWithFallback({
      placeId,
      countryCode: inferredCc,
      adminArea,
      canonicalName: canonicalCityName(display),
      latitude: latitude ?? coverage.latitude,
      longitude: longitude ?? coverage.longitude,
      city: display,
    });
  }
  if (!isResolvedCityId(cityId)) {
    console.log(
        `[DISCOVERY] city unresolved · ${display} · needs location · ` +
        `pipeline=${EXPLORE_DISCOVERY_PIPELINE_VERSION}`);
    return discoveryResponse({
      ok: false,
      reason: 'city_unresolved',
      needsLocationResolution: true,
      cityId: cityId || '',
      status: 'failed',
    });
  }
  // Unknown coverage / below visible verified target must expand.
  // Never treat raw candidateCount alone as pool_healthy.
  if (!force &&
      !shouldExpandDiscovery(coverage) &&
      isVerifiedPoolHealthy(coverage)) {
    console.log(`[DISCOVERY] verified pool healthy · skip paid discovery`);
    await markDiscoveryFinished(display, proc, {...coverage, cityId});
    return discoveryResponse({
      ok: true,
      skipped: true,
      reason: 'pool_healthy',
      cityId,
      status: 'complete',
      candidatesDiscovered: 0,
      candidatesStored: coverage.candidateCount || 0,
      verifiedVisibleCount: coverage.verifiedVisibleCount || 0,
      noPublicPriceCount: coverage.noPublicPriceCount || 0,
      coverage,
    });
  }
  if (!force) {
    const gate = await shouldRunDiscovery(display, proc, coverage, cityId);
    if (!gate.start) {
      console.log(`[DISCOVERY] skip · ${display} · ${proc} · ${gate.reason}`);
      return discoveryResponse({
        ok: true,
        skipped: true,
        reason: gate.reason,
        jobId: gate.jobId || null,
        needsLocationResolution: gate.needsLocationResolution || false,
        cityId,
        status: coverage.discoveryStatus || coverage.status || 'partial',
        candidatesDiscovered: 0,
        candidatesStored: coverage.candidateCount || 0,
        verifiedVisibleCount: coverage.verifiedVisibleCount || 0,
        noPublicPriceCount: coverage.noPublicPriceCount || 0,
        coverage,
      });
    }
  }
  if (shouldExpandDiscovery(coverage) || coverage.candidateCount == null) {
    console.log(`[DISCOVERY] thin/unknown pool · trigger background expansion`);
  }

  const lease = await acquireDiscoveryLease(display, proc, {cityId});
  if (!lease.acquired) {
    if (lease.needsLocationResolution) {
      return discoveryResponse({
        ok: false,
        reason: 'city_unresolved',
        needsLocationResolution: true,
        cityId: cityId || '',
        status: 'failed',
      });
    }
    console.log(
        `[DISCOVERY] lease_held · job=${lease.jobId} · ${display} · ${proc}`);
    return discoveryResponse({
      ok: true,
      skipped: true,
      reason: 'lease_held',
      jobId: lease.jobId,
      cityId,
      status: 'running',
      candidatesDiscovered: 0,
      candidatesStored: coverage.candidateCount || 0,
      verifiedVisibleCount: coverage.verifiedVisibleCount || 0,
      noPublicPriceCount: coverage.noPublicPriceCount || 0,
      coverage,
    });
  }

  await markDiscoveryRunning(display, proc, {
    cityId,
    jobId: lease.jobId,
    leaseOwner: lease.leaseOwner,
  });
  const queries = discoveryQueriesForProcedure(proc, display);
  console.log(
      `[BRIGHTDATA MAPS] start · ${display} · ${proc} · job=${lease.jobId} · ` +
      `pipeline=${EXPLORE_DISCOVERY_PIPELINE_VERSION}`);

  let clinics = [];
  try {
    if (useBrightData()) {
      try {
        clinics = await discoverMapsClinics({
          city: display,
          queries,
          limitPerQuery: 25,
        });
      } catch (bdErr) {
        console.log(
            `[BRIGHTDATA MAPS] optional provider failed · continue · ` +
            `${bdErr.message || bdErr}`);
        clinics = [];
      }
    } else {
      console.log(
          `[BRIGHTDATA MAPS] disabled or unconfigured · ` +
          `USE_BRIGHTDATA / BRIGHTDATA_API_KEY · Places fallback`);
    }
    // Fallback: Google Places text search (existing). One missing provider
    // must not fail the cold-city job.
    if (!clinics.length) {
      console.log(`[DISCOVERY] places fallback · ${display} · ${proc}`);
      clinics = await searchPlaces({
        city: display,
        procedure: proc,
        apiKey: process.env.GOOGLE_PLACES_API_KEY,
        maxResults: Number(process.env.EXPLORE_DISCOVERY_LIMIT || 30),
        queries,
        paginate: true,
      });
      clinics = clinics.map((p) => ({
        ...p,
        discovery_provider: 'google_places',
      }));
    }

    const saved = await saveCandidates(display, proc, clinics);
    const nextCoverage = await getCityCoverage(display, proc);
    const status = await markDiscoveryFinished(display, proc, {
      ...nextCoverage,
      cityId,
      jobId: lease.jobId,
    });
    const verifiedVisible =
        Number(nextCoverage.verifiedVisibleCount || 0);
    const noPublicPrice =
        Number(nextCoverage.noPublicPriceCount || 0);
    console.log(
        `[BRIGHTDATA MAPS] ${status} · candidates=${saved} · ` +
        `visible=${verifiedVisible} · noPublic=${noPublicPrice} · ` +
        `${display} · ${proc}`);
    return discoveryResponse({
      ok: true,
      skipped: false,
      cityId,
      status,
      candidatesDiscovered: clinics.length,
      candidatesStored: saved,
      verifiedVisibleCount: verifiedVisible,
      noPublicPriceCount: noPublicPrice,
      procedure: proc,
      city: display,
      jobId: lease.jobId,
    });
  } catch (err) {
    const msg = String(err.message || err);
    const quota = /429|RESOURCE_EXHAUSTED|quota/i.test(msg);
    await markDiscoveryFinished(display, proc, {
      cityId,
      jobId: lease.jobId,
      candidateCount: coverage.candidateCount || 0,
      verifiedPriceCount: coverage.verifiedPriceCount || 0,
      technicalFailure: true,
      failureType: quota ? 'quota' : 'temporary',
      failureReason: msg.slice(0, 400),
    });
    console.log(`[BRIGHTDATA MAPS] failed · ${msg}`);
    return discoveryResponse({
      ok: false,
      reason: msg,
      failureType: quota ? 'quota' : 'temporary',
      cityId,
      status: 'failed',
      jobId: lease.jobId,
    });
  } finally {
    try {
      await releaseDiscoveryLease(display, proc, {
        cityId,
        jobId: lease.jobId,
      });
    } catch (_) {/* ignore */}
  }
}

/**
 * Seed main procedure families for a city (background).
 */
async function runCityBackgroundSeed({
  city,
  force = false,
  cityId = '',
  countryCode = '',
  adminArea = '',
  latitude,
  longitude,
  placeId = '',
} = {}) {
  const display = cityDisplayName(city);
  if (!display) {
    return discoveryResponse({
      ok: false,
      reason: 'invalid_city',
      status: 'failed',
    });
  }
  const inferredCc = String(countryCode || '').trim() ||
      countryCodeForCity(display) ||
      '';
  let resolvedCityId = String(cityId || '').trim();
  if (!isResolvedCityId(resolvedCityId)) {
    resolvedCityId = resolveCityIdWithFallback({
      placeId,
      countryCode: inferredCc,
      adminArea,
      canonicalName: canonicalCityName(display),
      latitude,
      longitude,
      city: display,
    });
  }
  if (!isResolvedCityId(resolvedCityId)) {
    console.log(
        `[DISCOVERY] seed city unresolved · ${display} · ` +
        `pipeline=${EXPLORE_DISCOVERY_PIPELINE_VERSION}`);
    return discoveryResponse({
      ok: false,
      reason: 'city_unresolved',
      needsLocationResolution: true,
      cityId: resolvedCityId || '',
      status: 'failed',
      city: display,
    });
  }
  // Explicitly do not start Fresha while Bright Data path is active.
  if (useApifyFresha()) {
    console.log('[BRIGHTDATA MAPS] USE_APIFY_FRESHA=true — Bright Data seed skipped');
  }
  const results = [];
  let candidatesDiscovered = 0;
  let candidatesStored = 0;
  let verifiedVisibleCount = 0;
  let noPublicPriceCount = 0;
  let lastJobId = null;
  let lastStatus = 'partial';
  let anyOk = false;
  let unresolvedOnly = true;
  for (const procedure of BACKGROUND_SEED_PROCEDURES) {
    const row = await runCityProcedureDiscovery({
      city: display,
      procedure,
      force,
      cityId: resolvedCityId,
      countryCode: inferredCc,
      adminArea,
      latitude,
      longitude,
      placeId,
    });
    results.push(row);
    if (row && row.ok) anyOk = true;
    if (row && row.reason !== 'city_unresolved') unresolvedOnly = false;
    if (row && typeof row.candidatesDiscovered === 'number') {
      candidatesDiscovered += row.candidatesDiscovered;
    }
    if (row && typeof row.candidatesStored === 'number') {
      candidatesStored += row.candidatesStored;
    }
    if (row && typeof row.verifiedVisibleCount === 'number') {
      verifiedVisibleCount =
          Math.max(verifiedVisibleCount, row.verifiedVisibleCount);
    }
    if (row && typeof row.noPublicPriceCount === 'number') {
      noPublicPriceCount =
          Math.max(noPublicPriceCount, row.noPublicPriceCount);
    }
    if (row && row.jobId) lastJobId = row.jobId;
    if (row && row.status) lastStatus = row.status;
  }
  if (!anyOk && unresolvedOnly) {
    return discoveryResponse({
      ok: false,
      reason: 'city_unresolved',
      needsLocationResolution: true,
      cityId: resolvedCityId,
      status: 'failed',
      city: display,
      results,
    });
  }
  return discoveryResponse({
    ok: true,
    city: display,
    cityId: resolvedCityId,
    status: lastStatus || 'partial',
    candidatesDiscovered,
    candidatesStored,
    verifiedVisibleCount,
    noPublicPriceCount,
    jobId: lastJobId,
    results,
  });
}

async function handleRequestExploreCityDiscovery(request) {
  const data = (request && request.data) || {};
  const city = cityDisplayName(data.city || '');
  const procedure = String(data.procedure || '').trim();
  const force = data.force === true;
  const seedAll = data.seedAll === true || !procedure;
  const cityId = String(data.cityId || '').trim();
  const countryCode = String(data.countryCode || '').trim() ||
      (city ? countryCodeForCity(city) : '');
  const adminArea = String(data.adminArea || '').trim();
  const placeId = String(data.placeId || '').trim();
  const latitude = data.latitude != null ? Number(data.latitude) : undefined;
  const longitude = data.longitude != null ? Number(data.longitude) : undefined;
  console.log(
      `[DISCOVERY] request · pipeline=${EXPLORE_DISCOVERY_PIPELINE_VERSION} · ` +
      `city=${city} · procedure=${procedure || '(seedAll)'} · ` +
      `cityId=${cityId || '-'} · cc=${countryCode || '-'} · ` +
      `placeId=${placeId || '-'} · force=${force}`);
  if (!city) {
    return discoveryResponse({
      ok: false,
      reason: 'invalid_city',
      status: 'failed',
    });
  }
  if (seedAll) {
    return runCityBackgroundSeed({
      city,
      force,
      cityId,
      countryCode,
      adminArea,
      latitude,
      longitude,
      placeId,
    });
  }
  return runCityProcedureDiscovery({
    city,
    procedure,
    force,
    cityId,
    countryCode,
    adminArea,
    latitude,
    longitude,
    placeId,
  });
}

module.exports = {
  EXPLORE_DISCOVERY_PIPELINE_VERSION,
  runCityProcedureDiscovery,
  runCityBackgroundSeed,
  handleRequestExploreCityDiscovery,
  saveCandidates,
  discoveryResponse,
};
