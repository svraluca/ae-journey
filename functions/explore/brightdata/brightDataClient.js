'use strict';

/**
 * Shared Bright Data HTTP client.
 * Authorization: Bearer <BRIGHTDATA_API_KEY>
 * Never logs the API key.
 */

const REQUEST_URL = 'https://api.brightdata.com/request';

function brightDataApiKey() {
  return String(process.env.BRIGHTDATA_API_KEY || '').trim();
}

function brightDataConfigured() {
  return brightDataApiKey().length > 0;
}

/**
 * POST /request — SERP zone or Unlocker zone.
 * @return {Promise<{ok:boolean, status:number, body:string, json:object|null}>}
 */
async function brightDataRequest({
  zone,
  url,
  format = 'raw',
  method = 'GET',
  timeoutMs = 25000,
} = {}) {
  const key = brightDataApiKey();
  const z = String(zone || '').trim();
  const target = String(url || '').trim();
  if (!key || !z || !target) {
    return {ok: false, status: 0, body: '', json: null};
  }
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetch(REQUEST_URL, {
      method: 'POST',
      signal: ac.signal,
      headers: {
        Authorization: `Bearer ${key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        zone: z,
        url: target,
        format,
        method,
      }),
    });
    const body = await res.text();
    let json = null;
    try {
      json = JSON.parse(body);
    } catch (_) {
      json = null;
    }
    if (!res.ok) {
      console.log(`[BRIGHTDATA] request HTTP ${res.status} · zone=${z}`);
      return {ok: false, status: res.status, body, json};
    }
    return {ok: true, status: res.status, body, json};
  } catch (e) {
    console.log(`[BRIGHTDATA] request failed · ${e.message || e}`);
    return {ok: false, status: 0, body: '', json: null};
  } finally {
    clearTimeout(timer);
  }
}

module.exports = {
  REQUEST_URL,
  brightDataApiKey,
  brightDataConfigured,
  brightDataRequest,
};
