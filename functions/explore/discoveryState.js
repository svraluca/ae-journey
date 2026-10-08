'use strict';

const admin = require('firebase-admin');

const COLLECTION = 'explore_discovery_state';
const REVISION = 'v1';
const TEMP_COOLDOWN_MS = 6 * 60 * 60 * 1000;

function encodeDocId(raw) {
  const encoded = encodeURIComponent(raw).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

function docId(city, procedure, cityId = '') {
  const proc = String(procedure || '').trim().toLowerCase();
  const id = String(cityId || '').trim();
  if (id) {
    return encodeDocId(`${REVISION}|${id}|${proc}`);
  }
  const raw = `${REVISION}|${String(city).trim().toLowerCase()}|${proc}`;
  return encodeDocId(raw);
}

function emptyState() {
  return {
    acceptedPlaceIds: [],
    permanentRejectedPlaceIds: [],
    temporaryRejected: {},
  };
}

function parseDiscoveryState(data) {
  const temporaryRejected = data.temporaryRejected && typeof data.temporaryRejected === 'object'
    ? data.temporaryRejected : {};
  const now = Date.now();
  const liveTemp = {};
  for (const [placeId, row] of Object.entries(temporaryRejected)) {
    const retryAfter = Number(row && row.retryAfter || 0);
    if (retryAfter > now) liveTemp[placeId] = row;
  }
  return {
    acceptedPlaceIds: Array.isArray(data.acceptedPlaceIds) ? data.acceptedPlaceIds : [],
    permanentRejectedPlaceIds: Array.isArray(data.permanentRejectedPlaceIds)
      ? data.permanentRejectedPlaceIds : [],
    temporaryRejected: liveTemp,
  };
}

async function loadDiscoveryState(city, procedure, {cityId = ''} = {}) {
  const col = admin.firestore().collection(COLLECTION);
  const preferred = String(cityId || '').trim();
  if (preferred) {
    const snap = await col.doc(docId(city, procedure, preferred)).get();
    if (snap.exists) return parseDiscoveryState(snap.data() || {});
  }
  const legacy = await col.doc(docId(city, procedure)).get();
  if (!legacy.exists) return emptyState();
  return parseDiscoveryState(legacy.data() || {});
}

function isKnownPermanentReject(state, placeId) {
  const id = String(placeId || '').trim();
  if (!id) return false;
  return (state.permanentRejectedPlaceIds || []).includes(id);
}

function isAcceptedPlace(state, placeId) {
  const id = String(placeId || '').trim();
  if (!id) return false;
  return (state.acceptedPlaceIds || []).includes(id);
}

function isTemporarilyBlocked(state, placeId) {
  const id = String(placeId || '').trim();
  if (!id) return false;
  const row = (state.temporaryRejected || {})[id];
  if (!row) return false;
  return Number(row.retryAfter || 0) > Date.now();
}

async function patchDiscoveryState(city, procedure, mutate, {cityId = ''} = {}) {
  const id = docId(city, procedure, cityId);
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    let cur = snap.exists ? (snap.data() || {}) : {};
    // Seed from legacy city-name doc when migrating to cityId keys.
    if (!snap.exists && cityId) {
      const legacyRef = admin.firestore().collection(COLLECTION)
          .doc(docId(city, procedure));
      const legacySnap = await tx.get(legacyRef);
      if (legacySnap.exists) cur = legacySnap.data() || {};
    }
    const next = mutate({
      acceptedPlaceIds: Array.isArray(cur.acceptedPlaceIds) ? [...cur.acceptedPlaceIds] : [],
      permanentRejectedPlaceIds: Array.isArray(cur.permanentRejectedPlaceIds)
        ? [...cur.permanentRejectedPlaceIds] : [],
      temporaryRejected: {...(cur.temporaryRejected || {})},
    });
    tx.set(ref, {
      city,
      cityId: String(cityId || '').trim() || null,
      procedure,
      revision: REVISION,
      acceptedPlaceIds: [...new Set(next.acceptedPlaceIds)].slice(0, 200),
      permanentRejectedPlaceIds: [...new Set(next.permanentRejectedPlaceIds)].slice(0, 400),
      temporaryRejected: next.temporaryRejected,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  });
}

async function markAccepted(city, procedure, placeId, {cityId = ''} = {}) {
  const id = String(placeId || '').trim();
  if (!id) return;
  await patchDiscoveryState(city, procedure, (state) => {
    if (!state.acceptedPlaceIds.includes(id)) state.acceptedPlaceIds.push(id);
    delete state.temporaryRejected[id];
    return state;
  }, {cityId});
}

async function markPermanentReject(city, procedure, placeId, reason, {cityId = ''} = {}) {
  const id = String(placeId || '').trim();
  if (!id) return;
  await patchDiscoveryState(city, procedure, (state) => {
    if (!state.permanentRejectedPlaceIds.includes(id)) {
      state.permanentRejectedPlaceIds.push(id);
    }
    delete state.temporaryRejected[id];
    return state;
  }, {cityId});
  console.log(`[GP DISCOVERY] reject=${reason || 'permanent'} · placeId=${id} · name=`);
}

async function markTemporaryReject(
    city, procedure, placeId, reason, retryAfterMs = TEMP_COOLDOWN_MS,
    {cityId = ''} = {}) {
  const id = String(placeId || '').trim();
  if (!id) return;
  await patchDiscoveryState(city, procedure, (state) => {
    state.temporaryRejected[id] = {
      reason: String(reason || 'temporary_fetch_failure'),
      retryAfter: Date.now() + Number(retryAfterMs || TEMP_COOLDOWN_MS),
    };
    return state;
  }, {cityId});
}

/**
 * Place IDs Google Places discovery must not return.
 *
 * Accepted IDs are deliberately absent. A clinic accepted under an older
 * extraction revision comes back from Firestore as a price-0 identity stub, so
 * it has to stay discoverable to be re-verified; suppressing it here stranded
 * it permanently and left Explore showing a single card. Duplicates of a
 * *currently trusted* clinic are filtered per request instead, by the
 * host/name/placeId `seen` keys and excludeClinicKeys.
 */
function discoverySkipPlaceIds(state) {
  const s = state || {};
  const temporary = Object.keys(s.temporaryRejected || {})
      .filter((id) => isTemporarilyBlocked(s, id));
  return new Set([...(s.permanentRejectedPlaceIds || []), ...temporary]);
}

function isPermanentRejectReason(reason) {
  return [
    'marketplace_without_provider',
    'generic_business_name',
    'wrong_business_type',
    'duplicate_canonical_clinic',
    'invalid_identity',
  ].includes(String(reason || ''));
}

function isTemporaryFailureReason(reason) {
  const r = String(reason || '').toLowerCase();
  return r.includes('timeout') ||
      r.includes('5xx') ||
      r.includes('unavailable') ||
      r === 'temporary_fetch_failure' ||
      r === 'renderer_timeout' ||
      r === 'http_timeout';
}

module.exports = {
  docId,
  loadDiscoveryState,
  isKnownPermanentReject,
  isAcceptedPlace,
  isTemporarilyBlocked,
  discoverySkipPlaceIds,
  markAccepted,
  markPermanentReject,
  markTemporaryReject,
  isPermanentRejectReason,
  isTemporaryFailureReason,
  TEMP_COOLDOWN_MS,
};
