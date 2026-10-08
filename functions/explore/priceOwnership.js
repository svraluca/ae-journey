'use strict';

/**
 * Page-level price ownership — mirrors lib/services/explore_price_ownership.dart.
 * Fragment extractors must not bypass a country/market page classification.
 */

function classifyExplorePricePageContext({sourceUrl = '', pageText = '', title = ''} = {}) {
  const url = String(sourceUrl || '').trim().toLowerCase();
  const blob = `${title}\n${pageText}`.replace(/\u00a0/g, ' ').toLowerCase();

  if (/\/cost-of-[a-z0-9-]+-in-[a-z0-9-]+|\/prices?-in-[a-z0-9-]+|\/cost-guide|\/price-guide|\/cost-savings|\/cost-saving|cost-of-breast|\/breast-augmentation-cost|\/how-much-does-|\/average-cost|albania-vs-|vs-italy|vs-uk|vs-europe|getclearbeauty\.|trueclinic\.|mymeditravel\./i.test(url)) {
    return 'country_cost_guide';
  }
  if (/\bcompared with\b|\bcompare(?:d)?\s+(?:to|with)\b|\bpatients? can save\b|\bin albania (?:offers|starts|range)\b|\bacross (?:clinics|the country|albania|turkey)\b/i.test(blob)) {
    if (/\bitaly|france|uk|germany|europe|abroad\b/i.test(blob)) {
      return 'foreign_price_comparison';
    }
    return 'comparison_article';
  }
  if (/\baverage price\b|\bon average\b|\btypically (?:cost|range|start)\b|\bstarts? at roughly\b|\baround \d/i.test(blob)) {
    return 'market_average';
  }
  if (/\/blog\/|\/news\/|\/article\/|\/insights\//i.test(url) || /\bblog\b|\bin this article\b/i.test(blob)) {
    return 'blog';
  }
  if (/\/price-list|\/pricelist|\/precios|\/preturi|\/prezzi|\/tarifs|\/cmimet|\/çmimet|\/fiyat|\/cennik|\/pricing\b/i.test(url)) {
    return 'official_price_list';
  }
  if (/\bprice list\b|\bour prices?\b|\bcmimet\b|\bçmimet\b/i.test(blob)) {
    return 'official_price_list';
  }
  if (/\bour package\b|\bpackage (?:includes|starts|price)\b|\bincludes 1 pair of implants\b/i.test(blob)) {
    return 'official_package_price';
  }
  if (/\bour (?:breast|botox|filler|rhinoplast|peel).{0,40}\bprice\b|\bstarting (?:at|from)\b/i.test(`${title}\n${pageText}`)) {
    return 'official_service_price';
  }
  if (/\bin (?:albania|turkey|dubai|london|italy)\b.{0,48}\b(?:offers|starts)|\bwith only\b.{0,48}\b(?:breast|botox|filler|euros?|€)/i.test(blob)) {
    return 'country_cost_guide';
  }
  return 'unknown';
}

function looksLikeExplicitClinicOwnPriceLanguage(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  return /\bour (?:breast|botox|filler|rhinoplast|peel|package|price|prices)\b|\bour package starts\b|\bprice list\s*:|\bat\s+[A-Z][\w.\s-]{1,40}\s+(?:clinic|hospital|centre|center)\b|\bstarts? from\b|\bstarting (?:at|from)\b/i.test(t);
}

function looksLikeCountryMarketPriceMarketing(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t) return false;
  return /\bstarts? at roughly\b|\bwith only\b.{0,48}\b(?:breast|botox|filler|euros?|€)\b|\bbreast augmentation in \w+ offers\b|\bin albania (?:offers|starts|range|prices)\b|\bprices? in albania\b|\bcompared with italy\b|\bpatients? can save\b|\bcost of breast augmentation in\b|\ba breast augmentation starts at roughly\b/i.test(t);
}

function pageContextBlocksFragmentBypass(ctx) {
  return [
    'country_cost_guide',
    'market_average',
    'comparison_article',
    'foreign_price_comparison',
    'informational_article',
    'blog',
  ].includes(String(ctx || ''));
}

function pageContextIsAutomaticallyOwned(ctx) {
  return [
    'official_price_list',
    'official_service_price',
    'official_package_price',
  ].includes(String(ctx || ''));
}

function exploreEvidenceIsClinicOwnedPrice({
  pageContext = 'unknown',
  rawEvidence = '',
  rawProcedureText = '',
  rawPriceText = '',
} = {}) {
  const blob = `${rawProcedureText}\n${rawEvidence}\n${rawPriceText}`;
  if (looksLikeCountryMarketPriceMarketing(blob) &&
      !looksLikeExplicitClinicOwnPriceLanguage(blob)) {
    return false;
  }
  if (pageContextBlocksFragmentBypass(pageContext)) {
    return looksLikeExplicitClinicOwnPriceLanguage(blob);
  }
  if (pageContextIsAutomaticallyOwned(pageContext)) return true;
  return true;
}

function exploreNormalizeProcedureDisplayName({
  procedureCanonical = '',
  procedureFamily = '',
  rawProcedureText = '',
} = {}) {
  const canonical = String(procedureCanonical || '').trim().toLowerCase().replace(/\s+/g, '_');
  switch (canonical) {
    case 'chemical_peel':
    case 'peel':
      return 'Chemical Peel';
    case 'lip_filler':
    case 'filler':
    case 'dermal_filler':
      return 'Lip filler';
    case 'botox':
      return 'Botox';
    case 'rhinoplasty':
      return 'Rhinoplasty';
    case 'breast_augmentation':
    case 'breast':
      return 'Breast Augmentation';
    case 'hair_transplant':
    case 'hair':
      return 'Hair transplant';
    default:
      break;
  }
  const fam = String(procedureFamily || '').trim().toLowerCase();
  if (fam === 'breast' || fam === 'breast_augmentation') return 'Breast Augmentation';
  if (fam === 'botox') return 'Botox';
  if (looksLikeCountryMarketPriceMarketing(rawProcedureText)) {
    return 'Treatment';
  }
  const cleaned = String(rawProcedureText || '').replace(/\u00a0/g, ' ').trim();
  if (cleaned && cleaned.length <= 48 &&
      !/\b(includes|starts at|with only|roughly|offers:)\b/i.test(cleaned)) {
    return cleaned;
  }
  return 'Treatment';
}

function exploreNormalizeProcedureDetail(rawProcedureText) {
  const t = String(rawProcedureText || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return '';
  const mentor = /\bmentor\b/i.test(t);
  const includes = /\bincludes?\b.{0,40}\bimplants?\b/i.test(t);
  if (mentor && includes) return 'Mentor implants included';
  if (mentor) return 'Mentor implants';
  if (includes) return 'Implants included';
  return '';
}

module.exports = {
  classifyExplorePricePageContext,
  looksLikeExplicitClinicOwnPriceLanguage,
  looksLikeCountryMarketPriceMarketing,
  exploreEvidenceIsClinicOwnedPrice,
  exploreNormalizeProcedureDisplayName,
  exploreNormalizeProcedureDetail,
  pageContextBlocksFragmentBypass,
  pageContextIsAutomaticallyOwned,
};
