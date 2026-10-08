import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_request_coordinator.dart';

/// A Tirana peels search verified DaVINCI Clinic, Goldentirana and My Spa
/// Tirana several times over, each pass repeating sitemap → Firecrawl → fetch
/// → DOM parse → LLM. The screen stopped taking taps and the duplicate work
/// produced no extra card.
void main() {
  setUp(() {
    ExploreRequestCoordinator.instance.resetForTest();
    ExploreHtmlPriceParseCache.instance.clear();
  });

  group('one website verification per clinic + procedure', () {
    test('a concurrent duplicate joins instead of scraping again', () async {
      var runs = 0;
      final gate = Completer<void>();
      Future<String> verify() async {
        runs++;
        await gate.future;
        return 'davinci';
      }

      final a = ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'davinci.al|chemical peel facial',
        run: verify,
      );
      final b = ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'davinci.al|chemical peel facial',
        run: verify,
      );
      gate.complete();
      expect(await a, 'davinci');
      expect(await b, 'davinci');
      expect(runs, 1);
      expect(ExploreRequestCoordinator.instance.verifyJoins, 1);
    });

    test('a different procedure for the same clinic still verifies', () async {
      var runs = 0;
      Future<String> verify() async {
        runs++;
        return 'ok';
      }

      await ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'davinci.al|chemical peel facial',
        run: verify,
      );
      await ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'davinci.al|lip filler',
        run: verify,
      );
      expect(runs, 2);
    });

    test('a later search re-verifies once the first one settled', () async {
      var runs = 0;
      Future<String> verify() async {
        runs++;
        return 'ok';
      }

      await ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'goldentirana.com|chemical peel facial',
        run: verify,
      );
      await Future<void>.delayed(Duration.zero);
      await ExploreRequestCoordinator.instance.runClinicVerify(
        clinicKey: 'goldentirana.com|chemical peel facial',
        run: verify,
      );
      expect(runs, 2);
    });

    test('verification never exceeds the session-wide cap', () async {
      var peak = 0;
      var active = 0;
      final gate = Completer<void>();
      final all = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        all.add(
          ExploreRequestCoordinator.instance.runClinicVerify(
            clinicKey: 'clinic-$i.al|peel',
            run: () async {
              active++;
              if (active > peak) peak = active;
              await gate.future;
              active--;
            },
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait(all);
      expect(peak, lessThanOrEqualTo(
        ExploreRequestCoordinator.maxVerifyConcurrency,
      ));
    });
  });

  group('page parse is not thrown away by a duplicate fetch', () {
    const url = 'https://myspatirana.com/services/relax';
    const full = '''
<html><body>
<h1>Peeling</h1>
<ul>
<li>1. Peeling kimik sipërfaqësor 33€ 90 min</li>
<li>3. Peeling me TCA 45€ 2 ore</li>
</ul>
</body></html>''';

    test('a shorter re-fetch keeps the richer parse', () {
      final cache = ExploreHtmlPriceParseCache.instance;
      cache.rememberHtml(url, full);
      final first = cache.evidenceFor(url);
      expect(first, isNotEmpty);

      // Plain HTTP re-fetch of a page the renderer already delivered.
      cache.rememberHtml(url, '<html><body><p>1. Paketa</p></body></html>');
      expect(identical(cache.evidenceFor(url), first), isTrue);
    });

    test('a richer fetch does replace the parse', () {
      final cache = ExploreHtmlPriceParseCache.instance;
      cache.rememberHtml(url, '<html><body><p>Peeling</p></body></html>');
      final thin = cache.evidenceFor(url);
      cache.rememberHtml(url, full);
      expect(identical(cache.evidenceFor(url), thin), isFalse);
      expect(cache.evidenceFor(url), isNotEmpty);
    });

    test('the cache is bounded', () {
      final cache = ExploreHtmlPriceParseCache.instance;
      for (var i = 0; i < ExploreHtmlPriceParseCache.maxCachedPages + 25; i++) {
        cache.rememberHtml('https://x.al/p$i', full);
      }
      expect(
        cache.htmlByUrl.length,
        lessThanOrEqualTo(ExploreHtmlPriceParseCache.maxCachedPages),
      );
    });

    test('warming fills the cache so the sync read never parses', () async {
      final cache = ExploreHtmlPriceParseCache.instance;
      cache.rememberHtml('https://warm.al/cmimet', full);
      expect(cache.evidenceByUrl.containsKey('https://warm.al/cmimet'), isFalse);

      await cache.warmEvidence(['https://warm.al/cmimet']);
      expect(cache.evidenceByUrl.containsKey('https://warm.al/cmimet'), isTrue);
      final rows = cache.evidenceFor('https://warm.al/cmimet');
      expect(rows, isNotEmpty);
      // Second read is the same object — no reparse on the frame thread.
      expect(identical(cache.evidenceFor('https://warm.al/cmimet'), rows), isTrue);
    });

    test('warmAllPending covers pages the sync host scan would touch', () async {
      final cache = ExploreHtmlPriceParseCache.instance;
      cache.rememberHtml('https://a.al/cmimet', full);
      cache.rememberHtml('https://a.al/sherbimet', full);
      await cache.warmAllPending();
      expect(cache.evidenceByUrl.length, 2);
    });

    test('the numbered Tirana rows now carry the real fee', () {
      final cache = ExploreHtmlPriceParseCache.instance;
      cache.rememberHtml(url, full);
      final rows = cache.evidenceFor(url);
      expect(rows.map((r) => r.priceMin), containsAll(<double>[33, 45]));
    });
  });
}
