'use strict';

const {looksLikeCityMarketPricingGuideUrl,
  looksLikeTreatmentFinanceUrl,
  looksLikePriceMenuHeadingOnly,
  looksLikeEnergyOrDeviceTreatment,
  looksLikePartialRhinoplastyStarting} = require('./priceSanity');
const {looksLikeMarketEstimateDirectoryUrl} = require('./identity');
const {looksLikeSurgicalChinTreatment, looksLikeSpanishMarketPriceQuote,
  looksLikeLipHydrationWhenAugmentationRequested, looksLikeNonToxinSkinTreatment} = require('./procedureScope');

/**
 * Semantic procedureRelation gate (mirrors Dart explore_procedure_relation.dart).
 * Price scoring runs only after exact|variant eligibility.
 */

const RELATIONS = {
  exact: 'exact',
  variant: 'variant',
  bundle: 'bundle',
  addOn: 'add_on',
  different: 'different_procedure',
  market: 'market_information',
  ambiguous: 'ambiguous',
};

const FROM = 'áàäâãåéèëêíìïîóòöôõúùüûñçşșță';
const TO = 'aaaaaaeeeeiiiiooooouuuuncssta';

function fold(raw) {
  return String(raw || '').toLowerCase().split('').map((ch) => {
    const i = FROM.indexOf(ch);
    return i >= 0 ? TO[i] : ch;
  }).join('');
}

function hasAny(folded, needles) {
  return needles.some((n) => {
    const f = fold(n);
    return f.length >= 3 && folded.includes(f);
  });
}

function requestedFamily(procedure) {
  const t = fold(procedure);
  if (!t || t === 'all') return 'other';
  if (t.includes('filler') || t.includes('hialuron') || t.includes('hyaluron') ||
      t.includes('relleno') || t.includes('juvederm') || t.includes('فيلر')) {
    return 'filler';
  }
  if (t.includes('botox') || t.includes('toxin') || t.includes('dysport') ||
      t.includes('بوتوكس')) return 'botox';
  if (t.includes('hydrafacial') || t.includes('hydra facial')) return 'hydrafacial';
  if (t.includes('profhilo') || t.includes('sculptra') || t.includes('skin booster') ||
      t.includes('rejuran') || t.includes('jalupro')) return 'skin';
  if (/\bprp\b/.test(t) || t.includes('platelet')) return 'prp';
  if (t.includes('microneedl') || t.includes('dermapen') || t.includes('skinpen')) {
    return 'microneedling';
  }
  if (t.includes('hifu') || t.includes('ultherapy')) return 'hifu';
  if (t.includes('laser') || t.includes('epilare') || t.includes('depilacion') ||
      t.includes('ليزر') || t.includes('pico') ||
      t.includes('photo rejuvenation') || t.includes('photorejuvenation') ||
      t.includes('photofacial') || t.includes('byonik') || t.includes('ipl')) {
    return 'laser';
  }
  if (t.includes('peel') || t.includes('تقشير')) return 'peel';
  if (t.includes('rhino') || t.includes('rinoplast') || t.includes('nose job') ||
      t.includes('تجميل الانف') || t.includes('تجميل الأنف')) return 'rhinoplasty';
  if (t.includes('breast') || t.includes('boob') || t.includes('pecho') ||
      t.includes('mamar') || t.includes('تكبير الثدي') || t.includes('تكبير الصدر')) {
    return 'breast_augmentation';
  }
  if (t.includes('hair') || t.includes('fue') || t.includes('dhi') ||
      t.includes('graft') || t.includes('injerto') || t.includes('زراعة الشعر')) {
    return 'hair';
  }
  return 'other';
}

function detectSignals(raw) {
  const t = fold(raw);
  const breastRemoval = hasAny(t, [
    'implant removal', 'breast implant removal', 'explant',
  ]) || (t.includes('removal') && t.includes('implant') && t.includes('breast'));
  const breastReduction = hasAny(t, [
    'breast reduction', 'reduccion de pecho', 'reducción de pecho', 'تصغير الثدي',
  ]);
  const breastLift = hasAny(t, [
    'breast lift', 'mastopex', 'mastopexy', 'شد الثدي', 'رفع الثدي',
  ]);
  const breastAug = hasAny(t, [
    'breast augmentation', 'aumento de pecho', 'aumento mamario', 'implant mamar',
    'breast implant', 'marire sani', 'marirea sanilor', 'marire de sani',
    'augmentare mamara', 'augmentarea mamara', 'boob job',
    'تكبير الثدي', 'تكبير الصدر',
  ]) || (t.includes('breast') && (t.includes('augment') || t.includes('implant'))) ||
      (t.includes('marire') && (t.includes('sani') || t.includes('sanilor'))) ||
      (t.includes('augmentare') && t.includes('mamar'));
  const botox = hasAny(t, [
    'botox', 'botulinum', 'toxina botulin', 'botulotoxin', 'dysport', 'xeomin', 'neuronox',
    'jeuveau', 'daxxify', 'neuromodul', 'wrinkle relaxer', 'neurotoxin', 'بوتوكس',
  ]) || /\blip[\s-]?flip\b|\blipflip\b|\bgummy\s*smile\b/i.test(t) || /\btox\b/.test(t) || (/\banti[\s-]?wrinkle\b|\bantiarrugas\b/.test(t) &&
      /\binject|toxin|unit|units|\biu\b|treatments?|injections?|\b(?:1|2|3|one|two|three)\s*(?:area|areas|zona|zone)/.test(t) &&
      !/\b(?:cream|serum|moistur|lotion|skincare|pad|mask)\b/.test(t));
  const filler = hasAny(t, [
    'filler', 'hyaluronic', 'acido hialuronico', 'relleno', 'juvederm',
    'restylane', 'radiesse', 'teosyal', 'belotero', 'revolax',
    'lip filler', 'lip augmentation', 'aumento de labios',
    'russian lips', 'russian lip',
    'فيلر',
  ]) || (t.includes('lip') && (t.includes('augment') || t.includes('filler'))) ||
      /\bstylage\s+[mlx]\b/i.test(t) ||
      (/\bstylage\b/i.test(t) && !/\bstylage\s+hydro|\bhydromax\b/i.test(t) &&
        /\b\d+(?:[.,]\d+)?\s*ml\b/i.test(t));
  const skin = hasAny(t, [
    'profhilo', 'sculptra', 'skin booster', 'skinbooster', 'rejuran', 'jalupro',
    'nucleofill', 'stylage hydro', 'hydromax', 'biorevital', 'nctf', 'filorga',
    'mesoterapia', 'mesotherapy',
  ]);
  const prp = hasAny(t, ['prp', 'platelet rich', 'vampire facial']);
  const hydrafacial = hasAny(t, ['hydrafacial', 'hydra facial']);
  const microneedling = hasAny(t, ['microneedling', 'dermapen', 'skinpen']);
  const hifu = hasAny(t, ['hifu', 'ultherapy', 'ulthera']);
  const laser = hasAny(t, [
    'laser', 'fraxel', 'ipl', 'photo rejuvenation', 'photorejuvenation',
    'photofacial', 'byonik', 'ليزر', 'pico',
  ]);
  const peel = hasAny(t, ['peel', 'peeling', 'chemical peel', 'تقشير']);
  const rhino = hasAny(t, ['rhinoplasty', 'rinoplastia', 'nose job', 'تجميل الانف']);
  const hair = hasAny(t, ['hair transplant', 'fue', 'dhi', 'graft', 'زراعة الشعر']);
  const energy = looksLikeEnergyOrDeviceTreatment(t) ||
      /\bradiofrequency\b|\brf\s*microneedl|\bthread lift\b|\bpdo threads?\b/.test(t);
  const families = new Set();
  if (botox) families.add('botox');
  if (filler) families.add('filler');
  if (skin) families.add('skin');
  if (prp) families.add('prp');
  if (hydrafacial) families.add('hydrafacial');
  if (microneedling) families.add('microneedling');
  if (hifu) families.add('hifu');
  if (energy) families.add('energy_device');
  if (laser) families.add('laser');
  if (peel) families.add('peel');
  if (rhino) families.add('rhinoplasty');
  if (hair) families.add('hair');
  if (breastAug && !breastRemoval && !breastReduction) families.add('breast_augmentation');
  if (breastLift) families.add('breast_lift');
  if (breastReduction) families.add('breast_reduction');
  if (breastRemoval) families.add('breast_removal');
  return {
    botox, filler, skin, prp, hydrafacial, microneedling, hifu,
    energyDevice: energy,
    laser, peel, rhinoplasty: rhino, hair,
    breastAugmentation: breastAug && !breastRemoval && !breastReduction,
    breastLift, breastReduction, breastRemoval, families,
    matches(want) {
      if (want === 'breast' || want === 'breast_augmentation') return this.breastAugmentation;
      if (want === 'profhilo' || want === 'sculptra' || want === 'skin_booster') {
        return this.skin;
      }
      if (want === 'energy_device') return this.energyDevice;
      return !!this[want] || (want === 'hair' && this.hair);
    },
    extrasBeside(want) {
      const all = new Set(this.families);
      if (want === 'breast' || want === 'breast_augmentation') all.delete('breast_augmentation');
      else if (want === 'profhilo' || want === 'sculptra' || want === 'skin_booster') {
        all.delete('skin');
      } else all.delete(want);
      return all;
    },
  };
}

function hasComboSyntax(folded) {
  return /\+|\/\s*(?:and|&)|\b(?:plus|combo|bundle|package|pack|paquet|pachet|باقة)\b|\bwith\s+(?:breast\s+)?(?:lift|mastopex|reduction|botox|filler|peel|laser)\b|\bbotox\s*(?:\+|and|&)\s*filler\b|\bfiller\s*(?:\+|and|&)\s*botox\b|\b(?:face\s+)?tox\s*(?:\+|and|&)\s*(?:\d+\s+syringes?\s+)?filler\b|\bfiller\s*(?:\+|and|&)\s*(?:\d+\s+syringes?\s+)?(?:face\s+)?tox\b/i.test(folded);
}

function looksLikeExplicitAddOn(folded) {
  return /\badd[\s-]?on\b|\baddon\b/i.test(folded);
}

function looksLikeKnownBotoxZone(folded) {
  return /periocular|glabel|glabella|frontal|frunte|crow|forehead|frown|\b(?:1|2|3|one|two|three|single)\s*(?:zon|area)/i.test(String(folded || ''));
}

function looksLikeLipFlipOrGummySmile(folded) {
  return /\blip[\s-]?flip\b|\blipflip\b|\bgummy\s*smile\b/i.test(String(folded || ''));
}

function looksLikeKnownFillerArea(folded) {
  if (looksLikeLipFlipOrGummySmile(folded)) return false;
  return /\b(?:lips?|cheeks?|tear\s*trough|smile\s*line|jaw\s*line|russian\s+lips?|\d+(?:[.,]\d+)?\s*ml)\b/i.test(String(folded || ''));
}

function pageHasRequestedFamilyWitness(rows, procedure) {
  const want = requestedFamily(procedure);
  if (want === 'other' || !Array.isArray(rows)) return false;
  return rows.some((r) => detectSignals(
      `${r && r.rawProcedureText || ''} ${r && r.rawEvidence || ''} ${r && r.sourceUrl || ''}`,
  ).matches(want));
}

function looksLikeVariant(folded, want) {
  const qty = /\b\d+(?:[.,]\d+)?\s*(?:ml|cc|syringe|unit|units|iu|zona|zone|zones|area|session|graft)s?\b|(?:per|\/)\s*(?:ml|unit|units|iu|area|session|graft)\b/i.test(folded);
  const brand = /\b(?:juvederm|restylane|teosyal|belotero|radiesse|dysport|xeomin|mentor|motiva)\b/i.test(folded);
  const zone = /\b(?:\d+|1|2|3)\s*(?:zone|zones|zona|area)s?\b|\b(?:forehead|frown|crow|glabel|periocular|underarm|full\s+face)\b/i.test(folded);
  if (want === 'botox' &&
      /periocular|glabel|frontal|frunte|crow|forehead|frown|\b(?:1|2|3|one|two|three|single)\s*(?:zon|area)/i.test(folded)) {
    return true;
  }
  if (want === 'laser' && /underarm|bikini|full\s+face|full\s+body|half\s+leg|peri[\s-]?anal|hollywood|photo\s*rejuvenation|byonik|\bipl\b/i.test(folded)) return true;
  return qty || brand || zone;
}

function looksLikeMarket(blob) {
  const t = String(blob || '');
  return /\btypically\b|\bgenerally\b|\bcommon prices?\b|\bacross clinics\b|\bapproximate\b|\bhigh-end\b|\bbudget clinics?\b|\bcost in\b|\bno less than\b|\bcost of a good\b|\breputable clinics\b|\bin this region given\b|\bgood boob job\b|\btypical london price ranges\b|\bprices? vary among surgeons\b|\bhelpful reference\b|\bon average:\b/i.test(t);
}

function looksLikeFinancingHeading(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim().toLowerCase();
  if (!t) return false;
  return /\bfinanc(?:e|ing|ial|iaci[oó]n)\b|\bmonthly payments?\b|\bpayment plans?\b|\b0\s*%\s*(?:apr|finance|interest)\b|\binstallments?\b|\bcuotas?\b|\bloan\b|\bhow to pay\b|\bpay monthly\b/i.test(t);
}

/**
 * @return {{relation:string, reason:string, eligible:boolean, logToken:string}}
 */
function urlPathText(sourceUrl) {
  const raw = String(sourceUrl || '').trim();
  if (!raw) return '';
  try {
    const u = new URL(raw.includes('://') ? raw : `https://${raw}`);
    return `${u.pathname} ${u.search}`.replace(/[/#?&=._\-]+/g, ' ');
  } catch (_) {
    return raw.replace(/[/#?&=._\-]+/g, ' ');
  }
}

function classifyProcedureRelation({
  requestedProcedure,
  label = '',
  evidence = '',
  sourceUrl = '',
  clinicOwnQuoted = false,
  parentHeading = '',
  pageHasFamilyWitness = false,
} = {}) {
  const want = requestedFamily(requestedProcedure);
  const blob = `${label}\n${evidence}`;
  const folded = fold(blob);
  const urlFolded = fold(urlPathText(sourceUrl));

  if (looksLikeSpanishMarketPriceQuote(blob)) {
    return {relation: RELATIONS.market, reason: 'spanish_market_price_quote',
      eligible: false, logToken: 'market_information'};
  }
  if (looksLikeLipHydrationWhenAugmentationRequested({procedure: requestedProcedure, label, evidence})) {
    return {relation: RELATIONS.different, reason: 'lip_hydration_not_augmentation',
      eligible: false, logToken: 'different_procedure'};
  }
  if (want === 'botox' && looksLikeNonToxinSkinTreatment(label)) {
    return {relation: RELATIONS.different, reason: 'skin_mesotherapy_not_toxin',
      eligible: false, logToken: 'different_procedure'};
  }

  if (want === 'filler' && (looksLikeSurgicalChinTreatment(blob) ||
      looksLikeSurgicalChinTreatment(urlFolded))) {
    return {relation: RELATIONS.different, reason: 'surgical_chin_not_filler',
      eligible: false, logToken: 'different_procedure'};
  }

  if (looksLikeFinancingHeading(label)) {
    return {relation: RELATIONS.ambiguous, reason: 'financing_heading', eligible: false, logToken: 'ambiguous'};
  }

  if (looksLikeCityMarketPricingGuideUrl(sourceUrl) ||
      looksLikeMarketEstimateDirectoryUrl(sourceUrl)) {
    return {relation: RELATIONS.market, reason: 'city_market_pricing_guide', eligible: false, logToken: 'market_information'};
  }
  if (looksLikeTreatmentFinanceUrl(sourceUrl)) {
    return {relation: RELATIONS.ambiguous, reason: 'treatment_finance_page', eligible: false, logToken: 'ambiguous'};
  }

  if (!clinicOwnQuoted && looksLikeMarket(blob)) {
    return {relation: RELATIONS.market, reason: 'market_or_city_average_copy', eligible: false, logToken: 'market_information'};
  }
  if (/\btypical(?:ly)?\s+sessions?\s+rang|\bprices?\s+vary\s+depending\b/i.test(folded)) {
    return {relation: RELATIONS.market, reason: 'typical_market_range_copy', eligible: false, logToken: 'market_information'};
  }

  const signals = detectSignals(blob);
  const urlSignals = detectSignals(urlFolded);
  const extras = signals.extrasBeside(want);

  if (want === 'breast_augmentation' || want === 'breast') {
    if (signals.breastRemoval || urlSignals.breastRemoval) {
      return {relation: RELATIONS.different, reason: 'breast_implant_removal', eligible: false, logToken: 'different_procedure'};
    }
    if (signals.breastReduction || urlSignals.breastReduction) {
      return {relation: RELATIONS.different, reason: 'breast_reduction', eligible: false, logToken: 'different_procedure'};
    }
    if ((signals.breastLift || urlSignals.breastLift) &&
        !signals.breastAugmentation && !urlSignals.breastAugmentation) {
      return {relation: RELATIONS.different, reason: 'breast_lift_only', eligible: false, logToken: 'different_procedure'};
    }
    if (/\binverted nipple\b|\bnipple (?:lift|reduction|correction)\b/.test(folded) &&
        !signals.breastAugmentation && !urlSignals.breastAugmentation) {
      return {relation: RELATIONS.different, reason: 'breast_nipple_only', eligible: false, logToken: 'different_procedure'};
    }
    if (/\bunilateral\b|\bone[- ]breast\b|\bsingle[- ]breast\b/.test(folded)) {
      return {relation: RELATIONS.different, reason: 'breast_unilateral', eligible: false, logToken: 'different_procedure'};
    }
    if (signals.breastAugmentation && (signals.breastLift || signals.breastReduction)) {
      return {relation: RELATIONS.bundle, reason: 'breast_aug_plus_lift_or_reduction', eligible: false, logToken: 'bundle'};
    }
    // "Breast Augmentation + Lift" without the word "breast" before lift.
    if (signals.breastAugmentation &&
        /\+\s*lift\b|\band\s+lift\b|\bwith\s+lift\b|\blift\s*\+/i.test(folded)) {
      return {relation: RELATIONS.bundle, reason: 'breast_aug_plus_lift_combo', eligible: false, logToken: 'bundle'};
    }
  }

  if (extras.size > 0 && hasComboSyntax(folded)) {
    return {relation: RELATIONS.bundle, reason: `combo_with_${[...extras].join('_')}`, eligible: false, logToken: 'bundle'};
  }
  if (extras.size > 0 && signals.matches(want) && folded.trim().length <= 160 &&
      (folded.includes('+') || /\b(?:package|combo|bundle|باقة)\b/i.test(folded) || extras.size >= 2)) {
    return {relation: RELATIONS.bundle, reason: `multi_procedure_line_${[...extras].join('_')}`, eligible: false, logToken: 'bundle'};
  }
  if (looksLikeExplicitAddOn(folded) ||
      (/\badd[\s-]?on\b|\baddon\b|\bextra\b|\boptional\b|when added to another/i.test(folded) && extras.size > 0)) {
    return {relation: RELATIONS.addOn, reason: 'add_on_modifier', eligible: false, logToken: 'add_on'};
  }
  if (want === 'botox' &&
      /when added to another|targeted areas|higher[- ]dosage supplement/i.test(folded) &&
      !/\b(?:1|one|single)\s*area\b/i.test(folded)) {
    return {relation: RELATIONS.addOn, reason: 'botox_addon_or_targeted', eligible: false, logToken: 'add_on'};
  }
  if (want === 'rhinoplasty' &&
      looksLikePartialRhinoplastyStarting(label)) {
    return {relation: RELATIONS.different, reason: 'rhino_tip_or_partial', eligible: false, logToken: 'different_procedure'};
  }

  if (want !== 'other' && !signals.matches(want)) {
    const labelSignals = detectSignals(label);
    const parentSignals = detectSignals(parentHeading);
    const competing = new Set([
      ...extras,
      ...urlSignals.extrasBeside(want),
      ...labelSignals.extrasBeside(want),
    ]);
    if (competing.size > 0 && !labelSignals.matches(want)) {
      const got = [...competing].join(',');
      console.log(`[RELATION REJECT] "${String(label || '').slice(0, 56)}" → different_procedure:${got}`);
      return {
        relation: RELATIONS.different,
        reason: `competing_family_${got}`,
        eligible: false,
        logToken: 'different_procedure',
      };
    }
    // Anatomy / zone may refine a family. It must never establish one.
    const familyWitness = labelSignals.matches(want) ||
        urlSignals.matches(want) ||
        parentSignals.matches(want) ||
        pageHasFamilyWitness === true;
    if (want === 'botox' && looksLikeKnownBotoxZone(fold(label)) &&
        familyWitness && competing.size === 0) {
      return {relation: RELATIONS.variant, reason: 'botox_zone_or_area_variant', eligible: true, logToken: 'variant'};
    }
    if (want === 'laser' &&
        /\b(?:underarm|bikini|brazilian|full\s+face|full\s+body|half\s+leg|peri[\s-]?anal|hollywood|photo\s*rejuvenation|photofacial|byonik|\bipl\b)\b/i.test(fold(label)) &&
        !/\b(?:shav(?:e|ing)|wax(?:ing)?|thread(?:ing)?|sugaring)\b/i.test(fold(label)) &&
        familyWitness && competing.size === 0) {
      return {relation: RELATIONS.variant, reason: 'laser_area_or_session_variant', eligible: true, logToken: 'variant'};
    }
    if (want === 'filler' && looksLikeKnownFillerArea(fold(label)) &&
        familyWitness && competing.size === 0) {
      return {relation: RELATIONS.variant, reason: 'filler_area_or_ml_variant', eligible: true, logToken: 'variant'};
    }
    if (urlSignals.matches(want) && urlSignals.extrasBeside(want).size === 0) {
      if (signals.families.size > 0 && !signals.matches(want)) {
        return {
          relation: RELATIONS.different,
          reason: `family_mismatch_want_${want}_got_${[...signals.families].join(',')}`,
          eligible: false,
          logToken: 'different_procedure',
        };
      }
      const strippedLabel = String(label || '').replace(/[\s*]+$/g, '').trim();
      const genericColumn = /^(?:treatment|treatments|procedure|procedures|service|services|item|guide price|guide price from|price from)$/i.test(
          strippedLabel.replace(/[^a-z0-9]+/gi, ' ').trim());
      const namedRow = strippedLabel.length >= 4 &&
          !looksLikePriceMenuHeadingOnly(label) &&
          !looksLikePriceMenuHeadingOnly(strippedLabel) &&
          !genericColumn &&
          !/^(?:from|starting(?:\s+from)?|starts\s+from|de la|desde)?\s*[€£$]?\s*[\d.,]+/i.test(strippedLabel);
      if (namedRow && !signals.matches(want)) {
        return {
          relation: RELATIONS.different,
          reason: 'named_row_not_requested_treatment',
          eligible: false,
          logToken: 'different_procedure',
        };
      }
      if (looksLikeVariant(folded, want) || looksLikeVariant(urlFolded, want)) {
        return {relation: RELATIONS.variant, reason: 'url_treatment_variant', eligible: true, logToken: 'variant'};
      }
      return {relation: RELATIONS.exact, reason: 'url_treatment_match', eligible: true, logToken: 'exact'};
    }
    if (signals.families.size > 0 || urlSignals.families.size > 0) {
      return {
        relation: RELATIONS.different,
        reason: `family_mismatch_want_${want}_got_${[...signals.families, ...urlSignals.families].join(',')}`,
        eligible: false,
        logToken: 'different_procedure',
      };
    }
    return {relation: RELATIONS.ambiguous, reason: 'unmatched_procedure_signal', eligible: false, logToken: 'ambiguous'};
  }

  if (extras.size > 0) {
    return {relation: RELATIONS.bundle, reason: `extra_procedure_${[...extras].join('_')}`, eligible: false, logToken: 'bundle'};
  }
  if (looksLikeVariant(folded, want)) {
    return {relation: RELATIONS.variant, reason: 'brand_amount_area_or_session_variant', eligible: true, logToken: 'variant'};
  }
  return {relation: RELATIONS.exact, reason: 'same_treatment', eligible: true, logToken: 'exact'};
}

function looksLikeInheritableAreaOnlyLabel(label, requestedFamily) {
  const folded = fold(label);
  if (!folded.trim()) return false;
  if (looksLikeEnergyOrDeviceTreatment(label) || looksLikeEnergyOrDeviceTreatment(folded)) {
    return false;
  }
  if (requestedFamily === 'botox') {
    return looksLikeKnownBotoxZone(folded);
  }
  if (requestedFamily === 'filler') {
    if (looksLikeLipFlipOrGummySmile(folded) ||
        /\bmasseter\b|\bbruxism\b|teeth grind|jawline slimming|filler[\s-]?dissolv|dissolv(?:e|ing)/i.test(folded)) {
      return false;
    }
    return /\b(?:lips?|cheeks?|tear\s*trough|smile\s*line|jaw\s*line|russian\s+lips?|\d+\s*ml)\b/i.test(folded);
  }
  if (requestedFamily === 'laser') {
    return /\b(?:underarm|bikini|full\s+face|full\s+body|half\s+leg|peri[\s-]?anal|hollywood|photo\s*rejuvenation|byonik|\bipl\b)\b/i.test(folded);
  }
  return false;
}

const _relationLogSeen = new Set();

function logProcedureRelation(result, label = '') {
  const short = String(label || '').trim();
  const key = `${result.logToken}|${result.reason}|${short.slice(0, 80)}`;
  if (_relationLogSeen.has(key)) return;
  if (_relationLogSeen.size > 80) _relationLogSeen.clear();
  _relationLogSeen.add(key);
  const suffix = short ? ` · "${short.length > 72 ? `${short.slice(0, 72)}…` : short}"` : '';
  console.log(`[PROCEDURE RELATION] ${result.logToken} · ${result.reason}${suffix}`);
  if (!result.eligible) {
    console.log(`[PRICE REJECT] relation_${result.logToken} · ${result.reason}`);
  }
}

module.exports = {
  classifyProcedureRelation,
  logProcedureRelation,
  looksLikeInheritableAreaOnlyLabel,
  looksLikeKnownBotoxZone,
  pageHasRequestedFamilyWitness,
  detectSignals,
  requestedFamily,
  RELATIONS,
};
