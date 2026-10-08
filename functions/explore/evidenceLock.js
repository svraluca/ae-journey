'use strict';

/**
 * Strict evidence lock before a price may be shown or saved.
 * Amount must literally exist in HTML/PDF text; procedure+price same block;
 * relation must be exact|variant.
 */

const {classifyProcedureRelation, logProcedureRelation} = require('./procedureRelation');
const {isValidExtractedPriceCandidate} = require('./priceSanity');

function amountLiterallyInSource(source, amount) {
  if (!source || !(amount > 0)) return false;
  const whole = Number.isInteger(amount) || amount === Math.round(amount)
    ? String(Math.round(amount))
    : String(amount);
  const compactSrc = String(source).replace(/[\s,\u00a0\u202f]/g, '');
  const compactAmt = whole.replace(/[\s,]/g, '');
  if (compactAmt.length >= 2 && compactSrc.includes(compactAmt)) return true;
  if (whole.length > 3) {
    const withCommas = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    if (String(source).includes(withCommas)) return true;
    const withDots = whole.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
    if (String(source).includes(withDots)) return true;
  }
  const re = new RegExp(`(?<![0-9])${whole.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![0-9])`);
  return re.test(String(source));
}

function priceAndProcedureShareBlock(row) {
  const block = String(row.rawEvidence || '').trim() ||
    `${row.rawProcedureText || ''}\n${row.rawPriceText || ''}`;
  if (!block.trim()) return false;
  if (!amountLiterallyInSource(block, row.priceMin)) return false;
  const label = String(row.rawProcedureText || '').trim();
  if (!label) return false;
  const foldedBlock = block.toLowerCase();
  const foldedLabel = label.toLowerCase();
  if (foldedBlock.includes(foldedLabel)) return true;
  const tokens = foldedLabel.split(/[^a-z0-9\u0600-\u06ff]+/i).filter((t) => t.length >= 4);
  if (!tokens.length) return true;
  return tokens.some((t) => foldedBlock.includes(t));
}

function logPriceSource(source, url = '') {
  console.log(`[PRICE SOURCE] ${source}${url ? ` · ${url}` : ''}`);
}

function logPriceLiteralFound(amount, currency, rawPriceText) {
  console.log(
    `[PRICE LITERAL FOUND] ${Math.round(amount)} ${currency || ''} · "${rawPriceText || ''}"`,
  );
}

function logPriceReject(reason, detail = '') {
  console.log(`[PRICE REJECT] ${reason}${detail ? ` · ${detail}` : ''}`);
}

function logPriceAccept({clinic, procedure, evidence, relation}) {
  console.log(
    `[PRICE ACCEPT] clinic="${clinic || ''}" procedure="${procedure || ''}" ` +
    `relation=${relation.logToken} raw="${evidence.rawPriceText || ''}" ` +
    `parsed=${Math.round(evidence.priceMin)} ${evidence.currency || ''} ` +
    `method=${evidence.extractionMethod || ''} url=${evidence.sourceUrl || ''}`,
  );
}

/**
 * @return {{accepted:boolean, rejectReason?:string, evidence?:object, relation?:object}}
 */
function lockPriceEvidence({
  candidate, procedure, sourceHtmlOrText, clinicOwnQuoted = false,
  pageHasFamilyWitness = false, parentHeading = '',
}) {
  const src = String(sourceHtmlOrText || '').trim() ||
    `${candidate.rawEvidence || ''}\n${candidate.rawPriceText || ''}`;

  if (!amountLiterallyInSource(src, candidate.priceMin) &&
      !amountLiterallyInSource(candidate.rawPriceText, candidate.priceMin) &&
      !amountLiterallyInSource(candidate.rawEvidence, candidate.priceMin)) {
    logPriceReject('amount_not_literal_in_source', `${Math.round(candidate.priceMin)} missing`);
    return {accepted: false, rejectReason: 'amount_not_literal_in_source'};
  }
  logPriceLiteralFound(candidate.priceMin, candidate.currency, candidate.rawPriceText);

  if (!priceAndProcedureShareBlock(candidate)) {
    logPriceReject('procedure_price_block_mismatch', candidate.rawProcedureText || '');
    return {accepted: false, rejectReason: 'procedure_price_block_mismatch'};
  }

  const relation = classifyProcedureRelation({
    requestedProcedure: procedure,
    label: candidate.rawProcedureText,
    evidence: `${candidate.rawPriceText || ''}\n${candidate.rawEvidence || ''}`,
    sourceUrl: candidate.sourceUrl || '',
    clinicOwnQuoted,
    pageHasFamilyWitness,
    parentHeading,
  });
  logProcedureRelation(relation, candidate.rawProcedureText || '');

  if (!relation.eligible) {
    logPriceReject(`relation_${relation.logToken}`, relation.reason);
    return {accepted: false, rejectReason: `relation_${relation.logToken}`, relation, evidence: candidate};
  }

  if (!isValidExtractedPriceCandidate({
    rawPriceText: candidate.rawPriceText,
    priceMin: candidate.priceMin,
    currency: candidate.currency,
    extractionMethod: candidate.extractionMethod,
    rawEvidence: candidate.rawEvidence,
    procedure,
    sourceUrl: candidate.sourceUrl,
    priceMax: candidate.priceMax,
  })) {
    logPriceReject('sanity_reject');
    return {accepted: false, rejectReason: 'sanity_reject', relation, evidence: candidate};
  }

  return {accepted: true, evidence: candidate, relation};
}

module.exports = {
  amountLiterallyInSource,
  lockPriceEvidence,
  logPriceSource,
  logPriceLiteralFound,
  logPriceReject,
  logPriceAccept,
};
