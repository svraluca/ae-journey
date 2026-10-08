'use strict';

const {localeForCity} = require('../searchLocale');

/**
 * Fresha location tokens. Prefer short codes where the actor docs show them
 * (AE, UK, US); use country names for others (Romania, Canada, …).
 */
const GL_TO_FRESHA_COUNTRY = {
  ae: 'AE',
  uk: 'UK',
  gb: 'UK',
  us: 'US',
  au: 'Australia',
  ca: 'Canada',
  ro: 'Romania',
  es: 'Spain',
  mx: 'Mexico',
  ar: 'Argentina',
  co: 'Colombia',
  it: 'Italy',
  fr: 'France',
  de: 'Germany',
  at: 'Austria',
  tr: 'Turkey',
  pt: 'Portugal',
  br: 'Brazil',
  nl: 'Netherlands',
  pl: 'Poland',
  kr: 'South Korea',
  jp: 'Japan',
  ru: 'Russia',
  cz: 'Czech Republic',
  gr: 'Greece',
  eg: 'Egypt',
  sa: 'Saudi Arabia',
  lb: 'Lebanon',
  ie: 'Ireland',
  ch: 'Switzerland',
  be: 'Belgium',
};

function cityDisplayName(city) {
  return String(city || '').trim().split(',')[0].trim();
}

function countryCodeForCity(city) {
  const gl = String(localeForCity(city).gl || '').trim().toLowerCase();
  if (!gl) return '';
  if (gl === 'uk') return 'GB';
  return gl.toUpperCase();
}

function freshaCountryLabel(city) {
  const gl = String(localeForCity(city).gl || '').trim().toLowerCase();
  if (!gl) return '';
  return GL_TO_FRESHA_COUNTRY[gl] || gl.toUpperCase();
}

/**
 * Dynamic "City, Country" for the Fresha actor — never hardcode Dubai.
 * Examples: "Dubai, AE", "London, UK", "Miami, US", "Bucharest, Romania".
 */
function freshaLocationForCity(city) {
  const name = cityDisplayName(city);
  const country = freshaCountryLabel(city);
  if (!name) return '';
  if (!country) return name;
  return `${name}, ${country}`;
}

function importCityKey(city) {
  const name = cityDisplayName(city).toLowerCase();
  const cc = countryCodeForCity(city).toLowerCase() || 'xx';
  const raw = `${name}|${cc}`;
  const encoded = encodeURIComponent(raw).replace(/%/g, '_');
  return encoded.length <= 400 ? encoded : encoded.slice(0, 400);
}

module.exports = {
  cityDisplayName,
  countryCodeForCity,
  freshaCountryLabel,
  freshaLocationForCity,
  importCityKey,
  GL_TO_FRESHA_COUNTRY,
};
