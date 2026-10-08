import 'package:flutter_test/flutter_test.dart';

import '../lib/services/explore_compare_mix.dart';
import '../lib/services/explore_price_discovery_tool.dart';
import '../lib/services/explore_search_locale.dart';

void main() {
  test('NYC boroughs match New York and nearby state localities conflict', () {
    expect(exploreCanonicalCityKey('Manhattan'), 'new york');
    expect(exploreCanonicalCityKey('Brooklyn'), 'new york');
    expect(explorePlacesAddressConflictsWithSearchCity('Queens, NY', 'New York'), isFalse);
    expect(explorePlacesAddressConflictsWithSearchCity('Clifton Park, New York', 'New York'), isTrue);
    expect(explorePlacesAddressConflictsWithSearchCity('White Plains, New York', 'New York'), isTrue);
  });

  const shared = 'https://novomed.com/services/cosmetic-dermatology/'
      'botox-in-abu-dhabi-and-al-ain/';

  test('shared-city price page remains local to each named city', () {
    expect(exploreUrlConflictsWithSearchCity(shared, 'Abu Dhabi'), isFalse);
    expect(exploreUrlConflictsWithSearchCity(shared, 'Al Ain'), isFalse);
    expect(exploreUrlConflictsWithSearchCity(shared, 'Dubai'), isTrue);
    expect(exploreQuotedPriceConflictsWithSearchCity(
      city: 'Abu Dhabi', url: shared,
      evidence: 'Botox in Abu Dhabi and Al Ain starts from AED 1500',
    ), isFalse);
  });

  test('hostname or query cannot rescue a Dubai-only price for Abu Dhabi', () {
    expect(exploreUrlConflictsWithSearchCity(
      'https://abudhabi.example/botox-in-dubai/?q=Abu-Dhabi', 'Abu Dhabi',
    ), isTrue);
    expect(exploreQuotedPriceConflictsWithSearchCity(
      city: 'Abu Dhabi', url: shared, evidence: 'Botox in Dubai costs AED 900',
    ), isTrue);
    expect(explorePlacesAddressConflictsWithSearchCity('Motor City, Dubai', 'Abu Dhabi'), isTrue);
  });

  test('initial selection keeps two saved plus two fresh and removes duplicates', () {
    final selected = selectExploreCompareRows<String>(
      saved: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      live: ['f', 'h', 'i', 'j'],
      sameProvider: (a, b) => a == b,
    );
    expect(selected, ['a', 'b', 'f', 'h']);
    expect(selected.toSet().length, 4);
  });

  test('short pools remain short and cold starts can show four live rows', () {
    List<String> select(List<String> saved, List<String> live) => selectExploreCompareRows(
      saved: saved, live: live, sameProvider: (String a, String b) => a == b,
    );
    expect(select(['a'], ['b']), ['a', 'b']);
    expect(select([], List.generate(10, (i) => '$i')).length, 4);
    expect(exploreCompareTargets(0).live, 4);
    expect(exploreCompareTargets(1).live, 3);
    expect(exploreCompareTargets(2).live, 2);
    expect(exploreCompareTargets(20).live, 2);
    expect(ExplorePriceDiscoveryTool.compareDisplayLimit, kExploreCompareDisplayLimit);
  });

  test('a Dubai provider needs local tariff proof to appear in Abu Dhabi', () {
    const source = 'https://www.estheticlinicdubai.com/en-ae/cosmetic-injectables/fillers/';
    expect(exploreProviderIdentityConflictsWithSearchCity(
      city: 'Abu Dhabi', name: 'Esthetic Clinic Dubai', sourceUrl: source,
      evidence: 'Dermal filler AED 500',
    ), isTrue);
    expect(exploreProviderIdentityConflictsWithSearchCity(
      city: 'Dubai', name: 'Esthetic Clinic Dubai', sourceUrl: source,
      evidence: 'Dermal filler AED 500',
    ), isFalse);
    expect(exploreProviderIdentityConflictsWithSearchCity(
      city: 'Abu Dhabi', name: 'Esthetic Clinic Dubai',
      sourceUrl: 'https://www.estheticlinicdubai.com/prices/abu-dhabi/',
      evidence: 'Dermal filler prices in Abu Dhabi: AED 500',
    ), isFalse);
  });
}
