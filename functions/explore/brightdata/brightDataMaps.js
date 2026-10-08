'use strict';

const {brightDataApiKey, brightDataConfigured} = require('./brightDataClient');
const {useBrightData} = require('../featureFlags');

/**
 * Bright Data Google Maps dataset — BACKGROUND seeding only.
 * Interactive Explore must never await a large Maps dataset run.
 *
 * API: datasets/v3 trigger + snapshot poll.
 * https://docs.brightdata.com/datasets/scrapers-library
 */

const TRIGGER_BASE = 'https://api.brightdata.com/datasets/v3/trigger';
const SNAPSHOT_BASE = 'https://api.brightdata.com/datasets/v3/snapshot';

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function datasetId() {
  return String(process.env.BRIGHTDATA_GOOGLE_MAPS_DATASET_ID || '').trim();
}

/**
 * Build keyword inputs for Bright Data Maps scraper.
 */
function mapsKeywordInputs({city, queries = [], limitPerQuery = 20} = {}) {
  const display = String(city || '').trim();
  const out = [];
  for (const q of queries) {
    const keyword = String(q || '').trim();
    if (!keyword) continue;
    out.push({
      keyword,
      location: display,
      country: '',
      zoom: '12',
      limit: limitPerQuery,
    });
  }
  return out;
}

function normalizeMapsRow(row) {
  if (!row || typeof row !== 'object') return null;
  const name = String(row.name || row.title || row.business_name || '').trim();
  if (!name) return null;
  const website = String(
      row.website || row.site || row.url || row.domain || '').trim();
  const placeId = String(
      row.place_id || row.placeId || row.google_id || row.cid || '').trim();
  const address = String(
      row.address || row.full_address || row.street || '').trim();
  const lat = Number(row.latitude || row.lat || (row.location && row.location.lat) || 0) || 0;
  const lng = Number(row.longitude || row.lng || (row.location && row.location.lng) || 0) || 0;
  return {
    name,
    placeId,
    address,
    city: String(row.city || '').trim(),
    country: String(row.country || row.country_code || '').trim(),
    lat,
    lng,
    rating: Number(row.rating || row.stars || 0) || 0,
    reviews: Number(
        row.reviews_count || row.review_count || row.reviews || 0) || 0,
    category: String(row.category || row.type || row.categories || '').trim(),
    website,
    mapsUrl: String(row.link || row.maps_url || row.google_maps_url || '').trim(),
    discovery_provider: 'brightdata_maps',
  };
}

async function triggerMapsDataset(inputs) {
  const key = brightDataApiKey();
  const id = datasetId();
  if (!key || !id || !inputs.length) return null;
  const url = `${TRIGGER_BASE}?dataset_id=${encodeURIComponent(id)}&format=json`;
  console.log(`[BRIGHTDATA MAPS] trigger · inputs=${inputs.length}`);
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(inputs),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    console.log(`[BRIGHTDATA MAPS] trigger HTTP ${res.status} · ${body.slice(0, 160)}`);
    return null;
  }
  const json = await res.json().catch(() => ({}));
  const snapshotId = String(
      json.snapshot_id || json.snapshotId || json.id || '').trim();
  if (!snapshotId) {
    console.log('[BRIGHTDATA MAPS] missing snapshot_id');
    return null;
  }
  return snapshotId;
}

async function pollMapsSnapshot(snapshotId, {maxWaitMs = 420000} = {}) {
  const key = brightDataApiKey();
  if (!key || !snapshotId) return [];
  const deadline = Date.now() + maxWaitMs;
  while (Date.now() < deadline) {
    const url = `${SNAPSHOT_BASE}/${encodeURIComponent(snapshotId)}?format=json`;
    const res = await fetch(url, {
      headers: {Authorization: `Bearer ${key}`},
    });
    if (res.status === 202) {
      await sleep(8000);
      continue;
    }
    if (!res.ok) {
      console.log(`[BRIGHTDATA MAPS] snapshot HTTP ${res.status}`);
      return [];
    }
    const data = await res.json().catch(() => null);
    const rows = Array.isArray(data) ? data
      : (data && Array.isArray(data.data) ? data.data : []);
    console.log(`[BRIGHTDATA MAPS] rows=${rows.length}`);
    return rows.map(normalizeMapsRow).filter(Boolean);
  }
  console.log('[BRIGHTDATA MAPS] snapshot timeout');
  return [];
}

/**
 * Background-only: discover clinic candidates via Bright Data Maps dataset.
 */
async function discoverMapsClinics({city, queries = [], limitPerQuery = 20} = {}) {
  if (!useBrightData() || !brightDataConfigured() || !datasetId()) {
    console.log('[BRIGHTDATA MAPS] not configured — skip');
    return [];
  }
  const inputs = mapsKeywordInputs({city, queries, limitPerQuery});
  if (!inputs.length) return [];
  const snapshotId = await triggerMapsDataset(inputs);
  if (!snapshotId) return [];
  return pollMapsSnapshot(snapshotId);
}

module.exports = {
  discoverMapsClinics,
  normalizeMapsRow,
  mapsKeywordInputs,
  datasetId,
};
