'use strict';

/**
 * Persistent clinic-identity repository.
 * One document per real clinic (city + placeId, else host + name).
 * Procedure metadata is additive — Botox then Fillers keeps both families.
 */

const admin = require('firebase-admin');
const {requestedFamily} = require('./procedureRelation');
const {clinicIdentityRejectReason} = require('./identity');
const {hostOf} = require('./parsePrice');
const {cityDisplayName, countryCodeForCity} = require('./marketplaces/locationFormat');

const COLLECTION = 'explore_clinic_candidates';
const NO_PUBLIC_PRICE_RECHECK_MS = 10 * 24 * 60 * 60 * 1000;
const VERIFY_LEASE_MS = 3 * 60 * 1000;

function cityKey(city) {
  return String(city || '').trim().toLowerCase();
}

function normalizeName(name) {
  return String(name || '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .trim();
}

function familyOf(procedure) {
  const fam = requestedFamily(procedure);
  return fam && fam !== 'other' ? fam : '';
}

/**
 * Stable clinic identity. Prefer city + Google Place ID so Bright Data and
 * Places upsert the same document. Fallback: host + normalized name.
 * Place-ID form matches legacy Bright Data ids: `{city}|{placeId}`.
 */
function candidateDocId({city, placeId, website, name}) {
  const ck = cityKey(city);
  const pid = String(placeId || '').trim();
  if (ck && pid) {
    return encodeURIComponent(`${ck}|${pid}`).replace(/%/g, '_').slice(0, 400);
  }
  const host = hostOf(website || '');
  const nn = normalizeName(name);
  const raw = host ? `${ck}|host:${host}|${nn}` : `${ck}|${nn || name || 'clinic'}`;
  return encodeURIComponent(raw).replace(/%/g, '_').slice(0, 400);
}

function mergeCandidateRecord(existing, incoming) {
  const a = legacyToCanonical(existing);
  const b = legacyToCanonical(incoming);
  return {
    ...a,
    ...b,
    placeId: a.placeId || b.placeId,
    website: a.website || b.website,
    websiteHost: a.websiteHost || b.websiteHost,
    name: a.name || b.name,
    discoveredProcedures: [...new Set([
      ...(a.discoveredProcedures || []),
      ...(b.discoveredProcedures || []),
    ])],
    procedureFamilies: [...new Set([
      ...(a.procedureFamilies || []),
      ...(b.procedureFamilies || []),
    ])],
    discoveryProviders: [...new Set([
      ...(a.discoveryProviders || []),
      ...(b.discoveryProviders || []),
    ])],
    firstSeenAt: a.firstSeenAt || b.firstSeenAt,
    verificationAttempts: Math.max(
        Number(a.verificationAttempts || 0),
        Number(b.verificationAttempts || 0)),
    permanentRejectReason: a.permanentRejectReason || b.permanentRejectReason,
    procedureOffered: {...(a.procedureOffered || {}), ...(b.procedureOffered || {})},
    priceStatus: {...(a.priceStatus || {}), ...(b.priceStatus || {})},
  };
}

function prioritizePlaces({
  reverify = [],
  stored = [],
  places = [],
  serp = [],
} = {}) {
  const out = [];
  const seen = new Set();
  const add = (place, source) => {
    if (!place || !place.name) return;
    const pid = String(place.placeId || place.place_id || '').trim();
    const host = hostOf(place.website || '');
    const name = normalizeName(place.name);
    const keys = [
      pid && `id:${pid}`,
      host && `host:${host}`,
      name && `name:${name}`,
    ].filter(Boolean);
    if (keys.some((k) => seen.has(k))) return;
    for (const k of keys) seen.add(k);
    out.push({...place, queueSource: source});
  };
  for (const p of reverify) add(p, 'reverify');
  for (const p of stored) add(p, 'stored');
  for (const p of places) add(p, 'places');
  for (const p of serp) add(p, 'serp');
  return out;
}

function coverageLevel(candidateCount) {
  const n = Number(candidateCount) || 0;
  if (n < 15) return 'thin';
  if (n < 30) return 'partial';
  if (n < 60) return 'healthy';
  return 'broad';
}

function verificationPriority(verifiedCount) {
  const n = Number(verifiedCount) || 0;
  if (n < 4) return 'high';
  if (n < 10) return 'active';
  if (n < 20) return 'normal';
  return 'maintenance';
}

/** Visible verified target — never treat candidate count as “healthy”. */
function exploreVisibleTarget() {
  const n = Number(process.env.EXPLORE_VISIBLE_TARGET || 4);
  if (!Number.isFinite(n) || n < 1) return 4;
  return Math.min(8, Math.floor(n));
}

/**
 * Pool is healthy only when post-validation unique verified clinics
 * reach the visible target. Raw/candidate/pre-validation counts do not count.
 */
function isVerifiedPoolHealthy({
  verifiedPriceCount,
  verifiedVisibleCount,
} = {}) {
  const n = Number(
      verifiedVisibleCount != null
        ? verifiedVisibleCount
        : verifiedPriceCount);
  if (!Number.isFinite(n)) return false;
  return n >= exploreVisibleTarget();
}

function shouldExpandDiscovery({
  candidateCount,
  verifiedPriceCount,
  verifiedVisibleCount,
} = {}) {
  // Unknown coverage must expand.
  if (candidateCount == null &&
      verifiedPriceCount == null &&
      verifiedVisibleCount == null) {
    return true;
  }
  // Below visible target → always discover / continue verification.
  if (!isVerifiedPoolHealthy({verifiedPriceCount, verifiedVisibleCount})) {
    return true;
  }
  // Above visible target but thin candidate pool → optional growth.
  if (candidateCount != null && coverageLevel(candidateCount) === 'thin') {
    return true;
  }
  return false;
}

function shouldContinueVerification({
  verifiedPriceCount = 0,
  unverifiedCandidateCount = 0,
} = {}) {
  return unverifiedCandidateCount > 0 &&
      verificationPriority(verifiedPriceCount) !== 'maintenance';
}

function legacyToCanonical(data) {
  const src = data && typeof data === 'object' ? data : {};
  const procedures = Array.isArray(src.discoveredProcedures)
    ? src.discoveredProcedures.map(String)
    : (src.procedure ? [String(src.procedure)] : []);
  const families = Array.isArray(src.procedureFamilies)
    ? src.procedureFamilies.map(String)
    : procedures.map(familyOf).filter(Boolean);
  return {
    cityKey: src.cityKey || cityKey(src.city || src.cityDisplay || ''),
    cityDisplay: src.cityDisplay || src.city || '',
    countryCode: src.countryCode || '',
    placeId: src.placeId || src.place_id || '',
    name: src.name || '',
    normalizedName: src.normalizedName || normalizeName(src.name || ''),
    website: src.website || '',
    websiteHost: src.websiteHost || hostOf(src.website || ''),
    address: src.address || src.formattedAddress || '',
    lat: Number(src.lat || 0),
    lng: Number(src.lng || 0),
    rating: Number(src.rating || 0),
    reviews: Number(src.reviews || src.user_ratings_total || 0),
    discoveredProcedures: [...new Set(procedures.filter(Boolean))],
    procedureFamilies: [...new Set(families.filter(Boolean))],
    discoveryProviders: Array.isArray(src.discoveryProviders)
      ? src.discoveryProviders
      : (src.discovery_provider ? [src.discovery_provider] : []),
    verificationAttempts: Number(src.verificationAttempts || 0),
    lastAttemptedAt: src.lastAttemptedAt || null,
    lastVerifiedAt: src.lastVerifiedAt || null,
    lastFailureReason: src.lastFailureReason || '',
    temporaryRetryAfter: Number(src.temporaryRetryAfter || 0),
    verifyLeaseUntil: Number(src.verifyLeaseUntil || 0),
    permanentRejectReason: src.permanentRejectReason || '',
    procedureOffered: src.procedureOffered && typeof src.procedureOffered === 'object'
      ? src.procedureOffered : {},
    priceStatus: src.priceStatus && typeof src.priceStatus === 'object'
      ? src.priceStatus : {},
    status: src.status || 'candidate',
    firstSeenAt: src.firstSeenAt || null,
    lastSeenAt: src.lastSeenAt || src.updatedAt || null,
    updatedAt: src.updatedAt || null,
  };
}

function candidateToPlace(row) {
  const c = legacyToCanonical(row);
  return {
    name: c.name,
    website: c.website,
    address: c.address,
    lat: c.lat,
    lng: c.lng,
    rating: c.rating,
    reviews: c.reviews,
    placeId: c.placeId,
    cityDisplay: c.cityDisplay,
    city: c.cityDisplay,
    discovery_provider: (c.discoveryProviders || [])[0] || 'stored_candidate',
    fromCandidateStore: true,
  };
}

function isRetryBlocked(row, now = Date.now()) {
  const c = legacyToCanonical(row);
  if (c.permanentRejectReason) return true;
  if (Number(c.temporaryRetryAfter || 0) > now) return true;
  if (Number(c.verifyLeaseUntil || 0) > now) return true;
  return false;
}

function discoveryUpsertFields(raw, {
  cityKey,
  cityDisplay,
  countryCode,
  procedure,
  fam,
  provider,
  FieldValue,
} = {}) {
  const payload = {
    cityKey,
    cityDisplay,
    countryCode,
    placeId: String(raw.placeId || raw.place_id || ''),
    name: String(raw.name || '').trim(),
    normalizedName: normalizeName(raw.name),
    address: String(raw.address || raw.formattedAddress || ''),
    lat: Number(raw.lat || 0),
    lng: Number(raw.lng || 0),
    rating: Number(raw.rating || 0),
    reviews: Number(raw.reviews || 0),
    lastSeenAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  };
  const website = String(raw.website || '').trim();
  if (website) {
    payload.website = website;
    payload.websiteHost = hostOf(website);
  }
  if (procedure) {
    payload.discoveredProcedures = FieldValue.arrayUnion(String(procedure));
  }
  if (fam) payload.procedureFamilies = FieldValue.arrayUnion(fam);
  if (provider) payload.discoveryProviders = FieldValue.arrayUnion(provider);
  return payload;
}

function applyFamilyVerificationState(existing, {
  fam = '',
  offered = null,
  priceStatus = '',
  verified = false,
} = {}) {
  const src = existing && typeof existing === 'object' ? existing : {};
  const nextPrice = {
    ...(src.priceStatus && typeof src.priceStatus === 'object' ? src.priceStatus : {}),
  };
  const nextOffered = {
    ...(src.procedureOffered && typeof src.procedureOffered === 'object'
      ? src.procedureOffered : {}),
  };
  if (fam && verified) {
    nextPrice[fam] = 'verified';
    nextOffered[fam] = true;
  } else if (fam && offered === true &&
      (priceStatus === 'no_public_price' || priceStatus === 'unresolved')) {
    nextOffered[fam] = true;
    nextPrice[fam] = priceStatus || 'unresolved';
  }
  return {priceStatus: nextPrice, procedureOffered: nextOffered};
}

function tallyProcedureFamilyCoverage(rows, fam, {now = Date.now()} = {}) {
  let relevant = 0;
  let unverified = 0;
  let familyVerified = 0;
  let noPublicPrice = 0;
  for (const row of rows || []) {
    const families = row.procedureFamilies || [];
    const isRel = !fam || families.length === 0 || families.includes(fam);
    if (!isRel) continue;
    relevant += 1;
    const price = fam ? (row.priceStatus || {})[fam] : '';
    if (price === 'verified') familyVerified += 1;
    else if (price === 'no_public_price') noPublicPrice += 1;
    else if (!isRetryBlocked(row, now) && row.status !== 'rejected') {
      unverified += 1;
    }
  }
  return {relevant, unverified, familyVerified, noPublicPrice};
}

function noPublicPriceRetryAfter(now = Date.now()) {
  return now + NO_PUBLIC_PRICE_RECHECK_MS;
}

async function upsertCandidates({
  city,
  procedure,
  clinics,
  provider = 'brightdata_maps',
  cityId = '',
  countryCode = '',
} = {}) {
  const display = cityDisplayName(city) || String(city || '').trim();
  const ck = cityKey(display);
  const fam = familyOf(procedure);
  const preferredId = String(cityId || '').trim();
  const country = (() => {
    const explicit = String(countryCode || '').trim().toUpperCase();
    if (explicit) return explicit;
    try {
      return countryCodeForCity(display) || '';
    } catch (_) {
      return '';
    }
  })();
  if ((!ck && !preferredId) || !Array.isArray(clinics) || !clinics.length) return 0;

  const db = admin.firestore();
  const FieldValue = admin.firestore.FieldValue;
  let saved = 0;
  let batch = db.batch();
  let ops = 0;
  const flush = async () => {
    if (!ops) return;
    await batch.commit();
    batch = db.batch();
    ops = 0;
  };

  for (const raw of clinics) {
    if (!raw || !raw.name) continue;
    if (clinicIdentityRejectReason(raw.name)) continue;
    const id = candidateDocId({
      city: display,
      placeId: raw.placeId || raw.place_id,
      website: raw.website,
      name: raw.name,
    });
    const ref = db.collection(COLLECTION).doc(id);
    const payload = discoveryUpsertFields(raw, {
      cityKey: ck,
      cityDisplay: display,
      countryCode: country,
      procedure,
      fam,
      provider,
      FieldValue,
    });
    // Do not write status — rediscovery must not reset verified / retry state.
    batch.set(ref, {
      ...payload,
      city: display,
      cityId: preferredId || null,
      procedure: procedure || '',
      discovery_provider: provider,
    }, {merge: true});
    saved += 1;
    ops += 1;
    console.log(`[CANDIDATE] added · provider=${provider} · clinic=${raw.name}`);
    if (ops >= 400) await flush();
  }
  await flush();
  return saved;
}

async function loadCandidatesForCity(city, {limit = 120, cityId = ''} = {}) {
  const display = cityDisplayName(city) || String(city || '').trim();
  const ck = cityKey(display);
  if (!ck && !cityId) return [];
  const cap = Math.min(200, Number(limit) || 120);
  const col = admin.firestore().collection(COLLECTION);
  const queries = [];
  const preferredId = String(cityId || '').trim();
  if (preferredId) {
    queries.push(col.where('cityId', '==', preferredId).limit(cap).get());
  }
  if (ck) {
    queries.push(col.where('cityKey', '==', ck).limit(cap).get());
    queries.push(col.where('city', '==', display).limit(cap).get());
  }
  const snaps = await Promise.all(queries);
  const byId = new Map();
  for (const snap of snaps) {
    for (const d of snap.docs) {
      if (!byId.has(d.id)) {
        byId.set(d.id, legacyToCanonical({id: d.id, ...d.data()}));
      }
    }
  }
  return [...byId.values()].slice(0, cap);
}

async function loadCandidatesForProcedure(city, procedure, {
  limit = 40,
  includeBlocked = false,
  cityId = '',
} = {}) {
  const fam = familyOf(procedure);
  const all = await loadCandidatesForCity(city, {limit: 200, cityId});
  const now = Date.now();
  const out = [];
  for (const row of all) {
    if (!includeBlocked && isRetryBlocked(row, now)) continue;
    const families = row.procedureFamilies || [];
    const procs = row.discoveredProcedures || [];
    const relevant = !fam ||
        families.includes(fam) ||
        procs.some((p) => familyOf(p) === fam) ||
        families.length === 0;
    if (!relevant) continue;
    out.push(row);
    if (out.length >= limit) break;
  }
  return out;
}

async function loadUnverifiedBatch(city, procedure, {limit = 8} = {}) {
  const fam = familyOf(procedure);
  const rows = await loadCandidatesForCity(city, {limit: 200});
  const now = Date.now();
  const pending = rows.filter((row) => {
    if (isRetryBlocked(row, now)) return false;
    if (row.status === 'rejected') return false;
    const price = (row.priceStatus || {})[fam] || '';
    if (price === 'verified') return false;
    const families = row.procedureFamilies || [];
    if (fam && families.length && !families.includes(fam)) return false;
    return true;
  });
  pending.sort((a, b) =>
    Number(a.verificationAttempts || 0) - Number(b.verificationAttempts || 0));
  return pending.slice(0, Math.min(10, Math.max(5, Number(limit) || 8)));
}

async function markCandidateAttempt(row, {
  procedure,
  offered = null,
  priceStatus = '',
  failureReason = '',
  permanent = false,
  temporaryMs = 6 * 60 * 60 * 1000,
  verified = false,
} = {}) {
  const display = row.cityDisplay || row.city || '';
  const id = candidateDocId({
    city: display,
    placeId: row.placeId,
    website: row.website,
    name: row.name,
  });
  const fam = familyOf(procedure);
  const FieldValue = admin.firestore.FieldValue;
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const existing = snap.exists ? (snap.data() || {}) : {};
    const applied = applyFamilyVerificationState(existing, {
      fam,
      offered,
      priceStatus,
      verified,
    });
    const patch = {
      verificationAttempts: FieldValue.increment(1),
      lastAttemptedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      priceStatus: applied.priceStatus,
      procedureOffered: applied.procedureOffered,
      verifyLeaseUntil: 0,
    };
    if (failureReason) patch.lastFailureReason = String(failureReason);
    if (permanent && failureReason) {
      patch.permanentRejectReason = String(failureReason);
      patch.status = 'rejected';
    } else if (verified) {
      patch.lastVerifiedAt = FieldValue.serverTimestamp();
      patch.status = 'verified';
      patch.temporaryRetryAfter = 0;
    } else if (offered === true && priceStatus === 'no_public_price') {
      patch.status = 'offered_unpriced';
      patch.temporaryRetryAfter = noPublicPriceRetryAfter();
    } else if (offered === true && priceStatus === 'unresolved') {
      patch.status = 'offered_unpriced';
    } else if (failureReason && !permanent) {
      patch.temporaryRetryAfter = Date.now() + Number(temporaryMs || 0);
      patch.status = 'temp_fail';
    }
    if (procedure) {
      patch.discoveredProcedures = FieldValue.arrayUnion(String(procedure));
    }
    if (fam) patch.procedureFamilies = FieldValue.arrayUnion(fam);
    tx.set(ref, patch, {merge: true});
  });
}

async function claimCandidateForVerify(row, {leaseMs = VERIFY_LEASE_MS} = {}) {
  const display = row.cityDisplay || row.city || '';
  const id = candidateDocId({
    city: display,
    placeId: row.placeId,
    website: row.website,
    name: row.name,
  });
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  const FieldValue = admin.firestore.FieldValue;
  return admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? (snap.data() || {}) : {};
    const until = Number(data.verifyLeaseUntil || 0);
    if (until > Date.now()) return false;
    tx.set(ref, {
      verifyLeaseUntil: Date.now() + Number(leaseMs || VERIFY_LEASE_MS),
      lastAttemptedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    return true;
  });
}

async function persistCandidateIdentity(row, fields = {}) {
  const display = row.cityDisplay || row.city || '';
  const id = candidateDocId({
    city: display,
    placeId: row.placeId,
    website: row.website,
    name: row.name,
  });
  const website = String(fields.website || '').trim();
  const patch = {
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (website) {
    patch.website = website;
    patch.websiteHost = hostOf(website);
  }
  if (fields.placeId) patch.placeId = String(fields.placeId);
  if (fields.address) patch.address = String(fields.address);
  if (fields.lat) patch.lat = Number(fields.lat);
  if (fields.lng) patch.lng = Number(fields.lng);
  if (fields.rating) patch.rating = Number(fields.rating);
  if (fields.reviews) patch.reviews = Number(fields.reviews);
  await admin.firestore().collection(COLLECTION).doc(id).set(patch, {merge: true});
}

async function getCityCoverage(city, procedure, {cityId = ''} = {}) {
  const rows = await loadCandidatesForCity(city, {limit: 200, cityId});
  const fam = familyOf(procedure);
  const now = Date.now();
  let relevant = 0;
  let unverified = 0;
  let verified = 0;
  let poolVerified = 0;
  try {
    const {loadCached} = require('./firestoreStore');
    // loadCached already drops other-city / untrusted rows.
    const cached = await loadCached(city, procedure, {cityId});
    poolVerified = Array.isArray(cached) ? cached.length : 0;
  } catch (_) {
    poolVerified = 0;
  }
  const tallied = tallyProcedureFamilyCoverage(rows, fam, {now});
  relevant = tallied.relevant;
  unverified = tallied.unverified;
  verified = Math.max(tallied.familyVerified, poolVerified);
  const noPublicPriceCount = Number(tallied.noPublicPrice || 0);
  const candidateCount = rows.length;
  const verifiedVisibleCount = poolVerified;
  let discoveryStatus;
  if (isVerifiedPoolHealthy({
    verifiedVisibleCount,
    verifiedPriceCount: verified,
  })) {
    discoveryStatus = coverageLevel(candidateCount) === 'thin' ? 'partial' : 'healthy';
  } else if (verifiedVisibleCount > 0) {
    discoveryStatus = 'partial';
  } else {
    // Candidate healthy/broad must NOT mean verification complete.
    const level = coverageLevel(candidateCount);
    discoveryStatus = (level === 'healthy' || level === 'broad')
      ? 'partial'
      : level;
  }
  let verificationStatus = 'incomplete';
  if (verifiedVisibleCount >= 20) verificationStatus = 'healthy';
  else if (verifiedVisibleCount >= 4) verificationStatus = 'progressing';
  const coverage = {
    candidateCount,
    procedureRelevantCandidateCount: relevant,
    verifiedPriceCount: verified,
    verifiedVisibleCount,
    noPublicPriceCount,
    unverifiedCandidateCount: unverified,
    discoveryStatus,
    verificationStatus,
  };
  console.log(
      `[CANDIDATE POOL] ${cityDisplayName(city) || city} · ${procedure} · ` +
      `total=${candidateCount} verified=${verified} ` +
      `visible=${verifiedVisibleCount} pending=${unverified}`);
  return coverage;
}

module.exports = {
  COLLECTION,
  cityKey,
  normalizeName,
  candidateDocId,
  mergeCandidateRecord,
  prioritizePlaces,
  coverageLevel,
  verificationPriority,
  shouldExpandDiscovery,
  shouldContinueVerification,
  isVerifiedPoolHealthy,
  exploreVisibleTarget,
  legacyToCanonical,
  candidateToPlace,
  isRetryBlocked,
  discoveryUpsertFields,
  applyFamilyVerificationState,
  tallyProcedureFamilyCoverage,
  noPublicPriceRetryAfter,
  NO_PUBLIC_PRICE_RECHECK_MS,
  VERIFY_LEASE_MS,
  upsertCandidates,
  loadCandidatesForCity,
  loadCandidatesForProcedure,
  loadUnverifiedBatch,
  markCandidateAttempt,
  claimCandidateForVerify,
  persistCandidateIdentity,
  getCityCoverage,
};
