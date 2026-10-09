import 'explore_regex_cache.dart';
import 'explore_search_locale.dart';

bool exploreMarketComparisonContext(String raw) => cachedRegExp(
  r'\b(?:turkey|world|global|uk|us|eu|europe)\s+price\s*[:|]',
).hasMatch(foldExploreCityText(raw)) || cachedRegExp(
  r'\b(?:ulkeler\w*\s+gore|sehirler\w*\s+gore|(?:prices?|costs?)\s+(?:by|across)\s+(?:countr\w*|cities)|(?:precios?|costes?)\s+por\s+(?:paises|ciudades)|prix\s+par\s+(?:pays|ville)|preise\s+nach\s+(?:land|stadt)|prezzi\s+per\s+(?:paese|citta)|average\s+\w*(?:\s+\w*){0,3}\s+price|typical\s+price\s+range|worked\s+cost\s+example|global\s+market)\b',
).hasMatch(foldExploreCityText(raw));

String? exploreAncillaryPriceReason(String procedure, String prefix) {
  final t = foldExploreCityText(prefix);
  if (cachedRegExp(
    r'\b(?:international\s+flights?|flights?|airfare|travel\s+insurance|extra\s+hotel\s+nights?|companion\s+accommodation|personal\s+meals|vuelos?|seguro\s+de\s+viaje|ucak\s+bilet\w*|seyahat\s+sigorta\w*|vols?|assurance\s+voyage|flug\w*|reiseversicherung|voli|assicurazione\s+viaggio)\b[^|\n€$£₺]{0,60}$',
  ).hasMatch(t)) {
    return 'travel_cost_not_procedure';
  }
  if (cachedRegExp(
        r'hair|transplant|sac\s+ekim|capilar|greffe',
        caseSensitive: false,
      ).hasMatch(procedure) &&
      cachedRegExp(
        r'\b(?:prp|platelet[- ]rich\s+plasma|mesotherap\w*|mezoterapi\w*|minoxidil|finasteride)\b[^|\n€$£₺]{0,65}$',
      ).hasMatch(t)) {
    return 'hair_adjunct_not_transplant';
  }
  return null;
}

String? exploreCalendarPriceReason(double amount, String prefix, String tail) {
  return amount >= 1990 &&
          amount <= 2100 &&
          amount == amount.truncateToDouble() &&
          cachedRegExp(
            r'\b(?:kac|ne\s+kadar|how\s+much|cuanto(?:\s+cuesta)?|combien|wie\s+viel|quanto)\b[^|:\n]{0,45}$',
          ).hasMatch(foldExploreCityText(prefix)) &&
          cachedRegExp(r'^\s*\?').hasMatch(tail)
      ? 'calendar_year_not_price'
      : null;
}

bool exploreMedicalQaPriceContext(String sourceUrl, String text) =>
    cachedRegExp(r'/(?:s-s-s|questions?|answers?)/', caseSensitive: false).hasMatch(sourceUrl) &&
    cachedRegExp(r'\b(?:devlet\s+hastaneler\w*|hastalar\s+soruyor|ask\s+(?:a\s+)?doctor|medical\s+questions?|patient\s+questions?|fiyatlarinin\s+bazi\s+ornekleri|fiyat\w*[^.!?\n]{0,100}ortalama|(?:average|typical|example)\s+(?:\w+\s+){0,3}(?:prices?|fees?))\b')
        .hasMatch(foldExploreCityText(text));
