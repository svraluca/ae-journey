'use strict';

// Pure scope checks shared by extraction, stored-card validation and selection.
function fold(raw) {
  return String(raw || '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
      .toLowerCase().replace(/[_-]+/g, ' ');
}

function looksLikeSurgicalChinTreatment(raw) {
  const text = fold(raw);
  if (/\bgenioplast\w*\b|\bchin\s+(?:implants?|reduction|osteotomy|surgery)\b|\b(?:implante|protesis)\s+(?:de\s+)?menton\b|\bmenton\b.{0,35}\b(?:implante|protesis|osteotomia)\b/.test(text)) {
    return true;
  }
  if (!/\bmentoplast\w*\b/.test(text)) return false;
  // Some clinics call HA injections "non-surgical mentoplasty". Explicit
  // injectable scope is valid unless an implant/osteotomy is also quoted.
  return !/\bnon\s+surgical\s+mentoplast\w*\b|\bmentoplast\w*\b.{0,45}\b(?:no\s+quirurgic\w*|sin\s+cirugia|con\s+acido\s+hialuronic\w*|with\s+hyaluronic\s+acid)\b/.test(text);
}

function looksLikeCombinedToxinSkinTreatment(raw) {
  const toxin = /\b(?:botox|botulin\w*|toxina\w*|neuromodul\w*|dysport|xeomin)\b/;
  const skin = /\b(?:skin\s*booster\w*|profhilo|rejuran|jalupro|nucleofill)\b/;
  // A currency quote or row separator bounds the treatment name. Distinct
  // prices in neighboring services must not turn a standalone row into a pack.
  return fold(raw).split(/[\n|€$£]|\b(?:eur|usd|gbp|ron|aed)\b/).some((part) =>
    toxin.test(part) && skin.test(part) &&
      /\+|&|\/|\b(?:and|y|with|con|plus|combo|bundle|pack(?:age)?)\b/.test(part));
}

function isApproximatePriceQuote(raw, amount) {
  if (!(Number(amount) > 0)) return false;
  const text = fold(raw);
  const forms = [...new Set([String(amount), Number(amount).toLocaleString('en-US'),
    Number(amount).toLocaleString('de-DE')])];
  const escaped = forms.map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const prices = new RegExp(`(?<![\\d.,])(?:${escaped.join('|')})(?![\\d.,])`, 'g');
  const cue = '(?:roughly|approximately|approx\\.?|about|around|aproximad(?:amente|[oa]s?)|alrededor\\s+de|suele(?:n)?\\s+rondar|en\\s+torno\\s+a|circa)';
  const before = new RegExp(`\\b${cue}[^\\d\\n|€$£]{0,32}(?:[€$£])?\\s*$`);
  const after = new RegExp(`^\\s*(?:€|[$£]|eur|usd|gbp|aed|ron)?\\s*${cue}\\b`);
  return [...text.matchAll(prices)].some((match) => {
    const suffix = text.slice(match.index + match[0].length, match.index + match[0].length + 65);
    if (/^\s*(?:minutes?|mins?|hours?|days?|ml|mg|units?|vials?|areas?)\b/.test(suffix)) return false;
    return before.test(text.slice(Math.max(0, match.index - 65), match.index)) || after.test(suffix);
  });
}

function looksLikeCreditLimitQuote({rawPriceText = '', rawEvidence = '', priceMin}) {
  if (!(Number(priceMin) > 0)) return false;
  const forms = [...new Set([String(priceMin), Number(priceMin).toLocaleString('en-US'),
    Number(priceMin).toLocaleString('de-DE')])]
      .map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const cap = new RegExp(`\\b(?:hasta|up\\s+to|credit\\s+limit(?:\\s+of)?|maximum(?:\\s+of)?)\\s*(?:€|[$£]|eur|usd|gbp)?\\s*(?:${forms.join('|')})(?![\\d.,])`, 'g');
  const text = fold(`${rawEvidence}\n${rawPriceText}`);
  return [...text.matchAll(cap)].some((match) =>
    /\bfinanc\w*|\bcredit\w*|\bcuotas?\b|\bprestam\w*|\bloans?\b/.test(
        text.slice(Math.max(0, match.index - 220), match.index + match[0].length + 220)));
}

function looksLikeSpanishMarketPriceQuote(raw) {
  const text = fold(raw);
  if (/\bprecio(?:s)?\s+(?:medio|promedio)\b|\bmedia\s+(?:de\s+)?(?:los\s+)?precios\b/.test(text)) return true;
  const own = /\b(?:nuestra\s+clinica|nuestro\s+centro|con\s+mi\s+tecnica|en\s+mi\s+consulta)\b/.test(text);
  return !own && /\bprecio\b.{0,100}\ben\s+espana\b.{0,70}\b(?:oscila|varia|entre|ronda)\b/.test(text);
}

function looksLikeLipHydrationWhenAugmentationRequested({procedure = '', label = '', evidence = ''}) {
  const want = fold(procedure);
  if (!/\blip\s+(?:fillers?|augmentation|enhancement)\b|\b(?:aumento|relleno)\s+(?:de\s+)?labios\b/.test(want)) return false;
  const text = fold(label || evidence);
  return /\bhidrata\w*|\bhydrat\w*/.test(text) && /\blips?\b|\blabios\b/.test(text) &&
    !/\b(?:aumento|augmentation|enhancement|volum\w*)\b/.test(text);
}

function looksLikeNonToxinSkinTreatment(raw) {
  const text = fold(raw);
  return /\bnctf\b|\bfilorga\b|\bmesoterap\w*|\bmesotherap\w*/.test(text) &&
    !/\b(?:botox|botulin\w*|neuromodul\w*)\b/.test(text);
}

module.exports = {looksLikeSurgicalChinTreatment, looksLikeCombinedToxinSkinTreatment,
  isApproximatePriceQuote, looksLikeCreditLimitQuote, looksLikeSpanishMarketPriceQuote,
  looksLikeLipHydrationWhenAugmentationRequested, looksLikeNonToxinSkinTreatment};
