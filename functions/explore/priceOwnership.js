'use strict';
const {comparisonPriceContext} = require('./tariffScope');

/**
 * Page-level price ownership — mirrors lib/services/explore_price_ownership.dart.
 * Fragment extractors must not bypass a country/market page classification.
 */

function withoutDoseAverages(raw) {
  return String(raw || '').replace(
      /\bon average\s*,?\s*\d+(?:\s*[-–—]\s*\d+)?\s+(?:units?|grafts?)\b([^.!?\n]{0,120}\b(?:are|is)\s+(?:used|required|needed)\b[^.!?\n]*(?:[.!?]|$))/gi,
      (sentence, remainder) => /[€£$]|\b(?:costs?|prices?|fees?|aed|eur|usd|gbp|ron|lei)\b/i.test(sentence) || /\d/.test(remainder) ? sentence : '',
  );
}

function ownershipFold(raw) {
  return String(raw || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
      .replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').toLowerCase();
}

function looksLikeExplicitNonOwnedPriceDisclaimer(raw) {
  const t = ownershipFold(raw).replace(/ı/g, 'i');
  if (/\b(?:these|listed)\s+(?:prices|fees|figures)\s+are\s+(?:only\s+)?(?:averages|estimates)\b|\b(?:fiyatlar|ucretler|degerler|rakamlar)\s+(?:sadece\s+)?ortalamadir\b|\b(?:bu|yukaridaki)\s+(?:fiyatlar|ucretler|degerler|rakamlar)\s+ortalama\s+olup\b|\b(?:estos|los)\s+(?:precios|importes)\s+son\s+(?:solo\s+)?(?:promedios|estimaciones)\b/.test(t)) return true;
  return /\bno\s+representan\s+los\s+precios\s+aplicados\s+en\s+(?:la\s+)?(?:consulta|clinica)\b|\bno\s+(?:son|representan)\s+(?:nuestros\s+precios|las\s+tarifas\s+de\s+nuestra\s+clinica)\b|\b(?:do\s+not|don't)\s+represent\s+(?:the\s+)?(?:prices|fees)\s+(?:charged|applied)\s+(?:at|in)\s+(?:our|the)\s+(?:clinic|practice)\b/.test(t);
}

function looksLikeNonClinicBookingPlatform(raw) {
  const t = ownershipFold(raw);
  return /\bno\s+es\s+un\s+(?:consultorio\s+medico|centro\s+medico|centro\s+sanitario)\b|\b(?:is\s+not|isn't)\s+a\s+(?:medical\s+clinic|medical\s+practice)\b/.test(t);
}

function looksLikeConditionalCompanionOffer(raw) {
  const t = ownershipFold(raw);
  return /\bpack\s+(?:amigas|amigos|parejas)\b|\bven\s+con\s+(?:una?\s+)?amig[ao]\b|\b(?:bring|with)\s+(?:a|your)\s+friend\b.{0,90}\b(?:price|offer|discount|special)\b|\b(?:friends?|couples?)\s+(?:pack|offer|discount)\b/.test(t);
}

function looksLikeLocalizedMarketPriceEstimate(raw) {
  const t = ownershipFold(raw).replace(/ı/g, 'i');
  return /\b(?:fiyat\w*|ucret\w*|maliyet\w*)\b(?:[^.!?\n|]|\.(?=\d)){0,100}\b(?:genellikle|ortalama|degis\w*|arasinda)\b|\b(?:genellikle|ortalama|genel olarak)\b(?:[^.!?\n|]|\.(?=\d)){0,100}\b(?:fiyat\w*|ucret\w*|maliyet\w*|tl|try)\b|\bne kadar ortalama\b/.test(t);
}

function classifyExplorePricePageContext({sourceUrl = '', pageText = '', title = ''} = {}) {
  const url = String(sourceUrl || '').trim().toLowerCase();
  const blob = withoutDoseAverages(`${title}\n${pageText}`).replace(/\u00a0/g, ' ').toLowerCase();

  if (looksLikeExplicitNonOwnedPriceDisclaimer(blob)) return 'explicit_non_owned_prices';
  if (looksLikeNonClinicBookingPlatform(blob)) return 'non_clinic_booking_platform';

  if (/\/cost-of-[a-z0-9-]+-in-[a-z0-9-]+|\/prices?-in-[a-z0-9-]+|\/cost-guide|\/price-guide\/[^/?#]|\/cost-savings|\/cost-saving|cost-of-breast|\/breast-augmentation-cost|\/how-much-does-|\/average-cost|albania-vs-|vs-italy|vs-uk|vs-europe|getclearbeauty\.|trueclinic\.|mymeditravel\./i.test(url)) {
    return 'country_cost_guide';
  }
  if (/\bcompared with\b|\bcompare(?:d)?\s+(?:to|with)\b|\bpatients? can save\b|\bin albania (?:offers|starts|range)\b|\bacross (?:clinics|the country|albania|turkey)\b/i.test(blob)) {
    if (/\bitaly|france|uk|germany|europe|abroad\b/i.test(blob)) {
      return 'foreign_price_comparison';
    }
    return 'comparison_article';
  }
  if (looksLikeLocalizedMarketPriceEstimate(blob) || /\baverage price\b|\bon average\b|\btypically (?:cost|range|start)\b|\bstarts? at roughly\b|\baround \d/i.test(blob)) {
    return 'market_average';
  }
  if (/\/blog\/|\/news\/|\/article\/|\/insights\//i.test(url) || /\bblog\b|\bin this article\b/i.test(blob)) {
    return 'blog';
  }
  if (/\/price-list|\/pricelist|\/prices?(?:\/|$|[?#])|\/price-guide(?:\/|$|[?#])|\/precios|\/preturi|\/prezzi|\/tarifs|\/cmimet|\/çmimet|\/fiyat|\/cennik|\/pricing\b/i.test(url)) {
    return 'official_price_list';
  }
  if (/\bprice list\b|\bour prices?\b|\bcmimet\b|\bçmimet\b/i.test(blob)) {
    return 'official_price_list';
  }
  if (/\bour package\b|\bpackage (?:includes|starts|price)\b|\bincludes 1 pair of implants\b/i.test(blob)) {
    return 'official_package_price';
  }
  if (/\bour (?:breast|botox|filler|rhinoplast|peel).{0,40}\bprice\b|\bstarting (?:at|from)\b|(?:^|\s)(?:عرضنا|أسعارنا)(?:\s|$)/i.test(`${title}\n${pageText}`)) {
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
  if (/\b(?:klinigimiz\w*|hastanemiz\w*|merkezimiz\w*)\b.{0,100}\b(?:fiyat\w*|ucret\w*|botoks|dolgu\w*)\b/.test(ownershipFold(t).replace(/ı/g, 'i'))) return true;
  return /\bour (?:breast|botox|filler|rhinoplast|peel|package|price|prices)\b|\bour package starts\b|\bprice list\s*:|\bat\s+[A-Z][\w.\s-]{1,40}\s+(?:clinic|hospital|centre|center)\b|\bstarts? from\b|\bstarting (?:at|from)\b|(?:^|\s)(?:عرضنا|أسعارنا)(?:\s|$)/i.test(t);
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
  sourceUrl = '',
  extractionMethod = '',
} = {}) {
  const blob = `${rawProcedureText}\n${rawEvidence}\n${rawPriceText}`;
  if (looksLikeLocalizedMarketPriceEstimate(rawEvidence) || comparisonPriceContext(rawEvidence)) return false;
  if (pageContext === 'explicit_non_owned_prices' ||
      pageContext === 'non_clinic_booking_platform' ||
      looksLikeExplicitNonOwnedPriceDisclaimer(blob) ||
      looksLikeNonClinicBookingPlatform(blob) ||
      looksLikeConditionalCompanionOffer(blob)) return false;
  // The extractor preserved an explicit branded menu section on a page
  // that also contains geographical comparisons. Never trust the method alone.
  if (extractionMethod === 'owned_currency_tariff_table') {
    let brand = '';
    try { brand = new URL(sourceUrl).hostname.replace(/^www\./, '').split('.')[0]; } catch (_) { /* no proof */ }
    const heading = String(rawEvidence).split('|')[0];
    const key = (s) => ownershipFold(s).replace(/[^a-z0-9]/g, '');
    if (brand.length >= 4 && key(heading).includes(key(brand)) &&
        /\b(?:prices?|fees?|costs?)\b/i.test(heading)) return true;
  }
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
  const listed = String(rawProcedureText || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  if (listed && listed.length <= 110 &&
      !/^(?:botox|chemical peel|lip filler|dermal filler|filler|rhinoplasty|breast augmentation|hair transplant)$/i.test(listed) &&
      !/\b(?:prices?|costs?|average|how|what|starting|from|roughly)\b|[€£$]/i.test(listed) &&
      !looksLikeCountryMarketPriceMarketing(listed)) {
    return listed;
  }
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
  looksLikeExplicitNonOwnedPriceDisclaimer,
  looksLikeNonClinicBookingPlatform,
  looksLikeConditionalCompanionOffer,
  classifyExplorePricePageContext,
  looksLikeExplicitClinicOwnPriceLanguage,
  looksLikeCountryMarketPriceMarketing,
  exploreEvidenceIsClinicOwnedPrice,
  exploreNormalizeProcedureDisplayName,
  exploreNormalizeProcedureDetail,
  pageContextBlocksFragmentBypass,
  pageContextIsAutomaticallyOwned,
};
