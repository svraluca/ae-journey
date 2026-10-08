'use strict';

const assert = require('assert');
const {
  scorePriceUrl,
  rankAndPickUrls,
  isPdfUrl,
} = require('../urlRank');
const {
  markdownToExtractableHtml,
  bodyFromScrapeResponse,
} = require('../firecrawlClient');
const {firecrawlMapSearch} = require('../firecrawlDiscovery');
const {extractPriceEvidence} = require('../priceExtractor');
const {selectEvidenceForProcedure} = require('../procedureMatch');
const {evaluateExtractedPriceCandidate} = require('../priceSanity');

function testUrlRank() {
  assert.ok(scorePriceUrl('https://clinic.ae/en/prices') >= 3);
  assert.ok(scorePriceUrl('https://clinic.ae/pricelist.pdf') >= 3);
  assert.ok(isPdfUrl('https://clinic.ae/menu.pdf'));
  const picked = rankAndPickUrls([
    'https://clinic.ae/',
    'https://clinic.ae/blog/hello',
    'https://clinic.ae/en/botox-prices',
    'https://clinic.ae/prices.pdf',
    'https://other.com/prices',
  ], {procedure: 'botox', max: 5, host: 'clinic.ae'});
  assert.ok(picked.length >= 1);
  assert.ok(picked.every((u) => u.includes('clinic.ae')));
  assert.ok(picked.some((u) => u.includes('botox') || u.includes('pdf') || u.includes('price')));
  console.log('ok urlRank');
}

function testMarkdownExtractPipeline() {
  const md = `
| Treatment | Price |
|-----------|-------|
| Botox forehead | 799 AED |
| Lip filler 1ml | 1200 AED |
`;
  const html = markdownToExtractableHtml(md);
  assert.ok(html.includes('<table>'));
  const rows = extractPriceEvidence({
    html,
    sourceUrl: 'https://clinic.ae/prices.pdf',
  });
  assert.ok(rows.length >= 1, 'expected extracted rows from pdf markdown');
  const picked = selectEvidenceForProcedure(rows, 'Botox anti-wrinkle injection');
  assert.ok(picked, 'procedure match should pick botox row');
  const sanity = evaluateExtractedPriceCandidate({
    rawPriceText: picked.rawPriceText,
    priceMin: picked.priceMin,
    currency: picked.currency,
    extractionMethod: picked.extractionMethod,
    rawEvidence: picked.rawEvidence,
    procedure: 'Botox',
  });
  assert.ok(sanity.accepted, sanity.reason);
  // Firecrawl scrape response must never invent a price field we trust
  const body = bodyFromScrapeResponse({
    data: {
      url: 'https://clinic.ae/prices.pdf',
      markdown: md,
      // Ignored — we do not read extract/price from Firecrawl
      extract: {price: 1, currency: 'USD'},
    },
  }, 'https://clinic.ae/prices.pdf');
  assert.ok(body.html.includes('799'));
  assert.ok(!('price' in body));
  console.log('ok firecrawl markdown → extractPriceEvidence');
}

function testMapSearch() {
  const s = firecrawlMapSearch({
    procedure: 'Botox',
    city: 'Abu Dhabi',
  });
  assert.ok(/botox/i.test(s));
  assert.ok(/price|سعر|fees|fee/i.test(s));
  console.log('ok firecrawlMapSearch');
}

testUrlRank();
testMarkdownExtractPipeline();
testMapSearch();
console.log('firecrawlDiscovery tests passed');
