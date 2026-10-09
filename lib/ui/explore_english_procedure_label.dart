import '../services/explore_regex_cache.dart';

// Medical terminology, never provider names or prices. Applied only to the
// display label: original source text and verification evidence stay intact.
final _terms = <(RegExp, String)>[
  (cachedRegExp(r'o\s+zon[aă]|1\s+b[oö]lge', caseSensitive: false), '1 area'),
  (cachedRegExp(r'dou[aă]\s+zone|2\s+b[oö]lge', caseSensitive: false), '2 areas'),
  (cachedRegExp(r'trei\s+zone|3\s+b[oö]lge', caseSensitive: false), '3 areas'),
  (cachedRegExp(r'dudak\s+dolgusu|lippen\s*(?:filler|aufspritzung)|relleno\s+de\s+labios|aumento\s+de\s+labios|(?:m[aă]rire|augmentare)\s+buze|augmentation\s+des\s+l[eè]vres', caseSensitive: false), 'Lip filler'),
  (cachedRegExp(r'burun\s+dolgusu|relleno\s+(?:nasal|de\s+nariz)', caseSensitive: false), 'Nose filler'),
  (cachedRegExp(r'[cç]ene\s+dolgusu|relleno\s+de\s+ment[oó]n|umplere\s+menton', caseSensitive: false), 'Chin filler'),
  (cachedRegExp(r'elmac[iı]k\s+(?:kemi[gğ]i\s+)?dolgusu|relleno\s+de\s+p[oó]mulos|(?:umplere|augmentare)\s+pome[tț]i', caseSensitive: false), 'Cheek filler'),
  (cachedRegExp(r'g[oö]z\s+alt[iı]\s+(?:[iı][sş][iı]k\s+)?dolgusu|umplere\s+cearc[aă]ne|relleno\s+de\s+ojeras', caseSensitive: false), 'Tear trough filler'),
  (cachedRegExp(r'(?:kapal[iı]|cerrada|ferm[eé]e)\s+(?:rinoplasti|rinoplastia|rhinoplastie)', caseSensitive: false), 'Closed rhinoplasty'),
  (cachedRegExp(r'(?:a[cç][iı]k|abierta|ouverte)\s+(?:rinoplasti|rinoplastia|rhinoplastie)', caseSensitive: false), 'Open rhinoplasty'),
  (cachedRegExp(r'burun\s+esteti[gğ]i|rinoplasti(?:e|a)?|rhinoplastie|nasenkorrektur', caseSensitive: false), 'Rhinoplasty'),
  (cachedRegExp(r'meme\s+b[uü]y[uü]tme|aumento\s+de\s+mamas|augmentare\s+mamar[aă]|augmentation\s+mammaire|brustvergr[oö][sß]erung', caseSensitive: false), 'Breast augmentation'),
  (cachedRegExp(r'sa[cç]\s+ekimi|transplant\s+de\s+p[aă]r|injerto\s+capilar|greffe\s+capillaire|haartransplantation', caseSensitive: false), 'Hair transplant'),
  (cachedRegExp(r'kimyasal\s+peeling|peeling\s+chimi[cs]|peeling\s+qu[ií]mico|peeling\s+chimique|chemisches\s+peeling', caseSensitive: false), 'Chemical peel'),
  (cachedRegExp(r'peeling\s+de\s+[aá]cido\s+salic[ií]lico|peeling\s+salicilic', caseSensitive: false), 'Salicylic acid peel'),
  (cachedRegExp(r'peeling\s+(?:glicolic|glikolik)|peeling\s+de\s+[aá]cido\s+glic[oó]lico', caseSensitive: false), 'Glycolic acid peel'),
  (cachedRegExp(r'toxina\s+botul[ií]nica|toxine\s+botulique|botulinumtoxin|botoks|neuromoduladores', caseSensitive: false), 'Botox'),
  (cachedRegExp(r'tercio\s+superior\s+completo|[uü]st\s+y[uü]z', caseSensitive: false), 'Upper face'),
  (cachedRegExp(r'cu\s+acid\s+hialuronic|con\s+[aá]cido\s+hialur[oó]nico|avec\s+acide\s+hyaluronique', caseSensitive: false), 'with hyaluronic acid'),
  (cachedRegExp(r'cu\s+implanturi|con\s+implantes|implant\s+ile|avec\s+implants', caseSensitive: false), 'with implants'),
  (cachedRegExp(r'(?<!\w)seans(?!\w)|sesi[oó]n|[sș]edin[tț][aă]', caseSensitive: false), 'session'),
];

String exploreEnglishProcedureLabel(String source) {
  var label = source;
  for (final (pattern, english) in _terms) {
    label = label.replaceAll(pattern, english);
  }
  return label.replaceAll(RegExp(r'\s+'), ' ').trim();
}
