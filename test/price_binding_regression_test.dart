import '../lib/services/explore_price_binding.dart';
void check(bool condition, String label) {
  if (!condition) throw StateError('FAILED: $label');
}
void main() {
  check(exploreBreastProcedureDisplayName(
    rawProcedureText: 'Mărire a sânilor',
    evidence: 'Mărire a sânilor 5700 – 6100 Euro (prețul nu include implantul mamar)',
    priceMin: 5700, currency: 'EUR',
  ).endsWith('Implant cost excluded'), 'excluded implant is visible');
  check(!exploreBreastImplantCostExcluded('implanturile sunt incluse'), 'included implants');
  check(!exploreBreastImplantCostExcluded('fat transfer without implants'), 'fat transfer');
  for (final text in [
    'Schimbare a implanturilor mamare 5000 EUR',
    'Îndepărtare implant mamar 5000 EUR',
    'Reconstrucție cu implant mamar 5000 EUR',
    'Mărire de sâni cu implant și ridicare 5000 EUR',
  ]) {
    check(exploreBreastPriceIsOtherSurgery(evidence: text, priceMin: 5000, currency: 'EUR'), text);
  }
  check(!exploreBreastPriceIsOtherSurgery(
    evidence: 'Mărire de sâni cu implante mamare 17000 RON', priceMin: 17000, currency: 'RON',
  ), 'primary implants');
  check(exploreBreastProcedureDetail(
    rawProcedureText: 'Breast augmentation',
    evidence: 'Breast augmentation with implants 5000 EUR; Implant replacement 6000 EUR (excluding implants)',
    priceMin: 5000, currency: 'EUR',
  ) == 'With implants', 'adjacent service cannot change price scope');
  check(explorePublishedPriceIsSuperseded(
    evidence: 'Botox from £250 from £180', priceMin: 250, currency: 'GBP',
  ), 'old price rejected');
  print('10 Dart regression checks passed.');
}
