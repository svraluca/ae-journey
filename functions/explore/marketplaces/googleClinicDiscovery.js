'use strict';

const {
  clinicIdentityRejectReason,
  logDiscoveryReject,
} = require('../identity');
const {clinicWordForCity} = require('../searchLocale');
const {placeDetails} = require('../discovery');
const {AESTHETIC_PLACE_QUERIES, FRESHA_MAX_RESULTS} = require('./constants');
const {cityDisplayName} = require('./locationFormat');

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function displayNameOf(place) {
  const n = place && place.displayName;
  if (n && typeof n === 'object') return String(n.text || '').trim();
  return String((place && place.name) || '').trim();
}

function toLegacySearchRow(place) {
  const loc = (place && place.location) || {};
  return {
    place_id: String((place && place.id) || ''),
    name: displayNameOf(place),
    formatted_address: String((place && place.formattedAddress) || ''),
    rating: Number((place && place.rating) || 0),
    user_ratings_total: Number((place && place.userRatingCount) || 0),
    geometry: {
      location: {
        lat: Number(loc.latitude || 0),
        lng: Number(loc.longitude || 0),
      },
    },
    types: Array.isArray(place && place.types) ? place.types : [],
  };
}

async function fetchTextSearchPage({query, apiKey, pageToken = ''}) {
  const body = {textQuery: query, maxResultCount: 20};
  if (pageToken) body.pageToken = pageToken;
  const res = await fetch('https://places.googleapis.com/v1/places:searchText', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask':
        'places.id,places.displayName,places.formattedAddress,' +
        'places.rating,places.userRatingCount,places.location,places.types,' +
        'nextPageToken',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    console.log(`[FRESHA PLACES] textsearch HTTP ${res.status}`);
    return {results: [], nextPageToken: ''};
  }
  const json = await res.json();
  if (json.error) {
    console.log(
        `[FRESHA PLACES] textsearch error · ${json.error.status} · ${json.error.message}`);
    return {results: [], nextPageToken: ''};
  }
  return {
    results: Array.isArray(json.places) ? json.places.map(toLegacySearchRow) : [],
    nextPageToken: String(json.nextPageToken || ''),
  };
}

/**
 * Google Places is the authority for medical-aesthetic clinic discovery.
 * Fresha is never used to decide medical relevance.
 */
async function discoverAestheticClinics({
  city,
  apiKey,
  maxResults = FRESHA_MAX_RESULTS,
} = {}) {
  if (!apiKey) return [];
  const display = cityDisplayName(city);
  const clinicWord = clinicWordForCity(city);
  const seen = new Set();
  const rawHits = [];

  for (const topic of AESTHETIC_PLACE_QUERIES) {
    if (rawHits.length >= maxResults * 2) break;
    const q = `${clinicWord} ${topic} ${display}`.trim();
    console.log(`[FRESHA PLACES] query · ${q}`);
    let pageToken = '';
    for (let page = 0; page < 1; page++) {
      if (page > 0) {
        if (!pageToken) break;
        await sleep(2100);
      }
      const pageJson = await fetchTextSearchPage({
        query: q,
        apiKey,
        pageToken,
      });
      pageToken = pageJson.nextPageToken;
      for (const row of pageJson.results) {
        const placeId = String(row.place_id || '').trim();
        const name = String(row.name || '').trim();
        if (!placeId || seen.has(placeId)) continue;
        seen.add(placeId);
        const reason = clinicIdentityRejectReason(name);
        if (reason) {
          logDiscoveryReject(reason, {placeId, name});
          continue;
        }
        rawHits.push(row);
      }
      if (!pageToken) break;
    }
  }

  const out = [];
  for (const row of rawHits) {
    if (out.length >= maxResults) break;
    const details = await placeDetails(row.place_id, apiKey);
    if (!details || !details.placeId) continue;
    // Website optional — Fresha may be the booking menu.
    out.push(details);
  }
  console.log(`[FRESHA PLACES] clinics=${out.length} · ${display}`);
  return out;
}

module.exports = {
  discoverAestheticClinics,
};
