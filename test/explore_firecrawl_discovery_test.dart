import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_firecrawl_client.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_price_sanity.dart';

void main() {
  group('Firecrawl discovery helpers', () {
    test('ranks pricing and PDF urls on the clinic host', () {
      final picked = exploreRankFirecrawlUrls(
        [
          'https://clinic.ae/',
          'https://clinic.ae/blog/news',
          'https://clinic.ae/en/botox-price-list',
          'https://clinic.ae/menu.pdf',
          'https://other.com/prices',
        ],
        procedure: 'botox',
        host: 'clinic.ae',
        max: 5,
      );
      expect(picked, isNotEmpty);
      expect(picked.every((u) => u.contains('clinic.ae')), isTrue);
      expect(
        picked.any((u) => u.contains('botox') || u.contains('.pdf')),
        isTrue,
      );
    });

    test('map search includes procedure and price words', () {
      final s = exploreFirecrawlMapSearch(
        procedure: 'Botox',
        priceWords: const ['سعر', 'أسعار'],
      );
      expect(s.toLowerCase(), contains('botox'));
      expect(
        s.contains('سعر') || s.toLowerCase().contains('price'),
        isTrue,
      );
    });

    test(
        'PDF markdown goes through extractPriceEvidence — not a Firecrawl price',
        () {
      const md = '''
| Treatment | Price |
|-----------|-------|
| Botox forehead | 799 AED |
| Lip filler 1 ml | 1200 AED |
''';
      final html = exploreMarkdownToExtractableHtml(md);
      expect(html, contains('<table>'));
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://clinic.ae/prices.pdf',
      );
      expect(rows, isNotEmpty);
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 799);
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: picked.rawPriceText,
          priceMin: picked.priceMin,
          currency: picked.currency,
          extractionMethod: picked.extractionMethod.wire,
          rawEvidence: picked.rawEvidence,
          procedure: 'Botox',
        ).accepted,
        isTrue,
      );

      final page = exploreParseFirecrawlScrape(
        jsonEncode({
          'data': {
            'url': 'https://clinic.ae/prices.pdf',
            'markdown': md,
            'extract': {'price': 1, 'currency': 'USD'},
          },
        }),
        fallbackUrl: 'https://clinic.ae/prices.pdf',
      );
      expect(page.html, contains('799'));
      expect(page.fromPdf, isTrue);
    });
  });
}
