import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';

void main() {
  test('a treatment page without a fee cannot supply a price card', () {
    // Representative offline page, not a fetch or current-site assertion.
    final rows = extractPriceEvidence(
      sourceUrl: 'https://clinicadraolmo.com/botox-en-valencia/',
      html: '<h1>Botox en Valencia</h1>'
          '<p>Toxina botulínica para las arrugas faciales.</p>'
          '<p>Valoración 4.9 de 5, 230 reseñas.</p>'
          '<p>Teléfono +34 963 456 789. Solicita una valoración.</p>',
    );
    expect(rows, isEmpty);
  });

  test('an official tariff keeps its published treatment and fee', () {
    final rows = extractPriceEvidence(
      sourceUrl: 'https://valencia-clinic.example/prices/',
      html:
          '<h1>Precios</h1><table><tr>'
          '<td>Toxina botulínica (3 zonas)</td><td>230 €</td>'
          '</tr></table>',
    );
    expect(rows, isNotEmpty);
    expect(rows.first.priceMin, 230);
    expect(rows.first.rawProcedureText, contains('3 zonas'));
  });

  test('a market paragraph cannot hide behind an exact-looking table row', () {
    final rows = extractPriceEvidence(
      sourceUrl: 'https://valencia-clinic.example/prices/',
      html:
          '<h1>Botox prices</h1>'
          '<p>On average Botox prices across clinics range from 150 to 400 euros.</p>'
          '<table><tr><td>Botox 3 zones</td><td>230 €</td></tr></table>',
    );
    expect(rows, isEmpty);
  });

  test('foreign price comparisons cannot become local clinic tariffs', () {
    final rows = extractPriceEvidence(
      sourceUrl: 'https://valencia-clinic.example/prices/',
      html:
          '<h1>Compare Botox prices</h1>'
          '<p>Compared with UK prices, patients can save up to 50 percent.</p>'
          '<table><tr><td>Botox 3 zones</td><td>230 €</td></tr></table>',
    );
    expect(rows, isEmpty);
  });
}
