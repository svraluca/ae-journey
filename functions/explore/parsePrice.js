'use strict';

const crypto = require('crypto');
const {isApproximatePriceQuote} = require('./procedureScope');
const {looksLikePhoneNumber, looksLikeAddressNumber,
  looksLikeGraftOrFollicleQuantity, looksLikePerGraftQuotedPrice,
  stripGraftQuantityPhrases, stripDosageQuantityPhrases,
  hairGraftSessionQuantity,
  looksLikeCityMarketPricingGuideUrl} = require('./priceSanity');
const {isMarketplaceOrDirectoryHost, looksLikeMarketEstimateDirectoryUrl} = require('./identity');
const {
  detectCurrencyToken,
  stripCurrencyTokensForNumberParse,
} = require('./currencyTokens');

function buildEvidenceHash(sourceUrl, rawProcedureText, rawPriceText) {
  const raw = `${String(sourceUrl || '').trim()}|${String(rawProcedureText || '').trim()}|${String(rawPriceText || '').trim()}`;
  return crypto.createHash('sha256').update(raw).digest('hex').slice(0, 24);
}

function stripTags(raw) {
  return String(raw || '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
}

function parseLocaleNumber(raw) {
  let s = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!s) return null;
  s = s.replace(/['’]/g, '');
  s = s.replace(/[^\d.,\s]/g, '');
  s = s.replace(/\s+/g, '');
  if (!s) return null;

  const hasComma = s.includes(',');
  const hasDot = s.includes('.');
  if (hasComma && hasDot) {
    if (s.lastIndexOf(',') > s.lastIndexOf('.')) {
      s = s.replace(/\./g, '').replace(',', '.');
    } else {
      s = s.replace(/,/g, '');
    }
  } else if (hasComma) {
    if (/,\d{1,2}$/.test(s) && !/,\d{3}$/.test(s)) {
      s = s.replace(',', '.');
    } else if (/,\d{3}(?:\d{3})*$/.test(s)) {
      s = s.replace(/,/g, '');
    } else {
      s = s.replace(',', '.');
    }
  } else if (hasDot) {
    if (/\.\d{3}(?:\d{3})*$/.test(s) && !/\.\d{1,2}$/.test(s)) {
      s = s.replace(/\./g, '');
    }
  }
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

/**
 * Canonical numeric parser. Never ask an LLM to fix formatting.
 * @return {{priceMin:number, priceMax:number, currency:string, priceType:string}|null}
 */
function parsePriceText(raw) {
  const original = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!original) return null;

  const currency = detectCurrencyToken(original);
  const graftSessionQty = hairGraftSessionQuantity(original);
  let working = stripDosageQuantityPhrases(stripGraftQuantityPhrases(original));
  if (looksLikePhoneNumber(original) || looksLikeAddressNumber(original)) {
    return null;
  }
  if (looksLikeGraftOrFollicleQuantity(original)) {
    return null;
  }

  const perGraftQuote = looksLikePerGraftQuotedPrice(original);
  // Prefer original text so "1 ml" dosage survives stripDosageQuantityPhrases.
  const unitQty = parseUnitQuantity(original);
  // "1 ml" in a procedure name is package quantity, not a /ml rate.
  const explicitPerUnit =
      /(?:per|\/)\s*(?:ml|cc|iu|unit|units|syringe|syringes|vial|مل|وحدات)\b/i
          .test(original);
  const explicitPerArea =
      /(?:per|\/)\s*(?:area|areas|zone|zones|منطقة)\b/i.test(original);
  const finish = (p) => {
    let type = p.priceType;
    let unit = unitQty.unit;
    let qty = graftSessionQty != null ? graftSessionQty : unitQty.quantity;
    const u = unitQty.unit;
    if (type === 'fixed' || type === 'from') {
      if (explicitPerArea &&
          ['area', 'areas', 'zone', 'zones', 'منطقة'].includes(u)) {
        type = 'perArea';
      } else if (explicitPerUnit &&
          ['unit', 'units', 'iu', 'وحدات', 'ml', 'cc', 'مل',
            'syringe', 'syringes'].includes(u)) {
        type = 'perUnit';
      } else if (u === 'graft' || u === 'grafts') {
        if (perGraftQuote) {
          type = 'perUnit';
        } else {
          unit = '';
          qty = graftSessionQty != null ? graftSessionQty : unitQty.quantity;
        }
      }
      // else: keep fixed/from + quantity metadata (no auto /ml).
    }
    if (type !== 'sale' && (isApproximatePriceQuote(original, p.priceMin) ||
        isApproximatePriceQuote(original, p.priceMax))) type = 'approximate';
    return {
      priceMin: p.priceMin,
      priceMax: p.priceMax,
      currency: p.currency || currency,
      priceType: type,
      unit,
      quantity: qty,
    };
  };

  let type = 'fixed';
  // No trailing \b on Arabic — JS \w does not include Arabic letters.
  const fromRe = /(?:from|starts?\s+from|starts?\s+at|starting(?:\s+(?:at|from))?|desde|de\s+la|a\s+partir\s+de|ab|od|à\s+partir\s+de)\b|(?:يبدأ من|تبدأ من|تبدا من)/i;
  const fromMatch = fromRe.exec(working);
  if (fromMatch || /\d\s*\+\s*$/.test(working.trim())) type = 'from';
  if (fromMatch) working = working.slice(fromMatch.index);

  const saleDel = working.match(/<del[^>]*>([\s\S]*?)<\/del>/i);
  const saleIns = working.match(/<ins[^>]*>([\s\S]*?)<\/ins>/i);
  if (saleIns) {
    const active = parseLocaleNumber(stripTags(saleIns[1] || ''));
    const originalAmt = saleDel ? parseLocaleNumber(stripTags(saleDel[1] || '')) : null;
    if (active && active > 0) {
      const isSale = originalAmt != null && originalAmt > active;
      return finish({
        priceMin: active,
        priceMax: isSale ? originalAmt : active,
        currency,
        priceType: isSale ? 'sale' : 'fixed',
      });
    }
  }

  working = stripCurrencyTokensForNumberParse(working)
      .replace(/\s+/g, ' ')
      .trim();
  // WooCommerce / BG locales often emit "163 61 €" for European 163,61.
  working = working.replace(
      /\b(\d{1,6})\s+(\d{2})(?=\s*(?:€|eur|euro|euros|£|gbp|\$|usd|ron|lei|bgn|лв|lv\.?|try|tl|aed)?(?:\s|$|[^\d]))/gi,
      (_, a, b) => `${a}.${b}`);
  working = working.replace(/\b(\d{1,3}(?:\s\d{3})+)\b/g, (m) => m.replace(/\s/g, ''));

  const range = working.match(/(\d[\d.,\s]*)\s*(?:–|—|-|to|a|until|hasta)\s*(\d[\d.,\s]*)/i);
  if (range) {
    const lo = parseLocaleNumber(range[1]);
    const hi = parseLocaleNumber(range[2]);
    if (lo && hi && lo > 0 && hi >= lo) {
      return finish({priceMin: lo, priceMax: hi, currency, priceType: 'range'});
    }
  }

  const nums = [];
  for (const m of working.matchAll(/\d[\d.,]*/g)) {
    const after = working.slice(m.index + m[0].length).trimStart();
    if (/^(ml|cc|iu|syringe|syringes|area|areas|zone|zones|session|sessions|vial|vials|package|packages|graft|grafts|unit|units|ampoule|ampoules|مل|منطقة|جلسة|وحدات)\b/i.test(after)) {
      continue;
    }
    const n = parseLocaleNumber(m[0]);
    if (n != null && n >= 1) nums.push(n);
  }
  if (!nums.length) return null;
  if (type === 'from' || nums.length === 1) {
    return finish({priceMin: nums[0], priceMax: nums[0], currency, priceType: type});
  }
  if (nums.length >= 3) {
    return finish({priceMin: nums[0], priceMax: nums[0], currency, priceType: 'fixed'});
  }
  const lo = nums[0] <= nums[1] ? nums[0] : nums[1];
  const hi = nums[0] <= nums[1] ? nums[1] : nums[0];
  if (hi >= lo * 3) {
    return finish({priceMin: nums[0], priceMax: nums[0], currency, priceType: 'fixed'});
  }
  if (String(Math.round(Math.abs(lo))).length >= 8) return null;
  return finish({
    priceMin: lo,
    priceMax: hi,
    currency,
    priceType: type,
  });
}

function parseUnitQuantity(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ');
  if (!t.trim()) return {unit: '', quantity: null};
  const variesWithAreas = /varies\s+with\s+(?:the\s+)?(?:number\s+of\s+)?(?:areas?|zones?)/i.test(t);
  const qtyUnit = t.match(
      /(\d+(?:[.,]\d+)?)\s*-?\s*(ml|cc|iu|syringe|syringes|area|areas|zone|zones|session|sessions|vial|vials|package|packages|graft|grafts|unit|units|ampoule|ampoules|مل|منطقة|جلسة|وحدات)\b/i,
  );
  if (qtyUnit && !(variesWithAreas && /^(?:areas?|zones?)$/i.test(qtyUnit[2] || ''))) {
    const unit = String(qtyUnit[2] || '').toLowerCase();
    const rawQ = String(qtyUnit[1] || '');
    const q = Number(rawQ.replace(',', '.'));
    const graftThousands = (unit === 'graft' || unit === 'grafts') &&
        /^\d{1,3}[.,]\d{3}$/.test(rawQ);
    const graftSession = (unit === 'graft' || unit === 'grafts') &&
        ((Number.isFinite(q) && q >= 50) || graftThousands) &&
        !/(?:per|\/)\s*graft/i.test(t);
    if (!graftSession) {
      return {
        unit,
        quantity: Number.isFinite(q) ? q : null,
      };
    }
  }
  const per = t.match(
      /(?:per|\/|على)\s*(ml|cc|syringe|area|zone|session|vial|package|graft|unit|مل|منطقة|جلسة)\b/i,
  );
  if (per && !variesWithAreas) return {unit: String(per[1] || '').toLowerCase(), quantity: null};
  return {unit: '', quantity: null};
}

function isNonLiteralClinicPriceUrl(sourceUrl) {
  const raw = String(sourceUrl || '').toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) { /* use raw */ }
  if (path.includes('/blog/') ||
      path.includes('/article/') ||
      path.includes('/articles/') ||
      path.includes('/articole/') ||
      path.includes('/articulos/') ||
      path.includes('/artículos/') ||
      path.includes('/noticias/') ||
      path.includes('/stiri/') ||
      path.includes('/ghid/') ||
      path.includes('/guides/') ||
      path.includes('/guide/') ||
      path.includes('aftercare') ||
      path.includes('complete-guide') ||
      path.includes('complete-pricing-guide') ||
      path.includes('complete-price-guide') ||
      path.includes('complete-cost-guide') ||
      path.includes('complete-breakdown') ||
      path.includes('the-cost-of-') ||
      path.includes('cost-of-hair-transplant') ||
      path.includes('how-to-') ||
      path.includes('how-long') ||
      path.includes('-template') ||
      path.includes('/template') ||
      path.includes('page-editor') ||
      raw.includes('preview_theme')) {
    return true;
  }
  if (looksLikeMarketEstimateDirectoryUrl(raw)) return true;
  return /cost-london|london-prices|precio-medio|price-range|average-price|average-cost|cat-costa|cat_costa|how-much-does|how-much-do|cuanto-cuesta|market[-_]?average|typical[-_]?price|city[-_]?average|glutathione|salmon-dna|iv-drip|migraine/.test(raw);
}

/** Smallest span containing both procedure label and price text. */
function shrinkEvidenceToProcedureAndPrice({block, procedure, priceRaw}) {
  const text = String(block || '').replace(/\s+/g, ' ').trim();
  if (!text) return text;
  const proc = String(procedure || '').replace(/\s+/g, ' ').trim();
  const price = String(priceRaw || '').replace(/\s+/g, ' ').trim();
  if (!proc || !price) return text;
  const lo = text.toLowerCase();
  const procLo = proc.toLowerCase();
  const priceLo = price.toLowerCase();
  let pIdx = lo.indexOf(procLo);
  if (pIdx < 0 && procLo.length > 12) pIdx = lo.indexOf(procLo.slice(0, 12));
  let priceIdx = lo.indexOf(priceLo);
  if (priceIdx < 0) {
    const amount = /\d[\d.,]*/.exec(priceLo);
    if (amount) priceIdx = lo.indexOf(amount[0]);
  }
  if (pIdx < 0 || priceIdx < 0) return text;
  const start = Math.min(pIdx, priceIdx);
  const end = Math.max(pIdx + proc.length, priceIdx + price.length);
  if (end <= start || end > text.length) return text;
  const slice = text.slice(start, end).trim();
  return slice.length >= 8 ? slice : text;
}

/**
 * Clinic-owned editorial ("/post/best-botox-in-dubai-reviews-and-prices").
 * Not a menu: a single listed amount is usable, brand ranges are not.
 */
function looksLikeClinicArticlePriceUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  const segments = ['/post/', '/posts/', '/news/', '/insights/', '/resources/',
    '/magazine/', '/articles/', '/tips/', '/for-men/', '/for-women/', '/ask-the-expert/'];
  if (segments.some((seg) => path.includes(seg))) return true;
  return /best-[a-z-]{2,40}-in-|top-\d+-|reviews-and-price|price-comparison|complete-breakdown|complete-pricing-guide|complete-price-guide|complete-cost-guide|the-cost-of-hair/.test(raw);
}

function looksLikeCityCostArticleUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  if (path.includes('/uncategorized/')) return true;
  return /(?:cost|costs|price|prices|pricing)-in-[a-z][a-z-]{2,30}|cost-of-[a-z][a-z-]{2,40}|(?:cost|price)-\d{4}(?:\/|$)|-cost-london(?:\/|$)|cost-london|london-prices|plastic-surgery-cost|plastic-surgery-price|surgery-cost-in-|surgery-prices?-in-|common-prices?|average-(?:cost|price)|complete-pricing-guide|complete-price-guide|complete-cost-guide|(?:^|\/)botox-cost(?:\/|$)/.test(path);
}

function looksLikeOfficialPriceListUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  if (/book-online|\/booking|\/book-now/.test(path)) return false;
  if (/special-?offers?|\/offers?\/|\/deals?\//.test(path)) return false;
  if (looksLikeCityCostArticleUrl(raw)) return false;
  return /(?:^|\/)(?:preturi|precios|precos|preços|prices|pricing|price-list|pricelist|price-guide|tarife|our-fees|fees|information-and-fees|rhinoplasty-cost|hair-transplant-cost|cost-and-prices|cost)(?:\/|$|\.|-)/i.test(path);
}

function looksLikeBotoxSpecialtyVariantUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  return /lip[-_]?flip|barbie[-_]?botox|trap[-_]?tox|gummy[-_]?smile|masseter|hyperhidros|baby[-_]?botox|jawline[-_]?lift|calf[-_]?(?:slim|reduction)|bunny[-_]?line|chin[-_]?dimpl|platysm|migraine[-_]?botox/i.test(path);
}

function looksLikeBotoxStandardStartingUrl(sourceUrl) {
  const raw = String(sourceUrl || '').trim().toLowerCase();
  if (!raw) return false;
  if (looksLikeBotoxSpecialtyVariantUrl(raw)) return false;
  let path = raw;
  try {
    path = new URL(raw.includes('://') ? raw : `https://${raw}`).pathname.toLowerCase();
  } catch (_) {}
  return /upper[-_]?face|anti[-_]?wrinkle|(?:^|\/)(?:1|one)[-_]?area(?:\/|$)|forehead[-_]?botox|frown[-_]?line/i.test(path);
}

const PRICE_RANGE_RE = /\d[\d.,]*\s*(?:aed|eur|euro|usd|gbp|ron|lei|try|€|£|\$|درهم)?\s*(?:to|–|—|-|until|hasta|pana la|până la)\s*(?:aed|eur|euro|usd|gbp|ron|lei|try|€|£|\$|درهم)?\s*\d/i;

/** "AED 750 to AED 1,800 per area" — a spread across brands or clinics. */
function evidenceQuotesPriceRange({
  rawProcedureText = '', rawPriceText = '', priceMin = 0, priceMax = 0,
}) {
  if (priceMin > 0 && priceMax > priceMin + 0.5) return true;
  return PRICE_RANGE_RE.test(String(rawProcedureText)) ||
      PRICE_RANGE_RE.test(String(rawPriceText));
}

function classifyPriceSourceType(sourceUrl) {
  if (isNonLiteralClinicPriceUrl(sourceUrl)) return 'search_snippet';
  const host = hostOf(sourceUrl);
  if (!host) return 'search_snippet';
  if (host.includes('google.') || host.includes('bing.com') || host.includes('yahoo.')) {
    return 'search_snippet';
  }
  if (isMarketplaceOrDirectoryHost(host)) {
    const aggregators = [
      'doctoralia.es', 'doctoralia.com', 'topdoctors.es', 'topdoctors.com',
      'saludestetica.com', 'estheticon.com', 'medigence.com',
    ];
    if (aggregators.some((h) => host === h || host.endsWith('.' + h))) {
      return 'aggregator';
    }
    return 'marketplace';
  }
  return 'official_clinic';
}

function hostOf(url) {
  try {
    const u = new URL(String(url || '').includes('://') ? url : `https://${url}`);
    return u.hostname.toLowerCase().replace(/^www\./, '');
  } catch (_) {
    return '';
  }
}

function htmlLooksLikeJsShell(html) {
  const raw = String(html || '').trim();
  if (!raw) return true;
  const lower = raw.toLowerCase();
  const stripped = raw
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  if ((lower.includes('enable javascript') || lower.includes('enable js')) &&
      stripped.length < 250) {
    return true;
  }
  if (raw.length > 1500 && stripped.length < 180) return true;
  if (stripped.length < 80 && /<div[^>]+id=["'](?:root|app|__next)["']/.test(lower)) {
    return true;
  }
  return false;
}

/**
 * Keep the already-parsed number. Ignore any AI price fields.
 */
function applyLabelClassification(evidence, aiJson) {
  const json = aiJson && typeof aiJson === 'object' ? aiJson : {};
  for (const key of ['price', 'price_min', 'price_max', 'priceMin', 'priceMax', 'cost', 'amount']) {
    if (json[key] != null) {
      console.log('[PRICE] AI NUMERIC OUTPUT IGNORED');
      break;
    }
  }
  const family = String(json.family || json.procedure_family || '').trim();
  const canonical = String(json.canonical || json.canonical_procedure || '').trim();
  const confidence = Number(json.confidence);
  return {
    ...evidence,
    procedureFamily: family || evidence.procedureFamily || '',
    procedureCanonical: canonical || evidence.procedureCanonical || '',
    confidence: Number.isFinite(confidence) ? confidence : evidence.confidence,
    priceMin: evidence.priceMin,
    priceMax: evidence.priceMax,
    currency: evidence.currency,
    rawPriceText: evidence.rawPriceText,
  };
}

module.exports = {
  buildEvidenceHash,
  parsePriceText,
  parseLocaleNumber,
  parseUnitQuantity,
  detectCurrencyToken,
  classifyPriceSourceType,
  isNonLiteralClinicPriceUrl,
  looksLikeClinicArticlePriceUrl,
  looksLikeCityCostArticleUrl,
  looksLikeCityMarketPricingGuideUrl,
  looksLikeOfficialPriceListUrl,
  looksLikeBotoxSpecialtyVariantUrl,
  looksLikeBotoxStandardStartingUrl,
  shrinkEvidenceToProcedureAndPrice,
  evidenceQuotesPriceRange,
  hostOf,
  htmlLooksLikeJsShell,
  applyLabelClassification,
  stripTags,
};
