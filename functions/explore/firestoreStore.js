'use strict';

const admin = require('firebase-admin');
const {
  clinicIdentityRejectReason,
  clinicMergeKey,
  mergeClinicRecords,
} = require('./identity');
const {stripInvalidCachedPrice} = require('./priceSanity');
const {evaluatePriceTrust} = require('./trustRules');
const {EXTRACT_REVISION} = require('./clinicCatalog');
const {classifyProcedureRelation} = require('./procedureRelation');
const {exploreUrlConflictsWithSearchCity} = require('./cityIdentity');

const COLLECTION = 'explore_google_prices';
const REVISION = 'v14';
const PREV_REVISION = 'v13';
const PRICE_TTL_MS = 14 * 24 * 60 * 60 * 1000;
const MAX_CLINICS = 30;

function encodeDocId(raw) {
  const encoded = encodeURIComponent(raw).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

function docId(city, procedure, revision = REVISION) {
  const raw = `${revision}|${String(city).trim().toLowerCase()}|${String(procedure).trim().toLowerCase()}`;
  return encodeDocId(raw);
}

/** Prefer cityId when present: `v13|{cityId}|{procedure}`. */
function docIdWithLocality({city, cityId, procedure} = {}) {
  const proc = String(procedure || '').trim().toLowerCase();
  const id = String(cityId || '').trim();
  if (id) {
    return encodeDocId(`${REVISION}|${id}|${proc}`);
  }
  return docId(city, procedure);
}

/** Ordered read candidates: cityId doc → current city name → previous revision. */
function docIdReadCandidates({city, cityId, procedure} = {}) {
  const out = [];
  const add = (id) => {
    if (id && !out.includes(id)) out.push(id);
  };
  add(docIdWithLocality({city, cityId, procedure}));
  if (cityId) add(docId(city, procedure));
  add(docId(city, procedure, PREV_REVISION));
  return out;
}

async function readFirstExistingDoc({city, cityId, procedure}) {
  const col = admin.firestore().collection(COLLECTION);
  for (const id of docIdReadCandidates({city, cityId, procedure})) {
    const snap = await col.doc(id).get();
    if (snap.exists) return {id, snap, data: snap.data() || {}};
  }
  return null;
}

function isTrustedPrice(row) {
  return evaluatePriceTrust(row).trusted;
}

function isIdentityReverifyStub(row) {
  if (!row) return false;
  const status = String(row.price_verification_status || '').toLowerCase();
  if (status === 'legacy_untrusted' ||
      status === 'legacy_unverified' ||
      row.needs_reverification === true) {
    const name = String(row.name || row.clinicName || '').trim();
    const placeId = String(row.place_id || row.placeId || '').trim();
    const website = String(row.website || '').trim();
    return !!name && (!!placeId || !!website);
  }
  return false;
}

function toReverifyIdentityStub(row, reason) {
  return {
    ...row,
    price_min: 0,
    price_max: 0,
    priceMin: 0,
    priceMax: 0,
    price_gbp: 0,
    price_label: '',
    priceLabel: '',
    price_verified: false,
    priceVerified: false,
    verified: false,
    needs_reverification: true,
    price_verification_status: 'legacy_unverified',
    price_rejection_reason: String(reason || 'needs_reverification'),
  };
}

function sanitizeVerifiedPoolRow(row, procedure = '', {city = ''} = {}) {
  if (!row || typeof row !== 'object') return row;
  const proc = String(procedure || '').trim();
  let next = {...row};
  let rev = String(next.price_extract_revision || next.extractRevision || '').trim();
  // Deterministic e17 → e18 when locked evidence is complete.
  if (rev === 'e17') {
    const rawPrice = String(next.raw_price_text || next.rawPriceText ||
        next.price_label || '').trim();
    const rawProc = String(next.raw_procedure_text || next.rawProcedureText ||
        next.brand || '').trim();
    const sourceUrl = String(next.price_source_url || next.sourceUrl || '').trim();
    const method = String(next.extraction_method || next.extractionMethod || '').trim();
    const currency = String(next.currency || '').trim();
    const evidence = String(next.price_evidence_text || next.rawEvidence || '').trim();
    const hash = String(next.evidence_hash || next.evidenceHash || '').trim();
    if (rawPrice && rawProc && sourceUrl && method && currency &&
        (evidence || hash)) {
      const searchCity = String(city || next.source_city || next.sourceCity ||
          next.city || '').trim();
      if (searchCity && sourceUrl &&
          exploreUrlConflictsWithSearchCity(sourceUrl, searchCity)) {
        return toReverifyIdentityStub(next, 'other_city_source_url');
      }
      const blob = `${rawPrice} ${evidence} ${rawProc}`.toLowerCase();
      const perUnit = /(?:per|\/)\s*(?:ml|cc|iu|unit|units|syringe)/i.test(blob);
      const from = /\b(?:from|starting\s+from|de la|desde|a partir)\b/i.test(blob);
      const range = /\d[\d.,]*\s*[–\-—]\s*\d/.test(blob);
      let priceType = 'fixed';
      if (perUnit) priceType = 'perUnit';
      else if (from) priceType = 'from';
      else if (range) priceType = 'range';
      next = {
        ...next,
        price_type: priceType,
        priceType,
        price_extract_revision: EXTRACT_REVISION,
        extractRevision: EXTRACT_REVISION,
        needs_revalidation: false,
      };
      if (!perUnit && /^(?:ml|cc)$/i.test(String(next.price_unit || next.unit || ''))) {
        next.price_unit = '';
        next.unit = '';
      }
      rev = EXTRACT_REVISION;
    }
  }
  if (rev !== EXTRACT_REVISION) {
    return toReverifyIdentityStub(next, 'stale_extract_revision');
  }
  const min = Number(next.price_min || next.priceMin || 0);
  if (min > 0 && !String(next.currency || '').trim()) {
    return toReverifyIdentityStub(next, 'missing_currency');
  }
  const label = String(
      next.raw_procedure_text || next.rawProcedureText || next.brand || '');
  const evidence = String(
      next.price_evidence_text || next.rawEvidence ||
      next.raw_price_text || next.rawPriceText || '');
  const sourceUrl = String(next.price_source_url || next.sourceUrl || '');
  const searchCity = String(city || next.source_city || next.sourceCity ||
      next.city || '').trim();
  if (searchCity && sourceUrl &&
      exploreUrlConflictsWithSearchCity(sourceUrl, searchCity)) {
    return toReverifyIdentityStub(next, 'other_city_source_url');
  }
  const classified = classifyProcedureRelation({
    requestedProcedure: proc || label,
    label,
    evidence,
    sourceUrl,
    clinicOwnQuoted: true,
  });
  if (!classified.eligible) {
    return toReverifyIdentityStub(
        next, `ineligible_procedure_relation_${classified.logToken}`);
  }
  const canonical = {
    ...next,
    procedure_relation: classified.logToken,
    procedureRelation: classified.logToken,
  };
  const stripped = stripInvalidCachedPrice(
      canonical, proc || label, {logRejects: false});
  const trust = evaluatePriceTrust(stripped);
  if (!trust.trusted) {
    return toReverifyIdentityStub(stripped, trust.reason || 'untrusted');
  }
  return stripped;
}

function toLegacyUnverified(row) {
  if (isTrustedPrice(row)) return row;
  if (!(Number(row.price_min || 0) > 0)) return row;
  return {
    ...row,
    price_verification_status: 'legacy_unverified',
    price_verified: false,
    verified: false,
  };
}

function mergeVerifiedPool(existing, incoming, procedure = '', city = '') {
  const byKey = new Map();
  const stubs = [];
  for (const row of existing || []) {
    const cleaned = sanitizeVerifiedPoolRow(
        toLegacyUnverified({...row}), procedure, {city});
    const k = clinicMergeKey(cleaned);
    if (usablePoolRow(cleaned, procedure, city)) {
      if (k) byKey.set(k, cleaned);
      continue;
    }
    if (isIdentityReverifyStub(cleaned)) {
      if (k) byKey.set(k, cleaned);
      else stubs.push(cleaned);
    }
  }
  const beforeCount = [...byKey.values()]
      .filter((r) => usablePoolRow(r, procedure, city)).length;
  for (const c of incoming || []) {
    const sanitized = sanitizeVerifiedPoolRow(c, procedure, {city});
    const k = clinicMergeKey(sanitized);
    if (!k) continue;
    const prev = byKey.get(k) || {};
    byKey.set(k, mergeClinicRecords(prev, sanitized));
  }
  const trusted = [...byKey.values()].filter((r) => usablePoolRow(r, procedure, city));
  const remainingStubs = [...byKey.values()]
      .filter((r) => !usablePoolRow(r, procedure, city) && isIdentityReverifyStub(r))
      .concat(stubs);
  const merged = [
    ...trusted.slice(0, MAX_CLINICS),
    ...remainingStubs.slice(0, Math.max(0, MAX_CLINICS - trusted.length)),
  ];
  return {merged, trusted, beforeCount, afterCount: trusted.length};
}

function usablePoolRow(row, procedure = '', city = '') {
  const cleaned = sanitizeVerifiedPoolRow(
      toLegacyUnverified({...row}), procedure, {city});
  if (clinicIdentityRejectReason(cleaned.name || cleaned.clinicName || '')) {
    return false;
  }
  return isTrustedPrice(cleaned);
}

async function loadCached(city, procedure, {cityId = ''} = {}) {
  const found = await readFirstExistingDoc({city, cityId, procedure});
  if (!found) return [];
  const {id, data} = found;
  const cachedAt = data.cachedAt && data.cachedAt.toDate ? data.cachedAt.toDate() : null;
  const raw = Array.isArray(data.clinics) ? data.clinics : [];
  const now = Date.now();
  const expired = cachedAt && (now - cachedAt.getTime()) > PRICE_TTL_MS;
  const usable = [];
  let cleanupDirty = false;
  for (const row of raw) {
    const next = sanitizeVerifiedPoolRow(
        toLegacyUnverified({...row}), procedure, {city});
    if (String(next.price_verification_status || '') === 'legacy_untrusted') {
      cleanupDirty = true;
      continue;
    }
    if (expired && isTrustedPrice(next)) {
      cleanupDirty = true;
      continue;
    }
    if (!usablePoolRow(next, procedure, city)) {
      cleanupDirty = true;
      continue;
    }
    usable.push(next);
  }
  if (cleanupDirty && usable.length !== raw.length) {
    console.log(`[FIRESTORE] cleanupDirty ${raw.length - usable.length} dead rows · ${city} · ${procedure}`);
    // Persist purge so other-city rows cannot resurrect after restart.
    try {
      await admin.firestore().collection(COLLECTION).doc(id).set({
        clinics: usable.slice(0, MAX_CLINICS),
        clinicCount: usable.length,
        cleanupDirty: false,
        purgedOtherCity: true,
        cachedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, {merge: true});
    } catch (_) {
      // non-fatal
    }
  }
  return usable;
}

/**
 * Identity stubs with legacy_untrusted / needs_reverification for priority re-verify.
 * Never returned as pool prices.
 */
async function loadReverifyCandidates(city, procedure, {cityId = ''} = {}) {
  const found = await readFirstExistingDoc({city, cityId, procedure});
  if (!found) return [];
  const raw = Array.isArray(found.data.clinics) ? found.data.clinics : [];
  return raw
      .map((row) => sanitizeVerifiedPoolRow(row, procedure, {city}))
      .filter(isIdentityReverifyStub)
      .map((row) => ({
        name: String(row.name || row.clinicName || '').trim(),
        placeId: String(row.place_id || row.placeId || '').trim(),
        website: String(row.website || '').trim(),
        address: String(row.address || '').trim(),
        lat: Number(row.lat || 0),
        lng: Number(row.lng || 0),
        rating: Number(row.rating || 0),
        reviews: Number(row.reviews || 0),
        discovery_provider: row.discovery_provider || row.discoveryProvider || 'reverify',
        needs_reverification: true,
      }));
}

async function upsertVerified(city, procedure, clinics, {cityId = ''} = {}) {
  const incoming = (clinics || []).filter((c) => {
    if (clinicIdentityRejectReason(c.name || c.clinicName || '')) return false;
    if (Number(c.price_min || 0) > 0) return usablePoolRow(c, procedure, city);
    return false;
  });
  if (!incoming.length) return;

  const id = docIdWithLocality({city, cityId, procedure});
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  let seedExisting = [];
  const legacy = await readFirstExistingDoc({city, cityId, procedure});
  if (legacy && legacy.id !== id && Array.isArray(legacy.data.clinics)) {
    seedExisting = legacy.data.clinics;
  }
  let beforeCount = 0;
  let afterCount = 0;
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    let existing = snap.exists && Array.isArray(snap.data().clinics)
      ? snap.data().clinics : [];
    if (!existing.length && seedExisting.length) {
      existing = seedExisting;
    }
    const {merged, beforeCount: b, afterCount: a} =
        mergeVerifiedPool(existing, incoming, procedure, city);
    beforeCount = b;
    afterCount = a;
    tx.set(ref, {
      city,
      cityId: String(cityId || '').trim() || null,
      procedure,
      revision: REVISION,
      clinics: merged,
      cachedAt: admin.firestore.FieldValue.serverTimestamp(),
      cleanupDirty: false,
    }, {merge: true});
  });
  if (afterCount !== beforeCount) {
    console.log(`[POOL GROW] ${beforeCount} → ${afterCount}`);
  }
  console.log(`[FIRESTORE] saved ${incoming.length} · ${city} · ${procedure}`);
  return {beforeCount, afterCount};
}

module.exports = {
  docId,
  docIdWithLocality,
  docIdReadCandidates,
  isTrustedPrice,
  loadCached,
  loadReverifyCandidates,
  upsertVerified,
  REVISION,
  PREV_REVISION,
  MAX_CLINICS,
  usablePoolRow,
  isIdentityReverifyStub,
  mergeVerifiedPool,
  sanitizeVerifiedPoolRow,
  toReverifyIdentityStub,
};
