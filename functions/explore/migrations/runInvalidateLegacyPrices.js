#!/usr/bin/env node
'use strict';

/**
 * CLI for legacy price invalidation.
 *
 * Dry run (default):
 *   node explore/migrations/runInvalidateLegacyPrices.js --dryRun
 *
 * Execute (requires explicit --execute):
 *   node explore/migrations/runInvalidateLegacyPrices.js --execute
 *
 * Optional:
 *   --limit=50
 *   --startAfterId=DOC_ID
 */

const path = require('path');

// Load service account if GOOGLE_APPLICATION_CREDENTIALS is set; else default ADC.
const admin = require('firebase-admin');
if (!admin.apps.length) {
  try {
    admin.initializeApp();
  } catch (e) {
    console.error('Firebase Admin init failed:', e.message || e);
    console.error('Set GOOGLE_APPLICATION_CREDENTIALS or run in an environment with ADC.');
    process.exit(1);
  }
}

const {invalidateLegacyPrices} = require('./invalidateLegacyPrices');

async function main() {
  const args = process.argv.slice(2);
  const execute = args.includes('--execute');
  const dryRun = !execute;
  let limit = 0;
  let startAfterId = '';
  for (const a of args) {
    if (a.startsWith('--limit=')) limit = Number(a.slice(8)) || 0;
    if (a.startsWith('--startAfterId=')) startAfterId = a.slice(15);
  }

  console.log('==================================================');
  console.log(dryRun
    ? 'DRY RUN — no Firestore writes'
    : 'EXECUTE — will write legacy_untrusted invalidations');
  console.log('==================================================');

  const stats = await invalidateLegacyPrices({dryRun, limit, startAfterId});

  console.log('\nTOTAL RECORDS (clinic rows scanned):', stats.clinicsScanned);
  console.log('DOCUMENTS SCANNED:', stats.documentsScanned);
  console.log('TRUSTED RECORDS KEPT:', stats.pricesStillTrusted);
  console.log('LEGACY PRICES TO INVALIDATE:', stats.pricesInvalidated);
  console.log('CLINICS TO PRESERVE:', stats.clinicsPreserved);
  console.log('CLINICS TO REMOVE:', stats.clinicsRemoved);
  console.log('DUPLICATES FOUND:', stats.duplicatesFound);
  console.log('ERRORS:', stats.errors);
  if (stats.sampleInvalidations.length) {
    console.log('\nSample invalidations:');
    for (const s of stats.sampleInvalidations.slice(0, 10)) {
      console.log(' -', s);
    }
  }
  if (!dryRun) {
    console.log('\nMigration writes completed. Review Explore UI + Firestore.');
  } else {
    console.log('\nTo execute after review:');
    console.log('  node explore/migrations/runInvalidateLegacyPrices.js --execute');
  }
  process.exit(stats.errors ? 2 : 0);
}

main().catch((e) => {
  console.error(e.message || e);
  if (/credentials|authentication|permission/i.test(String(e.message || e))) {
    console.error('\nAuthenticate first, e.g.:');
    console.error('  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccount.json');
    console.error('  # or: gcloud auth application-default login');
  }
  process.exit(1);
});
