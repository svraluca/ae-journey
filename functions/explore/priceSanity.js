'use strict';
const {quoteScopeReason} = require('./tariffScope');
const {injectableScopeRejection} = require('./injectableScope');

const {looksLikeSurgicalChinTreatment,
  looksLikeCombinedToxinSkinTreatment, looksLikeCreditLimitQuote,
  looksLikeSpanishMarketPriceQuote, looksLikeLipHydrationWhenAugmentationRequested} = require('./procedureScope');

function isWeakPriceExtractionMethod(method) {
  switch (String(method || '').trim().toLowerCase()) {
    case 'dom_block':
    case 'domblock':
    case 'list_item':
    case 'listitem':
    case 'text_proximity':
    case 'textproximity':
      return true;
    default:
      return false;
  }
}

function isStructuredPriceExtractionMethod(method) {
  switch (String(method || '').trim().toLowerCase()) {
    case 'jsonld':
    case 'json_ld':
    case 'schemaoffer':
    case 'schema_offer':
    case 'html_table':
    case 'owned_currency_tariff_table':
    case 'htmltable':
    case 'woocommerce':
    case 'shopify':
    case 'product_card':
    case 'productcard':
    case 'fresha_menu':
    case 'marketplace_menu':
    case 'booksy_menu':
      return true;
    default:
      return false;
  }
}

const PHONE_CUE = /\b(?:tel(?:e(?:fono|phone))?|tel[eé]fono|whatsapp|m[oó]vil|mobile|contact(?:o|ar)?|llam(?:ar|enos)|call\s+us)\b/i;
const ADDRESS_CUE = /\b(?:c\/|calle|carrer|avenida|avda\.?|av\.|street|road|plaza|passeig|postal|c\.?p\.?|codigo postal|c[oó]digo postal|building|floor|planta|izq\.?|dcha\.?|izquierda|derecha)\b/i;
const DURATION_CUE = /\b(?:\d+\s*(?:min|mins|minutes?|hora?s?|hours?|h|days?|d[ií]as?|months?|meses|sesiones?|sessions?))\b/i;
const DURATION_UNIT =
    '(?:min|mins|minutes?|hora?s?|hours?|h|days?|d[ií]as?|months?|meses|sesiones?|sessions?)';

function amountHasCurrencyQuote(n, raw) {
  const amount = String(Math.round(Number(n) || 0));
  if (!amount || amount === '0') return false;
  const t = String(raw || '');
  const re = new RegExp(
      `(?:\\$|€|£)\\s*${amount}(?:[.,]\\d+)?|` +
      `${amount}(?:[.,]\\d+)?\\s*(?:usd|eur|gbp|aed|ron|lei|\\$|€|£|/\\s*unit|per\\s+unit)`,
      'i',
  );
  return re.test(t);
}

function amountAttachedToDurationUnit(n, raw) {
  const amount = String(Math.round(Number(n) || 0));
  if (!amount || amount === '0') return false;
  const re = new RegExp(
      `(?<![\\d.,\\$€£])${amount}(?:[.,]\\d+)?\\s*${DURATION_UNIT}\\b`,
      'i',
  );
  return re.test(String(raw || ''));
}

/** Duration copy in the same block must not kill a currency / per-unit price. */
function looksLikeDurationQuotedAsPrice({priceMin, rawPriceText, blob}) {
  const n = Math.round(Number(priceMin) || 0);
  if (n <= 0) return false;
  const price = String(rawPriceText || '').replace(/\u00a0/g, ' ');
  const all = `${blob || ''}\n${price}`.replace(/\u00a0/g, ' ');
  if (amountHasCurrencyQuote(n, price) || amountHasCurrencyQuote(n, all)) {
    return false;
  }
  if (amountAttachedToDurationUnit(n, price)) return true;
  if (DURATION_CUE.test(price) && !hasCurrencySignal(price)) return true;
  return amountAttachedToDurationUnit(n, all);
}

function amountAttachedToMonthlyUnit(n, raw) {
  const amount = Number(n);
  if (!(amount > 0) || !String(raw || '').trim()) return false;
  const re = new RegExp(
      `(?:\\$|€|£)?\\s*${amount}(?:[.,]\\d+)?\\s*(?:/\\s*mo(?:nth)?s?\\b|per\\s+month\\b|a\\s+month\\b)`,
      'i',
  );
  return re.test(String(raw || ''));
}

function amountLooksLikeMonthlyInstallment(n, raw) {
  if (amountAttachedToMonthlyUnit(n, raw)) return true;
  const amount = Number(n);
  if (!(amount > 0)) return false;
  const re = new RegExp(
      `\\bmonthly\\s+(?:from|payment|instalments?|installments?|finance|financing)\\b.{0,32}(?:\\$|€|£)?\\s*${amount}` +
      `|(?:\\$|€|£)?\\s*${amount}(?:[.,]\\d+)?.{0,32}\\bmonthly\\s+(?:from|payment|instalments?|installments?|finance|financing)\\b`,
      'i',
  );
  return re.test(String(raw || ''));
}

/** `$99/mo` is financing. `$950 per syringe` next to "in a month" is not. */
function looksLikeMonthlyFinancingQuotedAsPrice({priceMin, rawPriceText, blob}) {
  const n = Math.round(Number(priceMin) || 0);
  if (n <= 0) return false;
  const price = String(rawPriceText || '').replace(/\u00a0/g, ' ');
  const all = `${blob || ''}\n${price}`.replace(/\u00a0/g, ' ');
  if (/(?:per|\/)\s*(?:unit|syringe|ml|vial|session|area|graft)\b/i.test(price)) {
    return false;
  }
  if (amountHasCurrencyQuote(n, price) && !amountLooksLikeMonthlyInstallment(n, price)) {
    return false;
  }
  return amountLooksLikeMonthlyInstallment(n, price) ||
      amountLooksLikeMonthlyInstallment(n, all);
}

/** "Typical sessions ranging from $500 to $800" is market copy, not a menu. */
function looksLikeTypicalMarketRangeQuotedAsPrice({priceMin, rawPriceText, blob}) {
  const n = Math.round(Number(priceMin) || 0);
  if (n <= 0) return false;
  const price = String(rawPriceText || '').replace(/\u00a0/g, ' ');
  if (price.length <= 90 &&
      !/\btypical|\bprices?\s+vary|\bon average\b|\branging from\b/i.test(price) &&
      amountHasCurrencyQuote(n, price)) {
    return false;
  }
  return /\btypical(?:ly)?\s+sessions?\s+rang|\bprices?\s+vary\s+depending\b|\btypical(?:ly)?\s+(?:session|treatment)s?\s+rang(?:e|ing)\s+from\b/i.test(price);
}
const PERCENT_CUE = /\d+(?:[.,]\d+)?\s*%/;
const REVIEW_CUE = /\b(?:reviews?|rese[nñ]as|opiniones|valoraciones|google\s+reviews?)\b/i;
const PRICING_LANGUAGE = /\b(?:price|precio|precios|preț|pret|tarifa|tarifas|cost|coste|costo|from|desde|a\s+partir\s+de|de\s+la|starting(?:\s+at)?)\b|(?:سعر|بسعر|أسعار|اسعار|تكلفة|يبدأ من|تبدأ من)/i;
const {hasCurrencySignal} = require('./currencyTokens');
const {
  classifyExplorePricePageContext,
  exploreEvidenceIsClinicOwnedPrice,
} = require('./priceOwnership');

function digitsOnly(raw) {
  return String(raw || '').replace(/\D/g, '');
}

function hasPricingLanguage(raw) {
  return PRICING_LANGUAGE.test(String(raw || ''));
}

function looksLikePhoneNumber(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  const lower = t.toLowerCase();
  if (lower.includes('tel:') || lower.includes('telephone:') ||
      lower.includes('telefono:') || lower.includes('teléfono:') ||
      lower.includes('phone:') || lower.includes('whatsapp:') ||
      lower.includes('contact:')) {
    return true;
  }
  if (PHONE_CUE.test(t)) return true;
  const compact = t.replace(/[\s().\-./]/g, '');
  if (/^\+\d{8,15}$/.test(compact)) return true;
  if (/^00\d{8,15}$/.test(compact) && !hasCurrencySignal(t) &&
      !hasPricingLanguage(t)) {
    return true;
  }
  if (/(?:\+|00)\s*3[0-9]\b/.test(t) && digitsOnly(t).length >= 9) return true;
  if (/(?:\+|00)?\s*(?:34[\s.\-/]*)?[6-9]\d{2}[\s.\-/]+\d{3}[\s.\-/]+\d{3}\b/.test(t) &&
      digitsOnly(t).length >= 9) {
    return true;
  }
  return false;
}

function looksLikeAddressNumber(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  if (ADDRESS_CUE.test(t)) return true;
  if (hasCurrencySignal(t)) return false;
  if (/\b\d{5}\s+[A-Za-zÀ-ÿ]/.test(t)) return true;
  if (/\b\d{4,5}\s*[-–]\s*[A-Za-zÀ-ÿ]/.test(t)) return true;
  if (/\b\d+º/.test(t)) return true;
  if (/\bE-\d\b/.test(t)) return true;
  return false;
}

function looksLikeMultiSessionSeriesQuote(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (/\b(?:[2-9]|[1-9]\d+)\s*(?:sesiones|sessions|sedinte|seances|sitzungen)\b/i.test(t)) return true;
  return /(?:a\s+)?(?:full\s+)?series\s+(?:of\s+)?\d|full series|package of\s+\d|(?:series|package)\s+of\s+\d|\d\s*(?:x|×)\s*(?:sessions?|treatments?|peels?)|\d+\s+sessions?\s+for|3\s+for\s*[\$£€]|pack(?:age)?\s+of\s+[3-9]/i.test(t);
}

function looksLikeDepigmentationPeelPackage(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t) return false;
  if (/cosmelan|dermamelan|melanostop|depigmentation\s+peel|pigmentation\s+peel\s+kit/i.test(t)) {
    return true;
  }
  if (/starter\s+kit/.test(t) && /peel|homecare|home[\s-]?care/.test(t)) {
    return true;
  }
  return false;
}

function isBareYear(amount, raw) {
  const n = Math.round(Number(amount) || 0);
  if (n < 1900 || n > 2100) return false;
  if (hasCurrencySignal(raw) || hasPricingLanguage(raw)) return false;
  return true;
}

function plausibleAmountBand({currency, procedure}) {
  const curr = String(currency || '').trim().toUpperCase();
  const proc = String(procedure || '').toLowerCase();
  let min = 10;
  let max = 100000;
  const botox = /botox|toxin|dysport|xeomin/.test(proc);
  const filler = /filler|hialuron|hyaluron|relleno|labio/.test(proc);
  const laser = /laser|epilare|depilacion/.test(proc);
  const peel = /peel/.test(proc);
  const rhino = /rhino|rinoplast|nose/.test(proc);
  const breast = /breast|boob|pecho|mamar/.test(proc);
  const hair = /hair|fue|injerto|transplant/.test(proc);
  if (botox) {
    // Match Dart: session totals plus published per-unit rates (USD $8–$16).
    min = 8; max = 8000;
  } else if (filler) {
    min = 30; max = 5000;
  } else if (laser || peel) {
    min = 10; max = 5000;
  } else if (rhino) {
    min = 2000; max = 100000;
  } else if (breast) {
    min = 500; max = 100000;
  } else if (hair) {
    min = 300; max = 100000;
  }
  // High-denomination / FX scale bands (currency-aware, not one global ceiling).
  if (curr === 'RON' || curr === 'LEI' || curr === 'MDL') return {min: min * 5, max: max * 5};
  if (curr === 'ALL' || curr === 'LEK') return {min: min * 80, max: max * 120};
  if (curr === 'TRY' || curr === 'TL') return {min: min * 10, max: max * 35};
  if (curr === 'KRW' || curr === '₩') return {min: min * 400, max: max * 2000};
  if (curr === 'JPY' || curr === '¥') return {min: min * 50, max: max * 200};
  if (curr === 'IDR' || curr === 'RP') return {min: min * 5000, max: max * 20000};
  if (curr === 'VND') return {min: min * 8000, max: max * 30000};
  if (curr === 'HUF' || curr === 'FT') return {min: min * 120, max: max * 400};
  if (curr === 'CZK') return {min: min * 8, max: max * 30};
  if (curr === 'INR' || curr === '₹') return {min: min * 30, max: max * 100};
  if (curr === 'THB' || curr === '฿') return {min: min * 12, max: max * 40};
  if (curr === 'MYR' || curr === 'RM') return {min: min * 2, max: max * 5};
  if (curr === 'COP' || curr === 'CLP' || curr === 'ARS') {
    return {min: min * 200, max: max * 2000};
  }
  if (curr === 'HUF') return {min: min * 100, max: max * 400};
  if (curr === 'AED' || curr === 'SAR' || curr === 'QAR') {
    return {min, max: max * 2};
  }
  if (curr === 'KWD' || curr === 'BHD' || curr === 'OMR') {
    return {min: Math.max(1, min / 4), max: max / 2};
  }
  if ((curr === 'GBP' || curr === '£') && breast) {
    min = Math.max(min, 4000);
  }
  return {min, max};
}

function hostFromSourceUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim();
  if (!raw) return '';
  try {
    const host = new URL(raw.includes('://') ? raw : `https://${raw}`).hostname;
    return String(host || '').toLowerCase().replace(/^www\./, '');
  } catch (_) {
    return '';
  }
}

function looksLikePriceMenuHeadingOnly(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase()
      .replace(/[^a-z0-9ăâîșț]+/g, ' ').trim();
  if (!t) return false;
  return /^(?:price guide|price list|our fees|our prices|prices|pricing|tariffs?|fees|cost|costs|(?:the )?price of the procedures?|(?:the )?cost of (?:the )?procedures?|(?:the )?cost of offered services|pretul procedurii|pre[tț]ul procedurii|costul procedurii|pretul serviciului|pre[tț]ul serviciului|pre[tț]uri(?: la servicii)?)$/.test(t);
}

function looksLikeBreastAugmentationAddOnRow(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (/\bareolas?\b|\bareole\b|\bareolei\b|\bareolelor\b/i.test(t)) return true;
  return /in case of breast augment|correction of areola|corec[tț]ie(?:a)? (?:de )?areol|liquidation of breast contraction|removing breast implants|extragerea implantelor|scoatere(?:a)? implantelor|capsulectom/i.test(t);
}

function looksLikeBotoxPerUnitQuote(raw, procedure = '') {
  const t = `${raw || ''} ${procedure || ''}`.replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (!/(?:per|\/)\s*units?\b|(?:per|\/)\s*iu\b|\b1\s*units?\b|\b1\s*unitate|\bpe\s+unitate|\/\s*unitate|\(\s*1\s*unit/.test(t)) {
    return false;
  }
  return /botox|toxin|dysport|xeomin|neuromod|wrinkle\s+relax|toxina|botulin/.test(t);
}

function urlPathForFamily(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return '';
  try {
    return new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {
    return raw;
  }
}

function exploreUrlPathFamilyKey(sourceUrl) {
  const path = urlPathForFamily(sourceUrl);
  if (!path) return '';
  if (/rhinoplast|rinoplast|nose-job|nose-reshaping|septorhino/i.test(path)) return 'rhinoplasty';
  if (/boob-job|breast-aug|breast-enlarg|breast-implant|breast-uplift|mamoplast|aumento-de-pecho|marire-sani/i.test(path)) {
    return 'breast';
  }
  if (/hair-transplant|injerto-capilar|fue-hair|transplant-de-par/i.test(path)) return 'hair';
  if (/botox|anti-wrinkle|dysport|xeomin|neuromodul/i.test(path)) return 'botox';
  if (/dermal-filler|lip-filler|\/fillers?(?:\/|$)|juvederm|relleno/i.test(path)) return 'filler';
  if (/chemical-peel|peeling|\/peels?(?:\/|$)/i.test(path)) return 'peel';
  if (/laser-hair|depilacion|epilare-laser|hair-removal/i.test(path)) return 'laser';
  if (/(?:^|\/)forma(?:\/|$)|morpheus|endolift|skinpen|thermage|ulthera|(?:^|\/)hifu(?:\/|$)|coolsculpt|emsculpt|(?:^|\/)exilis(?:\/|$)/i.test(path)) {
    return 'energy_device';
  }
  return '';
}

function looksLikeEnergyOrDeviceTreatment(raw) {
  return /\bforma\b|\bmorpheus\s*8?\b|\bendolift\b|\bskinpen\b|\bthermage\b|\bulthera(?:py)?\b|\bhifu\b|\bcoolsculpt|\bemsculpt\b|\bexilis\b|\bemface\b|\bsofwave\b/i.test(String(raw || ''));
}

function familyKeyFromProcedure(procedure) {
  const p = String(procedure || '').toLowerCase();
  if (/botox|toxin|بوتوكس/.test(p)) return 'botox';
  if (/filler|hialuron|فيلر/.test(p)) return 'filler';
  if (/laser|ليزر/.test(p)) return 'laser';
  if (/peel|تقشير/.test(p)) return 'peel';
  if (/rhino|nose|أنف/.test(p)) return 'rhinoplasty';
  if (/breast|boob|ثدي/.test(p)) return 'breast';
  if (/hair|fue|شعر/.test(p)) return 'hair';
  return '';
}

function looksLikeTreatmentFinanceUrl(sourceUrl) {
  const path = urlPathForFamily(sourceUrl);
  if (!path) return false;
  return /(?:^|\/)(?:[^/]*-)?on-finance(?:\/|$)|(?:^|\/)(?:0-percent-)?financ(?:e|ing|iar)(?:\/|$)|payment-plan|pay-monthly|monthly-payments?/i.test(path);
}

function exploreUrlConflictsWithProcedure(sourceUrl, procedure) {
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) return true;
  const want = familyKeyFromProcedure(procedure);
  if (!want) return false;
  const got = exploreUrlPathFamilyKey(sourceUrl);
  if (!got) return false;
  return got !== want;
}

function looksLikeCityMarketPricingGuideUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  return /complete-pricing-guide|complete-price-guide|complete-cost-guide|complete-pricing|typical-[-]?cost|cost-in-london-complete/i.test(path);
}

function looksLikeHospitalFeesOnlyQuote(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (/inclusive of.{0,48}hospital|includes?.{0,32}hospital (?:stay|costs?|fees?)|night.?s stay in hospital|hospital stay is included/i.test(t)) {
    return false;
  }
  return /hospital charges|\bguide price\b|estimated guide to the hospital|excludes?\s+(?:consultation|diagnostic|professional|surgeon)|professional fees charged separately|(?:surgeon|anaesthetist|consultant).{0,48}charged separately|does not include.{0,48}(?:surgeon|anaesthetist|consultation)|hospital fee(?:s)?(?:\s+only)?\b.{0,40}exclud/i.test(t);
}

function looksLikeStarredHospitalGuidePrice({blob, priceMin, procedure}) {
  const proc = String(procedure || '').toLowerCase();
  if (!/rhino|rinoplast|\bnose/.test(proc)) return false;
  if (!(Number(priceMin) > 0) || Number(priceMin) >= 5000) return false;
  return /\d[\d,]*\s*\*/.test(String(blob || '').replace(/\u00a0/g, ' '));
}

function looksLikePartialRhinoplastyStarting(raw) {
  const folded = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!folded.trim()) return false;
  return /\btip\s+rhino|\brhinoplasty\s+tip|\bnose\s+tip|\btip-only|\balarplasty|\balar\s+base|revision\s+rhino|\bsecondary\s+rhino|\bethnic\s+rhino|\brinoplastia\s+(?:racial|[eé]tnica|secundaria|parcial|(?:de\s+(?:la\s+)?)?punta|post[\s-]?traum[aá]tic\w*)|\bpost[\s-]?traumatic\s+rhino|\brhino\w*\s+post[\s-]?traumatic|\bpartial\s+rhino|\brinoplastie\s+par[tț]ial|\bcartilaginous area of the nasal tip|\bseptum region\b|\bwing region\b/i.test(folded);
}

function looksLikePrimaryRhinoplastyStarting(raw) {
  const folded = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (looksLikePartialRhinoplastyStarting(folded)) return false;
  return /\bprimary\b|\bstandard primary\b|\bopen rhino|\bclosed rhino/i.test(folded);
}

function looksLikePatientAnecdotePrice(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  return /\bi paid\b|\bwe paid\b|\bpatient(?:s)?\s+(?:reported|paid|who reported|who paid)\b|\breviews?\s+mention\b|\breported\s+(?:paying|a price)\b/i.test(t);
}

function explorePublishedOrReviewedYear(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ');
  if (!t.trim()) return 0;
  const m = t.match(
      /(?:last\s+(?:reviewed|updated|modified)|published(?:\s+on)?|revised(?:\s+in)?|updated(?:\s+on)?|medically reviewed)[^\d]{0,48}((?:19|20)\d{2})|\b((?:19|20)\d{2})\s+procedure\s+prices|(?:june|july|january|february|march|april|may|august|september|october|november|december)\s+((?:19|20)\d{2})/i);
  if (!m) return 0;
  for (let i = 1; i < m.length; i++) {
    const y = Number(m[i]);
    if (y >= 2018 && y <= 2035) return y;
  }
  return 0;
}

function priceMaxHintFromRaw(rawPriceText, priceMin) {
  const t = String(rawPriceText || '').replace(/\u00a0/g, ' ');
  const m = t.match(/(\d{1,3}(?:,\d{3})+|\d+)\s*(?:£|gbp)?\s*[–—-]\s*(?:£|gbp)?\s*(\d{1,3}(?:,\d{3})+|\d+)/i);
  if (!m) return priceMin;
  const hi = Number(String(m[2]).replace(/,/g, '')) || 0;
  return hi > priceMin ? hi : priceMin;
}

function looksLikeRoundedMarketPriceSpread({
  priceMin, priceMax, currency, procedure,
} = {}) {
  const curr = String(currency || '').trim().toUpperCase();
  if (curr !== 'GBP' && curr !== '£') return false;
  const proc = String(procedure || '').toLowerCase();
  const min = Number(priceMin) || 0;
  const max = Number(priceMax) || 0;
  if (min <= 0 || max <= min + 500) return false;
  const breast = /breast|boob|pecho|mamar|enlargement|augmentation/.test(proc);
  const rhino = /rhino|rinoplast|\bnose/.test(proc);
  if (breast) {
    if (min % 1000 !== 0 || max % 1000 !== 0) return false;
    const span = max - min;
    return span >= 1500 && span <= 5000;
  }
  if (rhino) {
    const span = max - min;
    if (min <= 5500 && span >= 1500 && span <= 4000) return true;
    if (min % 1000 === 0 && max % 1000 === 0 &&
        min >= 6000 && min <= 9000 && span >= 4000) {
      return true;
    }
  }
  return false;
}

function hostLooksLikeUkClinic(sourceUrl) {
  const host = hostFromSourceUrl(sourceUrl);
  if (!host) return false;
  return host.endsWith('.uk') || host.endsWith('.london') || host.endsWith('.scot');
}

function currencyLooksLikeUsd(currency, blob) {
  const c = String(currency || '').trim().toUpperCase();
  if (c === 'USD' || c === '$' || c === 'US$' || c === 'DOLLAR') return true;
  const t = String(blob || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (t.includes('£') || t.includes('gbp') || t.includes('€') || /\beur\b/.test(t)) {
    return false;
  }
  return t.includes('$') || /\busd\b/.test(t);
}

function looksLikeShopifyThemeDummyPrice({
  rawPriceText, priceMin, currency, rawEvidence = '', procedure = '',
}) {
  const blob = `${rawPriceText || ''}\n${rawEvidence || ''}\n${procedure || ''}`
      .replace(/\u00a0/g, ' ').toLowerCase();
  if (/page\s*editor|lorem ipsum|placeholder product|theme preview/.test(blob)) {
    return true;
  }
  if (!currencyLooksLikeUsd(currency, blob)) return false;
  if (/\$\s*399(?:\.99)?\b|\b399\.99\b/.test(blob)) return true;
  const amount = Number(priceMin) || 0;
  const rounded = Math.round(amount);
  if (Math.abs(amount - 399.99) < 0.02 || rounded === 399 || rounded === 400) {
    return /399|from\s*\$/.test(blob);
  }
  return false;
}

function looksLikeUsdQuotedOnUkHost({
  sourceUrl, currency, rawPriceText = '', rawEvidence = '',
}) {
  if (!String(sourceUrl || '').trim()) return false;
  if (!hostLooksLikeUkClinic(sourceUrl)) return false;
  return currencyLooksLikeUsd(currency, `${rawPriceText || ''}\n${rawEvidence || ''}`);
}

function looksLikeCompetitorPriceColumnHeader(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase().trim();
  if (!t) return false;
  return /high street salon|non[- ]medical|harley street average|harley street clinics|central london average|other clinics?|other providers?/i.test(t);
}

function looksLikeThirdPartyProviderPriceLabel(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (looksLikeCompetitorPriceColumnHeader(t)) return true;
  return /harley street\s*\((?:doctor[- ]led|avg|average)|high street salon|central london average|your saving vs/i.test(t);
}

function looksLikeCompetitorOrThirdPartyPriceQuote(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (looksLikeCompetitorPriceColumnHeader(t)) return true;
  return /some clinics that are offering|ridiculously cheap|cheapest is not always best|other clinics (?:that )?are offering|clinics that are offering|other providers|other practitioners|unscrupulous practitioners|fake botox|high street salon|harley street average|central london average/i.test(t);
}

function looksLikeHairGraftPackageMenuLabel(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t || t.length > 90 || /[?؟]/.test(t)) return false;
  return new RegExp(
      `\\d[\\d.,]*\\s*(?:${HAIR_TECH}\\s+)?-?\\s*(?:grafts?|grafturi|follicles?|بصيلة|بصيلات)\\b`,
      'i').test(t);
}

function looksLikePerGraftQuotedPrice(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (looksLikeEffectivePerGraftMarketing(t)) return false;
  return /(?:per\s+graft|\/graft|per\s+follicle|\/follicle|لكل\s+بصيلة|للبصيلة|per\s+grafturi)/i.test(t);
}

function looksLikeEffectivePerGraftMarketing(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  return /effective\s+cost\s+per\s+graft|lowest\s+effective\s+cost|cost\s+per\s+graft\s+at\s+full|per\s+graft\s+at\s+full\s+allowance|works\s+out\s+(?:at|to|between)|what\s+each\s+package\s+works\s+out|honest\s+way\s+to\s+compare/i.test(t);
}

function looksLikeHairNonStartingRow(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (/\bconsultation\b|theatre\s+deposit|non[- ]?refundable|no\s+wait\s+booking|female\s+hair\s+loss\s+specialist|pre[- ]assessment|video consultation|follow[- ]up appointment|scalp\s+micro|micropigment|\bsmp\b|scar\s+revision|\beyebrows?\b|\bbeard\b|\bsideburn|highest (?:package|total)|maximum grafts|prices valid/i.test(t)) {
    return true;
  }
  return /arrangement\s+fee/i.test(t) && !hairRowIncludesMandatoryAddOnFee(t);
}

function looksLikeHairLargerThanStartingPackage(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (/lowest (?:total )?payable|lowest package|package\s*1\b|min(?:imum)?\s+fee|up to\s*3[.,]?000/i.test(t)) {
    return false;
  }
  return /package\s*[2-9]\b|up to\s*5[.,]?000|5,?000\s*grafts|full coverage|including the crown/i.test(t);
}

function looksLikeHairMarketComparisonRow(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  return /uk average|central london and harley|greater london,|grafts actually needed|estimated market|wimpole|estimated difference|around £\s*\d|market range|estimated cost per graft/i.test(t);
}

function looksLikeHairDhiWhenFueRequested({procedure, blob}) {
  const want = String(procedure || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!/\bfue\b/.test(want)) return false;
  const t = String(blob || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!/\bdhi\b|\bchoi pen\b/.test(t)) return false;
  if (/\bfue\b|\bsapphire\b/.test(t)) return false;
  return true;
}

function looksLikeHairStartingPackageRow(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  return /lowest total payable|lowest package|package\s*1\b|min(?:imum)?\s+fee|starts?\s+at|up to\s*3[.,]?000/i.test(t);
}

function hairRowIncludesMandatoryAddOnFee(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  return /total payable|including the .{0,24}(?:arrangement|admin|booking) fee|incl(?:udes|uding)?\.?\s*(?:the\s+)?(?:arrangement|admin|booking) fee/i.test(t);
}

function exploreMandatoryPackageAddOnFee(blob) {
  const t = String(blob || '').replace(/\u00a0/g, ' ');
  if (!t.trim()) return null;
  if (!/arrangement fee|admin(?:istration)? fee|booking fee/i.test(t)) return null;
  if (!/every package|all packages|applies to every|added to every|total payable.{0,40}arrangement/i.test(t)) {
    return null;
  }
  const m = /(?:arrangement|admin(?:istration)?|booking)\s+fee[^£$€\d]{0,48}[£$€]\s*(\d{2,4})|[£$€]\s*(\d{2,4})\s+(?:arrangement|admin(?:istration)?|booking)\s+fee/i.exec(t);
  if (!m) return 200;
  const n = Number(String(m[1] || m[2] || '').replace(/,/g, '')) || 0;
  if (n < 50 || n > 800) return 200;
  return n;
}

function looksLikeHairOfficialCostMenuUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  return /(?:^|\/)(?:fees|our-fees|prices?|pricing|price-list|pricelist|price-guide|hair-transplant-cost|cost-and-prices|cost)(?:\/|$|\.|-)/i.test(path);
}

function looksLikeHairCachedNonStartingPackageFrom({sourceUrl, blob, priceMin}) {
  const t = String(blob || '');
  if (looksLikeHairStartingPackageRow(t) || hairRowIncludesMandatoryAddOnFee(t)) {
    return false;
  }
  if (looksLikeHairLargerThanStartingPackage(t) || looksLikeHairMarketComparisonRow(t)) {
    return true;
  }
  const n = Math.round(Number(priceMin) || 0);
  if (n === 3599 || n === 3799 || n === 3899 || n === 4099 || n === 4799 || n === 4999) {
    return looksLikeHairOfficialCostMenuUrl(sourceUrl);
  }
  return false;
}

function looksLikeHairMarketPerGraftBlurb(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  if (!/\b(?:fue|fut|grafts?|follicles?|hair transplants?)\b/i.test(t)) return false;
  return /\bhair transplants?\s+in\s+(?:london|the\s+uk)\s+typically\b|(?:often|typically|usually|commonly).{0,48}\bper graft\b|\bper graft\b.{0,40}(?:often|typically|usually|common)|\bfue\b.{0,80}\boften\b.{0,40}per graft|\bfut\b.{0,80}starting at.{0,40}per graft|\bfut\b.{0,48}may be slightly cheaper|\boften\s+(?:cost|costs)\s+[£$€]?\s*\d.{0,24}per graft/i.test(t);
}

function looksLikeHairFutWhenFueRequested({procedure, blob}) {
  const want = String(procedure || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!/\bfue\b/.test(want)) return false;
  const t = String(blob || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!/\bfut\b|\bstrip method\b|\bstrip (?:surgery|procedure)\b/.test(t)) return false;
  if (/\bfue\b/.test(t) &&
      !/\bfut\b.{0,48}(?:£|gbp|per graft)|(?:£|gbp|per graft).{0,24}\bfut\b/.test(t)) {
    return false;
  }
  return true;
}

function looksLikeHairProcedureLandingUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  if (/cost-and-prices|hair-transplant-cost|transplant-cost|\/(?:our-)?fees(?:\/|$)|\/prices?(?:\/|$)|\/pricing(?:\/|$)|\/price-list|\/pricelist|\/price-guide/.test(path)) {
    return false;
  }
  return /fue-hair-transplant|\/fue(?:\/|$)|hair-restoration|\/hair-transplant(?:\/|$)/.test(path);
}

function looksLikeHairStaleLandingQuote({sourceUrl, blob, priceMin, priceMax}) {
  if (!looksLikeHairProcedureLandingUrl(sourceUrl)) return false;
  if (hairGraftSessionQuantity(blob) != null) return false;
  const t = String(blob || '');
  if (/min(?:imum)?\s+fee|2,?400\s*[-–—]\s*3,?000\s*grafts/i.test(t)) return false;
  // Amounts, ranges and the absence of a graft table cannot establish age.
  // Mirror the Flutter verifier's explicit expiry/supersession requirement.
  return /\b(?:expired|superseded|archived|discontinued|no longer available)\b.{0,70}\b(?:price|offer|tariff|package)\b|\b(?:price|offer|tariff|package)\b.{0,70}\b(?:expired|superseded|discontinued|no longer available)\b/i.test(t);
}

function looksLikeUnshavenHairVariant(raw) {
  return /\bunshaven\b|\bun-shaven\b|\bno[- ]shave\b/i.test(String(raw || ''));
}

const HAIR_TECH = '(?:fue|fut|dhi|sapphire|micro[- ]?sapphire)';

function looksLikeGraftOrFollicleQuantity(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  if (looksLikePerGraftQuotedPrice(t)) return false;
  return new RegExp(
      `^\\s*(?:up\\s+to\\s+|area\\s*\\d+\\s*[–\\-—]\\s*)?` +
      `\\d[\\d.,\\s]*(?:\\s*(?:–|—|-|to|و|\\+)\\s*\\d[\\d.,\\s]*)?` +
      `\\s*(?:${HAIR_TECH}\\s+)?-?\\s*` +
      `(?:grafts?|grafturi|follicles?|folicul(?:i|e)?|بصيلة|بصيلات)\\s*\\+?\\s*\\.?\\s*$`,
      'i').test(t);
}

function hairGraftSessionQuantity(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ');
  if (!t.trim()) return null;
  if (looksLikePerGraftQuotedPrice(t)) return null;
  const m = new RegExp(
      `(?:up\\s+to\\s+)?(\\d{1,3}(?:[.,]\\d{3})+|\\d{2,4})\\s*(?:${HAIR_TECH}\\s+)?-?\\s*grafts?\\+?`,
      'i').exec(t);
  if (!m) return null;
  const rawNum = m[1] || '';
  if (rawNum.includes('.') && /^\d{1,3}(?:\.\d{3})+$/.test(rawNum)) {
    const n = Number(rawNum.replace(/\./g, ''));
    return Number.isFinite(n) && n >= 50 && n <= 12000 ? n : null;
  }
  const n = Number(rawNum.replace(/,/g, ''));
  if (!Number.isFinite(n) || n < 50 || n > 12000) return null;
  return n;
}

function looksLikeGraftCountMistakenForPrice({priceMin, blob}) {
  const amount = Number(priceMin) || 0;
  if (amount < 50 || amount > 8000) return false;
  if (looksLikePerGraftQuotedPrice(blob)) return false;
  const qty = hairGraftSessionQuantity(blob);
  if (qty == null || Math.abs(qty - amount) > 0.5) return false;
  if (!hasCurrencySignal(blob)) return true;
  return hasPricingLanguage(blob);
}

function stripGraftQuantityPhrases(raw) {
  return String(raw || '').replace(new RegExp(
      `\\b(?:up\\s+to\\s+)?\\d{1,3}(?:[.,]\\d{3})+\\s*(?:${HAIR_TECH}\\s+)?-?\\s*grafts?\\+?\\b|` +
      `\\b(?:up\\s+to\\s+)?\\d{2,4}\\s*(?:${HAIR_TECH}\\s+)?-?\\s*grafts?\\+?\\b|` +
      `\\b\\d[\\d.,]*\\s*(?:–|—|-|to)\\s*\\d[\\d.,]*\\s*(?:${HAIR_TECH}\\s+)?(?:grafts?|بصيلة|بصيلات)\\b`,
      'gi'), ' ');
}

/// Strip a dose range like "40-50 units" so the parser sees "$18.00 per unit".
///
/// Mirrors stripDosageQuantityPhrases in lib/services/explore_price_sanity.dart.
/// Per-unit menus quote the fee and the average dose together — "BOTOX®
/// Cosmetic $18.00 per unit. On average, 40-50 units are used" — and
/// parsePriceText looks for a numeric range before currency-marked amounts, so
/// the dose won and the row parsed as a $40-50 "price". Only ranges are
/// stripped: a lone "40 units" is already skipped while scanning amounts.
///
/// The number must touch the unit word, so "$2,500 - $4,000 per session" keeps
/// its range because "per" sits between the amount and the unit.
function stripDosageQuantityPhrases(raw) {
  return String(raw || '').replace(new RegExp(
      '\\b(?:up\\s+to\\s+)?\\d[\\d.,]*\\s*(?:–|—|-|to|and)\\s*\\d[\\d.,]*\\s*' +
      '(?:units?|iu|ml|cc|syringes?|vials?|ampoules?|areas?|zones?|' +
      'sessions?|وحدات|مل|منطقة|جلسة)\\b',
      'gi'), ' ');
}

function hairPerGraftPlausibleMax(currency) {
  const c = String(currency || '').trim().toUpperCase();
  switch (c) {
    case 'TRY': case 'TL': case '₺': return 500;
    case 'AED': case 'د.إ': return 150;
    case 'RON': case 'LEI': return 250;
    case 'PLN': case 'ZŁ': return 400;
    case 'RUB': case '₽': return 5000;
    case '₩': case 'KRW': case 'WON': return 8000;
    case 'JPY': case '¥': return 5000;
    case 'HKD': return 150;
    case 'INR': case '₹': return 200;
    case 'SGD': return 50;
    case 'THB': case '฿': return 500;
    default: return 100;
  }
}

function botoxAmountOwnedByCompetingProcedure({rawEvidence, priceMin, currency}, competing) {
  const text = String(rawEvidence || '');
  const money = /(?:EUR\b|AED\b|USD\b|€|\$)\s*(\d+(?:[.,]\d+)?)|(\d+(?:[.,]\d+)?)\s*(EUR\b|AED\b|USD\b|€|\$)/gi;
  const prices = [...text.matchAll(money)];
  const code = (c) => ({'€': 'EUR', '$': 'USD'}[c] || c.toUpperCase());
  let conflicts = 0;
  for (let i = 0; i < prices.length; i++) {
    const match = prices[i];
    const amount = Number((match[1] || match[2]).replace(',', '.'));
    const unit = match[3] || match[0].match(/EUR|AED|USD|€|\$/i)[0];
    if (code(unit) !== code(currency) || Math.abs(amount - Number(priceMin)) > .011) continue;
    const start = i ? prices[i-1].index + prices[i-1][0].length : 0;
    const prefix = text.slice(start, match.index).toLowerCase();
    const toxin = [...prefix.matchAll(/\b(?:botox|botulin\w*|neuromodul\w*)\b/g)];
    const filler = [...prefix.matchAll(competing)];
    if (toxin.length && (!filler.length || toxin.at(-1).index > filler.at(-1).index)) return false;
    if (filler.length) conflicts++;
  }
  return conflicts > 0;
}

function botoxAmountOwnedByFiller(quote) {
  return botoxAmountOwnedByCompetingProcedure(quote,
      /\b(?:hyaluronic\s+acid|acid[ou]\s+hialuronic[ou]?|fillers?)\b/g);
}

function botoxAmountOwnedBySkinTreatment(quote) {
  return botoxAmountOwnedByCompetingProcedure(quote,
      /\b(?:mesoterap\w*|mesotherap\w*|nctf|filorga|skin\s*booster\w*)\b/g);
}

function evaluateExtractedPriceCandidate({
  rawPriceText,
  priceMin,
  currency,
  extractionMethod,
  rawEvidence = '',
  rawProcedureText = '',
  procedure = '',
  sourceUrl = '',
  priceMax = 0,
  structuredOffer = false,
  logRejects = true,
  pageText = '',
  pageTitle = '',
  pageContext = '',
  clinicName = '',
}) {
  const blob = `${rawPriceText || ''}\n${rawEvidence || ''}`.replace(/\u00a0/g, ' ');
  const method = String(extractionMethod || '').trim();
  const weak = isWeakPriceExtractionMethod(method);
  const structured = structuredOffer || isStructuredPriceExtractionMethod(method);
  const amount = Number(priceMin) || 0;

  if (amount <= 0) {
    return {accepted: false, reason: 'missing_price_semantics'};
  }
  const scopeFailure = quoteScopeReason({procedure, rawEvidence, priceMin: amount, currency});
  if (scopeFailure) return {accepted: false, reason: scopeFailure};
  const injectableFailure = injectableScopeRejection({procedure,
    label: rawProcedureText, evidence: rawEvidence, provider: clinicName, sourceUrl});
  if (injectableFailure) return {accepted: false, reason: injectableFailure};
  if (looksLikeCreditLimitQuote({rawPriceText, rawEvidence, priceMin: amount})) {
    return {accepted: false, reason: 'financing_credit_limit'};
  }
  if (looksLikeSpanishMarketPriceQuote(blob)) {
    return {accepted: false, reason: 'spanish_market_price_quote'};
  }
  if (looksLikeLipHydrationWhenAugmentationRequested({procedure, evidence: blob})) {
    return {accepted: false, reason: 'lip_hydration_not_augmentation'};
  }
  if (/botox|botulin|toxin|neuromodul/i.test(procedure) &&
      botoxAmountOwnedBySkinTreatment({rawEvidence, priceMin: amount, currency})) {
    return {accepted: false, reason: 'neighbouring_skin_treatment_amount'};
  }
  if (/filler|hialuron|hyaluron|relleno/i.test(procedure) &&
      (looksLikeSurgicalChinTreatment(`${procedure}\n${blob}`) ||
          looksLikeSurgicalChinTreatment(sourceUrl))) {
    return {accepted: false, reason: 'surgical_chin_not_filler'};
  }
  if (/botox|botulin|toxin|neuromodul/i.test(procedure) &&
      looksLikeCombinedToxinSkinTreatment(`${procedure}\n${blob}`)) {
    return {accepted: false, reason: 'combined_toxin_skinbooster'};
  }
  if (/rhino|rinoplast/i.test(procedure) &&
      looksLikePartialRhinoplastyStarting(`${procedure}\n${blob}`)) {
    return {accepted: false, reason: 'rhino_tip_or_partial'};
  }
  if (/peel/i.test(procedure) &&
      /\bcorporal\w*|\bcuerpo\b|\bbody\b|\bscrub\b|\bsales\b|\bsalt\b|\bsugar\b|autobronceador|enzim[aá]tic|enzymatic|microdermabrasion|peel\s*off/i.test(`${procedure} ${blob}`)) {
    return {accepted: false, reason: 'nonfacial_tariff_scope'};
  }
  if (/(?:^|\/\/)(?:www\.)?(?:multiestetica\.com|gorgeousgetaways\.com)(?:\/|$)/i.test(sourceUrl)) {
    return {accepted: false, reason: 'directory_or_agency_price'};
  }
  if (/\/\/[^/]*booksy\.com\/[^?#]*\/(?:s|l|search|category|categories|explore)\//i.test(sourceUrl)) {
    return {accepted: false, reason: 'marketplace_category'};
  }
  if (/botox|bótox|botulin/i.test(`${procedure} ${blob}`) &&
      /anti[- ]?frizz|anti[- ]?pluis|antiencresp|anti[- ]?encresp|botox\s+(?:capilar|hair|haar|capillaire)|(?:hair|haar|capillary)\s+botox|haar[- ]?botox|botox[- ]?haar|keratin|straightening|alisado|peluquer[ií]a|kapper|botox[ -]*like|brow\s+lamination|lash\s+lift/i.test(`${procedure} ${blob} ${clinicName} ${sourceUrl}`)) {
    return {accepted: false, reason: 'noninjectable_botox'};
  }
  if (/botox|botulin|toxin|neuromodulat/i.test(procedure) &&
      botoxAmountOwnedByFiller({rawEvidence, priceMin: amount, currency})) {
    return {accepted: false, reason: 'neighbouring_filler_amount'};
  }
  if (/\brelated\s+products?\b|\bgift\s+(?:voucher|card)\b|\blorem\s+ipsum\b/i.test(blob)) {
    return {accepted: false, reason: 'non_treatment_label'};
  }

  const ctx = pageContext || classifyExplorePricePageContext({
    sourceUrl,
    pageText: pageText || rawEvidence,
    title: pageTitle || procedure,
  });
  if (!exploreEvidenceIsClinicOwnedPrice({
    pageContext: ctx,
    rawEvidence,
    rawProcedureText: procedure,
    rawPriceText,
    sourceUrl,
    extractionMethod: method,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · not_clinic_owned_price');
    return {accepted: false, reason: 'not_clinic_owned_price'};
  }

  if (looksLikeShopifyThemeDummyPrice({
    rawPriceText, priceMin: amount, currency, rawEvidence, procedure,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · theme_placeholder');
    return {accepted: false, reason: 'theme_placeholder'};
  }
  if (looksLikeUsdQuotedOnUkHost({
    sourceUrl, currency, rawPriceText, rawEvidence,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · tld_currency_mismatch');
    return {accepted: false, reason: 'tld_currency_mismatch'};
  }
  if (looksLikePhoneNumber(rawPriceText) || looksLikePhoneNumber(blob)) {
    if (logRejects) console.log('[GP PRICE] REJECT · phone_number');
    return {accepted: false, reason: 'phone_number'};
  }
  const intDigits = String(Math.round(Math.abs(amount))).length;
  const currUp = String(currency || '').trim().toUpperCase();
  const highDenom = ['KRW', 'JPY', 'IDR', 'VND', 'HUF', 'COP', 'CLP', 'ARS', 'IRR']
      .includes(currUp);
  // Allow larger literal amounts for high-denomination currencies (₩1.5M, Rp15M).
  const digitCap = highDenom ? 12 : 8;
  const absCap = highDenom ? 1e12 : 1e8;
  if (amount >= absCap || intDigits >= digitCap) {
    if (logRejects) console.log('[GP PRICE] REJECT · implausible_amount');
    return {accepted: false, reason: 'implausible_amount'};
  }
  if (looksLikeAddressNumber(rawPriceText) ||
      (weak && looksLikeAddressNumber(blob))) {
    if (logRejects) console.log('[GP PRICE] REJECT · address_number');
    return {accepted: false, reason: 'address_number'};
  }
  if (looksLikeDurationQuotedAsPrice({
    priceMin: amount,
    rawPriceText,
    blob,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · duration');
    return {accepted: false, reason: 'duration'};
  }
  if (PERCENT_CUE.test(String(rawPriceText || '')) &&
      !hasCurrencySignal(rawPriceText)) {
    if (logRejects) console.log('[GP PRICE] REJECT · missing_price_semantics');
    return {accepted: false, reason: 'missing_price_semantics'};
  }
  if (REVIEW_CUE.test(blob)) {
    if (logRejects) console.log('[GP PRICE] REJECT · missing_price_semantics');
    return {accepted: false, reason: 'missing_price_semantics'};
  }
  if (isBareYear(amount, blob) && !structured) {
    if (logRejects) console.log('[GP PRICE] REJECT · missing_price_semantics');
    return {accepted: false, reason: 'missing_price_semantics'};
  }

  const currencyHere = String(currency || '').trim() !== '' ||
      hasCurrencySignal(rawPriceText) || hasCurrencySignal(blob);
  const pricingHere = hasPricingLanguage(rawPriceText) || hasPricingLanguage(blob);
  if (!structured && !currencyHere && !pricingHere) {
    if (logRejects) console.log('[GP PRICE] REJECT · missing_price_semantics');
    return {accepted: false, reason: 'missing_price_semantics'};
  }
  if (weak && !currencyHere && !pricingHere) {
    if (logRejects) console.log('[GP PRICE] REJECT · missing_price_semantics');
    return {accepted: false, reason: 'missing_price_semantics'};
  }
  if (blob.includes('+') && !currencyHere && !pricingHere &&
      digitsOnly(blob).length >= 8) {
    if (logRejects) console.log('[GP PRICE] REJECT · phone_number');
    return {accepted: false, reason: 'phone_number'};
  }

  if (looksLikeGraftOrFollicleQuantity(rawPriceText) ||
      looksLikeGraftCountMistakenForPrice({priceMin: amount, blob})) {
    if (logRejects) console.log('[GP PRICE] REJECT · graft_count');
    return {accepted: false, reason: 'graft_count'};
  }
  if (looksLikeCityMarketPricingGuideUrl(sourceUrl)) {
    if (logRejects) console.log('[GP PRICE] REJECT · market_information');
    return {accepted: false, reason: 'market_information'};
  }
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) {
    if (logRejects) console.log('[GP PRICE] REJECT · finance_page');
    return {accepted: false, reason: 'finance_page'};
  }
  if (looksLikeMonthlyFinancingQuotedAsPrice({priceMin: amount, rawPriceText, blob})) {
    if (logRejects) console.log('[GP PRICE] REJECT · monthly_financing');
    return {accepted: false, reason: 'monthly_financing'};
  }
  if (looksLikeTypicalMarketRangeQuotedAsPrice({priceMin: amount, rawPriceText, blob})) {
    if (logRejects) console.log('[GP PRICE] REJECT · market_average');
    return {accepted: false, reason: 'market_average'};
  }
  if (/\baverage\b[^.]{0,48}\bcost\b|\bcost in\b[^.]{0,40}\bis\b|\bon average\b.{0,48}\b(?:cost|price|prices|range)\b|\btypically costs?\b/i.test(blob)) {
    if (logRejects) console.log('[GP PRICE] REJECT · market_average');
    return {accepted: false, reason: 'market_average'};
  }
  if (looksLikeEffectivePerGraftMarketing(blob) ||
      looksLikeEffectivePerGraftMarketing(rawPriceText) ||
      looksLikeEffectivePerGraftMarketing(procedure)) {
    if (logRejects) console.log('[GP PRICE] REJECT · effective_per_graft');
    return {accepted: false, reason: 'effective_per_graft'};
  }
  if (looksLikeHairMarketPerGraftBlurb(blob) ||
      looksLikeHairMarketPerGraftBlurb(rawPriceText) ||
      looksLikeHairMarketPerGraftBlurb(procedure)) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_market_per_graft');
    return {accepted: false, reason: 'hair_market_per_graft'};
  }
  if (looksLikeHairFutWhenFueRequested({
    procedure, blob: `${blob}\n${procedure}`,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_fut_not_fue');
    return {accepted: false, reason: 'hair_fut_not_fue'};
  }
  if (looksLikeHairStaleLandingQuote({
    sourceUrl, blob: `${blob}\n${procedure}`, priceMin: amount, priceMax,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_stale_landing');
    return {accepted: false, reason: 'hair_stale_landing'};
  }
  if (looksLikeHairDhiWhenFueRequested({
    procedure, blob: `${blob}\n${procedure}`,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_dhi_not_fue');
    return {accepted: false, reason: 'hair_dhi_not_fue'};
  }
  if (looksLikeHairMarketComparisonRow(blob) ||
      looksLikeHairMarketComparisonRow(rawPriceText)) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_market_comparison');
    return {accepted: false, reason: 'hair_market_comparison'};
  }
  if (looksLikeHairLargerThanStartingPackage(blob) ||
      looksLikeHairLargerThanStartingPackage(rawPriceText)) {
    if (logRejects) console.log('[GP PRICE] REJECT · hair_larger_package');
    return {accepted: false, reason: 'hair_larger_package'};
  }

  const spreadMax = Number(priceMax) > amount
      ? Number(priceMax)
      : priceMaxHintFromRaw(rawPriceText, amount);
  if (looksLikeRoundedMarketPriceSpread({
    priceMin: amount,
    priceMax: spreadMax,
    currency,
    procedure,
  })) {
    if (logRejects) console.log('[GP PRICE] REJECT · market_price_spread');
    return {accepted: false, reason: 'market_price_spread'};
  }
  if (looksLikePatientAnecdotePrice(blob) || looksLikePatientAnecdotePrice(rawPriceText)) {
    if (logRejects) console.log('[GP PRICE] REJECT · patient_anecdote');
    return {accepted: false, reason: 'patient_anecdote'};
  }
  if (looksLikeThirdPartyProviderPriceLabel(procedure) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(blob) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(rawPriceText) ||
      looksLikeCompetitorOrThirdPartyPriceQuote(procedure)) {
    if (logRejects) console.log('[GP PRICE] REJECT · competitor_quote');
    return {accepted: false, reason: 'competitor_quote'};
  }
  if (looksLikePartialRhinoplastyStarting(rawPriceText) &&
      !looksLikePrimaryRhinoplastyStarting(rawPriceText)) {
    if (logRejects) console.log('[GP PRICE] REJECT · rhino_tip_or_partial');
    return {accepted: false, reason: 'rhino_tip_or_partial'};
  }

  let band = plausibleAmountBand({currency, procedure});
  if (looksLikePerGraftQuotedPrice(blob) || looksLikePerGraftQuotedPrice(rawPriceText)) {
    if (amount > hairPerGraftPlausibleMax(currency)) {
      if (logRejects) console.log('[GP PRICE] REJECT · implausible_per_graft');
      return {accepted: false, reason: 'implausible_per_graft'};
    }
    band = {min: 1, max: hairPerGraftPlausibleMax(currency)};
  }
  if (looksLikeBotoxPerUnitQuote(blob, procedure) ||
      looksLikeBotoxPerUnitQuote(rawPriceText, procedure)) {
    band = {min: 5, max: 150};
  }
  if (amount < band.min || amount > band.max) {
    if (logRejects) console.log('[GP PRICE] REJECT · implausible_amount');
    return {accepted: false, reason: 'implausible_amount'};
  }
  return {accepted: true, reason: ''};
}

function isValidExtractedPriceCandidate(args) {
  return evaluateExtractedPriceCandidate(args).accepted;
}

function logPriceAccept({
  clinic, procedure, rawPriceText, parsedAmount, currency, extractionMethod, sourceUrl,
}) {
  console.log(
      `[GP PRICE] ACCEPT · clinic="${clinic || ''}" procedure="${procedure || ''}" ` +
      `raw="${rawPriceText || ''}" parsed=${Math.round(parsedAmount || 0)} ${currency || ''} ` +
      `method=${extractionMethod || ''} url=${sourceUrl || ''}`);
}

function stripInvalidCachedPrice(row, procedure, {logRejects = true} = {}) {
  const min = Number(row && (row.price_min || row.priceMin) || 0);
  if (!(min > 0)) return row;
  const rawPrice = String(row.raw_price_text || row.rawPriceText || row.price_label || '').trim();
  const currency = String(row.currency || '').trim();
  const method = String(row.extraction_method || row.extractionMethod || '').trim();
  const evidence = String(row.price_evidence_text || row.rawEvidence || '').trim();
  const proc = String(procedure || row.brand || row.raw_procedure_text || '').trim();
  const sourceUrl = String(row.price_source_url || row.priceSourceUrl ||
      row.source_url || row.sourceUrl || '').trim();
  const verdict = evaluateExtractedPriceCandidate({
    rawPriceText: rawPrice,
    priceMin: min,
    currency,
    extractionMethod: method,
    rawEvidence: evidence,
    procedure: proc,
    sourceUrl,
    priceMax: Number(row && (row.price_max || row.priceMax) || 0),
    rawProcedureText: String(row.raw_procedure_text || row.rawProcedureText || ''),
    clinicName: String(row.provider_clinic || row.providerClinic || row.name || row.clinicName || ''),
    logRejects,
  });
  if (verdict.accepted) return row;
  return {
    ...row,
    price_min: 0,
    price_max: 0,
    price_gbp: 0,
    price_label: '',
    price_verified: false,
    verified: false,
    price_verification_status: 'legacy_unverified',
    needs_revalidation: true,
    price_rejection_reason: verdict.reason,
  };
}

module.exports = {
  botoxAmountOwnedByFiller,
  botoxAmountOwnedBySkinTreatment,
  evaluateExtractedPriceCandidate,
  isValidExtractedPriceCandidate,
  isWeakPriceExtractionMethod,
  looksLikePhoneNumber,
  looksLikeAddressNumber,
  looksLikeDurationQuotedAsPrice,
  looksLikeMonthlyFinancingQuotedAsPrice,
  looksLikeTypicalMarketRangeQuotedAsPrice,
  looksLikeShopifyThemeDummyPrice,
  looksLikeUsdQuotedOnUkHost,
  hostLooksLikeUkClinic,
  looksLikeRoundedMarketPriceSpread,
  looksLikeCityMarketPricingGuideUrl,
  looksLikeTreatmentFinanceUrl,
  exploreUrlPathFamilyKey,
  exploreUrlConflictsWithProcedure,
  looksLikeEnergyOrDeviceTreatment,
  looksLikeHospitalFeesOnlyQuote,
  looksLikeStarredHospitalGuidePrice,
  looksLikePartialRhinoplastyStarting,
  looksLikePrimaryRhinoplastyStarting,
  looksLikePatientAnecdotePrice,
  looksLikePriceMenuHeadingOnly,
  looksLikeBreastAugmentationAddOnRow,
  explorePublishedOrReviewedYear,
  looksLikeDepigmentationPeelPackage,
  looksLikeMultiSessionSeriesQuote,
  looksLikeCompetitorOrThirdPartyPriceQuote,
  looksLikeThirdPartyProviderPriceLabel,
  looksLikeCompetitorPriceColumnHeader,
  looksLikeGraftOrFollicleQuantity,
  looksLikeHairGraftPackageMenuLabel,
  looksLikePerGraftQuotedPrice,
  looksLikeEffectivePerGraftMarketing,
  looksLikeHairNonStartingRow,
  looksLikeHairLargerThanStartingPackage,
  looksLikeHairMarketComparisonRow,
  looksLikeHairDhiWhenFueRequested,
  looksLikeHairStartingPackageRow,
  hairRowIncludesMandatoryAddOnFee,
  exploreMandatoryPackageAddOnFee,
  looksLikeHairOfficialCostMenuUrl,
  looksLikeHairCachedNonStartingPackageFrom,
  looksLikeHairMarketPerGraftBlurb,
  looksLikeHairFutWhenFueRequested,
  looksLikeHairProcedureLandingUrl,
  looksLikeHairStaleLandingQuote,
  looksLikeUnshavenHairVariant,
  looksLikeGraftCountMistakenForPrice,
  stripGraftQuantityPhrases,
  stripDosageQuantityPhrases,
  hairGraftSessionQuantity,
  hairPerGraftPlausibleMax,
  plausibleAmountBand,
  looksLikeBotoxPerUnitQuote,
  hasCurrencySignal,
  logPriceAccept,
  stripInvalidCachedPrice,
};
