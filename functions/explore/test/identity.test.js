'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  clinicIdentityRejectReason,
  isGenericShopIdentity,
  isMarketplaceBrandName,
  extractMarketplaceProviderName,
  marketplaceListingBusinessNameFromUrl,
  namesLookLikeSameProvider,
  packedCanonicalClinicName,
  looksLikeRawScrapedProcedureTitle,
  looksLikeFinancingOrPaymentHeading,
  looksLikeMarketEstimateDirectoryUrl,
  ingestExcludeClinicKeys,
} = require('../identity');

test('ClinicPoint as provider is rejected', () => {
  assert.equal(clinicIdentityRejectReason('ClinicPoint'), 'marketplace_without_provider');
  assert.equal(isMarketplaceBrandName('ClinicPoint'), true);
});

test('marketplace HTML with Clínica Londres extracts provider', () => {
  const html = '{"clinicName":"Clínica Londres Rosselló"} <h2>Clínica Londres Rosselló</h2>';
  const provider = extractMarketplaceProviderName(html, {
    sourceUrl: 'https://clinicpoint.com/x',
    marketplaceName: 'ClinicPoint',
  });
  assert.match(provider, /Londres/);
  assert.equal(clinicIdentityRejectReason(provider, {
    websiteHost: 'clinicpoint.com',
    providerClinic: provider,
    sourceType: 'marketplace',
  }), null);
});

test('Booksy barber listing is not an aesthetic provider', () => {
  assert.equal(clinicIdentityRejectReason('Flyy City Barbershop'), 'wrong_business_type');
  assert.equal(isMarketplaceBrandName('Booksy'), true);
  const barberUrl =
      'https://booksy.com/en-us/111_flyy-city-barbershop_barber-shop_miami';
  const beautyUrl =
      'https://booksy.com/en-us/222_endless-beauty-aesthetics_medical-spa_miami';
  assert.equal(
      marketplaceListingBusinessNameFromUrl(barberUrl),
      'Flyy City Barbershop');
  assert.equal(extractMarketplaceProviderName(
      '{"businessName":"Endless Beauty Aesthetics"}',
      {sourceUrl: barberUrl, marketplaceName: 'Flyy City Barbershop'}), '');
  assert.equal(extractMarketplaceProviderName(
      '{"businessName":"Flyy City Barbershop"}',
      {sourceUrl: beautyUrl, marketplaceName: 'Flyy City Barbershop'}),
  'Endless Beauty Aesthetics');
});

test('Tienda is a generic shop identity', () => {
  assert.equal(isGenericShopIdentity('Tienda'), true);
  assert.equal(clinicIdentityRejectReason('Tienda'), 'generic_business_name');
});

test('Turó Park variants collapse', () => {
  assert.equal(
      namesLookLikeSameProvider('Turó Park Aesthetic Clinic', 'Turoparkaesthetic'),
      true);
  assert.equal(
      packedCanonicalClinicName('Turó Park Aesthetic Clinic'),
      packedCanonicalClinicName('Turoparkaesthetic'));
});

test('raw comment text is not a procedure title', () => {
  assert.equal(looksLikeRawScrapedProcedureTitle('Luis Fajardo noviembre 13, 2022'), true);
  assert.equal(looksLikeRawScrapedProcedureTitle('Magia en cinco pinchazos'), true);
  assert.equal(looksLikeRawScrapedProcedureTitle('Aumento de labios'), false);
});

test('GetClearBeauty is a market-estimate directory, not a clinic', () => {
  assert.equal(isMarketplaceBrandName('GetClearBeauty'), true);
  assert.equal(clinicIdentityRejectReason('GetClearBeauty'), 'marketplace_without_provider');
  assert.equal(
      looksLikeMarketEstimateDirectoryUrl('https://getclearbeauty.com/vi-peel/'),
      true);
  assert.equal(clinicIdentityRejectReason('Miami Skin Spa', {
    websiteHost: 'https://getclearbeauty.com/vi-peel/',
    providerClinic: 'Miami Skin Spa',
    sourceType: 'marketplace',
  }), 'market_estimate');
});

test('scraped price copy is not a clinic name', () => {
  assert.equal(clinicIdentityRejectReason('Cost \$3500'), 'invalid_identity');
  assert.equal(clinicIdentityRejectReason('Starts at \$3000'), 'invalid_identity');
  assert.equal(clinicIdentityRejectReason('From £4500'), 'invalid_identity');
  assert.equal(clinicIdentityRejectReason('Miami Skin Spa'), null);
});

test('Romanian Serp page titles are not clinic names', () => {
  assert.equal(clinicIdentityRejectReason('preț 2026'), 'invalid_identity');
  assert.equal(
      clinicIdentityRejectReason('Mărire buze cu acid hialuronic de la 659 lei'),
      'invalid_identity');
  assert.equal(
      clinicIdentityRejectReason('Tarife epilare definitiva laser'),
      'invalid_identity');
});

test('Breast surgery financing is not a procedure title', () => {
  assert.equal(looksLikeFinancingOrPaymentHeading('Breast surgery financing'), true);
  assert.equal(looksLikeRawScrapedProcedureTitle('Breast surgery financing'), true);
  assert.equal(looksLikeRawScrapedProcedureTitle('Breast Enlargement'), false);
  assert.equal(looksLikeRawScrapedProcedureTitle('Breast Enlargement Cost'), true);
  assert.equal(
      looksLikeRawScrapedProcedureTitle(
          'Pain following breast enlargement surgery'),
      true);
});

test('excludeClinicKeys ingest keeps prefixed identity keys as-is', () => {
  const seen = ingestExcludeClinicKeys([
    'host:miamiskinspa.com',
    'id:ChIJpeelOnly',
    'name:miami skin spa',
    'bare name',
  ]);
  assert.equal(seen.has('host:miamiskinspa.com'), true);
  assert.equal(seen.has('id:ChIJpeelOnly'), true);
  assert.equal(seen.has('id:chijpeelonly'), true);
  assert.equal(seen.has('name:miami skin spa'), true);
  assert.equal(seen.has('name:bare name'), true);
  assert.equal(seen.has('name:host:miamiskinspa.com'), false);
});
