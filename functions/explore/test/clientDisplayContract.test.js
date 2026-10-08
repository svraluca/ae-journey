'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {EXTRACT_REVISION} = require('../extractRevision');
const {classifyExplorePricePageContext, exploreNormalizeProcedureDisplayName} = require('../priceOwnership');

test('backend price stamp matches the actual Flutter verifier', () => {
  const dart = fs.readFileSync(path.join(__dirname,
      '../../../lib/services/explore_price_sanity.dart'), 'utf8');
  const stamp = /const kExplorePriceExtractRevision = '([^']+)';/.exec(dart);
  assert.ok(stamp, 'Client extraction revision must be declared');
  assert.equal(EXTRACT_REVISION, stamp[1]);
});

test('published treatment label is preserved instead of the category name', () => {
  assert.equal(exploreNormalizeProcedureDisplayName({procedureCanonical: 'botox',
    rawProcedureText: 'Toxina botulínica (3 zonas)'}), 'Toxina botulínica (3 zonas)');
  assert.equal(exploreNormalizeProcedureDisplayName({procedureCanonical: 'filler',
    rawProcedureText: 'Aumento labial Teosyal RHA Kiss 1 ml'}), 'Aumento labial Teosyal RHA Kiss 1 ml');
  assert.equal(exploreNormalizeProcedureDisplayName({procedureCanonical: 'botox',
    rawProcedureText: 'How much does Botox cost?'}), 'Botox');
});

test('official tariff guide stays owned while averages and foreign guides remain excluded', () => {
  assert.equal(classifyExplorePricePageContext({sourceUrl: 'https://clinic.example/price-guide/',
    pageText: 'Rhinoplasty £7,995'}), 'official_price_list');
  assert.equal(classifyExplorePricePageContext({sourceUrl: 'https://clinic.example/price-guide/',
    pageText: 'On average Rhinoplasty costs £7,995.'}), 'market_average');
  assert.equal(classifyExplorePricePageContext({sourceUrl: 'https://clinic.example/price-guide/turkey/',
    pageText: 'Rhinoplasty £7,995'}), 'country_cost_guide');
});
