'use strict';

const admin = require('firebase-admin');
const {hostOf} = require('./parsePrice');
const {evaluateExtractedPriceCandidate} = require('./priceSanity');
const {EXTRACT_REVISION} = require('./extractRevision');

const COLLECTION = 'clinic_price_catalog';
/** Stale catalog rows must not skip a fresh scrape. */
const TTL_MS = 7 * 24 * 60 * 60 * 1000;

function catalogId(host) {
  const h = String(host || '').toLowerCase().replace(/^www\./, '');
  const encoded = encodeURIComponent(h).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

function catalogIsFresh(data) {
  if (!data || typeof data !== 'object') return false;
  const rev = String(data.extractRevision || data.price_extract_revision || '');
  if (rev && rev !== EXTRACT_REVISION) return false;
  const updated = data.updatedAt && data.updatedAt.toDate
    ? data.updatedAt.toDate()
    : (data.updatedAtMs ? new Date(Number(data.updatedAtMs)) : null);
  if (!updated) return false;
  return Date.now() - updated.getTime() <= TTL_MS;
}

async function loadHostCatalog(url) {
  const host = hostOf(url);
  if (!host) return [];
  const snap = await admin.firestore().collection(COLLECTION).doc(catalogId(host)).get();
  if (!snap.exists) return [];
  const data = snap.data() || {};
  if (!catalogIsFresh(data)) {
    console.log(`[CATALOG] stale · ${host} — re-scrape required`);
    return [];
  }
  const rows = data.evidence;
  if (!Array.isArray(rows)) return [];
  return rows.filter((row) => evaluateExtractedPriceCandidate({
    rawPriceText: String(row.rawPriceText || row.raw_price_text || ''),
    priceMin: Number(row.priceMin || row.price_min || 0),
    currency: String(row.currency || ''),
    extractionMethod: String(row.extractionMethod || row.extraction_method || ''),
    rawEvidence: String(row.rawEvidence || ''),
    procedure: String(row.rawProcedureText || ''),
    sourceUrl: String(row.sourceUrl || row.source_url || url || ''),
  }).accepted);
}

async function saveHostCatalog({url, clinicName, city, evidence}) {
  const host = hostOf(url);
  if (!host || !Array.isArray(evidence) || !evidence.length) return;
  const clean = evidence.filter((row) => evaluateExtractedPriceCandidate({
    rawPriceText: String(row.rawPriceText || ''),
    priceMin: Number(row.priceMin || 0),
    currency: String(row.currency || ''),
    extractionMethod: String(row.extractionMethod || ''),
    rawEvidence: String(row.rawEvidence || ''),
    procedure: String(row.rawProcedureText || ''),
    sourceUrl: String(row.sourceUrl || url || ''),
  }).accepted);
  if (!clean.length) return;
  const id = catalogId(host);
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  await ref.set({
    host,
    clinicName: clinicName || '',
    city: city || '',
    sourceUrl: url,
    evidence: clean,
    extractRevision: EXTRACT_REVISION,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAtMs: Date.now(),
  }, {merge: true});
}

module.exports = {
  loadHostCatalog,
  saveHostCatalog,
  catalogId,
  catalogIsFresh,
  TTL_MS,
  EXTRACT_REVISION,
};
