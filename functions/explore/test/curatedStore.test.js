'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const {
  CURATED_SOURCE,
  buildCuratedClinic,
  buildCuratedPriceRow,
  curatedPriceRowId,
  curatedProcedureFamily,
  normalizeCuratedDataset,
  parseUnitLabel,
  resolveCuratedPrice,
  sourceUrlDepth,
  tallyFamilies,
} = require('../curatedStore');
const {EXTRACT_REVISION} = require('../extractRevision');

const DATASET_PATH = path.join(
    __dirname, '..', '..', 'scripts', 'data',
    'miami_clinics_sitewide_all_public_prices_v4.json');

const dataset = JSON.parse(fs.readFileSync(DATASET_PATH, 'utf8'));
const normalized = normalizeCuratedDataset({
  dataset,
  cityKeyOverride: 'miami',
});

function rowsFor(clinicName) {
  const clinic = normalized.clinics
      .find((c) => c.doc.name === clinicName);
  assert.ok(clinic, `clinic not in dataset: ${clinicName}`);
  return normalized.rows.filter((r) => r.doc.clinic_id === clinic.clinicId);
}

function rowNamed(clinicName, procedureName) {
  const row = rowsFor(clinicName)
      .find((r) => r.doc.procedure_name === procedureName);
  assert.ok(row, `row not found: ${clinicName} · ${procedureName}`);
  return row.doc;
}

test('every imported clinic has a name, a contact and a priced procedure', () => {
  assert.equal(normalized.clinics.length, 34);
  for (const {doc, rowCount} of normalized.clinics) {
    assert.ok(doc.name.length > 0, 'name');
    assert.ok(doc.address.length > 0, `address for ${doc.name}`);
    assert.ok(
        doc.phone.length > 0 || doc.website.length > 0,
        `phone or website for ${doc.name}`,
    );
    assert.ok(rowCount > 0, `priced procedure for ${doc.name}`);
  }
  assert.equal(normalized.invalidClinics.length, 0);
});

test('a procedure with no numeric price is never imported', () => {
  for (const {doc} of normalized.rows) {
    assert.ok(doc.price_min > 0, `${doc.clinic_name} · ${doc.procedure_name}`);
    assert.ok(doc.price_max >= doc.price_min);
  }

  const empty = buildCuratedPriceRow({
    clinicDoc: {city_key: 'miami', name: 'X', country_code: 'US'},
    clinicId: 'x',
    procedure: {
      name: 'Consultation',
      currency: 'USD',
      source_url: 'https://example.com/pricing',
      price: null,
      price_min: null,
      regular_price: null,
      member_price: null,
    },
    checkedAt: '2026-09-08',
  });
  assert.equal(empty.skip, 'no_numeric_price');
});

test('currency comes from the row and never defaults silently to nothing', () => {
  for (const {doc} of normalized.rows) {
    assert.equal(doc.currency, 'USD');
  }
  // The dataset supplies USD on every row; a row that omits it falls back to
  // the documented global default rather than an empty string.
  assert.equal(resolveCuratedPrice({price: 100, currency: ''}).currency, 'USD');
  assert.equal(resolveCuratedPrice({price: 100, currency: 'eur'}).currency, 'EUR');
});

test('a published range stays a range', () => {
  const rhino = rowNamed('Careaga Plastic Surgery', 'Rhinoplasty');
  assert.equal(rhino.price_type, 'range');
  assert.equal(rhino.price_min, 8000);
  assert.equal(rhino.price_max, 12000);
  assert.equal(rhino.procedure_family, 'rhinoplasty');

  const ranged = normalized.rows.filter((r) => r.doc.price_type === 'range');
  assert.ok(ranged.length > 0);
  for (const {doc} of ranged) {
    assert.ok(doc.price_max > doc.price_min, doc.procedure_name);
  }
});

test('per-unit Botox stays per-unit and keeps the unit price', () => {
  const botox = rowNamed('Alexis Lauren - Coral Gables', 'Botox');
  assert.equal(botox.price_type, 'per_unit');
  assert.equal(botox.unit, 'unit');
  assert.equal(botox.price_min, 14);
  assert.equal(botox.procedure_family, 'botox');
  // Not read as a $14 whole treatment.
  assert.equal(botox.price_max, 14);
});

test('per-graft hair transplant stays per-graft', () => {
  const graft = rowNamed('The Miami Hair Clinic', 'Hair Transplant - Per Graft');
  assert.equal(graft.price_type, 'per_unit');
  assert.equal(graft.unit, 'graft');
  assert.equal(graft.price_min, 5.5);
  assert.equal(graft.procedure_family, 'hair_transplant');
});

test('member and regular prices stay separate, regular is the display price', () => {
  const botox = rowNamed('Alexis Lauren - Coral Gables', 'Botox');
  assert.equal(botox.regular_price, 14);
  assert.equal(botox.member_price, 11.2);
  // The card price is the public one, not the member rate.
  assert.equal(botox.price_min, 14);

  // A row with only member + regular still shows the regular price.
  const priced = resolveCuratedPrice({
    currency: 'USD',
    unit: 'per syringe',
    price_type: 'fixed',
    member_price: 675,
    regular_price: 750,
  });
  assert.equal(priced.priceMin, 750);
  assert.equal(priced.memberPrice, 675);
  assert.equal(priced.regularPrice, 750);
});

test('a clinic with 161 procedures imports all of them, untruncated', () => {
  const amma = rowsFor('AMMA Aesthetics');
  assert.equal(amma.length, 161);
  const source = dataset.clinics.find((c) => c.name === 'AMMA Aesthetics');
  assert.equal(source.procedures.length, 161);
});

test('one clinic can belong to many families at once', () => {
  const families = new Set(
      rowsFor('Miami Skin Spa - Brickell').map((r) => r.doc.procedure_family));
  for (const expected of ['botox', 'filler', 'peel', 'laser']) {
    assert.ok(families.has(expected), `missing family ${expected}`);
  }
  assert.ok(families.size >= 6);
});

test('re-running the import reuses the same document ids', () => {
  const again = normalizeCuratedDataset({dataset, cityKeyOverride: 'miami'});
  assert.equal(again.rows.length, normalized.rows.length);
  assert.deepEqual(
      again.rows.map((r) => r.rowId),
      normalized.rows.map((r) => r.rowId),
  );
  assert.deepEqual(
      again.clinics.map((c) => c.clinicId),
      normalized.clinics.map((c) => c.clinicId),
  );
  // Ids are unique, so a rerun updates in place instead of duplicating.
  assert.equal(new Set(normalized.rows.map((r) => r.rowId)).size,
      normalized.rows.length);
});

test('the published procedure name survives; family is only for querying', () => {
  const platinum = rowNamed('Miami Skin Spa - Brickell', 'HydraFacial Platinum');
  assert.equal(platinum.procedure_name, 'HydraFacial Platinum');
  assert.equal(platinum.procedure_family, 'hydrafacial');
  assert.notEqual(platinum.procedure_name, 'Facial');

  const motiva = normalized.rows
      .map((r) => r.doc)
      .filter((d) => d.procedure_family === 'breast_augmentation');
  assert.ok(motiva.length > 0);
  for (const doc of motiva) {
    assert.ok(doc.procedure_name.length > 0);
  }
});

test('unrelated services keep their own family instead of a flagship pill', () => {
  const families = tallyFamilies(normalized.rows);
  for (const expected of [
    'surgery', 'wellness', 'iv_therapy', 'facials', 'body_contouring',
    'tattoo_removal', 'waxing', 'lashes_brows', 'massage_wellness',
  ]) {
    assert.ok(families[expected] > 0, `expected rows for ${expected}`);
  }
  // An IV drip must not be filed under one of the six flagship categories.
  const iv = rowsFor('AMMA Aesthetics')
      .find((r) => r.doc.procedure_name === 'IV Hydration');
  assert.ok(iv);
  assert.equal(iv.doc.procedure_family, 'iv_therapy');
});

test('dataset categories are aliased onto the Explore family vocabulary', () => {
  // "peels"/"fillers" in the source would be invisible to the singular family
  // keys the rest of the pipeline matches on.
  assert.equal(
      curatedProcedureFamily({name: 'PRX Perfexion', category: 'peels'}).family,
      'peel',
  );
  assert.equal(
      curatedProcedureFamily({name: 'Vollure', category: 'fillers'}).family,
      'filler',
  );
  const families = tallyFamilies(normalized.rows);
  assert.equal(families.peels, undefined);
  assert.equal(families.fillers, undefined);
});

test('unit labels parse into a token and a quantity', () => {
  assert.deepEqual(parseUnitLabel('per unit'), {unit: 'unit', quantity: 0, token: 'unit'});
  assert.deepEqual(parseUnitLabel('per graft'), {unit: 'graft', quantity: 0, token: 'graft'});
  assert.equal(parseUnitLabel('1.5 ml').unit, 'ml');
  assert.equal(parseUnitLabel('1.5 ml').quantity, 1.5);
  // "per month" must not be mistaken for a per-item rate.
  assert.equal(parseUnitLabel('per month').unit, 'month');
  assert.equal(resolveCuratedPrice({
    price: 199, currency: 'USD', unit: 'per month', price_type: 'fixed',
  }).priceType, 'fixed');
});

test('a promotional price keeps its unit and is flagged, not relabelled', () => {
  const intro = resolveCuratedPrice({
    price: 10,
    currency: 'USD',
    unit: 'per unit',
    price_type: 'introductory',
  });
  assert.equal(intro.priceType, 'per_unit');
  assert.equal(intro.isPromotional, true);
  assert.equal(intro.sourcePriceType, 'introductory');
});

test('a package keeps its session count and is flagged', () => {
  const pack = rowNamed('AMMA Aesthetics', 'HydraFacial Platinum - 4 Pack');
  assert.equal(pack.package_sessions, 4);
  assert.equal(pack.is_package, true);
});

test('every row carries the current extract revision and curated source', () => {
  assert.equal(EXTRACT_REVISION, 'e18');
  for (const {doc} of normalized.rows) {
    assert.equal(doc.price_extract_revision, EXTRACT_REVISION);
    assert.equal(doc.source, CURATED_SOURCE);
    assert.ok(doc.source_url.startsWith('http'), doc.procedure_name);
    assert.equal(doc.checked_at, '2026-09-08');
    assert.equal(doc.city_key, 'miami');
  }
});

test('the whole metro answers a Miami search', () => {
  const gables = normalized.clinics
      .find((c) => c.doc.name === 'Alexis Lauren - Coral Gables');
  assert.equal(gables.doc.city_key, 'miami');
  // The printed address still names the real municipality.
  assert.match(gables.doc.address, /Coral Gables/);
  assert.equal(gables.doc.city, 'Coral Gables');
});

test('a conflicting price on two pages resolves to the more specific page', () => {
  assert.equal(sourceUrlDepth('https://care4hairmiami.com/'), 0);
  assert.equal(sourceUrlDepth('https://care4hairmiami.com/fue-hair-transplant-in-miami'), 1);

  const fue = rowNamed('Care4Hair', 'FUE Hair Transplant');
  assert.equal(fue.price_min, 2);
  assert.equal(fue.price_max, 3.5);
  assert.match(fue.source_url, /fue-hair-transplant-in-miami/);
  assert.equal(normalized.conflicts.length, 1);
});

test('duplicate rows on two pages collapse without losing a clinic', () => {
  // The same rate published twice is one row, and reported as a duplicate.
  assert.equal(normalized.duplicatesMerged, 3);
  assert.equal(
      normalized.rows.length,
      dataset.priced_procedure_count -
        normalized.duplicatesMerged -
        normalized.conflicts.length,
  );
});

test('row ids change with unit and price type but not with price', () => {
  const base = {
    cityKey: 'miami', clinicId: 'c1', procedureName: 'Lip Filler',
  };
  const full = curatedPriceRowId({...base, unit: 'syringe', priceType: 'per_unit'});
  const half = curatedPriceRowId({...base, unit: 'half syringe', priceType: 'per_unit'});
  assert.notEqual(full, half);
  // A price change must update the existing row, not create a second one.
  assert.equal(full, curatedPriceRowId({...base, unit: 'syringe', priceType: 'per_unit'}));
});

test('a clinic document records identity without embedding its prices', () => {
  const {doc} = buildCuratedClinic({
    clinic: dataset.clinics.find((c) => c.name === 'AMMA Aesthetics'),
    cityKeyOverride: 'miami',
    checkedAt: '2026-09-08',
  });
  assert.equal(doc.website_host, 'ammaaesthetics.com');
  assert.equal(doc.country_code, 'US');
  assert.ok(doc.rating > 0);
  // Prices live in the flattened collection so refreshing one procedure
  // cannot disturb the other 160.
  assert.equal(doc.procedures, undefined);
  assert.equal(doc.procedure_count, 161);
});
