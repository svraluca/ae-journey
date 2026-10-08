import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_request_coordinator.dart';

void main() {
  group('ExploreRequestCoordinator', () {
    tearDown(() {
      ExploreRequestCoordinator.instance.resetForTest();
    });

    test('Serper concurrency never exceeds 2', () async {
      final coord = ExploreRequestCoordinator.instance;
      var peak = 0;
      final gates = <Completer<void>>[];
      Future<int> job(int id) {
        return coord.runSerpQuery<int>(
          queryKey: 'q$id',
          procedureKey: 'botox',
          mode: ExploreRequestMode.foreground,
          run: () async {
            final g = Completer<void>();
            gates.add(g);
            if (coord.serpInFlight > peak) peak = coord.serpInFlight;
            await g.future;
            return id;
          },
        );
      }

      final f1 = job(1);
      final f2 = job(2);
      final f3 = job(3);
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 2);
      expect(peak, lessThanOrEqualTo(2));
      gates[0].complete();
      await f1;
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 3);
      for (final g in gates) {
        if (!g.isCompleted) g.complete();
      }
      await Future.wait([f2, f3]);
      expect(coord.providerConcurrencyPeak, lessThanOrEqualTo(2));
    });

    test('All-screen Serper budget caps at 4', () async {
      final coord = ExploreRequestCoordinator.instance;
      coord.beginAllVisit('all|timisoara|1');
      var ran = 0;
      for (var i = 0; i < 8; i++) {
        await coord.runSerpQuery<void>(
          queryKey: 'all-q$i',
          procedureKey: 'pill$i',
          mode: ExploreRequestMode.foreground,
          allPreview: true,
          onBudgetExhausted: () {},
          run: () async {
            ran++;
          },
        );
      }
      expect(ran, ExploreRequestCoordinator.allScreenSerperBudget);
      expect(coord.allSerpUsed, 4);
      coord.endAllVisit('all|timisoara|1');
    });

    test('foreground never retries Serper', () {
      final coord = ExploreRequestCoordinator.instance;
      expect(
        coord.mayRetrySerper(
          mode: ExploreRequestMode.foreground,
          uiDeadlinePassed: false,
          procedureKey: 'botox',
        ),
        isFalse,
      );
      expect(
        coord.mayRetrySerper(
          mode: ExploreRequestMode.background,
          uiDeadlinePassed: false,
          procedureKey: 'botox',
        ),
        isTrue,
      );
      expect(
        coord.mayRetrySerper(
          mode: ExploreRequestMode.background,
          uiDeadlinePassed: true,
          procedureKey: 'botox',
        ),
        isFalse,
      );
    });
  });

  group('e17 → e18 migration', () {
    test('valid e17 evidence becomes e18 without HTTP', () {
      final row = <String, Object?>{
        'name': 'Olariuclinics',
        'price_min': 1600,
        'price_max': 1600,
        'currency': 'RON',
        'raw_price_text': '1600 RON',
        'raw_procedure_text': 'Injectare acid hialuronic 1 ml',
        'price_evidence_text': 'Injectare acid hialuronic 1 ml: 1600 RON',
        'price_source_url': 'https://olariuclinics.ro/preturi',
        'extraction_method': 'html_table',
        'evidence_hash': 'abc123',
        'price_type': 'perUnit',
        'price_unit': 'ml',
        'price_verified': true,
        'price_verification_status': 'official_website',
        'price_extract_revision': 'e17',
      };
      final out = stripInvalidCachedPriceJson(
        row,
        procedure: 'lip filler',
        city: 'Timisoara',
        logRejects: false,
      );
      expect(out['price_extract_revision'], kExplorePriceExtractRevision);
      expect(out['price_min'], 1600);
      expect('${out['price_type']}', 'fixed');
      expect('${out['price_unit']}', isNot('ml'));
    });

    test('cross-city e17 is not migrated as trusted', () {
      final row = <String, Object?>{
        'name': 'Cronosmed',
        'price_min': 1700,
        'price_max': 1700,
        'currency': 'RON',
        'raw_price_text': '1700 RON',
        'raw_procedure_text': 'Restylane 1 ml',
        'price_evidence_text': 'Restylane 1 ml 1700 RON',
        'price_source_url': 'https://cronosmed.ro/preturi/bucuresti',
        'extraction_method': 'html_table',
        'evidence_hash': 'xyz',
        'price_verified': true,
        'price_verification_status': 'official_website',
        'price_extract_revision': 'e17',
      };
      final out = stripInvalidCachedPriceJson(
        row,
        procedure: 'lip filler',
        city: 'Timisoara',
        logRejects: false,
      );
      expect((out['price_min'] as num?)?.toDouble() ?? 0, 0);
    });

    test('directory host is not migrated', () {
      final row = <String, Object?>{
        'name': 'med.ro listing',
        'price_min': 500,
        'price_max': 500,
        'currency': 'RON',
        'raw_price_text': '500 RON',
        'raw_procedure_text': 'Botox',
        'price_evidence_text': 'Botox 500 RON',
        'price_source_url': 'https://www.med.ro/clinici/botox',
        'extraction_method': 'html_table',
        'evidence_hash': 'dir',
        'price_verified': true,
        'price_verification_status': 'official_website',
        'price_extract_revision': 'e17',
      };
      final migrated = migrateE17CachedPriceRow(
        row,
        procedure: 'botox',
        city: 'Timisoara',
        logRejects: false,
      );
      expect(migrated, isNull);
    });
  });
}
