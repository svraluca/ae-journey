'use strict';

const {describe, it} = require('node:test');
const assert = require('node:assert/strict');

const {
  freshaLocationForCity,
  countryCodeForCity,
  importCityKey,
} = require('../marketplaces/locationFormat');
const {
  parseNumericPrice,
  expandServicePriceRows,
  FreshaProvider,
  venueHasMedicalAestheticServices,
  venueIsBeautyOnly,
} = require('../marketplaces/freshaProvider');
const {classifyFreshaService} = require('../marketplaces/procedureMap');
const {pickFromPricesByProcedure} = require('../marketplaces/importCity');
const {
  extractFreshaVenueUrl,
  freshaUrlMatchesClinic,
} = require('../marketplaces/freshaUrlFinder');
const {hasUsefulImport} = require('../marketplaces/importState');

describe('fresha locationFormat', () => {
  it('maps cities dynamically', () => {
    assert.equal(freshaLocationForCity('Dubai'), 'Dubai, AE');
    assert.equal(freshaLocationForCity('London'), 'London, UK');
    assert.equal(freshaLocationForCity('Miami'), 'Miami, US');
    assert.equal(freshaLocationForCity('Bucharest'), 'Bucharest, Romania');
    assert.equal(countryCodeForCity('Dubai'), 'AE');
    assert.ok(importCityKey('Dubai').includes('dubai'));
  });
});

describe('fresha price parse', () => {
  it('never invents prices', () => {
    assert.equal(parseNumericPrice(null), 0);
    assert.equal(parseNumericPrice('on request'), 0);
    assert.equal(parseNumericPrice(990), 990);
    assert.equal(parseNumericPrice('from AED 990'), 990);
    assert.equal(parseNumericPrice('£45'), 45);
  });

  it('uses Malikgen priceValue without inventing', () => {
    const rows = expandServicePriceRows({
      name: 'Lip Filler 1ml',
      price: 'AED 990',
      priceValue: 990,
      duration: '45 min',
      category: 'Injectables',
    }, 'AED');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].price, 990);
    assert.match(rows[0].rawPriceText, /990/);
  });

  it('skips missing priceValue', () => {
    const rows = expandServicePriceRows({
      name: 'Consult',
      price: 'Price on request',
      priceValue: null,
    }, 'AED');
    assert.equal(rows.length, 0);
  });
});

describe('service-first gate', () => {
  it('accepts medical aesthetic catalogues', () => {
    const services = [
      {name: 'Botox 1 Area', category: 'Injectables'},
      {name: 'Lip Filler', category: 'Injectables'},
      {name: 'Chemical Peel', category: 'Skin'},
    ];
    assert.equal(venueHasMedicalAestheticServices(services), true);
    assert.equal(venueIsBeautyOnly(services), false);
  });

  it('rejects haircut/nails/massage only', () => {
    const services = [
      {name: 'Haircut', category: 'Hair'},
      {name: 'Gel Manicure', category: 'Nails'},
      {name: 'Swedish Massage', category: 'Massage'},
    ];
    assert.equal(venueHasMedicalAestheticServices(services), false);
    assert.equal(venueIsBeautyOnly(services), true);
  });
});

describe('fresha procedure classify', () => {
  it('maps common aesthetic services', () => {
    const lip = classifyFreshaService('Lip Filler 1ml');
    assert.equal(lip.accepted, true);
    assert.match(lip.exploreProcedure, /filler/i);

    const botox = classifyFreshaService('Anti Wrinkle 3 Areas');
    assert.equal(botox.accepted, true);
    assert.match(botox.exploreProcedure, /Botox/i);

    const profhilo = classifyFreshaService('Profhilo Face');
    assert.equal(profhilo.accepted, true);

    const sculptra = classifyFreshaService('Sculptra Face');
    assert.equal(sculptra.accepted, true);
    assert.match(sculptra.exploreProcedure, /Sculptra/i);
  });

  it('rejects bundles', () => {
    const bundle = classifyFreshaService('1ml Filler + Botox');
    assert.equal(bundle.accepted, false);
  });

  it('does not force unknown into wrong family', () => {
    const unk = classifyFreshaService('Swedish Massage 60 min');
    assert.equal(unk.accepted, false);
  });
});

describe('fresha FROM price', () => {
  it('picks lowest eligible variant per procedure', () => {
    const picked = pickFromPricesByProcedure([
      {
        exploreProcedure: 'dermal filler lips cheeks',
        service: {name: 'Lip Filler 1ml', price: 990},
      },
      {
        exploreProcedure: 'dermal filler lips cheeks',
        service: {name: 'Lip Filler 0.5ml', price: 700},
      },
      {
        exploreProcedure: 'Botox anti-wrinkle injection',
        service: {name: 'Botox 3 areas', price: 1200},
      },
    ]);
    const filler = picked.find((p) =>
      p.exploreProcedure.includes('filler'));
    assert.equal(filler.service.price, 700);
  });
});

describe('fresha url match', () => {
  it('extracts /a/ venue urls only', () => {
    assert.equal(
        extractFreshaVenueUrl(
            'https://www.fresha.com/a/glow-clinic-dubai-jlt-abc123?x=1'),
        'https://www.fresha.com/a/glow-clinic-dubai-jlt-abc123');
    assert.equal(
        extractFreshaVenueUrl('https://www.fresha.com/lvp/something'),
        '');
  });

  it('matches clinic name in slug', () => {
    const clinic = {name: 'Glow Aesthetic Clinic'};
    const v = freshaUrlMatchesClinic(
        'https://www.fresha.com/a/glow-aesthetic-clinic-dubai-jlt-xyz',
        clinic,
        'Dubai');
    assert.equal(v.ok, true);
  });
});

describe('import usefulness', () => {
  it('requires clinics and prices for useful complete', () => {
    assert.equal(hasUsefulImport({clinicsImported: 0, pricesImported: 0}), false);
    assert.equal(hasUsefulImport({clinicsImported: 5, pricesImported: 0}), false);
    assert.equal(hasUsefulImport({clinicsImported: 5, pricesImported: 12}), true);
  });
});

describe('fresha provider normalize malikgen', () => {
  it('normalizes categories[].services with priceValue', () => {
    const provider = new FreshaProvider();
    const raw = {
      venueName: 'Glow Aesthetic Dubai',
      url: 'https://www.fresha.com/a/glow-aesthetic-dubai-jlt-abc',
      currency: 'AED',
      rating: 4.8,
      categories: [
        {
          name: 'Injectables',
          services: [
            {
              name: 'Lip Filler 1ml',
              price: 'AED 990',
              priceValue: 990,
              duration: '45 min',
            },
            {
              name: 'Mystery Ritual',
              price: 'Price on request',
              priceValue: null,
            },
          ],
        },
      ],
    };
    const venue = provider.normalizeVenue(raw);
    assert.ok(venue.freshaVenueId);
    assert.equal(venue.currency, 'AED');
    const services = provider.normalizeServices(raw);
    assert.equal(services.length, 1);
    assert.equal(services[0].price, 990);
  });
});
