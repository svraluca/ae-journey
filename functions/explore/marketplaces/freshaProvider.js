'use strict';

const {MarketplaceProvider} = require('./marketplaceProvider');
const {injectableScopeRejection} = require('../injectableScope');
const {
  FRESHA_ACTOR_ID,
  FRESHA_VENUE_BATCH_SIZE,
  PROVIDER_FRESHA,
} = require('./constants');

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function apifyToken() {
  return String(process.env.APIFY_API_TOKEN || '').trim();
}

function parseNumericPrice(raw) {
  if (raw == null || raw === '') return 0;
  if (typeof raw === 'number' && Number.isFinite(raw) && raw > 0) {
    return Math.round(raw);
  }
  const s = String(raw).replace(/\u00a0/g, ' ').trim();
  if (!s) return 0;
  if (/request|quote|consult|call|tbd|n\/a|free\b/i.test(s) && !/\d/.test(s)) {
    return 0;
  }
  const m = s.match(/(\d{1,3}(?:[.,\s]\d{3})+|\d+)(?:[.,](\d{1,2}))?/);
  if (!m) return 0;
  let whole = m[1].replace(/[.,\s]/g, '');
  if (/^\d{1,3}(\.\d{3})+$/.test(m[1])) whole = m[1].replace(/\./g, '');
  else if (/^\d{1,3}(,\d{3})+$/.test(m[1])) whole = m[1].replace(/,/g, '');
  const n = Number(whole);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
}

function venueIdFromUrl(url) {
  const m = String(url || '').match(/fresha\.com\/a\/([^/?#]+)/i);
  return m ? m[1] : '';
}

/**
 * Flatten Malikgen categories[].services[] and legacy scrapesage shapes.
 */
function flattenServiceItems(raw) {
  const out = [];
  if (!raw || typeof raw !== 'object') return out;

  // Malikgen: categories: [{ name, services: [{ name, price, priceValue, duration }] }]
  const categories = Array.isArray(raw.categories) ? raw.categories : [];
  for (const cat of categories) {
    const category = String((cat && (cat.name || cat.category)) || '').trim();
    const services = Array.isArray(cat && cat.services) ? cat.services : [];
    for (const svc of services) {
      if (!svc || typeof svc !== 'object') continue;
      out.push({...svc, category});
    }
  }

  // Legacy / alternate: services: [{ category, items: [...] }] or flat list
  const services = Array.isArray(raw.services) ? raw.services : [];
  for (const block of services) {
    if (!block || typeof block !== 'object') continue;
    if (Array.isArray(block.items)) {
      const category = String(block.category || block.name || '').trim();
      for (const item of block.items) {
        if (!item || typeof item !== 'object') continue;
        out.push({...item, category});
      }
      continue;
    }
    if (block.name) out.push(block);
  }

  // Direct services array under category wrappers already handled.
  return out;
}

/**
 * Expand a service into priced rows. Never invents a number.
 * Prefers Malikgen priceValue; falls back to literal price text only.
 */
function expandServicePriceRows(item, venueCurrency) {
  const rows = [];
  const baseName = String((item && item.name) || '').trim();
  if (!baseName) return rows;
  const currency = String(
      (item && item.currency) || venueCurrency || '').trim().toUpperCase();
  const duration = String((item && item.duration) || '').trim();
  const category = String((item && item.category) || '').trim();
  const description = String((item && item.description) || '').trim();

  const pushRow = (name, priceRaw, formatted) => {
    const price = parseNumericPrice(priceRaw);
    if (!(price > 0)) return;
    const rawPriceText = String(formatted || '').trim() ||
        (currency ? `${currency} ${price}` : String(price));
    rows.push({
      name: String(name || baseName).trim(),
      price,
      priceValue: price,
      currency,
      rawPriceText,
      duration,
      category,
      description,
      isVariant: name !== baseName,
    });
  };

  // Malikgen: priceValue numeric + price string like "AED 450"
  const priceValue = item.priceValue != null ? item.priceValue : item.price_value;
  const priceText = String(
      item.price || item.formattedPrice || item.rawPriceText || '').trim();
  if (priceValue != null && priceValue !== '') {
    pushRow(baseName, priceValue, priceText);
  } else if (priceText) {
    pushRow(baseName, priceText, priceText);
  }

  const variants = Array.isArray(item.variants) ? item.variants : [];
  for (const v of variants) {
    if (!v || typeof v !== 'object') continue;
    const vName = String(v.name || '').trim();
    const label = vName ? `${baseName} · ${vName}` : baseName;
    const vVal = v.priceValue != null ? v.priceValue : v.price;
    const vText = String(v.price || v.formattedPrice || '').trim();
    pushRow(label, vVal != null ? vVal : vText, vText);
  }
  return rows;
}

const AESTHETIC_SERVICE_NEEDLES = [
  'botox', 'dysport', 'xeomin', 'filler', 'juvederm', 'restylane', 'hialuron',
  'hyaluron', 'profhilo', 'sculptra', 'prp', 'microneedl', 'dermapen', 'hifu',
  'ultherapy', 'hydrafacial', 'hydra facial', 'chemical peel', 'peeling',
  'laser', 'fraxel', 'pico', 'skin booster', 'mesotherapy', 'rejuran',
  'anti-wrinkle', 'anti wrinkle', 'toxin', 'dermato', 'aesthetic inject',
];

const BEAUTY_ONLY_NEEDLES = [
  'haircut', 'hair cut', 'blow dry', 'blowdry', 'manicure', 'pedicure',
  'nail ', 'gel polish', 'waxing', 'eyebrow thread', 'beard trim',
  'swedish massage', 'deep tissue', 'hot stone', 'barber',
];

function fold(s) {
  return String(s || '').toLowerCase();
}

function serviceLooksAesthetic(name, category = '') {
  const t = fold(`${name} ${category}`);
  if (injectableScopeRejection({procedure: name, label: name, evidence: category})) return false;
  return AESTHETIC_SERVICE_NEEDLES.some((n) => t.includes(n));
}

function serviceLooksBeautyOnly(name, category = '') {
  const t = fold(`${name} ${category}`);
  if (serviceLooksAesthetic(name, category)) return false;
  return BEAUTY_ONLY_NEEDLES.some((n) => t.includes(n));
}

/**
 * Service-first gate: venue contributes only if catalogue has medical-aesthetic
 * procedures (not haircut/nails/massage-only).
 */
function venueHasMedicalAestheticServices(services) {
  const list = Array.isArray(services) ? services : [];
  return list.some((s) => serviceLooksAesthetic(s.name, s.category));
}

function venueIsBeautyOnly(services) {
  const list = Array.isArray(services) ? services : [];
  if (!list.length) return true;
  if (venueHasMedicalAestheticServices(list)) return false;
  return list.every((s) => serviceLooksBeautyOnly(s.name, s.category) ||
      !serviceLooksAesthetic(s.name, s.category));
}

async function listDatasetItems(token, datasetId) {
  const items = [];
  let offset = 0;
  const limit = 250;
  for (;;) {
    const url = new URL(
        `https://api.apify.com/v2/datasets/${datasetId}/items`);
    url.searchParams.set('format', 'json');
    url.searchParams.set('clean', '1');
    url.searchParams.set('offset', String(offset));
    url.searchParams.set('limit', String(limit));
    const res = await fetch(url, {
      headers: {Authorization: `Bearer ${token}`},
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`Apify dataset HTTP ${res.status}: ${body.slice(0, 200)}`);
    }
    const batch = await res.json();
    if (!Array.isArray(batch) || !batch.length) break;
    items.push(...batch);
    if (batch.length < limit) break;
    offset += batch.length;
  }
  return items;
}

async function runFreshaActor({token, input, maxWaitMs = 480000}) {
  const startRes = await fetch(
      `https://api.apify.com/v2/acts/${FRESHA_ACTOR_ID}/runs`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(input),
      });
  if (!startRes.ok) {
    const body = await startRes.text().catch(() => '');
    throw new Error(`Apify start HTTP ${startRes.status}: ${body.slice(0, 200)}`);
  }
  const startJson = await startRes.json();
  const run = startJson && startJson.data ? startJson.data : startJson;
  const runId = String((run && run.id) || '').trim();
  if (!runId) throw new Error('Apify start missing run id');

  const deadline = Date.now() + maxWaitMs;
  let lastStatus = String((run && run.status) || 'RUNNING');
  while (Date.now() < deadline) {
    const statusRes = await fetch(
        `https://api.apify.com/v2/actor-runs/${runId}`,
        {headers: {Authorization: `Bearer ${token}`}});
    if (!statusRes.ok) {
      throw new Error(`Apify run status HTTP ${statusRes.status}`);
    }
    const statusJson = await statusRes.json();
    const data = statusJson && statusJson.data ? statusJson.data : statusJson;
    lastStatus = String((data && data.status) || '');
    if (lastStatus === 'SUCCEEDED') {
      const datasetId = String((data && data.defaultDatasetId) || '').trim();
      if (!datasetId) throw new Error('Apify run missing dataset id');
      return {
        runId,
        items: await listDatasetItems(token, datasetId),
      };
    }
    if (['FAILED', 'ABORTED', 'TIMED-OUT'].includes(lastStatus)) {
      throw new Error(`Apify run ${lastStatus}`);
    }
    await sleep(5000);
  }
  throw new Error(`Apify run timeout · status=${lastStatus} · runId=${runId}`);
}

class FreshaProvider extends MarketplaceProvider {
  get id() {
    return PROVIDER_FRESHA;
  }

  /**
   * Venue-mode only. Never uses Malikgen/search or ScrapeSage city discovery.
   * @param {string[]} venueUrls Fresha /a/ URLs
   */
  async scrapeVenues(venueUrls = []) {
    const token = apifyToken();
    if (!token) throw new Error('APIFY_API_TOKEN not configured');
    const urls = [...new Set(
        (venueUrls || []).map((u) => String(u || '').trim()).filter(Boolean))];
    if (!urls.length) return [];

    const all = [];
    for (let i = 0; i < urls.length; i += FRESHA_VENUE_BATCH_SIZE) {
      const batch = urls.slice(i, i + FRESHA_VENUE_BATCH_SIZE);
      const input = {
        mode: 'venue',
        venueUrls: batch,
        includeReviews: false,
        includeTeam: false,
        outputFormat: 'full',
      };
      console.log(
          `[FRESHA IMPORT] malikgen venue batch · ${batch.length} urls`);
      const {items} = await runFreshaActor({token, input});
      all.push(...(items || []));
    }
    console.log(`[FRESHA IMPORT] venues=${all.length}`);
    return all;
  }

  /** @deprecated City discovery removed — use Google Places + scrapeVenues. */
  async discoverCity() {
    throw new Error(
        'Fresha city discovery disabled — use Google Places then scrapeVenues');
  }

  normalizeVenue(raw, {fallbackUrl = '', googleClinic = null} = {}) {
    if (!raw || typeof raw !== 'object') return null;
    const venueUrl = String(
        raw.url || raw.venueUrl || fallbackUrl || '').trim();
    const name = String(
        raw.venueName || raw.name ||
        (googleClinic && googleClinic.name) || '').trim();
    const freshaVenueId = String(
        raw.venueId || raw.slug || venueIdFromUrl(venueUrl) || '').trim();
    if (!name || !venueUrl) return null;
    const location = String(raw.location || raw.fullAddress || '').trim();
    return {
      provider: PROVIDER_FRESHA,
      freshaVenueId: freshaVenueId || venueIdFromUrl(venueUrl),
      name,
      venueUrl,
      rating: Number(raw.rating || 0) || 0,
      reviewsCount: Number(raw.reviewsCount || raw.reviews || 0) || 0,
      address: location || String((googleClinic && googleClinic.address) || ''),
      street: String(raw.street || '').trim(),
      city: String(raw.city || '').trim(),
      country: String(raw.country || '').trim(),
      latitude: Number(raw.latitude || raw.lat ||
          (googleClinic && googleClinic.lat) || 0) || 0,
      longitude: Number(raw.longitude || raw.lng ||
          (googleClinic && googleClinic.lng) || 0) || 0,
      currency: String(raw.currency || '').trim().toUpperCase(),
      phone: String(raw.phone || '').trim(),
      isFreshaVerified: raw.isFreshaVerified === true,
      website: String(raw.website || '').trim(),
      scrapedAt: String(raw.scrapedAt || new Date().toISOString()),
      rawCategories: raw.categories,
      rawServices: raw.services,
    };
  }

  normalizeServices(rawVenue, {venueUrl = ''} = {}) {
    const venue = this.normalizeVenue(rawVenue, {fallbackUrl: venueUrl}) ||
        (rawVenue && rawVenue.freshaVenueId ? rawVenue : null);
    if (!venue) return [];
    const items = flattenServiceItems(rawVenue);
    const rows = [];
    for (const item of items) {
      for (const priced of expandServicePriceRows(item, venue.currency)) {
        rows.push({
          ...priced,
          marketplaceVenueId: venue.freshaVenueId,
          venueUrl: venue.venueUrl || venueUrl,
          providerClinic: venue.name,
          sourcePlatform: PROVIDER_FRESHA,
        });
      }
    }
    console.log(
        `[FRESHA IMPORT] services=${rows.length} · venue="${venue.name}"`);
    return rows;
  }
}

module.exports = {
  FreshaProvider,
  parseNumericPrice,
  expandServicePriceRows,
  flattenServiceItems,
  runFreshaActor,
  venueHasMedicalAestheticServices,
  venueIsBeautyOnly,
  serviceLooksAesthetic,
  serviceLooksBeautyOnly,
};
