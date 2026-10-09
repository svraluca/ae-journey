import 'explore_regex_cache.dart';

String _fold(String value) {
  const from = 'áàäâãåéèëêíìïîóòöôõúùüûñçşșțăı';
  const to = 'aaaaaaeeeeiiiiooooouuuuncsstai';
  return value
      .toLowerCase()
      .replaceAll('ğ', 'g')
      .split('')
      .map((c) {
        final i = from.indexOf(c);
        return i < 0 ? c : to[i];
      })
      .join('');
}

/// Technique comes from the priced service, never a clinic-name allowlist.
String? exploreInjectableScopeRejection({
  required String procedure,
  String label = '',
  String evidence = '',
  String provider = '',
  String sourceUrl = '',
}) {
  final requested = _fold(procedure);
  final botox = cachedRegExp(
    r'botox|botulin|toxin|neuromodul|ботокс|بوتوكس',
  ).hasMatch(requested);
  final filler =
      requested == 'filler' ||
      cachedRegExp(
        r'filler|hyaluron|hialuron|relleno|aumento.*labios|фил[ъе]р|فيلر',
      ).hasMatch(requested);
  if (!botox && !filler) return null;
  final local = _fold('$label $evidence');
  final adjunct = local.replaceAll(
    cachedRegExp(
      r'\b(?:numbing|anaesthetic|anesthetic)\s+cream\b|\bcrema\s+anestesica\b',
    ),
    '',
  );
  if (cachedRegExp(
    r'\b(?:creams?|cremas?|cremes?|serums?|serum|lotion\w*|moisturi\w*|'
    r'cosmetic\s+products?|skincare|skin\s+care|topical\w*|topic[oa]\w*)\b|'
    r'крем\w*|сыворот\w*|كريم|مصل',
  ).hasMatch(adjunct)) {
    return 'topical_product_not_injectable';
  }
  if (filler &&
      cachedRegExp(
        r'hyaluron\w*\s*[- ]*pen\b|hialuron\w*\s*[- ]*pen\b|'
        r'needle[- ]?(?:less|free)|sin\s+agujas?|sem\s+agulhas?|sans\s+aiguilles?|'
        r'senza\s+aghi|ohne\s+nadeln?|fara\s+ace|ignesiz|pa\s+gjilper\w*|'
        r'без\s+игл\w*|без\s+игли|بدون\s+(?:ابر|إبر)',
      ).hasMatch(local)) {
    return 'needleless_not_injectable_filler';
  }
  if (botox &&
      cachedRegExp(
        r'(?:hair|haar|capillary|cabelo|cabelos|capelli|cheveux|par|flok\w*|sac)\s*[- ]*botox|'
        r'botox\s*(?:for\s+)?(?:hair|haar|capilar|capillaire|capelli|cheveux|cabelo|par|flok\w*|sac)|'
        r'ботокс\s+(?:для\s+)?волос|ботокс\s+за\s+коса|بوتوكس\s+(?:لل)?شعر|'
        r'anti[- ]?frizz|anti[- ]?encresp|keratin\w*|straightening|alisado|'
        r'\b(?:media\s+melena|pelo\s+(?:corto|largo)|short\s+hair|long\s+hair)\b',
      ).hasMatch(local)) {
    return 'noninjectable_botox';
  }
  final identity = _fold(
    '$provider $sourceUrl',
  ).replaceAll('-', ' ').replaceAll('_', ' ');
  final beauty = cachedRegExp(
    r'\b(?:hair|nails?|nailbar|manicur\w*|pedicur\w*|barber\w*|peluquer\w*|'
    r'perruquer\w*|coiffeur\w*|parrucchier\w*|cabeleireir\w*|kapper\w*|'
    r'friseur\w*|kuafor\w*|floktore|unghii|ongler\w*)\b|'
    r'(?:hair|nail)[-_](?:salon|studio)|парикмахер\w*|маникюр\w*',
  ).hasMatch(identity);
  final clinical = cachedRegExp(
    r'\b(?:inject\w*|injections?|infiltr\w*|iniezion\w*|inyecci\w*|'
    r'jeringas?|syringes?|dysport|xeomin|azzalure|bocouture|'
    r'neuromodul\w*|neurotox\w*|botulin\w*|juvederm|restylane|teosyal|'
    r'belotero|revolax)\b|dermal\s+fillers?|lip\s+fillers?|'
    r'toxina\s+botulin\w*|\b(?:1|2|3|one|two|three)\s*(?:areas?|zones?|zonas?)\b|'
    r'\b(?:per|por)\s+(?:unit|unidad)\w*\b|инъекц\w*|инжекц\w*|حقن',
  ).hasMatch(local);
  if (beauty && !clinical) {
    return botox ? 'noninjectable_botox' : 'injectable_technique_unverified';
  }
  return null;
}
