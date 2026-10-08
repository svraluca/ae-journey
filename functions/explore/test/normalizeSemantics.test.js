'use strict';

/**
 * Semantic normalizer + trust rules — LLM must never modify numeric prices.
 */

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  normalizeProcedureSemantics,
  mergeVerifiedNumericWithSemantics,
  inferUnitsFromLabel,
  stripPriceFields,
  isStrongReject,
  NORMALIZER_VERSION,
} = require('../normalizeProcedureSemantics');
const {evaluatePriceTrust, invalidatePriceKeepIdentity} = require('../trustRules');
const {classifyProcedureRelation} = require('../procedureRelation');
const {matchRawProcedureLabel} = require('../procedureMatch');
const {parsePriceText} = require('../parsePrice');

test('stripPriceFields drops all price-related LLM keys', () => {
  const cleaned = stripPriceFields({
    family: 'botox',
    price: 700,
    priceMin: 700,
    priceMax: 900,
    amount: 700,
    currency: 'AED',
    estimatedPrice: 650,
    averagePrice: 800,
    unitType: 'area',
    unitQuantity: 1,
  });
  assert.equal(cleaned.family, 'botox');
  assert.equal(cleaned.unitType, 'area');
  assert.equal(cleaned.price, undefined);
  assert.equal(cleaned.priceMin, undefined);
  assert.equal(cleaned.currency, undefined);
  assert.equal(cleaned.estimatedPrice, undefined);
});

test('inferUnitsFromLabel preserves area/ml quantities literally', () => {
  assert.deepEqual(inferUnitsFromLabel('Botox 1 Area'), {
    unitType: 'area', unitQuantity: 1,
  });
  assert.deepEqual(inferUnitsFromLabel('Botox 2 Areas'), {
    unitType: 'area', unitQuantity: 2,
  });
  assert.deepEqual(inferUnitsFromLabel('Anti-Wrinkle Treatment Three Areas'), {
    unitType: 'area', unitQuantity: 3,
  });
  assert.deepEqual(inferUnitsFromLabel('Russian Lips 1ml'), {
    unitType: 'ml', unitQuantity: 1,
  });
});

test('Botox 1 Area — AED 700 → botox / variant / area=1 / 700 preserved', async () => {
  const rawPrice = 'AED 700';
  const parsed = parsePriceText(rawPrice);
  assert.ok(parsed);
  assert.equal(parsed.priceMin, 700);

  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Botox 1 Area',
    requestedProcedure: 'Botox',
    skipCache: true,
  });
  assert.equal(semantics.family, 'botox');
  assert.equal(semantics.relation, 'variant');
  assert.equal(semantics.unitType, 'area');
  assert.equal(semantics.unitQuantity, 1);
  assert.equal(semantics.eligible, true);

  const locked = {
    priceMin: 700,
    priceMax: 700,
    currency: 'AED',
    rawPriceText: rawPrice,
    rawEvidence: 'Botox 1 Area — AED 700',
    sourceUrl: 'https://clinic.example/prices',
  };
  const merged = mergeVerifiedNumericWithSemantics(locked, semantics);
  assert.equal(merged.priceMin, 700);
  assert.equal(merged.priceMax, 700);
  assert.equal(merged.currency, 'AED');
  assert.equal(merged.rawPriceText, rawPrice);
  assert.equal(merged.procedureFamily, 'botox');
  assert.equal(merged.unitQuantity, 1);
  assert.equal(merged.normalizerVersion, NORMALIZER_VERSION);
});

test('Botox 2 Areas — AED 1,100 → area=2', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Botox 2 Areas',
    requestedProcedure: 'Botox',
    skipCache: true,
  });
  assert.equal(semantics.family, 'botox');
  assert.equal(semantics.relation, 'variant');
  assert.equal(semantics.unitQuantity, 2);
  assert.equal(semantics.eligible, true);

  const merged = mergeVerifiedNumericWithSemantics({
    priceMin: 1100,
    priceMax: 1100,
    currency: 'AED',
    rawPriceText: 'AED 1,100',
    rawEvidence: 'Botox 2 Areas — AED 1,100',
    sourceUrl: 'https://clinic.example/prices',
  }, semantics);
  assert.equal(merged.priceMin, 1100);
});

test('Russian Lips 1ml — AED 990 → lip_filler / variant / ml=1', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Russian Lips 1ml',
    requestedProcedure: 'Lip filler',
    skipCache: true,
  });
  assert.equal(semantics.family, 'filler');
  assert.ok(semantics.canonical.includes('lip') || semantics.canonical === 'filler');
  assert.equal(semantics.relation, 'variant');
  assert.equal(semantics.unitType, 'ml');
  assert.equal(semantics.unitQuantity, 1);
  assert.equal(semantics.eligible, true);

  const merged = mergeVerifiedNumericWithSemantics({
    priceMin: 990,
    priceMax: 990,
    currency: 'AED',
    rawPriceText: 'AED 990',
    rawEvidence: 'Russian Lips 1ml — AED 990',
    sourceUrl: 'https://clinic.example/prices',
  }, {
    ...semantics,
    // Simulate hostile LLM that tried to change the amount via leftover keys.
    priceMin: 1,
    priceMax: 99999,
    currency: 'USD',
  });
  assert.equal(merged.priceMin, 990);
  assert.equal(merged.currency, 'AED');
});

test('Anti-Wrinkle Treatment Three Areas — £250 → botox / variant / area=3', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Anti-Wrinkle Treatment Three Areas',
    requestedProcedure: 'Botox',
    skipCache: true,
  });
  assert.equal(semantics.family, 'botox');
  assert.equal(semantics.unitQuantity, 3);
  assert.equal(semantics.eligible, true);
  const merged = mergeVerifiedNumericWithSemantics({
    priceMin: 250,
    priceMax: 250,
    currency: 'GBP',
    rawPriceText: '£250',
    rawEvidence: 'Anti-Wrinkle Treatment Three Areas — £250',
    sourceUrl: 'https://clinic.example/prices',
  }, semantics);
  assert.equal(merged.priceMin, 250);
});

test('Botox + Filler Package — rejected bundle', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Botox + Filler Package',
    requestedProcedure: 'Botox',
    skipCache: true,
  });
  assert.equal(semantics.eligible, false);
  assert.ok(
      semantics.relation === 'bundle' ||
      /bundle|wrong_family|different/.test(semantics.rejectReason || ''),
  );
});

test('Breast Augmentation + Lift — rejected bundle', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Breast Augmentation + Lift',
    requestedProcedure: 'Breast augmentation',
    skipCache: true,
  });
  assert.equal(semantics.eligible, false);
  assert.ok(
      semantics.relation === 'bundle' ||
      /bundle|different/.test(String(semantics.rejectReason || semantics.relation)),
  );
});

test('Average filler cost in Dubai — market_information rejected', async () => {
  const rel = classifyProcedureRelation({
    requestedProcedure: 'Filler',
    label: 'Average filler cost in Dubai AED 1,000–3,000',
    evidence: 'Average filler cost in Dubai AED 1,000–3,000',
    clinicOwnQuoted: false,
  });
  assert.equal(rel.relation, 'market_information');
  assert.equal(rel.eligible, false);

  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Average filler cost in Dubai AED 1,000–3,000',
    requestedProcedure: 'Filler',
    clinicOwnQuoted: false,
    skipCache: true,
  });
  assert.equal(semantics.eligible, false);
});

test('Consultation AED 500 rejected for Botox', async () => {
  const match = matchRawProcedureLabel('Consultation', 'Botox');
  // Consultation is wrong family / not botox.
  const rel = classifyProcedureRelation({
    requestedProcedure: 'Botox',
    label: 'Consultation AED 500',
    evidence: 'Consultation AED 500',
    clinicOwnQuoted: true,
  });
  assert.equal(rel.eligible, false);

  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Consultation AED 500',
    requestedProcedure: 'Botox',
    skipCache: true,
  });
  assert.equal(semantics.eligible, false);
  void match;
});

test('clinic-owned "start from" filler may be eligible as from pricing', async () => {
  const semantics = await normalizeProcedureSemantics({
    rawLabel: 'Lip Filler',
    serviceLabel: 'Our filler treatments start from AED 990',
    requestedProcedure: 'Filler',
    clinicOwnQuoted: true,
    skipCache: true,
  });
  // Deterministic family match on "Lip Filler" should pass without LLM.
  assert.equal(semantics.family, 'filler');
  assert.equal(semantics.eligible, true);
  assert.equal(semantics.fromLlm, false);
});

test('AI cannot override strong deterministic rejection', () => {
  assert.equal(isStrongReject(
      {rejectReason: '', family: 'botox', confidence: 0.9},
      {relation: 'bundle', eligible: false, logToken: 'bundle'},
  ), true);
  assert.equal(isStrongReject(
      {rejectReason: 'wrong_family_filler', family: 'filler', confidence: 0.9},
      {relation: 'exact', eligible: true, logToken: 'exact'},
  ), true);
  assert.equal(isStrongReject(
      {rejectReason: '', family: 'botox', confidence: 0.9},
      {relation: 'variant', eligible: true, logToken: 'variant'},
  ), false);
});

test('legacy_untrusted never trusted; identity preserved on invalidate', () => {
  const trusted = {
    name: 'Good Clinic',
    place_id: 'ChIJabc',
    website: 'https://goodclinic.example',
    price_min: 700,
    price_verified: true,
    verified: true,
    price_verification_status: 'official_website',
    raw_price_text: 'AED 700',
    raw_procedure_text: 'Botox 1 Area',
    price_source_url: 'https://goodclinic.example/prices',
    extraction_method: 'html_table',
    procedure_relation: 'variant',
    currency: 'AED',
    price_evidence_text: 'Botox 1 Area AED 700',
  };
  assert.equal(evaluatePriceTrust(trusted).trusted, true);

  const bad = {
    name: 'Old AI Clinic',
    place_id: 'ChIJxyz',
    website: 'https://old.example',
    price_min: 500,
    price_verified: true,
    verified: true,
    price_verification_status: 'ai_verified',
    raw_price_text: '',
    extraction_method: 'ai_estimate',
  };
  assert.equal(evaluatePriceTrust(bad).trusted, false);

  const invalidated = invalidatePriceKeepIdentity(bad);
  assert.equal(invalidated.price_verification_status, 'legacy_untrusted');
  assert.equal(invalidated.needs_reverification, true);
  assert.equal(invalidated.price_min, 0);
  assert.equal(invalidated.legacy_price_min, 500);
  assert.equal(invalidated.name, 'Old AI Clinic');
  assert.equal(invalidated.place_id, 'ChIJxyz');
  assert.equal(evaluatePriceTrust(invalidated).trusted, false);
});

test('merge never lets semantics overwrite locked numeric evidence', () => {
  const locked = {
    priceMin: 1400,
    priceMax: 1400,
    currency: 'AED',
    rawPriceText: 'AED 1,400',
    rawEvidence: 'Anti-Wrinkle Treatment - 2 Areas AED 1,400',
    sourceUrl: 'https://clinic.com/prices',
  };
  const hostileSemantics = {
    family: 'botox',
    canonical: 'botox',
    relation: 'variant',
    unitType: 'area',
    unitQuantity: 2,
    confidence: 0.99,
    priceMin: 999,
    priceMax: 9999,
    currency: 'USD',
    rawPriceText: 'HACKED',
  };
  const merged = mergeVerifiedNumericWithSemantics(locked, hostileSemantics);
  assert.equal(merged.priceMin, 1400);
  assert.equal(merged.priceMax, 1400);
  assert.equal(merged.currency, 'AED');
  assert.equal(merged.rawPriceText, 'AED 1,400');
  assert.equal(merged.unitQuantity, 2);
});
