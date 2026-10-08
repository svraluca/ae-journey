'use strict';

const {brightDataRequest, brightDataConfigured} = require('./brightDataClient');
const {useBrightData} = require('../featureFlags');
const {serpHlGl} = require('../searchLocale');

/**
 * Bright Data SERP — discovery only.
 * Never parse prices from titles/snippets.
 */

function buildGoogleSearchUrl(query, {hl = 'en', gl = ''} = {}) {
  const u = new URL('https://www.google.com/search');
  u.searchParams.set('q', String(query || '').trim());
  u.searchParams.set('num', '10');
  u.searchParams.set('hl', String(hl || 'en').trim() || 'en');
  const country = String(gl || '').trim().toLowerCase();
  if (country) u.searchParams.set('gl', country === 'uk' ? 'gb' : country);
  u.searchParams.set('brd_json', '1');
  return u.toString();
}

function hitFrom(row) {
  if (!row || typeof row !== 'object') return null;
  const url = String(row.link || row.url || row.href || '').trim();
  const title = String(row.title || row.name || '').trim();
  const snippet = String(
      row.snippet || row.description || row.desc || '').trim();
  if (!url || !/^https?:\/\//i.test(url)) return null;
  return {url, title, snippet};
}

function parseBrightDataSerpBody(body, json) {
  const out = [];
  const seen = new Set();
  const push = (row) => {
    const hit = hitFrom(row);
    if (!hit || seen.has(hit.url)) return;
    seen.add(hit.url);
    out.push(hit);
  };

  const root = json && typeof json === 'object' ? json : null;
  let parsed = root;
  if (!parsed) {
    try {
      parsed = JSON.parse(String(body || ''));
    } catch (_) {
      parsed = null;
    }
  }
  if (parsed && typeof parsed === 'object') {
    const organic = parsed.organic || parsed.organic_results ||
        parsed.results || parsed.organicResults || [];
    if (Array.isArray(organic)) {
      for (const row of organic) push(row);
    }
    if (Array.isArray(parsed.general)) {
      for (const row of parsed.general) push(row);
    }
  }

  // HTML fallback: extract result links heuristically (no price parsing).
  if (!out.length && typeof body === 'string' && body.includes('http')) {
    const re = /href="(https?:\/\/(?!www\.google\.)[^"]+)"/gi;
    let m;
    while ((m = re.exec(body)) && out.length < 10) {
      try {
        const u = new URL(m[1]);
        if (/google\.|gstatic\.|youtube\./i.test(u.host)) continue;
        push({link: u.toString(), title: '', snippet: ''});
      } catch (_) {
        // ignore
      }
    }
  }
  return out;
}

/**
 * @return {Promise<Array<{url:string,title:string,snippet:string}>>}
 */
async function searchBrightDataSerp({
  query,
  city = '',
  hl = '',
  gl = '',
  zone = process.env.BRIGHTDATA_SERP_ZONE,
} = {}) {
  if (!useBrightData() || !brightDataConfigured()) return [];
  const z = String(zone || '').trim();
  const q = String(query || '').trim();
  if (!z || !q) return [];

  let lang = hl;
  let country = gl;
  if ((!lang || !country) && city) {
    const loc = serpHlGl(city);
    lang = lang || loc.hl;
    country = country || loc.gl;
  }

  const searchUrl = buildGoogleSearchUrl(q, {hl: lang, gl: country});
  console.log(`[BRIGHTDATA SERP] ${q}`);
  const res = await brightDataRequest({
    zone: z,
    url: searchUrl,
    format: 'raw',
    timeoutMs: 22000,
  });
  if (!res.ok) return [];
  const hits = parseBrightDataSerpBody(res.body, res.json);
  console.log(`[BRIGHTDATA SERP] hits=${hits.length}`);
  return hits;
}

module.exports = {
  searchBrightDataSerp,
  buildGoogleSearchUrl,
  parseBrightDataSerpBody,
};
