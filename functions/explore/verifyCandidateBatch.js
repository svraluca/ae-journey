'use strict';

const {HttpsError} = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const {HttpClinicPageFetcher} = require('./pageFetcher');
const {verifyPlace, pastDeadline} = require('./getExploreProcedurePrices');
const {upsertVerified} = require('./firestoreStore');
const {
  loadUnverifiedBatch,
  getCityCoverage,
  shouldContinueVerification,
  candidateToPlace,
  markCandidateAttempt,
  claimCandidateForVerify,
  persistCandidateIdentity,
} = require('./clinicCandidateStore');
const {isTemporaryFailureReason} = require('./discoveryState');
const {cityDisplayName} = require('./marketplaces/locationFormat');

const BATCH_MIN = 5;
const BATCH_MAX = 10;
const BATCH_WORKERS = 3;
const BATCH_DEADLINE_MS = 95000;
const BATCH_CLAIM_RESERVE_MS = 20000;
const NO_WEBSITE_RETRY_MS = 24 * 60 * 60 * 1000;

function verifyExceptionPatch(err) {
  const msg = String(err && err.message || err || '');
  const temp = isTemporaryFailureReason(msg) ||
      /timeout|ECONNRESET|unavailable|5\d\d|cloudflare|renderer/i.test(msg);
  return {
    failureReason: temp ? 'temporary_fetch_failure' : 'verify_error',
    permanent: false,
    temporaryMs: 6 * 60 * 60 * 1000,
  };
}

function batchSize(verifiedPriceCount) {
  const n = Number(verifiedPriceCount) || 0;
  if (n < 4) return 8;
  if (n < 10) return 8;
  if (n < 20) return 6;
  return 5;
}

async function resolveCandidateWebsite(row) {
  const apiKey = process.env.GOOGLE_PLACES_API_KEY;
  if (!apiKey) return null;
  const {placeDetails, findPlaceByName} = require('./discovery');
  let place = null;
  if (row.placeId) {
    place = await placeDetails(row.placeId, apiKey);
  }
  if ((!place || !place.website) && row.name) {
    place = await findPlaceByName({
      name: row.name,
      city: row.cityDisplay || row.city || '',
      apiKey,
    });
  }
  if (!place || !place.website) return null;
  return place;
}

async function verifyOneCandidate(row, {
  display,
  proc,
  fetcher,
  deadlineAt,
  deep = true,
}) {
  let place = candidateToPlace(row);
  if (!place.website) {
    const resolved = await resolveCandidateWebsite(row);
    if (resolved && resolved.website) {
      await persistCandidateIdentity(row, {
        website: resolved.website,
        placeId: resolved.placeId,
        address: resolved.address,
        lat: resolved.lat,
        lng: resolved.lng,
        rating: resolved.rating,
        reviews: resolved.reviews,
      });
      place = {
        ...place,
        ...candidateToPlace({
          ...row,
          website: resolved.website,
          placeId: resolved.placeId || row.placeId,
          address: resolved.address || row.address,
        }),
        website: resolved.website,
        placeId: resolved.placeId || place.placeId,
      };
    }
  }
  if (!place.website) {
    await markCandidateAttempt(row, {
      procedure: proc,
      failureReason: 'no_website',
      permanent: false,
      temporaryMs: NO_WEBSITE_RETRY_MS,
    });
    return {offeredUnpriced: 0, accepted: 0};
  }
  try {
    const result = await verifyPlace(fetcher, place, {
      city: display,
      procedure: proc,
      deep,
      deadlineAt,
    });
    if (result && result.clinic) {
      await upsertVerified(display, proc, [result.clinic]);
      await markCandidateAttempt(row, {
        procedure: proc,
        verified: true,
        offered: true,
      });
      return {accepted: 1, offeredUnpriced: 0};
    }
    if (result && result.permanentReject) {
      await markCandidateAttempt(row, {
        procedure: proc,
        permanent: true,
        failureReason: result.permanentReject,
      });
      return {accepted: 0, offeredUnpriced: 0};
    }
    if (result && result.procedureOffered) {
      await markCandidateAttempt(row, {
        procedure: proc,
        offered: true,
        priceStatus: 'no_public_price',
      });
      return {accepted: 0, offeredUnpriced: 1};
    }
    await markCandidateAttempt(row, {
      procedure: proc,
      failureReason: 'no_literal_price',
      priceStatus: 'unresolved',
      temporaryMs: 12 * 60 * 60 * 1000,
    });
    return {accepted: 0, offeredUnpriced: 0};
  } catch (err) {
    const patch = verifyExceptionPatch(err);
    await markCandidateAttempt(row, {
      procedure: proc,
      failureReason: patch.failureReason,
      permanent: patch.permanent,
      temporaryMs: patch.temporaryMs,
    });
    return {accepted: 0, offeredUnpriced: 0};
  }
}

async function verifyCandidateBatch({
  city,
  procedure,
  limit = 0,
  deadlineMs,
  deep = true,
} = {}) {
  const display = cityDisplayName(city) || String(city || '').trim();
  const proc = String(procedure || '').trim();
  if (!display || !proc) {
    return {ok: false, reason: 'invalid_args'};
  }
  const coverage = await getCityCoverage(display, proc);
  if (!shouldContinueVerification(coverage) &&
      Number(coverage.unverifiedCandidateCount || 0) <= 0) {
    console.log(`[VERIFY QUEUE] skip · ${display} · ${proc} · ` +
        `verified=${coverage.verifiedPriceCount}`);
    return {ok: true, skipped: true, reason: 'verification_idle', coverage};
  }
  const isDeep = deep !== false;
  const budget = Number(deadlineMs || (isDeep ? BATCH_DEADLINE_MS : 14000));
  const size = isDeep
    ? Math.min(
        BATCH_MAX,
        Math.max(BATCH_MIN, limit || batchSize(coverage.verifiedPriceCount)))
    : Math.min(5, Math.max(1, limit || 5));
  const rows = await loadUnverifiedBatch(display, proc, {limit: size});
  const remaining = Math.max(0,
      Number(coverage.unverifiedCandidateCount || 0) - rows.length);
  console.log(
      `[VERIFY QUEUE] batch=${rows.length} remaining=${remaining} ` +
      `deep=${isDeep} deadlineMs=${budget}`);
  if (!rows.length) {
    return {ok: true, skipped: true, reason: 'empty_queue', coverage};
  }

  const deadlineAt = Date.now() + budget;
  const fetcher = new HttpClinicPageFetcher();
  let accepted = 0;
  let offeredUnpriced = 0;
  let cursor = 0;
  const workerCount = Math.min(isDeep ? BATCH_WORKERS : 2, rows.length);
  const claimReserve = isDeep ? BATCH_CLAIM_RESERVE_MS : 3000;

  async function worker() {
    while (true) {
      if (pastDeadline(deadlineAt, claimReserve)) {
        console.log('[VERIFY QUEUE] batch deadline — stop claiming');
        return;
      }
      const idx = cursor++;
      if (idx >= rows.length) return;
      const row = rows[idx];
      const claimed = await claimCandidateForVerify(row);
      if (!claimed) {
        console.log(`[VERIFY QUEUE] skip leased · ${row.name}`);
        continue;
      }
      const result = await verifyOneCandidate(row, {
        display,
        proc,
        fetcher,
        deadlineAt,
        deep: isDeep,
      });
      accepted += result.accepted || 0;
      offeredUnpriced += result.offeredUnpriced || 0;
    }
  }

  await Promise.all(Array.from({length: workerCount}, () => worker()));
  const next = await getCityCoverage(display, proc);
  return {
    ok: true,
    skipped: false,
    accepted,
    offeredUnpriced,
    batch: rows.length,
    coverage: next,
  };
}

async function handleVerifyExploreCandidates(request) {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Sign in required');
  }
  const data = request.data || {};
  return verifyCandidateBatch({
    city: data.city,
    procedure: data.procedure,
    limit: Number(data.limit || 5),
    deep: false,
    deadlineMs: 14000,
  });
}

async function handleScheduledCandidateVerify() {
  const snap = await admin.firestore()
      .collection('explore_city_discovery')
      .limit(40)
      .get();
  let ran = 0;
  const results = [];
  for (const doc of snap.docs) {
    if (ran >= 2) break;
    const city = doc.data() && doc.data().city;
    const procedure = doc.data() && doc.data().procedure;
    if (!city || !procedure) continue;
    const coverage = await getCityCoverage(city, procedure);
    if (!shouldContinueVerification(coverage)) continue;
    results.push(await verifyCandidateBatch({
      city,
      procedure,
      limit: 6,
      deep: true,
      deadlineMs: 150000,
    }));
    ran += 1;
  }
  return {ok: true, cities: ran, results};
}

module.exports = {
  verifyCandidateBatch,
  handleVerifyExploreCandidates,
  handleScheduledCandidateVerify,
  batchSize,
  resolveCandidateWebsite,
  BATCH_WORKERS,
  BATCH_DEADLINE_MS,
  verifyExceptionPatch,
};
