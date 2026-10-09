'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {clinicIdentityRejectReason, looksLikeMarketEstimateDirectoryUrl} = require('../identity');

test('a publication is rejected despite a plausible provider name', () => {
  assert.equal(clinicIdentityRejectReason('ELLE ES', {websiteHost: 'www.elle.com'}),
      'non_clinic_content_host');
  assert.equal(clinicIdentityRejectReason('Aster Medical Clinic', {websiteHost: 'elle.com'}),
      'non_clinic_content_host');
});

test('an editorial cost-guide fragment needs its complete page checked', () => {
  assert.equal(looksLikeMarketEstimateDirectoryUrl(
      'https://aster.example/precios-cirugia-plastica-madrid-guia-doctor/'), true);
  assert.equal(looksLikeMarketEstimateDirectoryUrl(
      'https://aster.example/rinoplastia/precios-rinoplastia/'), false);
});
