'use strict';

const admin = require('firebase-admin');
const {hostOf} = require('./parsePrice');

/**
 * Cached discovery URLs per clinic host so later users skip repeating SERP/map.
 * Stores URL metadata — never a trusted numeric price.
 */
const COLLECTION = 'clinic_site_urls';
const TTL_MS = 14 * 24 * 60 * 60 * 1000;

function docId(host) {
  const h = String(host || '').toLowerCase().replace(/^www\./, '');
  const encoded = encodeURIComponent(h).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

function normalizeEntry(raw) {
  if (typeof raw === 'string' && raw.trim()) {
    return {
      url: raw.trim(),
      extractionMethod: '',
      procedureFamily: '',
      canonicalProcedure: '',
      lastSuccessAt: '',
      successCount: 0,
      failureCount: 0,
    };
  }
  if (raw && typeof raw === 'object') {
    const url = String(raw.url || '').trim();
    if (!url) return null;
    return {
      url,
      extractionMethod: String(raw.extractionMethod || '').trim(),
      procedureFamily: String(raw.procedureFamily || '').trim(),
      canonicalProcedure: String(raw.canonicalProcedure || '').trim(),
      lastSuccessAt: String(raw.lastSuccessAt || '').trim(),
      successCount: Number(raw.successCount || 0) || 0,
      failureCount: Number(raw.failureCount || 0) || 0,
    };
  }
  return null;
}

async function loadCachedSiteUrls(hostOrUrl) {
  const entries = await loadCachedSiteUrlEntries(hostOrUrl);
  return entries.map((e) => e.url);
}

async function loadCachedSiteUrlEntries(hostOrUrl) {
  const host = hostOf(hostOrUrl) || String(hostOrUrl || '')
      .toLowerCase()
      .replace(/^www\./, '')
      .trim();
  if (!host) return [];
  try {
    const snap = await admin.firestore().collection(COLLECTION).doc(docId(host)).get();
    if (!snap.exists) return [];
    const data = snap.data() || {};
    const updated = data.updatedAt && data.updatedAt.toDate
      ? data.updatedAt.toDate()
      : (data.updatedAtMs ? new Date(Number(data.updatedAtMs)) : null);
    if (updated && Date.now() - updated.getTime() > TTL_MS) return [];
    const out = [];
    const seen = new Set();
    for (const row of (Array.isArray(data.entries) ? data.entries : [])) {
      const e = normalizeEntry(row);
      if (e && !seen.has(e.url)) {
        seen.add(e.url);
        out.push(e);
      }
    }
    if (!out.length) {
      for (const u of (Array.isArray(data.urls) ? data.urls : [])) {
        const e = normalizeEntry(u);
        if (e && !seen.has(e.url)) {
          seen.add(e.url);
          out.push(e);
        }
      }
    }
    // Prefer successful procedure URLs first.
    out.sort((a, b) => {
      const as = Number(a.successCount || 0);
      const bs = Number(b.successCount || 0);
      if (bs !== as) return bs - as;
      return String(b.lastSuccessAt || '').localeCompare(String(a.lastSuccessAt || ''));
    });
    return out;
  } catch (e) {
    console.log(`[SITE URL CACHE] read error: ${e.message || e}`);
    return [];
  }
}

async function saveCachedSiteUrls({
  hostOrUrl,
  urls,
  procedure = '',
  city = '',
  clinicName = '',
  source = 'firecrawl',
  extractionMethod = '',
  procedureFamily = '',
  canonicalProcedure = '',
  success = null,
  entries = null,
}) {
  const host = hostOf(hostOrUrl) || String(hostOrUrl || '')
      .toLowerCase()
      .replace(/^www\./, '')
      .trim();
  const incoming = [];
  if (Array.isArray(entries) && entries.length) {
    for (const row of entries) {
      const e = normalizeEntry(row);
      if (e) incoming.push(e);
    }
  } else {
    for (const u of (urls || [])) {
      const e = normalizeEntry({
        url: u,
        extractionMethod,
        procedureFamily,
        canonicalProcedure: canonicalProcedure || procedure,
      });
      if (e) incoming.push(e);
    }
  }
  if (!host || !incoming.length) return;
  try {
    const ref = admin.firestore().collection(COLLECTION).doc(docId(host));
    const prev = await ref.get();
    const prevData = prev.exists ? (prev.data() || {}) : {};
    const prevEntries = [];
    for (const row of (Array.isArray(prevData.entries) ? prevData.entries : [])) {
      const e = normalizeEntry(row);
      if (e) prevEntries.push(e);
    }
    if (!prevEntries.length) {
      for (const u of (Array.isArray(prevData.urls) ? prevData.urls : [])) {
        const e = normalizeEntry(u);
        if (e) prevEntries.push(e);
      }
    }
    const mergedMap = new Map();
    for (const e of prevEntries) mergedMap.set(e.url, e);
    for (const e of incoming) {
      const prevE = mergedMap.get(e.url) || {};
      let successCount = Number(prevE.successCount || 0) || 0;
      let failureCount = Number(prevE.failureCount || 0) || 0;
      let lastSuccessAt = String(prevE.lastSuccessAt || '');
      if (success === true) {
        successCount += 1;
        lastSuccessAt = new Date().toISOString();
      } else if (success === false) {
        failureCount += 1;
      }
      mergedMap.set(e.url, {
        url: e.url,
        extractionMethod: e.extractionMethod || prevE.extractionMethod || '',
        procedureFamily: e.procedureFamily || prevE.procedureFamily || '',
        canonicalProcedure: e.canonicalProcedure || prevE.canonicalProcedure ||
            procedure || '',
        lastSuccessAt,
        successCount,
        failureCount,
      });
    }
    const merged = [...mergedMap.values()].slice(0, 60);
    await ref.set({
      host,
      clinicName: clinicName || '',
      city: city || '',
      lastProcedure: procedure || '',
      source: source || 'firecrawl',
      urls: merged.map((e) => e.url),
      entries: merged,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: Date.now(),
    }, {merge: true});
    console.log(`[SITE URL CACHE] saved ${merged.length} urls · ${host}`);
  } catch (e) {
    console.log(`[SITE URL CACHE] write error: ${e.message || e}`);
  }
}

module.exports = {
  loadCachedSiteUrls,
  loadCachedSiteUrlEntries,
  saveCachedSiteUrls,
  docId,
  COLLECTION,
};
