'use strict';

const {requestedFamily} = require('../procedureRelation');
const {laserRequestedSubtype} = require('../procedureMatch');
const {localProcedureName, localeForCity} = require('../searchLocale');

/**
 * Family-specific discovery queries. City is a geographic signal only —
 * never a per-city query map. Unknown cities use English + local aliases.
 */
function discoveryQueriesForProcedure(procedure, city, opts = {}) {
  const proc = String(procedure || '').trim();
  const c = String(city || '').trim();
  if (!proc || !c) return [];
  const fam = requestedFamily(proc);
  const loc = localeForCity(c, {countryCode: opts.countryCode});
  const local = localProcedureName(proc, loc.lang) || '';
  const asciiCity = String(opts.asciiCity || c).trim();
  const country = String(opts.countryName || opts.countryCode || '').trim();
  const tld = countryTld(opts.countryCode || loc.gl || '');
  const priceWord = loc.priceWord || 'price';
  const out = [];
  const add = (q) => {
    const t = String(q || '').replace(/\s+/g, ' ').trim();
    if (t && !out.includes(t)) out.push(t);
  };
  const addLocal = () => {
    if (local && local.toLowerCase() !== proc.toLowerCase()) {
      add(`${local} ${priceWord} ${c}`);
      add(`${local} ${c}`);
      if (loc.clinicWord && loc.lang !== 'en') {
        add(`${local} ${loc.clinicWord} ${c}`);
      }
      if (tld) add(`site:${tld} ${c} ${local} ${priceWord}`);
    }
  };
  const addEnglishFallback = (alias) => {
    add(`${alias} price ${c}${country ? ` ${country}` : ''}`);
    if (asciiCity && asciiCity.toLowerCase() !== c.toLowerCase()) {
      add(`${alias} price ${asciiCity}`);
    }
  };

  switch (fam) {
    case 'botox':
      add(`Botox clinic ${c}`);
      add(`medical aesthetics Botox ${c}`);
      add(`Botox injections ${c}`);
      add(`cosmetic dermatology Botox ${c}`);
      add(`neuromodulator clinic ${c}`);
      addEnglishFallback('Botox');
      addLocal();
      break;
    case 'filler':
      add(`dermal filler clinic ${c}`);
      add(`lip filler clinic ${c}`);
      add(`aesthetic injectables ${c}`);
      add(`hyaluronic acid filler ${c}`);
      addEnglishFallback('lip filler');
      addLocal();
      break;
    case 'laser': {
      const sub = laserRequestedSubtype(proc);
      if (sub === 'hair') {
        add(`laser hair removal clinic ${c}`);
        add(`laser clinic ${c}`);
        add(`diode laser hair removal ${c}`);
      } else {
        add(`laser skin clinic ${c}`);
        add(`IPL photofacial clinic ${c}`);
        add(`laser rejuvenation ${c}`);
        add(`cosmetic dermatology laser ${c}`);
      }
      addLocal();
      break;
    }
    case 'peel':
      add(`chemical peel clinic ${c}`);
      add(`dermatologist chemical peel ${c}`);
      add(`medical spa chemical peel ${c}`);
      addLocal();
      break;
    case 'rhinoplasty':
      add(`rhinoplasty ${c}`);
      add(`rhinoplasty surgeon ${c}`);
      add(`plastic surgeon rhinoplasty ${c}`);
      add(`facial plastic surgeon ${c}`);
      addEnglishFallback('rhinoplasty');
      addLocal();
      break;
    case 'breast_augmentation':
    case 'breast':
      add(`breast augmentation ${c}`);
      add(`breast implant surgeon ${c}`);
      add(`plastic surgeon breast implants ${c}`);
      addLocal();
      break;
    case 'hair':
      add(`hair transplant clinic ${c}`);
      add(`FUE hair transplant ${c}`);
      add(`hair restoration clinic ${c}`);
      addLocal();
      break;
    case 'skin':
    case 'profhilo':
      add(`Profhilo clinic ${c}`);
      add(`skin booster clinic ${c}`);
      add(`injectable moisturiser ${c}`);
      addLocal();
      break;
    case 'microneedling':
      add(`microneedling clinic ${c}`);
      add(`SkinPen clinic ${c}`);
      add(`Dermapen clinic ${c}`);
      addLocal();
      break;
    case 'prp':
      add(`PRP clinic ${c}`);
      add(`platelet rich plasma ${c}`);
      addLocal();
      break;
    case 'hifu':
      add(`HIFU clinic ${c}`);
      add(`Ultherapy clinic ${c}`);
      addLocal();
      break;
    default:
      add(`${proc} clinic ${c}`);
      add(`${proc} ${c}`);
      addEnglishFallback(proc);
      addLocal();
  }
  add(`${loc.clinicWord || 'clinic'} ${c} prices`);
  return out.slice(0, 10);
}

function countryTld(code) {
  const cc = String(code || '').trim().toUpperCase();
  const map = {
    RO: '.ro', MD: '.md', BG: '.bg', FR: '.fr', DE: '.de', ES: '.es', IT: '.it',
    PT: '.pt', TR: '.tr', GB: '.uk', UK: '.uk', AE: '.ae', JP: '.jp',
    BR: '.br', CA: '.ca', US: '.com', NL: '.nl', PL: '.pl',
  };
  return map[cc] || '';
}

/** Families the extract/relation pipeline can verify. */
const BACKGROUND_SEED_PROCEDURES = [
  'Botox anti-wrinkle injection',
  'dermal filler lips cheeks',
  'laser skin rejuvenation IPL',
  'laser hair removal',
  'chemical peel facial',
  'skin booster Profhilo',
  'microneedling SkinPen',
  'PRP vampire facial',
  'HIFU ultherapy',
  'rhinoplasty nose job',
  'breast augmentation',
  'hair transplant FUE',
];

module.exports = {
  discoveryQueriesForProcedure,
  BACKGROUND_SEED_PROCEDURES,
};
