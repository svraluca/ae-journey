import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:glowpass/services/openai_service.dart';

void main() {
  group('price sanity gate', () {
    test('+34 621 145 099 is rejected as a phone', () {
      expect(looksLikePhoneNumber('+34 621 145 099'), isTrue);
      expect(parsePriceText('+34 621 145 099'), isNull);
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '+34 621 145 099',
          priceMin: 34621145099,
          currency: 'EUR',
          extractionMethod: 'dom_block',
        ),
        isFalse,
      );
    });

    test('+34 933 623 707 is rejected as a phone', () {
      expect(looksLikePhoneNumber('+34 933 623 707'), isTrue);
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '+34 933 623 707',
          priceMin: 34933623707,
          currency: '',
          extractionMethod: 'dom_block',
        ).reason,
        'phone_number',
      );
    });

    test('UAE emergency 999 is not a Botox price', () {
      expect(
        looksLikeEmergencyOrHelpNumber(
          'In urgent cases, ring 999; this is the emergency number for the UAE',
          priceMin: 999,
        ),
        isTrue,
      );
      expect(
        looksLikeEmergencyOrHelpNumber(
          'Ambulance: 999/998',
          priceMin: 999,
        ),
        isTrue,
      );
      expect(
        looksLikeGoogleAreaEstimateBlurb(
          'promotional pricing for upper face Botox has run from '
          'approximately AED 600, while standard aesthetic pricing '
          'through Enhance by Mediclinic starts from around AED 55 per unit',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'approximately AED 600',
          priceMin: 600,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'Rezumat generat de AI · starts from around AED 55 per unit',
          procedure: 'Botox anti-wrinkle injection',
        ).accepted,
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '999 AED',
          priceMin: 999,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          procedure: 'Botox anti-wrinkle injection',
        ).accepted,
        isTrue,
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'from 999 AED',
          priceMin: 999,
          currency: 'AED',
          extractionMethod: 'html_table',
          rawEvidence: 'Botox one area from 999 AED',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '999 درهمًا إماراتيًا',
          priceMin: 999,
          currency: 'AED',
          extractionMethod: 'html_table',
          rawEvidence:
              'كل يوم إثنين استغلي عرضنا الحصري على البوتوكس بسعر 999 درهمًا إماراتيًا',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
    });

    test('08021 Barcelona is rejected as an address', () {
      expect(looksLikeAddressNumber('08021 Barcelona'), isTrue);
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '08021 Barcelona',
          priceMin: 8021,
          currency: '',
          extractionMethod: 'text_proximity',
        ),
        isFalse,
      );
    });

    test('2026 without price context is rejected', () {
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '2026',
          priceMin: 2026,
          currency: '',
          extractionMethod: 'text_proximity',
        ).reason,
        'missing_price_semantics',
      );
    });

    test('30min is rejected as a duration', () {
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '30min',
          priceMin: 30,
          currency: '',
          extractionMethod: 'dom_block',
        ).reason,
        'duration',
      );
    });

    test('syringe price is kept when the page says results last a month', () {
      expect(
        looksLikeMonthlyFinancingQuotedAsPrice(
          priceMin: 950,
          rawPriceText: r'$950 per syringe',
          blob:
              'Restylane® \$950 per syringe. Results typically last a month. '
              'Ask about monthly financing with CareCredit.',
        ),
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: r'$950 per syringe',
          priceMin: 950,
          currency: 'USD',
          extractionMethod: 'list_item',
          rawEvidence:
              'Restylane® \$950 per syringe. Results typically last a month.',
          procedure: 'Restylane',
        ).accepted,
        isTrue,
      );
    });

    test(r'$99/mo is still monthly financing', () {
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: r'$99/mo',
          priceMin: 99,
          currency: 'USD',
          extractionMethod: 'list_item',
        ).reason,
        'monthly_financing',
      );
    });

    test('typical sessions ranging from \$500 to \$800 is not a FROM price', () {
      const blob =
          'Prices vary depending on the type and amount of filler used, with '
          'typical sessions ranging from \$500 to \$800 per syringe; a detailed '
          'estimate is provided during your consultation.';
      expect(
        looksLikeTypicalMarketRangeQuotedAsPrice(
          priceMin: 500,
          rawPriceText: blob,
          blob: blob,
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: blob,
          priceMin: 500,
          currency: 'USD',
          extractionMethod: 'text_proximity',
          rawEvidence: blob,
          procedure: 'filler',
        ).accepted,
        isFalse,
      );
    });

    test('typical Botox might cost between \$100 and \$800 is market_average', () {
      const blob =
          "The cost of Botox for frown lines will vary depending on the "
          "provider's experience, the patient's location, and the quantity "
          'of Botox needed. A typical Botox treatment for frown wrinkles '
          'might cost between \$100 and \$800 per session.';
      expect(
        looksLikeTypicalMarketRangeQuotedAsPrice(
          priceMin: 100,
          rawPriceText: blob,
          blob: blob,
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: blob,
          priceMin: 100,
          currency: 'USD',
          extractionMethod: 'text_proximity',
          rawEvidence: blob,
          procedure: 'Botox anti-wrinkle injection',
          sourceUrl: 'https://www.tarikcavusoglu.com/en/botox-injections',
        ).accepted,
        isFalse,
      );
    });

    test('Botox \$13/unit is kept when the same row says lasts 3–4 months', () {
      const blob =
          'Wrinkle Relaxers · Forehead, frown lines, crow\'s feet · '
          '3–4 months · \$13/unit';
      expect(
        looksLikeDurationQuotedAsPrice(
          priceMin: 13,
          rawPriceText: '\$13/unit',
          blob: blob,
        ),
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '\$13/unit',
          priceMin: 13,
          currency: 'USD',
          extractionMethod: 'html_table',
          rawEvidence: blob,
          procedure: 'Botox',
        ).accepted,
        isTrue,
      );
    });

    test('Miami Skin & Vein \$18 per unit is kept despite 30 days in the blob', () {
      const blob =
          'BOTOX® Cosmetic\$18.00 per unit. On average, 40-50 units of BOTOX® '
          'are used to treat the entire upper face. Consultation credited '
          'within 30 days of the initial visit.';
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '\$18.00 per unit',
          priceMin: 18,
          currency: 'USD',
          extractionMethod: 'list_item',
          rawEvidence: blob,
          procedure: 'Botox',
        ).accepted,
        isTrue,
      );
    });

    test('4.8 / 120 reviews is rejected', () {
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '4.8 / 120 reviews',
          priceMin: 120,
          currency: '',
          extractionMethod: 'list_item',
          rawEvidence: '4.8 / 120 reviews',
        ),
        isFalse,
      );
    });

    test('Desde 120 € is accepted', () {
      final parsed = parsePriceText('Desde 120 €');
      expect(parsed?.priceMin, 120);
      expect(parsed?.currency, 'EUR');
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'Desde 120 €',
          priceMin: parsed!.priceMin,
          currency: parsed.currency,
          extractionMethod: 'html_table',
        ),
        isTrue,
      );
    });

    test('Botox 3 zonas — 400 EUR is accepted', () {
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '400 EUR',
          priceMin: 400,
          currency: 'EUR',
          extractionMethod: 'html_table',
          procedure: 'Botox 3 zonas',
        ),
        isTrue,
      );
    });

    test('Rinoplastia desde 4.500 € is accepted', () {
      final parsed = parsePriceText('Rinoplastia desde 4.500 €');
      expect(parsed?.priceMin, 4500);
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'desde 4.500 €',
          priceMin: parsed!.priceMin,
          currency: parsed.currency,
          extractionMethod: 'html_table',
          procedure: 'Rinoplastia',
        ),
        isTrue,
      );
    });

    test('Rhinoplasty €6,500 is accepted', () {
      final parsed = parsePriceText('Rhinoplasty €6,500');
      expect(parsed?.priceMin, 6500);
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '€6,500',
          priceMin: parsed!.priceMin,
          currency: parsed.currency,
          extractionMethod: 'html_table',
          procedure: 'Rhinoplasty',
        ),
        isTrue,
      );
    });

    test('schema Offer 2026 EUR is accepted', () {
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '2026 EUR',
          priceMin: 2026,
          currency: 'EUR',
          extractionMethod: 'schema_offer',
          structuredOffer: true,
        ),
        isTrue,
      );
    });

    test('34621145099 EUR can never pass', () {
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '€34621145099',
          priceMin: 34621145099,
          currency: 'EUR',
          extractionMethod: 'dom_block',
          procedure: 'Laser',
        ).reason,
        anyOf('implausible_amount', 'phone_number'),
      );
    });

    test('cached poisoned prices are stripped before display', () {
      final row = stripInvalidCachedPriceJson({
        'name': 'Laserum',
        'price_min': 34621145099,
        'price_max': 34621145099,
        'price_label': '€34621145099',
        'currency': 'EUR',
        'raw_price_text': '+34 621 145 099',
        'extraction_method': 'dom_block',
        'price_source_url': 'https://laserum.com',
        'price_verification_status': 'official_website',
        'price_verified': true,
        'rating': 4.8,
      }, procedure: 'Laser');
      expect(row['price_min'], 0);
      expect(row['price_verified'], isFalse);
      expect(row['needs_revalidation'], isTrue);

      final clinic = OpenAIClinic.fromJson({
        'name': 'Laserum',
        'price_min': 34621145099,
        'currency': 'EUR',
        'raw_price_text': '+34 621 145 099',
        'extraction_method': 'dom_block',
        'price_source_url': 'https://laserum.com',
        'price_verification_status': 'official_website',
        'has_procedure': true,
        'brand': 'Laser',
      });
      expect(clinic.priceMin, 0);
      expect(explorePriceIsVerified(clinic), isFalse);
    });

    test('Firestore rows without extract stamp are not painted', () {
      final stale = OpenAIClinic.fromJson({
        'name': 'Tajmeel Clinic',
        'price_min': 399,
        'price_max': 1299,
        'currency': 'AED',
        'raw_price_text': '399 AED',
        'extraction_method': 'text_proximity',
        'price_source_url':
            'https://tajmeels.ae/en/lip-augmentation-cost-in-dubai/',
        'price_verification_status': 'official_website',
        'has_procedure': true,
        'brand': 'Lip filler',
      });
      expect(stale.priceMin, 0);
      expect(explorePriceIsVerified(stale), isFalse);

      final fresh = OpenAIClinic.fromJson({
        'name': 'Tajmeel Clinic',
        'price_min': 500,
        'price_max': 1000,
        'currency': 'AED',
        'raw_price_text': '500 AED to 1000 AED',
        'price_evidence_text': 'Cost: 500 AED to 1000 AED',
        'extraction_method': 'list_item',
        'price_source_url':
            'https://tajmeels.ae/en/lip-augmentation-cost-in-dubai/',
        'price_verification_status': 'official_website',
        'has_procedure': true,
        'brand': 'Lip filler',
        'price_extract_revision': kExplorePriceExtractRevision,
      });
      expect(fresh.priceMin, 500);
      expect(fresh.priceMax, 1000);
      expect(explorePriceIsVerified(fresh), isTrue);

      final stripped = stripInvalidCachedPriceJson({
        'name': 'Tajmeel Clinic',
        'price_min': 399,
        'currency': 'AED',
        'raw_price_text': '399 AED',
        'extraction_method': 'text_proximity',
        'price_source_url': 'https://tajmeels.ae/',
        'price_verification_status': 'official_website',
        'price_verified': true,
        'brand': 'Lip filler',
      }, procedure: 'dermal filler lips cheeks');
      expect(stripped['price_min'], 0);
      expect(stripped['price_rejection_reason'], 'stale_extract_revision');
    });

    test('calendar year next to preț is not a surgery price', () {
      expect(
        looksLikeCalendarYearPrice(2026, 'Rinoplastie București: preț 2026'),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'preț 2026',
          priceMin: 2026,
          currency: 'EUR',
          extractionMethod: 'dom_block',
          rawEvidence: 'Rinoplastie București: preț operație nas 2026',
          procedure: 'rhinoplasty',
        ).accepted,
        isFalse,
      );
    });

    test('în general city average is not a clinic menu', () {
      expect(
        looksLikeMarketAveragePriceBlurb(
          'În general, costul unei rinoplastii în București începe de la '
          'aproximativ 3000-4000 de euro',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'Average Price Range for Fillers in Dubai · Basic HA',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb('Lip filler 1ml from 1500 AED'),
        isFalse,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The cost of a good boob job should be no less than £5,000 - £7,000. '
          'Most reputable clinics and surgeons will price themselves in this region',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The average guide price for breast augmentation (enlargement) '
          'at a Nuffield Health hospital is £8,579',
        ),
        isFalse,
      );
      expect(
        looksLikeRoundedMarketPriceSpread(
          priceMin: 5000,
          priceMax: 7000,
          currency: 'GBP',
          procedure: 'breast augmentation',
        ),
        isTrue,
      );
    });

    test('typically range in Dubai is a city average', () {
      expect(
        looksLikeMarketAveragePriceBlurb(
          'Rhinoplasty costs in Dubai typically range from AED 27,299 to '
          'AED 50,000',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The chemical peel cost Dubai ranges from 399 AED to 1299 AED, '
          'depending on the number of sessions required, the condition of '
          'the patient',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The nose job cost Dubai ranges from 12999 AED to 19999 AED, '
          'depending on several factors',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The Hair transplant price UAE ranges from 4,999 AED to 29,999 AED, '
          'depending on the number of grafts',
        ),
        isTrue,
      );
      expect(
        clinicOwnPublishedPriceWindow(
          'The nose job cost Dubai ranges from 12999 AED to 19999 AED, '
          'depending on several factors',
        ),
        contains('12999'),
      );
      expect(
        clinicOwnPublishedPriceWindow(
          'The Hair transplant price UAE ranges from 4,999 AED to 29,999 AED',
        ),
        contains('4,999'),
      );
      expect(
        looksLikeMarketAveragePriceBlurb('Glycolic chemical peel 399 AED'),
        isFalse,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'The cost of a good boob job should be no less than £5,000 - £7,000. '
          'Most reputable clinics in this region given the cost.',
        ),
        isTrue,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'Breast enlargement - Bilateral Implants £5,995',
        ),
        isFalse,
      );
    });

    test('clinic-own range next to a city typical is accepted', () {
      const blob =
          'Rhinoplasty costs in Dubai typically range from AED 27,299 to '
          'AED 50,000, depending on factors like the surgeon’s expertise. '
          'At Quttainah Specialized Hospital, the price usually ranges from '
          'AED 22000 to AED 40,000.';
      expect(looksLikeMarketAveragePriceBlurb(blob), isTrue);
      expect(
        clinicOwnPublishedPriceWindow(blob),
        contains('22000'),
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'the price usually ranges from AED 22000 to AED 40,000',
          priceMin: 22000,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence: blob,
          procedure: 'rhinoplasty',
        ).accepted,
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'AED 27,299 to AED 50,000',
          priceMin: 27299,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence: blob,
          procedure: 'rhinoplasty',
        ).accepted,
        isFalse,
      );
    });

    test('clinic Average Cost per Area is not a city-average blog', () {
      expect(
        looksLikeMarketAveragePriceBlurb(
          'Average Cost per Area: Hairline Restoration',
        ),
        isFalse,
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'Average Price Range for Fillers in Dubai · Basic HA',
        ),
        isTrue,
      );
    });

    test('hair per-graft AED is accepted; graft count is not a package', () {
      expect(looksLikeGraftOrFollicleQuantity('1,000 grafts'), isTrue);
      expect(looksLikePerGraftQuotedPrice('8 AED per graft'), isTrue);
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '8 AED per graft',
          priceMin: 8,
          currency: 'AED',
          extractionMethod: 'html_table',
          rawEvidence: 'FUE Hair Transplant Cost in Dubai (Per Graft)',
          procedure: 'hair transplant FUE',
        ).accepted,
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 8,
          currency: 'AED',
          procedure: 'hair transplant FUE',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 6999,
          currency: 'AED',
          procedure: 'hair transplant FUE',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 1000,
          currency: 'AED',
          procedure: 'hair transplant FUE',
        ),
        isFalse,
      );
      expect(looksLikeGraftOrFollicleQuantity('1,000 FUE grafts'), isTrue);
      expect(
        looksLikeEffectivePerGraftMarketing(
          'Lowest effective cost per graft £0.76',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '1,000 FUE grafts',
          priceMin: 1000,
          currency: 'GBP',
          extractionMethod: 'list_item',
          rawEvidence: 'Cost of 1,000 FUE grafts – from £5000',
          procedure: 'hair transplant FUE',
        ).accepted,
        isFalse,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from 3499 GBP/graft',
          priceMin: 3499,
          currency: 'GBP',
          extractionMethod: 'text_proximity',
          rawEvidence: 'FUE starts from £3,499 grafts',
          procedure: 'hair transplant FUE',
        ).accepted,
        isFalse,
      );
    });

    test('gold packages, Quick Facts, and SEO titles are not clinic prices', () {
      expect(
        looksLikeMixedServiceBundle(
          'د.إ 999 الباقة الذهبية اختر أي 2 من الخدمات التالية '
          'ليزر الكربون هايدرا فيشل',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'د.إ 999',
          priceMin: 999,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'د.إ 999 الباقة الذهبية اختر أي 2 من الخدمات التالية '
              'ليزر الكربون هايدرا فيشل',
          procedure: 'Botox anti-wrinkle injection',
        ).accepted,
        isFalse,
      );
      expect(
        looksLikeSearchQuickFactsBlob('Quick Facts: · Lip filler 1,300 AED'),
        isTrue,
      );
      expect(
        looksLikeSearchQuickFactsBlob(
          'Quick Facts:\nCost: 500 AED to 1000 AED',
        ),
        isFalse,
      );
      expect(
        looksLikeClinicLabeledCostFact('Cost: 500 AED to 1000 AED'),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '500 AED to 1000 AED',
          priceMin: 500,
          currency: 'AED',
          extractionMethod: 'list_item',
          rawEvidence: 'Quick Facts:\nCost: 500 AED to 1000 AED',
          procedure: 'lip augmentation dermal fillers',
        ).accepted,
        isTrue,
      );
      expect(
        looksLikeSearchQuickFactsBlob(
          'At Tajmeel Clinic in Abu Dhabi, dermal filler sessions generally '
          'start around AED 599 to AED 1,000+ per syringe. MediGence',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '1,300 AED',
          priceMin: 1300,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence: 'Quick Facts: · Lip filler 1,300 AED to 1,599 AED',
          procedure: 'dermal filler lips cheeks',
        ).reason,
        'search_quick_facts',
      );
      expect(
        looksLikeSeoQuotedPriceHeadline(
          'Laser Hair Removal Price Abu Dhabi — From AED 100 | Dr Azra',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'From AED 100',
          priceMin: 100,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'Laser Hair Removal Price Abu Dhabi — From AED 100 | Dr Azra',
          procedure: 'laser skin treatment hair removal',
        ).reason,
        'seo_price_headline',
      );
      expect(
        looksLikeMarketAveragePriceBlurb(
          'تتراوح تكلفة تجميل الأنف في دبي بين 17,999 درهم إماراتي '
          'و 29,999 درهم إماراتي',
        ),
        isTrue,
      );
      expect(
        clinicOwnPublishedPriceWindow(
          'تتراوح تكلفة تجميل الأنف في دبي بين 17,999 درهم إماراتي '
          'و 29,999 درهم إماراتي',
        ),
        isNull,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: '17,999 درهم',
          priceMin: 17999,
          currency: 'AED',
          extractionMethod: 'text_proximity',
          rawEvidence:
              'تتراوح تكلفة تجميل الأنف في دبي بين 17,999 درهم إماراتي '
              'و 29,999 درهم إماراتي',
          procedure: 'rhinoplasty nose job',
        ).reason,
        'market_average',
      );
      expect(
        parsePriceText('starts from AED 490')?.priceMin,
        490,
      );
      expect(
        parsePriceText('starts from AED 490')?.priceType,
        PriceType.from,
      );
      expect(
        parsePriceText(
          'At SKIN111, our chemical peel treatment starts from AED 490',
        )?.priceMin,
        490,
      );
    });

    test('Shopify \$399.99 dummy and USD on .co.uk are rejected', () {
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from \$399.99',
          priceMin: 399.99,
          currency: 'USD',
          extractionMethod: 'dom_block',
        ).reason,
        'theme_placeholder',
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from 400 USD',
          priceMin: 400,
          currency: 'USD',
          extractionMethod: 'list_item',
          sourceUrl: 'https://2glow.co.uk/pages/botox',
        ).reason,
        'tld_currency_mismatch',
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: '£99',
          priceMin: 99,
          currency: 'GBP',
          extractionMethod: 'list_item',
          sourceUrl: 'https://2glow.co.uk/pages/botox',
        ),
        isTrue,
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'from \$200',
          priceMin: 200,
          currency: 'USD',
          extractionMethod: 'list_item',
          sourceUrl: 'https://example.com/botox',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from £2,500',
          priceMin: 2500,
          currency: 'GBP',
          extractionMethod: 'html_table',
          procedure: 'breast augmentation',
          sourceUrl: 'https://harleystreetbreastcentre.com/breast-augmentation/',
        ).reason,
        'implausible_amount',
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'from £4,595',
          priceMin: 4595,
          currency: 'GBP',
          extractionMethod: 'html_table',
          procedure: 'breast augmentation',
          sourceUrl: 'https://enhancemedicalgroup.com/boob-job-cost',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 2500,
          currency: 'GBP',
          procedure: 'breast augmentation',
        ),
        isFalse,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 4595,
          currency: 'GBP',
          procedure: 'breast augmentation',
        ),
        isTrue,
      );
    });

    test('Cosmelan starter kit is a depigmentation package, not a facial peel session', () {
      expect(
        looksLikeDepigmentationPeelPackage(
          'Cosmelan Peel Starter Kit £900 – Limited Time Offer',
        ),
        isTrue,
      );
      expect(
        looksLikeDepigmentationPeelPackage('Glycolic chemical peel from £200'),
        isFalse,
      );
    });

    test('hair market £/graft copy and stale landing quotes are rejected', () {
      expect(
        looksLikeHairMarketPerGraftBlurb(
          'FUE hair transplants in London often cost £2–£3 per graft',
        ),
        isTrue,
      );
      expect(
        looksLikeHairMarketPerGraftBlurb(
          'FUT may be slightly cheaper, starting at £1.50 per graft',
        ),
        isTrue,
      );
      expect(
        looksLikeHairMarketPerGraftBlurb('Our FUE is £2.50 per graft'),
        isFalse,
      );
      expect(
        looksLikeHairFutWhenFueRequested(
          procedure: 'hair transplant FUE',
          blob: 'FUT starting at £1.50 per graft',
        ),
        isTrue,
      );
      expect(
        looksLikeHairProcedureLandingUrl(
          'https://drmarktam.co.uk/fue-hair-transplant/',
        ),
        isTrue,
      );
      expect(
        looksLikeHairProcedureLandingUrl('https://drmarktam.co.uk/fees/'),
        isFalse,
      );
      expect(
        looksLikeHairStaleLandingQuote(
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          blob:
              'Our hair transplant treatment fee starts from £5400 to £7600.',
          priceMin: 5400,
          priceMax: 7600,
        ),
        isTrue,
      );
      expect(
        looksLikeHairStaleLandingQuote(
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          blob: 'Our hair transplant treatment fee to £7600.',
          priceMin: 5400,
          priceMax: 5400,
        ),
        isTrue,
      );
      expect(
        looksLikeHairStaleLandingQuote(
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          blob: 'from 5400 £',
          priceMin: 5400,
          priceMax: 5400,
        ),
        isTrue,
      );
      expect(
        looksLikeHairStaleLandingQuote(
          sourceUrl: 'https://drmarktam.co.uk/fees/',
          blob: 'Min fee £14,400 inc 20% VAT',
          priceMin: 14400,
        ),
        isFalse,
      );
      expect(
        looksLikeHairLargerThanStartingPackage(
          'Package 2 Micro Sapphire FUE 5,000 £3,799',
        ),
        isTrue,
      );
      expect(
        looksLikeHairLargerThanStartingPackage(
          'Lowest total payable £3,199 including the £200 arrangement fee',
        ),
        isFalse,
      );
      expect(
        looksLikeHairCachedNonStartingPackageFrom(
          sourceUrl: 'https://www.fksclinic.co.uk/hair-transplant-uk/cost/',
          blob: 'Hair transplant\nfrom 3,799 £',
          priceMin: 3799,
        ),
        isTrue,
      );
      expect(
        exploreMandatoryPackageAddOnFee(
          'A £200 arrangement fee applies to every package, '
          'so the total payable ranges from £3,199 to £4,999.',
        ),
        200,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'starts from £5400 to £7600',
          priceMin: 5400,
          priceMax: 7600,
          currency: 'GBP',
          extractionMethod: 'dom_block',
          procedure: 'hair transplant FUE',
          sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
          rawEvidence:
              'Our hair transplant treatment fee starts from £5400 to £7600.',
        ).reason,
        'hair_stale_landing',
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from £1.50 per graft',
          priceMin: 1.5,
          currency: 'GBP',
          extractionMethod: 'dom_block',
          procedure: 'hair transplant FUE',
          sourceUrl:
              'https://londonhairtransplantclinic.uk/the-cost-of-hair-transplants-london-a-complete-breakdown/',
          rawEvidence: 'FUT starting at £1.50 per graft',
        ).reason,
        'hair_market_per_graft',
      );
    });

    test('rhinoplasty market guide is rejected; hospital guide stays scoped', () {
      expect(
        looksLikeCityMarketPricingGuideUrl(
          'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/',
        ),
        isTrue,
      );
      expect(
        evaluateExtractedPriceCandidate(
          rawPriceText: 'from £7,000–£15,000',
          priceMin: 7000,
          priceMax: 15000,
          currency: 'GBP',
          extractionMethod: 'dom_block',
          procedure: 'rhinoplasty nose job',
          sourceUrl:
              'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/',
          rawEvidence: 'Ethnic rhinoplasty £7,000–£15,000',
        ).reason,
        'market_information',
      );
      expect(
        looksLikeHospitalFeesOnlyQuote(
          'from £3,000* (guide price). This guide price excludes consultation '
          'fees and professional fees charged separately by your surgeon.',
        ),
        isTrue,
      );
      expect(
        looksLikeHospitalFeesOnlyQuote(
          'Rhinoplasty costs £6,295 with Enhance Medical and includes a '
          'night’s stay in hospital.',
        ),
        isFalse,
      );
      expect(
        isValidExtractedPriceCandidate(
          rawPriceText: 'starts from £3,000* (guide price)',
          priceMin: 3000,
          currency: 'GBP',
          extractionMethod: 'list_item',
          procedure: 'rhinoplasty nose job',
          sourceUrl: 'https://hje.org.uk/treatments/rhinoplasty/',
          rawEvidence:
              'hospital charges associated with your treatment. Guide price '
              'excludes surgeon and anaesthetist fees.',
        ),
        isTrue,
      );
    });
  });

  group('Chisinau lei Botox', () {
    test('Chisinau lei Botox: 150 lei per unit is justified', () {
      expect(
        looksLikeBotoxPerUnitQuote(
          'Correcting facial wrinkles (1 unit botulinum toxin)',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      expect(
        looksLikeBotoxPerUnitQuote(
          'Corectare riduri faciale (1 unitate toxina botulinica)',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 150,
          currency: 'RON',
          procedure: 'Botox anti-wrinkle injection',
          evidence: 'Correcting facial wrinkles (1 unit botulinum toxin) 150 lei',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 70,
          currency: 'EUR',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 150,
          currency: 'RON',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isFalse,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 390,
          currency: 'RON',
          procedure: 'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      // Cronos Med Timisoara real Botox is 920–1770 lei; 6500 was a
      // surgery-sized figure mis-attached as Botox.
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 6500,
          currency: 'RON',
          procedure: 'Botox anti-wrinkle injection',
          evidence: 'Botox treatment',
        ),
        isFalse,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 1770,
          currency: 'RON',
          procedure: 'Botox anti-wrinkle injection',
          evidence: '3 zone 1770 lei',
        ),
        isTrue,
      );
      // Chișinău surgery menus print euro amounts; city default is MDL.
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 3000,
          currency: 'MDL',
          procedure: 'breast augmentation',
          evidence: 'Breast augmentation 3000-3500',
        ),
        isTrue,
      );
      expect(
        isJustifiedProcedurePriceValue(
          priceMin: 3700,
          currency: 'MDL',
          procedure: 'rhinoplasty nose job',
        ),
        isTrue,
      );
    });
  });
}
