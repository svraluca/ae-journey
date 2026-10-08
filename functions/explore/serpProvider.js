'use strict';

/**
 * Web search is used for **discovery only**: it tells us which clinic pages
 * exist and where to fetch them. No price ever comes from a search result —
 * amounts are parsed from the clinic's own HTML by the deterministic extractor
 * and verified against its official domain.
 *
 * Mirrors lib/services/explore_serp_provider.dart.
 */

// `regular` carries the same organic rows as `advanced` for a third of the
// bytes and about half the latency; discovery reads url/title/description only.
const DATAFORSEO_ENDPOINT =
  'https://api.dataforseo.com/v3/serp/google/organic/live/regular';

const SERPER_ENDPOINT = 'https://google.serper.dev/search';

/**
 * Preference order. Serper wins because tail latency decides whether a card
 * reaches the screen: DataForSEO's live endpoint answered in 2s most of the
 * time but left single requests unanswered for 17s and 31s. The others stay
 * wired up so one provider having a bad night cannot blank the lists.
 */
function serpProviderKind({serperApiKey, dataForSeoLogin, dataForSeoPassword, serpApiKey}) {
  if (String(serperApiKey || '').trim()) return 'serper';
  if (String(dataForSeoLogin || '').trim() && String(dataForSeoPassword || '').trim()) {
    return 'dataforseo';
  }
  if (String(serpApiKey || '').trim()) return 'serpapi';
  return 'none';
}

function serperHeaders(apiKey) {
  return {'X-API-KEY': String(apiKey || '').trim(), 'Content-Type': 'application/json'};
}

/**
 * Serper takes plain Google parameters, so `gl`/`hl` pass straight through and
 * unmapped markets simply omit them rather than being forced to google.com.
 *
 * No `num`: Serper returns one page whatever is asked for — 10, 30 and 100 all
 * came back with the same nine rows for one credit — and asking for more than a
 * page doubled the response time. Breadth comes from asking a second question,
 * not a deeper page.
 */
function serperRequestBody({query, hl = '', gl = ''}) {
  const body = {q: String(query || '').trim()};
  const lang = String(hl || '').trim().toLowerCase();
  const country = String(gl || '').trim().toLowerCase();
  if (lang) body.hl = lang;
  if (country) body.gl = country === 'uk' ? 'gb' : country;
  return body;
}

/** A bad or spent Serper key is 401/402/403, and no retry can fix either. */
function serperKeyUnusable(statusCode) {
  return statusCode === 401 || statusCode === 402 || statusCode === 403;
}

function parseSerperOrganic(decoded) {
  if (!decoded || typeof decoded !== 'object') return [];
  const out = [];
  for (const item of Array.isArray(decoded.organic) ? decoded.organic : []) {
    const hit = hitFrom({
      title: item && item.title,
      link: item && item.link,
      snippet: item && item.snippet,
      displayed: (item && item.displayedLink) || (item && item.domain),
    });
    if (hit) out.push(hit);
  }
  return out;
}

function dataForSeoAuthHeader(login, password) {
  const raw = `${String(login).trim()}:${String(password).trim()}`;
  return `Basic ${Buffer.from(raw, 'utf8').toString('base64')}`;
}

/** Google geo target IDs for countries are `2000 + ISO 3166-1 numeric`. */
const ISO_NUMERIC = {
  ae: 784, al: 8, am: 51, ar: 32, at: 40, au: 36, az: 31,
  ba: 70, bd: 50, be: 56, bg: 100, bh: 48, br: 76,
  ca: 124, ch: 756, cl: 152, cn: 156, co: 170, cy: 196, cz: 203,
  de: 276, dk: 208, ee: 233, eg: 818, es: 724,
  fi: 246, fr: 250, gb: 826, ge: 268, gh: 288, gr: 300,
  hk: 344, hr: 191, hu: 348, id: 360, ie: 372, il: 376, in: 356,
  is: 352, it: 380, jo: 400, jp: 392, ke: 404, kr: 410, kw: 414,
  kz: 398, lb: 422, lk: 144, lt: 440, lu: 442, lv: 428,
  ma: 504, md: 498, mk: 807, mt: 470, mx: 484, my: 458,
  ng: 566, nl: 528, no: 578, np: 524, nz: 554, om: 512,
  pe: 604, ph: 608, pk: 586, pl: 616, pt: 620, qa: 634,
  ro: 642, rs: 688, ru: 643, sa: 682, se: 752, sg: 702, si: 705,
  sk: 703, th: 764, tn: 788, tr: 792, tw: 158, ua: 804, us: 840,
  uz: 860, vn: 704, za: 710,
};

/** The `gl` codes we emit are Google-flavoured, so `uk` must resolve to GB. */
function dataForSeoLocationCode(gl) {
  let code = String(gl || '').trim().toLowerCase();
  if (!code) return null;
  if (code === 'uk') code = 'gb';
  const numeric = ISO_NUMERIC[code];
  return numeric ? 2000 + numeric : null;
}

/**
 * How deep a DataForSEO query goes; Serper has no equivalent knob.
 *
 * DataForSEO charges per 10 results and five times over for search operators,
 * so a `site:` lookup stays shallow — only the top on-domain hit is ever used.
 * A broad city sweep is the opposite: one deep SERP lists ~29 clinic hosts, and
 * one request always beats three when a slow upstream can cost the request its
 * whole budget.
 */
function dataForSeoDepth(query) {
  return String(query || '').toLowerCase().includes('site:') ? 10 : 30;
}

/**
 * `depth` is charged per 10 results. DataForSEO always needs a location, so
 * markets we cannot map fall back to google.com and lean on the city name in
 * the query as the geo signal.
 */
function dataForSeoRequestBody({query, hl = '', gl = '', depth = 10}) {
  const task = {
    keyword: String(query || '').trim(),
    depth,
    device: 'desktop',
    os: 'windows',
  };
  const lang = String(hl || '').trim().toLowerCase();
  if (lang) task.language_code = lang;
  const location = dataForSeoLocationCode(gl);
  if (location) {
    task.location_code = location;
  } else {
    task.location_code = 2840;
    task.language_code = lang || 'en';
  }
  return [task];
}

/**
 * DataForSEO answers HTTP 200 and reports problems in `status_code`, and the
 * codes look alike while meaning very different things: 40100 is bad
 * credentials (stop using the provider) while 40101 is the search engine
 * hiccuping (retry the same query).
 */
const PROVIDER_UNUSABLE = new Set([40100, 40104, 40200, 40201, 40210]);
const RETRYABLE = new Set([40101, 40103, 50000, 50001]);

function dataForSeoStatus(decoded) {
  const make = (code, message) => ({
    code,
    message,
    ok: code === 20000,
    providerUnusable: PROVIDER_UNUSABLE.has(code),
    retryable: RETRYABLE.has(code),
    rateLimited: code === 40202,
    noResults: code === 40102,
    logLine: code === 20000 ? '' : `${code} ${message}`.trim(),
  });
  if (!decoded || typeof decoded !== 'object') return make(-1, 'malformed response');
  if (typeof decoded.status_code === 'number' && decoded.status_code !== 20000) {
    return make(decoded.status_code, String(decoded.status_message || ''));
  }
  const tasks = Array.isArray(decoded.tasks) ? decoded.tasks : [];
  if (!tasks.length) return make(-1, 'no tasks');
  const first = tasks[0] || {};
  if (typeof first.status_code === 'number' && first.status_code !== 20000) {
    return make(first.status_code, String(first.status_message || ''));
  }
  return make(20000, 'Ok.');
}

/** Non-empty when DataForSEO reported a problem, for one log line. */
function dataForSeoStatusError(decoded) {
  return dataForSeoStatus(decoded).logLine;
}

function hitFrom({title, link, snippet, displayed}) {
  const t = String(title || '').trim();
  const l = String(link || '').trim();
  const s = String(snippet || '').trim();
  const d = String(displayed || '').trim();
  if (!t && !l && !s) return null;
  return {title: t, url: l, snippet: s, displayedLink: d};
}

function parseDataForSeoOrganic(decoded) {
  if (!decoded || typeof decoded !== 'object') return [];
  const out = [];
  for (const task of Array.isArray(decoded.tasks) ? decoded.tasks : []) {
    for (const result of Array.isArray(task && task.result) ? task.result : []) {
      for (const item of Array.isArray(result && result.items) ? result.items : []) {
        if (!item || item.type !== 'organic') continue;
        const hit = hitFrom({
          title: item.title,
          link: item.url,
          snippet: item.description,
          displayed: item.breadcrumb || item.domain,
        });
        if (hit) out.push(hit);
      }
    }
  }
  return out;
}

function parseSerpApiOrganic(decoded) {
  if (!decoded || typeof decoded !== 'object') return [];
  const out = [];
  for (const item of Array.isArray(decoded.organic_results) ? decoded.organic_results : []) {
    const hit = hitFrom({
      title: item && item.title,
      link: item && item.link,
      snippet: item && item.snippet,
      displayed: item && item.displayed_link,
    });
    if (hit) out.push(hit);
  }
  return out;
}

// DataForSEO serialises live requests per account: with six posts open, four
// answered in ~2s while the extras sat unanswered for 18s and 31s. Holding a
// slot keeps every query inside the request deadline instead of stalling on an
// account queue we cannot see.
const MAX_IN_FLIGHT = 2;
let inFlight = 0;
const waiting = [];

function acquireSlot() {
  if (inFlight < MAX_IN_FLIGHT) {
    inFlight++;
    return Promise.resolve();
  }
  return new Promise((resolve) => waiting.push(resolve));
}

function releaseSlot() {
  const next = waiting.shift();
  if (next) return next();
  if (inFlight > 0) inFlight--;
}

/**
 * One discovery query. Returns `[{url, title, snippet, displayedLink}]` —
 * never prices.
 */
async function searchOrganicResults({
  query,
  hl = '',
  gl = '',
  city = '',
  serperApiKey = '',
  dataForSeoLogin = '',
  dataForSeoPassword = '',
  serpApiKey = '',
}) {
  const q = String(query || '').trim();
  if (!q) return [];

  // Bright Data SERP primary when configured.
  try {
    const {useBrightData} = require('./featureFlags');
    const {brightDataConfigured} = require('./brightdata/brightDataClient');
    if (useBrightData() && brightDataConfigured() &&
        String(process.env.BRIGHTDATA_SERP_ZONE || '').trim()) {
      const {searchBrightDataSerp} = require('./brightdata/brightDataSerp');
      const bdHits = await searchBrightDataSerp({query: q, city, hl, gl});
      if (bdHits.length) return bdHits;
      console.log('[BRIGHTDATA SERP] empty — falling back to Serper');
    }
  } catch (e) {
    console.log(`[BRIGHTDATA SERP] error · ${e.message || e}`);
  }

  let kind = serpProviderKind({
    serperApiKey,
    dataForSeoLogin,
    dataForSeoPassword,
    serpApiKey,
  });
  if (kind === 'none') {
    console.log('[GP] Discovery skipped — no SERPER_API_KEY / DATAFORSEO_* / SERPAPI_API_KEY');
    return [];
  }

  if (kind === 'serper') {
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await fetch(SERPER_ENDPOINT, {
        method: 'POST',
        headers: serperHeaders(serperApiKey),
        body: JSON.stringify(serperRequestBody({query: q, hl, gl})),
      });
      if (res.ok) return parseSerperOrganic(await res.json().catch(() => null));
      console.log(`[GP] Serper HTTP ${res.status}`);
      if (serperKeyUnusable(res.status)) break;
      if (res.status !== 429 && res.status < 500) return [];
    }
    // Hand the request to the next provider rather than blanking discovery.
    kind = serpProviderKind({dataForSeoLogin, dataForSeoPassword, serpApiKey});
    if (kind === 'none') return [];
    console.log(`[GP] Discovery falling back to ${kind}`);
  }

  if (kind === 'dataforseo') {
    let unusable = false;
    await acquireSlot();
    try {
      // One retry: Google itself sometimes answers 40101 through DataForSEO.
      for (let attempt = 0; attempt < 2 && !unusable; attempt++) {
        const res = await fetch(DATAFORSEO_ENDPOINT, {
          method: 'POST',
          headers: {
            'Authorization': dataForSeoAuthHeader(dataForSeoLogin, dataForSeoPassword),
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(
              dataForSeoRequestBody({query: q, hl, gl, depth: dataForSeoDepth(q)}),
          ),
        });
        if (!res.ok) {
          console.log(`[GP] DataForSEO HTTP ${res.status}`);
          unusable = [401, 402, 403].includes(res.status);
          if (!unusable && res.status !== 429 && res.status < 500) return [];
          continue;
        }
        const json = await res.json().catch(() => null);
        const status = dataForSeoStatus(json);
        if (status.ok) return parseDataForSeoOrganic(json);
        console.log(`[GP] DataForSEO ${status.logLine}`);
        if (status.providerUnusable) {
          unusable = true;
        } else if (!status.retryable) {
          return [];
        }
      }
    } finally {
      releaseSlot();
    }
    // Account-level problems must not blank discovery while SerpApi still works.
    if (!unusable || !String(serpApiKey || '').trim()) return [];
    console.log('[GP] Discovery falling back to SerpApi');
  }

  const url = new URL('https://serpapi.com/search.json');
  url.searchParams.set('engine', 'google');
  url.searchParams.set('q', q);
  if (hl) url.searchParams.set('hl', hl);
  if (gl) url.searchParams.set('gl', gl);
  url.searchParams.set('num', '10');
  url.searchParams.set('api_key', serpApiKey);
  const res = await fetch(url);
  if (!res.ok) {
    console.log(`[GP] SerpApi HTTP ${res.status}`);
    return [];
  }
  return parseSerpApiOrganic(await res.json());
}

module.exports = {
  DATAFORSEO_ENDPOINT,
  SERPER_ENDPOINT,
  serpProviderKind,
  dataForSeoDepth,
  serperHeaders,
  serperRequestBody,
  serperKeyUnusable,
  parseSerperOrganic,
  dataForSeoAuthHeader,
  dataForSeoLocationCode,
  dataForSeoRequestBody,
  dataForSeoStatusError,
  dataForSeoStatus,
  parseDataForSeoOrganic,
  parseSerpApiOrganic,
  searchOrganicResults,
};
