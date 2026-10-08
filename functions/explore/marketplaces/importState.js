'use strict';

const admin = require('firebase-admin');
const {
  IMPORT_COLLECTION,
  FRESHA_IMPORT_TTL_DAYS,
  FRESHA_EMPTY_COOLDOWN_MS,
  PROVIDER_FRESHA,
} = require('./constants');
const {importCityKey, countryCodeForCity, cityDisplayName} = require('./locationFormat');

function importRef(city) {
  return admin.firestore().collection(IMPORT_COLLECTION).doc(importCityKey(city));
}

function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === 'function') return value.toDate();
  if (value instanceof Date) return value;
  const n = Number(value);
  if (Number.isFinite(n) && n > 0) return new Date(n);
  const d = new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d;
}

function hasUsefulImport(state) {
  const prices = Number((state && state.pricesImported) || 0);
  const clinics = Number((state && state.clinicsImported) || 0);
  return prices > 0 && clinics > 0;
}

function withinCooldown(state, ms) {
  const completed = toDate(state && state.lastCompletedAt);
  if (!completed) return false;
  return Date.now() - completed.getTime() < ms;
}

/**
 * Decide whether a Fresha city import should start.
 * Never starts a duplicate while status=running.
 * 7-day TTL only after a useful complete (clinics>0 AND prices>0).
 * empty/partial → short cooldown (~30m).
 */
async function shouldStartImport(city) {
  const snap = await importRef(city).get();
  if (!snap.exists) {
    return {start: true, reason: 'missing', state: null};
  }
  const state = snap.data() || {};
  const status = String(state.status || 'idle');

  if (status === 'running') {
    const started = toDate(state.lastStartedAt);
    if (started && Date.now() - started.getTime() < 45 * 60 * 1000) {
      return {start: false, reason: 'already_running', state};
    }
    return {start: true, reason: 'stale_running', state};
  }

  if (status === 'complete') {
    if (!hasUsefulImport(state)) {
      // Legacy bug: complete with 0 useful results — allow retry soon.
      if (withinCooldown(state, FRESHA_EMPTY_COOLDOWN_MS)) {
        return {start: false, reason: 'empty_cooldown', state};
      }
      return {start: true, reason: 'complete_but_empty', state};
    }
    const ttlMs = FRESHA_IMPORT_TTL_DAYS * 24 * 60 * 60 * 1000;
    if (withinCooldown(state, ttlMs)) {
      return {start: false, reason: 'ttl_fresh', state};
    }
    return {start: true, reason: 'ttl_expired', state};
  }

  if (status === 'empty' || status === 'partial') {
    if (withinCooldown(state, FRESHA_EMPTY_COOLDOWN_MS)) {
      return {start: false, reason: `${status}_cooldown`, state};
    }
    return {start: true, reason: `${status}_retry`, state};
  }

  // failed / idle → allow
  return {start: true, reason: status || 'idle', state};
}

async function markImportRunning(city, {revision = 1} = {}) {
  const name = cityDisplayName(city);
  const countryCode = countryCodeForCity(city);
  const ref = importRef(city);
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const prev = snap.exists ? (snap.data() || {}) : {};
    if (String(prev.status || '') === 'running') {
      const started = toDate(prev.lastStartedAt);
      if (started && Date.now() - started.getTime() < 45 * 60 * 1000) {
        const err = new Error('already_running');
        err.code = 'already_running';
        throw err;
      }
    }
    tx.set(ref, {
      city: name,
      countryCode,
      status: 'running',
      provider: PROVIDER_FRESHA,
      lastStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastCompletedAt: prev.lastCompletedAt || null,
      venuesImported: 0,
      servicesImported: 0,
      pricesImported: 0,
      clinicsImported: 0,
      error: '',
      revision: Number(prev.revision || 0) + Number(revision || 1),
    }, {merge: true});
  });
}

/**
 * Mark finished. Only status=complete when clinics AND prices > 0.
 * Otherwise empty / partial (short cooldown, not 7-day TTL).
 */
async function markImportFinished(city, {
  venuesImported = 0,
  servicesImported = 0,
  pricesImported = 0,
  clinicsImported = 0,
} = {}) {
  let status = 'complete';
  if (clinicsImported <= 0 || pricesImported <= 0) {
    status = (venuesImported > 0 || servicesImported > 0) ? 'partial' : 'empty';
  }
  await importRef(city).set({
    city: cityDisplayName(city),
    countryCode: countryCodeForCity(city),
    status,
    provider: PROVIDER_FRESHA,
    lastCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
    venuesImported,
    servicesImported,
    pricesImported,
    clinicsImported,
    error: '',
  }, {merge: true});
  return status;
}

/** @deprecated Use markImportFinished */
async function markImportComplete(city, stats) {
  return markImportFinished(city, stats);
}

async function markImportFailed(city, error) {
  const msg = String((error && error.message) || error || 'unknown').slice(0, 500);
  await importRef(city).set({
    city: cityDisplayName(city),
    countryCode: countryCodeForCity(city),
    status: 'failed',
    provider: PROVIDER_FRESHA,
    lastCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
    error: msg,
  }, {merge: true});
}

module.exports = {
  importRef,
  shouldStartImport,
  markImportRunning,
  markImportFinished,
  markImportComplete,
  markImportFailed,
  hasUsefulImport,
  toDate,
};
