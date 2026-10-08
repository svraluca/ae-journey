'use strict';

/**
 * Zyte API browserHtml fallback — rendered HTML only.
 * Never reads AI extract / product / customAttributes fields as prices.
 */

const ZYTE_URL = 'https://api.zyte.com/v1/extract';

/**
 * @param {string} pageUrl
 * @param {string} [apiKey]
 * @return {Promise<string>} browser HTML or ''
 */
async function fetchZyteBrowserHtml(pageUrl, apiKey) {
  const key = String(apiKey || process.env.ZYTE_API_KEY || '').trim();
  const url = String(pageUrl || '').trim();
  if (!key || !url) return '';
  const target = url.includes('://') ? url : `https://${url}`;
  try {
    console.log(`[ZYTE FALLBACK] browserHtml · ${target}`);
    const auth = Buffer.from(`${key}:`).toString('base64');
    const res = await fetch(ZYTE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Basic ${auth}`,
      },
      body: JSON.stringify({
        url: target,
        browserHtml: true,
      }),
    });
    if (!res.ok) {
      console.log(`[ZYTE FALLBACK] HTTP ${res.status}`);
      return '';
    }
    const data = await res.json();
    for (const banned of [
      'product', 'productList', 'article', 'jobPosting',
      'customAttributes', 'extract', 'llm',
    ]) {
      if (data && Object.prototype.hasOwnProperty.call(data, banned)) {
        console.log(`[ZYTE FALLBACK] ignoring banned field "${banned}"`);
      }
    }
    const html = String((data && data.browserHtml) || '').trim();
    if (!html) {
      console.log('[ZYTE FALLBACK] empty browserHtml');
      return '';
    }
    console.log(`[ZYTE FALLBACK] ok · ${html.length} chars`);
    return html;
  } catch (e) {
    console.log(`[ZYTE FALLBACK] failed: ${e.message || e}`);
    return '';
  }
}

module.exports = {fetchZyteBrowserHtml};
