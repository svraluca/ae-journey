import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/openai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final snapshot =
      jsonDecode(
            File(
              'verification/whatclinic_six_tabs_v11_95.json',
            ).readAsStringSync(),
          )
          as Map;
  final cities = snapshot['cities'] as Map;
  const tabPills = {
    'botox': 'Botox',
    'filler': 'Fillers',
    'chemical_peel': 'Peels',
    'rhinoplasty': 'Rhinoplasty',
    'breast_augmentation': 'Boob job',
    'hair_transplant': 'Hair',
  };

  for (final city in cities.keys) {
    final procedures = cities[city] as Map;
    for (final canonical in procedures.keys) {
      test(
        'captured $city $canonical old offers require fresh source verification',
        () async {
          // Replay source evidence; refreshing the fixture's clock is not a new
          // live verification claim. The audit retains its actual capture time.
          final source = (procedures[canonical] as Map)['rows'] as List;
          final rows = source
              .map(
                (raw) => ExplorePriceDiscoveryTool.rowFromJson({
                  ...Map<String, Object?>.from(raw as Map),
                  'last_verified_at': DateTime.now().toUtc().toIso8601String(),
                })!,
              )
              .toList();
          final result = await validateExploreDiscoveryCompareRows(
            rows: rows,
            city: city as String,
            procedure: explorePillAiSearchQuery(tabPills[canonical]!),
            selection: tabPills[canonical]!,
          );
          expect(result.accepted, isEmpty);
          for (final row in rows) {
            expect(row.priceExtractRevision, 'e31');
            expect(result.rejectedUrls, contains(row.sourceUrl));
          }
        },
      );
    }
  }

  test(
    'reading an old backend result cannot certify it under the current revision',
    () async {
      // Keep the previous live receipt at its real extraction revision.
      // Reading it cannot certify those old fees under e32.
      final oldSnapshot =
          jsonDecode(
                File(
                  'verification/istanbul_published_menus_v11_94.json',
                ).readAsStringSync(),
              )
              as Map;
      final raw = Map<String, Object?>.from(
        ((oldSnapshot['procedures'] as Map)['botox'] as Map)['rows'][0] as Map,
      );
      expect(raw['price_extract_revision'], 'e30');
      for (final stale in ['', 'e20', 'e27', 'e28', 'e29', 'e30', 'e31']) {
        final row = ExplorePriceDiscoveryTool.rowFromJson({
          ...raw,
          'price_extract_revision': stale,
          'last_verified_at': DateTime.now().toUtc().toIso8601String(),
        })!;
        final result = await validateExploreDiscoveryCompareRows(
          rows: [row],
          city: 'İstanbul',
          procedure: 'botox',
          selection: 'Botox',
        );
        expect(result.accepted, isEmpty);
        expect(result.rejectedUrls, contains(row.sourceUrl));
      }
    },
  );
}
