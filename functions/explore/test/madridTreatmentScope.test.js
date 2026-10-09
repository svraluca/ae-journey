'use strict';

// Fictional tariffs reproduce category leaks; these are not source-page snapshots.
const test = require('node:test');
const assert = require('node:assert/strict');
const {classifyProcedureRelation} = require('../procedureRelation');
const {selectEvidenceForProcedure, exploreCachedPriceNeedsReselect} = require('../procedureMatch');
const {evaluateExtractedPriceCandidate, stripInvalidCachedPrice} = require('../priceSanity');
const {sanitizeVerifiedPoolRow} = require('../firestoreStore');
const {EXTRACT_REVISION} = require('../extractRevision');
const {parsePriceText} = require('../parsePrice');
const {extractPriceEvidence} = require('../priceExtractor');
const {standardizePriceType} = require('../normalizeProcedureSemantics');
const {clinicJson} = require('../getExploreProcedurePrices');
const {isApproximatePriceQuote} = require('../procedureScope');
const {resolveCuratedPrice} = require('../curatedStore');

function quote(label, amount = 510, sourceUrl = 'https://aster.example/precios/', evidence = '') {
  return {rawProcedureText: label, rawPriceText: `${amount} EUR`,
    priceMin: amount, priceMax: amount, currency: 'EUR', sourceUrl,
    extractionMethod: 'html_table', rawEvidence: evidence || `${label} ${amount} EUR`};
}

function stored(row) {
  return {...row, name: 'Aster Clinic', clinicName: 'Aster Clinic',
    place_id: 'fictional-place', website: 'https://aster.example/', address: 'Madrid',
    price_min: row.priceMin, price_max: row.priceMax,
    raw_procedure_text: row.rawProcedureText, raw_price_text: row.rawPriceText,
    price_evidence_text: row.rawEvidence, price_source_url: row.sourceUrl,
    extraction_method: row.extractionMethod, price_extract_revision: EXTRACT_REVISION,
    extractRevision: EXTRACT_REVISION, verified: true, price_verified: true,
    price_verification_status: 'official_website', procedure_relation: 'exact',
    amount_literal_verified: true};
}

test('surgical chin context cannot become live or cached injectable filler', () => {
  for (const row of [
    quote('Chin filler', 2500, 'https://aster.example/mentoplastia/'),
    quote('Chin filler', 2500, 'https://aster.example/precios/',
      'Chin filler — Mentoplastia con prótesis 2500 EUR'),
    quote('Chin filler / genioplasty', 2500),
    quote('Chin implant filler', 2500),
  ]) {
    const relation = classifyProcedureRelation({requestedProcedure: 'Fillers',
      label: row.rawProcedureText, evidence: row.rawEvidence, sourceUrl: row.sourceUrl,
      clinicOwnQuoted: true});
    assert.equal(relation.eligible, false, row.rawEvidence);
    assert.equal(selectEvidenceForProcedure([row], 'Fillers'), null);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Fillers'}), true);
    assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Fillers',
      logRejects: false}).accepted, false);
    assert.equal(sanitizeVerifiedPoolRow(stored(row), 'Fillers').price_min, 0);
  }
});

test('injectable chin fillers stay valid regardless of amount', () => {
  for (const label of ['Chin filler 1 ml', 'Relleno de mentón con ácido hialurónico',
    'Non-surgical chin augmentation with hyaluronic acid filler',
    'Non-surgical mentoplasty with hyaluronic acid filler',
    'Mentoplastia con ácido hialurónico']) {
    const row = quote(label, 2500);
    assert.ok(selectEvidenceForProcedure([row], 'Fillers'), label);
    assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Fillers',
      logRejects: false}).accepted, true);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Fillers'}), false);
  }
});

test('toxin and skinbooster combination is rejected through every cache path', () => {
  const row = quote('NeuroSkin (Skinbooster + Neuromoduladores)');
  assert.equal(selectEvidenceForProcedure([row], 'Botox'), null);
  assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Botox'}), true);
  assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Botox',
    logRejects: false}).accepted, false);
  assert.equal(stripInvalidCachedPrice(stored(row), 'Botox', {logRejects: false}).price_min, 0);
  assert.equal(sanitizeVerifiedPoolRow(stored(row), 'Botox').price_min, 0);
});

test('standalone toxin and separate neighboring skinbooster tariffs remain valid', () => {
  for (const row of [quote('Neuromoduladores (3 zonas)', 300), quote('Botox 3 areas', 300)]) {
    const rows = [row, quote('Skinbooster', 210)];
    const picked = selectEvidenceForProcedure(rows, 'Botox');
    assert.ok(picked, row.rawEvidence);
    assert.equal(picked.priceMin, 300);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Botox'}), false);
    assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Botox',
      logRejects: false}).accepted, true);
  }
});

test('Spanish partial and secondary rhinoplasty cannot supply a primary tariff', () => {
  for (const label of ['Rinoplastia parcial', 'Rinoplastia de punta', 'Rinoplastia secundaria',
    'Rinoplastia Post-Traumática']) {
    const row = quote(label, 8500);
    assert.equal(classifyProcedureRelation({requestedProcedure: 'Rhinoplasty',
      label, evidence: row.rawEvidence, sourceUrl: row.sourceUrl,
      clinicOwnQuoted: true}).eligible, false, label);
    assert.equal(selectEvidenceForProcedure([row], 'Rhinoplasty'), null, label);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Rhinoplasty'}), true, label);
    assert.equal(sanitizeVerifiedPoolRow(stored(row), 'Rhinoplasty').price_min, 0, label);
  }
  const primary = quote('Rinoplastia primaria', 8500);
  assert.ok(selectEvidenceForProcedure([primary], 'Rhinoplasty'));
  assert.ok(selectEvidenceForProcedure([quote('Rinoplastia Ultrasónica', 7500)], 'Rhinoplasty'));
});

test('financing caps cannot become fees while a distinct treatment tariff stays valid', () => {
  const credit = quote('Chin filler', 2500, 'https://aster.example/',
    'Chin filler | Hasta 2.500€ | Pregúntanos por la financiación');
  assert.equal(selectEvidenceForProcedure([credit], 'Fillers'), null);
  assert.equal(exploreCachedPriceNeedsReselect({...credit, procedure: 'Fillers'}), true);
  assert.equal(sanitizeVerifiedPoolRow(stored(credit), 'Fillers').price_min, 0);
  const treatment = quote('Chin filler', 350, 'https://aster.example/precios/',
    'Chin filler 350 EUR. Financing is available up to 2500 EUR.');
  assert.ok(selectEvidenceForProcedure([treatment], 'Fillers'));
});

test('amount-bound approximate cues survive parsing, extraction and output without inventing a range', () => {
  for (const literal of ['roughly 300 EUR', 'aproximadamente 300 EUR',
    'suele rondar los 300 EUR', '300 EUR aproximadamente']) {
    const parsed = parsePriceText(literal);
    assert.equal(parsed.priceType, 'approximate', literal);
    assert.equal(parsed.priceMin, 300);
    assert.equal(parsed.priceMax, 300);
  }
  const range = parsePriceText('Botox aproximadamente 300 a 400 EUR');
  assert.equal(range.priceType, 'approximate');
  assert.equal(range.priceMax, 400);
  assert.equal(parsePriceText('Botox 300 EUR').priceType, 'fixed');
  assert.equal(isApproximatePriceQuote('Approximately 30 minutes; Botox 300 EUR', 300), false);
  assert.equal(isApproximatePriceQuote('Approximately 30 minutes; Botox 300 EUR', 30), false);
  assert.equal(standardizePriceType('approximate', null), 'approximate');
  const curated = resolveCuratedPrice({price_min: 300, price_max: 400,
    currency: 'EUR', price_type: 'approximate'}, 'EUR');
  assert.equal(curated.priceType, 'approximate');
  assert.equal(curated.priceMax, 400);
  const rows = extractPriceEvidence({html: '<table><tr><td>Botox 3 areas</td>' +
    '<td>approximately 300 EUR</td></tr></table>', sourceUrl: 'https://aster.example/precios/'});
  const picked = selectEvidenceForProcedure(rows, 'Botox');
  assert.ok(picked);
  assert.equal(picked.priceType, 'approximate');
  const json = clinicJson({place: {name: 'Aster Clinic'}, evidence: picked, city: 'Madrid'});
  assert.equal(json.price_type, 'approximate');
  assert.match(json.price_label, /^approximately /);
  assert.equal(json.price_max, 300);
});

test('Spanish market ranges stay excluded beside a genuine owned primary tariff', () => {
  const markets = [
    'El precio medio de una rinoplastia en España está entre 6500€ y 10000€.',
    'El precio promedio de una rinoplastia es 6500 a 10000 EUR.',
    'El precio de la rinoplastia en España oscila entre los 5000 y 10000 euros.',
  ];
  for (const evidence of markets) {
    const row = {...quote('Rinoplastia', 6500, 'https://aster.example/precios/', evidence),
      priceMax: 10000, rawPriceText: '6500 EUR – 10000 EUR'};
    assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Rhinoplasty',
      logRejects: false}).accepted, false, evidence);
    assert.equal(selectEvidenceForProcedure([row], 'Rhinoplasty'), null, evidence);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Rhinoplasty'}), true);
    assert.equal(sanitizeVerifiedPoolRow(stored(row), 'Rhinoplasty').price_min, 0);
  }
  const own = quote('Rinoplastia Ultrasónica', 8000, 'https://aster.example/precios/',
    'En nuestra clínica el precio de la Rinoplastia Ultrasónica es desde 8000 EUR.');
  assert.ok(selectEvidenceForProcedure([own], 'Rhinoplasty'));
  assert.equal(evaluateExtractedPriceCandidate({...own, procedure: 'Rhinoplasty',
    logRejects: false}).accepted, true);
});

test('an explicit lip augmentation request does not borrow a hydration-only HA tariff', () => {
  const hydration = quote('Hidratación de labios con ácido hialurónico', 250);
  for (const procedure of ['Lip filler', 'Lip augmentation', 'Aumento de labios']) {
    assert.equal(selectEvidenceForProcedure([hydration], procedure), null, procedure);
    assert.equal(evaluateExtractedPriceCandidate({...hydration, procedure,
      logRejects: false}).accepted, false, procedure);
    assert.equal(exploreCachedPriceNeedsReselect({...hydration, procedure}), true, procedure);
  }
  const augmentation = quote('Aumento de labios con ácido hialurónico', 349);
  assert.ok(selectEvidenceForProcedure([hydration, augmentation], 'Lip filler'));
  assert.equal(selectEvidenceForProcedure([hydration, augmentation], 'Lip filler').priceMin, 349);
  assert.ok(selectEvidenceForProcedure([hydration], 'Fillers'),
    'A general family search may retain the honest published hydration label');
});

test('mesotherapy keeps its own amount despite a preceding toxin heading', () => {
  for (const label of ['Mesoterapia NCTF', 'Neuromoduladores']) {
    const row = quote(label, 210, 'https://aster.example/precios/',
      'Neuromoduladores | Mesoterapia NCTF 210 EUR');
    assert.equal(selectEvidenceForProcedure([row], 'Botox'), null, label);
    assert.equal(evaluateExtractedPriceCandidate({...row, procedure: 'Botox',
      logRejects: false}).accepted, false, label);
    assert.equal(exploreCachedPriceNeedsReselect({...row, procedure: 'Botox'}), true);
    assert.equal(sanitizeVerifiedPoolRow(stored(row), 'Botox').price_min, 0);
  }
  const own = quote('Neuromoduladores (3 zonas)', 350, 'https://aster.example/precios/',
    'Mesoterapia NCTF 210 EUR | Neuromoduladores (3 zonas) 350 EUR');
  assert.equal(evaluateExtractedPriceCandidate({...own, procedure: 'Botox',
    logRejects: false}).accepted, true);
  assert.equal(exploreCachedPriceNeedsReselect({...own, procedure: 'Botox'}), false);
  assert.equal(selectEvidenceForProcedure([quote('Mesoterapia NCTF', 210),
    quote('Neuromoduladores (3 zonas)', 350)], 'Botox').priceMin, 350);
});
