'use strict';

/**
 * Global URL scoring + sitemap discovery for Explore price pages.
 * Locale tokens come from searchLocale — no city/clinic allowlists.
 */

const {WORLD_SITE_PRICE_WORDS, localeForCity} = require('./searchLocale');
const {hostOf, looksLikeBotoxSpecialtyVariantUrl,
  looksLikeBotoxStandardStartingUrl} = require('./parsePrice');
const {exploreUrlConflictsWithProcedure} = require('./priceSanity');
const {
  exploreUrlConflictsWithSearchCity,
  urlMatchesSearchCity,
} = require('./cityIdentity');

const WORLD_URL_PRICE_TOKENS = [
  ...WORLD_SITE_PRICE_WORDS,
  'fees', 'fee', 'menu', 'meniu', 'listino', 'cennik',
  'book', 'booking', 'book-online', 'reserve', 'reservation', 'cita',
  'treatment', 'treatments', 'services', 'packages', 'offers',
  'تكلفة', 'اسعارنا', 'باقات', 'حجز',
  '가격', '비용', '요금', '料金', '価格', '費用',
  'цена', 'цены', 'стоимость', 'прайс',
];

const TREATMENT_TOKENS = [
  'botox', 'filler', 'fillers', 'laser', 'peel', 'peeling', 'rhino',
  'rhinoplasty', 'breast', 'hair', 'transplant', 'hifu', 'prp',
  'hyaluron', 'injectable', 'بوتوكس', 'فيلر', 'ليزر', 'تقشير',
];

function isPdfUrl(url) {
  const u = String(url || '').toLowerCase();
  return /\.pdf(\?|#|$)/i.test(u) || u.includes('format=pdf') || u.includes('type=pdf');
}

function contentTypeIsPdf(contentType) {
  const t = String(contentType || '').toLowerCase();
  return t.includes('application/pdf') || t.includes('application/x-pdf');
}

function scorePriceUrl(url, {procedure = '', city = ''} = {}) {
  const u = String(url || '').toLowerCase();
  if (!u) return 0;
  if (/wp-admin|wp-login|\/tag\/|\/author\/|\.jpe?g(\?|$)|\.png(\?|$)|\.gif(\?|$)|mailto:|tel:/.test(u)) {
    return 0;
  }
  if (String(procedure || '').trim() && exploreUrlConflictsWithProcedure(url, procedure)) {
    return 0;
  }
  // Branch/city path for a different city must never score as a candidate.
  if (String(city || '').trim() && exploreUrlConflictsWithSearchCity(url, city)) {
    return 0;
  }
  const loc = localeForCity(city);
  const tokens = new Set([
    ...WORLD_URL_PRICE_TOKENS.map((t) => String(t).toLowerCase()),
    loc.priceWord ? String(loc.priceWord).toLowerCase() : '',
  ].filter(Boolean));

  let score = 0;
  for (const t of tokens) {
    if (t.length >= 2 && u.includes(t)) {
      score = Math.max(score, 3);
      break;
    }
  }
  if (score < 2) {
    for (const t of ['servicii', 'tratament', 'tratamiento', 'procedur',
      'procedure', 'services', 'treatments', '/treatment', 'booking',
      'reserve', 'cita', 'حجز']) {
      if (u.includes(t)) {
        score = 2;
        break;
      }
    }
  }
  if (score < 1) {
    for (const t of TREATMENT_TOKENS) {
      if (u.includes(t)) {
        score = 1;
        break;
      }
    }
  }
  if (isPdfUrl(u) && score < 3) score = 3;

  const proc = String(procedure || '').toLowerCase();
  for (const t of proc.split(/[^a-z0-9\u0600-\u06ff]+/i)) {
    if (t.length >= 4 && u.includes(t)) score += 1;
  }
  if (/\/page\/\d+(?:\/|$|\?)/.test(u) && score < 3) {
    score = score >= 2 ? score - 2 : 0;
  }
  if (/(?:^|\/)(?:price-list|pricelist|price-guide)(?:\/|$|\.)|\/prices(?:\/|$)|rhinoplasty-cost|nose-job-cost|boob-job-cost|\/(?:our-)?fees(?:\/|$)|\/cost(?:\/|$)/i.test(u) &&
      !/special-?offers?|\/(?:offers|deals)(?:\/|$)|\/booking|\/book-|cost-in-|cost-london|london-prices|botox-cost/i.test(u)) {
    if (score < 5) score = 5;
  } else if (/(?:^|[/?#])(?:book-online|booking|book-now)(?:\/|$|\.|[#?])/i.test(u)) {
    if (score < 4) score = 4;
  } else if (/\/blog\/|\/guides?\/|\/faq|\/best-|cost-in-|special-?offers?|\/(?:offers|deals|promotions?)(?:\/|$)|(?:^|\/)botox-cost(?:\/|$)/i.test(u)) {
    if (score > 1) score = 1;
  }
  const procFam = String(procedure || '').toLowerCase();
  if (/botox|toxin|بوتوكس/.test(procFam)) {
    if (looksLikeBotoxSpecialtyVariantUrl(u)) {
      if (score > 1) score = 1;
    } else if (looksLikeBotoxStandardStartingUrl(u)) {
      if (score < 4) score = 4;
    }
  }
  // Prefer exact branch/city price pages (e.g. /preturi/timisoara/).
  if (String(city || '').trim() && urlMatchesSearchCity(url, city)) {
    score += 4;
  }
  return score;
}

function rankAndPickUrls(urls, {procedure = '', max = 5, host = '', city = ''} = {}) {
  const hostKey = String(host || '')
      .toLowerCase()
      .replace(/^www\./, '')
      .trim();
  const scored = [];
  const seen = new Set();
  for (const raw of urls || []) {
    const url = String(raw || '').trim();
    if (!url || seen.has(url)) continue;
    seen.add(url);
    if (hostKey) {
      try {
        const h = new URL(url.includes('://') ? url : `https://${url}`)
            .hostname
            .toLowerCase()
            .replace(/^www\./, '');
        if (h !== hostKey && !h.endsWith(`.${hostKey}`) && !hostKey.endsWith(`.${h}`)) {
          continue;
        }
      } catch (_) {
        continue;
      }
    }
    const score = scorePriceUrl(url, {procedure, city});
    if (score < 1 && !isPdfUrl(url)) continue;
    scored.push({url, score: score + (isPdfUrl(url) ? 1 : 0)});
  }
  scored.sort((a, b) => b.score - a.score || a.url.length - b.url.length);
  return scored.slice(0, Math.max(1, Math.min(12, max || 5))).map((r) => r.url);
}

function parseSitemapLocs(xml, siteHost) {
  const out = [];
  const re = /<loc>\s*([^<]+)\s*<\/loc>/gi;
  let m;
  while ((m = re.exec(String(xml || '')))) {
    const u = String(m[1] || '').trim();
    if (!u) continue;
    try {
      const h = new URL(u).hostname.toLowerCase().replace(/^www\./, '');
      if (h === siteHost || h.endsWith(`.${siteHost}`) || siteHost.endsWith(`.${h}`)) {
        out.push(u);
      }
    } catch (_) { /* skip */ }
  }
  return out;
}

/**
 * robots.txt + common sitemap paths → URL list for the clinic host.
 */
async function discoverSitemapUrls(hostOrBase, {timeoutMs = 6000} = {}) {
  const host = hostOf(hostOrBase) || String(hostOrBase || '')
      .toLowerCase()
      .replace(/^https?:\/\//, '')
      .replace(/^www\./, '')
      .split('/')[0];
  if (!host) return [];
  const base = `https://${host}`;
  const seeds = new Set([
    `${base}/sitemap.xml`,
    `${base}/sitemap_index.xml`,
    `${base}/wp-sitemap.xml`,
    `${base}/sitemap-index.xml`,
  ]);
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    try {
      const robots = await fetch(`${base}/robots.txt`, {signal: ac.signal});
      if (robots.ok) {
        const text = await robots.text();
        for (const line of text.split(/\r?\n/)) {
          const m = /^\s*sitemap\s*:\s*(\S+)/i.exec(line);
          if (m && m[1]) seeds.add(m[1].trim());
        }
      }
    } catch (_) { /* ignore */ }

    const out = new Set();
    for (const sm of seeds) {
      try {
        const res = await fetch(sm, {signal: ac.signal});
        if (!res.ok) continue;
        const body = await res.text();
        if (body.length > 2_000_000) continue;
        for (const u of parseSitemapLocs(body, host)) out.add(u);
      } catch (_) { /* ignore */ }
    }
    console.log(`[SITEMAP] ${host} → ${out.size} urls`);
    return [...out];
  } finally {
    clearTimeout(timer);
  }
}

module.exports = {
  scorePriceUrl,
  rankAndPickUrls,
  isPdfUrl,
  contentTypeIsPdf,
  discoverSitemapUrls,
  parseSitemapLocs,
  WORLD_URL_PRICE_TOKENS,
};
