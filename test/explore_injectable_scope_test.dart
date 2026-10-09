import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_injectable_scope.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/explore_price_verification.dart';

OpenAIClinic clinicFixture({
  required String name,
  required String procedure,
  required String canonical,
  required String rawTitle,
  required double amount,
  required String currency,
  required String city,
}) => OpenAIClinic(
  rank: 0,
  name: name,
  area: '$city · aster.example',
  distanceMi: 0,
  rating: 0,
  reviews: 0,
  priceGbp: amount.round(),
  priceMin: amount,
  priceMax: amount,
  priceLabel: '$amount $currency',
  currency: currency,
  brand: procedure,
  badge: '',
  badgeVariant: 'mid',
  coord: const OpenAICoord(0, 0),
  priceSourceUrl: 'https://aster.example/prices/',
  priceEvidenceText: '$rawTitle | $amount $currency',
  rawProcedureText: rawTitle,
  rawPriceText: '$amount $currency',
  extractionMethod: 'html_table',
  sourceType: 'discovery_tool',
  procedureCanonical: canonical,
  procedureDisplayName: rawTitle,
  providerClinic: name,
  priceVerificationStatus: PriceVerificationStatus.officialWebsite,
  priceVerificationConfidence: 0.95,
  priceVerifiedAt: DateTime.utc(2026, 10, 6),
  priceExtractRevision: kExplorePriceExtractRevision,
  procedureRelation: 'exact',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases =
      (jsonDecode(
                File(
                  'test/fixtures/injectable_scope_cases.json',
                ).readAsStringSync(),
              )
              as List)
          .cast<Map<String, dynamic>>();
  for (final c in cases) {
    test('worldwide injectable scope: ${c['id']}', () {
      expect(
        exploreInjectableScopeRejection(
          procedure: c['procedure'],
          label: c['label'],
          evidence: c['evidence'],
          provider: c['provider'],
          sourceUrl: c['source_url'],
        ),
        c['expected'],
      );
      if (c['expected'] != null) {
        final verdict = evaluateExtractedPriceCandidate(
          procedure: c['procedure'],
          rawProcedureText: c['label'],
          rawEvidence: '${c['evidence']} | 350 EUR',
          clinicName: c['provider'],
          sourceUrl: c['source_url'],
          priceMin: 350,
          rawPriceText: '350 EUR',
          currency: 'EUR',
          extractionMethod: 'html_table',
          logRejects: false,
        );
        expect(verdict.accepted, false);
        expect(verdict.reason, c['expected']);
        final clinic =
            clinicFixture(
              name: c['provider'],
              procedure: c['procedure'],
              canonical: c['procedure'],
              rawTitle: c['label'],
              currency: 'EUR',
              city: 'Madrid',
              amount: 350,
            ).copyWith(
              priceEvidenceText: '${c['evidence']} | 350 EUR',
              priceSourceUrl: c['source_url'],
            );
        expect(
          explorePriceIsVerified(clinic),
          false,
          reason: 'Saved verification flags must not bypass treatment scope',
        );
        final stored = <String, Object?>{
          'name': c['provider'],
          'provider_clinic': c['provider'],
          'brand': c['procedure'],
          'procedure_canonical': c['procedure'],
          'raw_procedure_text': c['label'],
          'price_evidence_text': '${c['evidence']} | 350 EUR',
          'raw_price_text': '350 EUR',
          'price_min': 350,
          'price_max': 350,
          'currency': 'EUR',
          'price_source_url': c['source_url'],
          'extraction_method': 'html_table',
          'price_verification_status': 'official_website',
          'price_verified': true,
          'price_extract_revision': kExplorePriceExtractRevision,
          'has_procedure': true,
        };
        expect(OpenAIClinic.fromJson(stored).priceMin, 0);
        final curated = stripInvalidCachedPriceJson(
          {
            ...stored,
            'source_type': 'curated_public_site',
            'price_verification_status': 'curated_public_site',
          },
          procedure: c['procedure'],
          logRejects: false,
        );
        expect(curated['price_min'], 0);
        expect(curated['price_rejection_reason'], c['expected']);
      }
    });
  }

  test(
    'native cache worker rejects bare hair-provider Botox before painting',
    () async {
      final bad =
          clinicFixture(
            name: 'La Coqueta Hair Nails Studio Alcala',
            procedure: 'Botox',
            canonical: 'botox',
            rawTitle: 'Tratamiento Botox',
            amount: 80,
            currency: 'EUR',
            city: 'Madrid',
          ).copyWith(
            priceSourceUrl:
                'https://booksy.com/es-es/123_la-coqueta-hair-nails-studio_53009_madrid',
            priceEvidenceText: 'Tratamiento Botox | 80 EUR',
          );
      final valid = clinicFixture(
        name: 'Aster Medical Clinic',
        procedure: 'Botox',
        canonical: 'botox',
        rawTitle: 'Toxina botulínica 3 zonas',
        amount: 350,
        currency: 'EUR',
        city: 'Madrid',
      );
      final accepted = await validateExploreSavedComparisonClinics(
        rows: [bad, valid],
        city: 'Madrid',
        procedure: 'Botox',
      );
      expect(accepted.map((c) => c.name), ['Aster Medical Clinic']);
    },
  );

  test('schema descriptions cannot turn a cream into a medical price', () {
    final html =
        '<html><title>Aster Medical Clinic</title><script type="application/ld+json">${jsonEncode({
          '@type': 'Service',
          'name': 'Dermal filler',
          'description': 'Crema cosmética',
          'offers': {'@type': 'Offer', 'price': 350, 'priceCurrency': 'EUR'},
        })}</script></html>';
    expect(
      extractPriceEvidence(
        html: html,
        sourceUrl: 'https://aster.example/prices/',
      ),
      isEmpty,
    );
  });

  test('captured public Fresha offers cannot certify a medical filler card', () {
    final html = File('test/fixtures/cleopatra_fresha_offers.html').readAsStringSync();
    final rows = extractPriceEvidence(html: html,
      sourceUrl: 'https://www.fresha.com/a/cleopatra-nails-madrid-calle-arroyo-21-wmsg3rrr');
    expect(rows.where((r) => [150, 199].contains(r.priceMin)), isEmpty);
    expect(rows.where((r) => evaluateExtractedPriceCandidate(
      procedure: 'dermal filler', rawProcedureText: r.rawProcedureText, rawEvidence: r.rawEvidence,
      rawPriceText: r.rawPriceText, priceMin: r.priceMin, currency: r.currency,
      extractionMethod: r.extractionMethod.wire, sourceUrl: r.sourceUrl, logRejects: false,
    ).accepted), isEmpty);
  });

  test(
    'Fresha category rejects needleless offers and preserves genuine injection descriptions',
    () {
      String page(String category, String description) =>
          '<html><title>Aster Nails</title>'
          '<script type="application/ld+json">${jsonEncode({
            '@type': 'Offer',
            'price': 330,
            'priceCurrency': 'EUR',
            'category': category,
            'itemOffered': {'@type': 'Service', 'name': 'Aumento de labios', 'category': category, 'description': description},
          })}</script></html>';
      const url = 'https://www.fresha.com/a/aster-nails-madrid';
      expect(
        extractPriceEvidence(
          html: page('HYALURON PEN', 'INCLUYE 1 VIAL'),
          sourceUrl: url,
        ),
        isEmpty,
      );
      final rows = extractPriceEvidence(
        html: page('MEDICINA ESTÉTICA', 'Inyecciones. INCLUYE 1 VIAL'),
        sourceUrl: url,
      );
      expect(rows, hasLength(1));
      expect(rows.single.rawEvidence, contains('Inyecciones'));
    },
  );
}
