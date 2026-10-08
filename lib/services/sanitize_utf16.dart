/// Strip unpaired UTF-16 surrogates so Text / TextSpan never crash on
/// bad bytes from APIs / Firestore.
String sanitizeUtf16(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  final units = raw.codeUnits;
  final out = <int>[];
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      // High surrogate — keep only with a valid low pair.
      if (i + 1 < units.length) {
        final low = units[i + 1];
        if (low >= 0xDC00 && low <= 0xDFFF) {
          out.add(c);
          out.add(low);
          i++;
          continue;
        }
      }
      continue;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) {
      // Unpaired low surrogate.
      continue;
    }
    out.add(c);
  }
  if (out.length == units.length) return raw;
  return String.fromCharCodes(out);
}

String? sanitizeUtf16Nullable(String? raw) {
  if (raw == null) return null;
  return sanitizeUtf16(raw);
}
