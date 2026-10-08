'use strict';

/**
 * One-time migration: invalidate legacy AI / untrusted Explore prices.
 * Preserves clinic identity. dryRun=true by default.
 *
 * Usage:
 *   node explore/migrations/runInvalidateLegacyPrices.js --dryRun
 *   node explore/migrations/runInvalidateLegacyPrices.js --execute
 */

const admin = require('firebase-admin');
const {
  evaluatePriceTrust,
  invalidatePriceKeepIdentity,
} = require('../trustRules');
const {clinicMergeKey} = require('../identity');

const COLLECTION = 'explore_google_prices';
const BATCH_SIZE = 200;

function ensureAdmin() {
  if (!admin.apps.length) {
    admin.initializeApp();
  }
  return admin.firestore();
}

/**
 * @param {{dryRun?:boolean, limit?:number, startAfterId?:string}} opts
 */
async function invalidateLegacyPrices({
  dryRun = true,
  limit = 0,
  startAfterId = '',
} = {}) {
  const db = ensureAdmin();
  const stats = {
    dryRun: !!dryRun,
    documentsScanned: 0,
    clinicsScanned: 0,
    clinicsPreserved: 0,
    pricesStillTrusted: 0,
    pricesInvalidated: 0,
    clinicsRemoved: 0,
    duplicatesFound: 0,
    errors: 0,
    sampleInvalidations: [],
    sampleRemovals: [],
  };

  let query = db.collection(COLLECTION).orderBy(admin.firestore.FieldPath.documentId());
  if (startAfterId) {
    const startSnap = await db.collection(COLLECTION).doc(startAfterId).get();
    if (startSnap.exists) query = query.startAfter(startSnap);
  }

  let scannedDocs = 0;
  let lastId = '';
  // Paginate
  for (;;) {
    const snap = await query.limit(25).get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      lastId = doc.id;
      scannedDocs += 1;
      stats.documentsScanned += 1;
      if (limit > 0 && scannedDocs > limit) {
        return {...stats, resumableAfterId: lastId, done: false};
      }
      try {
        await processDoc(db, doc, stats, dryRun);
      } catch (e) {
        stats.errors += 1;
        console.log(`[MIGRATE] error · ${doc.id} · ${e.message || e}`);
      }
    }
    if (snap.size < 25) break;
    query = db.collection(COLLECTION)
        .orderBy(admin.firestore.FieldPath.documentId())
        .startAfter(snap.docs[snap.docs.length - 1]);
  }

  console.log('[MIGRATE] summary', JSON.stringify(stats, null, 2));
  return {...stats, resumableAfterId: lastId, done: true};
}

async function processDoc(db, doc, stats, dryRun) {
  const data = doc.data() || {};
  const clinics = Array.isArray(data.clinics) ? data.clinics : [];
  if (!clinics.length) return;

  const byKey = new Map();
  const nextClinics = [];
  for (const row of clinics) {
    stats.clinicsScanned += 1;
    const trust = evaluatePriceTrust(row);
    if (trust.removeClinic) {
      stats.clinicsRemoved += 1;
      if (stats.sampleRemovals.length < 15) {
        stats.sampleRemovals.push({
          docId: doc.id,
          name: row.name || row.clinicName,
          reason: trust.reason,
        });
      }
      continue;
    }

    const key = clinicMergeKey(row) ||
        `name:${String(row.name || '').toLowerCase()}`;
    if (byKey.has(key)) {
      stats.duplicatesFound += 1;
      // Keep the trusted / richer row.
      const prev = byKey.get(key);
      const prevTrust = evaluatePriceTrust(prev);
      if (trust.trusted && !prevTrust.trusted) {
        byKey.set(key, row);
      }
      continue;
    }

    if (trust.trusted) {
      stats.pricesStillTrusted += 1;
      stats.clinicsPreserved += 1;
      byKey.set(key, row);
      continue;
    }

    // Has a numeric price (or claims verified) but fails trust → invalidate.
    const hadPrice = Number(row.price_min || row.priceMin || 0) > 0 ||
        row.verified === true || row.price_verified === true ||
        String(row.price_verification_status || '') === 'official_website';
    if (hadPrice || String(row.price_verification_status || '') !== 'legacy_untrusted') {
      const invalidated = invalidatePriceKeepIdentity(row);
      stats.pricesInvalidated += 1;
      stats.clinicsPreserved += 1;
      byKey.set(key, invalidated);
      if (stats.sampleInvalidations.length < 20) {
        stats.sampleInvalidations.push({
          docId: doc.id,
          name: row.name || row.clinicName,
          reason: trust.reason,
          legacy_price_min: invalidated.legacy_price_min || 0,
        });
      }
    } else {
      // Already legacy_untrusted identity stub — keep.
      stats.clinicsPreserved += 1;
      byKey.set(key, row);
    }
  }

  for (const row of byKey.values()) nextClinics.push(row);

  const changed = JSON.stringify(clinics) !== JSON.stringify(nextClinics);
  if (!changed) return;

  if (dryRun) {
    console.log(
        `[MIGRATE] dryRun · would update ${doc.id} · ` +
        `clinics ${clinics.length} → ${nextClinics.length}`);
    return;
  }

  await doc.ref.set({
    ...data,
    clinics: nextClinics,
    migration_legacy_prices_at: admin.firestore.FieldValue.serverTimestamp(),
    migration_legacy_prices_version: 'm1',
  }, {merge: true});
  console.log(`[MIGRATE] wrote ${doc.id} · clinics=${nextClinics.length}`);
}

module.exports = {
  invalidateLegacyPrices,
  COLLECTION,
  BATCH_SIZE,
};
