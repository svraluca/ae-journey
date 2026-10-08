'use strict';

const {searchOrganicResults} = require('../serpProvider');
const {serpHlGl} = require('../searchLocale');
const {
  namesLookLikeSameProvider,
  packedCanonicalClinicName,
  spacedCanonicalClinicName,
} = require('../identity');
const {cityDisplayName} = require('./locationFormat');

const FRESHA_A_RE =
  /https?:\/\/(?:www\.)?fresha\.com\/a\/[a-z0-9][a-z0-9\-_%]*/i;

function extractFreshaVenueUrl(raw) {
  const s = String(raw || '').trim();
  if (!s) return '';
  const m = s.match(FRESHA_A_RE);
  if (!m) return '';
  return m[0].split('?')[0].split('#')[0].replace(/\/$/, '');
}

function slugTokens(url) {
  const path = String(url || '').toLowerCase();
  const m = path.match(/fresha\.com\/a\/([^/?#]+)/);
  if (!m) return [];
  return m[1].split(/[^a-z0-9]+/).filter((t) => t.length >= 3);
}

function nameTokens(name) {
  const spaced = spacedCanonicalClinicName(name);
  const base = spaced || String(name || '').toLowerCase();
  return base.replace(/[^a-z0-9]+/g, ' ').trim().split(/\s+/)
      .filter((t) => t.length >= 3);
}

/**
 * Strong Fresha `/a/` URL match for a Google clinic.
 */
function freshaUrlMatchesClinic(url, clinic, city) {
  const venueUrl = extractFreshaVenueUrl(url);
  if (!venueUrl) return {ok: false, url: '', reason: 'not_fresha_a'};
  const slug = slugTokens(venueUrl);
  const cityFold = String(cityDisplayName(city) || '').toLowerCase()
      .replace(/[^a-z0-9]+/g, '');
  const cityInSlug = !cityFold || slug.some((t) =>
    cityFold.includes(t) || t.includes(cityFold.slice(0, 5)));
  const clinicName = String((clinic && clinic.name) || '');
  const tokens = nameTokens(clinicName);
  let nameHits = 0;
  for (const t of tokens) {
    if (slug.some((s) => s.includes(t) || t.includes(s))) nameHits += 1;
  }
  const nameOk = nameHits >= Math.min(2, Math.max(1, tokens.length)) ||
      namesLookLikeSameProvider(clinicName, slug.join(' '));
  if (!nameOk) return {ok: false, url: venueUrl, reason: 'name_mismatch'};
  if (!cityInSlug && cityFold.length >= 4) {
    // Soft: city may be missing from short slugs — still accept strong name.
    if (nameHits < 2 && tokens.length >= 2) {
      return {ok: false, url: venueUrl, reason: 'city_mismatch'};
    }
  }
  return {ok: true, url: venueUrl, reason: 'strong'};
}

/**
 * Find Fresha venue URL for a Google clinic via Serper/Google + website check.
 */
async function findFreshaVenueUrlForClinic(clinic, {
  city,
  serperApiKey = '',
  dataForSeoLogin = '',
  dataForSeoPassword = '',
  serpApiKey = '',
} = {}) {
  if (!clinic || !clinic.name) {
    return {url: '', reason: 'missing_clinic'};
  }

  // Direct: clinic website already points at Fresha.
  const website = String(clinic.website || '').trim();
  const fromSite = extractFreshaVenueUrl(website);
  if (fromSite) {
    const verdict = freshaUrlMatchesClinic(fromSite, clinic, city);
    if (verdict.ok) {
      console.log(
          `[FRESHA URL] website · ${clinic.name} → ${verdict.url}`);
      return {url: verdict.url, reason: 'website'};
    }
  }

  const display = cityDisplayName(city);
  const q =
      `site:fresha.com/a "${clinic.name}" "${display}"`.replace(/\s+/g, ' ').trim();
  const {hl, gl} = serpHlGl(city);
  const hits = await searchOrganicResults({
    query: q,
    hl,
    gl,
    serperApiKey,
    dataForSeoLogin,
    dataForSeoPassword,
    serpApiKey,
  });

  for (const hit of hits || []) {
    const link = String((hit && hit.url) || '').trim();
    const title = String((hit && hit.title) || '').trim();
    const candidate = extractFreshaVenueUrl(link) ||
        extractFreshaVenueUrl(title);
    if (!candidate) continue;
    const verdict = freshaUrlMatchesClinic(candidate, clinic, city);
    if (verdict.ok) {
      console.log(
          `[FRESHA URL] serp · ${clinic.name} → ${verdict.url}`);
      return {url: verdict.url, reason: 'serp'};
    }
  }
  return {url: '', reason: 'not_found'};
}

module.exports = {
  extractFreshaVenueUrl,
  freshaUrlMatchesClinic,
  findFreshaVenueUrlForClinic,
};
