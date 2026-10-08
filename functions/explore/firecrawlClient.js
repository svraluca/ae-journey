'use strict';

/**
 * Firecrawl client for Explore URL discovery + page/PDF fetch.
 *
 * Rules:
 * - Map/search returns URLs only.
 * - Scrape returns raw HTML/markdown only.
 * - NEVER trust a Firecrawl "extract" / LLM price field — callers must run
 *   extractPriceEvidence → procedureMatch → priceSanity on the body.
 */

const MAP_URL = 'https://api.firecrawl.dev/v2/map';
const SCRAPE_URL = 'https://api.firecrawl.dev/v2/scrape';
const TIMEOUT_MS = 25000;

function apiKeyFromEnv() {
  return String(process.env.FIRECRAWL_API_KEY || '').trim();
}

/**
 * Turn Firecrawl markdown (including PDF parsers) into HTML so the existing
 * cheerio extractors can run unchanged. No amounts are invented here.
 */
function markdownToExtractableHtml(markdown) {
  const md = String(markdown || '').replace(/\r\n/g, '\n').trim();
  if (!md) return '';
  const lines = md.split('\n').map((l) => l.trim()).filter(Boolean);
  const parts = [];
  let inTable = false;
  for (const line of lines) {
    if (/^\|/.test(line) && /\|/.test(line.slice(1))) {
      if (/^\|?\s*-{2,}/.test(line.replace(/\s/g, ''))) continue;
      const cells = line
          .split('|')
          .map((c) => c.trim())
          .filter((c) => c.length > 0);
      if (cells.length < 2) continue;
      if (!inTable) {
        parts.push('<table>');
        inTable = true;
      }
      parts.push(
          `<tr>${cells.map((c) => `<td>${escapeHtml(c)}</td>`).join('')}</tr>`,
      );
      continue;
    }
    if (inTable) {
      parts.push('</table>');
      inTable = false;
    }
    if (/^[-*•]\s+/.test(line) || /^\d+\.\s+/.test(line)) {
      parts.push(`<li>${escapeHtml(line.replace(/^[-*•]\s+|^\d+\.\s+/, ''))}</li>`);
    } else {
      parts.push(`<p>${escapeHtml(line)}</p>`);
    }
  }
  if (inTable) parts.push('</table>');
  const body = parts.join('\n');
  if (!body) return '';
  return `<html><body>${body}</body></html>`;
}

function escapeHtml(s) {
  return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
}

/**
 * Prefer HTML; else wrap markdown. Never returns a structured price.
 * @return {{url:string, html:string, fromPdf:boolean}}
 */
function bodyFromScrapeResponse(json, fallbackUrl) {
  const data = json && (json.data || json);
  const meta = (data && data.metadata) || {};
  const url = String(
      (data && data.url) || meta.sourceURL || meta.url || fallbackUrl || '',
  ).trim();
  const html = String((data && data.html) || (data && data.rawHtml) || '').trim();
  const markdown = String((data && data.markdown) || '').trim();
  const fromPdf = /\.pdf(\?|#|$)/i.test(url) ||
      String(meta.contentType || '').toLowerCase().includes('pdf');
  if (html) return {url, html, fromPdf};
  if (markdown) {
    return {url, html: markdownToExtractableHtml(markdown), fromPdf};
  }
  return {url, html: '', fromPdf};
}

async function mapSite({
  siteUrl,
  search = '',
  limit = 40,
  apiKey = apiKeyFromEnv(),
  includeSubdomains = false,
} = {}) {
  const key = String(apiKey || '').trim();
  if (!key) {
    console.log('[FIRECRAWL] map skipped — FIRECRAWL_API_KEY not set');
    return [];
  }
  const url = String(siteUrl || '').trim();
  if (!url) return [];
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
  try {
    console.log(`[FIRECRAWL] map ${url} search="${search}"`);
    const res = await fetch(MAP_URL, {
      method: 'POST',
      signal: ac.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        url: url.includes('://') ? url : `https://${url}`,
        search: String(search || '').trim() || undefined,
        limit: Math.min(100, Math.max(5, Number(limit) || 40)),
        includeSubdomains: Boolean(includeSubdomains),
        sitemap: 'include',
      }),
    });
    if (!res.ok) {
      console.log(`[FIRECRAWL] map HTTP ${res.status}`);
      return [];
    }
    const json = await res.json();
    const links = [];
    const raw = json.links || (json.data && json.data.links) || [];
    for (const item of Array.isArray(raw) ? raw : []) {
      if (typeof item === 'string') {
        links.push(item);
        continue;
      }
      if (item && typeof item === 'object') {
        const u = String(item.url || item.href || '').trim();
        if (u) links.push(u);
      }
    }
    console.log(`[FIRECRAWL] map → ${links.length} urls`);
    return links;
  } catch (e) {
    console.log(`[FIRECRAWL] map failed: ${e.message || e}`);
    return [];
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Fetch page or PDF body for the deterministic extractor.
 * Uses formats html+markdown; PDFs go through Firecrawl's pdf parser → markdown.
 */
async function scrapeSitePage({
  pageUrl,
  apiKey = apiKeyFromEnv(),
} = {}) {
  const key = String(apiKey || '').trim();
  const url = String(pageUrl || '').trim();
  if (!key || !url) {
    return {url, html: '', fromPdf: false};
  }
  const isPdf = /\.pdf(\?|#|$)/i.test(url);
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
  try {
    console.log(`[FIRECRAWL] scrape ${url}${isPdf ? ' (pdf)' : ''}`);
    const body = {
      url: url.includes('://') ? url : `https://${url}`,
      formats: ['html', 'markdown'],
      onlyMainContent: false,
    };
    if (isPdf) {
      body.parsers = ['pdf'];
    }
    const res = await fetch(SCRAPE_URL, {
      method: 'POST',
      signal: ac.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${key}`,
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      console.log(`[FIRECRAWL] scrape HTTP ${res.status}`);
      return {url, html: '', fromPdf: isPdf};
    }
    const json = await res.json();
    const parsed = bodyFromScrapeResponse(json, url);
    console.log(
        `[FIRECRAWL] scrape → ${parsed.html.length} html chars` +
        (parsed.fromPdf ? ' (pdf→markdown)' : ''),
    );
    return parsed;
  } catch (e) {
    console.log(`[FIRECRAWL] scrape failed: ${e.message || e}`);
    return {url, html: '', fromPdf: isPdf};
  } finally {
    clearTimeout(timer);
  }
}

module.exports = {
  mapSite,
  scrapeSitePage,
  markdownToExtractableHtml,
  bodyFromScrapeResponse,
  apiKeyFromEnv,
};
