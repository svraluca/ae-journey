import 'explore_regex_cache.dart';

/// Lexical currency detection. Never use unbounded `contains('pen')` / `try`.
/// Prefer a symbol or ISO code adjacent to the amount over unrelated prose.

final _isoUnambiguous = cachedRegExp(
  r'\b(?:USD|EUR|GBP|RON|MDL|PLN|AED|SAR|QAR|KWD|BHD|OMR|CHF|'
  r'CAD|AUD|NZD|JPY|CNY|HKD|KRW|INR|SGD|MYR|THB|IDR|BRL|MXN|'
  r'CLP|CZK|HUF|SEK|NOK|DKK|ZAR|BGN|'
  // Markets the locale table already searches but could not price:
  // Balkans, Caucasus, Central Asia, South Asia, Africa, SE Asia.
  r'MKD|RSD|UAH|ISK|KZT|AZN|AMD|GEL|BDT|PKR|NGN|KES|PHP|TWD|VND|'
  r'EGP|JOD|LBP|IQD|MAD|TND|DZD|UYU|DOP|GTQ|BOB|PYG|CRC|HNL)\b',
  caseSensitive: false,
);

/// Collide with English words (`try`, `depending`/`pen`, `cop`, `ars`) if
/// matched case-insensitively. `ALL` (Albanian lek) is the worst offender —
/// "ALL TREATMENTS" is a heading on half the menus in this dataset — so it is
/// only read as a currency directly beside an amount, in [_currencyFromIso].
final _isoUppercaseOnly = cachedRegExp(r'\b(?:TRY|PEN|COP|ARS|BAM)\b');

/// Albanian lek written as an ISO code has to touch the number: "3500 ALL",
/// "ALL 3500". A bare "ALL" in prose is the English word.
final _lekIsoBesideAmount = cachedRegExp(
  r'(?:\d\s*ALL\b|\bALL\s*\d)',
);

String _windowAroundFirstAmount(String raw) {
  final m = cachedRegExp(r'(.{0,28})(\d[\d.,]*)(.{0,28})').firstMatch(raw);
  return m?.group(0) ?? '';
}

String _currencyFromSymbols(String s) {
  if (s.contains(r'R$')) return 'BRL';
  if (cachedRegExp(r'S/\.?\s*\d|\d\s*S/\.?|(?:^|[\s(])S/\.?(?=\s|$)').hasMatch(s)) {
    return 'PEN';
  }
  if (cachedRegExp(r'Mex\$', caseSensitive: false).hasMatch(s)) return 'MXN';
  if (cachedRegExp(r'HK\$', caseSensitive: false).hasMatch(s)) return 'HKD';
  if (cachedRegExp(r'NZ\$', caseSensitive: false).hasMatch(s)) return 'NZD';
  if (cachedRegExp(r'(?:^|[\s(])(?:AU\$|A\$)', caseSensitive: false).hasMatch(s)) {
    return 'AUD';
  }
  if (cachedRegExp(r'(?:^|[\s(])(?:C\$|Can\$)', caseSensitive: false).hasMatch(s)) {
    return 'CAD';
  }
  if (cachedRegExp(r'(?:^|[\s(])S\$').hasMatch(s)) return 'SGD';
  if (s.contains('£')) return 'GBP';
  if (s.contains('€')) return 'EUR';
  if (s.contains('₩') || s.contains('원')) return 'KRW';
  if (s.contains('₹')) return 'INR';
  if (s.contains('฿')) return 'THB';
  if (s.contains('د.إ') || s.contains('درهم')) return 'AED';
  if (s.contains('ر.س')) return 'SAR';
  if (s.contains('ر.ق')) return 'QAR';
  if (s.contains('د.ك')) return 'KWD';
  if (s.contains('د.ب')) return 'BHD';
  if (s.contains('ر.ع')) return 'OMR';
  if (s.contains('₺')) return 'TRY';
  if (s.toLowerCase().contains('zł')) return 'PLN';
  if (cachedRegExp(r'Kč', caseSensitive: false).hasMatch(s)) return 'CZK';
  if (s.contains('¥') || s.contains('円')) {
    if (cachedRegExp(r'\b(?:CNY|RMB|yuan)\b', caseSensitive: false).hasMatch(s) ||
        s.contains('元')) {
      return 'CNY';
    }
    return 'JPY';
  }
  if (s.contains(r'$')) return 'USD';
  return '';
}

String _currencyFromIso(String s) {
  if (_lekIsoBesideAmount.hasMatch(s)) return 'ALL';
  final upper = _isoUppercaseOnly.firstMatch(s);
  if (upper != null) return upper.group(0)!.toUpperCase();
  final safe = _isoUnambiguous.firstMatch(s);
  if (safe != null) return safe.group(0)!.toUpperCase();
  return '';
}

String _currencyFromLocalAbbrev(String s) {
  // Albanian menus write "3500 Lekë" / "3.500 leke" far more often than "ALL".
  // Checked before `lei` so Albanian "lekë" cannot be read as Romanian leu.
  if (cachedRegExp(r'\b(?:lek[ëe]?t?|lek[ëe]ve)\b',
          caseSensitive: false)
      .hasMatch(s)) {
    return 'ALL';
  }
  if (cachedRegExp(r'\b(?:lei|leul)\b', caseSensitive: false).hasMatch(s)) {
    return 'RON';
  }
  // Serbian / Macedonian / Bosnian menus print "12.000 din." / "ден" / "KM".
  // Dart's `\b` is ASCII-only, so a Cyrillic token must be anchored on the
  // amount instead — "ден" is also a fragment of ordinary Macedonian words.
  if (cachedRegExp(r'\bdin\.?\b', caseSensitive: false).hasMatch(s) ||
      cachedRegExp(r'\d\s*дин\.?').hasMatch(s)) {
    return 'RSD';
  }
  if (cachedRegExp(r'\d\s*ден\.?').hasMatch(s)) return 'MKD';
  if (cachedRegExp(r'\d\s*KM\b').hasMatch(s)) return 'BAM';
  if (cachedRegExp(r'грн|₴').hasMatch(s)) return 'UAH';
  if (cachedRegExp(r'\b(?:kč)\b', caseSensitive: false).hasMatch(s)) {
    return 'CZK';
  }
  // Bulgarian lev — menus print "250 BGN", "300 lv.", "лв".
  if (cachedRegExp(r'\b(?:bgn|lv\.?|лв\.?)\b', caseSensitive: false)
      .hasMatch(s)) {
    return 'BGN';
  }
  if (cachedRegExp(r'\beuros?\b', caseSensitive: false).hasMatch(s)) return 'EUR';
  if (cachedRegExp(r'\bdirhams?\b', caseSensitive: false).hasMatch(s)) return 'AED';
  if (cachedRegExp(r'\bTL\b').hasMatch(s)) return 'TRY';
  if (cachedRegExp(r'\b(?:zl)\b', caseSensitive: false).hasMatch(s)) return 'PLN';
  if (cachedRegExp(r'\bRM\b').hasMatch(s)) return 'MYR';
  if (cachedRegExp(r'\bRp\.?\b').hasMatch(s)) return 'IDR';
  if (cachedRegExp(r'\bRs\.?\b').hasMatch(s)) return 'INR';
  if (cachedRegExp(r'\bFt\b').hasMatch(s)) return 'HUF';
  if (cachedRegExp(r'\bfr\.\b', caseSensitive: false).hasMatch(s)) return 'CHF';
  if (cachedRegExp(r'\bR\s+\d').hasMatch(s) || cachedRegExp(r'\bZAR\b').hasMatch(s)) {
    return 'ZAR';
  }
  if (cachedRegExp(r'\bkr\b', caseSensitive: false).hasMatch(s)) {
    if (cachedRegExp(r'\bNOK\b').hasMatch(s) ||
        cachedRegExp(r'norway|norge', caseSensitive: false).hasMatch(s)) {
      return 'NOK';
    }
    if (cachedRegExp(r'\bDKK\b').hasMatch(s) ||
        cachedRegExp(r'denmark|dansk', caseSensitive: false).hasMatch(s)) {
      return 'DKK';
    }
    return 'SEK';
  }
  if (s.contains('元') || cachedRegExp(r'\bRMB\b', caseSensitive: false).hasMatch(s)) {
    return 'CNY';
  }
  return '';
}

String _detectCurrencyIn(String raw) {
  final fromSymbol = _currencyFromSymbols(raw);
  if (fromSymbol.isNotEmpty) return fromSymbol;
  final fromIso = _currencyFromIso(raw);
  if (fromIso.isNotEmpty) return fromIso;
  return _currencyFromLocalAbbrev(raw);
}

/// Public parser used by HTML extract and price sanity.
String detectExploreCurrencyToken(String raw) {
  final text = raw.replaceAll('\u00a0', ' ');
  if (text.trim().isEmpty) return '';
  final near = _windowAroundFirstAmount(text);
  if (near.isNotEmpty) {
    final fromNear = _detectCurrencyIn(near);
    if (fromNear.isNotEmpty) return fromNear;
  }
  return _detectCurrencyIn(text);
}

bool hasExploreCurrencySignal(String raw) =>
    detectExploreCurrencyToken(raw).isNotEmpty;

String stripCurrencyTokensForNumberParse(String raw) {
  return raw
      .replaceAll(
        cachedRegExp(r'R\$|S/\.?|Mex\$|HK\$|NZ\$|AU\$|A\$|C\$|Can\$|S\$',
            caseSensitive: false),
        ' ',
      )
      .replaceAll(cachedRegExp(r'[€£$¥₩₹฿₺]'), ' ')
      .replaceAll(_isoUnambiguous, ' ')
      .replaceAll(_isoUppercaseOnly, ' ')
      .replaceAll(
        cachedRegExp(
          r'\b(?:lei|leul|lek[ëe]?t?|lek[ëe]ve|euros?|dirhams?|TL|zl|zł|RM|'
          r'Rp\.?|Rs\.?|Ft|fr\.|kr|bgn|lv\.?|лв\.?|din\.?|дин\.?|ден\.?|'
          r'грн|kč)\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(cachedRegExp(r'₴'), ' ')
      .replaceAll(cachedRegExp(r'د\.إ|درهم|ر\.س|ر\.ق|د\.ك|د\.ب|ر\.ع|元|円|원'), ' ');
}
