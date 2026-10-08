import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_marketplace_discovery.dart';

void main() {
  group('marketplace discovery queries', () {
    test('builds WhatClinic + Fresha + Booksy + Bookimed site queries', () {
      for (final city in ['Chisinau', 'Miami', 'Bucharest', 'Barcelona', 'Tiranë']) {
        final q = exploreMarketplaceDiscoveryQueries(
          procedure: 'Botox anti-wrinkle injection',
          city: city,
          topic: 'Botox anti-wrinkle injection',
        );
        expect(q.length, greaterThanOrEqualTo(4));
        expect(q.any((e) => e.contains('site:whatclinic.com')), isTrue);
        expect(q.any((e) => e.contains('site:fresha.com')), isTrue);
        expect(q.any((e) => e.contains('site:booksy.com')), isTrue);
        expect(q.any((e) => e.contains('site:bookimed.com')), isTrue);
        expect(q.first, contains(city));
      }
    });

    test('filler queries also probe HA brand listings and Fresha dermal fillers', () {
      final q = exploreMarketplaceDiscoveryQueries(
        procedure: 'dermal filler lips cheeks',
        city: 'București',
        topic: 'dermal filler lips cheeks',
      );
      expect(q.length, greaterThanOrEqualTo(5));
      expect(q.any((e) => e.contains('juvederm') || e.contains('restylane')), isTrue);
      expect(q.any((e) => e.contains('dermal fillers') && e.contains('fresha')), isTrue);
    });
  });

  group('marketplace clinic name parsing', () {
    test('strips WhatClinic suffix from title', () {
      expect(
        exploreClinicNameFromMarketplaceSerp(
          title: 'Clinica SANCOS - Chișinău - WhatClinic.com',
          snippet: '',
          url:
              'https://www.whatclinic.com/cosmetic-plastic-surgery/moldova/chisinau/clinica-sancos',
          city: 'Chișinău',
        ),
        'Clinica SANCOS',
      );
    });

    test('strips in City, Country from doctor listing titles', () {
      expect(
        exploreClinicNameFromMarketplaceSerp(
          title: "Dr. Esra Çabuk Cömert's Clinic in Ankara, Turkey",
          snippet: '',
          url:
              'https://www.whatclinic.com/cosmetic-plastic-surgery/turkey/ankara/dr-esra-cabuk-comert',
          city: 'Ankara',
        ),
        "Dr. Esra Çabuk Cömert's Clinic",
      );
    });

    test('website resolve query drops geo suffix and uses local clinic tokens', () {
      final q = exploreMarketplaceClinicWebsiteQuery(
        clinicName: "Dr. Esra Çabuk Cömert's Clinic in Ankara, Turkey",
        city: 'Ankara',
      );
      expect(q, isNot(contains('Turkey')));
      expect(q.toLowerCase(), contains('klinik'));
      expect(q, contains('Ankara'));
      expect(q, contains('-site:whatclinic.com'));
    });

    test('parses US WhatClinic listing for Miami', () {
      expect(
        exploreClinicNameFromMarketplaceSerp(
          title: 'Miami Institute - Miami - WhatClinic.com',
          snippet: '',
          url:
              'https://www.whatclinic.com/cosmetic-plastic-surgery/united-states/miami/miami-institute',
          city: 'Miami',
        ),
        'Miami Institute',
      );
    });

    test('reads Bookimed clinic slug', () {
      expect(
        exploreClinicNameFromMarketplaceListingUrl(
          'https://us-uk.bookimed.com/clinic/sancos-clinic/',
        ),
        'Sancos Clinic',
      );
    });

    test('reads Fresha venue slug', () {
      expect(
        exploreClinicNameFromMarketplaceListingUrl(
          'https://www.fresha.com/a/joys-touch-tirane-rruga-dhimiter-shuteriqi-ivv5sysy',
          city: 'Tiranë',
        ),
        'Joys Touch',
      );
      expect(
        exploreIsFreshaVenueUrl(
          'https://www.fresha.com/a/klaudias-aesthetic-tirane-tirana-rruga-petro-korcari-nzu73yzx',
        ),
        isTrue,
      );
    });

    test('rejects marketplace brand as clinic name', () {
      expect(
        exploreClinicNameFromMarketplaceSerp(
          title: 'WhatClinic - Find a clinic',
          snippet: 'Compare clinics',
          url:
              'https://www.whatclinic.com/cosmetic-plastic-surgery/moldova/chisinau',
          city: 'Chisinau',
        ),
        isEmpty,
      );
    });
  });

  group('marketplace website resolve query', () {
    test('excludes directory hosts for any city', () {
      final q = exploreMarketplaceClinicWebsiteQuery(
        clinicName: 'Miami Plastic Surgery',
        city: 'Miami',
      );
      expect(q, contains('Miami Plastic Surgery'));
      expect(q, contains('Miami'));
      expect(q, contains('-site:whatclinic.com'));
      expect(q, contains('-site:bookimed.com'));
      expect(q, contains('-site:mediglobus.com'));
    });
  });
}
