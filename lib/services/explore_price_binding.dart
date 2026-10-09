import 'explore_regex_cache.dart';
import 'explore_tariff_scope.dart';

/// Bind a published amount and procedure subtype to the same menu row.
/// Pure Dart so the price rules can be checked without Flutter or Firebase.
const _publishedNumber =
    r'(?:\d{1,3}(?:[., \u00a0\u202f]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)';
const _publishedCurrency =
    r'(?:EUR\b|euros?\b|€|GBP\b|£|USD\b|\$|AED\b|HUF\b|Ft\b|RON\b|lei\b|BGN\b|TRY\b|TL\b|₺|ALL\b|Lek\b)';
final _publishedPrice = cachedRegExp(
  '(?<![\\d.,])(?:($_publishedCurrency)\\s*($_publishedNumber)|'
  '($_publishedNumber)\\s*($_publishedCurrency))(?!\\d|[.,]\\d)',
  caseSensitive: false,
);
final _repeatedStartingPrice = cachedRegExp(
  r'^\s*(?:(?:from|starting\s+from|starts?\s+from|de\s+la|desde|a\s+partir\s+de|a\s+partire\s+da|nga|ab)\s*)?[€$£\s]*$',
  caseSensitive: false,
);

String _bindingFold(String text) {
  var result = text.toLowerCase();
  const accents = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ă': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'í': 'i',
    'î': 'i',
    'ó': 'o',
    'ö': 'o',
    'ő': 'o',
    'ú': 'u',
    'ü': 'u',
    'ű': 'u',
    'ș': 's',
    'ş': 's',
    'ț': 't',
    'ţ': 't',
  };
  for (final entry in accents.entries) {
    result = result.replaceAll(entry.key, entry.value);
  }
  return result;
}

String _bindingCurrency(String value) {
  return switch (value.trim().toUpperCase()) {
    '€' || 'EURO' || 'EUROS' => 'EUR',
    '£' => 'GBP',
    r'$' => 'USD',
    'FT' => 'HUF',
    'LEI' => 'RON',
    'TL' || '₺' => 'TRY',
    'LEK' => 'ALL',
    final code => code,
  };
}

double? _bindingAmount(String value) {
  var text = value.replaceAll(cachedRegExp(r'[\s\u00a0\u202f]'), '');
  if (cachedRegExp(r'^\d{1,3}(?:[.,]\d{3})+$').hasMatch(text)) {
    return double.tryParse(text.replaceAll(cachedRegExp(r'[.,]'), ''));
  }
  final comma = text.lastIndexOf(',');
  final dot = text.lastIndexOf('.');
  if (comma >= 0 && dot >= 0) {
    final decimal = comma > dot ? ',' : '.';
    text = text.replaceAll(decimal == ',' ? '.' : ',', '');
    if (decimal == ',') text = text.replaceAll(',', '.');
  } else if (comma >= 0) {
    text = text.replaceAll(',', '.');
  }
  return double.tryParse(text);
}

/// A generated rawPriceText is not evidence. The retained source excerpt must
/// contain this amount beside its currency (including either end of a range).
bool exploreEvidenceQuotesPrice({required String evidence, required double amount,
  required String currency, double? priceMax}) {
  final code = _bindingCurrency(currency);
  if (evidence.trim().isEmpty || code.isEmpty || amount <= 0) return false;
  final aliases = switch (code) {
    'EUR' => r'EUR\b|euros?\b|€', 'USD' => r'USD\b|\$', 'GBP' => r'GBP\b|£',
    'TRY' => r'TRY\b|TL\b|₺', 'RON' => r'RON\b|lei\b',
    'AED' => r'AED\b|dirhams?\b|درهم|د\.?إ',
    'HUF' => r'HUF\b|Ft\b', 'BGN' => r'BGN\b|лв',
    _ => '${RegExp.escape(code)}\\b',
  };
  final cur = '(?:$aliases)';
  const separator = r'(?:[-–—]|to|ile|ila)';
  final quotes = cachedRegExp(
    '(?<![\\w.,])(?:$cur\\s*($_publishedNumber)'
    '(?:\\s*$separator\\s*(?:$cur\\s*)?($_publishedNumber))?|'
    '($_publishedNumber)(?:\\s*(?:$cur\\s*)?$separator\\s*($_publishedNumber))?\\s*$cur)',
    caseSensitive: false,
  );
  for (final match in quotes.allMatches(evidence)) {
    final values = <double>[];
    for (var i = 1; i <= 4; i++) {
      final n = _bindingAmount(match.group(i) ?? '');
      if (n != null) values.add(n);
    }
    if (!values.any((n) => (n - amount).abs() < .011)) continue;
    if (priceMax == null || (priceMax - amount).abs() < .011) return true;
    if (values.length == 2 && values.any((n) => (n - priceMax).abs() < .011)) {
      return true;
    }
  }
  return false;
}

class _BoundPrice {
  const _BoundPrice(this.match, this.amount, this.currency);
  final RegExpMatch match;
  final double amount;
  final String currency;
}

List<_BoundPrice> _bindingPrices(String text) {
  final result = <_BoundPrice>[];
  for (final match in _publishedPrice.allMatches(text)) {
    final amount = _bindingAmount(match.group(2) ?? match.group(3)!);
    if (amount == null) continue;
    result.add(
      _BoundPrice(
        match,
        amount,
        _bindingCurrency(match.group(1) ?? match.group(4)!),
      ),
    );
  }
  return result;
}

/// Reject a filler amount followed by a Botox heading in flattened evidence.
bool exploreBotoxAmountOwnedByFiller({
  required String evidence, required double priceMin, required String currency,
}) {
  final prices = _bindingPrices(evidence);
  final code = _bindingCurrency(currency);
  var conflicts = 0;
  for (var i = 0; i < prices.length; i++) {
    final price = prices[i];
    if (price.currency != code || (price.amount - priceMin).abs() > .011) continue;
    final start = i == 0 ? 0 : prices[i - 1].match.end;
    final prefix = _bindingFold(evidence.substring(start, price.match.start));
    final toxin = cachedRegExp(r'\b(?:botox|botulin\w*|neuromodulat\w*)\b').allMatches(prefix).toList();
    final filler = cachedRegExp(r'\b(?:hyaluronic\s+acid|acid[ou]\s+hialuronic[ou]?|fillers?|aumento\s+(?:labial|de\s+labios)|relleno\s+de\s+labios)\b').allMatches(prefix).toList();
    if (toxin.isNotEmpty && (filler.isEmpty || toxin.last.start > filler.last.start)) return false;
    if (filler.isNotEmpty) conflicts++;
  }
  return conflicts > 0;
}

/// Amount-scoped exclusions also apply to saved rows from older extractors.
String? exploreNonTreatmentPriceReason({
  required String evidence, required double priceMin, required String currency,
  String procedure = '',
}) {
  if (exploreMarketComparisonContext(evidence)) return 'market_comparison_table';
  final folded = _bindingFold(evidence);
  const months = r'january|february|march|april|may|june|july|august|september|october|november|december|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre';
  if (cachedRegExp('\\b(?:promo\\w*|oferta|offer)\\b.{0,110}\\b(?:$months)\\b|'
      '\\b(?:$months)\\b.{0,45}\\b(?:promo\\w*|offer)\\b|'
      '\\b(?:durante el mes de|during the month of)\\s+(?:$months)\\b').hasMatch(folded)) {
    return 'seasonal_offer_unconfirmed';
  }
  final prices = _bindingPrices(evidence);
  if (_publishedPriceIsSuperseded(evidence, priceMin, currency, prices)) {
    return 'superseded_price';
  }
  String? rejected;
  for (var i = 0; i < prices.length; i++) {
    final p = prices[i];
    if (p.currency != _bindingCurrency(currency) || (p.amount-priceMin).abs() > .011) continue;
    final start = i == 0 ? 0 : prices[i-1].match.end;
    final prefix = _bindingFold(evidence.substring(start, p.match.start));
    final end = i+1 < prices.length ? prices[i+1].match.start : evidence.length;
    final tail = _bindingFold(evidence.substring(p.match.end, end));
    final scopeFailure = exploreAncillaryPriceReason(procedure, prefix) ??
        exploreCalendarPriceReason(p.amount, prefix, tail);
    if (scopeFailure != null) return scopeFailure;
    final near = _bindingFold(evidence.substring(
      (p.match.start - 240).clamp(0, evidence.length),
      (p.match.end + 240).clamp(0, evidence.length),
    ));
    final creditContext = cachedRegExp(
      r'\b(?:financi\w*|credit\w*|prestamo\w*|loans?|cuotas?|installments?)\b',
    ).hasMatch(near);
    final creditCap = cachedRegExp(
      r'\b(?:hasta|up\s+to|maximum|maximo|limite(?:\s+de)?\s+credito|credit\s+limit|loan\s+limit)\s*[:=-]?\s*$',
    ).hasMatch(prefix);
    if (creditContext && creditCap) {
      rejected = 'credit_limit';
    } else if (cachedRegExp(
      r'\b(?:pack\s+amigas?|friends?\s+pack|bring\s+(?:a\s+)?friend|ven\s+con\s+una\s+amiga|'
      r'en\s+pareja|couples?\s+offer|couples?\s+price|per\s+couple)\b',
    ).hasMatch(prefix)) {
      rejected = 'conditional_offer';
    } else if (cachedRegExp(r'\b(?:promedio|(?:precio|coste|costo)s?\s+medi[oa]s?|clinicas? low cost|precio orientativo (?:en|de)|precios orientativos|rangos orientativos)\b').hasMatch(prefix)) {
      rejected = 'market_average';
    } else if (cachedRegExp(r'\brinoplastia\s+parcial\b').hasMatch(prefix)) {
      rejected = 'partial_rhinoplasty';
    } else if (cachedRegExp(r'\b(?:cuanto cuestan los implantes mamarios|por par de implantes|precio de (?:los )?implantes mamarios en espana)\b').hasMatch(prefix)) {
      rejected = 'implant_component_price';
    } else if (cachedRegExp(r'\b(?:en pareja|couples? offer|couples? price|per couple)\b').hasMatch(prefix)) {
      rejected = 'conditional_offer';
    } else if (cachedRegExp(r'\b(?:aesthetic medicine appointment|consultation fee|initial consultation|consulta inicial|primera visita)\b').hasMatch(prefix) ||
        (cachedRegExp(r'\bappointment\b').hasMatch(prefix) && cachedRegExp(r'^.{0,40}\bredeemable\b').hasMatch(tail))) {
      rejected = 'consultation_fee';
    } else {
      return null;
    }
  }
  return rejected;
}

/// Preserve uncertainty only when it qualifies the published currency amount.
bool explorePublishedPriceIsApproximate({
  required String evidence,
  double priceMin = 0,
}) {
  final qualifier = cachedRegExp(
    r'\b(?:approximately|approx\.?|roughly|around|about|aproximadamente|'
    r'aproximad[oa]s?|suele\s+rondar|ronda|en\s+torno\s+a)'
    r'\s+(?:(?:los?|unos?|entre)\s+)?$',
  );
  for (final price in _bindingPrices(evidence)) {
    if (priceMin > 0 && (price.amount - priceMin).abs() > 0.011) continue;
    final before = _bindingFold(evidence.substring(
      (price.match.start - 80).clamp(0, evidence.length),
      price.match.start,
    ));
    if (qualifier.hasMatch(before)) return true;
  }
  return false;
}

String exploreProcedureTitleWithoutPromotion(String raw) => raw
    .replaceAll(cachedRegExp(r'\b\d+(?:[.,]\d+)?\s*%\s*off\b', caseSensitive: false), '')
    .replaceAll(cachedRegExp(r'\bsave\s+(?:AED|EUR|USD|GBP|[$€£])?\s*\d[\d.,]*\s*(?:AED|EUR|USD|GBP)?\b', caseSensitive: false), '')
    .replaceAll(cachedRegExp(r'\s+'), ' ').trim().replaceAll(cachedRegExp(r'[|·:\s]+$'), '');

/// A discount amount or gift value is not the clinic's payable procedure price.
bool explorePublishedPriceIsIncentive({
  required String evidence,
  required double priceMin,
  required String currency,
}) {
  final code = _bindingCurrency(currency);
  for (final price in _bindingPrices(evidence)) {
    if (price.currency != code || (price.amount - priceMin).abs() > .011) {
      continue;
    }
    final before = _bindingFold(
      evidence.substring(
        (price.match.start - 100).clamp(0, evidence.length),
        price.match.start,
      ),
    ).split(cachedRegExp(r'[|;\n]')).last;
    final after = _bindingFold(
      evidence.substring(
        price.match.end,
        (price.match.end + 100).clamp(0, evidence.length),
      ),
    ).split(cachedRegExp(r'[|;\n]')).first;
    if (cachedRegExp(
          r'\b(?:save(?:\s+up\s+to)?|saving(?:s)?\s+(?:of|up\s+to)|(?:discount|gift|bonus)\s+(?:package|voucher)(?:\s+worth)?|(?:gift|bonus)\s+(?:value|worth)|kedvezmenycsomag|ajandek(?:csomag)?\s+erteke)\s*[:=-]?\s*$',
        ).hasMatch(before) ||
        cachedRegExp(
          r'^\s*(?:worth\b.{0,65}\b(?:discount|gift|bonus)|(?:price\s+)?discount\b|off\b|erteku\b|(?:worth\s+)?(?:gift|bonus)\s+(?:package|voucher)|kedvezmeny(?:csomag)?\b)',
        ).hasMatch(after)) {
      return true;
    }
  }
  return false;
}

/// Reject a cached list price when the same row contains its current price.
/// A cheaper neighboring treatment or a published range is not a promotion.
bool explorePublishedPriceIsSuperseded({
  required String evidence,
  required double priceMin,
  required String currency,
}) {
  return _publishedPriceIsSuperseded(
    evidence, priceMin, currency, _bindingPrices(evidence),
  );
}

bool _publishedPriceIsSuperseded(
  String evidence,
  double priceMin,
  String currency,
  List<_BoundPrice> prices,
) {
  final code = _bindingCurrency(currency);
  for (var i = 0; i + 1 < prices.length; i++) {
    final old = prices[i];
    final current = prices[i + 1];
    if (old.currency != code ||
        current.currency != code ||
        (old.amount - priceMin).abs() > 0.011 ||
        current.amount >= old.amount) {
      continue;
    }
    final between = evidence.substring(old.match.end, current.match.start);
    if (_repeatedStartingPrice.hasMatch(between)) return true;
    final before = _bindingFold(evidence.substring(
      i == 0 ? 0 : prices[i - 1].match.end,
      old.match.start,
    ));
    if (cachedRegExp(r'\b(?:antes|was|old\s+price|previous\s+price|precio\s+anterior)\s*[:=-]?\s*$')
            .hasMatch(before) ||
        cachedRegExp(r'^\s*(?:ahora|now|current\s+price|precio\s+actual)\s*[:=-]?\s*$',
                caseSensitive: false)
            .hasMatch(between) ||
        cachedRegExp(r'\bantes\b.{0,50}\bahora\b').hasMatch(before)) {
      return true;
    }
  }
  return false;
}

String _breastPricedRow(String text, double? amount, String currency) {
  final prices = _bindingPrices(text);
  if (prices.isEmpty) return text;
  var index = prices.indexWhere(
    (price) =>
        amount != null &&
        (price.amount - amount).abs() <= 0.011 &&
        (currency.isEmpty || price.currency == _bindingCurrency(currency)),
  );
  if (index < 0) index = 0;
  final target = prices[index];
  var previous = index - 1;
  if (previous >= 0 &&
      _repeatedStartingPrice.hasMatch(
        text.substring(prices[previous].match.end, target.match.start),
      )) {
    previous--;
  }
  final start = previous < 0 ? 0 : prices[previous].match.end;
  var row = text.substring(start, target.match.end);
  final services = cachedRegExp(
    r'augmentation\s+mastopexy|breast\s+(?:augmentation|enlargement|fat\s+transfer|lift|reduction|reconstruction|implant(?:s|\s+(?:replacement|removal))?)|mastoplastica\s+(?:additt?iva|riduttiva)|mastopessi|aumento\s+seno|mellnagyobbitas|mellfelvarras|mellkisebbites|zmadhim\w*\s+(?:i\s+)?(?:gjoks|gjir)|zvogelim\w*\s+(?:i\s+)?gj',
  ).allMatches(_bindingFold(row)).toList();
  if (services.isNotEmpty) {
    var service = services.last;
    if (services.length > 1) {
      final first = services[0];
      final second = services[1];
      final between = row.substring(first.end, second.start);
      if (first.group(0)!.contains('mastopexy') ||
          cachedRegExp(
            r'\(\s*$|\b(?:and|plus|with)\s*$|\+\s*$',
            caseSensitive: false,
          ).hasMatch(between)) {
        service = first;
      }
    }
    row = row.substring(service.start);
  } else if (_repeatedStartingPrice.hasMatch(
    text.substring(start, target.match.start),
  )) {
    // A table may put the currency/amount cell before its procedure cell.
    final end = index + 1 < prices.length
        ? prices[index + 1].match.start
        : text.length;
    row =
        '${text.substring(target.match.end, end).trim()} '
        '${target.match.group(0)}';
  }
  final note = cachedRegExp(r'^\s*(\([^()]{1,240}\))')
      .firstMatch(text.substring(target.match.end));
  if (note != null && exploreBreastImplantCostExcluded(note.group(1)!)) {
    row = '$row ${note.group(1)}';
  }
  return row;
}

bool exploreBreastImplantCostExcluded(String text) {
  final folded = _bindingFold(text);
  return folded.contains('implant cost excluded') || cachedRegExp(
    r'(?:nu\s+include|nu\s+includ|fara\s+costul|exclud(?:e[sd]?|ing)|does\s+not\s+include|not\s+including|hors|ohne|sin)\s+(?:(?:the|cost|costul|of|de|des|der)\s+){0,3}(?:implant\w*|protez\w*|prothes\w*)|(?:implant\w*|protez\w*|prothes\w*)\s+(?:(?:are|is|costs?)\s+){0,2}(?:not\s+included|excluded|extra|separately|nu\s+sunt\s+incluse|non\s+inclusi)',
  ).hasMatch(folded);
}

String _breastMethod(String text) {
  final folded = _bindingFold(text);
  if (exploreBreastImplantCostExcluded(text)) return 'Implant cost excluded';
  final fat = cachedRegExp(
    r'fat\s+(?:transfer|graft)|(?:own|autologous|autolog|sajat)\s+(?:fat|zsir)|lipofill|lipotransfer|lipomodel|zsiratultet|zsirtolt|grasso|eigenfett|grasime\s+proprie|grasa\s+propia|transfert\s+de\s+graisse|me\s+yndyre',
  ).hasMatch(folded);
  final implants =
      cachedRegExp(
        r'implant|protesi|prothese|protesis|silicone\s+breast|saline\s+breast|\b(?:mentor|motiva|polytech|nagor|allergan)\b',
      ).hasMatch(folded) &&
      !cachedRegExp(
        r'without\s+implants?|no\s+implants?|implant\w*\s+nelkul',
      ).hasMatch(folded);
  final lift = cachedRegExp(
    r'mastopex\w*|mastopessi|breast\s+lift|mellfelvarras|lifting\s+al\s+seno|lift\s*\+|ridicar\w*',
  ).hasMatch(folded);
  if (lift && implants) return 'Lift + implants';
  if (lift && fat) return 'Lift + fat transfer';
  if (fat && implants) return 'Implants + fat transfer';
  if (fat) return 'Fat transfer';
  if (implants) return 'With implants';
  return '';
}

String exploreBreastProcedureDetail({
  required String rawProcedureText,
  String procedureDetail = '',
  String evidence = '',
  double? priceMin,
  String currency = '',
}) {
  // The exact price's row comes first; a broad page can list other methods.
  for (final candidate in [
    _breastPricedRow(evidence, priceMin, currency),
    procedureDetail,
    rawProcedureText,
  ]) {
    final method = _breastMethod(candidate);
    if (method.isNotEmpty) return method;
  }
  return 'Method not specified';
}

String exploreBreastProcedureDisplayName({
  required String rawProcedureText,
  String procedureDetail = '',
  String evidence = '',
  double? priceMin,
  String currency = '',
}) {
  final detail = exploreBreastProcedureDetail(
    rawProcedureText: rawProcedureText,
    procedureDetail: procedureDetail,
    evidence: evidence,
    priceMin: priceMin,
    currency: currency,
  );
  final size = cachedRegExp(r'\b\d+\s*[-–—]\s*\d+\s*cc\b', caseSensitive: false)
      .firstMatch(rawProcedureText)?.group(0);
  return [
    'Breast augmentation',
    if (detail != 'Method not specified') detail,
    if (size != null) size,
  ].join(' · ');
}

bool exploreBreastPriceIsOtherSurgery({
  required String evidence,
  required double priceMin,
  required String currency,
}) {
  final row = _bindingFold(_breastPricedRow(evidence, priceMin, currency));
  if (cachedRegExp(
    r'\b(?:replacement|exchange|removal|explantation|reconstruction|reduction|revision|gynecomastia|gynaecomastia)\b|riduttiv|zvogelimi|mellkisebbites|implantatumcsere|\b(?:schimbar\w*|inlocuir\w*|indepartar\w*|explantar\w*|reconstruct\w*|reduct\w*|micsorar\w*|revizie)\b',
  ).hasMatch(row)) {
    return true;
  }
  if (cachedRegExp(
    r'mastopex\w*|mastopessi|breast\s+lift|mellfelvarras|ridicar\w*',
  ).hasMatch(row)) {
    return true;
  }
  return false;
}
