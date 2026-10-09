'use strict';

const MARKETPLACE_EXACT_HOSTS = [
  'clinicpoint.com', 'whatclinic.com', 'bookimed.com',
  'qunomedical.com', 'treatwell.com', 'groupon.com', 'groupon.es',
  'doctoralia.es', 'doctoralia.com', 'topdoctors.es', 'topdoctors.com',
  'saludestetica.com',   'estheticon.com', 'fresha.com', 'booksy.com', 'studio24.bg',
  'medigence.com', 'mediglobus.com', 'salonsindubai.ae', 'getclearbeauty.com',
  'trueclinic.com', 'mymeditravel.com',
  'placidway.com', 'doktortakvimi.com',
  'turkeymedicals.com', 'turkeybeautyguide.com', 'healthyturkiye.com',
  'medicaltravelcost.com', 'clinicbooking.com', 'turkeyluxuryclinics.com',
  'medifyr.com', 'trendyol.com',
  // Delivery / classifieds — breast-pump SERP noise.
  'wolt.com', 'merrjep.al', 'merrjep.com', 'glovoapp.com', 'glovo.com',
  'bolt.eu', 'food.bolt.eu', 'ubereats.com', 'olx.al', 'olx.com',
  'njoftime.com',
];

const MARKETPLACE_HOST_NEEDLES = [
  'clinicpoint.', 'whatclinic.', 'bookimed.', 'qunomedical.',
  'treatwell.', 'groupon.', 'doctoralia.', 'topdoctors.',
  'saludestetica.', 'estheticon.', 'fresha.', 'booksy.', 'studio24.',
  'medigence.', 'mediglobus.', 'salonsindubai.', 'getclearbeauty.',
  'trueclinic.', 'mymeditravel.',
  'placidway.', 'doktortakvimi.',
  'turkeymedicals.', 'turkeybeautyguide.', 'healthyturkiye.',
  'medicaltravelcost.', 'clinicbooking.', 'turkeyluxuryclinics.',
  'medifyr.', 'trendyol.',
  'wolt.', 'merrjep.', 'glovo', 'ubereats.', 'olx.', 'njoftime.',
];

const MARKETPLACE_BRAND_TOKENS = [
  'clinicpoint', 'whatclinic', 'bookimed', 'qunomedical', 'treatwell',
  'groupon', 'doctoralia', 'topdoctors', 'top doctors', 'saludestetica',
  'salud estetica', 'estheticon', 'fresha', 'booksy',
  'studio24', 'studio 24',
  'medigence', 'mediglobus', 'medi globus',
  'salonsindubai', 'salons in dubai',
  'getclearbeauty', 'get clear beauty',
  'trueclinic', 'mymeditravel', 'placidway', 'doktortakvimi',
  'turkeymedicals', 'turkeybeautyguide', 'turkey beauty guide',
  'healthyturkiye', 'healthy turkiye',
  'medicaltravelcost', 'medical travel cost',
  'clinicbooking', 'clinic booking', 'turkeyluxuryclinics',
  'medifyr', 'trendyol',
];

const NON_AESTHETIC_MARKETPLACE_CATEGORIES = new Set([
  'barber-shop', 'barber', 'barbershop', 'hair-salon', 'nail-salon',
  'nails', 'makeup-artist', 'tattoo', 'tattoo-studio', 'pet-grooming',
]);

const GENERIC_SHOP_NAMES = [
  'tienda', 'shop', 'store', 'boutique', 'outlet',
  'the shop', 'the store', 'la tienda', 'el outlet',
];

const GENERIC_NAME_TOKENS = [
  'clinic', 'clinica', 'clinicas', 'clinics', 'aesthetic', 'esthetic',
  'estetic', 'estetica', 'medical', 'international', 'barcelona', 'madrid',
  'valencia', 'centre', 'center', 'centers', 'centres', 'hospital', 'spa',
  'and', 'the',
];

function normalizeHost(raw) {
  let h = String(raw || '').trim().toLowerCase();
  if (!h) return '';
  h = h.replace(/^https?:\/\//, '').replace(/^www\./, '');
  return h.split('/')[0].split(':')[0].split('?')[0].trim();
}

function isMarketplaceOrDirectoryHost(rawHost) {
  const h = normalizeHost(rawHost);
  if (!h) return false;
  if (MARKETPLACE_EXACT_HOSTS.includes(h)) return true;
  for (const exact of MARKETPLACE_EXACT_HOSTS) {
    if (h === exact || h.endsWith('.' + exact)) return true;
  }
  for (const needle of MARKETPLACE_HOST_NEEDLES) {
    if (h.includes(needle)) return true;
  }
  return false;
}

function looksLikeMarketEstimateDirectoryUrl(sourceUrl) {
  const h = normalizeHost(sourceUrl);
  if (!h) return false;
  const hosts = ['getclearbeauty.com'];
  const url = String(sourceUrl || '').toLowerCase();
  return hosts.some((exact) => h === exact || h.endsWith('.' + exact)) ||
      (/(?:^|[-/])(?:guia|guide)(?:[-/]|$)/.test(url) && /precio|price|cost/.test(url) &&
      !/\/(?:price|pricing|precio|precios)[-_](?:guide|guia)\/?(?:[?#].*)?$/.test(url));
}

function marketplacePlatformLabel(rawHostOrName) {
  const host = normalizeHost(rawHostOrName);
  const packed = packedCanonicalClinicName(rawHostOrName);
  const labels = {
    clinicpoint: 'ClinicPoint',
    whatclinic: 'WhatClinic',
    bookimed: 'Bookimed',
    qunomedical: 'Qunomedical',
    treatwell: 'Treatwell',
    groupon: 'Groupon',
    doctoralia: 'Doctoralia',
    topdoctors: 'TopDoctors',
    saludestetica: 'SaludEstetica',
    estheticon: 'Estheticon',
    fresha: 'Fresha',
    booksy: 'Booksy',
    studio24: 'Studio24',
    medigence: 'MediGence',
    mediglobus: 'MediGlobus',
    salonsindubai: 'Salons in Dubai',
    getclearbeauty: 'Get Clear Beauty',
  };
  for (const [key, label] of Object.entries(labels)) {
    if (host.includes(key) || packed.includes(key)) return label;
  }
  return host || String(rawHostOrName || '').trim();
}

function foldIdentityText(raw) {
  return String(raw || '')
      .replace(/\u00a0/g, ' ')
      .trim()
      .toLowerCase()
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '');
}

function packedCanonicalClinicName(raw) {
  let packed = foldIdentityText(raw).replace(/[^a-z0-9]+/g, '');
  if (!packed) return '';
  let changed = true;
  while (changed) {
    changed = false;
    for (const token of GENERIC_NAME_TOKENS) {
      if (packed.length <= token.length + 3) continue;
      if (packed.startsWith(token)) {
        packed = packed.slice(token.length);
        changed = true;
      } else if (packed.endsWith(token)) {
        packed = packed.slice(0, -token.length);
        changed = true;
      }
    }
  }
  return packed;
}

function spacedCanonicalClinicName(raw) {
  const name = foldIdentityText(raw)
      .replace(/[^a-z0-9]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  const kept = name.split(' ').filter((p) => p && !GENERIC_NAME_TOKENS.includes(p));
  const spaced = kept.join(' ').trim();
  return spaced || name;
}

function isMarketplaceBrandName(name) {
  const spaced = spacedCanonicalClinicName(name);
  const packed = packedCanonicalClinicName(name);
  const folded = foldIdentityText(name).trim();
  if (MARKETPLACE_BRAND_TOKENS.includes(folded) ||
      MARKETPLACE_BRAND_TOKENS.includes(spaced) ||
      MARKETPLACE_BRAND_TOKENS.includes(packed)) {
    return true;
  }
  for (const token of MARKETPLACE_BRAND_TOKENS) {
    const compact = token.replace(/\s+/g, '');
    if (packed === compact) return true;
    if (folded === token || folded === token + '.com') return true;
  }
  return false;
}

function isGenericShopIdentity(name) {
  const folded = foldIdentityText(name)
      .replace(/[^a-z0-9 ]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  if (!folded) return true;
  if (GENERIC_SHOP_NAMES.includes(folded)) return true;
  const trivial = new Set([
    'the', 'el', 'la', 'de', 'del', 'online', 'oficial', 'official',
    'barcelona', 'madrid', 'valencia', 'shop', 'store', 'tienda',
    'boutique', 'outlet',
  ]);
  const meaningful = folded.split(' ').filter((t) => t && !trivial.has(t));
  if (!meaningful.length) return true;
  if (meaningful.length === 1 && GENERIC_SHOP_NAMES.includes(meaningful[0])) {
    return true;
  }
  return false;
}

function looksLikeNonAestheticVenueName(name) {
  const n = foldIdentityText(name)
      .replace(/[^a-z0-9 ]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  if (!n) return false;
  const medicalCue = [
    'clinic', 'clinica', 'clinique', 'aesthetic', 'esthetic', 'estetic',
    'cosmetic', 'plastic', 'dermat', 'botox', 'filler', 'inject',
    'medical', 'medspa', 'doctor', 'surgery', 'chirurgie',
  ];
  const hasMedicalCue = medicalCue.some((cue) => n.includes(cue));
  if (/\b(barber|barbershop|frizer|frizerie)\b/.test(n) && !hasMedicalCue) {
    return true;
  }
  if (/\b(nail salon|lash bar|lash lounge)\b/.test(n) && !hasMedicalCue) {
    return true;
  }
  if (/\bhair salon\b/.test(n) && !hasMedicalCue) return true;
  return false;
}

function titleCaseHyphenSlug(slug) {
  return String(slug || '')
      .split('-')
      .filter(Boolean)
      .map((w) => {
        const lo = w.toLowerCase();
        if (lo === 'md' || lo === 'pa' || lo === 'do') return lo.toUpperCase();
        return lo.charAt(0).toUpperCase() + lo.slice(1);
      })
      .join(' ');
}

function booksyListingMatch(sourceUrl) {
  const host = normalizeHost(sourceUrl);
  if (!host || !host.includes('booksy')) return null;
  let path = '';
  try {
    path = new URL(sourceUrl.includes('://') ? sourceUrl : 'https://' + sourceUrl).pathname;
  } catch (_) {
    return null;
  }
  const m = path.match(/\/(\d+)_([a-z0-9-]+)_([a-z0-9-]+)(?:_|\/|\?|$)/i);
  if (!m) return null;
  return {slug: m[2], category: String(m[3] || '').toLowerCase()};
}

function marketplaceListingBusinessNameFromUrl(sourceUrl) {
  const m = booksyListingMatch(sourceUrl);
  if (!m || !m.slug) return '';
  return titleCaseHyphenSlug(m.slug);
}

function marketplaceListingCategoryIsNonAesthetic(sourceUrl) {
  const m = booksyListingMatch(sourceUrl);
  if (!m) return false;
  return NON_AESTHETIC_MARKETPLACE_CATEGORIES.has(m.category);
}

function looksLikePriceQuotedClinicName(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  const lower = t.toLowerCase();
  if (/\b(cl[ií]nica|clinic|doctor|dra?\.?|hospital|centre|center|salon|medspa)\b/.test(lower)) {
    return false;
  }
  const money = /[$£€]|aed|usd|eur|gbp|ron|lei|\d/i.test(t);
  if (!money) return false;
  if (/^(?:cost|costs|price|prices|from|starting(?:\s+(?:at|from))?|starts\s+(?:at|from)|desde|de la)\b/i.test(t)) {
    return true;
  }
  return t.length <= 48 && /[$£€]\s*[\d.,]+/.test(t);
}

function clinicIdentityRejectReason(name, {
  websiteHost = '',
  providerClinic = '',
  sourceType = '',
} = {}) {
  const t = String(name || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return 'invalid_identity';
  const lower = t.toLowerCase();
  if (/^\d[\d.,\s]*\s*[€£$%]?\s*$/.test(t)) return 'invalid_identity';
  if (looksLikePriceQuotedClinicName(t)) return 'invalid_identity';
  if (/hasta un\s+\d+\s*%/.test(lower)) return 'invalid_identity';
  if (lower.includes('dto.') || lower.includes('dto ') || lower.endsWith('dto')) {
    if (!/\b(cl[ií]nica|clinic|doctor|dr\.?|centre|center)\b/.test(lower)) {
      return 'invalid_identity';
    }
  }
  if (/\b(oferta especial|special offer|best .+ prices?)\b/.test(lower)) {
    return 'invalid_identity';
  }
  if (/pre[tț]\s*20\d{2}/.test(lower)) return 'invalid_identity';
  if (/\b(precio|precios|price|prices|cost|costs|pret|preț|preturi|tarife|fiyat|fiyatı|fiyatları|fiyatlari|ücret|ucret)\b/.test(lower) &&
      !/\b(cl[ií]nica|clinic|doctor|hospital|centre|center|salon|klinik|hastane)\b/.test(lower)) {
    return 'invalid_identity';
  }
  if (/\b(botoks|botox|rinoplasti|burun estet|meme büyüt|meme buyut|dolgu)\b/i.test(lower) &&
      /\b(fiyat|ücret|ucret|20\d{2})\b/i.test(lower) &&
      !/\b(klinik|clinic|doctor|dr\.?|hastane)\b/i.test(lower)) {
    return 'invalid_identity';
  }
  if (/\b(botox|filler|labios|buze|peel|laser|rinoplast|hialuronic)\b/i.test(lower) &&
      /\b(desde|from|de la)\s*\d/.test(lower)) {
    return 'invalid_identity';
  }
  if (isGenericShopIdentity(t)) return 'generic_business_name';
  if (looksLikeNonAestheticVenueName(t)) return 'wrong_business_type';
  if (isMarketplaceBrandName(t)) return 'marketplace_without_provider';
  if (looksLikeMarketEstimateDirectoryUrl(websiteHost) ||
      looksLikeMarketEstimateDirectoryUrl(t)) {
    return 'market_estimate';
  }
  const host = normalizeHost(websiteHost);
  const publishers = ['elle.com', 'vogue.com', 'vogue.es', 'hola.com', 'telva.com',
    'cosmopolitan.com', 'harpersbazaar.com', 'nytimes.com', 'theguardian.com'];
  if (publishers.some((domain) => host === domain || host.endsWith('.' + domain))) {
    return 'non_clinic_content_host';
  }
  const marketplaceHost = host && isMarketplaceOrDirectoryHost(host);
  const provider = String(providerClinic || '').trim();
  const providerOk = provider &&
      !isMarketplaceBrandName(provider) &&
      !isGenericShopIdentity(provider) &&
      !looksLikeNonAestheticVenueName(provider);
  if (marketplaceHost && !providerOk) {
    return 'marketplace_without_provider';
  }
  if ((sourceType === 'marketplace' || sourceType === 'aggregator') &&
      !providerOk) {
    return 'marketplace_without_provider';
  }
  return null;
}

function isInvalidClinicIdentity(name) {
  return clinicIdentityRejectReason(name) != null;
}

function extractMarketplaceProviderName(html, {
  sourceUrl = '',
  marketplaceName = '',
} = {}) {
  const fromUrl = marketplaceListingBusinessNameFromUrl(sourceUrl);
  if (fromUrl) {
    if (marketplaceListingCategoryIsNonAesthetic(sourceUrl) ||
        looksLikeNonAestheticVenueName(fromUrl) ||
        clinicIdentityRejectReason(fromUrl)) {
      return '';
    }
    return fromUrl;
  }
  const raw = String(html || '').replace(/\s+/g, ' ');
  if (!raw.trim()) return '';
  const candidates = [];
  const consider = (value) => {
    const t = String(value || '').replace(/\s+/g, ' ').trim();
    if (t.length < 4 || t.length > 80) return;
    if (isMarketplaceBrandName(t) || isGenericShopIdentity(t)) return;
    if (clinicIdentityRejectReason(t)) return;
    if (!/\b(cl[ií]nica|clinic|doctor|dra?\.?|centro|centre|center|hospital)\b/i.test(t) &&
        t.split(' ').length < 2) {
      return;
    }
    candidates.push(t);
  };
  for (const m of raw.matchAll(
      /"(?:clinicName|clinic_name|providerName|provider_name|businessName)"\s*:\s*"([^"]{4,80})"/gi)) {
    consider(m[1]);
  }
  for (const m of raw.matchAll(/itemprop=["']name["'][^>]*>\s*([^<]{4,80})/gi)) {
    consider(m[1]);
  }
  for (const m of raw.matchAll(
      /(?:cl[ií]nica|clinic|doctor(?:a)?|dra?\.?)\s+[A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ'’.\-\s]{2,50}/g)) {
    consider(m[0]);
  }
  const seen = new Set();
  const filtered = [];
  for (const c of candidates) {
    const key = packedCanonicalClinicName(c);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    if (marketplaceName &&
        packedCanonicalClinicName(c) === packedCanonicalClinicName(marketplaceName)) {
      continue;
    }
    filtered.push(c);
  }
  if (!filtered.length) return '';
  filtered.sort((a, b) => b.length - a.length);
  return filtered[0].trim();
}

function namesLookLikeSameProvider(a, b) {
  const pa = packedCanonicalClinicName(a);
  const pb = packedCanonicalClinicName(b);
  if (!pa || !pb) return false;
  if (pa === pb) return true;
  if (pa.length >= 8 && pb.length >= 8 && (pa.includes(pb) || pb.includes(pa))) {
    return true;
  }
  return false;
}

function clinicMergeKey(row) {
  const pid = String((row && (row.place_id || row.placeId)) || '').trim();
  if (pid) return `id:${pid}`;
  const host = normalizeHost(
      (row && (row.price_source_url || row.sourceUrl || row.area)) || '');
  if (host && !isMarketplaceOrDirectoryHost(host)) return `host:${host}`;
  return `name:${packedCanonicalClinicName((row && row.name) || '')}`;
}

function sourceRank(row) {
  const status = String((row && row.price_verification_status) || '');
  const platform = String((row && row.source_platform) || '').toLowerCase();
  const sourceType = String((row && row.source_type) || '').toLowerCase();
  if (status === 'official_website') return 40;
  if (status === 'fresha_marketplace' || platform === 'fresha') return 30;
  if (status === 'booksy_marketplace' || platform === 'booksy') return 20;
  if (sourceType === 'marketplace' && row.marketplace_identity_verified === true) {
    return 25;
  }
  if (row && (row.verified === true || row.price_verified === true)) return 10;
  return 0;
}

function mergeClinicRecords(prev, next) {
  const a = prev && typeof prev === 'object' ? prev : {};
  const b = next && typeof next === 'object' ? next : {};
  const aMin = Number(a.price_min || a.priceMin || 0);
  const bMin = Number(b.price_min || b.priceMin || 0);
  const ra = sourceRank(a);
  const rb = sourceRank(b);
  let preferBPrice = false;
  if (bMin > 0 && aMin <= 0) preferBPrice = true;
  else if (bMin > 0 && aMin > 0) {
    if (rb !== ra) preferBPrice = rb > ra;
    else if (rb >= 20) preferBPrice = bMin < aMin; // same marketplace tier: FROM = lowest
    else {
      preferBPrice = String(b.lastCheckedAt || b.last_checked_at || '') >=
          String(a.lastCheckedAt || a.last_checked_at || '');
    }
  }
  const merged = {...a, ...b};
  merged.place_id = String(b.place_id || b.placeId || a.place_id || a.placeId || '');
  merged.placeId = merged.place_id;
  const aName = String(a.name || '');
  const bName = String(b.name || '');
  if (bName && !isMarketplaceBrandName(bName)) merged.name = bName;
  else if (aName && !isMarketplaceBrandName(aName)) merged.name = aName;
  merged.rating = Math.max(Number(b.rating || 0), Number(a.rating || 0));
  merged.reviews = Math.max(Number(b.reviews || 0), Number(a.reviews || 0));
  const aSite = String(a.price_source_url || a.sourceUrl || '');
  const bSite = String(b.price_source_url || b.sourceUrl || '');
  if (preferBPrice) {
    merged.price_min = b.price_min ?? b.priceMin ?? aMin;
    merged.price_max = b.price_max ?? b.priceMax ?? merged.price_min;
    merged.raw_price_text = b.raw_price_text || b.rawPriceText || a.raw_price_text;
    merged.rawPriceText = merged.raw_price_text;
    merged.currency = b.currency || a.currency;
    merged.price_source_url = b.price_source_url || b.sourceUrl || aSite;
    merged.sourceUrl = merged.price_source_url;
    merged.raw_procedure_text = b.raw_procedure_text || a.raw_procedure_text;
    merged.brand = b.brand || a.brand;
    merged.extraction_method = b.extraction_method || b.extractionMethod ||
        a.extraction_method;
    merged.price_verification_status = b.price_verification_status ||
        a.price_verification_status;
    merged.source_type = b.source_type || a.source_type;
    merged.source_platform = b.source_platform || a.source_platform;
    merged.verified = true;
    merged.price_verified = true;
  } else if (aMin > 0) {
    merged.price_min = a.price_min ?? a.priceMin;
    merged.raw_price_text = a.raw_price_text || a.rawPriceText;
    merged.rawPriceText = merged.raw_price_text;
    merged.currency = a.currency || b.currency;
    merged.price_source_url = a.price_source_url || a.sourceUrl || bSite;
    merged.sourceUrl = merged.price_source_url;
    merged.price_verification_status = a.price_verification_status ||
        b.price_verification_status;
    merged.source_type = a.source_type || b.source_type;
    merged.source_platform = a.source_platform || b.source_platform;
  }
  // Prefer official clinic website URL when available for navigation.
  if (bSite && !isMarketplaceOrDirectoryHost(bSite) && isMarketplaceOrDirectoryHost(aSite)) {
    merged.website = bSite;
  }
  if (merged.marketplace_identity_verified !== true) {
    merged.marketplace_identity_verified =
        a.marketplace_identity_verified === true ||
        b.marketplace_identity_verified === true;
  }
  return merged;
}

function looksLikeFinancingOrPaymentHeading(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim().toLowerCase();
  if (!t) return false;
  return /\bfinanc(?:e|ing|ial|iaci[oó]n)\b|\bmonthly payments?\b|\bpayment plans?\b|\b0\s*%\s*(?:apr|finance|interest)\b|\binstallments?\b|\bcuotas?\b|\bloan\b|\bhow to pay\b|\bpay monthly\b/i.test(t);
}

function looksLikeUnilateralBreastStartingRow(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').toLowerCase();
  if (!t.trim()) return false;
  return /\bunilateral\b|\bone[- ]breast\b|\bsingle[- ]breast\b/i.test(t);
}

function looksLikeComplicationOrAftercareHeading(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim().toLowerCase();
  if (!t) return false;
  return /\bpain following\b|\bfollowing .{0,48}(?:surgery|augmentation|enlargement|procedure)\b|\bside effects?\b|\b(?:recovery|aftercare)\b.{0,32}(?:after|following)\b|^(?:recovery|aftercare|complications?|side effects?|faqs?|frequently asked)\b|\bcomplications?\s+(?:of|after|following)\b/i.test(t);
}

function looksLikeSeoCostPageHeading(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  const lo = t.toLowerCase();
  if (/\bcosts?\s+from\b|\bprices?\s+from\b|\bfrom\s+[£$€]?\s*\d/i.test(lo)) {
    return false;
  }
  return /\b(?:breast|boob|enlargement|augmentation|implants?|surgery|procedure|rhinoplast|botox|filler|laser|peel|hair)\b.{0,48}\b(?:cost|costs|prices?|pricing)\s*$/i.test(lo);
}

function looksLikeCatalogSectionHeading(left) {
  const lo = String(left || '').replace(/\u00a0/g, ' ').trim().toLowerCase();
  if (!lo) return true;
  if (looksLikeFinancingOrPaymentHeading(lo)) return true;
  if (looksLikeComplicationOrAftercareHeading(lo)) return true;
  if (looksLikeSeoCostPageHeading(lo)) return true;
  if (/^(?:the )?price of the procedures?$|^(?:the )?cost of (?:the )?procedures?$|^(?:the )?cost of offered services$|^pretul procedurii$|^costul procedurii$/.test(lo.replace(/[^a-z0-9ăâîșț]+/g, ' ').trim())) {
    return true;
  }
  if (/^treatments?$/.test(lo)) return true;
  if (lo.includes('?') || lo.includes('؟')) return true;
  if (/^(how|what|why|when|where|which|is|are|does|do|can|c[aâ]t|cu[aá]nto)\b/i.test(lo)) {
    return true;
  }
  if (/dermatolog|dermatocosmetolog|estetic|chirurgie|ginecolog|injectabil|procedee|proceduri|\bprocedures\b|non[\s-]?invaz|non[\s-]?invas|lista\s+(de\s+)?pre[tț]|\bpre[tț]uri\b|\bprecios\b|\bprices\b|\bpricing\b|price list|\btarifas\b|\bmenu\b|\bmenú\b|tratamientos|quick facts|medical[aă]/i.test(lo)) {
    return true;
  }
  const letters = String(left || '').replace(/[^A-Za-zĂÂÎȘȚăâîșț]/g, '');
  return letters.length >= 10 && String(left) === String(left).toUpperCase();
}

function looksLikeHairGraftPackageMenuLabel(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t || t.length > 90 || /[?؟]/.test(t)) return false;
  return /\d[\d.,]*\s*(?:fue|fut|dhi|sapphire|micro[- ]?sapphire)?\s*-?\s*(?:grafts?|grafturi|follicles?|بصيلة|بصيلات)\b/i.test(t);
}

function looksLikeRawScrapedProcedureTitle(raw) {
  const t = String(raw || '').replace(/\u00a0/g, ' ').trim();
  if (!t) return false;
  if (looksLikeFinancingOrPaymentHeading(t)) return true;
  if (looksLikeComplicationOrAftercareHeading(t)) return true;
  if (looksLikeSeoCostPageHeading(t)) return true;
  if (/^(?:the )?price of the procedures?$|^(?:the )?cost of (?:the )?procedures?$|^(?:the )?cost of offered services$|^pretul procedurii$|^costul procedurii$/i.test(t.replace(/[^a-z0-9ăâîșț]+/gi, ' ').trim())) {
    return true;
  }
  if (t.endsWith('?') || t.endsWith('؟')) return true;
  if (/^(how|what|why|when|where|which|is|are|does|do|can|c[aâ]t|cu[aá]nto)\b/i.test(t)) {
    return true;
  }
  if (/^(كم|ما هو|ما هي|لماذا|هل)(\s|$)/.test(t)) return true;
  if (/\b(how much|what is the cost|c[aâ]t cost[aă]|cu[aá]nto cuesta|cat costa)\b/i.test(t) ||
      /(كم يكلف|كم تكلفة|كم سعر|ما هي تكلفة)/.test(t)) {
    return true;
  }
  if (/\bcost of\b/i.test(t) && !looksLikeHairGraftPackageMenuLabel(t)) {
    return true;
  }
  if (t.length > 70) return true;
  if (/\d{1,2}[/.\\-]\d{1,2}[/.\\-]\d{2,4}/.test(t)) return true;
  if (/\b(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|january|february|march|april|june|july|august|september|october|november|december)\b/i.test(t) &&
      /\d{4}/.test(t)) {
    return true;
  }
  if (/\b(opini[oó]n|review|comentario|hace\s+\d+|pinchazos|magia en)\b/i.test(t)) {
    return true;
  }
  const words = t.split(/\s+/);
  const hasProc = /\b(botox|filler|fillers|labios|lip|laser|peel|peeling|rinoplast|rhinoplast|hair|transplant|breast|boob|toxina|hyaluron|juvederm|restylane|dysport|chemical|buze|hialuron)\b/i.test(t) ||
      /(بوتوكس|فيلر|هيالورونيك|ليزر|تقشير|تجميل الانف|تجميل الأنف|تكبير الثدي|تكبير الصدر|زراعة الشعر)/.test(t);
  if (words.length >= 8 && !hasProc) return true;
  if (words.length >= 4 && !hasProc && /[.!?…]/.test(t)) return true;
  return false;
}

function logDiscoveryReject(reason, {placeId = '', name = ''} = {}) {
  console.log(`[GP DISCOVERY] reject=${reason} · placeId=${placeId} · name=${name}`);
}

/** Hard skip of a candidate already known for THIS procedure only. */
function logDiscoverySkip(reason, {placeId = '', name = '', procedure = ''} = {}) {
  const n = String(name || '').trim();
  const p = String(procedure || '').trim();
  if (n && p) {
    console.log(`[DISCOVERY SKIP] ${n} · ${p} · reason=${reason}`);
    return;
  }
  console.log(`[GP DISCOVERY] skip=${reason} · placeId=${placeId} · name=${name}`);
}

/**
 * Flutter sends current-procedure identity keys (`id:`, `host:`, `name:`).
 * Do not wrap prefixed keys as `name:…` — that would miss host/id matches.
 * Cross-pill sibling identities must not be sent here.
 */
function ingestExcludeClinicKeys(excludeKeys, seen) {
  const out = seen || new Set();
  const list = excludeKeys == null ? [] : excludeKeys;
  for (const raw of list) {
    const original = String(raw || '').trim();
    if (!original) continue;
    const key = original.toLowerCase();
    if (key.startsWith('id:') || key.startsWith('host:') || key.startsWith('name:')) {
      out.add(original);
      out.add(key);
    } else {
      out.add(`name:${key}`);
    }
  }
  return out;
}

/**
 * Booking/marketplace pages require a strong city match on address/URL/copy.
 * Peer-city conflict always fails. No clinic allowlists.
 */
function marketplaceLocationStronglyMatches({
  city,
  placeAddress = '',
  sourceUrl = '',
  pageText = '',
}) {
  const c = String(city || '').trim();
  if (!c) return false;
  const blob = `${placeAddress} ${sourceUrl} ${pageText}`.toLowerCase();
  const cityLo = c.toLowerCase();
  // Peer Gulf / GCC conflict heuristics (same spirit as Dart peer marks).
  const peers = [
    {key: 'dubai', aliases: ['dubai', 'دبي']},
    {key: 'abu dhabi', aliases: ['abu dhabi', 'abudhabi', 'abu-dhabi', 'أبوظبي']},
    {key: 'sharjah', aliases: ['sharjah']},
    {key: 'riyadh', aliases: ['riyadh']},
    {key: 'jeddah', aliases: ['jeddah']},
    {key: 'doha', aliases: ['doha']},
    {key: 'kuwait', aliases: ['kuwait']},
    {key: 'london', aliases: ['london']},
    {key: 'manchester', aliases: ['manchester']},
    {key: 'birmingham', aliases: ['birmingham']},
    {key: 'leeds', aliases: ['leeds']},
    {key: 'glasgow', aliases: ['glasgow']},
    {key: 'edinburgh', aliases: ['edinburgh']},
    {key: 'liverpool', aliases: ['liverpool']},
    {key: 'bristol', aliases: ['bristol']},
    {key: 'nottingham', aliases: ['nottingham', 'nottinghamshire']},
    {key: 'derby', aliases: ['derbyshire', 'derby', 'ripley']},
    {key: 'sheffield', aliases: ['sheffield']},
    {key: 'cardiff', aliases: ['cardiff']},
    {key: 'belfast', aliases: ['belfast']},
    {key: 'brighton', aliases: ['brighton']},
    {key: 'leicester', aliases: ['leicester']},
    {key: 'southampton', aliases: ['southampton']},
  ];
  const packedCity = cityLo.replace(/[\s_-]+/g, '');
  let searchKey = null;
  for (const p of peers) {
    if (cityLo.includes(p.key) || packedCity.includes(p.key.replace(/\s+/g, ''))) {
      searchKey = p.key;
      break;
    }
  }
  const mentions = (text, aliases) => {
    const lo = String(text || '').toLowerCase();
    const packed = lo.replace(/[\s_-]+/g, '');
    return aliases.some((a) => {
      const ap = String(a).toLowerCase().replace(/[\s_-]+/g, '');
      return lo.includes(String(a).toLowerCase()) ||
          (ap.length >= 4 && packed.includes(ap));
    });
  };
  if (searchKey) {
    for (const p of peers) {
      if (p.key === searchKey) continue;
      if (mentions(placeAddress, p.aliases) || mentions(sourceUrl, p.aliases)) {
        return false;
      }
      if (mentions(pageText, p.aliases) && !mentions(pageText, peers.find((x) => x.key === searchKey).aliases)) {
        return false;
      }
    }
  }
  const tokens = cityLo.split(/[^a-z0-9\u0600-\u06ff]+/).filter((t) => t.length >= 3);
  if (tokens.some((t) => blob.includes(t))) return true;
  if (searchKey) {
    const peer = peers.find((p) => p.key === searchKey);
    if (peer && mentions(blob, peer.aliases)) return true;
  }
  if (packedCity.length >= 5 && blob.replace(/[\s_-]+/g, '').includes(packedCity)) {
    return true;
  }
  return false;
}

function isInvalidClinicIdentityCompat(name) {
  return isInvalidClinicIdentity(name);
}

module.exports = {
  MARKETPLACE_EXACT_HOSTS,
  isMarketplaceOrDirectoryHost,
  marketplacePlatformLabel,
  looksLikeMarketEstimateDirectoryUrl,
  packedCanonicalClinicName,
  spacedCanonicalClinicName,
  isMarketplaceBrandName,
  isGenericShopIdentity,
  looksLikeNonAestheticVenueName,
  marketplaceListingBusinessNameFromUrl,
  clinicIdentityRejectReason,
  looksLikePriceQuotedClinicName,
  isInvalidClinicIdentity,
  extractMarketplaceProviderName,
  namesLookLikeSameProvider,
  clinicMergeKey,
  mergeClinicRecords,
  looksLikeRawScrapedProcedureTitle,
  looksLikeFinancingOrPaymentHeading,
  looksLikeUnilateralBreastStartingRow,
  looksLikeComplicationOrAftercareHeading,
  looksLikeSeoCostPageHeading,
  looksLikeCatalogSectionHeading,
  logDiscoveryReject,
  logDiscoverySkip,
  ingestExcludeClinicKeys,
  marketplaceLocationStronglyMatches,
  normalizeHost,
  isInvalidClinicIdentityCompat,
};
