'use strict';

const admin = require('firebase-admin');
const {coverageLevel, verificationPriority, isVerifiedPoolHealthy,
  exploreVisibleTarget} =
    require('../clinicCandidateStore');
const crypto = require('crypto');
const {
  isResolvedCityId,
  coverageDocId,
} = require('../cityIdentity');

const COLLECTION = 'explore_city_discovery';
const COVERAGE_COLLECTION = 'explore_city_procedure_coverage';
const MIGRATION_QUEUE = 'explore_legacy_city_migration';
const USEFUL_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const THIN_RETRY_MS = 3 * 24 * 60 * 60 * 1000;
const TEMP_FAILURE_RETRY_MS = 30 * 60 * 1000;
const QUOTA_FAILURE_RETRY_MS = 6 * 60 * 60 * 1000;
const LEASE_TTL_MS = 45 * 60 * 1000;
const HEARTBEAT_STALE_MS = 12 * 60 * 1000;

/**
 * Coverage / discovery doc key. Requires resolved cityId — never name-only.
 */
function cityProcedureKey(city, procedure, cityId = '') {
  const id = String(cityId || '').trim();
  if (!isResolvedCityId(id)) {
    const proc = String(procedure || '').trim().toLowerCase();
    const digest = crypto.createHash('sha1')
        .update(`blocked|${city}|${proc}`)
        .digest('hex')
        .slice(0, 12);
    return `blocked_${digest}`;
  }
  return coverageDocId({cityId: id, procedure});
}

function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === 'function') return value.toDate();
  if (value instanceof Date) return value;
  const d = new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d;
}

function ref(city, procedure, cityId = '') {
  return admin.firestore()
      .collection(COLLECTION)
      .doc(cityProcedureKey(city, procedure, cityId));
}

function coverageRef(city, procedure, cityId = '') {
  return admin.firestore()
      .collection(COVERAGE_COLLECTION)
      .doc(cityProcedureKey(city, procedure, cityId));
}

function discoveryStatusOf(candidateCount) {
  return coverageLevel(candidateCount);
}

function verificationStatusOf(verifiedPriceCount, unverifiedCandidateCount) {
  if (verificationPriority(verifiedPriceCount) === 'maintenance') return 'healthy';
  if (Number(verifiedPriceCount || 0) >= 4) return 'progressing';
  if (Number(unverifiedCandidateCount || 0) > 0) return 'incomplete';
  return Number(verifiedPriceCount || 0) > 0 ? 'progressing' : 'incomplete';
}

function normalizeCoverageStatus(raw, {candidateCount, verifiedCount} = {}) {
  const s = String(raw || '').trim().toLowerCase();
  if (!s || s === 'unknown') return 'unknown';
  if (s === 'queued') return 'queued';
  if (s === 'running') return 'running';
  if (s === 'failed' || s === 'error') return 'failed';
  if (s === 'complete') return 'complete';
  // Candidate-pool labels (healthy/broad) are not verification complete.
  if (s === 'healthy' || s === 'broad') {
    const v = Number(verifiedCount);
    if (Number.isFinite(v) && v >= exploreVisibleTarget()) return 'complete';
    if (Number.isFinite(v) && v > 0) return 'partial';
    return 'partial';
  }
  if (s === 'thin' || s === 'empty') return 'thin';
  if (s === 'partial' || s === 'progressing') return 'partial';
  const n = Number(candidateCount);
  const v = Number(verifiedCount);
  if (Number.isFinite(v) && v >= exploreVisibleTarget()) return 'complete';
  if (Number.isFinite(n) && n > 0 && Number.isFinite(v) && v > 0) return 'partial';
  if (Number.isFinite(n) && n > 0) return 'partial';
  return 'unknown';
}

async function queueLegacyCityMigration({
  legacyDocId = '',
  legacyCity = '',
  resolvedCityId = '',
  reason = 'geo_unproven',
} = {}) {
  const id = encodeURIComponent(
      `${legacyDocId}|${resolvedCityId}|${reason}`).replace(/%/g, '_').slice(0, 400);
  await admin.firestore().collection(MIGRATION_QUEUE).doc(id).set({
    legacyDocId,
    legacyCity,
    resolvedCityId,
    reason,
    status: 'open',
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  return id;
}

async function shouldRunDiscovery(city, procedure, coverage = {}, cityId = '') {
  if (!isResolvedCityId(cityId)) {
    return {start: false, reason: 'city_unresolved', needsLocationResolution: true};
  }
  const hasCount = coverage.candidateCount != null;
  const candidateCount = hasCount ? Number(coverage.candidateCount) : null;
  const verifiedN = Number(
      coverage.verifiedVisibleCount != null
        ? coverage.verifiedVisibleCount
        : coverage.verifiedPriceCount);

  // Healthy only when post-validation verified cards hit the visible target.
  if (isVerifiedPoolHealthy(coverage)) {
    return {start: false, reason: 'pool_healthy', coverage};
  }

  const snap = await ref(city, procedure, cityId).get();
  // Legacy verified rows exist but coverage doc missing → not unknown forever.
  if (!snap.exists) {
    if (Number.isFinite(verifiedN) && verifiedN > 0) {
      return {start: true, reason: 'partial_verified_no_coverage_doc'};
    }
    return {start: true, reason: 'unknown_coverage'};
  }
  const state = snap.data() || {};
  const status = normalizeCoverageStatus(state.status || state.discoveryStatus, {
    candidateCount: state.candidateCount,
    verifiedCount: state.verifiedCount || state.verifiedPriceCount || verifiedN,
  });

  const lease = await readLease(city, procedure, cityId);
  if (lease && lease.active) {
    return {
      start: false,
      reason: 'lease_held',
      state,
      jobId: lease.jobId,
    };
  }

  if (status === 'running') {
    const started = toDate(state.lastStartedAt || state.lastRunAt);
    if (started && Date.now() - started.getTime() < LEASE_TTL_MS) {
      return {start: false, reason: 'already_running', state};
    }
    return {start: true, reason: 'stale_running', state};
  }

  const storedCount = Number(
      hasCount ? candidateCount : (state.candidateCount || 0));
  const discoveryStatus = normalizeCoverageStatus(
      state.discoveryStatus || discoveryStatusOf(storedCount),
      {
        candidateCount: storedCount,
        verifiedCount: state.verifiedPriceCount || verifiedN,
      });
  const completed = toDate(state.lastRunAt || state.lastCompletedAt);
  const nextRetry = toDate(state.nextRetryAt);

  if (nextRetry && Date.now() < nextRetry.getTime()) {
    return {start: false, reason: 'retry_backoff', state};
  }

  // TTL freshness applies only when verified target is already met.
  if (isVerifiedPoolHealthy({
    verifiedPriceCount: state.verifiedPriceCount || verifiedN,
  }) &&
      discoveryStatus !== 'thin' && storedCount >= 15 && completed &&
      Date.now() - completed.getTime() < USEFUL_TTL_MS) {
    return {start: false, reason: 'ttl_fresh', state};
  }
  // Below visible target (including verifiedN==0) always retries.
  const belowVisibleTarget = Number.isFinite(verifiedN) &&
      verifiedN < exploreVisibleTarget();
  if (discoveryStatus === 'thin' && completed &&
      Date.now() - completed.getTime() < THIN_RETRY_MS &&
      !belowVisibleTarget) {
    return {start: false, reason: 'thin_cooldown', state};
  }
  if (status === 'failed' && state.failureType === 'quota' && completed &&
      Date.now() - completed.getTime() < QUOTA_FAILURE_RETRY_MS) {
    return {start: false, reason: 'quota_backoff', state};
  }
  return {start: true, reason: status || 'retry', state};
}

async function acquireDiscoveryLease(city, procedure, {
  cityId = '',
  owner = '',
  ttlMs = LEASE_TTL_MS,
} = {}) {
  if (!isResolvedCityId(cityId)) {
    return {
      acquired: false,
      reused: false,
      reason: 'city_unresolved',
      needsLocationResolution: true,
    };
  }
  const db = admin.firestore();
  const docRef = ref(city, procedure, cityId);
  const now = Date.now();
  const jobId = crypto.randomBytes(8).toString('hex');
  const leaseOwner = String(owner || `fn_${jobId}`).slice(0, 80);

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(docRef);
    const data = snap.exists ? (snap.data() || {}) : {};
    const expiresAt = Number(data.leaseExpiresAt || 0);
    const heartbeatAt = Number(data.heartbeatAt || 0);
    const held = data.status === 'running' &&
        expiresAt > now &&
        (heartbeatAt <= 0 || now - heartbeatAt < HEARTBEAT_STALE_MS);

    if (held && data.jobId) {
      return {
        acquired: false,
        reused: true,
        jobId: String(data.jobId),
        leaseOwner: String(data.leaseOwner || ''),
        leaseExpiresAt: expiresAt,
        status: 'running',
      };
    }

    const patch = {
      city,
      cityId,
      procedure,
      status: 'running',
      discoveryStatus: 'running',
      jobId,
      leaseOwner,
      leaseExpiresAt: now + ttlMs,
      heartbeatAt: now,
      lastStartedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastRunAt: admin.firestore.FieldValue.serverTimestamp(),
      failureType: null,
      failureReason: null,
    };
    tx.set(docRef, patch, {merge: true});
    return {
      acquired: true,
      reused: false,
      jobId,
      leaseOwner,
      leaseExpiresAt: now + ttlMs,
      status: 'running',
    };
  });
}

async function heartbeatDiscoveryLease(city, procedure, {
  cityId = '',
  jobId = '',
  ttlMs = LEASE_TTL_MS,
} = {}) {
  if (!isResolvedCityId(cityId)) return;
  const now = Date.now();
  await ref(city, procedure, cityId).set({
    heartbeatAt: now,
    leaseExpiresAt: now + ttlMs,
    jobId: jobId || undefined,
    status: 'running',
  }, {merge: true});
}

async function releaseDiscoveryLease(city, procedure, {
  cityId = '',
  jobId = '',
} = {}) {
  if (!isResolvedCityId(cityId)) return;
  const docRef = ref(city, procedure, cityId);
  const snap = await docRef.get();
  if (!snap.exists) return;
  const data = snap.data() || {};
  if (jobId && data.jobId && data.jobId !== jobId) return;
  await docRef.set({
    leaseExpiresAt: 0,
    heartbeatAt: 0,
  }, {merge: true});
}

async function readLease(city, procedure, cityId = '') {
  if (!isResolvedCityId(cityId)) return null;
  const snap = await ref(city, procedure, cityId).get();
  if (!snap.exists) return null;
  const data = snap.data() || {};
  const now = Date.now();
  const expiresAt = Number(data.leaseExpiresAt || 0);
  const heartbeatAt = Number(data.heartbeatAt || 0);
  const active = data.status === 'running' &&
      expiresAt > now &&
      (heartbeatAt <= 0 || now - heartbeatAt < HEARTBEAT_STALE_MS);
  return {
    active,
    jobId: data.jobId || '',
    leaseOwner: data.leaseOwner || '',
    leaseExpiresAt: expiresAt,
    heartbeatAt,
    status: data.status || '',
  };
}

async function markDiscoveryRunning(city, procedure, {
  cityId = '',
  jobId = '',
  leaseOwner = '',
} = {}) {
  if (!isResolvedCityId(cityId)) return;
  const now = Date.now();
  await ref(city, procedure, cityId).set({
    city,
    cityId,
    procedure,
    status: 'running',
    discoveryStatus: 'running',
    provider: 'brightdata',
    jobId: jobId || undefined,
    leaseOwner: leaseOwner || undefined,
    leaseExpiresAt: now + LEASE_TTL_MS,
    heartbeatAt: now,
    lastStartedAt: admin.firestore.FieldValue.serverTimestamp(),
    lastRunAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  await upsertCoverageDoc(city, procedure, {
    cityId,
    status: 'running',
    jobId,
  });
}

async function upsertCoverageDoc(city, procedure, {
  cityId = '',
  status = '',
  candidateCount,
  verifiedCount,
  rejectedCount,
  providersAttempted,
  jobId = '',
  failureType = null,
  failureReason = null,
  nextRetryAt = null,
} = {}) {
  if (!isResolvedCityId(cityId)) return;
  const patch = {
    cityId,
    city,
    procedureCanonicalId: String(procedure || '').trim().toLowerCase(),
    procedure,
    lastDiscoveryAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (status) patch.status = status;
  if (candidateCount != null) patch.candidateCount = Number(candidateCount);
  if (verifiedCount != null) {
    patch.verifiedCount = Number(verifiedCount);
    if (Number(verifiedCount) > 0) {
      patch.lastSuccessfulVerificationAt =
          admin.firestore.FieldValue.serverTimestamp();
    }
  }
  if (rejectedCount != null) patch.rejectedCount = Number(rejectedCount);
  if (Array.isArray(providersAttempted)) {
    patch.providersAttempted = providersAttempted;
  }
  if (jobId) patch.jobId = jobId;
  if (failureType != null) patch.failureType = failureType;
  if (failureReason != null) patch.failureReason = failureReason;
  if (nextRetryAt != null) patch.nextRetryAt = nextRetryAt;
  await coverageRef(city, procedure, cityId).set(patch, {merge: true});
}

async function markDiscoveryFinished(city, procedure, {
  cityId = '',
  jobId = '',
  candidateCount = 0,
  verifiedPriceCount = 0,
  unverifiedCandidateCount = 0,
  procedureRelevantCandidateCount = 0,
  discoveryStatus = '',
  verificationStatus = '',
  failureType = null,
  failureReason = null,
  technicalFailure = false,
} = {}) {
  if (!isResolvedCityId(cityId)) return 'failed';
  const disc = discoveryStatus || discoveryStatusOf(candidateCount);
  const ver = verificationStatus ||
      verificationStatusOf(verifiedPriceCount, unverifiedCandidateCount);

  let status = 'complete';
  let nextRetryMs = null;
  const visibleTarget = exploreVisibleTarget();
  const verifiedVisible = Number(
      verifiedPriceCount != null ? verifiedPriceCount : 0);
  if (technicalFailure || failureType) {
    status = 'failed';
    const ft = failureType || 'temporary';
    nextRetryMs = ft === 'quota' ? QUOTA_FAILURE_RETRY_MS : TEMP_FAILURE_RETRY_MS;
  } else if (disc === 'thin' && candidateCount <= 0 && verifiedVisible <= 0) {
    status = 'thin';
    nextRetryMs = THIN_RETRY_MS;
  } else if (verifiedVisible <= 0) {
    // Raw candidates alone never mean complete.
    status = candidateCount > 0 ? 'partial' : 'thin';
    if (status === 'thin') nextRetryMs = THIN_RETRY_MS;
  } else if (disc === 'thin' ||
      (verifiedVisible > 0 && verifiedVisible < visibleTarget)) {
    status = 'partial';
  } else if (verifiedVisible >= visibleTarget) {
    status = 'complete';
  }

  const nextRetryAt = nextRetryMs != null
    ? new Date(Date.now() + nextRetryMs)
    : null;

  await ref(city, procedure, cityId).set({
    city,
    cityId,
    procedure,
    status,
    discoveryStatus: disc,
    verificationStatus: ver,
    provider: 'brightdata',
    candidateCount,
    verifiedCount: verifiedPriceCount,
    verifiedPriceCount,
    unverifiedCandidateCount,
    procedureRelevantCandidateCount,
    failureType: failureType || null,
    failureReason: failureReason || null,
    nextRetryAt: nextRetryAt,
    leaseExpiresAt: 0,
    heartbeatAt: 0,
    jobId: jobId || undefined,
    lastRunAt: admin.firestore.FieldValue.serverTimestamp(),
    lastCompletedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});

  await upsertCoverageDoc(city, procedure, {
    cityId,
    status,
    candidateCount,
    verifiedCount: verifiedPriceCount,
    jobId,
    failureType: failureType || null,
    failureReason: failureReason || null,
    nextRetryAt,
  });
  return status;
}

module.exports = {
  COLLECTION,
  COVERAGE_COLLECTION,
  MIGRATION_QUEUE,
  LEASE_TTL_MS,
  cityProcedureKey,
  shouldRunDiscovery,
  markDiscoveryRunning,
  markDiscoveryFinished,
  acquireDiscoveryLease,
  heartbeatDiscoveryLease,
  releaseDiscoveryLease,
  readLease,
  upsertCoverageDoc,
  queueLegacyCityMigration,
  normalizeCoverageStatus,
  discoveryStatusOf,
  verificationStatusOf,
};
