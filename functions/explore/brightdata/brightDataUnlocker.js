'use strict';

const {brightDataRequest, brightDataConfigured} = require('./brightDataClient');
const {useBrightData} = require('../featureFlags');

/**
 * Bright Data Web Unlocker — returns page HTML only.
 * Never trusts numeric prices from Bright Data metadata.
 */
async function fetchUnlockedHtml(pageUrl, {
  zone = process.env.BRIGHTDATA_UNLOCKER_ZONE,
  timeoutMs = 28000,
} = {}) {
  if (!useBrightData() || !brightDataConfigured()) return '';
  const z = String(zone || '').trim();
  const url = String(pageUrl || '').trim();
  if (!z || !url) return '';
  const target = url.includes('://') ? url : `https://${url}`;
  console.log(`[BRIGHTDATA UNLOCK] ${target}`);
  const res = await brightDataRequest({
    zone: z,
    url: target,
    format: 'raw',
    timeoutMs,
  });
  if (!res.ok) return '';
  // Raw HTML body — if JSON wrapper, try common fields then fall back.
  let html = '';
  if (res.json && typeof res.json === 'object') {
    html = String(
        res.json.html ||
        res.json.body ||
        res.json.content ||
        res.json.page_html ||
        '',
    ).trim();
  }
  if (!html) html = String(res.body || '').trim();
  // Reject obvious non-HTML JSON error payloads.
  if (html.startsWith('{') && html.includes('"error"') && html.length < 2000) {
    console.log('[BRIGHTDATA UNLOCK] error payload');
    return '';
  }
  if (!html || html.length < 80) {
    console.log('[BRIGHTDATA UNLOCK] empty');
    return '';
  }
  console.log(`[BRIGHTDATA UNLOCK] ok · ${html.length} chars`);
  return html;
}

module.exports = {fetchUnlockedHtml};
