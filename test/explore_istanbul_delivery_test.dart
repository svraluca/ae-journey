import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_search_locale.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

ExploreDiscoveryToolRow tariff(
  String name,
  String host, {
  String canonical = 'botox',
  String title = 'Botoks',
  String displayTitle = 'Botox treatment',
  String currency = 'TRY',
  double amount = 5000,
  String? evidence,
  String evidenceType = 'html_table',
}) => ExplorePriceDiscoveryTool.rowFromJson({
  'clinic_name': name,
  'source_url': 'https://$host/prices/',
  'source_type': 'official_clinic',
  'evidence_type': evidenceType,
  'clinic_own_price': true,
  'city_match': true,
  'procedure_canonical': canonical,
  'raw_procedure_text': title,
  'procedure_display_name': displayTitle,
  'price_min': amount,
  'price_max': amount,
  'currency': currency,
  'raw_price_text': '$amount $currency',
  'raw_evidence': evidence ?? '$title | $amount $currency',
  'last_verified_at': DateTime.now().toUtc().toIso8601String(),
})!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Istanbul verified euro tariff survives worker validation and card filtering',
    () async {
      final result = await validateExploreDiscoveryCompareRows(
        rows: [
          tariff(
            'Aster Medical Clinic',
            'aster.example',
            currency: 'EUR',
            amount: 250,
            title: 'Botox Injection (1 Area)',
            evidence:
                'Botox Injection (1 Area) ⭐ €250 Whatsapp +90543 13779 49 Polat Tower Residence 445 Istanbul, Şişli, Turkey',
          ),
        ],
        city: 'İstanbul',
        procedure: 'Botox anti-wrinkle injection',
        selection: 'Botox',
      );
      expect(result.rejectedUrls, isEmpty);
      expect(
        clinicsForCompareDisplay(
          result.accepted,
          procedure: 'Botox',
          city: 'İstanbul',
        ),
        hasLength(1),
      );
      expect(result.accepted.single.priceMin, 250);
      expect(result.accepted.single.currency, 'EUR');
    },
  );

  test(
    'six legitimate mixed-currency Istanbul clinics form a pool of at most four cards',
    () async {
      final rows = [
        for (var i = 0; i < 6; i++)
          tariff(
            'Medical Clinic $i',
            'clinic$i.example',
            currency: i < 3 ? 'EUR' : 'TRY',
            amount: i < 3 ? 250 : 5000,
          ),
      ];
      final result = await validateExploreDiscoveryCompareRows(
        rows: rows,
        city: 'İstanbul',
        procedure: 'Botox anti-wrinkle injection',
        selection: 'Botox',
      );
      expect(result.accepted, hasLength(6));
      expect(
        clinicsForCompareDisplay(
          result.accepted,
          procedure: 'Botox',
          city: 'İstanbul',
        ),
        hasLength(4),
      );
    },
  );

  test('a verified local tariff keeps its source currency in any market', () {
    expect(
      exploreListingFitsSearchCity(
        city: 'İstanbul',
        host: 'clinic.example',
        currency: 'EUR',
        procedureText: 'Our clinic in Istanbul: Botoks €250',
      ),
      isTrue,
    );
    expect(
      exploreListingFitsSearchCity(
        city: 'Fukuoka',
        host: 'clinic.example',
        currency: 'EUR',
        procedureText: 'Our clinic in Fukuoka: Botox €250',
      ),
      isTrue,
    );
    expect(
      exploreListingFitsSearchCity(
        city: 'İstanbul',
        host: 'clinic.example',
        currency: 'EUR',
        procedureText: 'Botox €250',
        area: 'İstanbul',
      ),
      isFalse,
    );
    expect(
      exploreListingFitsSearchCity(
        city: 'İstanbul',
        host: 'clinic.example',
        currency: 'EUR',
        procedureText: 'Our clinic in Madrid: Botox €250',
      ),
      isFalse,
    );
  });

  test('contact numbers beside a tariff are not parsed as its price', () {
    for (final contact in [
      'Whatsapp +90543 13779 49',
      'Tel: +34 621 145 099',
      'Phone: 212 555 0199',
    ]) {
      expect(
        parsePriceText('Botox Injection (1 Area) €250 $contact')?.priceMin,
        250,
      );
      expect(parsePriceText(contact), isNull);
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: contact,
          priceMin: 905431377949,
          currency: 'EUR',
          extractionMethod: 'html_table',
          procedure: 'Botox',
          logRejects: false,
        ).accepted,
        isFalse,
      );
    }
  });

  test(
    'Turkish SEO headings lose price copy while keeping the published treatment name',
    () async {
      for (final title in [
        'Botoks fiyatları 2026',
        'Botoks Fiyatları 2026 Botoks fiyatları 2026’da genellikle',
      ]) {
        final result = await validateExploreDiscoveryCompareRows(
          rows: [
            tariff(
              'Medical Clinic',
              'clinic.example',
              title: title,
              evidence: 'Our clinic in Istanbul: Botoks | 5000 TRY',
            ),
          ],
          city: 'İstanbul',
          procedure: 'Botox anti-wrinkle injection',
          selection: 'Botox',
        );
        expect(result.accepted, hasLength(1));
        expect(
          exploreCardProcedureLabel(
            result.accepted.single,
            selectedPill: 'Botox',
          ),
          'Botoks',
        );
      }
    },
  );

  test(
    'every procedure preserves a usable source-language row over an English display name',
    () async {
      const examples = [
        ('botox', 'Botox', 'Botoks', 'Botox treatment', 5000.0),
        ('filler', 'Fillers', 'Dudak dolgusu 1 ml', 'Lip filler', 8000.0),
        ('chemical_peel', 'Peels', 'Kimyasal peeling', 'Chemical Peel', 3000.0),
        (
          'rhinoplasty',
          'Rhinoplasty',
          'Burun estetiği',
          'Rhinoplasty',
          100000.0,
        ),
        (
          'breast_augmentation',
          'Boob job',
          'Meme büyütme',
          'Breast augmentation',
          150000.0,
        ),
        (
          'hair_transplant',
          'Hair',
          'Saç ekimi FUE',
          'Hair Transplant',
          60000.0,
        ),
      ];
      for (final (canonical, pill, title, english, amount) in examples) {
        final result = await validateExploreDiscoveryCompareRows(
          rows: [
            tariff(
              'Medical Clinic',
              'clinic.example',
              canonical: canonical,
              title: title,
              displayTitle: english,
              amount: amount,
            ),
          ],
          city: 'İstanbul',
          procedure: explorePillAiSearchQuery(pill),
          selection: pill,
        );
        expect(result.accepted, hasLength(1), reason: title);
        expect(
          exploreCardProcedureLabel(result.accepted.single, selectedPill: pill),
          title,
        );
      }
    },
  );

  test(
    'an article does not become an owned price table during Flutter mapping',
    () async {
      final result = await validateExploreDiscoveryCompareRows(
        rows: [
          tariff(
            'Medical Clinic',
            'clinic.example',
            canonical: 'filler',
            title: 'Dudak dolgusu',
            displayTitle: 'Dermal Filler',
            amount: 10000,
            evidenceType: 'official_article',
            evidence: 'Dudak dolgusu | 10000 TRY',
          ),
        ],
        city: 'İstanbul',
        procedure: 'dermal filler',
        selection: 'Fillers',
      );
      expect(result.accepted, isEmpty);
    },
  );

  test(
    'an invented amount cannot be revived from a clinic-own flag or formatted rawPriceText',
    () async {
      for (final evidence in [
        'Dudak dolgusu: contact us for a quote',
        'Dudak dolgusu | 8000 TRY',
      ]) {
        final result = await validateExploreDiscoveryCompareRows(
          rows: [
            tariff(
              'Medical Clinic',
              'clinic.example',
              canonical: 'filler',
              title: 'Dudak dolgusu',
              amount: 10000,
              evidence: evidence,
            ),
          ],
          city: 'İstanbul',
          procedure: 'dermal filler',
          selection: 'Fillers',
        );
        expect(result.accepted, isEmpty);
      }
    },
  );

  test(
    'Turkish market estimates are rejected even with old clinic-own flags',
    () async {
      for (final claim in [
        'Dudak dolgusu fiyatları genellikle 10.000 TL',
        'Dolgu fiyatları ortalama 45.000 TL',
        'Botoks fiyatları 2026’da genellikle 6.500 TL',
        'Saç ekimi maliyeti 60.000 TL ile 90.000 TL arasında değişir',
      ]) {
        final amount = claim.contains('45.000')
            ? 45000.0
            : claim.contains('6.500')
            ? 6500.0
            : claim.contains('60.000')
            ? 60000.0
            : 10000.0;
        final canonical = claim.startsWith('Botoks')
            ? 'botox'
            : claim.startsWith('Saç')
            ? 'hair_transplant'
            : 'filler';
        final result = evaluateExtractedPriceCandidate(
          rawPriceText: '$amount TRY',
          priceMin: amount,
          currency: 'TRY',
          extractionMethod: 'html_table',
          rawEvidence: claim,
          rawProcedureText: canonical,
          procedure: canonical,
          sourceUrl: 'https://clinic.example/prices/',
          logRejects: false,
        );
        expect(result.accepted, isFalse, reason: claim);
      }
    },
  );
}
