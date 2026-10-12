'use strict';

// A publication date is provenance, not an expiry date. Preserve it on fetch.
const DAY_MS = 24 * 60 * 60 * 1000;

function sourcePriceDateFields(row = {}) {
  return {
    source_price_updated_at: String(row.source_price_updated_at ?? row.sourcePriceUpdatedAt ?? '').trim(),
    source_price_date_text: String(row.source_price_date_text ?? row.sourcePriceDateText ?? '').trim(),
    source_price_date_basis: String(row.source_price_date_basis ?? row.sourcePriceDateBasis ?? '').trim(),
  };
}

function sourceCurrencyFields(row = {}) {
  return {source_currency_basis: String(row.source_currency_basis ?? row.sourceCurrencyBasis ?? '').trim()};
}

function explicitIsoDate(value) {
  // Date.parse otherwise normalizes invalid dates such as February 30.
  const raw = String(value || '').trim();
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?$/.exec(raw);
  if (!m) return NaN;
  const [year, month, day] = m.slice(1, 4).map(Number);
  const calendar = new Date(0);
  calendar.setUTCFullYear(year, month - 1, day);
  if (year < 1 || calendar.getUTCFullYear() !== year ||
      calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day) return NaN;
  if (m[4] !== undefined && (Number(m[4]) > 23 || Number(m[5]) > 59 || Number(m[6] || 0) > 59)) return NaN;
  if (m[8] && m[8] !== 'Z' &&
      (Number(m[8].slice(1, 3)) > 23 || Number(m[8].slice(4)) > 59)) return NaN;
  const timestamp = m[4] === undefined ? raw : raw.replace(' ', 'T') + (m[8] ? '' : 'Z');
  return Date.parse(timestamp);
}

function marketplacePriceDateFailure(updatedAt, dateBasis = '', {now = Date.now()} = {}) {
  if (dateBasis === 'ambiguous_menu_date') return 'marketplace_price_date_ambiguous';
  if (!updatedAt) return '';
  const date = explicitIsoDate(updatedAt);
  if (!Number.isFinite(date)) return 'marketplace_price_date_invalid';
  const clock = Number(now);
  if (date > clock + DAY_MS) return 'marketplace_price_date_future';
  return '';
}

function marketplaceRowPriceDateFailure(row, options = {}) {
  // Deferred import keeps the field-copy helper available to identity merging.
  const {isMarketplaceOrDirectoryHost} = require('./identity');
  const sourceType = String(row.source_type || row.sourceType || '').toLowerCase();
  const sourceUrl = row.price_source_url || row.priceSourceUrl || row.source_url || row.sourceUrl || '';
  if (sourceType !== 'marketplace' && !isMarketplaceOrDirectoryHost(sourceUrl)) return '';
  const fields = sourcePriceDateFields(row);
  return marketplacePriceDateFailure(fields.source_price_updated_at, fields.source_price_date_basis, options);
}

function marketplaceRowCurrencyFailure(row) {
  const {isMarketplaceOrDirectoryHost} = require('./identity');
  const sourceType = String(row.source_type || row.sourceType || '').toLowerCase();
  const sourceUrl = row.price_source_url || row.priceSourceUrl || row.source_url || row.sourceUrl || '';
  if (sourceType !== 'marketplace' && !isMarketplaceOrDirectoryHost(sourceUrl)) return '';
  if (sourceCurrencyFields(row).source_currency_basis === 'platform_converted') {
    let host = '';
    try { host = new URL(sourceUrl).hostname.toLowerCase(); } catch (_) { /* Reject below. */ }
    return (host === 'whatclinic.com' || host === 'www.whatclinic.com') && row.currency === 'EUR'
      ? '' : 'marketplace_conversion_currency_unstable';
  }
  return sourceCurrencyFields(row).source_currency_basis === 'viewer_localized'
    ? 'marketplace_original_currency_unverified' : '';
}

function closingDelimiter(value, start, opener, closer) {
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let i = start; i < value.length; i++) {
    const char = value[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
      continue;
    }
    if ('"\'`'.includes(char)) quote = char;
    else if (char === opener) depth++;
    else if (char === closer && --depth === 0) return i;
  }
  return -1;
}

function literalArguments(value) {
  const parts = [];
  let start = 0;
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === quote) quote = '';
    } else if ('"\'`'.includes(char)) quote = char;
    else if ('([{'.includes(char)) depth++;
    else if (')]}'.includes(char)) depth--;
    else if (char === ',' && !depth) {
      parts.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(value.slice(start).trim());
  return parts;
}

function nuxtLiterals(script) {
  const header = /window\.__NUXT__\s*=\s*\(function\(([^)]*)\)\s*\{/.exec(script);
  if (!header) return {};
  const bodyEnd = closingDelimiter(script, header.index + header[0].length - 1, '{', '}');
  const call = /^\s*\(/.exec(script.slice(bodyEnd + 1));
  if (bodyEnd < 0 || !call) return {};
  const start = bodyEnd + call[0].length;
  const finish = closingDelimiter(script, start, '(', ')');
  if (finish < 0) return {};
  const params = header[1].split(',');
  const args = literalArguments(script.slice(start + 1, finish));
  if (params.length !== args.length) return {};
  const out = {};
  params.forEach((param, i) => {
    try { out[param.trim()] = JSON.parse(args[i]); } catch (_) { /* Never execute expressions. */ }
  });
  return out;
}

function literalFields(value, literals) {
  const out = {};
  for (const match of value.matchAll(/(?:^|,)\s*([A-Za-z_$][\w$]*)\s*:\s*("(?:\\.|[^"\\])*"|[^,{}]+)/g)) {
    const raw = match[2].trim();
    if (Object.hasOwn(literals, raw)) out[match[1]] = literals[raw];
    else {
      try { out[match[1]] = JSON.parse(raw); } catch (_) { /* References are not literal dates. */ }
    }
  }
  return out;
}

function fold(value) {
  return String(value || '').normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim();
}

function bookimedPriceDateReader(html) {
  const $ = require('cheerio').load(html || '');
  let menu = $('#prices').first();
  if (!menu.length) menu = $('.clinic-prices__table').first().parent();
  if (!menu.length) return () => sourcePriceDateFields();
  const labels = menu.find('tr').toArray().map((row) => fold($(row).text()));
  const records = [];
  $('script').each((_, node) => {
    const script = $(node).html() || '';
    if (!script.includes('window.__NUXT__')) return;
    const literals = nuxtLiterals(script);
    const clinic = /content\s*:\s*\{clinic\s*:\s*\{id\s*:\s*([^,}]+)/.exec(script);
    if (!clinic) return;
    const clinicId = literalFields('id:' + clinic[1], literals).id;
    if (clinicId == null) return;
    for (const record of script.matchAll(/\{operation:\{([^{}]*(?:name_forms:\{[^{}]*\}[^{}]*)?)\},prices:\{([^{}]*)\}\}/g)) {
      const operation = literalFields(record[1], literals);
      const price = literalFields(record[2], literals);
      if (price.clinic_id === clinicId && price.entity_id === operation.id && price.entity === 'operations') {
        records.push({operation, price});
      }
    }
  });
  const explicit = /Last\s+price\s+update\s*[-—:]?\s*(\d{1,4}[./-]\d{1,2}[./-]\d{1,4})/i.exec(menu.text());
  return (row) => {
    const label = fold(String(row.rawProcedureText || '').split('·').pop());
    if (!label || !labels.some((text) => text.includes(label))) return sourcePriceDateFields();
    const dates = new Set();
    for (const {operation, price} of records) {
      if (fold(operation.name) !== label || price.currency !== row.currency) continue;
      const lower = Number(price.price_from);
      const upper = Number(price.price_to);
      const expectedUpper = row.priceMax == null ? row.priceMin : row.priceMax;
      if (!Number.isFinite(lower) || !Number.isFinite(upper) ||
          Math.abs(lower - row.priceMin) > .011 || Math.abs(upper - expectedUpper) > .011) continue;
      if (typeof price.updated_at === 'string' && Number.isFinite(explicitIsoDate(price.updated_at))) dates.add(price.updated_at);
    }
    if (dates.size === 1) {
      const date = [...dates][0];
      return {source_price_updated_at: date, source_price_date_text: 'updated_at=' + date,
        source_price_date_basis: 'provider_procedure_price_record'};
    }
    if (dates.size > 1) return {source_price_updated_at: '',
      source_price_date_text: 'Conflicting updated_at values for the selected fee', source_price_date_basis: 'ambiguous_menu_date'};
    if (!explicit) return sourcePriceDateFields();
    const dotted = /^(\d{2})\.(\d{2})\.(\d{4})$/.exec(explicit[1]);
    const iso = dotted ? `${dotted[3]}-${dotted[2]}-${dotted[1]}` : explicit[1];
    if (!/^(?:\d{4}-\d{2}-\d{2})$/.test(iso) || !Number.isFinite(explicitIsoDate(iso))) {
      return {source_price_updated_at: '', source_price_date_text: explicit[0], source_price_date_basis: 'ambiguous_menu_date'};
    }
    return {source_price_updated_at: iso, source_price_date_text: explicit[0], source_price_date_basis: 'provider_tariff_menu'};
  };
}

module.exports = {
  sourcePriceDateFields,
  sourceCurrencyFields,
  explicitIsoDate,
  marketplacePriceDateFailure,
  marketplaceRowPriceDateFailure,
  marketplaceRowCurrencyFailure,
  bookimedPriceDateReader,
};
