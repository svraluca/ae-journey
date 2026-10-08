/// Maps vague country searches to a compare hub city.
String normalizeExploreCity(String raw) {
  final c = raw.trim();
  if (c.isEmpty) return c;
  final lower = c.toLowerCase();
  if (lower == 'korea' ||
      lower == 'south korea' ||
      lower == '대한민국' ||
      lower == '한국') {
    return 'Seoul';
  }
  if (lower == 'delhi' || lower == 'newdelhi') return 'New Delhi';
  if (lower == 'india') return 'New Delhi';
  if (lower == 'japan') return 'Tokyo';
  if (lower == 'turkey' || lower == 'türkiye') return 'Istanbul';
  if (lower == 'uae' || lower == 'united arab emirates') return 'Dubai';
  if (lower == 'uk' || lower == 'united kingdom' || lower == 'england') {
    return 'London';
  }
  if (lower == 'usa' || lower == 'united states' || lower == 'us') {
    return 'New York';
  }
  if (lower == 'chișinău' ||
      lower == 'chisinău' ||
      lower == 'kishinev' ||
      lower == 'kishinau') {
    return 'Chisinau';
  }
  return c;
}

/// Local currency for a compare-tab city (clinic prices + default filter).
abstract final class CityCurrency {
  static String localCode(String city) {
    final c = city.toLowerCase().trim();
    if (c.isEmpty) return r'$';

    if (_matches(c, const [
      'beirut',
      'lebanon',
      'tripoli',
      'sidon',
    ])) {
      return r'$';
    }
    if (_matches(c, const [
      'los angeles',
      'new york',
      'miami',
      'chicago',
      'houston',
      'dallas',
      'plano',
      'frisco',
      'fort worth',
      'atlanta',
      'austin',
      'boston',
      'charlotte',
      'denver',
      'las vegas',
      'vegas',
      'nashville',
      'orlando',
      'phoenix',
      'scottsdale',
      'washington',
      'washington dc',
      'tampa',
      'san diego',
      'san francisco',
      'usa',
      'united states',
      ', us',
    ])) {
      return r'$';
    }
    if (_matches(c, const [
      'bucharest',
      'bucurești',
      'cluj',
      'timișoara',
      'iași',
      'braşov',
      'romania',
      'românia',
    ])) {
      return 'RON';
    }
    if (_matches(c, const [
      'chisinau',
      'chișinău',
      'chisinău',
      'moldova',
    ])) {
      return 'MDL';
    }
    if (_matches(c, const [
      'london',
      'manchester',
      'birmingham',
      'uk',
      'england',
      'scotland',
    ])) {
      return '£';
    }
    if (_matches(c, const ['istanbul', 'ankara', 'turkey', 'türkiye'])) {
      return 'TRY';
    }
    if (_matches(c, const ['warsaw', 'krakow', 'poland'])) {
      return 'PLN';
    }
    if (_matches(c, const ['dubai', 'abu dhabi', 'uae'])) {
      return 'AED';
    }
    if (_matches(c, const ['moscow', 'russia'])) {
      return 'RUB';
    }
    if (_matches(c, const [
      'seoul',
      'busan',
      'korea',
      'south korea',
      '대한민국',
      '한국',
    ])) {
      return '₩';
    }
    if (_matches(c, const [
      'tokyo',
      'osaka',
      'japan',
    ])) {
      return 'JPY';
    }
    if (_matches(c, const [
      'hong kong',
      'hongkong',
      'hk',
    ])) {
      return 'HKD';
    }
    if (_matches(c, const [
      'new delhi',
      'delhi',
      'mumbai',
      'bangalore',
      'bengaluru',
      'hyderabad',
      'chennai',
      'india',
    ])) {
      return 'INR';
    }
    if (_matches(c, const [
      'singapore',
    ])) {
      return 'SGD';
    }
    if (_matches(c, const [
      'bangkok',
      'phuket',
      'thailand',
    ])) {
      return 'THB';
    }
    if (_matches(c, const [
      'sydney',
      'melbourne',
      'australia',
    ])) {
      return 'AUD';
    }
    if (_matches(c, const [
      'toronto',
      'vancouver',
      'calgary',
      'edmonton',
      'halifax',
      'hamilton',
      'kelowna',
      'montreal',
      'montréal',
      'ottawa',
      'quebec',
      'québec',
      'saskatoon',
      'victoria',
      'winnipeg',
      'markham',
      'mississauga',
      'oakville',
      'richmond hill',
      'vaughan',
      'burnaby',
      'surrey',
      'canada',
    ])) {
      return 'CAD';
    }
    if (_matches(c, const [
      'zurich',
      'geneva',
      'switzerland',
    ])) {
      return 'CHF';
    }
    if (_matches(c, const [
      'shanghai',
      'beijing',
      'guangzhou',
      'shenzhen',
      'china',
    ])) {
      return 'CNY';
    }
    if (_matches(c, const [
      'paris',
      'milan',
      'barcelona',
      'berlin',
      'madrid',
      'rome',
      'france',
      'italy',
      'spain',
      'germany',
    ])) {
      return '€';
    }
    if (_matches(c, const [
      'sofia',
      'plovdiv',
      'varna',
      'burgas',
      'bulgaria',
      'българия',
    ])) {
      return 'BGN';
    }
    // Unknown city — do NOT default to € (that forced wrong currency on HK etc.).
    return '';
  }

  static FilterCurrency? filterForCityOrNull(String city) {
    final code = localCode(city);
    if (code.isEmpty) return null;
    return filterForCity(city);
  }

  static FilterCurrency filterForCity(String city) {
    return switch (localCode(city)) {
      r'$' || 'USD' => FilterCurrency.dollar,
      '£' || 'GBP' => FilterCurrency.gbp,
      'AED' => FilterCurrency.aed,
      'TRY' => FilterCurrency.lira,
      'RUB' || '₽' => FilterCurrency.ruble,
      '₩' || 'KRW' => FilterCurrency.yuan,
      'JPY' => FilterCurrency.jpy,
      'AUD' => FilterCurrency.aud,
      'CAD' => FilterCurrency.cad,
      'MDL' => FilterCurrency.dollar,
      'CHF' => FilterCurrency.chf,
      'CNY' || '¥' => FilterCurrency.yuan,
      'HKD' || 'SGD' || 'THB' || 'INR' => FilterCurrency.dollar,
      'RON' || 'LEI' => FilterCurrency.euro,
      '€' || 'EUR' => FilterCurrency.euro,
      _ => FilterCurrency.euro,
    };
  }

  static bool matches(String a, String b) {
    final x = normalizeCode(a);
    final y = normalizeCode(b);
    if (x.isEmpty || y.isEmpty) return false;
    return x == y;
  }

  /// Normalizes currency symbols/codes for compare (e.g. EUR→€, HK$→HKD).
  static String normalizeCode(String raw) {
    return _canonical(raw);
  }

  static String _canonical(String raw) {
    final t = raw.trim().toUpperCase();
    // HK$ / S$ use a trailing dollar — avoid '$' inside quotes for the analyzer.
    if (t == 'HKD' || t == 'HK\u0024') return 'HKD';
    if (t == 'SGD' || t == 'S\u0024') return 'SGD';
    if (t == 'INR' || t == 'RS' || t == '₹') return 'INR';
    return switch (t) {
      r'$' || 'USD' || r'US$' || 'DOLLAR' => r'$',
      '€' || 'EUR' || 'EURO' => '€',
      '£' || 'GBP' || 'POUND' => '£',
      'RON' || 'LEI' => 'RON',
      'TRY' || 'TL' || 'LIRA' || '₺' => 'TRY',
      'PLN' => 'PLN',
      'AED' => 'AED',
      'RUB' || 'RUR' || 'RUBLE' || '₽' => 'RUB',
      '₩' || 'KRW' || 'WON' => '₩',
      'JPY' || 'YEN' => 'JPY',
      'THB' || '฿' => 'THB',
      'AUD' => 'AUD',
      'CAD' => 'CAD',
      'CHF' => 'CHF',
      'CNY' || 'RMB' || 'YUAN' => 'CNY',
      'MDL' || 'LEU' => 'MDL',
      'BGN' || 'LV' || 'ЛВ' => 'BGN',
      _ => raw.trim(),
    };
  }

  static bool _matches(String city, List<String> needles) {
    for (final n in needles) {
      if (city.contains(n)) return true;
    }
    return false;
  }
}

/// Display currencies for Explore filters + approximate FX conversion.
enum FilterCurrency {
  euro,
  lira,
  dollar,
  ruble,
  aed,
  yuan,
  gbp,
  jod,
  omr,
  bhd,
  kwd,
  chf,
  jpy,
  cad,
  aud,
}

extension FilterCurrencyX on FilterCurrency {
  String get symbol => switch (this) {
        FilterCurrency.euro => '€',
        FilterCurrency.lira => '₺',
        FilterCurrency.dollar => r'$',
        FilterCurrency.ruble => '₽',
        FilterCurrency.aed => 'AED',
        FilterCurrency.yuan => '¥',
        FilterCurrency.gbp => '£',
        FilterCurrency.jod => 'JOD',
        FilterCurrency.omr => 'OMR',
        FilterCurrency.bhd => 'BHD',
        FilterCurrency.kwd => 'KWD',
        FilterCurrency.chf => 'CHF',
        FilterCurrency.jpy => 'JPY',
        FilterCurrency.cad => 'CAD',
        FilterCurrency.aud => 'AUD',
      };

  String get label => switch (this) {
        FilterCurrency.euro => 'Euro',
        FilterCurrency.lira => 'Lira',
        FilterCurrency.dollar => 'Dollar',
        FilterCurrency.ruble => 'Ruble',
        FilterCurrency.aed => 'AED',
        FilterCurrency.yuan => 'Yuan',
        FilterCurrency.gbp => 'GBP',
        FilterCurrency.jod => 'JOD',
        FilterCurrency.omr => 'OMR',
        FilterCurrency.bhd => 'BHD',
        FilterCurrency.kwd => 'KWD',
        FilterCurrency.chf => 'CHF',
        FilterCurrency.jpy => 'JPY',
        FilterCurrency.cad => 'CAD',
        FilterCurrency.aud => 'AUD',
      };

  /// Units of this currency per 1 USD (approximate guide rates).
  double get unitsPerUsd => switch (this) {
        FilterCurrency.dollar => 1.0,
        FilterCurrency.euro => 0.92,
        FilterCurrency.lira => 34.5,
        FilterCurrency.ruble => 92.0,
        FilterCurrency.aed => 3.6725,
        FilterCurrency.yuan => 7.25,
        FilterCurrency.gbp => 0.79,
        FilterCurrency.jod => 0.709,
        FilterCurrency.omr => 0.385,
        FilterCurrency.bhd => 0.376,
        FilterCurrency.kwd => 0.307,
        FilterCurrency.chf => 0.88,
        FilterCurrency.jpy => 150.0,
        FilterCurrency.cad => 1.36,
        FilterCurrency.aud => 1.53,
      };
}

/// Approximate static FX helpers for Explore map / list price conversion.
abstract final class FilterFx {
  /// Units of [code] per 1 USD. Supports clinic currency strings / symbols.
  static double unitsPerUsdForCode(String raw) {
    final t = raw.trim().toUpperCase();
    if (t.isEmpty) return 1.0;
    if (t == r'$' || t == 'USD' || t == r'US$' || t == 'DOLLAR') return 1.0;
    if (t == '€' || t == 'EUR' || t == 'EURO') return 0.92;
    if (t == '£' || t == 'GBP' || t == 'POUND') return 0.79;
    if (t == '₺' || t == 'TRY' || t == 'TL' || t == 'LIRA') return 34.5;
    if (t == '₽' || t == 'RUB' || t == 'RUBLE' || t == 'RUR') return 92.0;
    if (t == 'AED' || t == 'د.إ') return 3.6725;
    if (t == '¥' || t == 'CNY' || t == 'RMB' || t == 'YUAN') return 7.25;
    if (t == 'JPY' || t == 'YEN') return 150.0;
    if (t == 'CAD') return 1.36;
    if (t == 'AUD') return 1.53;
    if (t == 'RON' || t == 'LEI') return 4.55;
    if (t == '₩' || t == 'KRW' || t == 'WON') return 1350.0;
    if (t == 'HKD' || t == 'HK\u0024') return 7.8;
    if (t == 'SGD' || t == 'S\u0024') return 1.35;
    if (t == 'INR' || t == '₹' || t == 'RS') return 83.0;
    if (t == 'THB' || t == '฿') return 36.0;
    if (t == 'JOD') return 0.709;
    if (t == 'OMR') return 0.385;
    if (t == 'BHD') return 0.376;
    if (t == 'KWD') return 0.307;
    if (t == 'CHF' || t == 'FR' || t == 'SFR') return 0.88;
    return 1.0;
  }

  static double convert({
    required double amount,
    required String fromCode,
    required FilterCurrency to,
  }) {
    if (amount <= 0) return 0;
    final from = unitsPerUsdForCode(fromCode);
    final usd = amount / from;
    return usd * to.unitsPerUsd;
  }

  static String formatAmount(double amount, FilterCurrency to, {bool fromPrefix = true}) {
    final n = _formatNum(amount);
    final body = '$n ${to.symbol}';
    return fromPrefix ? 'from $body' : body;
  }

  static String _formatNum(double v) {
    // Gulf dinars / OMR often use 3 decimals; keep 1–0 for larger amounts.
    final n = v >= 1000
        ? v.roundToDouble()
        : (v >= 100
            ? v.roundToDouble()
            : (v >= 10 ? (v * 10).round() / 10 : (v * 100).round() / 100));
    if (n == n.roundToDouble()) {
      final s = n.round().toString();
      final buf = StringBuffer();
      for (var i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
        buf.write(s[i]);
      }
      return buf.toString();
    }
    if (n < 10) return n.toStringAsFixed(2);
    return n.toStringAsFixed(1);
  }

  /// Detect currency code/symbol from a price label like "from 1,690 €" or "AED 42".
  static String detectCodeFromLabel(String label, {String fallback = ''}) {
    final t = label.trim();
    if (t.isEmpty) return fallback;
    final code = RegExp(
      r'\b(AED|USD|EUR|GBP|TRY|RUB|CNY|RON|LEI|KRW|JPY|HKD|SGD|THB|AUD|CAD|CHF|INR|JOD|OMR|BHD|KWD)\b',
      caseSensitive: false,
    ).firstMatch(t);
    if (code != null) return code.group(1)!.toUpperCase();
    if (RegExp(r'HK\$|HKD', caseSensitive: false).hasMatch(t)) return 'HKD';
    if (RegExp(r'S\$|SGD', caseSensitive: false).hasMatch(t)) return 'SGD';
    if (RegExp(r'₹|\bINR\b|\bRs\.?\b', caseSensitive: false).hasMatch(t)) {
      return 'INR';
    }
    final sym = RegExp(r'[£€$₽₺¥₩฿₹]').firstMatch(t);
    if (sym != null) return sym.group(0)!;
    return fallback;
  }

  /// First numeric amount in a label (handles commas).
  static double? parseAmount(String label) {
    final m = RegExp(r'(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?').firstMatch(label);
    if (m == null) return null;
    final whole = m.group(1)!.replaceAll(',', '');
    final frac = m.group(2);
    return double.tryParse(frac == null ? whole : '$whole.$frac');
  }
}
