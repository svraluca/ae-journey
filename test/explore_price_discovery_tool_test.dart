import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';

void main() {
  test('old API or worker cannot bless prices with current client rules', () {
    expect(ExplorePriceDiscoveryTool.supportsCurrentPriceRules(
      {'ok': true, 'version': '0.11.88', 'worker_version': '0.11.88'}), false);
    expect(ExplorePriceDiscoveryTool.supportsCurrentPriceRules(
      {'ok': true, 'version': '0.11.91', 'worker_version': '0.11.88'}), false);
    expect(ExplorePriceDiscoveryTool.supportsCurrentPriceRules(
      {'ok': true, 'version': '0.11.91', 'worker_version': '0.11.91'}), true);
    expect(ExplorePriceDiscoveryTool.supportsCurrentPriceRules(
      {'ok': true, 'version': '0.12.0', 'worker_version': '0.12.0'}), true);
  });

  group('price discovery tool mapping', () {
    test('procedure names match the Python canonicalizer', () {
      expect(
        ExplorePriceDiscoveryTool.procedureForTool(
          'dermal filler lips cheeks',
          pill: 'Fillers',
        ),
        'dermal filler',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool('Boob job'),
        'breast augmentation',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool('hair transplant FUE', pill: 'Hair'),
        'hair transplant',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool('chemical peel facial', pill: 'Peels'),
        'chemical peel',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool('rhinoplasty nose job', pill: 'Rhinoplasty'),
        'rhinoplasty',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool('Botox anti-wrinkle injection', pill: 'Botox'),
        'botox',
      );
    });

    test('progress events paint stored cards before the final mix', () {
      final partial = ExplorePriceDiscoveryTool.rowsFromEvent({
        'event': 'partial',
        'display_results': [
          {
            'clinic_name': 'KEIT Day Hospital',
            'price_min': 3000,
            'price_max': 3200,
            'currency': 'EUR',
            'source_url': 'https://www.keit.al/de/gebuhren/',
            'source_type': 'official_clinic',
            'clinic_own_price': true,
            'city_match': true,
            'raw_procedure_text': 'Nasenkorrektur',
            'procedure_display_name': 'Rhinoplasty',
          },
        ],
      });
      expect(partial, hasLength(1));
      expect(partial.single.clinicName, 'KEIT Day Hospital');

      final done = ExplorePriceDiscoveryTool.rowsFromEvent({
        'event': 'done',
        'body': {
          'display_results': [
            {
              'clinic_name': 'KEIT Day Hospital',
              'price_min': 3000,
              'currency': 'EUR',
              'source_url': 'https://www.keit.al/de/gebuhren/',
              'source_type': 'official_clinic',
              'clinic_own_price': true,
              'city_match': true,
            },
          ],
        },
      });
      expect(done.single.priceMin, 3000);
    });

    test('keeps an owned clinic price and drops directories', () {
      final row = ExplorePriceDiscoveryTool.rowFromJson({
        'clinic_name': 'KEIT Day Hospital',
        'price_min': 3000,
        'price_max': 3200,
        'currency': 'EUR',
        'source_url': 'https://www.keit.al/de/gebuhren/',
        'source_type': 'official_clinic',
        'evidence_type': 'official_price_menu',
        'clinic_own_price': true,
        'city_match': true,
        'raw_procedure_text': 'Nasenkorrektur',
        'raw_evidence': 'Nasenkorrektur 3.000 - 3.200 €',
        'qualifier': 'range',
        'procedure_display_name': 'Rhinoplasty',
      });
      expect(row, isNotNull);
      expect(row!.priceMin, 3000);
      expect(row.priceMax, 3200);
      expect(row.currency, 'EUR');
      expect(row.rawPriceText, '3000–3200 EUR');

      expect(
        ExplorePriceDiscoveryTool.rowFromJson({
          'clinic_name': 'MedContour',
          'price_min': 2000,
          'currency': 'EUR',
          'source_url': 'https://medcontour.org/romania',
          'source_type': 'directory',
          'clinic_own_price': false,
          'city_match': true,
        }),
        isNull,
      );

      final menu = ExplorePriceDiscoveryTool.rowFromJson({
        'clinic_name': "Joy's Touch",
        'price_min': 8000,
        'currency': 'ALL',
        'source_url': 'https://www.fresha.com/a/joys-touch-tirane',
        'source_type': 'marketplace',
        'evidence_type': 'marketplace_service_menu',
        'clinic_own_price': false,
        'city_match': true,
        'raw_procedure_text': 'Lip Filler 0.5ml',
      });
      expect(menu, isNotNull);
      expect(menu!.priceMin, 8000);
      expect(menu.currency, 'ALL');

      final listed = ExplorePriceDiscoveryTool.rowFromJson({
        'clinic_name': 'Repeat Fitness and Wellness Club',
        'price_min': 250,
        'currency': 'USD',
        'source_url':
            'https://hirefrederick.com/repeat-fitness-and-wellness-club-tirana',
        'source_type': 'marketplace',
        'evidence_type': 'marketplace_service_menu',
        'clinic_own_price': false,
        'city_match': true,
        'raw_evidence': 'Baby Botox \$250.00',
      });
      expect(listed, isNotNull);
      expect(listed!.priceMin, 250);

      expect(
        ExplorePriceDiscoveryTool.rowFromJson({
          'clinic_name': 'Locationsnearmenow',
          'price_min': 699,
          'currency': 'USD',
          'source_url':
              'https://locationsnearmenow.net/med-spa-prices-list-costs-in-usa/',
          'source_type': 'official_clinic',
          'evidence_type': 'official_price_menu',
          'clinic_own_price': true,
          'city_match': true,
        }),
        isNull,
      );
      expect(
        ExplorePriceDiscoveryTool.rowFromJson({
          'clinic_name': 'MioDottore',
          'price_min': 400,
          'currency': 'EUR',
          'source_url': 'https://www.miodottore.it/servizi/botox-2/milano',
          'source_type': 'official_clinic',
          'evidence_type': 'official_treatment_page',
          'clinic_own_price': true,
          'city_match': true,
        }),
        isNull,
      );
    });
  });
}
