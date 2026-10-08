'use strict';

/**
 * Internal Cloud Run renderer. Not an open proxy.
 * POST /render { "url": "https://..." } → { html, url, statusCode }
 */

const http = require('http');
const dns = require('dns').promises;
const {chromium} = require('playwright');

const PORT = Number(process.env.PORT || 8080);
const TOKEN = String(process.env.RENDERER_TOKEN || '').trim();
const NAV_TIMEOUT_MS = 12000;
const MAX_HTML = 1_500_000;

const BLOCKED_HOST = /^(localhost|127\.|0\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.|169\.254\.|metadata\.google\.internal|\[::1\])/i;

let browserPromise = null;

function getBrowser() {
  if (!browserPromise) {
    browserPromise = chromium.launch({
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    });
  }
  return browserPromise;
}

function isPrivateIp(ip) {
  if (!ip) return true;
  if (ip === '::1' || ip === '0.0.0.0') return true;
  if (ip.startsWith('127.') || ip.startsWith('10.') || ip.startsWith('192.168.') ||
      ip.startsWith('169.254.')) return true;
  const m = ip.match(/^172\.(\d+)\./);
  if (m && Number(m[1]) >= 16 && Number(m[1]) <= 31) return true;
  // GCP metadata
  if (ip === '169.254.169.254') return true;
  return false;
}

async function assertSafeUrl(raw) {
  let u;
  try {
    u = new URL(raw);
  } catch (_) {
    throw new Error('invalid_url');
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') {
    throw new Error('invalid_scheme');
  }
  if (u.username || u.password) throw new Error('userinfo_not_allowed');
  if (BLOCKED_HOST.test(u.hostname)) throw new Error('blocked_host');
  const resolved = await dns.lookup(u.hostname, {all: true});
  for (const row of resolved) {
    if (isPrivateIp(row.address)) throw new Error('private_ip');
  }
  return u.toString();
}

async function render(url) {
  const safe = await assertSafeUrl(url);
  const browser = await getBrowser();
  const context = await browser.newContext({
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    javaScriptEnabled: true,
  });
  const page = await context.newPage();
  await page.route('**/*', (route) => {
    const type = route.request().resourceType();
    if (['image', 'media', 'font'].includes(type)) return route.abort();
    return route.continue();
  });
  try {
    const res = await page.goto(safe, {
      waitUntil: 'domcontentloaded',
      timeout: NAV_TIMEOUT_MS,
    });
    await page.waitForTimeout(800);
    let html = await page.content();
    if (html.length > MAX_HTML) html = html.slice(0, MAX_HTML);
    return {url: page.url(), html, statusCode: res ? res.status() : 200};
  } finally {
    await context.close();
  }
}

function unauthorized(req) {
  if (!TOKEN) return false;
  const hdr = String(req.headers.authorization || '');
  return hdr !== `Bearer ${TOKEN}`;
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, {'Content-Type': 'text/plain'});
    res.end('ok');
    return;
  }
  if (req.method !== 'POST' || req.url !== '/render') {
    res.writeHead(404);
    res.end();
    return;
  }
  if (unauthorized(req)) {
    res.writeHead(401);
    res.end('unauthorized');
    return;
  }
  let body = '';
  req.on('data', (c) => {
    body += c;
    if (body.length > 8000) req.destroy();
  });
  req.on('end', async () => {
    try {
      const json = JSON.parse(body || '{}');
      const url = String(json.url || '').trim();
      if (!url) {
        res.writeHead(400);
        res.end(JSON.stringify({error: 'url_required'}));
        return;
      }
      const out = await render(url);
      res.writeHead(200, {'Content-Type': 'application/json'});
      res.end(JSON.stringify(out));
    } catch (e) {
      const msg = e.message || String(e);
      const code = /invalid|blocked|private|scheme/.test(msg) ? 400 : 500;
      res.writeHead(code, {'Content-Type': 'application/json'});
      res.end(JSON.stringify({error: msg, html: ''}));
    }
  });
});

server.listen(PORT, () => {
  console.log(`[renderer] listening on ${PORT}`);
});
