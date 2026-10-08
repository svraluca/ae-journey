'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  discoveryResponse,
  EXPLORE_DISCOVERY_PIPELINE_VERSION,
} = require('../brightdata/cityDiscovery');
const {
  rejectEnqueueReason,
  looksLikeGuideOrDirectory,
} = require('../enqueueClinicCandidates');

test('discoveryResponse never returns successful null identity fields', () => {
  const ok = discoveryResponse({
    ok: true,
    cityId: 'place_ChIJankara',
    status: 'partial',
    candidatesDiscovered: 9,
    candidatesStored: 5,
    verifiedVisibleCount: 1,
    noPublicPriceCount: 3,
    jobId: 'job_1',
  });
  assert.equal(ok.ok, true);
  assert.equal(ok.pipelineVersion, EXPLORE_DISCOVERY_PIPELINE_VERSION);
  assert.equal(ok.cityId, 'place_ChIJankara');
  assert.equal(ok.status, 'partial');
  assert.equal(ok.candidatesDiscovered, 9);
  assert.equal(ok.candidatesStored, 5);
  assert.equal(ok.verifiedVisibleCount, 1);
  assert.equal(ok.noPublicPriceCount, 3);
  assert.equal(ok.jobId, 'job_1');
  assert.deepEqual(ok.rejectedByReason, {});

  const empty = discoveryResponse({ok: true});
  assert.equal(empty.ok, true);
  assert.equal(empty.pipelineVersion, EXPLORE_DISCOVERY_PIPELINE_VERSION);
  assert.equal(empty.cityId, '');
  assert.equal(empty.status, '');
  assert.equal(empty.candidatesDiscovered, 0);
  assert.equal(empty.candidatesStored, 0);
  assert.equal(empty.verifiedVisibleCount, 0);
  assert.equal(empty.noPublicPriceCount, 0);
  assert.equal(empty.jobId, null);
});

test('city_unresolved response is ok=false with zeroed counts', () => {
  const row = discoveryResponse({
    ok: false,
    reason: 'city_unresolved',
    needsLocationResolution: true,
    status: 'failed',
  });
  assert.equal(row.ok, false);
  assert.equal(row.reason, 'city_unresolved');
  assert.equal(row.needsLocationResolution, true);
  assert.equal(row.candidatesDiscovered, 0);
  assert.equal(row.verifiedVisibleCount, 0);
  assert.equal(row.noPublicPriceCount, 0);
  assert.ok(row.pipelineVersion);
});

test('enqueue rejects guide domains and SEO headlines', () => {
  assert.equal(looksLikeGuideOrDirectory('https://www.trueclinic.com/x'), true);
  assert.equal(looksLikeGuideOrDirectory('https://mymeditravel.com/a'), true);
  assert.equal(
      rejectEnqueueReason({
        name: 'Ankara Botoks Fiyatları 2026',
        website: 'https://example-clinic.com',
      }),
      'invalid_identity');
  assert.equal(
      rejectEnqueueReason({
        name: 'Dr Clinic',
        website: 'https://whatclinic.com/clinic/x',
      }),
      'guide_or_directory');
});
