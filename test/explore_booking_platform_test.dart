import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_clinic_identity.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_marketplace_discovery.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/openai_service.dart';

/// Tirana filler: the case where Compare showed 2/4 cards while six clean
/// priced rows sat on one Fresha venue page.
const _kKlaudias =
    'https://www.fresha.com/a/klaudias-aesthetic-tirane-tirana-'
    'rruga-petro-korcari-nzu73yzx';

void main() {
  group('booking-platform venue URLs', () {
    test('Serper /booking deep link normalises to the venue root', () {
      // The booking form renders client-side and carries no prices at all.
      expect(
        exploreBookingPlatformVenueUrl(
          '$_kKlaudias/booking?offerItemId=s:17834615',
        ),
        _kKlaudias,
      );
    });

    test('venue root is already canonical', () {
      expect(exploreBookingPlatformVenueUrl(_kKlaudias), _kKlaudias);
    });

    test('search and city hubs are not venue pages', () {
      for (final url in [
        'https://www.fresha.com/en-GB/search?address-name=Tirane',
        'https://www.fresha.com/',
        'https://www.fresha.com/for-business',
        'https://whatclinic.com/cosmetic-plastic-surgery/albania/tirana',
      ]) {
        expect(
          exploreIsBookingPlatformVenueUrl(url),
          isFalse,
          reason: url,
        );
      }
    });

    test('Booksy listing keeps its slug shape', () {
      const url = 'https://booksy.com/en-us/12345_glow-clinic_medical-spa_678';
      expect(exploreIsBookingPlatformVenueUrl(url), isTrue);
    });

    test('Hirefrederick is the directory, not the clinic', () {
      const url =
          'https://hirefrederick.com/repeat-fitness-and-wellness-club-tirana';
      expect(isMarketplaceOrDirectoryHost(url), isTrue);
      expect(isMarketplaceBrandName('Hirefrederick'), isTrue);
      expect(
        marketplaceListingBusinessNameFromUrl(url),
        'Repeat Fitness And Wellness Club',
      );
      expect(
        clinicIdentityRejectReason(
          'Hirefrederick',
          websiteHost: 'hirefrederick.com',
        ),
        'marketplace_without_provider',
      );
      expect(
        clinicIdentityRejectReason(
          'Repeat Fitness And Wellness Club',
          websiteHost: 'hirefrederick.com',
          providerClinic: 'Repeat Fitness And Wellness Club',
        ),
        isNull,
      );
    });

    test('a rejected revalidation removes the cached card', () {
      final cleared = OpenAIClinic(
        rank: 1,
        name: 'Botoxtirana',
        area: 'Tiranë · botoxtirana.com',
        distanceMi: 0,
        rating: 0,
        reviews: 0,
        priceGbp: 0,
        priceMin: 0,
        priceMax: 0,
        priceLabel: '',
        currency: 'EUR',
        brand: 'botox',
        badge: '',
        badgeVariant: 'mid',
        coord: const OpenAICoord(0, 0),
        hasProcedure: true,
        pricePending: true,
        priceSourceUrl: 'https://botoxtirana.com/cost-of-procedures/',
        priceVerificationStatus: PriceVerificationStatus.unverified,
        priceRejectionReason: 'no_prices_on_page',
      );
      expect(exploreRevalidationRemovesCard(cleared), isTrue);
      expect(
        exploreClinicDisplayName(
          OpenAIClinic(
            rank: 1,
            name: 'Hirefrederick',
            area: 'Tiranë · hirefrederick.com',
            distanceMi: 0,
            rating: 0,
            reviews: 0,
            priceGbp: 250,
            priceMin: 250,
            priceMax: 250,
            priceLabel: '250 USD',
            currency: 'USD',
            brand: 'botox',
            badge: '',
            badgeVariant: 'mid',
            coord: const OpenAICoord(0, 0),
            hasProcedure: true,
            pricePending: false,
            priceSourceUrl:
                'https://hirefrederick.com/repeat-fitness-and-wellness-club-tirana',
          ),
        ),
        'Repeat Fitness And Wellness Club',
      );
    });

    test('directories are not booking platforms', () {
      expect(isBookingPlatformHost('whatclinic.com'), isFalse);
      expect(isBookingPlatformHost('bookimed.com'), isFalse);
      expect(isBookingPlatformHost('www.fresha.com'), isTrue);
      expect(isBookingPlatformHost('booksy.com'), isTrue);
    });

    test('booking platforms stay marketplaces so the provider rebind runs',
        () {
      // This is what stops "Fresha" ever becoming the clinic card title.
      expect(isMarketplaceOrDirectoryHost('fresha.com'), isTrue);
      expect(
        clinicIdentityRejectReason('Some Venue', websiteHost: 'fresha.com'),
        'marketplace_without_provider',
      );
      expect(
        clinicIdentityRejectReason(
          'Klaudia\'S Aesthetic',
          websiteHost: 'fresha.com',
          providerClinic: 'Klaudia\'S Aesthetic',
        ),
        isNull,
      );
    });
  });

  group('venue naming', () {
    test('Fresha page title drops the address and the platform brand', () {
      expect(
        exploreBookingPlatformVenueName(
          'Klaudia&#x27;S Aesthetic - Tirana, Rruga Petro Korçari 1069 - '
          'Tiranë | Fresha',
        ),
        "Klaudia'S Aesthetic",
      );
    });

    test('Serper booking title drops the CTA prefix', () {
      expect(
        exploreBookingPlatformVenueName(
          "Make an appointment at Klaudia'S Aesthetic - Tirana, Rruga Petro",
        ),
        "Klaudia'S Aesthetic",
      );
    });

    test('the platform brand alone is not a venue', () {
      expect(exploreBookingPlatformVenueName('Fresha'), '');
      expect(exploreBookingPlatformVenueName('Booksy'), '');
    });

    test('provider name comes from the page JSON-LD, not the Fresha slug', () {
      final html = File('test/fixture_fresha_klaudias.html').readAsStringSync();
      expect(
        extractMarketplaceProviderName(html, sourceUrl: _kKlaudias),
        "Klaudia'S Aesthetic",
      );
    });
  });

  group('price bands outside the eurozone', () {
    test('Albanian lek filler is no longer judged on a EUR ceiling', () {
      // 18,000 ALL is ~EUR 180. Against the unscaled 5,000 filler ceiling it
      // read as implausible, which voided the whole Albanian market.
      final band = plausibleAmountBand(currency: 'ALL', procedure: 'lip filler');
      expect(18000, greaterThanOrEqualTo(band.min));
      expect(18000, lessThanOrEqualTo(band.max));
    });

    test('eurozone bands are untouched', () {
      final band = plausibleAmountBand(currency: 'EUR', procedure: 'lip filler');
      expect(band.min, 30);
      expect(band.max, 5000);
      expect(plausibleAmountBand(currency: 'EUR', procedure: 'botox').max, 800);
    });

    test('AED Botox keeps a published 1800 starting price', () {
      final band = plausibleAmountBand(currency: 'AED', procedure: 'botox');
      expect(1800, greaterThanOrEqualTo(band.min));
      expect(1800, lessThanOrEqualTo(band.max));
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'Botox treatment from AED 1,800.',
          priceMin: 1800,
          currency: 'AED',
          extractionMethod: 'html_paragraph',
          procedure: 'botox',
          sourceUrl: 'https://hortmanclinics.com/best-botox-brands-dubai/',
        ),
        isTrue,
      );
    });

    test('a currency with a hand-tuned branch keeps it', () {
      final band = plausibleAmountBand(currency: 'RON', procedure: 'filler');
      expect(band.max, 25000);
    });
  });

  group('injectable volume', () {
    test('volume is read off the service name, never the amount', () {
      expect(exploreInjectableVolumeMl('LIP FILLER 1ML'), 1.0);
      expect(exploreInjectableVolumeMl('LIP FILLERS 0.5'), 0.5);
      expect(exploreInjectableVolumeMl('Lip Filler 0.5 ml'), 0.5);
      expect(exploreInjectableVolumeMl('Mbushës buzësh 1 ml'), 1.0);
    });

    test('unspecified volume stays unspecified', () {
      // My Spa Tirana publishes "Filler — EUR 100" with no volume. Inventing
      // 1 ml there would make it falsely comparable.
      expect(exploreInjectableVolumeMl('Filler'), isNull);
      expect(exploreInjectableVolumeMl('Dermal filler treatment'), isNull);
    });

    test('non-injectable rows never get a volume', () {
      expect(exploreInjectableVolumeMl('CARBON PEELING 0.5'), isNull);
      expect(exploreInjectableVolumeMl('Laser session 2'), isNull);
    });
  });

  group('Fresha venue catalogue extraction', () {
    late List<ExtractedPriceEvidence> rows;

    setUpAll(() {
      final html = File('test/fixture_fresha_klaudias.html').readAsStringSync();
      rows = extractPriceEvidence(html: html, sourceUrl: _kKlaudias);
    });

    test('schema.org Offers behind itemOffered are parsed at all', () {
      // Before reading Offer.itemOffered this page extracted zero rows.
      expect(rows, isNotEmpty);
      expect(
        rows.every(
          (r) => r.extractionMethod == PriceExtractionMethod.schemaOffer,
        ),
        isTrue,
      );
    });

    test('every published filler row is recovered with its real amount', () {
      double? priceOf(String label) {
        for (final r in rows) {
          if (r.rawProcedureText.toUpperCase() == label.toUpperCase()) {
            return r.priceMin;
          }
        }
        return null;
      }

      expect(priceOf('LIP FILLER 1ML'), 18000);
      expect(priceOf('LIP FILLER STYLAGE 1ml'), 25000);
      expect(priceOf('CHIN FILLER 1ml'), 15000);
      expect(priceOf('JAWLINE FILLER 1ml'), 18000);
      expect(priceOf('UNDEREYE FILLER 1ml'), 20000);
      expect(priceOf('RHINOFILLER 1ml'), 20000);
    });

    test('currency is the venue currency, not a euro guess', () {
      expect(rows.every((r) => r.currency == 'ALL'), isTrue);
    });

    test('0.5 ml and 1 ml rows stay distinguishable', () {
      final half = rows.where((r) => r.quantity == 0.5).toList();
      final full = rows.where((r) => r.quantity == 1.0).toList();
      expect(half, isNotEmpty);
      expect(full, isNotEmpty);
      expect(half.every((r) => r.unit == 'ml'), isTrue);
      // The cheapest 0.5 ml lip row must not pass as a 1 ml price.
      final halfLip = half.firstWhere(
        (r) => r.rawProcedureText.toUpperCase().contains('LIP'),
      );
      expect(halfLip.priceMin, lessThan(18000));
    });

    test('the platform is never credited with the price', () {
      expect(
        rows.every(
          (r) => !r.rawProcedureText.toLowerCase().contains('fresha'),
        ),
        isTrue,
      );
    });
  });
}
