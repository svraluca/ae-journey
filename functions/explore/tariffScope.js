'use strict';

function fold(raw) {
  return String(raw || '').normalize('NFKD').toLowerCase()
      .replace(/[\u0300-\u036f]/g, '').replace(/ı/g, 'i');
}

function comparisonPriceContext(raw) {
  return /\b(?:ulkeler\w*\s+gore|sehirler\w*\s+gore|(?:prices?|costs?)\s+(?:by|across)\s+(?:countr\w*|cities)|(?:precios?|costes?)\s+por\s+(?:paises|ciudades)|prix\s+par\s+(?:pays|ville)|preise\s+nach\s+(?:land|stadt)|prezzi\s+per\s+(?:paese|citta)|average\s+\w*(?:\s+\w*){0,3}\s+price|typical\s+price\s+range|worked\s+cost\s+example|global\s+market)\b/.test(fold(raw));
}

function ancillaryPriceReason(procedure, prefix) {
  const t = fold(prefix);
  if (/\b(?:international\s+flights?|flights?|airfare|travel\s+insurance|extra\s+hotel\s+nights?|companion\s+accommodation|personal\s+meals|vuelos?|seguro\s+de\s+viaje|ucak\s+bilet\w*|seyahat\s+sigorta\w*|vols?|assurance\s+voyage|flug\w*|reiseversicherung|voli|assicurazione\s+viaggio)\b[^|\n€$£₺]{0,60}$/.test(t)) {
    return 'travel_cost_not_procedure';
  }
  if (/hair|transplant|sac\s+ekim|capilar|greffe/i.test(procedure) &&
      /\b(?:prp|platelet[- ]rich\s+plasma|mesotherap\w*|mezoterapi\w*|minoxidil|finasteride)\b[^|\n€$£₺]{0,65}$/.test(t)) {
    return 'hair_adjunct_not_transplant';
  }
  return null;
}

function calendarPriceReason(amount, prefix, tail) {
  return amount >= 1990 && amount <= 2100 && Number.isInteger(amount) &&
    /\b(?:kac|ne\s+kadar|how\s+much|cuanto(?:\s+cuesta)?|combien|wie\s+viel|quanto)\b[^|:\n]{0,45}$/.test(fold(prefix)) &&
    /^\s*\?/.test(tail) ? 'calendar_year_not_price' : null;
}

function number(raw) {
  let t = String(raw).replace(/[\s\u00a0\u202f]/g, '');
  if (/^\d{1,3}(?:[.,]\d{3})+$/.test(t)) return Number(t.replace(/[.,]/g, ''));
  if (t.includes(',') && t.includes('.')) {
    const decimal = t.lastIndexOf(',') > t.lastIndexOf('.') ? ',' : '.';
    t = t.replace(decimal === ',' ? /\./g : /,/g, '');
  }
  return Number(t.replace(',', '.'));
}

function quoteScopeReason({procedure, rawEvidence, priceMin, currency}) {
  if (comparisonPriceContext(rawEvidence)) return 'market_comparison_table';
  const codes = {EUR: 'EUR\\b|euros?\\b|€', USD: 'USD\\b|\\$', GBP: 'GBP\\b|£',
    TRY: 'TRY\\b|TL\\b|₺', RON: 'RON\\b|lei\\b'};
  const cur = codes[String(currency).toUpperCase()] || `${String(currency).replace(/[^A-Z]/gi, '')}\\b`;
  const num = '(?:\\d{1,3}(?:[., \\u00a0\\u202f]\\d{3})+(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?)';
  const regex = new RegExp(`(?<![\\d.,])(?:(?:${cur})\\s*(${num})|(${num})\\s*(?:${cur}))(?!\\d|[.,]\\d)`, 'gi');
  for (const match of String(rawEvidence || '').matchAll(regex)) {
    const amount = number(match[1] || match[2]);
    if (Math.abs(amount - Number(priceMin)) > .011) continue;
    const prefix = rawEvidence.slice(Math.max(0, match.index - 150), match.index);
    const tail = rawEvidence.slice(match.index + match[0].length);
    const reason = ancillaryPriceReason(procedure, prefix) || calendarPriceReason(amount, prefix, tail);
    if (reason) return reason;
  }
  return null;
}

module.exports = {comparisonPriceContext, ancillaryPriceReason, quoteScopeReason};
