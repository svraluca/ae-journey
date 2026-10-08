#!/usr/bin/env node
'use strict';

/**
 * Import the curated Miami public-price dataset into Firestore.
 *
 *   node scripts/importMiamiCuratedClinics.js --dry-run
 *   node scripts/importMiamiCuratedClinics.js
 *
 * Run from the `functions/` directory. Writing uses, in order:
 *   1. GOOGLE_APPLICATION_CREDENTIALS if that file exists
 *   2. `gcloud auth application-default login` credentials
 *   3. the currently logged-in `gcloud auth login` user
 * `--dry-run` needs none of these.
 *
 * Idempotent: every document id is derived from the data (see curatedStore),
 * so re-running updates rows in place. Price rows are separate documents, which
 * is what makes a refresh additive — re-checking one clinic's Botox price
 * cannot disturb its HydraFacial or Morpheus8 rows.
 */

const fs = require('fs');
const path = require('path');

const {
  CLINIC_COLLECTION,
  PRICE_COLLECTION,
  CURATED_REVISION,
  normalizeCuratedDataset,
  tallyFamilies,
} = require('../explore/curatedStore');

const DEFAULT_FILE = path.join(
    __dirname, 'data', 'miami_clinics_sitewide_all_public_prices_v4.json');

/** Whole-metro search key: a Coral Gables clinic must answer "Miami". */
const DEFAULT_CITY_KEY = 'miami';

/** Firestore caps a batch at 500 writes; the candidate store uses 400. */
const BATCH_LIMIT = 400;

function parseArgs(argv) {
  const args = {dryRun: false, file: DEFAULT_FILE, cityKey: DEFAULT_CITY_KEY};
  for (const raw of argv) {
    if (raw === '--dry-run' || raw === '--dryRun') args.dryRun = true;
    else if (raw.startsWith('--file=')) args.file = raw.slice('--file='.length);
    else if (raw.startsWith('--city-key=')) {
      args.cityKey = raw.slice('--city-key='.length).replace(/^["']|["']$/g, '').trim().toLowerCase();
    }
    else if (raw === '--help' || raw === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${raw}`);
  }
  return args;
}

function usage() {
  console.log(`Curated public-price import

  node scripts/importMiamiCuratedClinics.js [--dry-run] [--file=PATH] [--city-key=KEY]

  --dry-run        normalize and report without writing to Firestore
  --file=PATH      dataset path (default scripts/data/miami v4 file)
  --city-key=KEY   searchable city key (default "miami")

  London:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/london_clinics_sitewide_all_public_prices_v1.json --city-key=london

  Paris:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/paris_clinics_sitewide_all_public_prices_v1_100plus.json --city-key=paris

  New York:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/new_york_clinics_sitewide_all_public_prices_v1.json --city-key="new york"

  Los Angeles:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/los_angeles_clinics_sitewide_all_public_prices_v2_expanded.json --city-key="los angeles"

  Houston:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/houston_clinics_sitewide_all_public_prices_v1.json --city-key=houston

  Dallas:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/dallas_clinics_sitewide_all_public_prices_v1.json --city-key=dallas

  Atlanta:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/atlanta_clinics_sitewide_all_public_prices_v2_expanded_injectables.json --city-key=atlanta

  Austin:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/austin_clinics_public_pricing_seed_v1.json --city-key=austin

  Boston:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/boston_clinics_public_pricing_seed_v1.json --city-key=boston

  Charlotte:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/charlotte_clinics_public_pricing_seed_v1.json --city-key=charlotte

  Chicago:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/chicago_clinics_public_pricing_seed_v1.json --city-key=chicago

  Denver:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/denver_clinics_public_pricing_seed_v1.json --city-key=denver

  Las Vegas:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/las_vegas_clinics_public_pricing_seed_v1.json --city-key="las vegas"

  Nashville:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/nashville_clinics_public_pricing_seed_v1.json --city-key=nashville

  Orlando:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/orlando_clinics_sitewide_all_public_prices_v1.json --city-key=orlando

  Phoenix:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/phoenix_clinics_public_pricing_seed_v1.json --city-key=phoenix

  Washington DC:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/washington_dc_clinics_public_pricing_seed_v1.json --city-key="washington dc"

  Tampa:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/tampa_clinics_sitewide_all_public_prices_v1.json --city-key=tampa

  San Diego:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/san_diego_clinics_sitewide_all_public_prices_v1.json --city-key="san diego"

  Canada — Greater Toronto (Toronto + suburbs):
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/toronto_aesthetic_clinics_public_prices_v1.json --city-key=toronto
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/markham_aesthetic_clinics_public_prices_v1.json --city-key=toronto
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/mississauga_aesthetic_clinics_public_prices_v1.json --city-key=toronto
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/oakville_aesthetic_clinics_public_prices_v1.json --city-key=toronto
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/richmond_hill_aesthetic_clinics_public_prices_v1.json --city-key=toronto
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/vaughan_aesthetic_clinics_public_prices_v1.json --city-key=toronto

  Canada — Metro Vancouver (Vancouver + Burnaby + Surrey):
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/vancouver_aesthetic_clinics_public_prices_v1.json --city-key=vancouver
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/burnaby_aesthetic_clinics_public_prices_v1.json --city-key=vancouver
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/surrey_aesthetic_clinics_public_prices_v1.json --city-key=vancouver

  Canada — other metros:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/calgary_aesthetic_clinics_public_prices_v1.json --city-key=calgary
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/edmonton_aesthetic_clinics_public_prices_v1.json --city-key=edmonton
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/halifax_aesthetic_clinics_public_prices_v1.json --city-key=halifax
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/hamilton_aesthetic_clinics_public_prices_v1.json --city-key=hamilton
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/kelowna_aesthetic_clinics_public_prices_v1.json --city-key=kelowna
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/montreal_aesthetic_clinics_public_prices_v1.json --city-key=montreal
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/ottawa_aesthetic_clinics_public_prices_v1.json --city-key=ottawa
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/quebec_city_aesthetic_clinics_public_prices_v1.json --city-key="quebec city"
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/saskatoon_aesthetic_clinics_public_prices_v1.json --city-key=saskatoon
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/victoria_aesthetic_clinics_public_prices_v1.json --city-key=victoria
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/winnipeg_aesthetic_clinics_public_prices_v1.json --city-key=winnipeg

  Moldova — Chișinău:
  node scripts/importMiamiCuratedClinics.js --file=scripts/data/chisinau_aesthetic_clinics_public_prices_v1.json --city-key=chisinau
`);
}

function pad(n) {
  return String(n).padStart(5);
}

function reportFamilies(rows) {
  const counts = tallyFamilies(rows);
  const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  console.log('\nProcedure rows by family:');
  for (const [family, count] of sorted) {
    console.log(`  ${pad(count)}  ${family}`);
  }
  return sorted;
}

const PROJECT_ID = process.env.GCLOUD_PROJECT ||
    process.env.GOOGLE_CLOUD_PROJECT ||
    'aestheticpass-818c6';
const FIRESTORE_BASE =
    `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)`;

function gcloudAccessToken() {
  const {execSync} = require('child_process');
  return execSync('gcloud auth print-access-token', {encoding: 'utf8'}).trim();
}

function encodeValue(value) {
  if (value === null || value === undefined) return {nullValue: null};
  if (typeof value === 'string') return {stringValue: value};
  if (typeof value === 'boolean') return {booleanValue: value};
  if (typeof value === 'number') {
    return Number.isInteger(value)
      ? {integerValue: String(value)}
      : {doubleValue: value};
  }
  if (value instanceof Date) return {timestampValue: value.toISOString()};
  if (Array.isArray(value)) {
    return {arrayValue: {values: value.map(encodeValue)}};
  }
  if (typeof value === 'object') {
    const fields = {};
    for (const [k, v] of Object.entries(value)) {
      if (v === undefined) continue;
      fields[k] = encodeValue(v);
    }
    return {mapValue: {fields}};
  }
  return {stringValue: String(value)};
}

function docName(collection, id) {
  return `projects/${PROJECT_ID}/databases/(default)/documents/${collection}/${id}`;
}

async function restCommit(writes, token) {
  const res = await fetch(`${FIRESTORE_BASE}/documents:commit`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({writes}),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Firestore commit ${res.status}: ${body.slice(0, 500)}`);
  }
}

async function restListIds(collection, token) {
  const ids = new Set();
  let pageToken = '';
  for (;;) {
    const url = new URL(`${FIRESTORE_BASE}/documents/${collection}`);
    url.searchParams.set('pageSize', '300');
    url.searchParams.set('mask.fieldPaths', '__name__');
    if (pageToken) url.searchParams.set('pageToken', pageToken);
    const res = await fetch(url, {
      headers: {Authorization: `Bearer ${token}`},
    });
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`Firestore list ${res.status}: ${body.slice(0, 400)}`);
    }
    const json = await res.json();
    for (const doc of json.documents || []) {
      const name = String(doc.name || '');
      const id = name.split('/').pop();
      if (id) ids.add(id);
    }
    if (!json.nextPageToken) break;
    pageToken = json.nextPageToken;
  }
  return ids;
}

async function commitRestWrites(docs) {
  const token = gcloudAccessToken();
  let committed = 0;
  for (let i = 0; i < docs.length; i += BATCH_LIMIT) {
    const chunk = docs.slice(i, i + BATCH_LIMIT);
    await restCommit(chunk.map(({name, fields}) => ({
      update: {name, fields},
    })), token);
    committed += chunk.length;
    console.log(`  wrote ${committed}/${docs.length}`);
  }
  return committed;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }

  if (!fs.existsSync(args.file)) {
    throw new Error(`Dataset not found: ${args.file}`);
  }
  const dataset = JSON.parse(fs.readFileSync(args.file, 'utf8'));
  const normalized = normalizeCuratedDataset({
    dataset,
    cityKeyOverride: args.cityKey,
  });

  const declaredClinics = Number(dataset.clinic_count) || 0;
  const declaredRows = Number(dataset.priced_procedure_count) || 0;

  console.log(`Curated import` + (args.dryRun ? ' (dry run)' : ''));
  console.log(`  dataset:        ${args.file}`);
  console.log(`  schema_version: ${dataset.schema_version || '?'}`);
  console.log(`  checked_at:     ${normalized.checkedAt || '?'}`);
  console.log(`  city_key:       ${args.cityKey}`);
  console.log(`  revision:       ${CURATED_REVISION}`);
  console.log('');
  console.log(`  Clinics:            ${normalized.clinics.length}` +
      (declaredClinics ? ` (dataset declares ${declaredClinics})` : ''));
  console.log(`  Procedure rows:     ${normalized.rows.length}` +
      (declaredRows ? ` (dataset declares ${declaredRows})` : ''));
  console.log(`  Skipped invalid:    ${normalized.skipped.length}`);
  console.log(`  Duplicates merged:  ${normalized.duplicatesMerged}`);
  console.log(`  Price conflicts:    ${normalized.conflicts.length}`);
  console.log(`  Clinics rejected:   ${normalized.invalidClinics.length}`);

  if (normalized.conflicts.length) {
    console.log('\nPrice conflicts (same clinic, procedure and unit on two pages):');
    for (const c of normalized.conflicts) {
      console.log(`  - ${c.clinic} · ${c.procedure}`);
      console.log(`      kept    ${c.kept}`);
      console.log(`      dropped ${c.dropped}`);
    }
  }

  if (normalized.invalidClinics.length) {
    console.log('\nRejected clinics:');
    for (const c of normalized.invalidClinics) {
      console.log(`  - ${c.name || '<unnamed>'}: ${c.reason}`);
    }
  }
  if (normalized.skipped.length) {
    console.log('\nSkipped procedures:');
    for (const s of normalized.skipped.slice(0, 25)) {
      console.log(`  - ${s.clinic} · ${s.procedure || '<unnamed>'}: ${s.reason}`);
    }
    if (normalized.skipped.length > 25) {
      console.log(`  ... and ${normalized.skipped.length - 25} more`);
    }
  }

  reportFamilies(normalized.rows);

  console.log('\nProcedure rows per clinic:');
  for (const c of [...normalized.clinics].sort((a, b) => b.rowCount - a.rowCount)) {
    console.log(`  ${pad(c.rowCount)}  ${c.doc.name}`);
  }

  if (args.dryRun) {
    console.log('\nDry run — nothing written.');
    console.log(`Would write ${normalized.clinics.length} docs to ` +
        `${CLINIC_COLLECTION} and ${normalized.rows.length} to ${PRICE_COLLECTION}.`);
    return;
  }

  const token = gcloudAccessToken();
  console.log(`Using gcloud credentials for project ${PROJECT_ID}`);
  const existing = await restListIds(PRICE_COLLECTION, token);
  const now = new Date();
  let created = 0;
  let updated = 0;
  const docs = [];

  for (const clinic of normalized.clinics) {
    const fields = encodeValue({...clinic.doc, imported_at: now}).mapValue.fields;
    docs.push({name: docName(CLINIC_COLLECTION, clinic.clinicId), fields});
  }
  for (const row of normalized.rows) {
    if (existing.has(row.rowId)) updated += 1;
    else created += 1;
    const fields = encodeValue({...row.doc, imported_at: now}).mapValue.fields;
    docs.push({name: docName(PRICE_COLLECTION, row.rowId), fields});
  }

  const committed = await commitRestWrites(docs);

  console.log('');
  console.log(`  Created:  ${created}`);
  console.log(`  Updated:  ${updated}`);
  console.log(`  Writes committed: ${committed}`);
  console.log(`\nWrote ${normalized.clinics.length} clinics to ${CLINIC_COLLECTION}`);
  console.log(`Wrote ${normalized.rows.length} price rows to ${PRICE_COLLECTION}`);
}

main().catch((err) => {
  console.error(`\nImport failed: ${err && err.message ? err.message : err}`);
  process.exitCode = 1;
});
