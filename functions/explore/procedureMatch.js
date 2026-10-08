'use strict';

const {isValidExtractedPriceCandidate, looksLikeShopifyThemeDummyPrice,
  looksLikeUsdQuotedOnUkHost, looksLikeRoundedMarketPriceSpread,
  looksLikeDepigmentationPeelPackage, looksLikeMultiSessionSeriesQuote, looksLikePartialRhinoplastyStarting,
  looksLikePrimaryRhinoplastyStarting, looksLikePatientAnecdotePrice,
  looksLikePriceMenuHeadingOnly, explorePublishedOrReviewedYear,
  looksLikeBreastAugmentationAddOnRow,
  looksLikeCompetitorOrThirdPartyPriceQuote,
  looksLikeThirdPartyProviderPriceLabel,
  looksLikeGraftOrFollicleQuantity,
  looksLikePerGraftQuotedPrice,
  looksLikeEffectivePerGraftMarketing,
  looksLikeHairNonStartingRow,
  looksLikeHairLargerThanStartingPackage,
  looksLikeHairMarketComparisonRow,
  looksLikeHairDhiWhenFueRequested,
  looksLikeHairStartingPackageRow,
  hairRowIncludesMandatoryAddOnFee,
  exploreMandatoryPackageAddOnFee,
  looksLikeHairCachedNonStartingPackageFrom,
  looksLikeHairMarketPerGraftBlurb,
  looksLikeHairFutWhenFueRequested,
  looksLikeHairProcedureLandingUrl,
  looksLikeHairStaleLandingQuote,
  looksLikeUnshavenHairVariant,
  looksLikeGraftCountMistakenForPrice,
  looksLikeCityMarketPricingGuideUrl,
  exploreUrlConflictsWithProcedure,
  looksLikeEnergyOrDeviceTreatment,
  exploreUrlPathFamilyKey,
  hairPerGraftPlausibleMax} = require('./priceSanity');
const {
  isNonLiteralClinicPriceUrl,
  looksLikeClinicArticlePriceUrl,
  looksLikeCityCostArticleUrl,
  looksLikeOfficialPriceListUrl,
  looksLikeBotoxSpecialtyVariantUrl,
  evidenceQuotesPriceRange,
} = require('./parsePrice');
const {looksLikeMarketEstimateDirectoryUrl} = require('./identity');
const {looksLikeFinancingOrPaymentHeading,
  looksLikeUnilateralBreastStartingRow,
  looksLikeSeoCostPageHeading,
  looksLikeComplicationOrAftercareHeading} = require('./identity');
const {lockPriceEvidence, logPriceSource, logPriceAccept} = require('./evidenceLock');
const {looksLikeInheritableAreaOnlyLabel,
  pageHasRequestedFamilyWitness} = require('./procedureRelation');

const FILLER_POSITIVE = [
  'filler', 'dermal filler', 'hyaluronic acid', 'acido hialuronico',
  'ácido hialurónico', 'acid hialuronic', 'relleno dermico', 'relleno dérmico',
  'relleno', 'juvederm', 'restylane', 'teosyal', 'teoxane', 'belotero',
  'revolax', 'stylage', 'volbella', 'volift', 'voluma', 'radiesse',
  'aumento de labios',
  'relleno de labios', 'perfilado de labios',   'lip filler', 'lip augmentation', 'marire buze', 'volumizare buze',
  'russian lips', 'russian lip', 'cheek filler',
  'филър', 'хиалуронова киселина', 'филър за устни', 'дермален филър',
  'فيلر', 'الفيلر', 'هيالورونيك', 'حمض الهيالورونيك',
];

const BOTOX_POSITIVE = [
  'botox', 'botulinum', 'toxina botulinica', 'toxina botulínica',
  'toxina botulin', 'botulotoxina', 'botulotoxin',
  'dysport', 'xeomin', 'neuronox', 'azzalure', 'vistabel',
  'neuromodulador', 'neuromodulator', 'antiarrugas', 'anti-wrinkle',
  'anti wrinkle', 'antiwrinkle', 'wrinkle relaxer', 'wrinkle relaxers',
  'estompare riduri', 'corectie riduri', 'eliminare riduri',
  'periocular', 'glabelar',
  'ботокс', 'ботулин', 'ботулотоксин', 'ботулинов токсин',
  'بوتوكس', 'البوتولينوم', 'توكسين البوتولينوم',
];

const LASER_POSITIVE = [
  'laser', 'depilacion laser', 'depilación láser', 'epilare laser',
  'laser hair', 'fraxel', 'co2', 'ipl',
  'photo rejuvenation', 'photorejuvenation', 'photofacial', 'byonik',
  'лазерна епилация', 'лазер',
  'ليزر', 'بالليزر',
];

const PEEL_POSITIVE = [
  'peel', 'peeling', 'peeling quimico', 'peeling químico', 'chemical peel',
  'glycolic', 'jessner', 'tca peel',
  'химичен пилинг', 'пилинг',
  'تقشير', 'التقشير',
];

const RHINO_SURGERY = [
  'rhinoplasty', 'rinoplastia', 'rinoplastie', 'nose job',
  'nasal surgery', 'septoplast',
  'ринопластика', 'операция на носа', 'корекция на носа',
  'تجميل الانف', 'تجميل الأنف', 'رأب الأنف', 'راب الانف',
];

const BREAST_AUG = [
  'breast augmentation', 'breast enlargement', 'boob job', 'memorygel',
  'aumento de pecho', 'aumento mamario',
  'mamoplastia de aumento', 'implant mamar',
  'marire sani', 'marirea sanilor', 'marire de sani',
  'augmentare mamara', 'augmentarea mamara',
  'уголемяване на бюст', 'уголемяване на гърди',
  'гръдни импланти', 'импланти за бюст',
  'تكبير الثدي', 'تكبير الصدر', 'زراعة الثدي',
];

const HAIR_TX = [
  'hair transplant', 'hair implant', 'injerto capilar',
  'transplant de par', 'transplant par', 'implant de par', 'implant par',
  'implant capilar', 'fir cu fir', 'fue', 'dhi', 'graft', 'grafturi',
  'greffe de cheveux', 'trapianto capelli', 'haartransplantation',
  'saç ekimi', 'sac ekimi',
  'трансплантация на коса', 'присаждане на коса',
  'زراعة الشعر', 'زراعة شعر', 'زرع الشعر',
];

const PROFHILO_POSITIVE = [
  'profhilo', 'sculptra', 'skin booster', 'skinboosters', 'seventy hyal',
  'rejuran', 'jalupro', 'nucleofill', 'sunekos',
];

const PRP_POSITIVE = [
  'prp', 'platelet rich', 'vampire facial', 'prp hair', 'prp face',
  'prp facial', 'prp scalp',
];

const HYDRAFACIAL_POSITIVE = [
  'hydrafacial', 'hydra facial', 'hydra-facial',
];

const MICRONEEDLING_POSITIVE = [
  'microneedling', 'micro needling', 'dermapen', 'skinpen', 'collagen induction',
];

const HIFU_POSITIVE = [
  'hifu', 'ultherapy', 'ulthera', 'high intensity focused ultrasound',
];

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
      t.includes('relleno') || t.includes('juvederm') ||
      t.includes('филър') || t.includes('хиалуронова') ||
      t.includes('فيلر')) return 'filler';
  if (t.includes('botox') || t.includes('toxin') || t.includes('dysport') ||
      t.includes('ботокс') || t.includes('ботулин') ||
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
      t.includes('ليزر') || t.includes('лазер') || t.includes('pico') ||
      t.includes('photo rejuvenation') || t.includes('photorejuvenation') ||
      t.includes('photofacial') || t.includes('byonik') || t.includes('ipl')) {
    return 'laser';
  }
  if (t.includes('peel') || t.includes('تقشير') ||
      t.includes('пилинг') || t.includes('химичен')) return 'peel';
  if (t.includes('rhino') || t.includes('rinoplast') || t.includes('nose job') ||
      t.includes('ринопласт') || t.includes('операция на носа') ||
      t.includes('корекция на носа') ||
      t.includes('تجميل الانف') || t.includes('تجميل الأنف')) {
    return 'rhinoplasty';
  }
  if (t.includes('breast') || t.includes('boob') || t.includes('pecho') ||
      t.includes('mamar') || t.includes('تكبير الثدي') ||
      t.includes('تكبير الصدر') ||
      t.includes('уголемяване') || t.includes('гръдни имплант') ||
      t.includes('импланти за бюст') ||
      (t.includes('marire') && (t.includes('sani') || t.includes('sanilor'))) ||
      (t.includes('augmentare') && t.includes('mamar'))) {
    return 'breast_augmentation';
  }
  if (t.includes('hair') || t.includes('fue') || t.includes('injerto') ||
      t.includes('трансплантация на коса') || t.includes('присаждане на коса') ||
      t.includes('زراعة الشعر')) return 'hair';
  return 'other';
}

const LASER_HAIR_CUE = /\b(?:hair\s*remov|epilare|depilacion|depilación|diode|alexandrite|underarm|under[\s-]?arms?|bikini|brazilian|hollywood|peri[\s-]?anal|intimate|full\s+body|full\s+leg|half\s+leg|upper\s+lip|chest\s+hair|back\s+hair|beard)\b|ازالة الشعر|إزالة الشعر|شعر بالليزر/i;
const LASER_SKIN_CUE = /\b(?:byonik|fraxel|co2|moxi|genesis|photofacial|photo\s*rejuvenation|photorejuvenation|pigment|pigmentation|vascular|rosacea|acne\s+ipl|ipl\s+(?:face|skin|rejuven)|hydrating\s+laser|laser\s+facial|carbon\s+laser|resurfacing|skin\s+rejuvenation|intense\s+pulsed)\b/i;
const LASER_GENERIC_CUE = /^(?:laser(?:\s+hair)?(?:\s+removal)?(?:\s+treatments?)?|laser\s+skin\s+treatment)\s*$/i;

function laserRequestedSubtype(procedure) {
  const t = fold(procedure);
  if (!t) return 'mixed';
  const hair = LASER_HAIR_CUE.test(t) || t.includes('hair removal') || t.includes('laser hair');
  const skin = LASER_SKIN_CUE.test(t) ||
      (t.includes('skin') && (t.includes('rejuven') || t.includes('ipl') ||
          t.includes('fraxel') || t.includes('byonik')));
  if (hair && t.includes('skin')) return 'mixed';
  if (hair && skin) return 'mixed';
  if (hair) return 'hair';
  if (skin) return 'skin';
  if (t.includes('laser')) return 'mixed';
  return 'mixed';
}

function laserRowSubtype(raw) {
  const t = fold(raw);
  if (!t) return 'generic';
  if (LASER_GENERIC_CUE.test(t.trim())) return 'generic';
  const hair = LASER_HAIR_CUE.test(t);
  const skin = LASER_SKIN_CUE.test(t);
  if (hair && !skin) return 'hair';
  if (skin && !hair) return 'skin';
  if (hair && skin) return t.includes('hair') ? 'hair' : 'skin';
  if (/\b(?:underarm|bikini|leg|arm|chest|back|body|full\s+face)\b/.test(t) && !skin &&
      !t.includes('facial') && !t.includes('rejuven')) {
    return 'hair';
  }
  return 'generic';
}

function laserRowFitsRequest(label, procedure) {
  const want = laserRequestedSubtype(procedure);
  const got = laserRowSubtype(label);
  if (got === 'generic') return false;
  if (want === 'mixed') return true;
  return got === want;
}

function competingFamilyRejectReason(rawLabel, requested) {
  const t = fold(rawLabel);
  const want = String(requested || '').trim().toLowerCase();
  if (looksLikeFinancingOrPaymentHeading(rawLabel)) return 'wrong_family_financing';

  const lipLift = t.includes('lip lift') || t.includes('lip-lift') ||
      t.includes('liplift') || t.includes('lifting labial') ||
      t.includes('bullhorn') || t.includes('queiloplast') ||
      t.includes('cirugia labial');
  if (want === 'filler' && lipLift) return 'wrong_family_lip_lift';

  // DR.CYJ Hair Filler / scalp HA / hair mesotherapy — not facial dermal filler.
  if (want === 'filler' &&
      /\bhair\s+filler\b|\bfiller\s+(?:for\s+)?hair\b|\bdr\.?\s*cyj\b|\bhair\s+mesotherap|\bmesotherap(?:y|ie)\s+(?:for\s+)?hair\b|\bxl\s*hair\b|\bplinest\s+hair\b|\bhair\s+loss\s+treatment\b|\bhair\s+treatments?\b/i
          .test(t)) {
    return 'wrong_family_hair_filler';
  }

  const dissolve = t.includes('hialuronidaz') || t.includes('hyaluronidase') ||
      t.includes('hyaluronidas') || t.includes('topirea acidului') ||
      t.includes('dizolvare') ||       t.includes('dissolve filler') ||
      t.includes('dissolving filler') ||
      t.includes('filler dissolv') ||
      t.includes('dissolving clinic') ||
      t.includes('اذابة الفيلر') || t.includes('إذابة الفيلر');
  if (want === 'filler' && dissolve) return 'wrong_family_hyaluronidase';
  if ((want === 'filler' || want === 'botox') &&
      looksLikeEnergyOrDeviceTreatment(t)) {
    return 'wrong_family_energy_device';
  }
  if (want === 'filler' &&
      /\bmasseter\b|\bbruxism\b|teeth grind/i.test(t) &&
      !hasAny(t, FILLER_POSITIVE)) {
    return 'wrong_family_masseter_not_filler';
  }

  if (want === 'laser') {
    const shaveOrWax = /\b(?:shav(?:e|ing)|wax(?:ing)?|thread(?:ing)?|sugaring)\b/i
        .test(t);
    if (shaveOrWax && !hasAny(t, LASER_POSITIVE) && !t.includes('ipl')) {
      return 'wrong_family_shaving_or_wax';
    }
    if ((t.includes('hydrafacial') || t.includes('hifu') ||
        /\b\d+\s*cups?\b/.test(t) || t.includes('fat dissolv')) &&
        !hasAny(t, LASER_POSITIVE) && !t.includes('ipl') &&
        !t.includes('hair remov')) {
      return 'wrong_family_not_laser';
    }
  }

  if (want === 'botox') {
    if (hasAny(t, FILLER_POSITIVE) && !hasAny(t, BOTOX_POSITIVE)) {
      return 'wrong_family_filler';
    }
    if ((hasAny(t, LASER_POSITIVE) || t.includes('cheratoze') ||
        t.includes('thulium') || t.includes('lasemd')) &&
        !hasAny(t, BOTOX_POSITIVE)) {
      return 'wrong_family_laser';
    }
  }

  const rhinoFiller = t.includes('rinomodel') || t.includes('rhinomodel') ||
      t.includes('nose filler') || t.includes('filler nariz') ||
      t.includes('non-surgical rhino') || t.includes('nonsurgical rhino') ||
      t.includes('rinoplastia no quir') ||
      (t.includes('acido hialuronico') && t.includes('nariz')) ||
      (t.includes('hyaluronic') && t.includes('nariz'));
  if (rhinoFiller && (want === 'rhinoplasty' || want === 'filler')) {
    return 'wrong_family_rhinomodeling';
  }

  if (want === 'hair') {
    if ((t.includes('prp capilar') || t.includes('mesoterap') ||
        t.includes('consulta')) && !hasAny(t, HAIR_TX)) {
      return 'wrong_family_hair_nonsurgical';
    }
  }

  if (want === 'breast_augmentation' || want === 'breast') {
    if (t.includes('تثدي')) return 'wrong_family_breast_other';
    if ((t.includes('mastopex') || t.includes('breast reduction') ||
        t.includes('breast lift') || t.includes('reduccion de pecho') ||
        t.includes('تصغير الثدي') || t.includes('شد الثدي') ||
        t.includes('رفع الثدي') || t.includes('inverted nipple') ||
        t.includes('nipple lift') || t.includes('nipple reduction')) &&
        !hasAny(t, BREAST_AUG)) {
      return 'wrong_family_breast_other';
    }
  }

  if (t.includes('consulta') || t.includes('consultation') ||
      t.includes('evaluacion medica') || t.includes('primera visita') ||
      t.includes('استشارة')) {
    if (want !== 'consultation') return 'wrong_family_consultation';
  }
  return null;
}

function familiesCompatible(requested, got) {
  if (requested === got) return true;
  if (requested === 'breast' && got === 'breast_augmentation') return true;
  if (requested === 'hair' && got === 'hair_transplant') return true;
  if (requested === 'skin' &&
      (got === 'skin' || got === 'profhilo' || got === 'sculptra')) return true;
  if ((requested === 'prp' || requested === 'prp_hair' || requested === 'prp_face') &&
      got === 'prp') return true;
  return false;
}

function matchRawProcedureLabel(rawLabel, requestedProcedure) {
  const folded = fold(rawLabel);
  if (!folded.trim()) {
    return {family: 'other', canonical: '', confidence: 0, rejectReason: 'empty_label'};
  }
  const requested = requestedFamily(requestedProcedure);
  const conflict = competingFamilyRejectReason(rawLabel, requested);
  if (conflict) {
    console.log(`[MATCH] REJECT "${rawLabel}" → ${conflict}`);
    return {family: 'other', canonical: '', confidence: 0, rejectReason: conflict};
  }

  let family = 'other';
  let canonical = '';
  let confidence = 0;

  if (hasAny(folded, FILLER_POSITIVE)) {
    family = 'filler';
    canonical = (folded.includes('labio') || folded.includes('lip') || folded.includes('buze') ||
        folded.includes('russian'))
      ? 'lip_filler'
      : ((folded.includes('pomet') || folded.includes('cheek') || folded.includes('mejilla'))
          ? 'cheek_filler' : 'filler');
    confidence = 0.94;
  } else if (hasAny(folded, BOTOX_POSITIVE)) {
    family = 'botox';
    canonical = 'botox';
    confidence = 0.94;
  } else if (hasAny(folded, PROFHILO_POSITIVE)) {
    family = 'skin';
    canonical = folded.includes('sculptra') ? 'sculptra'
      : (folded.includes('profhilo') ? 'profhilo' : 'skin_booster');
    confidence = 0.93;
  } else if (hasAny(folded, PRP_POSITIVE)) {
    family = 'prp';
    canonical = (folded.includes('hair') || folded.includes('scalp') ||
        folded.includes('capilar')) ? 'prp_hair' : 'prp_face';
    confidence = 0.92;
  } else if (hasAny(folded, HYDRAFACIAL_POSITIVE)) {
    family = 'hydrafacial';
    canonical = 'hydrafacial';
    confidence = 0.94;
  } else if (hasAny(folded, MICRONEEDLING_POSITIVE)) {
    family = 'microneedling';
    canonical = 'microneedling';
    confidence = 0.92;
  } else if (hasAny(folded, HIFU_POSITIVE)) {
    family = 'hifu';
    canonical = 'hifu';
    confidence = 0.92;
  } else if (hasAny(folded, LASER_POSITIVE) || folded.includes('pico laser') ||
      folded.includes('picosecond')) {
    family = 'laser';
    canonical = (folded.includes('pico')) ? 'pico_laser' : 'laser';
    confidence = 0.9;
  } else if (hasAny(folded, PEEL_POSITIVE)) {
    family = 'peel';
    canonical = 'chemical_peel';
    confidence = 0.9;
  } else if (hasAny(folded, RHINO_SURGERY)) {
    family = 'rhinoplasty';
    canonical = 'rhinoplasty';
    confidence = 0.92;
  } else if (hasAny(folded, BREAST_AUG)) {
    family = 'breast_augmentation';
    canonical = 'breast_augmentation';
    confidence = 0.92;
  } else if (hasAny(folded, HAIR_TX)) {
    family = 'hair_transplant';
    canonical = 'hair_transplant';
    confidence = 0.9;
  }

  if (requested && requested !== 'other' && family !== 'other' &&
      !familiesCompatible(requested, family)) {
    console.log(`[MATCH] REJECT "${rawLabel}" → wrong_family_${family}`);
    return {family, canonical, confidence: 0, rejectReason: `wrong_family_${family}`};
  }
  if (family !== 'other') {
    console.log(`[MATCH] "${rawLabel}" → ${family}/${canonical}`);
  }
  return {family, canonical, confidence, rejectReason: ''};
}

function catalogAggregateRange(row) {
  const min = Number(row && row.priceMin) || 0;
  const max = Number(row && row.priceMax) || 0;
  const method = String((row && row.extractionMethod) || '');
  const jsonLd = method === 'jsonLd' || method === 'json_ld' ||
      method === 'schemaOffer' || method === 'schema_offer';
  const factor = jsonLd ? 3 : 4;
  if (min > 0 && max >= min * factor) return true;
  if (!jsonLd) return false;
  const raw = String((row && row.rawPriceText) || '').replace(/\u00a0/g, ' ');
  const m = raw.match(/(\d+(?:[.,]\d{3})*)\s*[–—-]\s*(\d+(?:[.,]\d{3})*)/);
  if (!m) return false;
  const parse = (s) => Number(String(s).replace(/[.\s]/g, '').replace(',', '.')) || 0;
  const low = parse(m[1]);
  const high = parse(m[2]);
  return low > 0 && high >= low * 3;
}

function menuRowScoreBoost(method) {
  const m = String(method || '');
  if (m === 'html_table' || m === 'list_item' || m === 'woocommerce' ||
      m === 'product_card') return 0.12;
  if (m === 'jsonLd' || m === 'schemaOffer') return -0.05;
  if (m === 'text_proximity') return -0.1;
  return 0;
}

function selectEvidenceForProcedure(rows, procedure) {
  let best = null;
  let bestScore = -1;
  const want = requestedFamily(procedure);
  const pageHasFamilyWitness = pageHasRequestedFamilyWitness(rows, procedure);
  for (const row of rows || []) {
    if (!row || !(row.priceMin > 0) || !String(row.rawPriceText || '').trim()) continue;
    if (exploreUrlConflictsWithProcedure(row.sourceUrl, procedure)) {
      console.log('[GP PRICE] REJECT · wrong_page_family');
      continue;
    }
    if (catalogAggregateRange(row)) {
      console.log('[GP PRICE] REJECT · catalog_aggregate_range');
      continue;
    }
    if (looksLikeRoundedMarketPriceSpread({
      priceMin: row.priceMin,
      priceMax: row.priceMax,
      currency: row.currency,
      procedure,
    })) {
      console.log('[GP PRICE] REJECT · market_price_spread');
      continue;
    }
    if (looksLikeClinicArticlePriceUrl(row.sourceUrl) &&
        evidenceQuotesPriceRange(row)) {
      console.log('[GP PRICE] REJECT · article_price_range');
      continue;
    }
    if (looksLikeMarketEstimateDirectoryUrl(row.sourceUrl)) {
      console.log('[GP PRICE] REJECT · market_information');
      continue;
    }
    if (looksLikeThirdPartyProviderPriceLabel(row.rawProcedureText) ||
        looksLikeCompetitorOrThirdPartyPriceQuote(
            `${row.rawPriceText || ''}\n${row.rawEvidence || ''}`) ||
        looksLikeCompetitorOrThirdPartyPriceQuote(row.rawPriceText)) {
      console.log('[GP PRICE] REJECT · competitor_quote');
      continue;
    }
    if (looksLikePriceMenuHeadingOnly(row.rawProcedureText)) {
      console.log('[GP PRICE] REJECT · menu_heading_not_row');
      continue;
    }
    const ownQuoted = looksLikePrimaryRhinoplastyStarting(row.rawProcedureText) ||
        /html_table/.test(String(row.extractionMethod || ''));
    const lock = lockPriceEvidence({
      candidate: row,
      procedure,
      sourceHtmlOrText: `${row.rawEvidence || ''}\n${row.rawPriceText || ''}`,
      pageHasFamilyWitness,
      clinicOwnQuoted: ownQuoted,
    });
    if (!lock.accepted) continue;
    const relation = lock.relation;

    const match = matchRawProcedureLabel(row.rawProcedureText, procedure);
    if (match.rejectReason) {
      console.log('[GP PRICE] REJECT · wrong_procedure');
      continue;
    }
    let family = match.family || 'other';
    let canonical = match.canonical || '';
    let confidence = match.confidence || 0;
    // Area-only labels inherit family when relation already passed.
    if (want !== 'other' && family === 'other') {
      const inheritAreaOnly = want === 'botox' || want === 'filler';
      if (relation && relation.eligible &&
          (!inheritAreaOnly ||
              looksLikeInheritableAreaOnlyLabel(row.rawProcedureText, want))) {
        family = want;
        canonical = want === 'filler' && /\blips?\b/i.test(row.rawProcedureText)
          ? 'lip_filler'
          : want;
        confidence = 0.72;
        console.log(
            `[GP MATCH] inherit_family_${want} "${row.rawProcedureText}" ` +
            `via ${relation.reason || relation.logToken}`);
      } else {
        console.log(
            `[GP PRICE] REJECT · no_family_match "${row.rawProcedureText}"`);
        continue;
      }
    }
    if (!isValidExtractedPriceCandidate({
      rawPriceText: row.rawPriceText,
      priceMin: row.priceMin,
      currency: row.currency,
      extractionMethod: row.extractionMethod,
      rawEvidence: row.rawEvidence,
      procedure,
      sourceUrl: row.sourceUrl,
    })) continue;
    let score = confidence;
    if (row.extractionMethod !== 'text_proximity') score += 0.2;
    score += menuRowScoreBoost(row.extractionMethod);
    if (row.priceType === 'from') score += 0.05;
    if (want === 'filler' && canonical === 'lip_filler') {
      score += 0.35;
    }
    const foldedLabel = fold(row.rawProcedureText);
    if (/your\s+saving|you\s+save|\bsaving\b/.test(foldedLabel)) {
      console.log('[GP PRICE] REJECT · promo_saving');
      continue;
    }
    if (want === 'laser') {
      if (!laserRowFitsRequest(row.rawProcedureText, procedure)) {
        console.log('[GP PRICE] REJECT · laser_subtype_or_generic');
        continue;
      }
      if (laserRowSubtype(row.rawProcedureText) !== 'generic') score += 0.18;
    }
    if (want === 'botox') {
      const oneZone = /\b1\s*zon|\buna\s*zona|\bperiocular|\bglabel|\bfrontal|\bfrunte\b|\bcrow|\bcoada och/.test(foldedLabel);
      const multiZone = /\b[2-4]\s*zon|\bfull face|\b3 zone|\bbaby botox/.test(foldedLabel);
      if (oneZone && !multiZone) score += 0.3;
      if (/\b(?:1|one)\s*area\b/.test(foldedLabel)) score += 0.35;
      const quoteFold = fold(row.rawPriceText || '');
      if (/when added to another|targeted areas|higher[- ]dosage supplement/i.test(quoteFold) &&
          !/\b(?:1|one|single)\s*area\b/.test(foldedLabel)) {
        console.log('[GP PRICE] REJECT · botox_addon_or_targeted');
        continue;
      }
      if (/chin\s*dimpl|pebbled\s*chin|mentalis|down[- ]?turned|mouth\s*corner|lip[- ]?flip|gummy\s*smile|bunny\s*line|jawline\s*lift|masseter|trap[- ]?tox|barbie|trapezius|fine\s+under[- ]?eye|calf\s*reduction|hyperhidros|migraine|chemical\s*brow|neck\s*lift/.test(`${foldedLabel} ${quoteFold} ${fold(row.rawEvidence || '')} ${fold(row.sourceUrl || '')}`) &&
          !/\b(?:1|one|single)\s*area\b/.test(foldedLabel)) {
        console.log('[GP PRICE] REJECT · specialty_botox');
        continue;
      }
      if (looksLikeBotoxSpecialtyVariantUrl(row.sourceUrl) &&
          !/\b(?:1|one|single)\s*area\b|upper[- ]?face/.test(foldedLabel)) {
        console.log('[GP PRICE] REJECT · specialty_botox');
        continue;
      }
      if (/gummy|gingival|zambet gingival|brux|hiperhidroz|hyperhidros|platism|masseter|slimming face|cicatrici/.test(foldedLabel)) {
        score -= 0.45;
      }
      // Mirrors the Dart selector: Dysport/Xeomin units are not Botox units
      // (roughly 2.5-3 Dysport units per Botox unit), so a cheaper alternative
      // brand must not undercut a Botox row when the user asked for Botox by
      // name. A demotion, not a reject — a clinic listing only Dysport still
      // quotes it.
      const altBrand =
          /\bdysport\b|\bxeomin\b|\bazzalure\b|\bvistabel\b|\bjeuveau\b|\bbocouture\b|\bdaxxify\b|\bnuceiva\b|\bletybo\b|\brelfydess\b/;
      const botoxByName = /\bbotox\b|\bbotulinum\b/;
      if (botoxByName.test(fold(procedure)) &&
          altBrand.test(foldedLabel) && !botoxByName.test(foldedLabel)) {
        score -= 0.5;
      }
    }
    if (want === 'peel') {
      const peelBlob = `${foldedLabel} ${row.rawPriceText || ''} ${row.rawEvidence || ''}`;
      if (looksLikeMultiSessionSeriesQuote(peelBlob)) {
        console.log('[GP PRICE] REJECT · peel_series_package');
        continue;
      }
      if (looksLikeDepigmentationPeelPackage(peelBlob)) {
        score -= 0.85;
      } else if (/chemical peel|skin peel|glycolic|mandelic|salicylic|\btca\b|\b(?:1|one|single)\s*session\b/i.test(foldedLabel)) {
        score += 0.32;
      }
    }
    if (want === 'rhinoplasty') {
      const blob = `${foldedLabel} ${fold(row.rawPriceText)} ${fold(row.rawEvidence)}`;
      if (looksLikeCityMarketPricingGuideUrl(row.sourceUrl)) {
        console.log('[GP PRICE] REJECT · rhino_market_guide');
        continue;
      }
      if (/non[- ]?surgical|nonsurgical|liquid rhino|nose filler|cheaper alternative/.test(blob) &&
          row.priceMin < 2500) {
        console.log('[GP PRICE] REJECT · nonsurgical_rhino');
        continue;
      }
      const tipOrPartial = looksLikePartialRhinoplastyStarting(foldedLabel) ||
          (looksLikePartialRhinoplastyStarting(blob) &&
              row.priceMin < 6000 &&
              !looksLikePrimaryRhinoplastyStarting(foldedLabel));
      if (tipOrPartial) {
        console.log('[GP PRICE] REJECT · rhino_tip_or_partial');
        continue;
      }
      if (looksLikePatientAnecdotePrice(blob)) {
        console.log('[GP PRICE] REJECT · patient_anecdote');
        continue;
      }
      if (looksLikeOfficialPriceListUrl(row.sourceUrl) &&
          /text_proximity|dom_block/.test(String(row.extractionMethod || '')) &&
          /\bmale\s+(?:nose|rhino)|\ba male nose|\brhinoplasty\s+for\s+men/.test(blob)) {
        console.log('[GP PRICE] REJECT · rhino_male_landing');
        continue;
      }
      if (looksLikePrimaryRhinoplastyStarting(foldedLabel) ||
          looksLikePrimaryRhinoplastyStarting(row.rawPriceText)) {
        score += 0.48;
      }
      if (/\bmale\s+(?:nose|rhino)|rhinoplasty\s+for\s+men|\bfor men\b|\ba male nose/.test(blob)) {
        score -= 0.4;
      }
      if (looksLikeClinicArticlePriceUrl(row.sourceUrl) ||
          /\/for-men\/|\/for-women\//.test(String(row.sourceUrl || '').toLowerCase())) {
        score -= 0.45;
      }
      const year = explorePublishedOrReviewedYear(
          `${row.rawEvidence || ''}\n${row.rawPriceText || ''}`);
      if (year >= 2026) score += 0.35;
      if (year > 0 && year <= 2024) score -= 0.25;
      if (looksLikeOfficialPriceListUrl(row.sourceUrl)) score += 0.2;
      if (/\bultrasonic\b|\bpiezo\b|\bpreservation\s+rhino/.test(foldedLabel) &&
          !looksLikePrimaryRhinoplastyStarting(foldedLabel)) {
        score -= 0.35;
      }
    }
    if (want === 'breast_augmentation' || want === 'breast') {
      if (looksLikeFinancingOrPaymentHeading(row.rawProcedureText) ||
          looksLikeFinancingOrPaymentHeading(foldedLabel)) {
        console.log('[GP PRICE] REJECT · financing_heading');
        continue;
      }
      if (looksLikeUnilateralBreastStartingRow(foldedLabel) ||
          looksLikeUnilateralBreastStartingRow(row.rawProcedureText)) {
        console.log('[GP PRICE] REJECT · breast_unilateral');
        continue;
      }
      if (looksLikeBreastAugmentationAddOnRow(foldedLabel) ||
          looksLikeBreastAugmentationAddOnRow(row.rawProcedureText)) {
        console.log('[GP PRICE] REJECT · breast_addon_or_areola');
        continue;
      }
      if (/\binverted nipple\b|\bnipple (?:lift|reduction|correction)\b/.test(foldedLabel) &&
          !/augment|enlargement|implant|memorygel|boob job/.test(foldedLabel)) {
        console.log('[GP PRICE] REJECT · breast_nipple_only');
        continue;
      }
      if (/\bbreast augmentation\b|\bboob job\b|\benlargement\b|\bmemorygel\b/.test(foldedLabel) &&
          !/unilateral|lift|mastopex|reduction/.test(foldedLabel)) {
        score += 0.28;
      }
    }
    if (want === 'hair') {
      const hairBlob = `${foldedLabel} ${fold(row.rawPriceText || '')} ${fold(row.rawEvidence || '')}`;
      if (looksLikeGraftOrFollicleQuantity(row.rawPriceText) ||
          looksLikeGraftCountMistakenForPrice({
            priceMin: row.priceMin,
            blob: `${row.rawProcedureText || ''} ${row.rawPriceText || ''} ${row.rawEvidence || ''}`,
          })) {
        console.log('[GP PRICE] REJECT · graft_count');
        continue;
      }
      if (looksLikeEffectivePerGraftMarketing(hairBlob) ||
          looksLikeEffectivePerGraftMarketing(row.rawPriceText) ||
          looksLikeEffectivePerGraftMarketing(row.rawProcedureText)) {
        console.log('[GP PRICE] REJECT · effective_per_graft');
        continue;
      }
      if (looksLikeHairMarketPerGraftBlurb(hairBlob) ||
          looksLikeHairMarketPerGraftBlurb(row.rawPriceText)) {
        console.log('[GP PRICE] REJECT · hair_market_per_graft');
        continue;
      }
      if (looksLikeHairFutWhenFueRequested({
        procedure, blob: hairBlob,
      })) {
        console.log('[GP PRICE] REJECT · hair_fut_not_fue');
        continue;
      }
      if (looksLikeHairDhiWhenFueRequested({procedure, blob: hairBlob})) {
        console.log('[GP PRICE] REJECT · hair_dhi_not_fue');
        continue;
      }
      if (looksLikeHairMarketComparisonRow(hairBlob) ||
          looksLikeHairMarketComparisonRow(foldedLabel)) {
        console.log('[GP PRICE] REJECT · hair_market_comparison');
        continue;
      }
      if (looksLikeHairLargerThanStartingPackage(hairBlob) ||
          looksLikeHairLargerThanStartingPackage(foldedLabel)) {
        console.log('[GP PRICE] REJECT · hair_larger_package');
        continue;
      }
      if (looksLikeHairStaleLandingQuote({
        sourceUrl: row.sourceUrl,
        blob: hairBlob,
        priceMin: row.priceMin,
        priceMax: row.priceMax,
      })) {
        console.log('[GP PRICE] REJECT · hair_stale_landing');
        continue;
      }
      if (looksLikeCityCostArticleUrl(row.sourceUrl) ||
          looksLikeClinicArticlePriceUrl(row.sourceUrl) ||
          isNonLiteralClinicPriceUrl(row.sourceUrl)) {
        console.log('[GP PRICE] REJECT · hair_city_guide');
        continue;
      }
      if (looksLikeHairNonStartingRow(foldedLabel) &&
          !/\bfue\b|\bdhi\b|\bsapphire\b/.test(foldedLabel)) {
        console.log('[GP PRICE] REJECT · hair_addon_or_consult');
        continue;
      }
      const perGraft = looksLikePerGraftQuotedPrice(hairBlob) ||
          looksLikePerGraftQuotedPrice(row.rawPriceText);
      if (perGraft && row.priceMin > hairPerGraftPlausibleMax(row.currency)) {
        console.log('[GP PRICE] REJECT · implausible_per_graft');
        continue;
      }
      if (looksLikeUnshavenHairVariant(foldedLabel)) score -= 0.45;
      if (/\bmin(?:imum)?\s+fee\b/.test(hairBlob)) score += 0.38;
      if (looksLikeHairStartingPackageRow(foldedLabel) ||
          looksLikeHairStartingPackageRow(hairBlob)) {
        score += 0.5;
      }
      if (looksLikeOfficialPriceListUrl(row.sourceUrl)) score += 0.42;
      if (/\bbarb|\bbeard|\bsprancean|\beyebrow/.test(foldedLabel)) score -= 0.4;
      if (/\bscalp|\bcapil|\bfue|\bdhi|\bsapphire|\bgraft|\bfir cu fir/.test(foldedLabel)) {
        score += 0.2;
      }
      if (perGraft) score -= 0.55;
      else if (row.priceType === 'from' || row.priceType === 'fixed') score += 0.42;
    }
    if (/\boferta|\boferta especial|\bflash\b|\bpromo\b/.test(foldedLabel)) {
      score -= 0.22;
    }
    const cheaperIsPartial = (want === 'rhinoplasty' &&
        (looksLikePartialRhinoplastyStarting(foldedLabel) ||
            looksLikeClinicArticlePriceUrl(row.sourceUrl) ||
            (best && /html_table|list_item|woocommerce|product_card/.test(best.extractionMethod || '') &&
                /text_proximity|dom_block/.test(row.extractionMethod || '')))) ||
        ((want === 'breast_augmentation' || want === 'breast') &&
            /\bunilateral\b/.test(foldedLabel));
    const cheaperLosesToOneArea = want === 'botox' && best &&
        /\b(?:1|one|single)\s*area\b/.test(fold(best.rawProcedureText || '')) &&
        !/\b(?:1|one|single)\s*area\b/.test(foldedLabel);
    const cheaperLosesToHairPackage = want === 'hair' && best &&
        !looksLikePerGraftQuotedPrice(
            `${best.rawProcedureText || ''} ${best.rawPriceText || ''} ${best.rawEvidence || ''}`) &&
        best.priceMin >= 800 &&
        (looksLikePerGraftQuotedPrice(
            `${row.rawProcedureText || ''} ${row.rawPriceText || ''} ${row.rawEvidence || ''}`) ||
            looksLikeEffectivePerGraftMarketing(
                `${row.rawProcedureText || ''} ${row.rawPriceText || ''}`));
    if (!best || score > bestScore ||
        (score === bestScore && row.priceMin < best.priceMin &&
            !cheaperIsPartial && !cheaperLosesToOneArea &&
            !cheaperLosesToHairPackage)) {
      best = {
        ...row,
        procedureFamily: family,
        procedureCanonical: canonical,
        procedureRelation: relation ? relation.logToken : '',
      };
      bestScore = score;
    }
  }
  if (best && want === 'hair') {
    const pageBlob = (rows || []).map((r) =>
        `${r.rawProcedureText || ''}\n${r.rawPriceText || ''}\n${r.rawEvidence || ''}`).join('\n');
    const fee = exploreMandatoryPackageAddOnFee(pageBlob);
    const already = hairRowIncludesMandatoryAddOnFee(
        `${best.rawProcedureText || ''}\n${best.rawPriceText || ''}\n${best.rawEvidence || ''}`);
    if (fee && !already && best.priceMin > fee * 4 && best.priceMin < 20000) {
      best = {...best, priceMin: best.priceMin + fee};
    }
  }
  if (best) {
    console.log(
        `[GP PRICE] PICK · "${best.rawProcedureText}" · ` +
        `${Math.round(best.priceMin)} ${best.currency || ''} · ` +
        `${best.extractionMethod || ''} · ${best.sourceUrl || ''}`);
    logPriceSource(best.extractionMethod || 'html', best.sourceUrl || '');
    logPriceAccept({
      clinic: '',
      procedure,
      evidence: best,
      relation: {logToken: best.procedureRelation || 'exact'},
    });
  }
  return best;
}

function exploreCachedPriceNeedsReselect({
  rawProcedureText, brand, sourceUrl, procedure,
  rawPriceText = '', priceMin = 0, priceMax = 0, currency = '',
}) {
  if (isNonLiteralClinicPriceUrl(sourceUrl)) return true;
  if (exploreUrlConflictsWithProcedure(sourceUrl, procedure)) return true;
  if (looksLikeShopifyThemeDummyPrice({
    rawPriceText, priceMin, currency, procedure: rawProcedureText,
  }) || looksLikeUsdQuotedOnUkHost({
    sourceUrl, currency, rawPriceText,
  })) {
    return true;
  }
  if (catalogAggregateRange({rawPriceText, priceMin, priceMax})) return true;
  const want = requestedFamily(procedure);
  if (want !== 'other' &&
      (competingFamilyRejectReason(rawProcedureText || brand, want) ||
          competingFamilyRejectReason(sourceUrl, want))) {
    return true;
  }
  if ((want === 'botox' || want === 'filler') &&
      (looksLikeEnergyOrDeviceTreatment(rawProcedureText || brand) ||
          looksLikeEnergyOrDeviceTreatment(sourceUrl) ||
          exploreUrlPathFamilyKey(sourceUrl) === 'energy_device')) {
    return true;
  }
  const raw = String(rawProcedureText || '').trim() || String(brand || '').trim();
  if (!raw) {
    return /beperfect\.ro|doctorskin\.ro|drestetix\.ro/.test(String(sourceUrl || ''));
  }
  const folded = fold(raw);
  if (/your\s+saving|you\s+save|\bsaving\b/.test(folded)) return true;
  if (looksLikeCompetitorOrThirdPartyPriceQuote(`${raw}\n${rawPriceText}`) ||
      looksLikeThirdPartyProviderPriceLabel(raw)) {
    return true;
  }
  if (want === 'botox' && looksLikeCityCostArticleUrl(sourceUrl)) return true;
  if (want === 'botox' &&
      /^(?:botox|anti[- ]?wrinkle)(?:\s+(?:treatment|treatments|injections?|injectables?))?$/.test(folded.trim())) {
    return true;
  }
  if (want === 'botox' &&
      /chin\s*dimpl|pebbled\s*chin|mentalis|down[- ]?turned|mouth\s*corner|lip[- ]?flip|gummy\s*smile|bunny\s*line|jawline\s*lift|masseter|trap[- ]?tox|barbie|trapezius|fine\s+under[- ]?eye|calf\s*reduction|hyperhidros|migraine/.test(`${folded} ${fold(rawPriceText)} ${fold(sourceUrl)}`) &&
      !/\b(?:1|one|single)\s*area\b|upper[- ]?face/.test(folded)) {
    return true;
  }
  if (want === 'botox' && looksLikeBotoxSpecialtyVariantUrl(sourceUrl) &&
      !/\b(?:1|one|single)\s*area\b|upper[- ]?face/.test(folded)) {
    return true;
  }
  if (want === 'hair' &&
      (looksLikeGraftOrFollicleQuantity(rawPriceText) ||
          looksLikeGraftCountMistakenForPrice({
            priceMin,
            blob: `${raw}\n${rawPriceText}`,
          }) ||
          looksLikeEffectivePerGraftMarketing(`${raw}\n${rawPriceText}`) ||
          looksLikeHairMarketPerGraftBlurb(`${raw}\n${rawPriceText}`) ||
          looksLikeHairFutWhenFueRequested({
            procedure, blob: `${raw}\n${rawPriceText}`,
          }) ||
          looksLikeHairDhiWhenFueRequested({
            procedure, blob: `${raw}\n${rawPriceText}`,
          }) ||
          looksLikeHairMarketComparisonRow(`${raw}\n${rawPriceText}`) ||
          looksLikeHairLargerThanStartingPackage(`${raw}\n${rawPriceText}`) ||
          looksLikeHairCachedNonStartingPackageFrom({
            sourceUrl, blob: `${raw}\n${rawPriceText}`, priceMin,
          }) ||
          looksLikeHairStaleLandingQuote({
            sourceUrl, blob: `${raw}\n${rawPriceText}`,
            priceMin, priceMax,
          }) ||
          looksLikeCityCostArticleUrl(sourceUrl) ||
          looksLikeClinicArticlePriceUrl(sourceUrl) ||
          looksLikeHairNonStartingRow(raw) ||
          (looksLikePerGraftQuotedPrice(`${raw}\n${rawPriceText}`) &&
              priceMin > hairPerGraftPlausibleMax(currency)))) {
    return true;
  }
  if (want === 'peel' &&
      (looksLikeDepigmentationPeelPackage(`${raw}\n${rawPriceText}`) ||
          looksLikeMultiSessionSeriesQuote(`${raw}\n${rawPriceText}`)) &&
      !/\/(?:price-list|pricelist|prices|pricing|preturi)(?:\/|$)/i.test(String(sourceUrl || ''))) {
    return true;
  }
  if (want === 'rhinoplasty') {
    if (/non[- ]?surgical|nonsurgical|liquid rhino|cheaper alternative/.test(
        `${folded} ${fold(rawPriceText)}`) && priceMin > 0 && priceMin < 2500) {
      return true;
    }
    if (looksLikePartialRhinoplastyStarting(folded) ||
        (looksLikePartialRhinoplastyStarting(`${folded} ${fold(rawPriceText)}`) &&
            priceMin > 0 && priceMin < 6000)) {
      return true;
    }
    if (looksLikePatientAnecdotePrice(`${folded} ${rawPriceText}`)) return true;
    if (looksLikeCityMarketPricingGuideUrl(sourceUrl) ||
        isNonLiteralClinicPriceUrl(sourceUrl)) {
      return true;
    }
    if (looksLikeClinicArticlePriceUrl(sourceUrl) &&
        priceMin > 0 && priceMin < 7500) {
      return true;
    }
    if (priceMin > 0 && priceMin < 7500 &&
        /rhinoplasty-cost/i.test(String(sourceUrl || '')) &&
        !/price-guide|price-list|pricelist/i.test(String(sourceUrl || ''))) {
      return true;
    }
  }
  if ((want === 'breast_augmentation' || want === 'breast') &&
      (looksLikeFinancingOrPaymentHeading(raw) ||
          looksLikeUnilateralBreastStartingRow(raw) ||
          looksLikeSeoCostPageHeading(raw) ||
          looksLikeComplicationOrAftercareHeading(raw))) {
    return true;
  }
  if (looksLikeRoundedMarketPriceSpread({
    priceMin, priceMax, currency, procedure,
  })) {
    return true;
  }
  const curr = String(currency || '').trim().toUpperCase();
  if ((want === 'breast_augmentation' || want === 'breast') &&
      priceMin > 0 && priceMin < 4000 && (curr === 'GBP' || curr === '£')) {
    return true;
  }
  if (want === 'laser' && !laserRowFitsRequest(raw, procedure)) return true;
  const match = matchRawProcedureLabel(raw, procedure);
  if (match.rejectReason) return true;
  if (want !== 'other' && match.family !== 'other' && !familiesCompatible(want, match.family)) {
    return true;
  }
  if (want !== 'other' && match.family === 'other') return true;
  return false;
}

module.exports = {
  matchRawProcedureLabel,
  selectEvidenceForProcedure,
  requestedFamily,
  competingFamilyRejectReason,
  exploreCachedPriceNeedsReselect,
  laserRequestedSubtype,
  laserRowSubtype,
  laserRowFitsRequest,
};
