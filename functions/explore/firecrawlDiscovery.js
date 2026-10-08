'use strict';

const {mapSite, scrapeSitePage, apiKeyFromEnv} = require('./firecrawlClient');
const {rankAndPickUrls, isPdfUrl, discoverSitemapUrls} = require('./urlRank');
const {loadCachedSiteUrls, saveCachedSiteUrls} = require('./siteUrlCache');
const {extractPriceEvidence} = require('./priceExtractor');
const {hostOf, isNonLiteralClinicPriceUrl} = require('./parsePrice');
const {WORLD_SITE_PRICE_WORDS, localeForCity} = require('./searchLocale');
const {fetchZyteBrowserHtml} = require('./zyteClient');

/**
 * Build Firecrawl /map search string: procedure + local + world price words.
 */
function firecrawlMapSearch({procedure, city}) {
  const proc = String(procedure || '').trim();
  const loc = localeForCity(city);
  const words = new Set([
    loc.priceWord,
    ...WORLD_SITE_PRICE_WORDS.slice(0, 8),
    'fees',
    'fee',
  ].filter(Boolean));
  const parts = [proc, ...[...words].slice(0, 6)].filter(Boolean);
  return parts.join(' ').replace(/\s+/g, ' ').trim().slice(0, 120);
}

/**
 * After HTTP + guessed paths + Serper failed, discover URLs via sitemap and
 * optional Firecrawl map. Cached host URLs are preferred.
 */
async function discoverFirecrawlUrls({
  websiteUrl,
  procedure,
  city,
  clinicName = '',
  maxUrls = 5,
}) {
  const host = hostOf(websiteUrl);
  if (!host) return [];

  const cached = await loadCachedSiteUrls(host);
  if (cached.length) {
    const picked = rankAndPickUrls(cached, {procedure, max: maxUrls, host, city});
    if (picked.length) {
      console.log(`[FIRECRAWL] cache hit ${host} · ${picked.length} urls`);
      return picked;
    }
  }

  const base = websiteUrl.includes('://')
    ? websiteUrl.replace(/\/+$/, '')
    : `https://${host}`;

  const sitemap = await discoverSitemapUrls(host);
  let mapped = [];
  if (apiKeyFromEnv()) {
    const search = firecrawlMapSearch({procedure, city});
    mapped = await mapSite({
      siteUrl: base,
      search,
      limit: 50,
    });
  }
  const filtered = [...sitemap, ...mapped]
      .filter((u) => !isNonLiteralClinicPriceUrl(u));
  const picked = rankAndPickUrls(filtered, {procedure, max: maxUrls, host, city});
  if (picked.length) {
    await saveCachedSiteUrls({
      hostOrUrl: host,
      urls: picked,
      procedure,
      city,
      clinicName,
      source: sitemap.length ? 'sitemap_firecrawl' : 'firecrawl_map',
    });
  }
  return picked;
}

/**
 * Fetch Firecrawl bodies (HTML or PDF→markdown→HTML) and run extractPriceEvidence.
 * Firecrawl never supplies a trusted numeric price — only page text.
 *
 * @param {object} opts
 * @param {string[]} opts.urls
 * @param {import('./pageFetcher').HttpClinicPageFetcher} [opts.fetcher]
 *   Prefer HTTP(+Playwright) for HTML; Firecrawl scrape for PDFs / empty HTTP.
 * @param {Function} [opts.htmlForUrl] async (url) => {html,url}
 */
async function evidenceFromFirecrawlUrls({
  urls,
  procedure,
  city,
  clinicName = '',
  htmlForUrl,
}) {
  const all = [];
  const useful = [];
  for (const url of urls || []) {
    if (!url || isNonLiteralClinicPriceUrl(url)) continue;
    let html = '';
    let sourceUrl = url;

    if (isPdfUrl(url) || !htmlForUrl) {
      const scraped = await scrapeSitePage({pageUrl: url});
      html = scraped.html || '';
      sourceUrl = scraped.url || url;
    } else {
      const page = await htmlForUrl(url);
      html = (page && page.html) || '';
      sourceUrl = (page && page.url) || url;
      if (!html) {
        const scraped = await scrapeSitePage({pageUrl: url});
        html = scraped.html || '';
        sourceUrl = scraped.url || url;
      }
      if (!html && !isPdfUrl(url)) {
        html = await fetchZyteBrowserHtml(url);
        if (html) sourceUrl = url;
      }
    }

    if (!html) continue;
    const rows = extractPriceEvidence({html, sourceUrl});
    if (rows.length) {
      console.log(`[FIRECRAWL] extract ${rows.length} rows · ${sourceUrl}`);
      useful.push({
        url: sourceUrl,
        extractionMethod: String(rows[0].extractionMethod || ''),
        procedureFamily: String(rows[0].procedureFamily || ''),
      });
      all.push(...rows);
    }
  }
  if (useful.length) {
    await saveCachedSiteUrls({
      hostOrUrl: useful[0].url,
      entries: useful,
      procedure,
      city,
      clinicName,
      source: 'firecrawl_useful',
    });
  }
  return all;
}

module.exports = {
  firecrawlMapSearch,
  discoverFirecrawlUrls,
  evidenceFromFirecrawlUrls,
};
