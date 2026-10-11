'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {marketplacePriceDateFailure, marketplaceRowPriceDateFailure, bookimedPriceDateReader} = require('../marketplacePriceFreshness');
const {evaluatePriceTrust} = require('../trustRules');
const {sanitizeVerifiedPoolRow, usablePoolRow, mergeVerifiedPool} = require('../firestoreStore');
const {mergeClinicRecords} = require('../identity');
const {evaluateExtractedPriceCandidate, stripInvalidCachedPrice} = require('../priceSanity');
const {selectEvidenceForProcedure} = require('../procedureMatch');
const {clinicJson} = require('../getExploreProcedurePrices');
const {extractPriceEvidence} = require('../priceExtractor');
const {catalogIsFresh, EXTRACT_REVISION} = require('../clinicCatalog');

const day = 86400000;
const clock = Date.parse('2026-10-10T12:00:00Z');
const recent = () => new Date(Date.now() - day).toISOString();
const old = () => new Date(Date.now() - 366 * day).toISOString();

test('a Q&A portal tariff cannot certify a clinic fee', () => {
  const verdict = evaluateExtractedPriceCandidate({rawPriceText: '8500 TRY',
    priceMin: 8500, currency: 'TRY', extractionMethod: 'html_table',
    rawEvidence: 'Teosyal Kiss Lip Filler | 8500 TRY', procedure: 'dermal filler',
    sourceUrl: 'https://www.hastalarsoruyor.com/teosyal-kiss/'});
  assert.equal(verdict.accepted, false);
  assert.equal(verdict.reason, 'medical_qa_price');
});

test('a fresh cache timestamp cannot certify missing or old extraction stamps', () => {
  const cached = {updatedAtMs: Date.now()};
  assert.equal(catalogIsFresh(cached), false);
  assert.equal(catalogIsFresh({...cached, extractRevision: 'e31'}), false);
  assert.equal(catalogIsFresh({...cached, extractRevision: EXTRACT_REVISION}), true);
});

function evidence(overrides = {}) {
  return {
    rawProcedureText: 'Lip filler', rawPriceText: '$300', rawEvidence: 'Lip filler | $300',
    priceMin: 300, priceMax: 300, currency: 'USD', priceType: 'fixed',
    sourceUrl: 'https://us-uk.bookimed.com/clinic/aster-clinic/#prices',
    extractionMethod: 'html_table', sourceType: 'marketplace', providerClinic: 'Aster Clinic',
    procedureRelation: 'exact', source_price_updated_at: recent(),
    source_price_date_text: 'Explicit own fee record updated_at',
    source_price_date_basis: 'provider_procedure_price_record', ...overrides,
  };
}

function row(overrides = {}) {
  return {...clinicJson({place: {name: 'Aster Clinic', website: 'https://aster.example/'},
    evidence: evidence(), city: 'Istanbul'}), ...overrides};
}

test('publication age does not expire a fee; invalid future dates still reject', () => {
  const atAge = (days) => new Date(clock - days * day).toISOString();
  assert.equal(marketplacePriceDateFailure(atAge(365), '', {now: clock}), '');
  assert.equal(marketplacePriceDateFailure(atAge(366), '', {now: clock}), '');
  assert.equal(marketplacePriceDateFailure('2001-01-01', '', {now: clock}), '');
  assert.equal(marketplacePriceDateFailure('2026-10-10T14:00:00+02:00', '', {now: clock}), '');
  assert.equal(marketplacePriceDateFailure(atAge(-1), '', {now: clock}), '');
  assert.equal(marketplacePriceDateFailure(atAge(-2), '', {now: clock}), 'marketplace_price_date_future');
});

test('invalid and ambiguous dates are rejected; absence remains unknown', () => {
  for (const value of ['2026-02-30', '2026-13-01', '29.03.2025', '2026-10-10T25:00:00Z']) {
    assert.equal(marketplacePriceDateFailure(value, '', {now: clock}), 'marketplace_price_date_invalid');
  }
  assert.equal(marketplacePriceDateFailure('', 'ambiguous_menu_date', {now: clock}), 'marketplace_price_date_ambiguous');
  assert.equal(marketplacePriceDateFailure('', '', {now: clock}), '');
  assert.equal(marketplaceRowPriceDateFailure({sourceType: 'official_clinic',
    sourceUrl: 'https://aster.example/prices/', source_price_updated_at: '2020-01-01'}, {now: clock}), '');
});

test('serialization keeps source date apart from today’s fetch verification', () => {
  const offer = evidence({sourcePriceUpdatedAt: '2025-03-29T12:00:00Z',
    sourcePriceDateText: 'Last price update 29.03.2025', sourcePriceDateBasis: 'provider_tariff_menu'});
  delete offer.source_price_updated_at;
  delete offer.source_price_date_text;
  delete offer.source_price_date_basis;
  const doc = clinicJson({place: {name: 'Aster Clinic'}, evidence: offer, city: 'Istanbul'});
  assert.equal(doc.source_price_updated_at, '2025-03-29T12:00:00Z');
  assert.equal(doc.source_price_date_text, 'Last price update 29.03.2025');
  assert.equal(doc.source_price_date_basis, 'provider_tariff_menu');
  assert.notEqual(doc.source_price_updated_at, doc.price_verified_at);
});

test('published fees with old source dates survive selection and current cache trust', () => {
  const stale = evidence({source_price_updated_at: old()});
  assert.equal(evaluateExtractedPriceCandidate({...stale, procedure: 'Fillers', logRejects: false}).accepted, true);
  assert.ok(selectEvidenceForProcedure([stale], 'Fillers'));
  const cached = row({source_price_updated_at: old(), lastCheckedAt: new Date().toISOString()});
  assert.equal(evaluatePriceTrust(cached).trusted, true);
  assert.equal(usablePoolRow(cached, 'Fillers', 'Istanbul'), true);
  const cleaned = sanitizeVerifiedPoolRow(cached, 'Fillers', {city: 'Istanbul'});
  assert.equal(cleaned.price_min, 300);
  assert.equal(cleaned.priceMin, 300);
  assert.equal(cleaned.name, 'Aster Clinic');
  assert.equal(cleaned.source_price_updated_at, cached.source_price_updated_at);
});

test('undated fees stay eligible without borrowing the fetch date', () => {
  const undated = row({source_price_updated_at: '', source_price_date_text: '', source_price_date_basis: ''});
  assert.equal(evaluatePriceTrust(undated).trusted, true);
  assert.equal(sanitizeVerifiedPoolRow(undated, 'Fillers').source_price_updated_at, '');
});

test('invalid source date clears numeric aliases and keeps audit provenance', () => {
  const stale = row({source_price_updated_at: 'not a date'});
  const cleaned = stripInvalidCachedPrice(stale, 'Fillers', {logRejects: false});
  assert.equal(cleaned.price_min, 0);
  assert.equal(cleaned.priceMin, 0);
  assert.equal(cleaned.priceMax, 0);
  assert.equal(cleaned.priceVerified, false);
  assert.equal(cleaned.source_price_date_basis, 'provider_procedure_price_record');
});

test('fee provenance follows the chosen amount and an undated replacement clears the old date', () => {
  const a = row({source_price_updated_at: recent()});
  const b = row({price_min: 400, priceMin: 400, source_price_updated_at: old(),
    source_currency_basis: 'viewer_localized'});
  const kept = mergeClinicRecords(a, b);
  assert.equal(kept.price_min, a.price_min);
  assert.equal(kept.source_price_updated_at, a.source_price_updated_at);
  assert.equal(kept.source_currency_basis, '');
  const replacement = row({price_min: 250, priceMin: 250, source_price_updated_at: '',
    source_price_date_text: '', source_price_date_basis: ''});
  const replaced = mergeClinicRecords(a, replacement);
  assert.equal(replaced.price_min, 250);
  assert.equal(replaced.source_price_updated_at, '');
});

test('localized marketplace currency is never relabeled as the provider original', () => {
  const localized = row({currency: 'RON', source_currency_basis: 'viewer_localized'});
  assert.equal(evaluatePriceTrust(localized).reason, 'marketplace_original_currency_unverified');
  assert.equal(sanitizeVerifiedPoolRow(localized, 'Fillers').price_rejection_reason, 'marketplace_original_currency_unverified');
  const merged = mergeVerifiedPool([localized], [row()], 'Fillers', 'Istanbul');
  assert.equal(merged.trusted.length, 1);
  assert.equal(merged.trusted[0].currency, 'USD');
  assert.equal(merged.trusted[0].source_currency_basis, '');
  const offer = evidence({sourceCurrencyBasis: 'viewer_localized', currency: 'RON'});
  const serialized = clinicJson({place: {name: 'Aster Clinic'}, evidence: offer, city: 'Istanbul'});
  assert.equal(serialized.source_currency_basis, 'viewer_localized');
  assert.equal(evaluateExtractedPriceCandidate({...offer, procedure: 'Fillers', logRejects: false}).reason, 'marketplace_original_currency_unverified');
});

function menuHtml({dateText = 'Last price update 29.03.2025', script = ''} = {}) {
  return `<title>Aster Clinic</title><h1>Aster Clinic</h1><section id="prices">
    <table class="clinic-prices__table"><tr><th>Treatment</th><th>Price</th></tr>
    <tr><td>Lip filler</td><td>$300</td></tr></table><p>${dateText}</p></section>${script}`;
}

function nuxtRecord(date, extra = '') {
  return `<script>window.__NUXT__=(function(a,b,c){return {content:{clinic:{id:a}},menu:[
    {operation:{id:b,name:"Lip filler"},prices:{clinic_id:a,entity_id:b,entity:"operations",currency:"USD",price_from:300,price_to:300,updated_at:c}}${extra}
    ]};}(7,8,${JSON.stringify(date)}));</script>`;
}

test('direct HTML extraction keeps a published fee without rewriting its old source date', () => {
  const html = menuHtml();
  const source = evidence();
  const date = bookimedPriceDateReader(html)(source);
  assert.equal(date.source_price_updated_at, '2025-03-29');
  assert.equal(date.source_price_date_basis, 'provider_tariff_menu');
  const extracted = extractPriceEvidence({html, sourceUrl: source.sourceUrl});
  assert.ok(extracted.some((r) => r.priceMin === 300 && r.source_price_updated_at === '2025-03-29'));
  const unrelatedDate = menuHtml({dateText: ''}) + '<footer>Last price update 29.03.2025</footer>';
  assert.equal(bookimedPriceDateReader(unrelatedDate)(source).source_price_updated_at, '');
});

test('a matching own fee record takes priority over the older menu summary', () => {
  const date = recent();
  const unrelated = ',{operation:{id:8,name:"Lip filler"},prices:{clinic_id:99,entity_id:8,entity:"operations",currency:"USD",price_from:300,price_to:300,updated_at:"2020-01-01"}}';
  const html = menuHtml({script: nuxtRecord(date, unrelated)});
  const fields = bookimedPriceDateReader(html)(evidence());
  assert.equal(fields.source_price_updated_at, date);
  assert.equal(fields.source_price_date_basis, 'provider_procedure_price_record');
  const rows = extractPriceEvidence({html, sourceUrl: evidence().sourceUrl});
  assert.ok(rows.some((r) => r.priceMin === 300 && r.source_price_updated_at === date));
  const wrongCurrency = bookimedPriceDateReader(html)(evidence({currency: 'EUR'}));
  assert.equal(wrongCurrency.source_price_date_basis, 'provider_tariff_menu');
});

test('conflicting matched fee dates and slash menu dates remain ambiguous', () => {
  const date = recent();
  const conflicting = ',{operation:{id:8,name:"Lip filler"},prices:{clinic_id:7,entity_id:8,entity:"operations",currency:"USD",price_from:300,price_to:300,updated_at:"2026-06-01"}}';
  const html = menuHtml({script: nuxtRecord(date, conflicting)});
  assert.equal(bookimedPriceDateReader(html)(evidence()).source_price_date_basis, 'ambiguous_menu_date');
  assert.equal(extractPriceEvidence({html, sourceUrl: evidence().sourceUrl}).length, 0);
  assert.equal(bookimedPriceDateReader(menuHtml({dateText: 'Last price update 10/03/2026'}))(evidence()).source_price_date_basis, 'ambiguous_menu_date');
});

test('website date expressions are never executed or promoted to verification dates', () => {
  const expr = nuxtRecord(recent()).replace(/}\(7,8,"[^"]+"\)\);/, '}(7,8,Date.now()));');
  const fields = bookimedPriceDateReader(menuHtml({dateText: '', script: expr}))(evidence());
  assert.equal(fields.source_price_updated_at, '');
});

test('actual marketplace country selector marks viewer currency without guessing from its ISO code', () => {
  const page = '<title>Aster Clinic</title><h1>Aster Clinic</h1>' +
    '<a class="link-country-selector">Romania</a>' +
    '<table><tr><th>Treatment</th><th>Price</th></tr><tr><td>Lip filler</td><td>1500 RON</td></tr></table>';
  const sourceUrl = 'https://www.whatclinic.com/beauty-clinics/turkey/istanbul/aster-clinic';
  assert.equal(extractPriceEvidence({html: page, sourceUrl}).length, 0);
  const original = page.replace('<a class="link-country-selector">Romania</a>', '');
  assert.ok(extractPriceEvidence({html: original, sourceUrl}).some((r) => r.currency === 'RON'));
  assert.ok(extractPriceEvidence({html: page, sourceUrl: 'https://aster.example/prices/'}).some((r) => r.currency === 'RON'));
});

test('user retention preserves a dated published fee but cannot bless a stale extraction', () => {
  const retained = row({source_price_updated_at: old(), source_price_date_basis: 'user_retained_published_fee'});
  assert.equal(usablePoolRow(retained, 'Fillers', 'Istanbul'), true);
  assert.equal(sanitizeVerifiedPoolRow({...retained, price_extract_revision: 'e17'}, 'Fillers').price_min, 0);
  assert.equal(sanitizeVerifiedPoolRow({...retained, source_price_updated_at: '2030-01-01'}, 'Fillers').price_min, 0);
});
