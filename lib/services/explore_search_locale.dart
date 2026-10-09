import 'explore_regex_cache.dart';
import 'filter_currency.dart';

/// City → search language, local "price" words, and procedure names as
/// people type them into Google (plus English, which the caller always adds).
({String lang, List<String> priceWords, String clinicWord})
exploreCityPriceSearchTerms(String city, {String countryCode = ''}) {
  // Resolved Places countryCode is authoritative — never lose it to a
  // same-name city heuristic (Paris TX vs Paris FR, etc.).
  final fromCc = exploreLocaleFromCountryCode(countryCode);
  if (fromCc != null) return fromCc;

  final c = city.toLowerCase().trim();
  bool any(List<String> keys) => keys.any(c.contains);

  if (any([
    'bucurești',
    'bucharest',
    'cluj',
    'timișoara',
    'timisoara',
    'iași',
    'iasi',
    'brașov',
    'brasov',
    'constanța',
    'constanta',
    'romania',
    'românia',
    'chisinau',
    'chișinău',
    'chisinău',
    'moldova',
  ])) {
    return (
      lang: 'ro',
      priceWords: ['pret', 'preturi', 'tarife'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'barcelona',
    'madrid',
    'valencia',
    'seville',
    'sevilla',
    'malaga',
    'málaga',
    'bilbao',
    'valència',
    'granada',
    'zaragoza',
    'alicante',
    'cordoba',
    'córdoba',
    'murcia',
    'palma',
    'spain',
    'españa',
    'espana',
    'mexico',
    'méxico',
    'cdmx',
    'buenos aires',
    'argentina',
    'bogota',
    'bogotá',
    'colombia',
    'santiago',
    'chile',
    'lima',
    'peru',
  ])) {
    return (
      lang: 'es',
      priceWords: ['precio', 'precios', 'tarifas'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'milan',
    'milano',
    'rome',
    'roma',
    'florence',
    'firenze',
    'naples',
    'napoli',
    'turin',
    'torino',
    'bologna',
    'venice',
    'venezia',
    'genoa',
    'genova',
    'palermo',
    'catania',
    'bari',
    'verona',
    'padua',
    'padova',
    'italy',
    'italia',
  ])) {
    return (
      lang: 'it',
      priceWords: ['prezzo', 'prezzi', 'tariffe'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'paris',
    'lyon',
    'marseille',
    'nice',
    'bordeaux',
    'toulouse',
    'lille',
    'nantes',
    'strasbourg',
    'montpellier',
    'rennes',
    'grenoble',
    'dijon',
    'reims',
    'toulon',
    'nimes',
    'nîmes',
    'cannes',
    'avignon',
    'orleans',
    'orléans',
    'rouen',
    'tours',
    'angers',
    'caen',
    'metz',
    'nancy',
    'mulhouse',
    'perpignan',
    'clermont',
    'aix-en-provence',
    'saint-etienne',
    'saint-étienne',
    'le havre',
    'versailles',
    'france',
    'brussels',
    'bruxelles',
    'liege',
    'liège',
    'geneva',
    'genève',
    'lausanne',
    'montreal',
    'montréal',
    'quebec',
    'québec',
    'quebec city',
    'québec city',
    'casablanca',
    'tunis',
    'rabat',
    'marrakech',
    'algiers',
    'alger',
  ])) {
    return (lang: 'fr', priceWords: ['prix', 'tarifs'], clinicWord: 'clinique');
  }
  if (any([
    'berlin',
    'munich',
    'münchen',
    'hamburg',
    'frankfurt',
    'cologne',
    'köln',
    'düsseldorf',
    'stuttgart',
    'leipzig',
    'hannover',
    'hanover',
    'nuremberg',
    'nürnberg',
    'nurnberg',
    'dortmund',
    'essen',
    'bremen',
    'dresden',
    'duisburg',
    'bochum',
    'wuppertal',
    'bielefeld',
    'bonn',
    'mannheim',
    'karlsruhe',
    'augsburg',
    'wiesbaden',
    'aachen',
    'freiburg',
    'kiel',
    'erfurt',
    'mainz',
    'rostock',
    'kassel',
    'saarbrücken',
    'saarbrucken',
    'potsdam',
    'heidelberg',
    'regensburg',
    'würzburg',
    'wurzburg',
    'ulm',
    'germany',
    'deutschland',
    'vienna',
    'wien',
    'austria',
    'österreich',
    'zurich',
    'zürich',
    'bern',
    'basel',
    'switzerland',
  ])) {
    return (
      lang: 'de',
      priceWords: ['preis', 'preise', 'kosten'],
      clinicWord: 'klinik',
    );
  }
  if (any([
    'istanbul',
    'ankara',
    'izmir',
    'antalya',
    'bursa',
    'turkey',
    'türkiye',
  ])) {
    return (
      lang: 'tr',
      priceWords: [
        'fiyat',
        'fiyatı',
        'fiyatlari',
        'fiyatları',
        'ücret',
        'ücreti',
        'ücretleri',
        'ucret',
        'maliyet',
        'maliyeti',
        'fiyat listesi',
        'ücret tarifesi',
      ],
      clinicWord: 'klinik',
    );
  }
  if (any([
    'lisbon',
    'lisboa',
    'porto',
    'portugal',
    'sao paulo',
    'são paulo',
    'rio de janeiro',
    'brazil',
    'brasil',
  ])) {
    return (
      lang: 'pt',
      priceWords: ['preco', 'preço', 'precos', 'preços', 'tabela'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'amsterdam',
    'rotterdam',
    'utrecht',
    'the hague',
    'den haag',
    'antwerp',
    'antwerpen',
    'ghent',
    'gent',
    'netherlands',
    'holland',
    'belgium',
  ])) {
    return (
      lang: 'nl',
      priceWords: ['prijs', 'prijzen', 'tarieven'],
      clinicWord: 'kliniek',
    );
  }
  if (any([
    'warsaw',
    'warszawa',
    'krakow',
    'kraków',
    'gdansk',
    'poland',
    'polska',
  ])) {
    return (
      lang: 'pl',
      priceWords: ['cena', 'cennik', 'ceny'],
      clinicWord: 'klinika',
    );
  }
  if (any(['seoul', 'busan', 'korea', 'south korea', '대한민국', '한국'])) {
    return (lang: 'ko', priceWords: ['가격', '비용'], clinicWord: '병원');
  }
  if (any([
    'dubai',
    'abu dhabi',
    'sharjah',
    'uae',
    'beirut',
    'lebanon',
    'cairo',
    'egypt',
    'riyadh',
    'jeddah',
    'doha',
    'qatar',
    'kuwait',
    'amman',
    'jordan',
    'bahrain',
    'muscat',
    'oman',
  ])) {
    return (
      lang: 'ar',
      priceWords: ['سعر', 'اسعار', 'أسعار'],
      clinicWord: 'عيادة',
    );
  }
  if (any(['tokyo', 'osaka', 'kyoto', 'yokohama', 'japan', '日本'])) {
    return (lang: 'ja', priceWords: ['料金', '価格'], clinicWord: 'クリニック');
  }
  if (any(['moscow', 'москва', 'saint petersburg', 'russia', 'россия'])) {
    return (
      lang: 'ru',
      priceWords: ['цена', 'цены', 'стоимость'],
      clinicWord: 'клиника',
    );
  }
  if (any(['kyiv', 'kiev', 'lviv', 'ukraine', 'україна'])) {
    return (lang: 'uk', priceWords: ['ціна', 'ціни'], clinicWord: 'клініка');
  }
  if (any(['athens', 'thessaloniki', 'greece', 'ελλάδα'])) {
    return (lang: 'el', priceWords: ['τιμή', 'τιμές'], clinicWord: 'κλινική');
  }
  if (any(['prague', 'praha', 'brno', 'czech', 'czechia'])) {
    return (
      lang: 'cs',
      priceWords: ['cena', 'cenik', 'ceník'],
      clinicWord: 'klinika',
    );
  }
  if (any(['budapest', 'hungary', 'magyarország'])) {
    return (
      lang: 'hu',
      priceWords: ['ar', 'ár', 'arak'],
      clinicWord: 'klinika',
    );
  }
  if (any(['stockholm', 'gothenburg', 'sweden', 'sverige'])) {
    return (lang: 'sv', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
  }
  if (any(['copenhagen', 'københavn', 'denmark', 'danmark'])) {
    return (lang: 'da', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
  }
  if (any(['oslo', 'bergen', 'norway', 'norge'])) {
    return (lang: 'no', priceWords: ['pris', 'priser'], clinicWord: 'klinikk');
  }
  if (any(['helsinki', 'finland', 'suomi'])) {
    return (
      lang: 'fi',
      priceWords: ['hinta', 'hinnat'],
      clinicWord: 'klinikka',
    );
  }
  if (any([
    'shanghai',
    'beijing',
    'guangzhou',
    'shenzhen',
    'hangzhou',
    'china',
    '中国',
  ])) {
    return (lang: 'zh', priceWords: ['价格', '费用'], clinicWord: '诊所');
  }
  if (any(['hong kong', 'hongkong', 'hk'])) {
    return (lang: 'zh', priceWords: ['價錢', '價格', 'price'], clinicWord: '診所');
  }
  if (any(['taipei', 'taiwan'])) {
    return (lang: 'zh', priceWords: ['價格', '價錢'], clinicWord: '診所');
  }
  if (any(['bangkok', 'phuket', 'pattaya', 'chiang mai', 'thailand'])) {
    return (lang: 'th', priceWords: ['ราคา'], clinicWord: 'คลินิก');
  }
  if (any([
    'new delhi',
    'delhi',
    'mumbai',
    'bangalore',
    'bengaluru',
    'hyderabad',
    'chennai',
    'india',
  ])) {
    return (
      lang: 'hi',
      priceWords: ['कीमत', 'मूल्य', 'price'],
      clinicWord: 'क्लिनिक',
    );
  }
  if (any(['tel aviv', 'jerusalem', 'israel'])) {
    return (lang: 'he', priceWords: ['מחיר', 'מחירים'], clinicWord: 'מרפאה');
  }
  if (any(['hanoi', 'ho chi minh', 'saigon', 'vietnam'])) {
    return (lang: 'vi', priceWords: ['gia', 'giá'], clinicWord: 'phong kham');
  }
  if (any(['belgrade', 'beograd', 'serbia', 'zagreb', 'croatia', 'split'])) {
    return (
      lang: 'sr',
      priceWords: ['cena', 'cijena', 'cene'],
      clinicWord: 'klinika',
    );
  }
  if (any([
    'worldwide',
    'international',
    'london',
    'manchester',
    'birmingham',
    'edinburgh',
    'glasgow',
    'liverpool',
    'bristol',
    'leeds',
    'new york',
    'los angeles',
    'miami',
    'chicago',
    'houston',
    'san francisco',
    'sydney',
    'melbourne',
    'toronto',
    'vancouver',
    'singapore',
    'dublin',
    'auckland',
    'cape town',
    'johannesburg',
  ])) {
    return (lang: 'en', priceWords: ['price', 'prices'], clinicWord: 'clinic');
  }
  final fromCountry = _localeFromCountryName(c);
  if (fromCountry != null) return fromCountry;
  return (lang: 'en', priceWords: ['price', 'prices'], clinicWord: 'clinic');
}

/// "Nantes, France" / "Leipzig, Germany" when the city itself is not listed.
({String lang, List<String> priceWords, String clinicWord})?
_localeFromCountryName(String cityLower) {
  bool any(List<String> keys) => keys.any(cityLower.contains);
  if (any(['romania', 'românia'])) {
    return (
      lang: 'ro',
      priceWords: ['pret', 'preturi', 'tarife'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'spain',
    'españa',
    'espana',
    'mexico',
    'méxico',
    'argentina',
    'colombia',
    'chile',
    'peru',
  ])) {
    return (
      lang: 'es',
      priceWords: ['precio', 'precios', 'tarifas'],
      clinicWord: 'clinica',
    );
  }
  if (any(['italy', 'italia'])) {
    return (
      lang: 'it',
      priceWords: ['prezzo', 'prezzi', 'tariffe'],
      clinicWord: 'clinica',
    );
  }
  if (any([
    'france',
    'morocco',
    'maroc',
    'tunisia',
    'tunisie',
    'algeria',
    'algérie',
    'algerie',
  ])) {
    return (lang: 'fr', priceWords: ['prix', 'tarifs'], clinicWord: 'clinique');
  }
  if (any(['germany', 'deutschland', 'austria', 'österreich', 'osterreich'])) {
    return (
      lang: 'de',
      priceWords: ['preis', 'preise', 'kosten'],
      clinicWord: 'klinik',
    );
  }
  if (any(['turkey', 'türkiye', 'turkiye'])) {
    return (
      lang: 'tr',
      priceWords: ['fiyat', 'fiyatlar', 'ücret'],
      clinicWord: 'klinik',
    );
  }
  if (any(['portugal', 'brazil', 'brasil'])) {
    return (
      lang: 'pt',
      priceWords: ['preco', 'preço', 'precos', 'preços', 'tabela'],
      clinicWord: 'clinica',
    );
  }
  if (any(['netherlands', 'holland', 'belgium'])) {
    return (
      lang: 'nl',
      priceWords: ['prijs', 'prijzen', 'tarieven'],
      clinicWord: 'kliniek',
    );
  }
  if (any(['poland', 'polska'])) {
    return (
      lang: 'pl',
      priceWords: ['cena', 'cennik', 'ceny'],
      clinicWord: 'klinika',
    );
  }
  if (any(['korea', 'south korea'])) {
    return (lang: 'ko', priceWords: ['가격', '비용'], clinicWord: '병원');
  }
  if (any([
    'uae',
    'lebanon',
    'egypt',
    'qatar',
    'kuwait',
    'jordan',
    'bahrain',
    'oman',
    'saudi',
  ])) {
    return (
      lang: 'ar',
      priceWords: ['سعر', 'اسعار', 'أسعار'],
      clinicWord: 'عيادة',
    );
  }
  if (any(['japan'])) {
    return (lang: 'ja', priceWords: ['料金', '価格'], clinicWord: 'クリニック');
  }
  if (any(['russia', 'россия'])) {
    return (
      lang: 'ru',
      priceWords: ['цена', 'цены', 'стоимость'],
      clinicWord: 'клиника',
    );
  }
  if (any(['ukraine', 'україна'])) {
    return (lang: 'uk', priceWords: ['ціна', 'ціни'], clinicWord: 'клініка');
  }
  if (any(['greece', 'ελλάδα'])) {
    return (lang: 'el', priceWords: ['τιμή', 'τιμές'], clinicWord: 'κλινική');
  }
  if (any(['czech', 'czechia'])) {
    return (
      lang: 'cs',
      priceWords: ['cena', 'cenik', 'ceník'],
      clinicWord: 'klinika',
    );
  }
  if (any(['hungary', 'magyarország'])) {
    return (
      lang: 'hu',
      priceWords: ['ar', 'ár', 'arak'],
      clinicWord: 'klinika',
    );
  }
  if (any(['sweden', 'sverige'])) {
    return (lang: 'sv', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
  }
  if (any(['denmark', 'danmark'])) {
    return (lang: 'da', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
  }
  if (any(['norway', 'norge'])) {
    return (lang: 'no', priceWords: ['pris', 'priser'], clinicWord: 'klinikk');
  }
  if (any(['finland', 'suomi'])) {
    return (
      lang: 'fi',
      priceWords: ['hinta', 'hinnat'],
      clinicWord: 'klinikka',
    );
  }
  if (any(['china', '中国'])) {
    return (lang: 'zh', priceWords: ['价格', '费用'], clinicWord: '诊所');
  }
  if (any(['thailand'])) {
    return (lang: 'th', priceWords: ['ราคา'], clinicWord: 'คลินิก');
  }
  if (any(['india'])) {
    return (
      lang: 'hi',
      priceWords: ['कीमत', 'मूल्य', 'price'],
      clinicWord: 'क्लिनिक',
    );
  }
  if (any(['israel'])) {
    return (lang: 'he', priceWords: ['מחיר', 'מחירים'], clinicWord: 'מרפאה');
  }
  if (any(['vietnam'])) {
    return (lang: 'vi', priceWords: ['gia', 'giá'], clinicWord: 'phong kham');
  }
  if (any(['serbia', 'croatia'])) {
    return (
      lang: 'sr',
      priceWords: ['cena', 'cijena', 'cene'],
      clinicWord: 'klinika',
    );
  }
  // Albania / Kosovo. Without this a Tirana search ran entirely in English:
  // Serper returned 0 results per clinic and Firecrawl ranked no price URLs,
  // even on sites that publish a full "Çmimet" menu.
  if (any([
    'albania',
    'shqip',
    'tirana',
    'tiran',
    'durres',
    'durrës',
    'vlore',
    'vlorë',
    'shkoder',
    'shkodër',
    'kosovo',
    'kosov',
    'pristina',
    'prishtin',
  ])) {
    return (
      lang: 'sq',
      priceWords: ['cmimet', 'çmimet', 'cmime', 'çmime'],
      clinicWord: 'klinike',
    );
  }
  if (any(['macedonia', 'skopje'])) {
    return (
      lang: 'mk',
      priceWords: ['цени', 'ценовник'],
      clinicWord: 'клиника',
    );
  }
  if (any(['bosnia', 'sarajevo', 'banja luka'])) {
    return (
      lang: 'bs',
      priceWords: ['cjenik', 'cijene'],
      clinicWord: 'klinika',
    );
  }
  if (any(['slovenia', 'ljubljana'])) {
    return (lang: 'sl', priceWords: ['cenik', 'cene'], clinicWord: 'klinika');
  }
  if (any(['slovakia', 'bratislava'])) {
    return (lang: 'sk', priceWords: ['cenik', 'ceník'], clinicWord: 'klinika');
  }
  if (any(['georgia', 'tbilisi'])) {
    return (lang: 'ka', priceWords: ['ფასები'], clinicWord: 'კლინიკა');
  }
  return null;
}

/// ISO country → Google search language for any city in that country.
({String lang, List<String> priceWords, String clinicWord})?
exploreLocaleFromCountryCode(String countryCode) {
  switch (countryCode.trim().toUpperCase()) {
    case 'ES':
    case 'MX':
    case 'AR':
    case 'CO':
    case 'CL':
    case 'PE':
    case 'UY':
    case 'EC':
    case 'VE':
    case 'GT':
    case 'CR':
    case 'PA':
    case 'BO':
    case 'PY':
    case 'DO':
    case 'CU':
    case 'HN':
    case 'SV':
    case 'NI':
      return (
        lang: 'es',
        priceWords: ['precio', 'precios', 'tarifas'],
        clinicWord: 'clinica',
      );
    case 'FR':
    case 'BE':
    case 'CH':
    case 'MA':
    case 'TN':
    case 'DZ':
    case 'SN':
    case 'CI':
    case 'LU':
    case 'MC':
      return (
        lang: 'fr',
        priceWords: ['prix', 'tarifs'],
        clinicWord: 'clinique',
      );
    case 'IT':
      return (
        lang: 'it',
        priceWords: ['prezzo', 'prezzi', 'tariffe'],
        clinicWord: 'clinica',
      );
    case 'DE':
    case 'AT':
      return (
        lang: 'de',
        priceWords: ['preis', 'preise', 'kosten'],
        clinicWord: 'klinik',
      );
    case 'RO':
      return (
        lang: 'ro',
        priceWords: ['pret', 'preturi', 'tarife'],
        clinicWord: 'clinica',
      );
    case 'TR':
      return (
        lang: 'tr',
        priceWords: ['fiyat', 'fiyatlar', 'ücret'],
        clinicWord: 'klinik',
      );
    case 'PT':
      return (
        lang: 'pt',
        priceWords: ['preco', 'preço', 'precos', 'preços', 'tabela'],
        clinicWord: 'clinica',
      );
    case 'BR':
      return (
        lang: 'pt',
        priceWords: ['preco', 'preço', 'precos', 'preços', 'tabela'],
        clinicWord: 'clinica',
      );
    case 'NL':
      return (
        lang: 'nl',
        priceWords: ['prijs', 'prijzen', 'tarieven'],
        clinicWord: 'kliniek',
      );
    case 'PL':
      return (
        lang: 'pl',
        priceWords: ['cena', 'cennik', 'ceny'],
        clinicWord: 'klinika',
      );
    case 'KR':
      return (lang: 'ko', priceWords: ['가격', '비용'], clinicWord: '병원');
    case 'JP':
      return (lang: 'ja', priceWords: ['料金', '価格'], clinicWord: 'クリニック');
    case 'CN':
    case 'TW':
      return (lang: 'zh', priceWords: ['价格', '费用'], clinicWord: '诊所');
    case 'AE':
    case 'SA':
    case 'QA':
    case 'KW':
    case 'BH':
    case 'OM':
    case 'EG':
    case 'LB':
    case 'JO':
    case 'IQ':
      return (
        lang: 'ar',
        priceWords: ['سعر', 'اسعار', 'أسعار'],
        clinicWord: 'عيادة',
      );
    case 'RU':
      return (
        lang: 'ru',
        priceWords: ['цена', 'цены', 'стоимость'],
        clinicWord: 'клиника',
      );
    case 'UA':
      return (lang: 'uk', priceWords: ['ціна', 'ціни'], clinicWord: 'клініка');
    case 'BG':
      return (
        lang: 'bg',
        priceWords: ['цена', 'цени', 'ценоразпис'],
        clinicWord: 'клиника',
      );
    case 'GR':
      return (lang: 'el', priceWords: ['τιμή', 'τιμές'], clinicWord: 'κλινική');
    case 'CZ':
      return (
        lang: 'cs',
        priceWords: ['cena', 'cenik', 'ceník'],
        clinicWord: 'klinika',
      );
    case 'HU':
      return (
        lang: 'hu',
        priceWords: ['ar', 'ár', 'arak'],
        clinicWord: 'klinika',
      );
    case 'SE':
      return (lang: 'sv', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
    case 'DK':
      return (lang: 'da', priceWords: ['pris', 'priser'], clinicWord: 'klinik');
    case 'NO':
      return (
        lang: 'no',
        priceWords: ['pris', 'priser'],
        clinicWord: 'klinikk',
      );
    case 'FI':
      return (
        lang: 'fi',
        priceWords: ['hinta', 'hinnat'],
        clinicWord: 'klinikka',
      );
    case 'TH':
      return (lang: 'th', priceWords: ['ราคา'], clinicWord: 'คลินิก');
    case 'IN':
      return (
        lang: 'hi',
        priceWords: ['कीमत', 'मूल्य', 'price'],
        clinicWord: 'क्लिनिक',
      );
    case 'IL':
      return (lang: 'he', priceWords: ['מחיר', 'מחירים'], clinicWord: 'מרפאה');
    case 'VN':
      return (lang: 'vi', priceWords: ['gia', 'giá'], clinicWord: 'phong kham');
    case 'AL':
    case 'XK':
      return (
        lang: 'sq',
        priceWords: ['cmimet', 'çmimet', 'cmime', 'çmime'],
        clinicWord: 'klinike',
      );
    case 'MK':
      return (
        lang: 'mk',
        priceWords: ['цени', 'ценовник'],
        clinicWord: 'клиника',
      );
    case 'BA':
      return (
        lang: 'bs',
        priceWords: ['cjenik', 'cijene'],
        clinicWord: 'klinika',
      );
    case 'SI':
      return (lang: 'sl', priceWords: ['cenik', 'cene'], clinicWord: 'klinika');
    case 'SK':
      return (
        lang: 'sk',
        priceWords: ['cenik', 'ceník'],
        clinicWord: 'klinika',
      );
    case 'GE':
      return (lang: 'ka', priceWords: ['ფასები'], clinicWord: 'კლინიკა');
    case 'RS':
    case 'ME':
    case 'HR':
      return (
        lang: 'sr',
        priceWords: ['cena', 'cijena', 'cene'],
        clinicWord: 'klinika',
      );
    case 'GB':
    case 'UK':
    case 'US':
    case 'AU':
    case 'CA':
    case 'NZ':
    case 'IE':
    case 'SG':
    case 'ZA':
    case 'HK':
    // 'AL' used to be listed here, so every Tirana search ran in English:
    // Serper returned 0 results per clinic and no Albanian price page was
    // ever ranked. Albania is handled above as 'sq'.
    case 'KE':
    case 'NG':
    case 'GH':
    case 'PH':
    case 'MY':
      return (
        lang: 'en',
        priceWords: ['price', 'prices'],
        clinicWord: 'clinic',
      );
    default:
      return null;
  }
}

/// Google `gl` (country) for SerpApi — keeps results in that market.
///
/// Prefer [countryCode] from a Places-resolved locality. City-name heuristics
/// remain only as legacy fallback for callers without structured identity.
/// Unknown / Worldwide cities omit `gl` so the city name in the query is
/// the geo signal instead of pinning Google to US/RO.
String exploreGoogleGl(String lang, String city, {String countryCode = ''}) {
  final cc = countryCode.trim().toUpperCase();
  if (cc.isNotEmpty) {
    final fromCc = exploreGoogleGlFromCountryCode(cc);
    if (fromCc.isNotEmpty) return fromCc;
  }

  final c = city.toLowerCase();
  if (c.contains('worldwide') || c.contains('international')) {
    return '';
  }
  if (c.contains('london') ||
      c.contains('manchester') ||
      c.contains('birmingham') ||
      c.contains('edinburgh') ||
      c.contains('glasgow') ||
      c.contains('united kingdom') ||
      c.contains('england') ||
      c.contains(' uk')) {
    return 'uk';
  }
  if (c.contains('united states') ||
      c.contains('usa') ||
      c.contains('new york') ||
      c.contains('los angeles') ||
      c.contains('miami') ||
      c.contains('chicago') ||
      c.contains('houston') ||
      c.contains('san francisco')) {
    return 'us';
  }
  if (c.contains('sydney') ||
      c.contains('melbourne') ||
      c.contains('australia')) {
    return 'au';
  }
  if (c.contains('chisinau') ||
      c.contains('chișinău') ||
      c.contains('chisinău') ||
      c.contains('moldova')) {
    return 'md';
  }
  if (c.contains('toronto') ||
      c.contains('vancouver') ||
      c.contains('calgary') ||
      c.contains('edmonton') ||
      c.contains('halifax') ||
      c.contains('hamilton') ||
      c.contains('kelowna') ||
      c.contains('montreal') ||
      c.contains('montréal') ||
      c.contains('ottawa') ||
      c.contains('quebec') ||
      c.contains('québec') ||
      c.contains('saskatoon') ||
      c.contains('victoria') ||
      c.contains('winnipeg') ||
      c.contains('markham') ||
      c.contains('mississauga') ||
      c.contains('oakville') ||
      c.contains('richmond hill') ||
      c.contains('vaughan') ||
      c.contains('burnaby') ||
      c.contains('surrey') ||
      c.contains('canada')) {
    return 'ca';
  }
  if (c.contains('auckland') ||
      c.contains('wellington') ||
      c.contains('new zealand')) {
    return 'nz';
  }
  if (c.contains('dublin') || c.contains('ireland')) {
    return 'ie';
  }
  if (c.contains('singapore')) {
    return 'sg';
  }
  if (c.contains('cape town') ||
      c.contains('johannesburg') ||
      c.contains('south africa')) {
    return 'za';
  }
  if (c.contains('hong kong') || c.contains('hongkong')) {
    return 'hk';
  }
  switch (lang.trim().toLowerCase()) {
    case 'es':
      if (c.contains('mexico') || c.contains('méxico')) return 'mx';
      if (c.contains('argentina')) return 'ar';
      if (c.contains('colombia')) return 'co';
      if (c.contains('chile')) return 'cl';
      if (c.contains('peru')) return 'pe';
      return 'es';
    case 'pt':
      return (c.contains('brazil') || c.contains('brasil')) ? 'br' : 'pt';
    case 'fr':
      return 'fr';
    case 'it':
      return 'it';
    case 'de':
      return 'de';
    case 'ro':
      return 'ro';
    case 'tr':
      return 'tr';
    case 'nl':
      return 'nl';
    case 'pl':
      return 'pl';
    case 'ko':
      return 'kr';
    case 'ja':
      return 'jp';
    case 'zh':
      return 'cn';
    case 'ar':
      if (c.contains('dubai') || c.contains('uae') || c.contains('abu dhabi')) {
        return 'ae';
      }
      if (c.contains('saudi') || c.contains('riyadh')) return 'sa';
      if (c.contains('egypt') || c.contains('cairo')) return 'eg';
      if (c.contains('beirut') || c.contains('lebanon')) return 'lb';
      return 'ae';
    case 'bg':
      return 'bg';
    case 'ru':
      return 'ru';
    case 'uk':
      return 'ua';
    case 'el':
      return 'gr';
    case 'cs':
      return 'cz';
    case 'hu':
      return 'hu';
    case 'sv':
      return 'se';
    case 'da':
      return 'dk';
    case 'no':
      return 'no';
    case 'fi':
      return 'fi';
    case 'th':
      return 'th';
    case 'hi':
      return 'in';
    case 'he':
      return 'il';
    case 'vi':
      return 'vn';
    // Balkans / Caucasus locales added for city price terms — without these
    // exploreCountryCodeForCity("Tiranë") returned '' and Places fallbacks
    // wrote unresolved_* cache keys (no country, no geo).
    case 'sq':
      return 'al';
    case 'mk':
      return 'mk';
    case 'bs':
      return 'ba';
    case 'sl':
      return 'si';
    case 'sk':
      return 'sk';
    case 'ka':
      return 'ge';
    case 'sr':
      return 'rs';
    case 'en':
      return '';
    default:
      return '';
  }
}

/// ISO-3166 alpha-2 → Google `gl` (lowercase). Empty when unknown / worldwide.
String exploreGoogleGlFromCountryCode(String countryCode) {
  final cc = countryCode.trim().toUpperCase();
  if (cc.isEmpty || cc == 'ZZ' || cc == 'XX') return '';
  // Google uses `uk` for the United Kingdom, not `gb`.
  if (cc == 'GB') return 'uk';
  if (cc.length == 2 && cachedRegExp(r'^[A-Z]{2}$').hasMatch(cc)) {
    return cc.toLowerCase();
  }
  return '';
}

/// ISO country for trending + localized search. Empty for Worldwide / unknown
/// cities so Google is not pinned to GB or Romania.
String exploreCountryCodeForCity(String city) {
  final raw = city.trim();
  if (raw.isEmpty) return '';
  final c = raw.toLowerCase();
  if (c == 'worldwide' || c == 'international') return '';
  final loc = exploreCityPriceSearchTerms(raw);
  final gl = exploreGoogleGl(loc.lang, raw);
  if (gl.trim().isEmpty) return '';
  if (gl == 'uk') return 'GB';
  return gl.trim().toUpperCase();
}

String exploreHostFromListing({String sourceUrl = '', String area = ''}) {
  for (final raw in [sourceUrl, area]) {
    final host = _hostFromBlob(raw);
    if (host.contains('.')) return host;
  }
  for (final part in area.split(cachedRegExp(r'[·|,]'))) {
    final host = _hostFromBlob(part.trim());
    if (host.contains('.')) return host;
  }
  return '';
}

String _hostFromBlob(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty || !s.contains('.')) return '';
  s = s.replaceFirst(cachedRegExp(r'^https?://'), '');
  if (s.startsWith('src:')) s = s.substring(4);
  s = s.split(cachedRegExp(r'[/?#\s]')).first;
  s = s.replaceFirst(cachedRegExp(r'^www\.'), '');
  if (!s.contains('.') || s.contains(' ')) return '';
  return s;
}

/// Country from a clinic ccTLD. Generic `.com` / `.net` return empty.
String exploreCountryFromHost(String host) {
  final h = host.trim().toLowerCase().replaceFirst(cachedRegExp(r'^www\.'), '');
  if (h.isEmpty) return '';
  if (h.endsWith('.co.uk') || h.endsWith('.uk')) return 'GB';
  if (h.endsWith('.com.au') || h.endsWith('.au')) return 'AU';
  if (h.endsWith('.co.ae') || h.endsWith('.ae')) return 'AE';
  if (h.endsWith('.co.za') || h.endsWith('.za')) return 'ZA';
  if (h.endsWith('.com.br') || h.endsWith('.br')) return 'BR';
  final m = cachedRegExp(r'\.([a-z]{2})$').firstMatch(h);
  if (m == null) return '';
  final tld = m.group(1)!;
  const generic = {
    'com',
    'net',
    'org',
    'io',
    'app',
    'dev',
    'info',
    'biz',
    'site',
    'online',
    'health',
    'clinic',
    'doctor',
    'dental',
    'care',
    'pro',
    'xyz',
    'shop',
    'store',
    'cloud',
    'ai',
  };
  if (generic.contains(tld)) return '';
  if (tld == 'uk') return 'GB';
  return tld.toUpperCase();
}

/// AED cities must not show RON/EUR/.ro menus; Bucharest may show EUR.
/// Sofia menus publish both BGN and EUR — either fits.
bool exploreCurrencyFitsSearchCity(String currency, String city) {
  final cityCur = CityCurrency.localCode(city);
  if (cityCur.isEmpty) return true;
  final clinic = CityCurrency.normalizeCode(currency);
  if (clinic.isEmpty) return true;
  if (CityCurrency.matches(clinic, cityCur)) return true;
  if (CityCurrency.matches(clinic, r'$')) return true;
  if (CityCurrency.matches(clinic, '€')) {
    return cityCur == '€' ||
        cityCur == 'RON' ||
        cityCur == 'MDL' ||
        cityCur == 'CHF' ||
        cityCur == '£' ||
        cityCur == 'BGN';
  }
  if (CityCurrency.matches(clinic, 'BGN')) {
    return cityCur == 'BGN' || cityCur == '€';
  }
  if (CityCurrency.matches(clinic, 'MDL') ||
      CityCurrency.matches(clinic, 'RON')) {
    return cityCur == 'MDL' || cityCur == 'RON' || cityCur == '€';
  }
  return false;
}

bool exploreHostFitsSearchCity(String host, String city) {
  final cityCc = exploreCountryCodeForCity(city);
  if (cityCc.isEmpty) return true;
  final hostCc = exploreCountryFromHost(host);
  if (hostCc.isEmpty) return true;
  return hostCc == cityCc;
}

/// Gulf / GCC, UK, and Romanian/Moldovan peer cities that must not be mixed
/// on one Compare search (e.g. /preturi/iasi on a Timisoara result).
const _kExplorePeerCityMarks = <({String key, List<String> aliases})>[
  (key: 'dubai', aliases: ['dubai', 'دبي', 'motor city']),
  (key: 'al ain', aliases: ['al ain', 'al-ain', 'alain', 'العين']),
  (
    key: 'abu dhabi',
    aliases: [
      'abu dhabi',
      'abudhabi',
      'abu-dhabi',
      'أبوظبي',
      'أبو ظبي',
      'ابوظبي',
    ],
  ),
  (key: 'sharjah', aliases: ['sharjah', 'الشارقة', 'شارقة']),
  (key: 'riyadh', aliases: ['riyadh', 'الرياض']),
  (key: 'jeddah', aliases: ['jeddah', 'جدة']),
  (key: 'doha', aliases: ['doha', 'الدوحة']),
  (key: 'kuwait', aliases: ['kuwait', 'الكويت']),
  (key: 'london', aliases: ['london']),
  (key: 'manchester', aliases: ['manchester']),
  (key: 'birmingham', aliases: ['birmingham']),
  (key: 'leeds', aliases: ['leeds']),
  (key: 'glasgow', aliases: ['glasgow']),
  (key: 'edinburgh', aliases: ['edinburgh']),
  (key: 'liverpool', aliases: ['liverpool']),
  (key: 'bristol', aliases: ['bristol']),
  (key: 'newcastle', aliases: ['newcastle upon tyne', 'newcastle-upon-tyne']),
  (key: 'nottingham', aliases: ['nottingham', 'nottinghamshire']),
  (key: 'derby', aliases: ['derbyshire', 'derby', 'ripley']),
  (key: 'sheffield', aliases: ['sheffield']),
  (key: 'cardiff', aliases: ['cardiff']),
  (key: 'belfast', aliases: ['belfast']),
  (key: 'brighton', aliases: ['brighton']),
  (key: 'leicester', aliases: ['leicester']),
  (key: 'southampton', aliases: ['southampton']),
  (key: 'timisoara', aliases: ['timisoara', 'timișoara', 'timişoara']),
  (key: 'chisinau', aliases: ['chisinau', 'chișinău', 'chisinău', 'kishinev']),
  (
    key: 'bucharest',
    aliases: ['bucharest', 'bucuresti', 'bucurești', 'bucureş'],
  ),
  (key: 'iasi', aliases: ['iasi', 'iași', 'iaşi']),
  (key: 'brasov', aliases: ['brasov', 'brașov', 'braşov']),
  (key: 'bacau', aliases: ['bacau', 'bacău', 'bacǎu']),
  (key: 'cluj', aliases: ['cluj', 'cluj-napoca', 'cluj napoca']),
  (key: 'constanta', aliases: ['constanta', 'constanța', 'constanţa']),
  (key: 'sibiu', aliases: ['sibiu']),
  (key: 'oradea', aliases: ['oradea']),
  (key: 'galati', aliases: ['galati', 'galați', 'galaţi']),
  (key: 'ploiesti', aliases: ['ploiesti', 'ploiești', 'ploieşti']),
  (key: 'craiova', aliases: ['craiova']),
  // Budapest was outside this list, so a Tiranë address or botoxtirana.com
  // host never counted as a different city.
  (key: 'budapest', aliases: ['budapest', 'budapesta']),
  (key: 'tirane', aliases: ['tirane', 'tirana', 'tiranë']),
  (key: 'durres', aliases: ['durres', 'durrës']),
  (key: 'vlore', aliases: ['vlore', 'vlorë', 'vlora']),
  (key: 'shkoder', aliases: ['shkoder', 'shkodër', 'shkodra']),
  (key: 'milan', aliases: ['milan', 'milano']),
  (key: 'rome', aliases: ['rome', 'roma']),
  (key: 'istanbul', aliases: ['istanbul']),
  (key: 'sofia', aliases: ['sofia']),
  (key: 'paris', aliases: ['paris']),
  (key: 'lyon', aliases: ['lyon']),
  (
    key: 'new york',
    aliases: ['new york', 'new york city', 'new-york', 'nyc', 'manhattan',
      'brooklyn', 'queens', 'bronx', 'staten island'],
  ),
  (key: 'clifton park', aliases: ['clifton park', 'clifton-park']),
  (key: 'westchester', aliases: ['westchester', 'white plains']),
  (key: 'long island', aliases: ['long island', 'long-island', 'cedarhurst', 'huntington', 'great neck']),
  (key: 'new jersey', aliases: ['new jersey', 'new-jersey']),
  // Spain — multi-city clinic/directory paths (/madrid/, /a-coruna/, …)
  (key: 'madrid', aliases: ['madrid']),
  (key: 'barcelona', aliases: ['barcelona', 'bcn']),
  (key: 'valencia', aliases: ['valencia', 'valència']),
  (key: 'sevilla', aliases: ['sevilla', 'seville']),
  (key: 'malaga', aliases: ['malaga', 'málaga']),
  (key: 'bilbao', aliases: ['bilbao']),
  (key: 'alicante', aliases: ['alicante', 'alacant']),
  (key: 'zaragoza', aliases: ['zaragoza']),
  (key: 'murcia', aliases: ['murcia']),
  (key: 'granada', aliases: ['granada']),
  (key: 'cordoba', aliases: ['cordoba', 'córdoba']),
  (key: 'vigo', aliases: ['vigo']),
  (
    key: 'a coruna',
    aliases: [
      'a coruna',
      'a coruña',
      'la coruna',
      'la coruña',
      'coruna',
      'coruña',
    ],
  ),
  (key: 'palma', aliases: ['palma', 'palma de mallorca']),
  (key: 'oviedo', aliases: ['oviedo']),
  (key: 'gijon', aliases: ['gijon', 'gijón']),
  (key: 'marbella', aliases: ['marbella']),
  (
    key: 'san sebastian',
    aliases: ['san sebastian', 'san sebastián', 'donostia'],
  ),
];

/// Shared canonical city key for Firestore / cache / discovery / Compare.
/// Accents fold: Timișoara → timisoara, Chișinău → chisinau.
String exploreCanonicalCityKey(String city) {
  final folded = foldExploreCityText(city).trim().toLowerCase();
  if (folded.isEmpty) return '';
  final packed = folded.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  for (final peer in _kExplorePeerCityMarks) {
    if (folded == peer.key || packed == peer.key.replaceAll(' ', '')) {
      return peer.key;
    }
    for (final alias in peer.aliases) {
      final a = foldExploreCityText(alias).toLowerCase();
      if (a.isEmpty) continue;
      if (folded == a || packed == a.replaceAll(cachedRegExp(r'[\s_-]+'), '')) {
        return peer.key;
      }
    }
  }
  return folded;
}

/// Fold Latin + common diacritics for city/cache keys (NFD + map).
String foldExploreCityText(String raw) {
  final nfd = raw
      .replaceAll('\u00a0', ' ')
      .trim()
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('İ', 'i')
      .replaceAll('ß', 'ss');
  // Strip combining marks after NFD so São/München fold without a city list.
  final decomposed = nfd.replaceAll(cachedRegExp(r'[\u0300-\u036f]'), '');
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçýăâîșşțţğ';
  const to = 'aaaaaaeeeeiiiiooooouuuuncyaaissttg';
  final buf = StringBuffer();
  for (final rune in decomposed.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buf.write(i >= 0 ? to[i] : ch);
  }
  return buf.toString();
}

/// True when two city labels are the same locality under folding / aliases.
/// Does not imply same country — callers must still compare [ExploreCityIdentity].
bool exploreCityLabelsAliasMatch(
  String a,
  String b, {
  List<String> aliases = const [],
}) {
  final fa = foldExploreCityText(a);
  final fb = foldExploreCityText(b);
  if (fa.isEmpty || fb.isEmpty) return false;
  if (fa == fb) return true;
  final pa = fa.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  final pb = fb.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  if (pa == pb) return true;
  final set = <String>{
    fa,
    pa,
    for (final x in aliases) foldExploreCityText(x),
    for (final x in aliases)
      foldExploreCityText(x).replaceAll(cachedRegExp(r'[\s_-]+'), ''),
  }..removeWhere((e) => e.isEmpty);
  return set.contains(fb) || set.contains(pb);
}

String? _explorePeerCityKey(String city) {
  final canonical = exploreCanonicalCityKey(city);
  if (canonical.isEmpty) return null;
  for (final peer in _kExplorePeerCityMarks) {
    if (peer.key == canonical) return peer.key;
  }
  final lo = city.trim().toLowerCase();
  if (lo.isEmpty) return null;
  final packed = lo.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  for (final peer in _kExplorePeerCityMarks) {
    if (lo.contains(peer.key) ||
        packed.contains(peer.key.replaceAll(' ', ''))) {
      return peer.key;
    }
    for (final alias in peer.aliases) {
      if (alias.contains(cachedRegExp(r'[a-z]')) && lo.contains(alias)) {
        return peer.key;
      }
      if (city.contains(alias)) return peer.key;
    }
  }
  return null;
}

/// A city token matches as a whole word. "roma" is not inside "romania".
bool _exploreLatinCityTokenIn(String foldedText, String aliasFold) {
  final token = aliasFold.trim();
  if (token.length < 4) return false;
  if (!cachedRegExp(r'^[a-z0-9 \-]+$').hasMatch(token)) return false;
  bool bounded(String needle) {
    if (needle.length < 4) return false;
    return cachedRegExp(
      '(?:^|[^a-z0-9])${RegExp.escape(needle)}(?:[^a-z0-9]|\$)',
    ).hasMatch(foldedText);
  }

  if (bounded(token)) return true;
  final dashed = token.replaceAll(cachedRegExp(r'\s+'), '-');
  if (dashed != token && bounded(dashed)) return true;
  final packed = token.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  if (packed != token && packed.length >= 6 && bounded(packed)) return true;
  return false;
}

bool _blobMentionsCityKey(String blob, String cityKey) {
  if (blob.trim().isEmpty || cityKey.isEmpty) return false;
  ({String key, List<String> aliases})? peer;
  for (final p in _kExplorePeerCityMarks) {
    if (p.key == cityKey) {
      peer = p;
      break;
    }
  }
  if (peer == null) return false;
  final folded = foldExploreCityText(blob);
  for (final alias in peer.aliases) {
    if (alias.isEmpty) continue;
    final aliasFold = foldExploreCityText(alias);
    if (_exploreLatinCityTokenIn(folded, aliasFold)) return true;
    if (!cachedRegExp(r'^[a-z0-9 \-]+$').hasMatch(aliasFold) &&
        blob.contains(alias)) {
      return true;
    }
  }
  return false;
}

/// Booking / marketplace pages only when clinic identity location strongly
/// matches the searched city (address, URL, or page copy). Peer-city conflict
/// always fails. No clinic- or city-specific allowlists.
bool exploreMarketplaceLocationStronglyMatches({
  required String city,
  String placeAddress = '',
  String sourceUrl = '',
  String pageText = '',
}) {
  final c = city.trim();
  if (c.isEmpty) return false;
  if (explorePlacesAddressConflictsWithSearchCity(placeAddress, c)) {
    return false;
  }
  if (exploreUrlConflictsWithSearchCity(sourceUrl, c)) return false;
  if (exploreTextConflictsWithSearchCity(pageText, c)) return false;
  if (exploreQuotedPriceConflictsWithSearchCity(
    city: c,
    url: sourceUrl,
    evidence: pageText,
  )) {
    return false;
  }

  final blob = '${explorePlacesAddressLocalityText(placeAddress)} $sourceUrl $pageText'.toLowerCase();
  final cityLo = c.toLowerCase();
  final tokens = cityLo
      .split(cachedRegExp(r'[^a-z0-9\u0600-\u06ff]+'))
      .where((t) => t.length >= 3)
      .toList();
  if (tokens.any(blob.contains)) return true;

  final key = _explorePeerCityKey(c);
  if (key != null && _blobMentionsCityKey(blob, key)) return true;

  // Packed city form: "abu dhabi" → "abudhabi" in URLs.
  final packed = cityLo.replaceAll(cachedRegExp(r'[\s_-]+'), '');
  if (packed.length >= 5 &&
      blob.replaceAll(cachedRegExp(r'[\s_-]+'), '').contains(packed)) {
    return true;
  }
  return false;
}

/// Keep locality evidence without mistaking a city-named street for a city.
String explorePlacesAddressLocalityText(String address) {
  final parts = address.split(',');
  if (parts.length < 2) return address;
  final first = foldExploreCityText(parts.first).trim();
  // City-named streets are not the address locality ("C. de Murcia" in
  // Madrid, "London Road" in Dubai). Retain district, postal city and country.
  if (cachedRegExp(r'^(?:\d+\s|c\s*[./]|calle\b|avenida\b|av\.|paseo\b|plaza\b|'
      r'rue\b|boulevard\b|via\b|viale\b|strada\b|street\b)|'
      r'\b(?:road|street|avenue|boulevard|lane)\s*$', caseSensitive: false)
      .hasMatch(first)) return parts.skip(1).join(',');
  return address;
}

/// Maps address is in Dubai while Compare is searching Abu Dhabi.
bool explorePlacesAddressConflictsWithSearchCity(String address, String city) {
  final searchKey = _explorePeerCityKey(city);
  if (searchKey == null || address.trim().isEmpty) return false;
  for (final peer in _kExplorePeerCityMarks) {
    if (peer.key == searchKey) continue;
    if (_blobMentionsCityKey(explorePlacesAddressLocalityText(address), peer.key)) return true;
  }
  return false;
}

/// FAQ / SEO copy that names another Gulf city and not the searched one.
bool exploreTextConflictsWithSearchCity(String text, String city) {
  final searchKey = _explorePeerCityKey(city);
  if (searchKey == null || text.trim().isEmpty) return false;
  final searchMentioned = _blobMentionsCityKey(text, searchKey);
  for (final peer in _kExplorePeerCityMarks) {
    if (peer.key == searchKey) continue;
    if (_blobMentionsCityKey(text, peer.key) && !searchMentioned) {
      return true;
    }
  }
  return false;
}

/// A generated "Abu Dhabi" area label cannot relocate a Dubai provider.
/// A foreign-named provider needs an own-city page path or tariff sentence.
bool exploreProviderIdentityConflictsWithSearchCity({
  required String city,
  required String name,
  required String sourceUrl,
  String evidence = '',
}) {
  final key = _explorePeerCityKey(city);
  if (key == null) return false;
  final uri = Uri.tryParse(sourceUrl);
  final identity = foldExploreCityText('$name ${uri?.host ?? ''}')
      .replaceAll(cachedRegExp(r'[^a-z0-9\u0600-\u06ff]'), '');
  bool identityMentions(String cityKey) => _kExplorePeerCityMarks
      .where((p) => p.key == cityKey).expand((p) => p.aliases)
      .map((a) => foldExploreCityText(a).replaceAll(cachedRegExp(r'[^a-z0-9\u0600-\u06ff]'), ''))
      .where((a) => a.length >= 4).any(identity.contains);
  if (identityMentions(key)) return false;
  final foreign = _kExplorePeerCityMarks.any((p) => p.key != key && identityMentions(p.key));
  if (!foreign) return false;
  return !_blobMentionsCityKey('${uri?.path ?? ''} $evidence', key);
}

bool _urlHasCityToken(String url, String cityToken) {
  return _exploreLatinCityTokenIn(
    foldExploreCityText(url),
    foldExploreCityText(cityToken),
  );
}

/// Strong branch evidence: URL path contains searched city / alias
/// (`/preturi/brasov/`, `/brasov-2/`). Not “query mentioned the city.”
bool exploreUrlStronglyMatchesSearchCity(String url, String city) {
  if (city.trim().isEmpty || url.trim().isEmpty) return false;
  final searchKey = _explorePeerCityKey(city);
  final foldedCity = foldExploreCityText(city);
  final tokens = <String>{
    if (foldedCity.isNotEmpty) foldedCity,
    if (searchKey != null) searchKey,
  };
  if (searchKey != null) {
    for (final peer in _kExplorePeerCityMarks) {
      if (peer.key != searchKey) continue;
      for (final alias in peer.aliases) {
        final a = foldExploreCityText(alias);
        if (a.length >= 4) tokens.add(a);
      }
    }
  }
  String path;
  try {
    final uri = Uri.parse(url.contains('://') ? url : 'https://$url');
    path = uri.path.toLowerCase();
  } catch (_) {
    path = url.toLowerCase();
  }
  for (final token in tokens) {
    final packed = token.replaceAll(cachedRegExp(r'[\s_-]+'), '');
    if (packed.length < 4) continue;
    if (cachedRegExp(
          '/$packed(?:-\\d+)?(?:/|\$)',
          caseSensitive: false,
        ).hasMatch(path) ||
        path.contains('/$packed/') ||
        path.endsWith('/$packed')) {
      return true;
    }
  }
  return false;
}

/// Dubai menu copy ("أسعار البوتوكس في دبي") is not an Abu Dhabi quote,
/// even when the SEO title also names Abu Dhabi.
bool exploreQuotedPriceConflictsWithSearchCity({
  required String city,
  String url = '',
  String evidence = '',
}) {
  if (city.trim().isEmpty || city.trim().toLowerCase() == 'worldwide') return false;
  if (exploreUrlConflictsWithSearchCity(url, city)) return true;
  if (exploreQuotedPriceDestinationConflicts(evidence, city)) return true;
  // Explicit tariff headings can name any branch, including cities absent
  // from the peer-city list. Do not let the URL override that branch.
  final scope = cachedRegExp(
    r'(?:precio|coste|costo|price|cost)\b[^|:!?€$]{0,85}\b(?:en|in)\s+([^|:!?€$\d]{1,45})\s*[|:]',
    caseSensitive: false,
  ).firstMatch(evidence);
  if (scope != null &&
      !exploreCityLabelsAliasMatch(scope.group(1)!.trim(), city) &&
      !foldExploreCityText(evidence).contains(foldExploreCityText(city))) {
    return true;
  }
  final searchKey = _explorePeerCityKey(city);
  if (searchKey == null) return false;
  // An own-city URL must not turn an explicitly foreign-only price quote
  // into a local price. Shared-city evidence still passes this check.
  if (exploreTextConflictsWithSearchCity(evidence, city)) return true;
  final blob = '$url $evidence';
  if (blob.trim().isEmpty) return false;
  // A price explicitly scoped to both cities can apply to either one.
  if (_blobMentionsCityKey(blob, searchKey)) return false;
  // "Motor City" is Dubai even when the sentence never writes the city name.
  if (searchKey != 'dubai' &&
      cachedRegExp(r'\bmotor city\b|\bdubai marina\b', caseSensitive: false)
          .hasMatch(blob)) {
    return true;
  }
  for (final peer in _kExplorePeerCityMarks) {
    if (peer.key == searchKey) continue;
    for (final alias in peer.aliases) {
      if (alias.isEmpty) continue;
      final a = RegExp.escape(alias);
      if (cachedRegExp(
        '(?:precio|coste|costo|cost|costs|price|prices|pricing|أسعار|تكلفة).{0,48}$a',
        caseSensitive: false,
      ).hasMatch(blob)) {
        return true;
      }
    }
  }
  return false;
}

bool exploreQuotedPriceDestinationConflicts(String evidence, String city) {
  final requested = exploreCountryCodeForCity(city).toUpperCase();
  if (requested.isEmpty || evidence.trim().isEmpty) return false;
  const destinations = <String, List<String>>{
    'AE': ['uae', 'united arab emirates'], 'IR': ['iran', 'إيران', 'ايران'],
    'TR': ['turkey'], 'IN': ['india'], 'US': ['united states', 'usa'],
    'AL': ['albania'], 'RO': ['romania'], 'IT': ['italy'],
    'GB': ['united kingdom', 'uk'], 'DE': ['germany'], 'FR': ['france'],
  };
  for (final entry in destinations.entries) {
    if (entry.key == requested) continue;
    for (final name in entry.value) {
      if (cachedRegExp(
        r'(?:\b(?:costs?|prices?|pricing|tariffs?|fees?|prezzi|prezzo|costo)\b|تكلفة|أسعار)'
        r'[^.!?\n|]{0,80}(?:\bin\s+(?:the\s+)?|في\s+)' +
        RegExp.escape(name) + r'(?!\w)', caseSensitive: false,
      ).hasMatch(evidence)) return true;
    }
  }
  return false;
}

/// `/hair-transplant-in-dubai/` is not an Abu Dhabi listing.
/// `/preturi/iasi` is not a Timisoara listing. A shared-city tariff can match
/// either city; its quoted price and clinic address are checked separately.
bool exploreUrlConflictsWithSearchCity(String url, String city) {
  if (city.trim().isEmpty || url.trim().isEmpty) return false;
  final searchKey = _explorePeerCityKey(city);
  final cityLo = foldExploreCityText(city);
  String path;
  try {
    path = Uri.parse(url.contains('://') ? url : 'https://$url').path;
  } catch (_) {
    path = url.split('?').first.split('#').first;
  }
  final searchInPath = searchKey != null
      ? _blobMentionsCityKey(path, searchKey)
      : _urlHasCityToken(path, cityLo);
  if (searchInPath) return false;
  for (final peer in _kExplorePeerCityMarks) {
    if (searchKey != null && peer.key == searchKey) continue;
    if (searchKey == null &&
        (cityLo.contains(peer.key) ||
            cityLo.contains(peer.key.replaceAll(' ', '')))) {
      continue;
    }
    for (final alias in peer.aliases) {
      final a = foldExploreCityText(alias);
      if (a.length < 4) continue;
      if (!cachedRegExp(r'^[a-z0-9 \-]+$').hasMatch(a)) continue;
      if (_urlHasCityToken(url, a)) return true;
    }
  }
  return false;
}

/// The city printed on the card ("Tiranë") is a different country from the
/// search ("Budapest"). A district label that is not itself a city stays.
bool exploreDisplayedLocalityConflictsWithSearchCity(String area, String city) {
  final searchCc = exploreCountryCodeForCity(city);
  if (searchCc.isEmpty || area.trim().isEmpty) return false;
  final head = area.split(cachedRegExp(r'[·|]')).first.trim();
  if (head.isEmpty || head.contains('.')) return false;
  final headFold = foldExploreCityText(
    head,
  ).replaceAll(cachedRegExp(r'[^a-z0-9]+'), '');
  final searchFold = foldExploreCityText(
    city,
  ).replaceAll(cachedRegExp(r'[^a-z0-9]+'), '');
  if (searchFold.length >= 4 && headFold.contains(searchFold)) return false;
  if (exploreCityLabelsAliasMatch(head, city)) return false;
  final headCc = exploreCountryCodeForCity(head);
  return headCc.isNotEmpty && headCc != searchCc;
}

/// True when this listing belongs in the searched city (not a Romania
/// `.ro` peel on Dubai, or a Dutch euro homepage for a Dubai branch).
bool exploreListingFitsSearchCity({
  required String city,
  String host = '',
  String currency = '',
  String priceLabel = '',
  String procedureText = '',
  String area = '',
  String url = '',
  bool verifiedSourceCity = false,
}) {
  final c = city.trim();
  if (c.isEmpty || c.toLowerCase() == 'worldwide') return true;
  if (exploreDisplayedLocalityConflictsWithSearchCity(area, c)) return false;
  if (explorePlacesAddressConflictsWithSearchCity(area, c)) {
    return false;
  }
  if (url.isNotEmpty && exploreUrlConflictsWithSearchCity(url, c)) {
    return false;
  }
  final locBlob = '$procedureText $priceLabel $area $url';
  if (exploreQuotedPriceConflictsWithSearchCity(
    city: c,
    url: url,
    evidence: locBlob,
  )) {
    return false;
  }
  if (exploreTextConflictsWithSearchCity(locBlob, c)) {
    return false;
  }
  if (host.isNotEmpty && !exploreHostFitsSearchCity(host, c)) {
    return false;
  }
  var cur = currency.trim();
  if (cur.isEmpty) {
    cur = CityCurrency.normalizeCode(
      FilterFx.detectCodeFromLabel(priceLabel, fallback: ''),
    );
  }
  if (cur.isNotEmpty && !exploreCurrencyFitsSearchCity(cur, c)) {
    // Currency is a hint, not geography: local clinics also quote foreign
    // currencies. Require actual source-location evidence or the discovery
    // verifier's city match, never just the UI's generated area label.
    final sourceLocation = '$procedureText $priceLabel $url';
    final mentionsCity = _blobMentionsCityKey(sourceLocation, exploreCanonicalCityKey(c)) ||
        _exploreLatinCityTokenIn(foldExploreCityText(sourceLocation), foldExploreCityText(c));
    if (!verifiedSourceCity && !mentionsCity) return false;
  }
  final loc = exploreCityPriceSearchTerms(c);
  final t = procedureText.toLowerCase();
  if (t.isEmpty) return true;
  if (loc.lang != 'ro' &&
      loc.lang != 'en' &&
      cachedRegExp(
        r'peeling chimic|rinoplastie|m[aă]rire|acid hialuronic|'
        r'toxina botulinica|transplant de par',
      ).hasMatch(t)) {
    return false;
  }
  if (loc.lang != 'nl' &&
      cachedRegExp(r'\boplossen\b|\bprijzen\b|\bbehandeling\b').hasMatch(t)) {
    return false;
  }
  return true;
}

/// Local Google names for a treatment family (`botox`, `filler`, …).
/// First entry is the primary search phrase in that language.
List<String> exploreProcedureNamesForLang(String family, String lang) {
  final fam = family.trim().toLowerCase();
  final byFam = _kProcedureNames[lang];
  if (byFam == null) return const [];
  return byFam[fam] ?? const [];
}

/// Distinctive local spellings so a French/Spanish/… page still matches
/// the English procedure family (e.g. "mammaire" → breast).
List<String> exploreLocalProcedureTokens(String family) {
  final fam = family.trim().toLowerCase();
  final cached = _tokenCache[fam];
  if (cached != null) return cached;
  final out = <String>{};
  for (final byFam in _kProcedureNames.values) {
    for (final name in byFam[fam] ?? const <String>[]) {
      final n = name.toLowerCase().trim();
      if (n.length < 4) continue;
      out.add(n);
    }
  }
  final list = out.toList(growable: false);
  _tokenCache[fam] = list;
  return list;
}

/// Always pair English with the local language (Spain, France, Korea, …).
bool exploreKeepsEnglishAlongsideLocal(String lang) {
  final l = lang.trim().toLowerCase();
  return l.isNotEmpty && l != 'en';
}

/// Local-language Google queries first (Spain, France, Turkey, …).
bool explorePrefersLocalSearchFirst(String lang) {
  const prefer = {
    'es',
    'fr',
    'it',
    'de',
    'tr',
    'pt',
    'ro',
    'pl',
    'nl',
    'ru',
    'uk',
    'el',
    'cs',
    'hu',
    'sv',
    'da',
    'no',
    'fi',
    'sr',
    'ar',
    'ko',
    'ja',
    'zh',
    'hi',
    'th',
    // Balkans / Caucasus — Tirana peels used only English queries without
    // these, so Serper never ranked local peel menus (botoxtirana /sq/, …).
    'sq',
    'bg',
    'mk',
    'bs',
    'hr',
    'sl',
    'sk',
    'ka',
  };
  return prefer.contains(lang.trim().toLowerCase());
}

/// Curated `_kProcedureNames` has nothing for this family + language.
bool exploreCuratedLocalNamesInsufficient({
  required String family,
  required String lang,
}) {
  final l = lang.trim().toLowerCase();
  if (l.isEmpty || l == 'en') return false;
  return exploreProcedureNamesForLang(family, l).isEmpty;
}

final Map<String, List<String>> _tokenCache = {};

const _kProcedureNames = <String, Map<String, List<String>>>{
  'en': {
    'botox': [
      'botox',
      'anti-wrinkle',
      'botulinum',
      'dysport',
      'xeomin',
      'neuronox',
    ],
    'filler': [
      'dermal filler',
      'lip filler',
      'cheek filler',
      'hyaluronic acid',
      'juvederm',
      'juvederm volbella',
      'restylane',
      'restylane kysse',
      'teosyal',
      'belotero',
      'stylage',
      'revanesse',
      'radiesse',
      'fillmed',
      'art filler',
    ],
    'laser': ['laser hair removal', 'laser hair'],
    'peel': ['chemical peel', 'peels', 'tca peel', 'jet peel', 'prx'],
    'skin': ['skin booster', 'profhilo', 'biorevitalization'],
    'rhinoplasty': ['rhinoplasty', 'nose job', 'nose reshaping'],
    'breast': ['breast augmentation', 'breast implants', 'boob job'],
    'hair': ['hair transplant', 'hair restoration', 'FUE'],
  },
  'ro': {
    'botox': [
      'botox',
      'toxina botulinica',
      'toxina botulinică',
      'botulotoxina',
      'neuronox',
      'xeomin',
      '1 zona facial',
      '1 zonă facial',
    ],
    'filler': [
      'filler buze',
      'filler dermal',
      'acid hialuronic',
      'acid hialuronic buze',
      'marire buze',
      'mărire buze',
      'augmentarea buzelor',
      'volumizare buze',
      'juvederm',
      'restylane',
      'teosyal',
      'belotero',
      'stylage',
      'radiesse',
      'fillmed',
      'art filler',
    ],
    'laser': ['epilare laser', 'epilare definitiva'],
    'peel': ['peeling chimic', 'peeling tca', 'peeling aha', 'jet peel', 'prx'],
    'skin': ['skinbooster', 'profhilo', 'polinucleotide', 'biorevitalizare'],
    'rhinoplasty': [
      'rinoplastie',
      'rinoplastie multizonala',
      'rinoseptoplastie',
    ],
    'breast': [
      'marire sani',
      'mărirea sânilor',
      'augmentare mamara',
      'implant mamar',
    ],
    'hair': [
      'transplant par',
      'implant de par',
      'transplant de par',
      'implant par',
      'FUE',
    ],
  },
  'es': {
    'botox': [
      'botox',
      'toxina botulinica',
      'toxina botulínica',
      'botox arrugas',
      'tratamiento antiarrugas',
      'arrugas de expresion',
      'arrugas de expresión',
      'neuromoduladores',
    ],
    'filler': [
      'relleno de labios',
      'acido hialuronico',
      'acido hialuronico labios',
      'aumento de labios',
    ],
    'laser': ['depilacion laser', 'depilación láser'],
    'peel': ['peeling quimico', 'peeling químico', 'peeling facial'],
    'skin': ['skinbooster', 'profhilo', 'polinucleotidos'],
    'rhinoplasty': ['rinoplastia'],
    'breast': ['aumento de pecho', 'aumento mamario', 'mamoplastia'],
    'hair': ['injerto capilar', 'transplante capilar', 'FUE'],
  },
  'it': {
    'botox': ['botox', 'tossina botulinica'],
    'filler': ['filler labbra', 'acido ialuronico'],
    'laser': ['epilazione laser'],
    'peel': ['peeling chimico'],
    'skin': ['skinbooster', 'profhilo', 'polinucleotidi'],
    'rhinoplasty': ['rinoplastica'],
    'breast': ['mastoplastica additiva', 'protesi seno'],
    'hair': ['trapianto capelli', 'FUE'],
  },
  'fr': {
    'botox': ['botox', 'toxine botulique', 'injections anti-rides'],
    'filler': ['acide hyaluronique', 'injections levres', 'filler levres'],
    'laser': ['epilation laser', 'épilation laser'],
    'peel': ['peeling chimique', 'peeling visage', 'peeling TCA'],
    'skin': ['skinbooster', 'profhilo', 'polynucleotides'],
    'rhinoplasty': ['rhinoplastie'],
    'breast': [
      'augmentation mammaire',
      'prothese mammaire',
      'implants mammaires',
    ],
    'hair': ['greffe de cheveux', 'greffe capillaire', 'FUE'],
  },
  'de': {
    'botox': ['Botox', 'Botulinum'],
    'filler': ['Hyaluron', 'Lippen aufspritzen', 'Hyaluronsaeure'],
    'laser': ['Laser Haarentfernung', 'Haarentfernung Laser'],
    'peel': ['chemisches Peeling', 'Fruchtsaeurepeeling'],
    'skin': ['Skinbooster', 'Profhilo', 'Polynukleotide'],
    'rhinoplasty': ['Nasenkorrektur', 'Rhinoplastik'],
    'breast': ['Brustvergroesserung', 'Brustvergrößerung', 'Brustimplantat'],
    'hair': ['Haartransplantation', 'FUE'],
  },
  'tr': {
    'botox': [
      'botoks',
      'botulinum toksini',
      'kırışıklık tedavisi',
      'kirisiklik tedavisi',
    ],
    'filler': [
      'dudak dolgusu',
      'dermal dolgu',
      'hyaluronik asit dolgusu',
      'yüz dolgusu',
      'yuz dolgusu',
      'yanak dolgusu',
    ],
    'laser': ['lazer epilasyon'],
    'peel': ['kimyasal peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': [
      'rinoplasti',
      'burun estetigi',
      'burun estetiği',
      'burun ameliyatı',
      'burun ameliyati',
      'burun estetiği fiyatları',
    ],
    'breast': [
      'meme buyutme',
      'meme büyütme',
      'göğüs büyütme',
      'gogus buyutme',
      'meme implantı',
      'meme implantı',
      'silikon protez',
      'meme protezi',
      'gogus protezi',
    ],
    'hair': ['sac ekimi', 'saç ekimi', 'FUE'],
  },
  'pt': {
    'botox': ['botox', 'toxina botulinica'],
    'filler': ['preenchimento labial', 'acido hialuronico'],
    'laser': ['depilacao a laser', 'depilação a laser'],
    'peel': ['peeling quimico', 'peeling químico'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['rinoplastia'],
    'breast': ['aumento mamario', 'protese de mama', 'mamoplastia de aumento'],
    'hair': ['transplante capilar', 'FUE'],
  },
  'nl': {
    'botox': ['botox'],
    'filler': ['lipfiller', 'hyaluronzuur'],
    'laser': ['laserontharing', 'ontharing laser'],
    'peel': ['chemische peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['neuscorrectie'],
    'breast': ['borstvergroting', 'borstimplantaten'],
    'hair': ['haartransplantatie', 'FUE'],
  },
  'pl': {
    'botox': ['botoks', 'botox'],
    'filler': ['wypelniacze ust', 'kwas hialuronowy'],
    'laser': ['depilacja laserowa'],
    'peel': ['peeling chemiczny'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['korekcja nosa', 'rhinoplastyka'],
    'breast': ['powiekszenie piersi', 'implant piersi'],
    'hair': ['przeszczep wlosow', 'FUE'],
  },
  'ko': {
    'botox': ['보톡스'],
    'filler': ['필러', '입술필러'],
    'laser': ['레이저제모', '레이저'],
    'peel': ['화학박피', '필링'],
    'skin': ['스킨부스터', '프로필로'],
    'rhinoplasty': ['코성형'],
    'breast': ['가슴성형', '가슴확대'],
    'hair': ['모발이식', 'FUE'],
  },
  'ar': {
    'botox': ['بوتوكس', 'توكسين البوتولينوم'],
    'filler': ['فيلر', 'فيلر شفايف', 'فيلر الشفاه', 'حمض الهيالورونيك'],
    'laser': ['ليزر ازالة الشعر', 'إزالة الشعر بالليزر'],
    'peel': ['تقشير كيميائي', 'تقشير البشرة'],
    'skin': ['سكين بوستر', 'بروفيهلو'],
    'rhinoplasty': ['تجميل الانف', 'عملية تجميل الأنف', 'رأب الأنف'],
    'breast': ['تكبير الثدي', 'زراعة الثدي', 'تكبير الصدر'],
    'hair': ['زراعة الشعر', 'زراعة شعر', 'FUE'],
  },
  'ja': {
    'botox': ['ボトックス'],
    'filler': ['ヒアルロン酸', '唇フィラー'],
    'laser': ['医療脱毛', 'レーザー脱毛'],
    'peel': ['ケミカルピーリング'],
    'skin': ['スキンブースター', 'プロファイロ'],
    'rhinoplasty': ['鼻整形'],
    'breast': ['豊胸'],
    'hair': ['自毛植毛', 'FUE'],
  },
  'ru': {
    'botox': ['ботокс'],
    'filler': ['филлер губ', 'гиалуроновая кислота'],
    'laser': ['лазерная эпиляция'],
    'peel': ['химический пилинг'],
    'skin': ['скинбустер', 'профайло'],
    'rhinoplasty': ['ринопластика'],
    'breast': ['увеличение груди', 'маммопластика'],
    'hair': ['пересадка волос', 'FUE'],
  },
  'uk': {
    'botox': ['ботокс'],
    'filler': ['філер губ', 'гіалуронова кислота'],
    'laser': ['лазерна епіляція'],
    'peel': ['хімічний пілінг'],
    'skin': ['скінбустер'],
    'rhinoplasty': ['ринопластика'],
    'breast': ['збільшення грудей'],
    'hair': ['пересадка волосся', 'FUE'],
  },
  'bg': {
    'botox': ['ботокс', 'ботулинов токсин'],
    'filler': [
      'филър',
      'хиалуронова киселина',
      'филър за устни',
      'дермален филър',
    ],
    'laser': ['лазерна епилация'],
    'peel': ['химичен пилинг', 'пилинг'],
    'skin': ['скинбустер', 'профайло'],
    'rhinoplasty': ['ринопластика', 'операция на носа', 'корекция на носа'],
    'breast': [
      'уголемяване на бюст',
      'уголемяване на гърди',
      'гръдни импланти',
      'импланти за бюст',
    ],
    'hair': [
      'трансплантация на коса',
      'присаждане на коса',
      'трансплантация на коса FUE',
      'FUE',
    ],
  },
  'el': {
    'botox': ['μποτοξ', 'botox'],
    'filler': ['υαλουρονικο', 'filler χειλιων'],
    'laser': ['αποτριχωση laser'],
    'peel': ['χημικο πιλινγκ'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['ρινοπλαστικη'],
    'breast': ['αυξηση στηθους'],
    'hair': ['μεταμοσχευση μαλλιων', 'FUE'],
  },
  'cs': {
    'botox': ['botox'],
    'filler': ['vyplne rtu', 'kyselina hyaluronova'],
    'laser': ['laserova epilace'],
    'peel': ['chemicky peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['korekce nosu'],
    'breast': ['zvetšení prsou', 'augmentace prsou'],
    'hair': ['transplantace vlasu', 'FUE'],
  },
  'hu': {
    'botox': ['botox'],
    'filler': ['ajakfeltoltes', 'hialuronsav'],
    'laser': ['lezeres szortelenites'],
    'peel': ['kemiai hamlaztas'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['orrplasztika'],
    'breast': ['mellnagyobbitas'],
    'hair': ['hajbeultetes', 'FUE'],
  },
  'sv': {
    'botox': ['botox'],
    'filler': ['läppfiller', 'hyaluronsyra'],
    'laser': ['laserhårborttagning'],
    'peel': ['kemisk peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['näsoperation'],
    'breast': ['bröstförstoring'],
    'hair': ['hårtransplantation', 'FUE'],
  },
  'da': {
    'botox': ['botox'],
    'filler': ['læbefiller', 'hyaluronsyre'],
    'laser': ['laser hårfjerning'],
    'peel': ['kemisk peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['næseoperation'],
    'breast': ['brystforstørrelse'],
    'hair': ['hårtransplantation', 'FUE'],
  },
  'no': {
    'botox': ['botox'],
    'filler': ['leppefiller', 'hyaluronsyre'],
    'laser': ['laser hårfjerning'],
    'peel': ['kjemisk peeling'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['neseoperasjon'],
    'breast': ['brystforstørrelse'],
    'hair': ['hårtransplantasjon', 'FUE'],
  },
  'fi': {
    'botox': ['botox'],
    'filler': ['huulitäyte', 'hyaluronihappo'],
    'laser': ['laser karvanpoisto'],
    'peel': ['kemiallinen kuorinta'],
    'skin': ['skinbooster', 'profhilo'],
    'rhinoplasty': ['nenäleikkaus'],
    'breast': ['rintojen suurennus'],
    'hair': ['hiussiirre', 'FUE'],
  },
  'zh': {
    'botox': ['肉毒', '保妥适'],
    'filler': ['玻尿酸', '丰唇'],
    'laser': ['激光脱毛', '激光'],
    'peel': ['化学换肤', '果酸换肤'],
    'skin': ['皮肤针', 'profhilo'],
    'rhinoplasty': ['隆鼻'],
    'breast': ['隆胸'],
    'hair': ['植发', 'FUE'],
  },
  'th': {
    'botox': ['โบท็อกซ์', 'botox'],
    'filler': ['ฟิลเลอร์ปาก', 'ฟิลเลอร์'],
    'laser': ['เลเซอร์กำจัดขน'],
    'peel': ['เคมีคอลพีล'],
    'skin': ['สกินบูสเตอร์'],
    'rhinoplasty': ['เสริมจมูก'],
    'breast': ['เสริมหน้าอก'],
    'hair': ['ปลูกผม', 'FUE'],
  },
  'hi': {
    'botox': ['बोटॉक्स', 'botox'],
    'filler': ['लिप फिलर', 'हायलूरोनिक'],
    'laser': ['लेजर हेयर रिमूवल'],
    'peel': ['केमिकल पील'],
    'skin': ['स्किन बूस्टर'],
    'rhinoplasty': ['नाक की सर्जरी'],
    'breast': ['ब्रेस्ट ऑगमेंटेशन'],
    'hair': ['हेयर ट्रांसप्लांट', 'FUE'],
  },
  'he': {
    'botox': ['בוטוקס'],
    'filler': ['פילר שפתיים'],
    'laser': ['הסרת שיער בלייזר'],
    'peel': ['פילינג כימי'],
    'skin': ['סקין בוסטר'],
    'rhinoplasty': ['ניתוח אף'],
    'breast': ['הגדלת חזה'],
    'hair': ['השתלת שיער', 'FUE'],
  },
  'vi': {
    'botox': ['botox'],
    'filler': ['filler moi', 'acid hyaluronic'],
    'laser': ['triet long laser'],
    'peel': ['peel da hoa chat'],
    'skin': ['skinbooster'],
    'rhinoplasty': ['nang mui'],
    'breast': ['nang nguc'],
    'hair': ['cay toc', 'FUE'],
  },
  'sr': {
    'botox': ['botoks', 'botox'],
    'filler': ['fileri usana', 'hijaluron'],
    'laser': ['laserska epilacija'],
    'peel': ['hemijski piling'],
    'skin': ['skinbooster'],
    'rhinoplasty': ['korekcija nosa'],
    'breast': ['povecanje grudi'],
    'hair': ['transplantacija kose', 'FUE'],
  },
  // Albania / Kosovo. Without this Tirana Peels only queried English
  // "chemical peel prices" and never ranked local menus that publish
  // BioRePeel / PRX under "peeling kimik" / "qërimi".
  'sq': {
    'botox': ['botox', 'botoks', 'toksina botulinike'],
    'filler': [
      'filler',
      'filler buze',
      'acid hialuronik',
      'mbushje buze',
      'juvederm',
      'restylane',
    ],
    'laser': ['epilim me lazer', 'lazer'],
    'peel': [
      'peeling kimik',
      'peeling',
      'qërimi',
      'qerimi',
      'biorepeel',
      'prx',
      'prx-t33',
      'peeling tca',
      'cosmelan',
    ],
    'skin': ['skinbooster', 'profhilo', 'mezoterapi'],
    'rhinoplasty': ['rinoplastike', 'rinoplastika', 'operacion hunde'],
    'breast': ['zmadhim gjiri', 'implant gjiri'],
    'hair': ['transplant flokesh', 'transplantimi i flokeve', 'FUE'],
  },
};
