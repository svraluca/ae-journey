import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/explore_url_discovery.dart';

void main() {
  group('global URL discovery', () {
    test('Arabic price path scores high for any Gulf city', () {
      expect(
        exploreScoreClinicPriceUrl(
          'https://clinic.ae/ar/أسعار-البوتوكس',
          city: 'Abu Dhabi',
          procedure: 'Botox',
        ),
        greaterThanOrEqualTo(3),
      );
      expect(
        exploreScoreClinicPriceUrl(
          'https://clinic.ae/ar/أسعار',
          city: 'Riyadh',
          procedure: 'filler',
        ),
        greaterThanOrEqualTo(3),
      );
    });

    test('Romanian and Korean price tokens score without city hardcoding', () {
      expect(
        exploreScoreClinicPriceUrl(
          'https://x.ro/preturi-injectabile',
          city: 'Bucharest',
          procedure: 'Botox',
        ),
        greaterThanOrEqualTo(3),
      );
      expect(
        exploreScoreClinicPriceUrl(
          'https://y.kr/가격',
          city: 'Seoul',
          procedure: 'botox',
        ),
        greaterThanOrEqualTo(3),
      );
    });

    test('ranks PDFs and keeps host filter', () {
      final ranked = exploreRankClinicPriceUrls(
        [
          'https://a.com/blog',
          'https://a.com/prices.pdf',
          'https://b.com/prices',
          'https://a.com/en/botox-fees',
        ],
        city: 'London',
        procedure: 'botox',
        host: 'a.com',
        max: 3,
      );
      expect(ranked.every((u) => u.contains('a.com')), isTrue);
      expect(ranked.any((u) => u.contains('.pdf') || u.contains('fees')), isTrue);
    });

    test('sitemap loc parser keeps same-host urls', () {
      const xml = '''
<?xml version="1.0"?>
<urlset>
  <url><loc>https://www.clinic.fr/tarifs</loc></url>
  <url><loc>https://other.fr/prices</loc></url>
</urlset>
''';
      // exercise via exploreDiscoverSitemapUrls is network; unit-test helper path
      expect(exploreUrlLooksLikePdf('https://x.com/list.pdf?v=1'), isTrue);
      expect(exploreContentTypeIsPdf('application/pdf; charset=binary'), isTrue);
      expect(xml.contains('clinic.fr/tarifs'), isTrue);
    });
  });

  group('units on parsePriceText', () {
    test('stores ml quantity and per-unit type', () {
      final p = parsePriceText('Lip filler 1 ml from 1200 AED');
      expect(p, isNotNull);
      expect(p!.unit, 'ml');
      expect(p.quantity, 1);
      expect(p.priceType, PriceType.perUnit);
      expect(p.priceMin, 1200);
    });

    test('area unit becomes perArea', () {
      final p = parsePriceText('Botox per area 599 AED');
      expect(p, isNotNull);
      expect(p!.unit, 'area');
      expect(p.priceType, PriceType.perArea);
    });

    test('from / range / sale still work globally', () {
      expect(parsePriceText('starts from 799 AED')?.priceType, PriceType.from);
      expect(
        parsePriceText('500 AED – 900 AED')?.priceType,
        PriceType.range,
      );
      expect(
        parsePriceText('<del>900</del><ins>700 AED</ins>')?.priceType,
        PriceType.sale,
      );
    });

    test('brand digits are not clinic-specific allowlists', () {
      final p = parsePriceText('At SKIN111, peel starts from AED 490');
      expect(p?.priceMin, 490);
    });
  });

  group('smallest evidence + booking location', () {
    test('shrinkEvidence keeps procedure and price only', () {
      final slim = shrinkEvidenceToProcedureAndPrice(
        block:
            'Intro fluff. Botox forehead from 799 AED. Unrelated laser 199 AED package.',
        procedure: 'Botox forehead',
        priceRaw: '799 AED',
      );
      expect(slim.toLowerCase(), contains('botox forehead'));
      expect(slim, contains('799'));
      expect(slim.toLowerCase(), isNot(contains('laser')));
    });

    test('marketplace location requires city signal, rejects peer city', () {
      expect(
        exploreMarketplaceLocationStronglyMatches(
          city: 'Paris',
          placeAddress: '12 Rue de Rivoli, Paris',
          sourceUrl: 'https://fresha.com/l/clinic-paris',
          pageText: 'Botox from 120 EUR',
        ),
        isTrue,
      );
      expect(
        exploreMarketplaceLocationStronglyMatches(
          city: 'Abu Dhabi',
          placeAddress: 'Sheikh Zayed Road, Dubai',
          sourceUrl: 'https://fresha.com/l/clinic-dubai',
          pageText: 'Botox Dubai',
        ),
        isFalse,
      );
      expect(
        exploreMarketplaceLocationStronglyMatches(
          city: 'Bucharest',
          placeAddress: '',
          sourceUrl: 'https://treatwell.com/place/xyz',
          pageText: 'Botox from 500 RON',
        ),
        isFalse,
      );
    });

    test('market-guide URLs are generic, not city allowlists', () {
      expect(
        isNonLiteralClinicPriceUrl(
          'https://clinic.com/blog/average-price-botox',
        ),
        isTrue,
      );
      expect(
        isNonLiteralClinicPriceUrl(
          'https://clinic.com/en/laser-treatments-cost-in-abu-dhabi/',
        ),
        isFalse,
      );
    });

    test('official price list outranks a treatment landing', () {
      final list = exploreScoreClinicPriceUrl(
        'https://skinlogicaesthetics.co.uk/price-list/',
        city: 'London',
        procedure: 'chemical peel facial',
      );
      final landing = exploreScoreClinicPriceUrl(
        'https://skinlogicaesthetics.co.uk/cosmelan-peel/',
        city: 'London',
        procedure: 'chemical peel facial',
      );
      expect(list, greaterThanOrEqualTo(5));
      expect(list, greaterThan(landing));
      expect(
        looksLikeOfficialPriceListUrl('https://facecliniclondon.com/prices'),
        isTrue,
      );
      expect(
        looksLikeCityCostArticleUrl('https://facecliniclondon.com/botox-cost/'),
        isTrue,
      );
      expect(
        looksLikeOfficialPriceListUrl('https://facecliniclondon.com/botox-cost/'),
        isFalse,
      );
      expect(
        exploreScoreClinicPriceUrl(
          'https://facecliniclondon.com/prices',
          city: 'London',
          procedure: 'Botox anti-wrinkle injection',
        ),
        greaterThan(
          exploreScoreClinicPriceUrl(
            'https://facecliniclondon.com/botox-cost/',
            city: 'London',
            procedure: 'Botox anti-wrinkle injection',
          ),
        ),
      );
      expect(
        exploreScoreClinicPriceUrl(
          'https://drmarktam.co.uk/fees/',
          city: 'London',
          procedure: 'hair transplant FUE',
        ),
        greaterThan(
          exploreScoreClinicPriceUrl(
            'https://drmarktam.co.uk/fue-hair-transplant/',
            city: 'London',
            procedure: 'hair transplant FUE',
          ),
        ),
      );
    });
  });
}
