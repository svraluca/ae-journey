import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_ownership.dart';
import 'package:glowpass/services/openai_service.dart';

void main() {
  group('page-level clinicOwnPrice', () {
    test('A breast augmentation starts at roughly → not clinic owned', () {
      const raw =
          'a breast augmentation starts at roughly €2,500';
      final ctx = classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/blog/breast-surgery-prices-albania-italy',
        pageText:
            'Article discussing breast surgery prices in Albania / Italy. $raw',
        title: 'Breast surgery costs Albania vs Italy',
      );
      expect(ctx, ExplorePricePageContext.foreignPriceComparison);
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ctx,
          rawEvidence: raw,
          rawProcedureText: 'a breast augmentation starts at roughly',
          rawPriceText: '€2,500',
        ),
        isFalse,
      );
      expect(
        exploreNormalizeProcedureDisplayName(
          procedureCanonical: 'breast_augmentation',
          rawProcedureText: 'a breast augmentation starts at roughly',
        ),
        'Breast Augmentation',
      );
    });

    test('With only 3.999 euros country guide → not owned + no sentence title',
        () {
      const raw =
          'With only 3.999 euros, breast augmentation in Albania offers:';
      final ctx = classifyExplorePricePageContext(
        sourceUrl:
            'https://guide.example/cost-of-breast-augmentation-in-albania/',
        pageText: raw,
        title: 'Cost of breast augmentation in Albania',
      );
      expect(ctx, ExplorePricePageContext.countryCostGuide);
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ctx,
          rawEvidence: raw,
          rawProcedureText: raw,
        ),
        isFalse,
      );
      expect(
        exploreNormalizeProcedureDisplayName(
          procedureCanonical: 'breast_augmentation',
          rawProcedureText: raw,
        ),
        'Breast Augmentation',
      );
    });

    test('Mentor package on official page → owned + clean title + detail', () {
      const raw =
          'Breast Augmentation Price includes 1 pair of implants MENTOR';
      final ctx = classifyExplorePricePageContext(
        sourceUrl: 'https://clinic.example/en/services/breast-augmentation/',
        pageText: 'Our package: $raw from €3,000',
        title: 'Breast Augmentation',
      );
      expect(
        explorePageContextIsAutomaticallyOwned(ctx) ||
            looksLikeExplicitClinicOwnPriceLanguage('Our package: $raw'),
        isTrue,
      );
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ExplorePricePageContext.officialPackagePrice,
          rawEvidence: 'Our package starts from €3,000. $raw',
          rawProcedureText: raw,
          rawPriceText: '€3,000',
        ),
        isTrue,
      );
      expect(
        exploreNormalizeProcedureDisplayName(
          procedureCanonical: 'breast_augmentation',
          rawProcedureText: raw,
        ),
        'Breast Augmentation',
      );
      expect(exploreNormalizeProcedureDetail(raw), 'Mentor implants included');
    });

    test('explicit own price language is clinic owned', () {
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ExplorePricePageContext.unknown,
          rawEvidence: 'Our breast augmentation price starts from €3,500',
          rawProcedureText: 'Breast augmentation',
          rawPriceText: '€3,500',
        ),
        isTrue,
      );
    });

    test('market page cannot bypass via short list_item fragment', () {
      final ctx = classifyExplorePricePageContext(
        sourceUrl: 'https://guide.example/cost-of-breast-augmentation-in-albania/',
        pageText:
            'Breast augmentation in Albania starts at roughly €2,500. '
            'Compared with Italy patients can save.',
      );
      expect(explorePageContextBlocksFragmentBypass(ctx), isTrue);
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ctx,
          rawEvidence: 'breast augmentation €2,500',
          rawProcedureText: 'breast augmentation',
          rawPriceText: '€2,500',
        ),
        isFalse,
      );
    });
  });

  group('broad SERP discovery', () {
    test('buildBroadProcedureDiscoveryQueries for Tirana breast', () {
      final qs = buildBroadProcedureDiscoveryQueries(
        city: 'Tiranë',
        procedure: 'breast augmentation',
        countryCode: 'AL',
        maxQueries: 6,
      );
      expect(qs, isNotEmpty);
      expect(qs.length, lessThanOrEqualTo(6));
      expect(
        qs.any((q) => q.toLowerCase().contains('tiran')),
        isTrue,
      );
      expect(
        qs.any((q) => q.toLowerCase().contains('breast')),
        isTrue,
      );
      expect(qs.any((q) => q.contains('site:')), isFalse);
    });

    test('SERP title is never clinic name', () {
      expect(
        resolveBroadSerpClinicCandidateName(
          'Breast Augmentation Tirana Prices',
          'conceptclinic.al',
        ),
        isNot(equals('Breast Augmentation Tirana Prices')),
      );
      expect(
        resolveBroadSerpClinicCandidateName(
          'Breast Augmentation Tirana - Prices and Clinics',
          'davinci.al',
        ).toLowerCase(),
        isNot(contains('breast augmentation tirana')),
      );
      final hostBrand = resolveBroadSerpClinicCandidateName(
        'Breast Augmentation Tirana Prices',
        'davinci.al',
      );
      expect(hostBrand.toLowerCase(), contains('davinci'));
    });
  });

  group('fill exhaustion helpers', () {
    test('under-target with pending work keeps fill alive', () {
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 3,
          uiVisibleTarget: 4,
          googleShownCount: 0,
          liveGoogleTarget: 2,
          hasPendingBackgroundWork: true,
          paused: false,
        ),
        isTrue,
      );
    });

    test('mix complete only at target or true exhaustion', () {
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 3,
          uiVisibleTarget: 4,
          paused: false,
          isPreviewFill: false,
          trulyExhausted: false,
        ),
        isFalse,
      );
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 3,
          uiVisibleTarget: 4,
          paused: false,
          isPreviewFill: false,
          trulyExhausted: true,
        ),
        isTrue,
      );
    });
  });

  group('cost-savings / foreign comparison pages', () {
    test('cost-savings Albania vs Italy URL is not clinic owned', () {
      final ctx = classifyExplorePricePageContext(
        sourceUrl:
            'https://tiranahealthclinic.com/cost-savings-albania-vs-italy',
        pageText: 'Lip Filler 150 – 300 EUR patients can save vs Italy',
        title: 'Cost Savings Albania vs Italy',
      );
      expect(
        ctx == ExplorePricePageContext.foreignPriceComparison ||
            ctx == ExplorePricePageContext.countryCostGuide ||
            ctx == ExplorePricePageContext.comparisonArticle,
        isTrue,
      );
      expect(
        exploreEvidenceIsClinicOwnedPrice(
          pageContext: ctx,
          rawEvidence: 'Lip Filler 150 – 300 EUR',
          rawProcedureText: 'Lip Filler',
          rawPriceText: '150 – 300 EUR',
        ),
        isFalse,
      );
    });
  });
}
