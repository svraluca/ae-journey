'use strict';

/**
 * Shared trust rules for Explore verified prices.
 * A row with price_min > 0 is NOT enough.
 */

const {clinicIdentityRejectReason} = require('./identity');
const {isValidExtractedPriceCandidate} = require('./priceSanity');
const {isMarketplaceOrDirectoryHost} = require('./identity');
const {hostOf} = require('./parsePrice');

const TRUSTED_RELATIONS = new Set(['exact', 'variant']);
const UNTRUSTED_STATUSES = new Set([
  'legacy_untrusted',
  'legacy_unverified',
  'unverified',
  'ai_verified',
  'search_evidence',
]);

/**
 * Clinic identity fields we preserve when invalidating a price.
 */
const IDENTITY_FIELDS = [
  'name', 'clinicName', 'place_id', 'placeId', 'website', 'address', 'area',
  'lat', 'lng', 'rating', 'reviews', 'city', 'sourceHost',
  'discovery_provider', 'discoveryProvider',
];

function relationOk(row) {
  const rel = String(
      row.procedure_relation || row.procedureRelation || '').trim().toLowerCase();
  return TRUSTED_RELATIONS.has(rel);
}

function hasLiteralEvidence(row) {
  const min = Number(row.price_min || row.priceMin || 0);
  const rawPrice = String(row.raw_price_text || row.rawPriceText || '').trim();
  const rawProc = String(
      row.raw_procedure_text || row.rawProcedureText || row.brand || '').trim();
  const source = String(
      row.price_source_url || row.sourceUrl || row.source_url || '').trim();
  const method = String(
      row.extraction_method || row.extractionMethod || '').trim();
  return min > 0 && !!rawPrice && !!rawProc && !!source && !!method;
}

function marketplaceOk(row) {
  return row.marketplace_identity_verified === true &&
      (row.price_verification_status === 'fresha_marketplace' ||
        row.price_verification_status === 'booksy_marketplace' ||
        String(row.source_type || row.sourceType || '') === 'marketplace');
}

function verificationFlagOk(row) {
  const status = String(row.price_verification_status || '').trim().toLowerCase();
  if (status === 'legacy_untrusted') return false;
  if (UNTRUSTED_STATUSES.has(status) && status !== 'official_website') {
    // official_website is trusted; legacy_* are not
    if (status.startsWith('legacy_')) return false;
    if (status === 'ai_verified' || status === 'search_evidence' ||
        status === 'unverified') {
      return false;
    }
  }
  if (row.verified === true || row.price_verified === true ||
      row.priceVerified === true) {
    return true;
  }
  if (status === 'official_website') return true;
  if (marketplaceOk(row)) return true;
  return false;
}

/**
 * Full trusted-price gate used by pool reads and migration keep-list.
 */
function evaluatePriceTrust(row) {
  if (!row || typeof row !== 'object') {
    return {trusted: false, reason: 'missing_row', removeClinic: false};
  }

  const name = String(row.name || row.clinicName || '').trim();
  const identityReason = clinicIdentityRejectReason(name, {
    websiteHost: hostOf(row.website || row.price_source_url || row.sourceUrl || ''),
    providerClinic: String(row.provider_clinic || row.providerClinic || ''),
    sourceType: String(row.source_type || row.sourceType || ''),
  });
  if (identityReason) {
    return {
      trusted: false,
      reason: `invalid_identity_${identityReason}`,
      removeClinic: true,
      identityReason,
    };
  }

  const status = String(row.price_verification_status || '').trim().toLowerCase();
  if (status === 'legacy_untrusted') {
    return {trusted: false, reason: 'legacy_untrusted', removeClinic: false};
  }
  if (row.needs_reverification === true && !(Number(row.price_min || 0) > 0 &&
      verificationFlagOk(row) && hasLiteralEvidence(row))) {
    return {trusted: false, reason: 'needs_reverification', removeClinic: false};
  }

  if (!verificationFlagOk(row)) {
    return {trusted: false, reason: 'not_verified_flag', removeClinic: false};
  }
  if (!hasLiteralEvidence(row)) {
    return {trusted: false, reason: 'missing_literal_evidence', removeClinic: false};
  }
  const currency = String(row.currency || '').trim();
  if (!currency) {
    return {trusted: false, reason: 'missing_currency', removeClinic: false};
  }
  if (!relationOk(row)) {
    return {trusted: false, reason: 'bad_procedure_relation', removeClinic: false};
  }

  const min = Number(row.price_min || row.priceMin || 0);
  const sane = isValidExtractedPriceCandidate({
    rawPriceText: String(row.raw_price_text || row.rawPriceText || ''),
    priceMin: min,
    currency: String(row.currency || ''),
    extractionMethod: String(row.extraction_method || row.extractionMethod || ''),
    rawEvidence: String(row.price_evidence_text || row.rawEvidence || ''),
    procedure: String(row.brand || row.raw_procedure_text || ''),
    sourceUrl: String(row.price_source_url || row.sourceUrl || ''),
    logRejects: false,
  });
  if (!sane) {
    return {trusted: false, reason: 'sanity_reject', removeClinic: false};
  }

  // Search-snippet / AI extraction methods are never trusted.
  const method = String(row.extraction_method || row.extractionMethod || '')
      .toLowerCase();
  if (/^(ai_|llm|gpt|snippet|serp)/.test(method) || method === 'search_snippet') {
    return {trusted: false, reason: 'untrusted_extraction_method', removeClinic: false};
  }

  const sourceType = String(row.source_type || row.sourceType || '').toLowerCase();
  if (sourceType === 'search_snippet' || sourceType === 'brightdata') {
    return {trusted: false, reason: 'untrusted_source_type', removeClinic: false};
  }

  return {trusted: true, reason: '', removeClinic: false};
}

/**
 * Build a preserved clinic row with price fields cleared / moved to legacy_*.
 */
function invalidatePriceKeepIdentity(row) {
  const out = {...row};
  const min = Number(row.price_min || row.priceMin || 0);
  const max = Number(row.price_max || row.priceMax || 0);
  if (min > 0) {
    out.legacy_price_min = min;
    out.legacy_price_max = max > 0 ? max : min;
    out.legacy_price_label = String(row.price_label || row.priceLabel || '');
  }
  out.price_min = 0;
  out.price_max = 0;
  out.priceMin = 0;
  out.priceMax = 0;
  out.price_gbp = 0;
  out.price_label = '';
  out.priceLabel = '';
  out.raw_price_text = '';
  out.rawPriceText = '';
  out.price_evidence_text = '';
  out.rawEvidence = '';
  out.price_verified = false;
  out.priceVerified = false;
  out.verified = false;
  out.needs_reverification = true;
  out.price_verification_status = 'legacy_untrusted';
  out.amount_literal_verified = false;
  out.procedure_evidence_verified = false;
  return out;
}

function clinicIdentityStub(row) {
  const stub = {};
  for (const k of IDENTITY_FIELDS) {
    if (row[k] != null && row[k] !== '') stub[k] = row[k];
  }
  stub.name = String(row.name || row.clinicName || '').trim();
  stub.clinicName = stub.name;
  stub.price_min = 0;
  stub.price_verified = false;
  stub.verified = false;
  stub.needs_reverification = true;
  stub.price_verification_status = 'legacy_untrusted';
  return stub;
}

module.exports = {
  evaluatePriceTrust,
  invalidatePriceKeepIdentity,
  clinicIdentityStub,
  hasLiteralEvidence,
  verificationFlagOk,
  IDENTITY_FIELDS,
  TRUSTED_RELATIONS,
};
