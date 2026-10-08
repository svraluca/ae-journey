'use strict';

const {hostOf} = require('./parsePrice');
const {rendererUrl} = require('./secrets');

const PRIVATE = /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.|0\.|169\.254\.|\[::1\]|metadata\.google\.internal)/i;

/**
 * Optional Cloud Run Playwright client. Never invents HTML.
 * If RENDERER_URL is unset, returns needsRendering without faking a parse.
 */
async function renderIfNeeded(url) {
  const base = String(rendererUrl.value() || process.env.RENDERER_URL || '')
      .replace(/\/+$/, '');
  if (!base) {
    console.log('[RENDER] skipped — RENDERER_URL not set');
    return {url, html: '', rendered: false, needsRendering: true};
  }
  const host = hostOf(url);
  if (!host || PRIVATE.test(host) || PRIVATE.test(url)) {
    return {url, html: '', rendered: false, blocked: true};
  }
  const token = String(process.env.RENDERER_TOKEN || '').trim();
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), 25000);
  try {
    console.log('[RENDER] Cloud Run Playwright');
    const res = await fetch(`${base}/render`, {
      method: 'POST',
      signal: ac.signal,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? {Authorization: `Bearer ${token}`} : {}),
      },
      body: JSON.stringify({url}),
    });
    if (!res.ok) {
      console.log(`[RENDER] HTTP ${res.status}`);
      return {url, html: '', rendered: false, needsRendering: true, statusCode: res.status};
    }
    const json = await res.json();
    const html = String(json.html || '');
    console.log('[RENDER] success');
    return {
      url: json.url || url,
      html,
      rendered: true,
      statusCode: json.statusCode || 200,
      jsShell: false,
      needsRendering: false,
    };
  } catch (e) {
    console.log(`[RENDER] failed: ${e.message || e}`);
    return {url, html: '', rendered: false, needsRendering: true};
  } finally {
    clearTimeout(timer);
  }
}

module.exports = {renderIfNeeded};
