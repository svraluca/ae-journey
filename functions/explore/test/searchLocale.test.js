'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  localeForCity,
  buildSerpQuery,
  clinicWordForCity,
  pricePathsForHost,
  WORLD_SITE_PRICE_WORDS,
} = require('../searchLocale');

test('catalog site: search is worldwide, not Spain-only precio', () => {
  const q = buildSerpQuery({
    city: 'București',
    procedure: 'rhinoplasty',
    websiteHost: 'any-clinic.ro',
  });
  assert.match(q, /site:any-clinic\.ro/);
  assert.match(q, /rinoplastie/);
  assert.match(q, /\bpret\b/);
  assert.match(q, /\bprices\b/);
  assert.match(q, /\bprecio\b/);
  assert.match(q, /\bprix\b/);
  assert.ok(WORLD_SITE_PRICE_WORDS.includes('preturi'));
});

test('city queries use local price words in every market', () => {
  assert.match(
    buildSerpQuery({city: 'Barcelona', procedure: 'rhinoplasty'}),
    /rinoplastia precio Barcelona/i,
  );
  assert.match(
    buildSerpQuery({city: 'Paris', procedure: 'rhinoplasty'}),
    /rhinoplastie prix Paris/i,
  );
  assert.match(
    buildSerpQuery({city: 'London', procedure: 'rhinoplasty'}),
    /rhinoplasty prices London/i,
  );
  assert.match(
    buildSerpQuery({city: 'Istanbul', procedure: 'rhinoplasty'}),
    /rinoplasti fiyat Istanbul/i,
  );
  assert.match(
    buildSerpQuery({city: 'Seoul', procedure: 'rhinoplasty'}),
    /코성형/,
  );
  assert.match(
    buildSerpQuery({city: 'București', procedure: 'hair transplant'}),
    /transplant par pret/i,
  );
  assert.match(
    buildSerpQuery({city: 'Dubai', procedure: 'dermal filler'}),
    /فيلر/,
  );
  assert.match(
    buildSerpQuery({city: 'Dubai', procedure: 'Botox'}),
    /بوتوكس/,
  );
  assert.match(
    buildSerpQuery({city: 'Dubai', procedure: 'rhinoplasty'}),
    /تجميل الانف/,
  );
  assert.match(
    buildSerpQuery({city: 'Dubai', procedure: 'breast augmentation'}),
    /تكبير الثدي/,
  );
  assert.match(
    buildSerpQuery({city: 'Dubai', procedure: 'hair transplant'}),
    /زراعة الشعر/,
  );
});

test('Places clinic word follows the city language', () => {
  assert.equal(clinicWordForCity('Barcelona'), 'clinica');
  assert.equal(clinicWordForCity('București'), 'clinica');
  assert.equal(clinicWordForCity('Paris'), 'clinique');
  assert.equal(clinicWordForCity('Berlin'), 'klinik');
  assert.equal(clinicWordForCity('London'), 'clinic');
  assert.equal(clinicWordForCity('Nairobi'), 'clinic');
  assert.equal(clinicWordForCity('Dubai'), 'عيادة');
});

test('Google gl follows the city, unknown cities are not pinned to ES/RO', () => {
  assert.equal(localeForCity('Barcelona').gl, 'es');
  assert.equal(localeForCity('București').gl, 'ro');
  assert.equal(localeForCity('London').gl, 'uk');
  assert.equal(localeForCity('New York').gl, 'us');
  assert.equal(localeForCity('Nairobi').gl, '');
  assert.equal(localeForCity('Worldwide').gl, '');
});

test('countryCode overrides city name for locale (BG)', () => {
  const bg = localeForCity('Sofia', {countryCode: 'BG'});
  assert.equal(bg.lang, 'bg');
  assert.equal(bg.gl, 'bg');
  assert.equal(bg.priceWord, 'цена');
  assert.equal(bg.clinicWord, 'клиника');
  assert.equal(localeForCity('Paris', {countryCode: 'BG'}).lang, 'bg');
  assert.ok(WORLD_SITE_PRICE_WORDS.includes('ценоразпис'));
  assert.match(
      buildSerpQuery({city: 'Sofia', procedure: 'Botox', countryCode: 'BG'}),
      /ботокс цена Sofia/i,
  );
  assert.match(
      buildSerpQuery({
        city: 'Sofia',
        procedure: 'rhinoplasty',
        countryCode: 'BG',
      }),
      /ринопластика/,
  );
});

test('price menu probes are generic by TLD, not a clinic allowlist', () => {
  assert.ok(pricePathsForHost('any-clinic.ro').includes('/preturi'));
  assert.ok(pricePathsForHost('clinica.es').includes('/precios'));
  assert.ok(pricePathsForHost('clinique.fr').includes('/tarifs'));
  assert.ok(pricePathsForHost('clinic.co.uk').includes('/prices'));
  assert.ok(pricePathsForHost('klinik.de').includes('/preise'));
  assert.ok(pricePathsForHost('clinic.ae').includes('/prices'));
});
