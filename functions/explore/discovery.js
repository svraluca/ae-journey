'use strict';

const {
  clinicIdentityRejectReason,
  isMarketplaceOrDirectoryHost,
  logDiscoveryReject,
} = require('./identity');
const {hostOf} = require('./parsePrice');
const {
  clinicWordForCity,
  buildSerpQuery,
  buildBroadProcedureDiscoveryQueries,
  serpHlGl,
} = require('./searchLocale');
const {searchOrganicResults} = require('./serpProvider');
const {looksLikeCountryMarketPriceMarketing} = require('./priceOwnership');

const MAX_PLACE_CANDIDATES = 24;
const PAGE_DELAY_MS = 2100;

/** Shared Places quota breaker across concurrent discovery tasks. */
let placesQuotaCircuitOpen = false;
let placesInFlight = 0;

function placesQuotaOpen() {
  return placesQuotaCircuitOpen;
}

function resetPlacesQuotaCircuit() {
  placesQuotaCircuitOpen = false;
}

function notePlacesQuotaFailure(statusCode, body = '') {
  const blob = `${statusCode} ${body}`.toUpperCase();
  if (Number(statusCode) === 429 ||
      /RESOURCE_EXHAUSTED|RATE_LIMIT|QUOTA/.test(blob)) {
    if (!placesQuotaCircuitOpen) {
      placesQuotaCircuitOpen = true;
      console.log(
          `[PLACE] circuit breaker ON · HTTP ${statusCode} · ` +
          `inFlight=${placesInFlight} may finish`);
    }
  }
}

function tryAcquirePlacesPermit() {
  if (placesQuotaCircuitOpen) return false;
  placesInFlight++;
  return true;
}

function releasePlacesPermit() {
  if (placesInFlight > 0) placesInFlight--;
}

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
  if (placesQuotaCircuitOpen && placesInFlight <= 0) {
    return {results: [], nextPageToken: ''};
  }
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
    const text = await res.text().catch(() => '');
    notePlacesQuotaFailure(res.status, text);
    console.log(`[PLACE] textsearch HTTP ${res.status}`);
    return {results: [], nextPageToken: ''};
  }
  const json = await res.json();
  if (json.error) {
    notePlacesQuotaFailure(
        res.status, `${json.error.status || ''} ${json.error.message || ''}`);
    console.log(
        `[PLACE] textsearch error · ${json.error.status} · ${json.error.message}`);
    return {results: [], nextPageToken: ''};
  }
  return {
    results: Array.isArray(json.places) ? json.places.map(toLegacySearchRow) : [],
    nextPageToken: String(json.nextPageToken || ''),
  };
}

function placeRawScore(row) {
  const rating = Number(row.rating || 0);
  const reviews = Number(row.user_ratings_total || row.reviews || 0);
  return rating * Math.log10(reviews + 10);
}

async function searchPlaces({
  city,
  procedure,
  apiKey,
  maxResults = 8,
  skipPlaceIds = new Set(),
  queries = null,
  paginate = false,
  maxRawHits = 0,
  countryCode = '',
  verifiedVisibleCount = 0,
  deep = false,
} = {}) {
  if (!apiKey) return [];
  if (!tryAcquirePlacesPermit()) {
    console.log('[PLACE] circuit open · skip new searchPlaces');
    return [];
  }
  try {
  const {discoveryQueriesForProcedure} = require('./brightdata/discoveryQueries');
  const qList = [];
  const add = (q) => {
    const t = String(q || '').replace(/\s+/g, ' ').trim();
    if (t && !qList.includes(t)) qList.push(t);
  };
  add(`${clinicWordForCity(city, {countryCode})} ${procedure} ${city}`);
  const extra = Array.isArray(queries) && queries.length
    ? queries
    : discoveryQueriesForProcedure(procedure, city, {countryCode});
  for (const q of extra) add(q);
  // Adaptive breadth: start narrow; expand only while underfilled.
  const verified = Number(verifiedVisibleCount) || 0;
  let queryCap = Math.min(2, qList.length);
  if (verified < 2) queryCap = Math.min(4, qList.length);
  if (deep || verified < 4) {
    queryCap = Math.min(deep ? 6 : 4, qList.length);
  }
  const rawCap = maxRawHits || MAX_PLACE_CANDIDATES;
  const pagesPerQuery = 1;
  console.log(
      `[PRICE DISCOVERY] ${city} · ${procedure} · queries=${queryCap}` +
      ` · verifiedHint=${verified}` +
      `${paginate ? ' · paginate' : ''}${deep ? ' · deep' : ''}`);
  const rawHits = [];
  const seenIds = new Set();
  for (let qi = 0; qi < queryCap && rawHits.length < rawCap; qi++) {
    if (placesQuotaCircuitOpen && qi > 0) break;
    const q = qList[qi];
    let pageToken = '';
    for (let page = 0; page < pagesPerQuery && rawHits.length < rawCap; page++) {
      if (page > 0) {
        if (!pageToken) break;
        await sleep(PAGE_DELAY_MS);
      }
      const pageJson = await fetchTextSearchPage({
        query: q,
        apiKey,
        pageToken,
      });
      pageToken = pageJson.nextPageToken;
      console.log(
          `[PLACE] textsearch q${qi + 1}p${page + 1} · ${pageJson.results.length} rows`);
      for (const row of pageJson.results) {
        if (rawHits.length >= rawCap) break;
        const placeId = String(row.place_id || '').trim();
        const name = String(row.name || '').trim();
        if (!placeId || seenIds.has(placeId)) continue;
        seenIds.add(placeId);
        if (skipPlaceIds.has(placeId)) {
          logDiscoveryReject('duplicate_known', {placeId, name});
          continue;
        }
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
  rawHits.sort((a, b) => placeRawScore(b) - placeRawScore(a));

  const out = [];
  const seenHosts = new Set();
  const seenNames = new Set();
  for (const row of rawHits) {
    if (out.length >= maxResults) break;
    if (placesQuotaCircuitOpen && out.length > 0 && placesInFlight <= 1) {
      // Still allow this wave to finish details it already queued.
    }
    const details = await placeDetails(row.place_id, apiKey, {continueInFlight: true});
    if (!details || !details.website) continue;
    if (isMarketplaceOrDirectoryHost(details.website)) {
      logDiscoveryReject('marketplace_without_provider', {
        placeId: details.placeId,
        name: details.name,
      });
      continue;
    }
    const host = hostOf(details.website);
    if (host && seenHosts.has(host)) continue;
    const nn = String(details.name || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
    if (nn && seenNames.has(nn)) continue;
    if (host) seenHosts.add(host);
    if (nn) seenNames.add(nn);
    console.log(`[PLACE] ${details.name} · official=${host}`);
    out.push(details);
  }
  return out;
  } finally {
    releasePlacesPermit();
  }
}

async function placeDetails(placeId, apiKey, {continueInFlight = false} = {}) {
  if (!placeId) return null;
  if (placesQuotaCircuitOpen && !continueInFlight && placesInFlight <= 0) {
    return null;
  }
  const id = String(placeId).replace(/^places\//, '');
  const res = await fetch(
      `https://places.googleapis.com/v1/places/${encodeURIComponent(id)}`, {
        headers: {
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
            'id,displayName,websiteUri,googleMapsUri,rating,userRatingCount,' +
            'location,formattedAddress,internationalPhoneNumber,nationalPhoneNumber',
        },
      });
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    notePlacesQuotaFailure(res.status, text);
    return null;
  }
  const r = await res.json();
  if (!r || r.error || !r.id) {
    if (r && r.error) {
      notePlacesQuotaFailure(429, `${r.error.status || ''} ${r.error.message || ''}`);
    }
    return null;
  }
  const name = displayNameOf(r);
  const reason = clinicIdentityRejectReason(name);
  if (reason) {
    logDiscoveryReject(reason, {placeId: id, name});
    return null;
  }
  const loc = r.location || {};
  return {
    name,
    website: String(r.websiteUri || '').trim(),
    mapsUrl: String(r.googleMapsUri || '').trim(),
    placeId: id,
    rating: Number(r.rating || 0),
    reviews: Number(r.userRatingCount || 0),
    lat: Number(loc.latitude || 0),
    lng: Number(loc.longitude || 0),
    address: String(r.formattedAddress || '').trim(),
    phone: String(
        r.internationalPhoneNumber || r.nationalPhoneNumber || '').trim(),
  };
}

async function findPlaceByName({name, city, apiKey}) {
  if (!apiKey || !name) return null;
  const page = await fetchTextSearchPage({
    query: `${name} ${city}`.trim(),
    apiKey,
  });
  const first = Array.isArray(page.results) ? page.results[0] : null;
  const foundId = first && first.place_id;
  if (!foundId) return null;
  return placeDetails(foundId, apiKey);
}

/**
 * Discovery: which clinic pages to fetch. Returns URLs, titles and snippets
 * only — the price of each page is decided later by fetching that page.
 */
async function searchSerpUrls({
  city,
  procedure,
  websiteHost,
  apiKey = '',
  serperApiKey = '',
  dataForSeoLogin = '',
  dataForSeoPassword = '',
  maxResults = 5,
  countryCode = '',
}) {
  const q = buildSerpQuery({city, procedure, websiteHost, countryCode});
  const englishQuery = /\bprices?\b/i.test(q) && !websiteHost;
  const {hl, gl} = serpHlGl(city, {englishQuery, countryCode});
  const hits = await searchOrganicResults({
    query: q,
    hl,
    gl,
    city,
    serperApiKey,
    dataForSeoLogin,
    dataForSeoPassword,
    serpApiKey: apiKey,
  });
  const urls = [];
  for (const r of hits) {
    const link = String(r.url || '').trim();
    const title = String(r.title || '').trim();
    if (!link) continue;
    const reason = clinicIdentityRejectReason(title);
    if (reason && !websiteHost) continue;
    urls.push({url: link, title, snippet: String(r.snippet || '')});
    if (urls.length >= maxResults) break;
  }
  return urls;
}

/**
 * Resolve a broad SERP hit into a clinic lead — never use the SERP title as
 * the final identity when it looks like a procedure/guide headline.
 */
function resolveBroadSerpClinicCandidate(result, {city = ''} = {}) {
  const link = String(result && result.url || '').trim();
  const title = String(result && result.title || '').trim();
  if (!link) return null;
  const host = hostOf(link);
  if (!host) return null;
  if (isMarketplaceOrDirectoryHost(host)) {
    return {
      name: '',
      officialWebsite: '',
      websiteHost: host,
      sourceUrl: link,
      title,
      snippet: String(result && result.snippet || ''),
      marketplaceLead: true,
      discoveryProvider: 'serp_broad',
    };
  }
  const reason = clinicIdentityRejectReason(title);
  const brandFromHost = host
      .replace(/^www\./, '')
      .split('.')[0]
      .replace(/[-_]+/g, ' ')
      .trim();
  let name = brandFromHost;
  if (!reason && title && !looksLikeCountryMarketPriceMarketing(title) &&
      !/^(?:breast|botox|filler|rhinoplast|procedures?\s+in)/i.test(title)) {
    const parts = title.split(/\s[\|\-–—]\s+|:\s+/).map((s) => s.trim())
        .filter((s) => s.length >= 3 && s.length <= 60);
    for (const part of parts) {
      if (!clinicIdentityRejectReason(part) &&
          !looksLikeCountryMarketPriceMarketing(part)) {
        name = part;
        break;
      }
    }
  }
  if (!name || clinicIdentityRejectReason(name)) {
    name = brandFromHost;
  }
  if (!name || clinicIdentityRejectReason(name)) return null;
  return {
    name,
    officialWebsite: `https://${host}`,
    websiteHost: host,
    sourceUrl: link,
    title,
    snippet: String(result && result.snippet || ''),
    cityMatch: true,
    identityVerified: false,
    discoveryProvider: 'serp_broad',
  };
}

/**
 * Broad web discovery (no site:) — finds clinic domains for later verifyPlace.
 */
async function discoverBroadSerpClinicCandidates({
  city,
  procedure,
  countryCode = '',
  serperApiKey = '',
  dataForSeoLogin = '',
  dataForSeoPassword = '',
  apiKey = '',
  maxResults = 8,
  maxQueries = 4,
} = {}) {
  const queries = buildBroadProcedureDiscoveryQueries({
    city, procedure, countryCode, maxQueries,
  });
  const out = [];
  const seenHosts = new Set();
  for (const q of queries) {
    if (out.length >= maxResults) break;
    const englishQuery = /\bprices?\b/i.test(q);
    const {hl, gl} = serpHlGl(city, {englishQuery, countryCode});
    const hits = await searchOrganicResults({
      query: q,
      hl,
      gl,
      city,
      serperApiKey,
      dataForSeoLogin,
      dataForSeoPassword,
      serpApiKey: apiKey,
    });
    for (const hit of hits) {
      if (out.length >= maxResults) break;
      const resolved = resolveBroadSerpClinicCandidate(hit, {city});
      if (!resolved || resolved.marketplaceLead) continue;
      const host = String(resolved.websiteHost || '').toLowerCase();
      if (!host || seenHosts.has(host)) continue;
      seenHosts.add(host);
      out.push(resolved);
    }
  }
  return out;
}

module.exports = {
  searchPlaces,
  searchSerpUrls,
  discoverBroadSerpClinicCandidates,
  resolveBroadSerpClinicCandidate,
  placeDetails,
  findPlaceByName,
  clinicWordForCity,
  placesQuotaOpen,
  resetPlacesQuotaCircuit,
  notePlacesQuotaFailure,
  tryAcquirePlacesPermit,
  releasePlacesPermit,
};
