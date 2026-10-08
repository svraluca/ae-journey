import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/openai_service.dart';
import 'package:glowpass/services/worldwide_curated_clinics.dart';
import 'package:glowpass/ui/clinic_compare_price_display.dart';

void main() {
  test('Worldwide Botox curated list is shown without live verification', () {
    final res = WorldwideCuratedClinics.buildComparison(pill: 'Botox');
    expect(res.clinics, isNotEmpty);
    final shown = exploreCompareClinics(
      res.clinics,
      procedure: 'Botox anti-wrinkle injection',
      city: 'Worldwide',
      worldwide: true,
    );
    expect(shown, isNotEmpty);
    expect(shown.every((c) => c.priceMin > 0), isTrue);
  });
}
