'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  serpProviderKind,
  dataForSeoAuthHeader,
  dataForSeoLocationCode,
  dataForSeoDepth,
  serperHeaders,
  serperRequestBody,
  serperKeyUnusable,
  parseSerperOrganic,
  SERPER_ENDPOINT,
  dataForSeoRequestBody,
  dataForSeoStatusError,
  dataForSeoStatus,
  parseDataForSeoOrganic,
  parseSerpApiOrganic,
} = require('../serpProvider');

test('A — Serper leads, then DataForSEO, then SerpApi', () => {
  assert.equal(
      serpProviderKind({
        serperApiKey: 'serper',
        dataForSeoLogin: 'me@glowpass.app',
        dataForSeoPassword: 'pw',
        serpApiKey: 'serp',
      }),
      'serper',
  );
  assert.equal(
      serpProviderKind({
        dataForSeoLogin: 'me@glowpass.app',
        dataForSeoPassword: 'pw',
        serpApiKey: 'serp',
      }),
      'dataforseo',
  );
  assert.equal(
      serpProviderKind({dataForSeoLogin: 'me@glowpass.app', dataForSeoPassword: '', serpApiKey: 'serp'}),
      'serpapi',
  );
  assert.equal(
      serpProviderKind({dataForSeoLogin: '', dataForSeoPassword: '', serpApiKey: ''}),
      'none',
  );
});

test('A2 — Serper asks Google plainly and reads URLs, not prices', () => {
  assert.equal(SERPER_ENDPOINT, 'https://google.serper.dev/search');
  assert.equal(serperHeaders(' key ')['X-API-KEY'], 'key');

  const body = serperRequestBody({query: 'بوتوكس سعر Dubai', hl: 'ar', gl: 'ae'});
  assert.equal(body.q, 'بوتوكس سعر Dubai');
  assert.equal(body.hl, 'ar');
  assert.equal(body.gl, 'ae');
  // Serper serves one page whatever `num` asks for, and asking for more only
  // doubled the response time.
  assert.equal('num' in body, false);
  assert.equal('gl' in serperRequestBody({query: 'botox nairobi'}), false);
  assert.equal(serperRequestBody({query: 'q', gl: 'uk'}).gl, 'gb');

  assert.equal(serperKeyUnusable(401), true);
  assert.equal(serperKeyUnusable(403), true);
  assert.equal(serperKeyUnusable(429), false);
  assert.equal(serperKeyUnusable(503), false);

  const hits = parseSerperOrganic({
    organic: [
      {
        title: 'Botox Dubai | Prices',
        link: 'https://euromedclinicdubai.com/botox',
        snippet: 'Botox from AED 1200 per area',
        displayedLink: 'euromedclinicdubai.com',
      },
      {title: 'no link'},
    ],
    answerBox: {snippet: 'Botox costs AED 800'},
  });
  assert.equal(hits.length, 2);
  assert.equal(hits[0].url, 'https://euromedclinicdubai.com/botox');
});

test('B — Dubai queries carry the UAE location and Arabic language', () => {
  assert.equal(dataForSeoLocationCode('ae'), 2784);
  assert.equal(dataForSeoLocationCode('uk'), 2826);
  assert.equal(dataForSeoLocationCode('ro'), 2642);
  assert.equal(dataForSeoLocationCode('zz'), null);

  const [task] = dataForSeoRequestBody({
    query: 'اسعار البوتوكس دبي',
    hl: 'ar',
    gl: 'ae',
  });
  assert.equal(task.keyword, 'اسعار البوتوكس دبي');
  assert.equal(task.location_code, 2784);
  assert.equal(task.language_code, 'ar');
  assert.equal(task.depth, 10);
});

test('B2 — DataForSEO city sweeps go deep, site: stays shallow', () => {
  assert.equal(dataForSeoDepth('بوتوكس سعر Dubai'), 30);
  assert.equal(dataForSeoDepth('Botox prices in Dubai'), 30);
  assert.equal(dataForSeoDepth('Lucia Clinic Botox price site:luciaclinic.com'), 10);
  const [task] = dataForSeoRequestBody({
    query: 'Botox prices in Dubai',
    gl: 'ae',
    depth: dataForSeoDepth('Botox prices in Dubai'),
  });
  assert.equal(task.depth, 30);
});

test('C — unmapped markets fall back to google.com instead of failing', () => {
  const [task] = dataForSeoRequestBody({query: 'botox nairobi price', gl: ''});
  assert.equal(task.location_code, 2840);
  assert.equal(task.language_code, 'en');
});

test('D — auth header is Basic base64(login:password)', () => {
  assert.equal(
      dataForSeoAuthHeader('me@glowpass.app', 'pw'),
      `Basic ${Buffer.from('me@glowpass.app:pw', 'utf8').toString('base64')}`,
  );
});

test('E — organic rows parse to url/title/snippet, other items ignored', () => {
  const hits = parseDataForSeoOrganic({
    status_code: 20000,
    tasks: [
      {
        status_code: 20000,
        result: [
          {
            items: [
              {type: 'people_also_ask', title: 'How much is botox?'},
              {
                type: 'organic',
                title: 'Botox Dubai — Price List',
                url: 'https://tajmeel.ae/prices',
                description: 'Botox from AED 750 per area',
                breadcrumb: 'https://tajmeel.ae › prices',
              },
            ],
          },
        ],
      },
    ],
  });
  assert.equal(hits.length, 1);
  assert.deepEqual(hits[0], {
    title: 'Botox Dubai — Price List',
    url: 'https://tajmeel.ae/prices',
    snippet: 'Botox from AED 750 per area',
    displayedLink: 'https://tajmeel.ae › prices',
  });
  // Discovery hands back no price field of any kind.
  assert.equal('price' in hits[0], false);
});

test('F — task-level errors are reported, not silently parsed', () => {
  assert.match(
      dataForSeoStatusError({status_code: 40100, status_message: 'Auth failed'}),
      /40100/,
  );
  assert.match(
      dataForSeoStatusError({
        status_code: 20000,
        tasks: [{status_code: 40501, status_message: 'Invalid Field'}],
      }),
      /40501/,
  );
  assert.equal(
      dataForSeoStatusError({status_code: 20000, tasks: [{status_code: 20000, result: []}]}),
      '',
  );
});

test('G — account problems disable the provider, SE hiccups only retry', () => {
  const bad = dataForSeoStatus({status_code: 40100, status_message: 'Unauthorized'});
  assert.equal(bad.providerUnusable, true);
  assert.equal(bad.retryable, false);

  const broke = dataForSeoStatus({
    status_code: 20000,
    tasks: [{status_code: 40101, status_message: 'Internal SE Server Error.'}],
  });
  assert.equal(broke.providerUnusable, false);
  assert.equal(broke.retryable, true);

  const funds = dataForSeoStatus({
    status_code: 20000,
    tasks: [{status_code: 40210, status_message: 'Insufficient Funds.'}],
  });
  assert.equal(funds.providerUnusable, true);

  const throttled = dataForSeoStatus({
    status_code: 20000,
    tasks: [{status_code: 40202, status_message: 'rate-limit per minute'}],
  });
  assert.equal(throttled.rateLimited, true);
  assert.equal(throttled.providerUnusable, false);

  const empty = dataForSeoStatus({
    status_code: 20000,
    tasks: [{status_code: 40102, status_message: 'No Search Results.'}],
  });
  assert.equal(empty.noResults, true);

  const fine = dataForSeoStatus({
    status_code: 20000,
    tasks: [{status_code: 20000, result: []}],
  });
  assert.equal(fine.ok, true);
  assert.equal(fine.logLine, '');
});

test('H — SerpApi rows still parse while the fallback exists', () => {
  const hits = parseSerpApiOrganic({
    organic_results: [
      {
        title: 'Fillers Dubai',
        link: 'https://skin111.com/price-list',
        snippet: 'Lip filler 1,900 AED',
        displayed_link: 'skin111.com › price-list',
      },
      {snippet: ''},
    ],
  });
  assert.equal(hits.length, 1);
  assert.equal(hits[0].url, 'https://skin111.com/price-list');
});
