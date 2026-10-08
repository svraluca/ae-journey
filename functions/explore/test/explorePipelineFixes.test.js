'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {extractPriceEvidence} = require('../priceExtractor');
const {selectEvidenceForProcedure} = require('../procedureMatch');
const {parsePriceText} = require('../parsePrice');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');
const {classifyProcedureRelation} = require('../procedureRelation');
const {evaluatePriceTrust} = require('../trustRules');
const {
  sanitizeVerifiedPoolRow,
  usablePoolRow,
} = require('../firestoreStore');
const {EXTRACT_REVISION} = require('../clinicCatalog');
const {clinicJson} = require('../getExploreProcedurePrices');
const {
  verifyExceptionPatch,
  handleVerifyExploreCandidates,
  BATCH_DEADLINE_MS,
} = require('../verifyCandidateBatch');
const {isRetryBlocked, noPublicPriceRetryAfter} = require('../clinicCandidateStore');
const {discoverySkipPlaceIds} = require('../discoveryState');

const PAGE =
    'Wrinkle relaxers are priced per unit — Dysport and Xeomin start at $13 per unit, ' +
    'with the exact total depending on the areas treated and the dose your plan calls for.';
const URL = 'https://www.miamiskinspa.com/botox';
const PROCEDURE = 'Botox anti-wrinkle injection';

function miamiHtml() {
  return `<div class="treatment"><p>${PAGE}</p></div>`;
}

function miamiRow(overrides = {}) {
  return {
    name: 'Miami Skin Spa',
    clinicName: 'Miami Skin Spa',
    place_id: 'ChIJMiamiSkinSpa',
    website: 'https://www.miamiskinspa.com',
    address: 'Miami, FL',
    rating: 4.8,
    reviews: 200,
    price_min: 13,
    priceMin: 13,
    price_max: 13,
    currency: 'USD',
    price_label: 'from 13 USD',
    raw_price_text: '$13 per unit',
    rawPriceText: '$13 per unit',
    raw_procedure_text: 'Dysport and Xeomin',
    rawProcedureText: 'Dysport and Xeomin',
    price_evidence_text: PAGE,
    rawEvidence: PAGE,
    price_source_url: URL,
    sourceUrl: URL,
    extraction_method: 'dom_block',
    extractionMethod: 'dom_block',
    price_verification_status: 'official_website',
    price_verified: true,
    verified: true,
    procedure_relation: 'variant',
    procedure_family: 'botox',
    price_extract_revision: EXTRACT_REVISION,
    extractRevision: EXTRACT_REVISION,
    amount_literal_verified: true,
    ...overrides,
  };
}

// Pinned on purpose: this must match kExplorePriceExtractRevision in
// lib/services/explore_price_sanity.dart, or the client zeroes every price the
// backend writes. Bump both sides together.
// e18: exact prices stay exact (no auto /ml from "1 ml"); cross-city cache purge.
test('extraction revision is e18', () => {
  assert.equal(EXTRACT_REVISION, 'e18');
});

test('Miami Skin Spa wrinkle-relaxer paragraph is 13 USD perUnit variant', () => {
  const parsed = parsePriceText(PAGE);
  assert.ok(parsed);
  assert.equal(parsed.priceMin, 13);
  assert.equal(parsed.currency, 'USD');
  assert.equal(parsed.priceType, 'perUnit');
  assert.notEqual(parsed.currency, 'PEN');

  const rows = extractPriceEvidence({html: miamiHtml(), sourceUrl: URL});
  assert.ok(rows.length, 'extractor must find the priced paragraph');
  const picked = selectEvidenceForProcedure(rows, PROCEDURE);
  assert.ok(picked, 'picker must accept the Dysport/Xeomin row for Botox');
  assert.equal(picked.priceMin, 13);
  assert.equal(picked.currency, 'USD');
  assert.equal(picked.priceType, 'perUnit');
  assert.equal(picked.procedureFamily, 'botox');
  assert.equal(picked.procedureRelation, 'variant');

  const sanity = evaluateExtractedPriceCandidate({
    rawPriceText: picked.rawPriceText,
    priceMin: picked.priceMin,
    currency: picked.currency,
    extractionMethod: picked.extractionMethod,
    rawEvidence: picked.rawEvidence,
    procedure: picked.rawProcedureText,
    sourceUrl: picked.sourceUrl,
    priceMax: picked.priceMax,
  });
  assert.equal(sanity.accepted, true, sanity.reason);
  assert.notEqual(sanity.reason, 'implausible_amount');
  assert.notEqual(sanity.reason, 'unjustified_amount');

  const relation = classifyProcedureRelation({
    requestedProcedure: PROCEDURE,
    label: picked.rawProcedureText,
    evidence: picked.rawEvidence,
    sourceUrl: URL,
    clinicOwnQuoted: true,
  });
  assert.equal(relation.eligible, true);
  assert.equal(relation.logToken, 'variant');

  const json = clinicJson({
    place: {
      name: 'Miami Skin Spa',
      website: 'https://www.miamiskinspa.com',
      address: 'Miami, FL',
      placeId: 'ChIJMiamiSkinSpa',
      rating: 4.8,
      reviews: 200,
    },
    evidence: picked,
    city: 'Miami',
  });
  assert.equal(json.currency, 'USD');
  assert.equal(json.currency_confirmed, true);
  assert.notEqual(json.currency, 'EUR');
  assert.equal(json.price_extract_revision, EXTRACT_REVISION);
  assert.equal(json.amount_literal_verified, true);

  const trusted = sanitizeVerifiedPoolRow(json, PROCEDURE);
  assert.equal(evaluatePriceTrust(trusted).trusted, true);
  assert.equal(usablePoolRow(trusted, PROCEDURE), true);
  assert.equal(trusted.price_min, 13);
  assert.equal(trusted.currency, 'USD');
  assert.equal(trusted.procedure_relation, 'variant');
});

test('stale e11 numeric row is identity stub, not a trusted cached price', () => {
  const stale = miamiRow({price_extract_revision: 'e11', extractRevision: 'e11'});
  const cleaned = sanitizeVerifiedPoolRow(stale, PROCEDURE);
  assert.equal(cleaned.name, 'Miami Skin Spa');
  assert.equal(cleaned.place_id, 'ChIJMiamiSkinSpa');
  assert.equal(cleaned.website, 'https://www.miamiskinspa.com');
  assert.equal(cleaned.address, 'Miami, FL');
  assert.equal(cleaned.rating, 4.8);
  assert.equal(cleaned.reviews, 200);
  assert.equal(cleaned.price_min, 0);
  assert.equal(cleaned.verified, false);
  assert.equal(cleaned.price_verified, false);
  assert.equal(cleaned.needs_reverification, true);
  assert.equal(cleaned.price_verification_status, 'legacy_unverified');
  assert.equal(cleaned.price_rejection_reason, 'stale_extract_revision');
  assert.equal(evaluatePriceTrust(cleaned).trusted, false);
  assert.equal(usablePoolRow(stale, PROCEDURE), false);
});

test('current-revision re-verify of the same clinic is trusted numeric', () => {
  const live = miamiRow();
  const cleaned = sanitizeVerifiedPoolRow(live, PROCEDURE);
  assert.equal(evaluatePriceTrust(cleaned).trusted, true);
  assert.equal(usablePoolRow(cleaned, PROCEDURE), true);
  assert.equal(cleaned.price_min, 13);
  assert.equal(cleaned.currency, 'USD');
  assert.equal(cleaned.price_extract_revision, EXTRACT_REVISION);
});

test('empty stored relation is recomputed; Endolift JawLine stays out', () => {
  const emptyRel = miamiRow({procedure_relation: '', procedureRelation: ''});
  const cleaned = sanitizeVerifiedPoolRow(emptyRel, PROCEDURE);
  assert.equal(evaluatePriceTrust(cleaned).trusted, true);
  assert.ok(cleaned.procedure_relation === 'exact' ||
      cleaned.procedure_relation === 'variant');

  const endolift = miamiRow({
    raw_procedure_text: 'Endolift JawLine (Under Chin)',
    rawProcedureText: 'Endolift JawLine (Under Chin)',
    price_evidence_text: 'Endolift JawLine (Under Chin) $499',
    price_min: 499,
    priceMin: 499,
    currency: 'USD',
    raw_price_text: '$499',
    price_source_url: 'https://www.miamiskinspa.com/endolift-jawline',
    sourceUrl: 'https://www.miamiskinspa.com/endolift-jawline',
  });
  const rejected = sanitizeVerifiedPoolRow(endolift, PROCEDURE);
  assert.equal(rejected.price_min, 0);
  assert.equal(usablePoolRow(endolift, PROCEDURE), false);
  assert.match(String(rejected.price_rejection_reason || ''),
      /ineligible_procedure_relation/);
});

test('missing currency is never trusted as EUR', () => {
  const row = miamiRow({currency: ''});
  const cleaned = sanitizeVerifiedPoolRow(row, PROCEDURE);
  assert.equal(cleaned.price_min, 0);
  assert.equal(cleaned.price_rejection_reason, 'missing_currency');
  const json = clinicJson({
    place: {name: 'Any Clinic', website: 'https://clinic.example'},
    evidence: {
      priceMin: 13,
      priceMax: 13,
      currency: '',
      rawProcedureText: 'Botox',
      rawPriceText: '13',
      sourceUrl: 'https://clinic.example/botox',
      extractionMethod: 'dom_block',
      rawEvidence: 'Botox 13',
      procedureFamily: 'botox',
      procedureRelation: 'exact',
    },
    city: 'Miami',
  });
  assert.equal(json.currency, '');
  assert.equal(json.currency_confirmed, false);
});

test('unexpected verifier exception is temporary, not a permanent blacklist', () => {
  const patch = verifyExceptionPatch(new Error('Cannot read properties of undefined'));
  assert.equal(patch.permanent, false);
  assert.equal(patch.failureReason, 'verify_error');
  assert.ok(patch.temporaryMs > 0);
});

test('client-triggered verifier is shallow and short', () => {
  assert.equal(BATCH_DEADLINE_MS, 95000);
  const src = handleVerifyExploreCandidates.toString();
  assert.match(src, /deep:\s*false/);
  assert.match(src, /14000/);
});

test('no_public_price still waits for its recheck TTL', () => {
  const now = Date.now();
  const until = noPublicPriceRetryAfter(now);
  assert.equal(isRetryBlocked({
    temporaryRetryAfter: until,
    priceStatus: {botox: 'no_public_price'},
    procedureOffered: {botox: true},
  }, now), true);
});

test('accepted place IDs stay discoverable so stale rows can re-verify', () => {
  const skip = discoverySkipPlaceIds({
    acceptedPlaceIds: ['accepted-1'],
    permanentRejectedPlaceIds: ['perm-1'],
    temporaryRejected: {
      'temp-live': {retryAfter: Date.now() + 60000},
      'temp-expired': {retryAfter: Date.now() - 60000},
    },
  });
  // The whole point of the fix: a previously accepted clinic whose price is now
  // a stale-revision stub must be rediscoverable.
  assert.equal(skip.has('accepted-1'), false);
  assert.equal(skip.has('perm-1'), true);
  assert.equal(skip.has('temp-live'), true);
  // Cooldown elapsed — eligible for retry again.
  assert.equal(skip.has('temp-expired'), false);
  assert.equal(skip.size, 2);
});

test('empty discovery state skips nothing', () => {
  assert.equal(discoverySkipPlaceIds({}).size, 0);
  assert.equal(discoverySkipPlaceIds(null).size, 0);
});
