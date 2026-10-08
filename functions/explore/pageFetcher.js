'use strict';

const {htmlLooksLikeJsShell, hostOf} = require('./parsePrice');

const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

const MAX_BYTES = 1_500_000;
const FETCH_TIMEOUT_MS = 4000;

const PRIVATE_HOST = /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.|0\.|169\.254\.|\[::1\]|metadata\.google\.internal)/i;

class HttpClinicPageFetcher {
  constructor() {
    this.cache = new Map();
  }

  /**
   * @param {string} url
   * @return {Promise<{url:string, html:string, rendered:boolean, statusCode?:number, blocked?:boolean, jsShell?:boolean, needsRendering?:boolean}>}
   */
  async fetch(url) {
    const cached = this.cache.get(url);
    if (cached) return cached;
    const result = await this._fetchUncached(url);
    this.cache.set(url, result);
    return result;
  }

  async _fetchUncached(url) {
    const host = hostOf(url);
    if (!host || PRIVATE_HOST.test(host) || PRIVATE_HOST.test(url)) {
      return {url, html: '', rendered: false, blocked: true, statusCode: 0};
    }
    let parsed;
    try {
      parsed = new URL(url.includes('://') ? url : `https://${url}`);
    } catch (_) {
      return {url, html: '', rendered: false, blocked: true};
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return {url, html: '', rendered: false, blocked: true};
    }

    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
    try {
      const res = await fetch(parsed.toString(), {
        method: 'GET',
        redirect: 'follow',
        signal: ac.signal,
        headers: {
          'User-Agent': UA,
          Accept: 'text/html,application/xhtml+xml',
          'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
        },
      });
      const statusCode = res.status;
      if (statusCode === 403 || statusCode === 429) {
        console.log(`[FETCH] ${parsed} · HTTP ${statusCode} blocked`);
        return {url: parsed.toString(), html: '', rendered: false, blocked: true, statusCode};
      }
      const ctype = String(res.headers.get('content-type') || '');
      if (ctype && !/html|xml|json|text/i.test(ctype)) {
        return {url: parsed.toString(), html: '', rendered: false, statusCode};
      }
      const buf = Buffer.from(await res.arrayBuffer());
      const html = buf.subarray(0, MAX_BYTES).toString('utf8');
      const jsShell = htmlLooksLikeJsShell(html);
      if (jsShell) {
        console.log(`[FETCH] JS shell detected ${parsed}`);
      } else {
        console.log(`[FETCH] ${parsed} · HTTP ${statusCode}`);
      }
      return {
        url: parsed.toString(),
        html,
        rendered: false,
        statusCode,
        blocked: false,
        jsShell,
        needsRendering: jsShell,
      };
    } catch (e) {
      console.log(`[FETCH] failed ${url}: ${e.message || e}`);
      return {url, html: '', rendered: false, blocked: false, needsRendering: true};
    } finally {
      clearTimeout(timer);
    }
  }
}

module.exports = {HttpClinicPageFetcher};
