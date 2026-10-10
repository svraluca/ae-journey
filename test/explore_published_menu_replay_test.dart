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
              'verification/istanbul_published_menus_v11_94.json',
            ).readAsStringSync(),
          )
          as Map;
  final procedures = snapshot['procedures'] as Map;
  const tabPills = {
    'botox': 'Botox',
    'filler': 'Fillers',
    'chemical_peel': 'Peels',
    'rhinoplasty': 'Rhinoplasty',
    'breast_augmentation': 'Boob job',
    'hair_transplant': 'Hair',
  };

  for (final canonical in procedures.keys) {
    test(
      'captured $canonical offers survive the complete Flutter worker',
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
          city: 'İstanbul',
          procedure: explorePillAiSearchQuery(tabPills[canonical]!),
          selection: tabPills[canonical]!,
        );
        expect(result.rejectedUrls, isEmpty);
        expect(result.accepted, hasLength(rows.length));
        expect(result.accepted, isNotEmpty);
        for (final accepted in result.accepted) {
          final original = rows.singleWhere(
            (r) => r.sourceUrl == accepted.priceSourceUrl,
          );
          expect(accepted.currency, original.currency);
          expect(accepted.priceMin, original.priceMin);
          expect(accepted.priceMax, original.priceMax ?? original.priceMin);
          expect(accepted.priceExtractRevision, kExplorePriceExtractRevision);
          if (original.sourceType == 'marketplace') {
            expect(accepted.sourceLocationText, contains('Provider locality: Istanbul'));
          } else {
            expect(original.clinicOwnPrice, isTrue);
            expect(accepted.sourceLocationText, isNotEmpty);
          }
        }
      },
    );
  }

  test(
    'reading an old backend result cannot certify it under the current revision',
    () async {
      final raw = Map<String, Object?>.from(
        (procedures['botox'] as Map)['rows'][0] as Map,
      );
      for (final stale in ['', 'e20', 'e27', 'e28', 'e29']) {
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
