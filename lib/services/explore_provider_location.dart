import 'dart:convert';

import 'explore_regex_cache.dart';
import 'explore_search_locale.dart';

/// Location of the medical entity on this profile, excluding platform offices
/// and recommended clinics. Never use the app's generated city label as proof.
List<String> exploreMarketplaceProviderLocations(String html, String sourceUrl) {
  final result = <String>{};
  final profile = sourceUrl.split('#').first.replaceFirst(RegExp(r'/$'), '');
  const medicalTypes = {'Hospital', 'MedicalClinic', 'MedicalBusiness',
    'Physician', 'Dentist', 'LocalBusiness', 'HealthAndBeautyBusiness'};
  void visit(Object? item, [bool mainEntity = false]) {
    if (item is List) {
      for (final child in item) { visit(child); }
    } else if (item is Map) {
      final rawTypes = item['@type'];
      final types = rawTypes is List ? rawTypes : [rawTypes];
      final ref = '${item['url'] ?? item['@id'] ?? ''}'
          .split('#').first.replaceFirst(RegExp(r'/$'), '');
      if (types.any(medicalTypes.contains) &&
          (ref == profile || (mainEntity && ref.isEmpty))) {
        final address = item['address'];
        if (address is String && address.isNotEmpty) result.add(address);
        if (address is Map) {
          final locality = '${address['addressLocality'] ?? ''}'.trim();
          final value = locality.isNotEmpty ? locality :
              ['streetAddress', 'addressRegion', 'addressCountry']
                  .map((k) => '${address[k] ?? ''}').where((v) => v.isNotEmpty).join(' ');
          if (value.isNotEmpty) result.add(value);
        }
      }
      for (final entry in item.entries) {
        visit(entry.value, entry.key == 'mainEntity');
      }
    }
  }
  for (final match in cachedRegExp(
    '''<script\\b[^>]*type=["']application/ld\\+json["'][^>]*>([\\s\\S]*?)</script>''',
    caseSensitive: false,
  ).allMatches(html)) {
    try { visit(jsonDecode(match.group(1)!)); } on FormatException { /* no proof */ }
  }
  return result.toList();
}

String exploreProviderLocationContext(String html, String sourceUrl) =>
    exploreMarketplaceProviderLocations(html, sourceUrl)
        .map((s) => 'Provider locality: $s').join('\n');

bool exploreProviderLocationConflicts(String context, String city) {
  final locations = context.split('\n').where((s) => s.startsWith('Provider locality: '))
      .map((s) => s.substring(19));
  if (locations.isEmpty) return false;
  final wanted = exploreCanonicalCityKey(city);
  return !locations.any((location) =>
      exploreCanonicalCityKey(location) == wanted ||
      cachedRegExp('(?:^|[^a-z])${RegExp.escape(wanted)}(?:\u0024|[^a-z])')
          .hasMatch(foldExploreCityText(location)));
}
