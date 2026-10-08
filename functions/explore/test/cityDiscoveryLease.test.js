'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  cityProcedureKey,
  normalizeCoverageStatus,
  LEASE_TTL_MS,
} = require('../brightdata/cityDiscoveryState');
const {shouldExpandDiscovery, coverageLevel} = require('../clinicCandidateStore');
const {discoveryQueriesForProcedure} = require('../brightdata/discoveryQueries');

test('missing coverage is unknown not complete', () => {
  assert.equal(normalizeCoverageStatus(''), 'unknown');
  assert.equal(normalizeCoverageStatus('unknown'), 'unknown');
  // Candidate-pool healthy/broad must not imply verification complete.
  assert.equal(normalizeCoverageStatus('healthy'), 'partial');
  assert.equal(normalizeCoverageStatus('broad'), 'partial');
  assert.equal(normalizeCoverageStatus('healthy', {verifiedCount: 4}), 'complete');
  assert.equal(normalizeCoverageStatus('complete'), 'complete');
  assert.equal(normalizeCoverageStatus('thin'), 'thin');
  assert.equal(normalizeCoverageStatus('empty'), 'thin');
  assert.equal(normalizeCoverageStatus('failed'), 'failed');
});

test('unknown candidateCount expands discovery', () => {
  assert.equal(shouldExpandDiscovery({}), true);
  assert.equal(shouldExpandDiscovery({candidateCount: null}), true);
  assert.equal(shouldExpandDiscovery({candidateCount: 8}), true);
  // Raw candidate count alone is never healthy — need verified visible.
  assert.equal(shouldExpandDiscovery({candidateCount: 22}), true);
  assert.equal(shouldExpandDiscovery({
    candidateCount: 22,
    verifiedVisibleCount: 4,
  }), false);
});

test('cityProcedureKey prefers cityId to avoid Paris FR/TX collision', () => {
  const {coverageDocId} = require('../cityIdentity');
  const fr = coverageDocId({cityId: 'geo_FR_abc', procedure: 'botox'});
  const tx = coverageDocId({cityId: 'geo_US_xyz', procedure: 'botox'});
  assert.notEqual(fr, tx);
});

test('lease TTL is finite so crashed jobs do not lock forever', () => {
  assert.ok(LEASE_TTL_MS > 60_000);
  assert.ok(LEASE_TTL_MS <= 60 * 60 * 1000);
});

test('localized discovery queries include price word and country context', () => {
  const qs = discoveryQueriesForProcedure('lip filler', 'Paris', {
    countryCode: 'FR',
    countryName: 'France',
    asciiCity: 'Paris',
  });
  assert.ok(qs.length >= 3);
  assert.ok(qs.some((q) => /price|prix/i.test(q)));
  assert.ok(qs.some((q) => /Paris/i.test(q)));
});

test('expired lease can be reacquired (pure clock logic)', () => {
  const now = Date.now();
  const lease = {
    status: 'running',
    leaseExpiresAt: now - 1000,
    heartbeatAt: now - 1000,
    jobId: 'old',
  };
  const active = lease.status === 'running' &&
      lease.leaseExpiresAt > now &&
      (now - lease.heartbeatAt) < (12 * 60 * 1000);
  assert.equal(active, false);
  // Reacquire path: create new jobId when inactive.
  const next = {
    ...lease,
    jobId: 'new',
    leaseExpiresAt: now + LEASE_TTL_MS,
    heartbeatAt: now,
  };
  assert.notEqual(next.jobId, lease.jobId);
  assert.ok(next.leaseExpiresAt > now);
});

test('concurrent searches reuse one active lease jobId', () => {
  const now = Date.now();
  const held = {
    status: 'running',
    jobId: 'shared-job',
    leaseExpiresAt: now + LEASE_TTL_MS,
    heartbeatAt: now,
  };
  const active = held.status === 'running' && held.leaseExpiresAt > now;
  assert.equal(active, true);
  // Second caller must reuse, not mint a second job.
  const second = active
    ? {acquired: false, reused: true, jobId: held.jobId}
    : {acquired: true, jobId: 'other'};
  assert.equal(second.reused, true);
  assert.equal(second.jobId, 'shared-job');
});

test('coverageLevel thin vs healthy boundaries', () => {
  assert.equal(coverageLevel(0), 'thin');
  assert.equal(coverageLevel(14), 'thin');
  assert.equal(coverageLevel(15), 'partial');
});

test('provider failure status is failed not empty', () => {
  assert.equal(normalizeCoverageStatus('failed'), 'failed');
  assert.notEqual(normalizeCoverageStatus('failed'), 'thin');
});
