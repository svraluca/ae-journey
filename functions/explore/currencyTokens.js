'use strict';

/**
 * Lexical currency detection. Never use unbounded .includes('pen'|'try'|…).
 * Prefer a symbol or ISO code adjacent to the amount over unrelated prose.
 */

const ISO_UNAMBIGUOUS = 'USD|EUR|GBP|RON|PLN|AED|SAR|QAR|KWD|BHD|OMR|CHF|' +
    'CAD|AUD|NZD|JPY|CNY|HKD|KRW|INR|SGD|MYR|THB|IDR|BRL|MXN|CLP|CZK|HUF|' +
    'SEK|NOK|DKK|ZAR';
/** Collide with English words when matched case-insensitively. */
const ISO_UPPERCASE_ONLY = 'TRY|PEN|COP|ARS';

const ISO_UNAMBIGUOUS_RE = new RegExp(`\\b(?:${ISO_UNAMBIGUOUS})\\b`, 'i');
const ISO_UPPER_RE = new RegExp(`\\b(?:${ISO_UPPERCASE_ONLY})\\b`);

function windowAroundFirstAmount(raw) {
  const s = String(raw || '');
  const m = s.match(/(.{0,28})(\d[\d.,]*)(.{0,28})/);
  return m ? m[0] : '';
}

function currencyFromSymbols(raw) {
  const s = String(raw || '');
  if (/R\$/.test(s)) return 'BRL';
  if (/S\/\.?\s*\d|\d\s*S\/\.?|(?:^|[\s(])S\/\.?(?=\s|$)/.test(s)) return 'PEN';
  if (/Mex\$/i.test(s)) return 'MXN';
  if (/HK\$/i.test(s)) return 'HKD';
  if (/NZ\$/i.test(s)) return 'NZD';
  if (/(?:^|[\s(])(?:AU\$|A\$)/i.test(s)) return 'AUD';
  if (/(?:^|[\s(])(?:C\$|Can\$)/i.test(s)) return 'CAD';
  if (/(?:^|[\s(])S\$/.test(s)) return 'SGD';
  if (/£/.test(s)) return 'GBP';
  if (/€/.test(s)) return 'EUR';
  if (/₩|원/.test(s)) return 'KRW';
  if (/₹/.test(s)) return 'INR';
  if (/฿/.test(s)) return 'THB';
  if (/د\.إ|درهم/.test(s)) return 'AED';
  if (/ر\.س/.test(s)) return 'SAR';
  if (/ر\.ق/.test(s)) return 'QAR';
  if (/د\.ك/.test(s)) return 'KWD';
  if (/د\.ب/.test(s)) return 'BHD';
  if (/ر\.ع/.test(s)) return 'OMR';
  if (/₺/.test(s)) return 'TRY';
  if (/zł/i.test(s)) return 'PLN';
  if (/Kč/i.test(s)) return 'CZK';
  if (/¥|円/.test(s)) {
    if (/\b(?:CNY|RMB|yuan)\b/i.test(s) || /元/.test(s)) return 'CNY';
    return 'JPY';
  }
  if (/\$/.test(s)) return 'USD';
  return '';
}

function currencyFromIso(raw) {
  const s = String(raw || '');
  const upper = s.match(ISO_UPPER_RE);
  if (upper) return upper[0].toUpperCase();
  const safe = s.match(ISO_UNAMBIGUOUS_RE);
  if (safe) return safe[0].toUpperCase();
  return '';
}

function currencyFromLocalAbbrev(raw) {
  const s = String(raw || '');
  if (/\b(?:lei|leul)\b/i.test(s)) return 'RON';
  if (/\beuros?\b/i.test(s)) return 'EUR';
  if (/\bdirhams?\b/i.test(s)) return 'AED';
  if (/\bTL\b/.test(s)) return 'TRY';
  if (/\b(?:zl)\b/i.test(s)) return 'PLN';
  if (/\bRM\b/.test(s)) return 'MYR';
  if (/\bRp\.?\b/.test(s)) return 'IDR';
  if (/\bRs\.?\b/.test(s)) return 'INR';
  if (/\bFt\b/.test(s)) return 'HUF';
  if (/\bfr\.\b/i.test(s)) return 'CHF';
  if (/\bR\s+\d/.test(s) || /\bZAR\b/.test(s)) return 'ZAR';
  if (/\bkr\b/i.test(s)) {
    if (/\bNOK\b/.test(s) || /norway|norge/i.test(s)) return 'NOK';
    if (/\bDKK\b/.test(s) || /denmark|dansk/i.test(s)) return 'DKK';
    return 'SEK';
  }
  if (/\b元\b/.test(s) || /\bRMB\b/i.test(s)) return 'CNY';
  return '';
}

function detectCurrencyIn(raw) {
  return currencyFromSymbols(raw) ||
      currencyFromIso(raw) ||
      currencyFromLocalAbbrev(raw);
}

function detectCurrencyToken(raw) {
  const text = String(raw || '').replace(/\u00a0/g, ' ');
  if (!text.trim()) return '';
  const near = windowAroundFirstAmount(text);
  if (near) {
    const fromNear = detectCurrencyIn(near);
    if (fromNear) return fromNear;
  }
  return detectCurrencyIn(text);
}

function hasCurrencySignal(raw) {
  return !!detectCurrencyToken(raw);
}

function stripCurrencyTokensForNumberParse(raw) {
  return String(raw || '')
      .replace(/R\$|S\/\.?|Mex\$|HK\$|NZ\$|AU\$|A\$|C\$|Can\$|S\$/gi, ' ')
      .replace(/[€£$¥₩₹฿₺]/g, ' ')
      .replace(new RegExp(`\\b(?:${ISO_UNAMBIGUOUS})\\b`, 'gi'), ' ')
      .replace(new RegExp(`\\b(?:${ISO_UPPERCASE_ONLY})\\b`, 'g'), ' ')
      .replace(/\b(?:lei|leul|euros?|dirhams?|TL|zl|zł|RM|Rp\.?|Rs\.?|Ft|fr\.|kr)\b/gi, ' ')
      .replace(/د\.إ|درهم|ر\.س|ر\.ق|د\.ك|د\.ب|ر\.ع|元|円|원/g, ' ');
}

module.exports = {
  detectCurrencyToken,
  hasCurrencySignal,
  stripCurrencyTokensForNumberParse,
  windowAroundFirstAmount,
};
