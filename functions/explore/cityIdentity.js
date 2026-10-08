'use strict';

/**
 * Worldwide city identity helpers for Functions.
 * Name-only keys are forbidden for new coverage / discovery / cache docs.
 */

const crypto = require('crypto');

const PEER_CITY_MARKS = [
  {key: 'timisoara', aliases: ['timisoara', 'timișoara', 'timişoara']},
  {key: 'iasi', aliases: ['iasi', 'iași', 'iaşi']},
  {key: 'brasov', aliases: ['brasov', 'brașov', 'braşov']},
  {key: 'cluj', aliases: ['cluj', 'cluj-napoca', 'cluj napoca']},
  {key: 'bucharest', aliases: ['bucharest', 'bucuresti', 'bucurești']},
  {key: 'chisinau', aliases: ['chisinau', 'chișinău', 'kishinev']},
  {key: 'constanta', aliases: ['constanta', 'constanța']},
  {key: 'paris', aliases: ['paris']},
  {key: 'london', aliases: ['london']},
  {key: 'springfield', aliases: ['springfield']},
];

function foldCityText(raw) {
  const s = String(raw || '')
      .replace(/\u00a0/g, ' ')
      .trim()
      .toLowerCase()
      .replace(/ı/g, 'i')
      .replace(/İ/g, 'i')
      .replace(/ß/g, 'ss')
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '');
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçýăâîșşțţğ';
  const to = 'aaaaaaeeeeiiiiooooouuuuncyaaissttg';
  let out = '';
  for (const ch of s) {
    const i = from.indexOf(ch);
    out += i >= 0 ? to[i] : ch;
  }
  return out;
}

function canonicalCityName(city) {
  const folded = foldCityText(city);
  if (!folded) return '';
  const packed = folded.replace(/[\s_-]+/g, '');
  for (const peer of PEER_CITY_MARKS) {
    if (folded === peer.key || packed === peer.key.replace(/\s+/g, '')) {
      return peer.key;
    }
    for (const alias of peer.aliases) {
      const a = foldCityText(alias);
      if (!a) continue;
      if (folded === a || packed === a.replace(/[\s_-]+/g, '')) return peer.key;
    }
  }
  return folded;
}

function geoBucket(deg) {
  return Math.round(Number(deg) * 100);
}

function deterministicFallbackCityId({
  countryCode = '',
  adminArea = '',
  canonicalName = '',
  latitude,
  longitude,
} = {}) {
  const cc = String(countryCode || '').trim().toUpperCase();
  const admin = foldCityText(adminArea).replace(/\s+/g, '-');
  const name = foldCityText(canonicalName).replace(/\s+/g, '-');
  const geo = (latitude != null && longitude != null &&
      Number.isFinite(Number(latitude)) && Number.isFinite(Number(longitude)))
    ? `${geoBucket(latitude)}_${geoBucket(longitude)}`
    : 'nogeo';
  const raw = `${cc}|${admin}|${name}|${geo}`;
  const digest = crypto.createHash('sha1').update(raw).digest('hex').slice(0, 16);
  if (!cc || geo === 'nogeo') {
    // Unresolved: never collide with a resolved same-name city.
    return `unresolved_${digest}`;
  }
  return `geo_${cc}_${digest}`;
}

function buildCityId({
  placeId = '',
  countryCode = '',
  adminArea = '',
  canonicalName = '',
  latitude,
  longitude,
} = {}) {
  const pid = String(placeId || '').trim();
  if (pid) {
    return `place_${pid.replace(/[^a-zA-Z0-9_-]/g, '_')}`;
  }
  return deterministicFallbackCityId({
    countryCode,
    adminArea,
    canonicalName,
    latitude,
    longitude,
  });
}

function isResolvedCityId(cityId) {
  const id = String(cityId || '').trim();
  if (!id) return false;
  if (id.startsWith('unresolved_')) return false;
  return id.startsWith('place_') || id.startsWith('geo_');
}

/** City-center fallbacks when client omits Places lat/lng (not clinic lists). */
const APPROX_CITY_COORDS = {
  ankara: {lat: 39.9334, lng: 32.8597, countryCode: 'TR'},
  istanbul: {lat: 41.0082, lng: 28.9784, countryCode: 'TR'},
  izmir: {lat: 38.4237, lng: 27.1428, countryCode: 'TR'},
  antalya: {lat: 36.8969, lng: 30.7133, countryCode: 'TR'},
  bursa: {lat: 40.1885, lng: 29.0610, countryCode: 'TR'},
  london: {lat: 51.5072, lng: -0.1276, countryCode: 'GB'},
  paris: {lat: 48.8566, lng: 2.3522, countryCode: 'FR'},
  dubai: {lat: 25.2048, lng: 55.2708, countryCode: 'AE'},
  bucharest: {lat: 44.4268, lng: 26.1025, countryCode: 'RO'},
  bucuresti: {lat: 44.4268, lng: 26.1025, countryCode: 'RO'},
  miami: {lat: 25.7617, lng: -80.1918, countryCode: 'US'},
  barcelona: {lat: 41.3851, lng: 2.1734, countryCode: 'ES'},
};

function approxCoordsForCity(city) {
  const key = foldCityText(city).replace(/[\s_-]+/g, '');
  return APPROX_CITY_COORDS[key] || null;
}

/**
 * Resolve cityId preferring placeId / explicit geo, then known city centers.
 */
function resolveCityIdWithFallback({
  placeId = '',
  countryCode = '',
  adminArea = '',
  canonicalName = '',
  latitude,
  longitude,
  city = '',
} = {}) {
  let lat = latitude;
  let lng = longitude;
  let cc = String(countryCode || '').trim().toUpperCase();
  if ((lat == null || lng == null || !cc) && city) {
    const approx = approxCoordsForCity(city);
    if (approx) {
      if (lat == null) lat = approx.lat;
      if (lng == null) lng = approx.lng;
      if (!cc) cc = approx.countryCode;
    }
  }
  return buildCityId({
    placeId,
    countryCode: cc,
    adminArea,
    canonicalName: canonicalName || canonicalCityName(city),
    latitude: lat,
    longitude: lng,
  });
}

function urlHasCityToken(url, cityToken) {
  const u = String(url || '').toLowerCase();
  const token = foldCityText(cityToken).replace(/[\s_-]+/g, '');
  if (!u || token.length < 4) return false;
  const path = u.replace(/^https?:\/\//, '');
  const packed = path.replace(/[\s_-]+/g, '');
  return packed.includes(token) ||
      new RegExp(`(?:^|[/_.-])${token}(?:[/_.-]|$)`, 'i').test(path);
}

/**
 * True when URL path clearly belongs to another peer city than [city].
 * e.g. /preturi/iasi while searching Timisoara.
 */
function exploreUrlConflictsWithSearchCity(url, city) {
  const search = canonicalCityName(city);
  const cityLo = foldCityText(city);
  if (!search && !cityLo) return false;
  for (const peer of PEER_CITY_MARKS) {
    if (search && peer.key === search) continue;
    if (!search && (cityLo.includes(peer.key) ||
        cityLo.includes(peer.key.replace(/\s+/g, '')))) {
      continue;
    }
    for (const alias of peer.aliases) {
      const a = foldCityText(alias);
      if (a.length < 4) continue;
      if (!/^[a-z0-9 \-]+$/.test(a)) continue;
      if (urlHasCityToken(url, a)) return true;
    }
  }
  return false;
}

/** Boost when URL path contains the searched city token. */
function urlMatchesSearchCity(url, city) {
  const search = canonicalCityName(city) || foldCityText(city);
  if (!search) return false;
  return urlHasCityToken(url, search);
}

/**
 * Legacy name-keyed docs may be reused only when geography matches.
 * Otherwise: do not show; queue for migration; start discovery.
 */
function legacyRecordMatchesResolvedCity(legacy = {}, resolved = {}) {
  const legacyCc = String(legacy.countryCode || legacy.country || '')
      .trim().toUpperCase();
  const resolvedCc = String(resolved.countryCode || '').trim().toUpperCase();
  if (legacyCc && resolvedCc && legacyCc !== resolvedCc) return false;

  const legacyAdmin = foldCityText(legacy.adminArea || legacy.region || '');
  const resolvedAdmin = foldCityText(resolved.adminArea || '');
  if (legacyAdmin && resolvedAdmin && legacyAdmin !== resolvedAdmin) {
    // Same country different admin (Paris TX vs Paris IL) — reject.
    if (legacyCc && resolvedCc && legacyCc === resolvedCc) return false;
  }

  const latA = Number(legacy.latitude ?? legacy.lat);
  const lngA = Number(legacy.longitude ?? legacy.lng);
  const latB = Number(resolved.latitude);
  const lngB = Number(resolved.longitude);
  if ([latA, lngA, latB, lngB].every(Number.isFinite) &&
      Math.abs(latA) + Math.abs(lngA) > 0 &&
      Math.abs(latB) + Math.abs(lngB) > 0) {
    const d = haversineKm(latA, lngA, latB, lngB);
    if (d > 40) return false;
    return true;
  }

  // Branch address must mention resolved city or country when present.
  const addr = foldCityText(
      `${legacy.address || ''} ${legacy.branchAddress || ''} ${legacy.city || ''}`);
  const name = foldCityText(resolved.canonicalName || resolved.displayName || '');
  if (name && addr && !addr.includes(name.replace(/\s+/g, '')) &&
      !addr.includes(name)) {
    if (legacyCc && resolvedCc && legacyCc === resolvedCc && !resolvedAdmin) {
      // Weak same-country name match without admin/coords — insufficient proof.
      return false;
    }
    if (!legacyCc || !resolvedCc) return false;
  }

  // Without country/coords/admin proof, refuse legacy reuse.
  if (!legacyCc || !resolvedCc) return false;
  if (legacyCc === resolvedCc && name &&
      (addr.includes(name) || foldCityText(legacy.city || '') === name)) {
    return true;
  }
  return false;
}

function haversineKm(lat1, lon1, lat2, lon2) {
  const r = 6371;
  const toRad = (d) => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}

function coverageDocId({cityId, procedure}) {
  const id = String(cityId || '').trim();
  if (!id || id.startsWith('unresolved_')) {
    throw new Error('coverage_requires_resolved_cityId');
  }
  const proc = String(procedure || '').trim().toLowerCase();
  const raw = `${id}|${proc}`;
  const encoded = encodeURIComponent(raw).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

/**
 * Normalize Explore locality fields from a callable `data` payload.
 * Prefer explicit client fields; fall back to city→country heuristics only
 * when countryCode is missing.
 */
function normalizeExploreLocality(data = {}) {
  const src = data && typeof data === 'object' ? data : {};
  const city = String(src.city || src.displayName || '').trim();
  const cityId = String(src.cityId || '').trim();
  let countryCode = String(src.countryCode || '').trim().toUpperCase();
  if (countryCode === 'UK') countryCode = 'GB';
  if (!countryCode && city) {
    try {
      const {countryCodeForCity} = require('./marketplaces/locationFormat');
      countryCode = String(countryCodeForCity(city) || '').trim().toUpperCase();
    } catch (_) {
      // ignore — keep empty
    }
  }
  const latRaw = src.latitude;
  const lngRaw = src.longitude;
  const latitude = latRaw != null && Number.isFinite(Number(latRaw))
    ? Number(latRaw)
    : null;
  const longitude = lngRaw != null && Number.isFinite(Number(lngRaw))
    ? Number(lngRaw)
    : null;
  const languageCodes = Array.isArray(src.languageCodes)
    ? src.languageCodes.map((e) => String(e || '').trim()).filter(Boolean)
    : [];
  return {
    city,
    cityId,
    countryCode: countryCode || '',
    countryName: String(src.countryName || '').trim(),
    adminArea: String(src.adminArea || '').trim(),
    placeId: String(src.placeId || '').trim(),
    latitude,
    longitude,
    languageCodes,
    currencyCode: String(src.currencyCode || '').trim().toUpperCase(),
    canonicalName: String(src.canonicalName || '').trim(),
    localName: String(src.localName || '').trim(),
  };
}

module.exports = {
  PEER_CITY_MARKS,
  foldCityText,
  canonicalCityName,
  deterministicFallbackCityId,
  buildCityId,
  isResolvedCityId,
  approxCoordsForCity,
  resolveCityIdWithFallback,
  exploreUrlConflictsWithSearchCity,
  urlMatchesSearchCity,
  urlHasCityToken,
  legacyRecordMatchesResolvedCity,
  coverageDocId,
  normalizeExploreLocality,
  haversineKm,
};
