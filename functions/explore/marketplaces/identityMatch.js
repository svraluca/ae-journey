'use strict';

const {
  namesLookLikeSameProvider,
  packedCanonicalClinicName,
  clinicIdentityRejectReason,
} = require('../identity');
const {placeDetails, findPlaceByName} = require('../discovery');

function haversineMeters(aLat, aLng, bLat, bLng) {
  const toRad = (d) => (d * Math.PI) / 180;
  const R = 6371000;
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const lat1 = toRad(aLat);
  const lat2 = toRad(bLat);
  const h = Math.sin(dLat / 2) ** 2 +
      Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

function normalizePhone(raw) {
  return String(raw || '').replace(/\D/g, '');
}

function phonesMatch(a, b) {
  const pa = normalizePhone(a);
  const pb = normalizePhone(b);
  if (!pa || !pb) return false;
  if (pa === pb) return true;
  const shortA = pa.slice(-9);
  const shortB = pb.slice(-9);
  return shortA.length >= 8 && shortA === shortB;
}

function addressOverlap(a, b) {
  const na = String(a || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const nb = String(b || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  if (!na || !nb) return false;
  const tokensA = na.split(/\s+/).filter((t) => t.length >= 3);
  if (!tokensA.length) return false;
  let hits = 0;
  for (const t of tokensA) {
    if (nb.includes(t)) hits += 1;
  }
  return hits >= Math.min(2, tokensA.length);
}

/**
 * Strong Google Places match for a Fresha venue before verified-pool entry.
 */
async function matchFreshaVenueToGoogle(venue, {city, apiKey} = {}) {
  if (!venue || !apiKey) {
    return {strong: false, place: null, reason: 'missing_api_or_venue'};
  }
  const name = String(venue.name || '').trim();
  if (!name || clinicIdentityRejectReason(name)) {
    return {strong: false, place: null, reason: 'invalid_name'};
  }

  let place = await findPlaceByName({
    name,
    city: city || venue.city || '',
    apiKey,
  });

  // Retry with street + city when name-only is ambiguous.
  if (!place && venue.street) {
    place = await findPlaceByName({
      name: `${name} ${venue.street}`,
      city: city || venue.city || '',
      apiKey,
    });
  }

  if (!place || !place.placeId) {
    return {strong: false, place: null, reason: 'no_google_candidate'};
  }

  // Enrich with phone when available.
  let details = place;
  try {
    const full = await placeDetails(place.placeId, apiKey);
    if (full && full.placeId) details = {...place, ...full};
  } catch (_) {
    // placeDetails already returned base fields from findPlaceByName path.
  }

  const nameOk = namesLookLikeSameProvider(name, details.name) ||
      packedCanonicalClinicName(name) === packedCanonicalClinicName(details.name);
  if (!nameOk) {
    return {strong: false, place: details, reason: 'name_mismatch'};
  }

  const vLat = Number(venue.latitude || 0);
  const vLng = Number(venue.longitude || 0);
  const pLat = Number(details.lat || 0);
  const pLng = Number(details.lng || 0);
  const geoOk = vLat && vLng && pLat && pLng &&
      haversineMeters(vLat, vLng, pLat, pLng) <= 450;

  const addrOk = addressOverlap(venue.address || venue.street, details.address);
  const phoneOk = phonesMatch(venue.phone, details.phone || details.international_phone_number);

  const signals = [geoOk, addrOk, phoneOk].filter(Boolean).length;
  // Strong: normalized name match plus geo, address, or phone corroboration.
  const strong = nameOk && (geoOk || addrOk || phoneOk);

  if (!strong) {
    return {
      strong: false,
      place: details,
      reason: nameOk ? (signals ? 'insufficient_signals' : 'weak_name_only')
        : 'name_mismatch',
    };
  }

  console.log(
      `[FRESHA MATCH] venue → Google place · "${name}" → ${details.placeId}`);
  return {strong: true, place: details, reason: 'strong'};
}

module.exports = {
  matchFreshaVenueToGoogle,
  haversineMeters,
  phonesMatch,
  addressOverlap,
};
