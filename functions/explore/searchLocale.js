'use strict';

// Local Google language for a city. Unknown cities stay English — the city
// name in the query is the geo signal, not a hardcoded Romania/Spain market.
const WORLD_SITE_PRICE_WORDS = [
  'price',
  'prices',
  'pricing',
  'precio',
  'precios',
  'tarifas',
  'pret',
  'preturi',
  'tarife',
  'prix',
  'tarifs',
  'prezzi',
  'preise',
  'fiyat',
  'fiyatlar',
  'cennik',
  'preco',
  'preços',
  'цена',
  'цени',
  'ценоразпис',
  'سعر',
  'اسعار',
  'أسعار',
  'fees',
  'fee',
];

const GENERIC_PRICE_PATHS = [
  '/prices',
  '/price-list',
  '/pricing',
  '/precios',
  '/tarifas',
  '/tarifs',
  '/preturi',
  '/tarife',
  '/prezzi',
  '/preise',
  '/prix',
  '/preisliste',
  '/fiyatlar',
  '/cennik',
  '/book-online',
];

function _city(city) {
  return String(city || '').toLowerCase().trim();
}

function _hit(city, keys) {
  return keys.some((k) => city.includes(k));
}

/** Prefer explicit ISO country when the client resolved locality. */
function localeForCountryCode(countryCode) {
  const cc = String(countryCode || '').trim().toUpperCase();
  if (!cc) return null;
  const map = {
    RO: {lang: 'ro', priceWord: 'pret', clinicWord: 'clinica', hl: 'ro', gl: 'ro'},
    MD: {lang: 'ro', priceWord: 'pret', clinicWord: 'clinica', hl: 'ro', gl: 'md'},
    BG: {lang: 'bg', priceWord: 'цена', clinicWord: 'клиника', hl: 'bg', gl: 'bg'},
    ES: {lang: 'es', priceWord: 'precio', clinicWord: 'clinica', hl: 'es', gl: 'es'},
    MX: {lang: 'es', priceWord: 'precio', clinicWord: 'clinica', hl: 'es', gl: 'mx'},
    AR: {lang: 'es', priceWord: 'precio', clinicWord: 'clinica', hl: 'es', gl: 'ar'},
    CO: {lang: 'es', priceWord: 'precio', clinicWord: 'clinica', hl: 'es', gl: 'co'},
    IT: {lang: 'it', priceWord: 'prezzo', clinicWord: 'clinica', hl: 'it', gl: 'it'},
    FR: {lang: 'fr', priceWord: 'prix', clinicWord: 'clinique', hl: 'fr', gl: 'fr'},
    BE: {lang: 'fr', priceWord: 'prix', clinicWord: 'clinique', hl: 'fr', gl: 'be'},
    DE: {lang: 'de', priceWord: 'preis', clinicWord: 'klinik', hl: 'de', gl: 'de'},
    AT: {lang: 'de', priceWord: 'preis', clinicWord: 'klinik', hl: 'de', gl: 'at'},
    TR: {lang: 'tr', priceWord: 'fiyat', clinicWord: 'klinik', hl: 'tr', gl: 'tr'},
    PT: {lang: 'pt', priceWord: 'preco', clinicWord: 'clinica', hl: 'pt', gl: 'pt'},
    BR: {lang: 'pt', priceWord: 'preco', clinicWord: 'clinica', hl: 'pt', gl: 'br'},
    NL: {lang: 'nl', priceWord: 'prijs', clinicWord: 'kliniek', hl: 'nl', gl: 'nl'},
    PL: {lang: 'pl', priceWord: 'cena', clinicWord: 'klinika', hl: 'pl', gl: 'pl'},
    KR: {lang: 'ko', priceWord: '가격', clinicWord: '병원', hl: 'ko', gl: 'kr'},
    JP: {lang: 'ja', priceWord: '料金', clinicWord: 'クリニック', hl: 'ja', gl: 'jp'},
    AE: {lang: 'ar', priceWord: 'سعر', clinicWord: 'عيادة', hl: 'ar', gl: 'ae'},
    SA: {lang: 'ar', priceWord: 'سعر', clinicWord: 'عيادة', hl: 'ar', gl: 'sa'},
    EG: {lang: 'ar', priceWord: 'سعر', clinicWord: 'عيادة', hl: 'ar', gl: 'eg'},
    LB: {lang: 'ar', priceWord: 'سعر', clinicWord: 'عيادة', hl: 'ar', gl: 'lb'},
    RU: {lang: 'ru', priceWord: 'цена', clinicWord: 'клиника', hl: 'ru', gl: 'ru'},
    CZ: {lang: 'cs', priceWord: 'cena', clinicWord: 'klinika', hl: 'cs', gl: 'cz'},
    GR: {lang: 'el', priceWord: 'τιμή', clinicWord: 'κλινική', hl: 'el', gl: 'gr'},
    GB: {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'uk'},
    UK: {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'uk'},
    US: {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'us'},
    AU: {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'au'},
    CA: {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'ca'},
    AL: {lang: 'sq', priceWord: 'cmimet', clinicWord: 'klinike', hl: 'sq', gl: 'al'},
    XK: {lang: 'sq', priceWord: 'cmimet', clinicWord: 'klinike', hl: 'sq', gl: 'al'},
  };
  return map[cc] || null;
}

function localeForCity(city, opts = {}) {
  const ccOpt = String(opts.countryCode || '').trim().toUpperCase();
  if (ccOpt) {
    const byCc = localeForCountryCode(ccOpt);
    if (byCc) return byCc;
  }
  const c = _city(city);
  if (!c || c === 'worldwide' || c === 'international') {
    return {
      lang: 'en',
      priceWord: 'price',
      clinicWord: 'clinic',
      hl: 'en',
      gl: '',
    };
  }
  if (_hit(c, [
    'sofia', 'софия', 'plovdiv', 'варна', 'varna', 'bulgaria', 'българия',
  ])) {
    return {lang: 'bg', priceWord: 'цена', clinicWord: 'клиника', hl: 'bg', gl: 'bg'};
  }
  if (_hit(c, [
    'tirana', 'tiranë', 'tirane', 'durres', 'durrës', 'vlore', 'vlorë',
    'shkoder', 'shkodër', 'albania', 'shqip', 'pristina', 'prishtina',
    'kosovo', 'kosov',
  ])) {
    return {lang: 'sq', priceWord: 'cmimet', clinicWord: 'klinike', hl: 'sq', gl: 'al'};
  }
  if (_hit(c, [
    'bucurești', 'bucharest', 'cluj', 'timisoara', 'timișoara',
    'iasi', 'iași', 'brasov', 'brașov', 'constanta', 'constanța',
    'romania', 'românia',
  ])) {
    return {lang: 'ro', priceWord: 'pret', clinicWord: 'clinica', hl: 'ro', gl: 'ro'};
  }
  if (_hit(c, [
    'barcelona', 'madrid', 'valencia', 'sevilla', 'malaga', 'málaga',
    'spain', 'españa', 'espana', 'mexico', 'méxico', 'buenos aires',
    'argentina', 'bogota', 'bogotá', 'colombia', 'santiago', 'lima',
  ])) {
    const gl = _hit(c, ['mexico', 'méxico']) ? 'mx'
      : _hit(c, ['argentina']) ? 'ar'
        : _hit(c, ['colombia']) ? 'co'
          : 'es';
    return {lang: 'es', priceWord: 'precio', clinicWord: 'clinica', hl: 'es', gl};
  }
  if (_hit(c, [
    'milan', 'milano', 'rome', 'roma', 'florence', 'firenze', 'naples',
    'italy', 'italia',
  ])) {
    return {lang: 'it', priceWord: 'prezzo', clinicWord: 'clinica', hl: 'it', gl: 'it'};
  }
  if (_hit(c, [
    'paris', 'lyon', 'marseille', 'nice', 'bordeaux', 'toulouse',
    'france', 'brussels', 'bruxelles', 'geneva', 'casablanca',
  ])) {
    return {lang: 'fr', priceWord: 'prix', clinicWord: 'clinique', hl: 'fr', gl: 'fr'};
  }
  if (_hit(c, [
    'berlin', 'munich', 'münchen', 'hamburg', 'frankfurt', 'cologne',
    'germany', 'deutschland', 'vienna', 'wien', 'austria',
  ])) {
    return {lang: 'de', priceWord: 'preis', clinicWord: 'klinik', hl: 'de', gl: 'de'};
  }
  if (_hit(c, ['istanbul', 'ankara', 'izmir', 'antalya', 'turkey', 'türkiye'])) {
    return {lang: 'tr', priceWord: 'fiyat', clinicWord: 'klinik', hl: 'tr', gl: 'tr'};
  }
  if (_hit(c, ['lisbon', 'lisboa', 'porto', 'portugal'])) {
    return {lang: 'pt', priceWord: 'preco', clinicWord: 'clinica', hl: 'pt', gl: 'pt'};
  }
  if (_hit(c, ['sao paulo', 'são paulo', 'rio de janeiro', 'brazil', 'brasil'])) {
    return {lang: 'pt', priceWord: 'preco', clinicWord: 'clinica', hl: 'pt', gl: 'br'};
  }
  if (_hit(c, ['amsterdam', 'rotterdam', 'utrecht', 'netherlands', 'holland'])) {
    return {lang: 'nl', priceWord: 'prijs', clinicWord: 'kliniek', hl: 'nl', gl: 'nl'};
  }
  if (_hit(c, ['warsaw', 'warszawa', 'krakow', 'kraków', 'poland', 'polska'])) {
    return {lang: 'pl', priceWord: 'cena', clinicWord: 'klinika', hl: 'pl', gl: 'pl'};
  }
  if (_hit(c, ['seoul', 'busan', 'korea', 'south korea'])) {
    return {lang: 'ko', priceWord: '가격', clinicWord: '병원', hl: 'ko', gl: 'kr'};
  }
  if (_hit(c, ['tokyo', 'osaka', 'kyoto', 'japan'])) {
    return {lang: 'ja', priceWord: '料金', clinicWord: 'クリニック', hl: 'ja', gl: 'jp'};
  }
  if (_hit(c, [
    'dubai', 'abu dhabi', 'uae', 'beirut', 'lebanon', 'cairo', 'riyadh',
  ])) {
    const gl = _hit(c, ['cairo']) ? 'eg'
      : _hit(c, ['riyadh']) ? 'sa'
        : _hit(c, ['beirut', 'lebanon']) ? 'lb'
          : 'ae';
    return {lang: 'ar', priceWord: 'سعر', clinicWord: 'عيادة', hl: 'ar', gl};
  }
  if (_hit(c, ['moscow', 'russia'])) {
    return {lang: 'ru', priceWord: 'цена', clinicWord: 'клиника', hl: 'ru', gl: 'ru'};
  }
  if (_hit(c, ['prague', 'praha', 'czech'])) {
    return {lang: 'cs', priceWord: 'cena', clinicWord: 'klinika', hl: 'cs', gl: 'cz'};
  }
  if (_hit(c, ['athens', 'greece'])) {
    return {lang: 'el', priceWord: 'τιμή', clinicWord: 'κλινική', hl: 'el', gl: 'gr'};
  }
  if (_hit(c, [
    'london', 'manchester', 'birmingham', 'edinburgh', 'glasgow',
    'united kingdom', 'england', ' uk',
  ])) {
    return {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'uk'};
  }
  if (_hit(c, [
    'new york', 'los angeles', 'miami', 'chicago', 'houston',
    'united states', 'usa',
  ])) {
    return {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'us'};
  }
  if (_hit(c, ['sydney', 'melbourne', 'australia'])) {
    return {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'au'};
  }
  if (_hit(c, ['toronto', 'vancouver', 'canada'])) {
    return {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: 'ca'};
  }
  // Unknown city: English query, no country pin — "{procedure} prices {city}"
  // is what makes search work in Nairobi, Faro, or any other market.
  return {lang: 'en', priceWord: 'price', clinicWord: 'clinic', hl: 'en', gl: ''};
}

function localProcedureName(procedure, lang) {
  const t = String(procedure || '').toLowerCase();
  let fam = '';
  if (/rhino|nose job|rinoplast/.test(t)) fam = 'rhinoplasty';
  else if (/botox|toxin|neuromodul/.test(t)) fam = 'botox';
  else if (/filler|labio|hialuron|juvederm/.test(t)) fam = 'filler';
  else if (/laser/.test(t)) fam = 'laser';
  else if (/\bpeel/.test(t)) fam = 'peel';
  else if (/breast|boob|mamar|pecho/.test(t)) fam = 'breast';
  else if (/\bhair|fue|injerto|transplant de par/.test(t)) fam = 'hair';
  const names = {
    rhinoplasty: {
      ro: 'rinoplastie', es: 'rinoplastia', fr: 'rhinoplastie',
      it: 'rinoplastica', de: 'Nasenkorrektur', tr: 'rinoplasti',
      pt: 'rinoplastia', ko: '코성형', ar: 'تجميل الانف',
      bg: 'ринопластика',
      sq: 'rinoplastike',
    },
    botox: {
      ro: 'botox', es: 'botox', fr: 'botox', it: 'botox', de: 'botox',
      tr: 'botox', pt: 'botox', ko: '보톡스', ar: 'بوتوكس',
      bg: 'ботокс',
      sq: 'botox',
    },
    filler: {
      ro: 'acid hialuronic', es: 'aumento de labios', fr: 'acide hyaluronique',
      it: 'filler labbra', de: 'lippenaufspritzung', tr: 'dudak dolgusu',
      pt: 'preenchimento labial', ar: 'فيلر',
      bg: 'филър',
      sq: 'filler',
    },
    laser: {
      ro: 'epilare laser', es: 'depilacion laser', fr: 'epilation laser',
      it: 'epilazione laser', de: 'laserhaarentfernung', tr: 'lazer epilasyon',
      ar: 'ليزر ازالة الشعر',
      bg: 'лазерна епилация',
    },
    peel: {
      ro: 'peeling chimic', es: 'peeling quimico', fr: 'peeling chimique',
      ar: 'تقشير كيميائي',
      bg: 'химичен пилинг',
      sq: 'peeling kimik',
    },
    breast: {
      ro: 'marire sani', es: 'aumento de pecho', fr: 'augmentation mammaire',
      it: 'mastoplastica', de: 'brustvergroesserung', tr: 'meme buyutme',
      ar: 'تكبير الثدي',
      bg: 'уголемяване на гърди',
      sq: 'zmadhim gjiri',
    },
    hair: {
      ro: 'transplant par', es: 'injerto capilar', fr: 'greffe de cheveux',
      tr: 'sac ekimi', ar: 'زراعة الشعر',
      bg: 'трансплантация на коса',
      sq: 'transplant flokesh',
    },
  };
  return (names[fam] && names[fam][lang]) || '';
}

// Google query for a city, or site: lookup of a clinic website already
// stored in the backend catalog — language-agnostic price words so a
// .ro / .fr / .co.uk menu is found the same way as a .es one.
function buildSerpQuery({city, procedure, websiteHost, countryCode} = {}) {
  const loc = localeForCity(city, {countryCode});
  const proc = String(procedure || '').trim();
  const localName = localProcedureName(proc, loc.lang);
  if (websiteHost) {
    const procOr = localName && localName.toLowerCase() !== proc.toLowerCase()
      ? `(${proc} OR ${localName})`
      : proc;
    return `site:${websiteHost} ${procOr} (${WORLD_SITE_PRICE_WORDS.join(' OR ')})`;
  }
  if (loc.lang !== 'en' && loc.priceWord && loc.priceWord !== 'price') {
    const name = localName || proc;
    return `${name} ${loc.priceWord} ${city}`.replace(/\s+/g, ' ').trim();
  }
  return `${proc} prices ${city}`.replace(/\s+/g, ' ').trim();
}

/**
 * Broad city×procedure SERP queries (no site:) for discovering new clinics.
 * Serper discovers; official clinic websites verify prices.
 */
function buildBroadProcedureDiscoveryQueries({
  city,
  procedure,
  countryCode = '',
  maxQueries = 6,
} = {}) {
  const c = String(city || '').trim();
  const proc = String(procedure || '').trim();
  if (!c || !proc) return [];
  const loc = localeForCity(c, {countryCode});
  const priceWord = loc.priceWord || 'price';
  const clinicWord = loc.clinicWord || 'clinic';
  const local = localProcedureName(proc, loc.lang) || '';
  const out = [];
  const add = (q) => {
    const t = String(q || '').replace(/\s+/g, ' ').trim();
    if (!t || out.includes(t) || out.length >= maxQueries) return;
    out.push(t);
  };
  add(`"${proc}" ${c} ${priceWord}`);
  add(`"${proc}" ${c} ${clinicWord} ${priceWord}`);
  if (local && local.toLowerCase() !== proc.toLowerCase()) {
    add(`"${local}" ${c} ${priceWord}`);
  }
  if (/breast|boob|mastoplast|zmadhim|implant/i.test(proc) ||
      /breast|mastoplast|zmadhim/i.test(local)) {
    add(`"breast implants" ${c} ${priceWord}`);
    if (loc.lang === 'it') add(`"mastoplastica additiva" ${c} prezzi`);
    if (loc.lang === 'sq') {
      add(`"zmadhim gjoksi" ${c} ${priceWord}`);
      add(`"zmadhimi i gjirit" ${c} ${priceWord}`);
    }
  }
  add(`${proc} prices ${c}`);
  return out;
}

function serpHlGl(city, {englishQuery = false, countryCode} = {}) {
  const loc = localeForCity(city, {countryCode});
  return {
    hl: englishQuery ? 'en' : loc.hl,
    gl: loc.gl,
  };
}

function clinicWordForCity(city, opts = {}) {
  return localeForCity(city, opts).clinicWord;
}

function pricePathsForHost(host) {
  const h = String(host || '').toLowerCase().replace(/^www\./, '');
  if (h.endsWith('.ro')) {
    return [
      '/preturi', '/preturi.php', '/preturi.html', '/tarife',
      '/lista-de-preturi', '/lista-preturi', '/pages/preturi-injectari',
      '/prices',
    ];
  }
  if (/\.(es|mx|ar|cl)$/.test(h) || h.endsWith('.co')) {
    return ['/precios', '/tarifas', '/lista-de-precios', '/book-online', '/prices'];
  }
  if (h.endsWith('.it')) return ['/prezzi', '/tariffe', '/listino', '/prices'];
  if (h.endsWith('.fr') || h.endsWith('.be')) {
    return ['/tarifs', '/prix', '/grille-tarifaire', '/prices'];
  }
  if (h.endsWith('.de') || h.endsWith('.at') || h.endsWith('.ch')) {
    return ['/preise', '/preisliste', '/prices'];
  }
  if (h.endsWith('.uk') || h.endsWith('.ie')) {
    return ['/prices', '/price-list', '/pricing', '/fees'];
  }
  if (h.endsWith('.tr')) return ['/fiyatlar', '/fiyat-listesi', '/prices'];
  if (h.endsWith('.pl')) return ['/cennik', '/ceny', '/prices'];
  if (h.endsWith('.pt') || h.endsWith('.br')) {
    return ['/precos', '/tabela-de-precos', '/prices'];
  }
  if (h.endsWith('.ae') || h.endsWith('.sa')) {
    return ['/prices', '/price-list', '/pricing', '/packages', '/offers',
      '/ar/prices', '/ar/price-list'];
  }
  if (h.endsWith('.kr')) return ['/prices', '/price', '/pricing'];
  if (h.endsWith('.jp')) return ['/price', '/prices', '/pricing'];
  return GENERIC_PRICE_PATHS;
}

module.exports = {
  WORLD_SITE_PRICE_WORDS,
  localeForCity,
  localeForCountryCode,
  localProcedureName,
  buildSerpQuery,
  buildBroadProcedureDiscoveryQueries,
  serpHlGl,
  clinicWordForCity,
  pricePathsForHost,
};
