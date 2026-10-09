'use strict';

const cheerio = require('cheerio');
const {isApproximatePriceQuote} = require('./procedureScope');
const {classifyExplorePricePageContext,
  looksLikeConditionalCompanionOffer} = require('./priceOwnership');
const {
  parsePriceText,
  buildEvidenceHash,
  classifyPriceSourceType,
  shrinkEvidenceToProcedureAndPrice,
} = require('./parsePrice');
const {
  evaluateExtractedPriceCandidate,
  looksLikeRoundedMarketPriceSpread,
  looksLikeCompetitorPriceColumnHeader,
  looksLikeThirdPartyProviderPriceLabel,
  looksLikeGraftOrFollicleQuantity,
  looksLikePerGraftQuotedPrice,
  hairGraftSessionQuantity,
  looksLikePriceMenuHeadingOnly,
} = require('./priceSanity');
const {
  isMarketplaceOrDirectoryHost,
  extractMarketplaceProviderName,
  marketplacePlatformLabel,
  looksLikeRawScrapedProcedureTitle,
  looksLikeFinancingOrPaymentHeading,
  looksLikeCatalogSectionHeading,
} = require('./identity');

// Arabic menus print dirhams as "درهم" / "د.إ" instead of "AED".
const PRICE_LIKE = /(?:€|eur|£|gbp|\$|usd|ron|lei|try|tl|pln|zł|aed|درهم|د\.إ)\s*\d|\d[\d.,\s]*\s*(?:€|eur|£|gbp|\$|usd|ron|lei|try|tl|pln|zł|aed|درهم|د\.إ)|(?:from|desde|de\s+la|a\s+partir\s+de|يبدأ من|تبدأ من)\s*[€£$]?\s*\d/i;
const BARE_PRICE = /(?:from|desde|de\s+la|a\s+partir\s+de)?\s*[€£$]?\s*\d{2,6}(?:[.,]\d{2,3})?\s*(?:€|eur|£|gbp|ron|lei|aed|درهم|د\.إ)?/i;

function looksLikeCommerceChromeLabel(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim().toLowerCase();
  if (!t) return false;
  if (/^(sale!?|on\s*sale|hot!?|new!?|promo!?|offer!?|oferta!?|description|descripcion|descripción|uncategorized|uncategorised|related products|you may also like|add to cart|book now|book now\s*>|know more|know more\s*>|quantity|category|categories|sku|in stock|out of stock|original price was|current price is)$/i.test(t)) {
    return true;
  }
  if (t.includes('book now') && t.includes('know more')) return true;
  if (looksLikeFinancingOrPaymentHeading(t)) return true;
  return t === 'sale' || t.startsWith('sale!') || t === 'onsale';
}

function looksLikeProcedureLabel(raw) {
  const t = String(raw || '').trim();
  if (t.length < 3 || t.length > 140) return false;
  // Arabic/Greek/Cyrillic menus have no Latin letters — still real labels.
  if (!/[A-Za-zÀ-ÿ\u0370-\u04ff\u0600-\u06ff]/.test(t)) return false;
  if (/^\d[\d.,\s]*\s*[€£$]?\s*$/.test(t)) return false;
  if (looksLikeCommerceChromeLabel(t)) return false;
  if (looksLikePriceMenuHeadingOnly(t)) return false;
  if (looksLikeRawScrapedProcedureTitle(t)) return false;
  return true;
}

function isGenericSectionHeading(raw) {
  const t = String(raw || '').trim().toLowerCase();
  if (!t) return true;
  if (looksLikeCatalogSectionHeading(t)) return true;
  return t === 'precios' || t === 'prices' || t === 'price list' ||
      t === 'tarifas' || t === 'menu' || t === 'menú' || t === 'tratamientos' ||
      t.includes('lista de precio');
}

function nearestSectionHeading($, el) {
  let cur = el;
  for (let i = 0; i < 10 && cur && cur.length; i++) {
    let sib = cur.prev();
    while (sib && sib.length) {
      const tag = String((sib.get(0) && sib.get(0).tagName) || '').toLowerCase();
      if (/^h[1-6]$/.test(tag)) {
        const t = visibleText($, sib);
        if (looksLikeProcedureLabel(t) && !isGenericSectionHeading(t)) return t;
      }
      sib = sib.prev();
    }
    cur = cur.parent();
  }
  return '';
}

function withSectionContext($, el, procedure) {
  const label = String(procedure || '').trim();
  if (!label) return label;
  if (looksLikeCatalogSectionHeading(label) && !looksLikeProcedureLabel(label)) {
    return label;
  }
  if (/^treatments?$/i.test(label)) return label;
  const heading = nearestSectionHeading($, el);
  if (!heading) return label;
  if (looksLikeCatalogSectionHeading(heading)) return label;
  if (label.toLowerCase().includes(heading.toLowerCase())) return label;
  return `${heading} · ${label}`;
}

function visibleText($, el) {
  if (!el || !el.length) return '';
  return $(el).text().replace(/\s+/g, ' ').trim();
}

function listedRawPriceText(raw, parsed) {
  let t = String(raw || '').replace(/\s+/g, ' ').trim();
  t = t.replace(/\s*\(\s*was\b[^)]*\)/i, '').trim();
  if (!t) return t;
  const hasCurrency = /(ron|lei|eur|usd|gbp|aed|try|€|£|\$|درهم|د\.إ)/i.test(t);
  if (!hasCurrency && parsed && parsed.currency) {
    return `${t} ${parsed.currency}`;
  }
  return t;
}

function makeEvidence(partial) {
  if (looksLikeConditionalCompanionOffer(
      `${partial.rawProcedureText || ''} ${partial.rawEvidence || ''}`)) return null;
  const hash = buildEvidenceHash(
      partial.sourceUrl, partial.rawProcedureText, partial.rawPriceText);
  const evidence = shrinkEvidenceToProcedureAndPrice({
    block: String(partial.rawEvidence || ''),
    procedure: String(partial.rawProcedureText || ''),
    priceRaw: String(partial.rawPriceText || ''),
  });
  let quantity = partial.quantity == null ? null : partial.quantity;
  if (!(Number(quantity) >= 50)) {
    const graftQty = hairGraftSessionQuantity(
        `${partial.rawProcedureText || ''} ${partial.rawPriceText || ''} ${partial.rawEvidence || ''}`);
    if (graftQty != null) quantity = graftQty;
  }
  const row = {
    rawProcedureText: partial.rawProcedureText,
    rawPriceText: partial.rawPriceText,
    priceMin: partial.priceMin,
    priceMax: partial.priceMax,
    currency: partial.currency || '',
    priceType: (isApproximatePriceQuote(evidence, partial.priceMin) ||
        isApproximatePriceQuote(evidence, partial.priceMax))
      ? 'approximate' : (partial.priceType || 'unknown'),
    sourceUrl: partial.sourceUrl,
    extractionMethod: partial.extractionMethod,
    rawEvidence: String(evidence || '').slice(0, 240),
    confidence: partial.confidence || 0.8,
    evidenceHash: hash,
    sourceType: classifyPriceSourceType(partial.sourceUrl),
    procedureFamily: '',
    procedureCanonical: '',
    providerClinic: '',
    sourcePlatform: isMarketplaceOrDirectoryHost(partial.sourceUrl)
      ? marketplacePlatformLabel(partial.sourceUrl) : '',
    unit: partial.unit || '',
    quantity,
  };
  const verdict = evaluateExtractedPriceCandidate({
    rawPriceText: row.rawPriceText,
    priceMin: row.priceMin,
    currency: row.currency,
    extractionMethod: row.extractionMethod,
    rawEvidence: row.rawEvidence,
    procedure: row.rawProcedureText,
    sourceUrl: row.sourceUrl,
    priceMax: row.priceMax,
    structuredOffer: row.extractionMethod === 'json_ld' ||
        row.extractionMethod === 'schema_offer',
  });
  if (!verdict.accepted) return null;
  return row;
}

function walkJsonLd(node, sourceUrl, out) {
  if (Array.isArray(node)) {
    for (const item of node) walkJsonLd(item, sourceUrl, out);
    return;
  }
  if (!node || typeof node !== 'object') return;
  if (node['@graph']) walkJsonLd(node['@graph'], sourceUrl, out);

  const type = String(node['@type'] || '').toLowerCase();
  const name = String(node.name || node.title || '').trim();
  const description = String(node.description || '').trim();
  const label = name || description;

  const fromOffer = (offer, procedure) => {
    if (Array.isArray(offer)) {
      for (const o of offer) fromOffer(o, procedure);
      return;
    }
    if (!offer || typeof offer !== 'object') return;
    const currency = String(offer.priceCurrency || offer.pricecurrency || '').trim().toUpperCase();
    const low = String(offer.lowPrice || offer.price || offer.highPrice || '').trim();
    const high = String(offer.highPrice || '').trim();
    if (!low && !offer.price) return;
    const rawPrice = high && high !== low ? `${low}–${high} ${currency}` : `${low} ${currency}`;
    const parsed = parsePriceText(rawPrice);
    if (!parsed || parsed.priceMin <= 0) return;
    let proc = String(procedure || label || '').trim();
    if (!proc) {
      const offered = offer.itemOffered;
      if (offered && typeof offered === 'object') {
        proc = String(offered.name || offered.title || offered.description || '').trim();
      }
    }
    if (!proc) proc = String(offer.name || offer.category || '').trim();
    if (!proc) return;
    out.push(makeEvidence({
      rawProcedureText: proc,
      rawPriceText: rawPrice.trim(),
      priceMin: parsed.priceMin,
      priceMax: high ? (Number(high) || parsed.priceMax) : parsed.priceMin,
      currency: parsed.currency || currency,
      priceType: parsed.priceType,
      sourceUrl,
      extractionMethod: type.includes('offer') && !type.includes('product')
        ? 'schema_offer' : 'json_ld',
      rawEvidence: JSON.stringify(offer).slice(0, 240),
      confidence: 0.98,
    }));
  };

  if (type.includes('product') || type.includes('service') ||
      type.includes('offer') || type.includes('aggregateoffer')) {
    if (node.offers) fromOffer(node.offers, label);
    else if (type.includes('offer') || type.includes('aggregateoffer')) {
      fromOffer(node, label);
    }
  }
  for (const key of ['hasOfferCatalog', 'itemListElement', 'makesOffer']) {
    if (node[key]) walkJsonLd(node[key], sourceUrl, out);
  }
}

function extractJsonLd($, sourceUrl) {
  const out = [];
  $('script[type="application/ld+json"]').each((_, el) => {
    const raw = $(el).contents().text().trim();
    if (!raw) return;
    try {
      walkJsonLd(JSON.parse(raw), sourceUrl, out);
    } catch (_) {
      for (const chunk of raw.split(/\}\s*\{/)) {
        let piece = chunk.trim();
        if (!piece.startsWith('{')) piece = `{${piece}`;
        if (!piece.endsWith('}')) piece = `${piece}}`;
        try {
          walkJsonLd(JSON.parse(piece), sourceUrl, out);
        } catch (__) { /* ignore */ }
      }
    }
  });
  return out;
}

function preferredTablePriceCell(priceCells) {
  const usable = (t) => t && !looksLikeGraftOrFollicleQuantity(t);
  for (const t of priceCells) {
    if (usable(t) && /(?:€|£|\$|gbp|eur|aed|ron|lei|درهم|د\.إ)/i.test(t)) return t;
  }
  for (const t of priceCells) {
    if (usable(t) && looksLikePerGraftQuotedPrice(t)) return t;
  }
  for (const t of priceCells) {
    if (usable(t)) return t;
  }
  return '';
}

function stripSurroundingPageCopyFromProcedureTitle(raw) {
  let t = String(raw || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  if (!t) return '';
  t = t.replace(
      /(?:every\s+\d+\s*(?:to|-|–|—)\s*\d+\s+weeks?,?\s*)?depending on (?:provider|physician|doctor|practitioner) discretion/ig,
      ' ');
  t = t.replace(/\bevery\s+\d+\s*(?:to|-|–|—)\s*\d+\s+weeks?\b/ig, ' ');
  t = t.replace(/\bfrequency\s*:?/ig, ' ');
  t = t.replace(/\s+/g, ' ').trim();
  t = t.replace(/^(?:pricing|prices|price|our pricing|our prices)\s+/i, '');
  t = t.replace(/\b(?:pricing|prices|price)\s+(?=face\b|vi\s*peel\b|chemical\b)/ig, '');
  return t.replace(/\s+/g, ' ').trim();
}

function procedureBeforePublishedPrice(text) {
  const t = String(text || '').replace(/\u00a0/g, ' ').trim();
  const cleaned = (procedure) => {
    const label = stripSurroundingPageCopyFromProcedureTitle(procedure);
    return looksLikeProcedureLabel(label) ? label : '';
  };
  const fromCut = t.search(
      /(?:from|starts?\s+from|starts?\s+at|starting(?:\s+from)?)\s*(?:aed|usd|eur|gbp|€|£|\$|درهم|د\.إ)?\s*\d/i);
  if (fromCut >= 3) {
    const procedure = t.slice(0, fromCut).replace(/[–—\-:\s]+$/, '').trim();
    const label = cleaned(procedure);
    if (label) return label;
  }
  if (t.length > 160 ||
      /\b(?:offering|clinics? that|ridiculously|typically last|consultation|financing|carecredit)\b/i.test(t)) {
    return '';
  }
  const cashCut = t.search(/(?:\$|€|£)\s*\d|(?:usd|eur|gbp|aed|ron|lei|درهم|د\.إ)\s*\d|\d[\d.,]*\s*(?:usd|eur|gbp|aed|ron|lei|€|£)/i);
  if (cashCut < 3) return '';
  const procedure = t.slice(0, cashCut).replace(/[–—\-:\s]+$/, '').trim();
  const label = cleaned(procedure);
  if (!label) return '';
  if (label.split(/\s+/).length > 8) return '';
  return label;
}

function looksLikeSingleNamedMenuLine(text) {
  const t = String(text || '').replace(/\u00a0/g, ' ').trim();
  if (t.length < 8 || t.length > 160) return false;
  if (/\btypical(?:ly)?\s+sessions?\s+rang|\bprices?\s+vary\s+depending\b/i.test(t)) {
    return false;
  }
  if (!PRICE_LIKE.test(t)) return false;
  return procedureBeforePublishedPrice(t).length > 0;
}

function tableColumnHeaders($, tr) {
  const table = $(tr).closest('table');
  if (!table.length) return [];
  const headerRow = table.find('thead tr').first().length
      ? table.find('thead tr').first()
      : table.find('tr').first();
  const out = [];
  headerRow.find('th, td').each((_, cell) => {
    out.push(visibleText($, $(cell)));
  });
  return out;
}

function isFormerPriceHeader(raw) {
  return /^(?:antes|anterior|precio\s+(?:anterior|original)|(?:previous|original|old)(?:\s+price)?|was)$/i
      .test(String(raw || '').replace(/\s+/g, ' ').trim());
}

function removeFormerPriceColumns($) {
  $('table').each((_, table) => {
    const firstRow = $(table).find('thead tr').first().length
      ? $(table).find('thead tr').first() : $(table).find('tr').first();
    const headers = firstRow.find('th, td').map((__, cell) => visibleText($, $(cell))).get();
    const oldColumns = headers.flatMap((header, i) => isFormerPriceHeader(header) ? [i] : []);
    if (!oldColumns.length) return;
    $(table).find('tr').each((__, tr) => {
      if (tr === firstRow.get(0)) return;
      const cells = $(tr).children('th, td');
      for (const i of oldColumns) cells.eq(i).empty();
    });
  });
}

function extractTables($, sourceUrl) {
  const out = [];
  $('tr').each((_, tr) => {
    const cells = $(tr).find('th, td');
    if (cells.length < 2) return;
    const headers = tableColumnHeaders($, tr);
    let procedure = '';
    const priceCells = [];
    const priceHeaders = new Map();
    cells.each((i, cell) => {
      const t = visibleText($, $(cell));
      if (!t) return;
      if (looksLikeGraftOrFollicleQuantity(t)) {
        if (!procedure) procedure = t;
        return;
      }
      const header = headers[i] || '';
      if (isFormerPriceHeader(header) || looksLikeCompetitorPriceColumnHeader(header) ||
          looksLikeThirdPartyProviderPriceLabel(header)) {
        return;
      }
      if (PRICE_LIKE.test(t) || BARE_PRICE.test(t)) {
        priceCells.push(t);
        priceHeaders.set(t, header);
      } else if (!procedure && looksLikeProcedureLabel(t)) {
        procedure = t;
      }
    });
    const priceRaw = preferredTablePriceCell(priceCells);
    if (!procedure || !priceRaw) return;
    if (looksLikeThirdPartyProviderPriceLabel(procedure) ||
        looksLikeCompetitorPriceColumnHeader(procedure)) {
      return;
    }
    const priceHeader = priceHeaders.get(priceRaw) || '';
    const dose = priceHeader.match(/\b\d+(?:[.,]\d+)?\s*(?:viales?|vials?|ml|sesiones?|sessions?)\b/i);
    if (dose && !procedure.toLowerCase().includes(dose[0].toLowerCase())) {
      procedure = `${procedure} · ${dose[0]}`;
    }
    procedure = withSectionContext($, $(tr), procedure);
    const parsed = parsePriceText(priceRaw);
    if (!parsed || parsed.priceMin <= 0) return;
    out.push(makeEvidence({
      rawProcedureText: procedure,
      rawPriceText: listedRawPriceText(priceRaw, parsed),
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency,
      priceType: parsed.priceType,
      unit: parsed.unit,
      quantity: parsed.quantity,
      sourceUrl,
      extractionMethod: 'html_table',
      rawEvidence: `${procedure} | ${priceHeader} | ${priceRaw}`,
      confidence: 0.97,
    }));
  });
  return out;
}

function nearestProcedureLabel($, priceEl) {
  let cur = priceEl;
  for (let i = 0; i < 8 && cur && cur.length; i++) {
    const heading = cur.find(
        'h1, h2, h3, h4, .product_title, .entry-title, .woocommerce-loop-product__title, .title span',
    ).first();
    if (heading.length) {
      const t = visibleText($, heading);
      if (looksLikeProcedureLabel(t) && !looksLikeCommerceChromeLabel(t)) return t;
    }
    let sib = cur.prev();
    while (sib && sib.length) {
      if (sib.hasClass('onsale') || looksLikeCommerceChromeLabel(visibleText($, sib))) {
        sib = sib.prev();
        continue;
      }
      const t = visibleText($, sib);
      if (looksLikeProcedureLabel(t) && t.length <= 120) return t;
      const inner = sib.find('h1, h2, h3, h4, .product_title').first();
      if (inner.length) {
        const ht = visibleText($, inner);
        if (looksLikeProcedureLabel(ht)) return ht;
      }
      sib = sib.prev();
    }
    if (cur.hasClass('product-item') ||
        (cur.hasClass('product') && !cur.hasClass('product-grid') &&
            !cur.hasClass('products'))) {
      break;
    }
    cur = cur.parent();
  }
  return '';
}

function wooProductTitle($) {
  const sels = [
    'h1.product_title', '.product_title', '.summary .product_title',
    '.entry-summary .product_title', '.title h1', '.title h2', '.title h2 span',
    'nav.woocommerce-breadcrumb li:last-child', '.woocommerce-breadcrumb li:last-child',
  ];
  for (const sel of sels) {
    const el = $(sel).first();
    if (!el.length) continue;
    const t = visibleText($, el);
    if (!t || looksLikeCommerceChromeLabel(t)) continue;
    if (looksLikeProcedureLabel(t)) return t;
  }
  return '';
}

function isInsideStruckThroughSalePrice($, node) {
  let cur = $(node);
  for (let i = 0; i < 6 && cur && cur.length; i++) {
    const tag = String((cur.get(0) && cur.get(0).tagName) || '').toLowerCase();
    if (tag === 'del') {
      return cur.parent().find('ins').length > 0;
    }
    if (tag === 'ins') return false;
    cur = cur.parent();
  }
  return false;
}

function priceContainer($, node) {
  let cur = $(node);
  for (let i = 0; i < 6 && cur && cur.length; i++) {
    const tag = String((cur.get(0) && cur.get(0).tagName) || '').toLowerCase();
    if (tag === 'del' || tag === 'ins') {
      cur = cur.parent();
      continue;
    }
    const parent = cur.parent();
    if (!parent.length) break;
    if (parent.find('.product-item, li.product').length > 1) break;
    if (parent.find('del, ins').length ||
        String((parent.get(0) && parent.get(0).tagName) || '').toLowerCase() === 'p' ||
        parent.hasClass('price') || parent.hasClass('summary') ||
        parent.hasClass('entry-summary')) {
      cur = parent;
      continue;
    }
    break;
  }
  return cur;
}

function extractWooCommerce($, sourceUrl) {
  const out = [];
  const seen = new Set();
  const productTitle = wooProductTitle($);
  const isProductPage = /\/product\/|\/products\/|\/shop\//i.test(sourceUrl);
  let nodes = isProductPage
    ? $('.summary.entry-summary > p.price, .entry-summary > p.price, .summary > p.price, .product .summary p.price')
    : $();
  if (!nodes.length) {
    nodes = $('p.price, .summary .price, .entry-summary .price, .woocommerce-Price-amount, span.price, .price');
  }
  nodes.each((_, node) => {
    if (isInsideRelatedOrUpsell($, node)) return;
    if (isInsideStruckThroughSalePrice($, node)) return;
    const block = priceContainer($, node);
    const key = block.toString().slice(0, 160);
    if (seen.has(key)) return;
    seen.add(key);
    const del = block.find('del').first();
    const ins = block.find('ins').first();
    let rawPrice;
    let parsed;
    if (ins.length) {
      const insText = visibleText($, ins);
      const delText = del.length ? visibleText($, del) : '';
      rawPrice = insText;
      const active = parsePriceText(insText);
      const original = delText ? parsePriceText(delText) : null;
      if (!active || active.priceMin <= 0) return;
      const isSale = !!(original && original.priceMin > active.priceMin);
      parsed = {
        priceMin: active.priceMin,
        priceMax: isSale ? original.priceMin : active.priceMin,
        currency: active.currency || (original && original.currency) || '',
        priceType: isSale ? 'sale' : active.priceType,
      };
    } else {
      rawPrice = visibleText($, block);
      const currentCue = rawPrice.match(/Current price is:\s*([\d.,]+\s*[A-Za-z€£$]*)/i);
      if (currentCue) rawPrice = currentCue[1].trim();
      parsed = parsePriceText(rawPrice);
      if (!parsed || parsed.priceMin <= 0) return;
    }
    let procedure = nearestProcedureLabel($, block);
    const inMainSummary = isInsideMainProductSummary($, block);
    if (!procedure || looksLikeCommerceChromeLabel(procedure)) {
      if (inMainSummary || isProductPage) procedure = productTitle;
    }
    if (!procedure || looksLikeCommerceChromeLabel(procedure)) return;
    procedure = cleanWooProcedureLabel(procedure, productTitle);
    out.push(makeEvidence({
      rawProcedureText: procedure,
      rawPriceText: rawPrice,
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency,
      priceType: parsed.priceType,
      sourceUrl,
      extractionMethod: 'woocommerce',
      rawEvidence: `${procedure} · ${rawPrice}`,
      confidence: inMainSummary ? 0.97 : 0.96,
    }));
    if (isProductPage && inMainSummary) return false; // break .each
  });
  return out;
}

function isInsideRelatedOrUpsell($, node) {
  let cur = $(node);
  for (let i = 0; i < 10 && cur && cur.length; i++) {
    const id = String(cur.attr('id') || '').toLowerCase();
    const cls = String(cur.attr('class') || '').toLowerCase();
    if (cls.includes('related') || cls.includes('upsell') ||
        cls.includes('cross-sell') || id.includes('related')) {
      return true;
    }
    cur = cur.parent();
  }
  return false;
}

function isInsideMainProductSummary($, node) {
  let cur = $(node);
  for (let i = 0; i < 8 && cur && cur.length; i++) {
    const cls = String(cur.attr('class') || '').toLowerCase();
    if (cls.includes('entry-summary') ||
        (cls.includes('summary') && !cls.includes('after-summary'))) {
      return true;
    }
    cur = cur.parent();
  }
  return false;
}

function cleanWooProcedureLabel(raw, productTitle) {
  let t = String(raw || '').replace(/\s+/g, ' ').trim();
  if (productTitle && t.toLowerCase().includes(String(productTitle).toLowerCase())) {
    return productTitle;
  }
  t = t.replace(/^(home|shop)\s+/i, '');
  const dup = t.match(/^(.+?)\s+(?:home|shop)\s+\1$/i);
  if (dup) return dup[1].trim();
  return t;
}

function extractShopify(html, sourceUrl) {
  const out = [];
  const jsonBlocks = html.matchAll(/<script[^>]*type="application\/json"[^>]*>([\s\S]*?)<\/script>/gi);
  for (const m of jsonBlocks) {
    const raw = (m[1] || '').trim();
    if (!raw || raw.length > 400000) continue;
    try {
      walkShopifyJson(JSON.parse(raw), sourceUrl, out);
    } catch (_) { /* ignore */ }
  }
  return out;
}

function walkShopifyJson(node, sourceUrl, out) {
  if (Array.isArray(node)) {
    for (const item of node) walkShopifyJson(item, sourceUrl, out);
    return;
  }
  if (!node || typeof node !== 'object') return;
  const title = String(node.title || node.name || '').trim();
  const variants = node.variants;
  if (title && Array.isArray(variants) && variants.length) {
    const vm = variants[0] || {};
    const priceRaw = String(vm.price || '');
    const compare = String(vm.compare_at_price || '');
    const parsed = parsePriceText(`${priceRaw} EUR`);
    if (parsed) {
      let min = parsed.priceMin;
      if (min >= 100 && Number.isInteger(min) && priceRaw.length >= 4 &&
          !priceRaw.includes('.') && min > 5000) {
        min = min / 100;
      }
      const orig = compare ? Number(compare) : null;
      out.push(makeEvidence({
        rawProcedureText: title,
        rawPriceText: priceRaw,
        priceMin: min,
        priceMax: orig && orig > min ? orig : min,
        currency: parsed.currency,
        priceType: orig && orig > min ? 'sale' : 'fixed',
        sourceUrl,
        extractionMethod: 'shopify',
        rawEvidence: JSON.stringify(vm).slice(0, 240),
        confidence: 0.94,
      }));
    }
  }
  for (const v of Object.values(node)) {
    if (v && typeof v === 'object') walkShopifyJson(v, sourceUrl, out);
  }
}

function firstPriceChild($, el) {
  const sels = [
    'ins', '.woocommerce-Price-amount', '.service-list--price', '.price',
    'strong', 'span', 'div.price', 'p',
  ];
  for (const sel of sels) {
    const found = el.find(sel);
    for (let i = 0; i < found.length; i++) {
      const child = found.eq(i);
      const t = visibleText($, child);
      if (!t || looksLikeGraftOrFollicleQuantity(t)) continue;
      if (PRICE_LIKE.test(t) || BARE_PRICE.test(t)) return child;
    }
  }
  return null;
}

function extractCardsAndLists($, sourceUrl) {
  const out = [];
  const blocks = $('li, p, .service, .servicio, .product, .product-item, .card, .tratamiento, .treatment, .item, article, div');
  blocks.each((_, node) => {
    const el = $(node);
    const text = visibleText($, el);
    if (text.length < 8 || text.length > 400) return;
    if (!PRICE_LIKE.test(text)) return;
    const tag = (node.tagName || node.name || '').toLowerCase();
    const priceEl = firstPriceChild($, el);
    let priceRaw = '';
    let parsed = null;
    if (priceEl) {
      priceRaw = visibleText($, priceEl);
      parsed = parsePriceText(priceRaw);
    } else if (tag === 'li' || tag === 'p' || looksLikeSingleNamedMenuLine(text)) {
      parsed = parsePriceText(text);
      if (parsed && parsed.priceMin > 0) priceRaw = text;
    } else {
      return;
    }
    if (!parsed || parsed.priceMin <= 0 || !priceRaw) return;
    if (/no less than|good boob job|most reputable clinics|should be no less/i.test(text)) {
      return;
    }
    if (looksLikeRoundedMarketPriceSpread({
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency,
      procedure: text,
    })) {
      return;
    }
    const heading = el.find(
      'h1, h2, h3, h4, .product_title, .entry-title, .service-list--block-title-text',
    ).first();
    let procedure = heading.length ? visibleText($, heading) : '';
    if (looksLikePriceMenuHeadingOnly(procedure)) procedure = '';
    if (!procedure) {
      procedure = text.replace(priceRaw, ' ').replace(/\s+/g, ' ').trim();
    }
    if (!procedure || procedure === priceRaw) {
      procedure = procedureBeforePublishedPrice(text);
    }
    procedure = stripSurroundingPageCopyFromProcedureTitle(procedure);
    procedure = withSectionContext($, el, procedure);
    if (!procedure || procedure === priceRaw || !looksLikeProcedureLabel(procedure)) return;
    const cls = String(el.attr('class') || '');
    let method = 'dom_block';
    if (tag === 'li') method = 'list_item';
    else if (/\b(product-item|product|service|servicio)\b/.test(cls)) method = 'product_card';
    out.push(makeEvidence({
      rawProcedureText: procedure,
      rawPriceText: priceRaw,
      priceMin: parsed.priceMin,
      priceMax: parsed.priceMax,
      currency: parsed.currency,
      priceType: parsed.priceType,
      unit: parsed.unit,
      quantity: parsed.quantity,
      sourceUrl,
      extractionMethod: method,
      rawEvidence: text,
      confidence: method === 'product_card' ? 0.93 : 0.88,
    }));
  });
  return out;
}

function extractPriceEvidence({html, sourceUrl}) {
  if (!String(html || '').trim()) return [];
  const $ = cheerio.load(html);
  $('nav, header, footer, [role="navigation"], .mega-menu, .mega-menu-wrap, #mega-menu-wrap').remove();
  const contextDoc = $.root().clone();
  contextDoc.find('script, style').remove();
  const pageContext = classifyExplorePricePageContext({sourceUrl,
    pageText: contextDoc.text(), title: $('title').text()});
  if (pageContext === 'explicit_non_owned_prices' ||
      pageContext === 'non_clinic_booking_platform') return [];
  removeFormerPriceColumns($);
  $('article, .promo-card, .promotion').each((_, node) => {
    const text = visibleText($, $(node));
    if (text.length <= 1500 && looksLikeConditionalCompanionOffer(text)) $(node).remove();
  });
  const out = [];
  const seen = new Set();
  const add = (row) => {
    if (!row || !(row.priceMin > 0)) return;
    if (String(row.rawProcedureText || '').trim().length < 3) return;
    const key = `${row.rawProcedureText.toLowerCase()}|${row.priceMin}|${row.extractionMethod}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push(row);
    console.log(`[EXTRACT] method=${row.extractionMethod}`);
    console.log(`[EXTRACT] procedure="${row.rawProcedureText}"`);
    console.log(`[EXTRACT] rawPrice="${row.rawPriceText}"`);
    console.log(`[PARSE] ${row.priceMin} ${row.currency}`);
  };

  for (const row of extractJsonLd($, sourceUrl)) add(row);
  for (const row of extractTables($, sourceUrl)) add(row);
  for (const row of extractWooCommerce($, sourceUrl)) add(row);
  for (const row of extractShopify(html, sourceUrl)) add(row);
  for (const row of extractCardsAndLists($, sourceUrl)) add(row);
  if (!out.length) return out;
  if (!isMarketplaceOrDirectoryHost(sourceUrl)) return out;
  const provider = extractMarketplaceProviderName(html, {sourceUrl});
  const platform = marketplacePlatformLabel(sourceUrl);
  return out.map((row) => ({
    ...row,
    providerClinic: provider,
    sourcePlatform: platform,
    sourceType: classifyPriceSourceType(sourceUrl),
  }));
}

module.exports = {extractPriceEvidence};
