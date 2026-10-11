/// A publication date is provenance, not an expiry date; preserve it on fetch.
/// Undated fees keep an unknown publication date.
String exploreMarketplacePriceDateFailure({
  required String updatedAt,
  String dateBasis = '',
  DateTime? now,
}) {
  if (dateBasis == 'ambiguous_menu_date') {
    return 'marketplace_price_date_ambiguous';
  }
  final raw = updatedAt.trim();
  if (raw.isEmpty) return '';
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?$',
  ).firstMatch(raw);
  if (match == null) return 'marketplace_price_date_invalid';
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final calendar = DateTime.utc(year, month, day);
  if (year < 1 ||
      calendar.year != year ||
      calendar.month != month ||
      calendar.day != day) {
    return 'marketplace_price_date_invalid';
  }
  final hour = int.tryParse(match.group(4) ?? '') ?? 0;
  final minute = int.tryParse(match.group(5) ?? '') ?? 0;
  final second = int.tryParse(match.group(6) ?? '') ?? 0;
  final zone = match.group(7) ?? '';
  if (hour > 23 || minute > 59 || second > 59 ||
      (zone.isNotEmpty && zone != 'Z' &&
          (int.parse(zone.substring(1, 3)) > 23 ||
              int.parse(zone.substring(4)) > 59))) {
    return 'marketplace_price_date_invalid';
  }
  final date = match.group(4) == null
      ? calendar
      : DateTime.tryParse(zone.isEmpty ? '${raw}Z' : raw)?.toUtc();
  if (date == null) return 'marketplace_price_date_invalid';
  final clock = (now ?? DateTime.now()).toUtc();
  if (date.isAfter(clock.add(const Duration(days: 1)))) {
    return 'marketplace_price_date_future';
  }
  return '';
}

/// Legacy HTML readers cannot certify Bookimed tariff dates. Let the backend
/// bind its selected procedure record to the source date before showing it.
/// WhatClinic's actual country selector marks viewer-converted menu amounts.
String exploreLegacyMarketplaceProvenanceFailure({
  required String sourceUrl,
  required String html,
}) {
  final host = Uri.tryParse(sourceUrl)?.host.toLowerCase() ?? '';
  if (host == 'bookimed.com' || host.endsWith('.bookimed.com')) {
    return 'marketplace_provenance_requires_backend';
  }
  if ((host == 'whatclinic.com' || host.endsWith('.whatclinic.com')) &&
      RegExp(
        r'''class\s*=\s*["'][^"']*\b(?:link-country-selector|country-selector-menu)\b''',
        caseSensitive: false,
      ).hasMatch(html)) {
    return 'marketplace_original_currency_unverified';
  }
  return '';
}
