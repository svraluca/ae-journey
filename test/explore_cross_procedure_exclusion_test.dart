import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_comparison_session.dart';
import 'package:glowpass/services/explore_html_price_extractor.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_verification.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/openai_service.dart';

OpenAIClinic _clinic({
  required String name,
  required String host,
  required String procedureLabel,
  required double price,
  String family = '',
  String relation = '',
  String urlPath = '/pricing',
}) {
  final url = 'https://$host$urlPath';
  return OpenAIClinic(
    rank: 1,
    name: name,
    area: '$host · src:$url',
    distanceMi: 1,
    rating: 4.6,
    reviews: 80,
    priceGbp: price.round(),
    priceMin: price,
    priceMax: price,
    priceLabel: '\$${price.round()}',
    currency: 'USD',
    brand: procedureLabel,
    badge: '',
    badgeVariant: 'mid',
    coord: const OpenAICoord(25.76, -80.19),
    hasProcedure: true,
    pricePending: false,
    currencyConfirmed: true,
    priceSourceUrl: url,
    priceEvidenceText: '$procedureLabel \$${price.round()}',
    priceVerificationStatus: PriceVerificationStatus.officialWebsite,
    rawProcedureText: procedureLabel,
    rawPriceText: '\$${price.round()}',
    extractionMethod: 'html_table',
    sourceType: 'official_clinic',
    procedureFamily: family,
    procedureRelation: relation,
  );
}

void main() {
  final miamiPeel = _clinic(
    name: 'Miami Skin Spa',
    host: 'miamiskinspa.com',
    procedureLabel: 'Chemical peel',
    price: 350,
    family: 'peel',
    relation: 'exact',
  );
  final miamiBotox = _clinic(
    name: 'Miami Skin Spa',
    host: 'miamiskinspa.com',
    procedureLabel: 'Botox',
    price: 13,
    family: 'botox',
    relation: 'variant',
  );
  final clinicAPeel = _clinic(
    name: 'Clinic A',
    host: 'clinica.example',
    procedureLabel: 'Chemical peel',
    price: 280,
    family: 'peel',
    relation: 'exact',
  );
  final clinicABotox = _clinic(
    name: 'Clinic A',
    host: 'clinica.example',
    procedureLabel: 'Botox',
    price: 12,
    family: 'botox',
    relation: 'variant',
  );
  final clinicBFiller = _clinic(
    name: 'Clinic B',
    host: 'clinicb.example',
    procedureLabel: 'Lip filler',
    price: 450,
    family: 'filler',
    relation: 'exact',
  );
  final clinicBBotox = _clinic(
    name: 'Clinic B',
    host: 'clinicb.example',
    procedureLabel: 'Botox',
    price: 11,
    family: 'botox',
    relation: 'variant',
  );

  group('procedure-scoped discovery exclusion', () {
    test('Peels record does not exclude Miami Skin Spa from Botox discovery', () {
      final siblingKeys = exploreClinicIdentityKeys(miamiPeel);
      expect(siblingKeys, contains('host:miamiskinspa.com'));

      final botoxExclusion = exploreCurrentProcedureExclusionKeys(
        shownKeys: const [],
        lastShownKeys: const [],
        poolKeys: const [],
      );
      expect(botoxExclusion, isEmpty);
      expect(
        exploreClinicBlockedFromCurrentProcedureDiscovery(
          miamiPeel,
          currentProcedureExclusionKeys: botoxExclusion,
        ),
        isFalse,
      );
      expect(
        exploreClinicBlockedFromCurrentProcedureDiscovery(
          miamiBotox,
          currentProcedureExclusionKeys: botoxExclusion,
        ),
        isFalse,
      );

      // Old bug: mixing sibling (Peels) keys into Botox exclusion.
      final wronglyUnioned = exploreCurrentProcedureExclusionKeys(
        shownKeys: const [],
        lastShownKeys: const [],
        poolKeys: siblingKeys,
      );
      expect(
        exploreClinicBlockedFromCurrentProcedureDiscovery(
          miamiBotox,
          currentProcedureExclusionKeys: wronglyUnioned,
        ),
        isTrue,
      );
    });

    test('Clinic A Peels-then-Botox remains Botox-discovery eligible', () {
      final peelKeys = exploreClinicIdentityKeys(clinicAPeel);
      final botoxExclusion = exploreCurrentProcedureExclusionKeys();
      expect(
        exploreClinicHitsKeys(clinicABotox, botoxExclusion),
        isFalse,
      );
      expect(
        exploreClinicHitsKeys(clinicABotox, peelKeys),
        isTrue,
        reason: 'same clinic identity, different procedure — peel keys '
            'must not be fed into Botox discovery exclusion',
      );
    });

    test('Clinic B Fillers-then-Botox remains Botox-discovery eligible', () {
      final fillerKeys = exploreClinicIdentityKeys(clinicBFiller);
      final botoxExclusion = exploreCurrentProcedureExclusionKeys();
      expect(
        exploreClinicHitsKeys(clinicBBotox, botoxExclusion),
        isFalse,
      );
      expect(exploreClinicHitsKeys(clinicBBotox, fillerKeys), isTrue);
    });

    test('same Botox clinic already shown on Botox tab is excluded', () {
      final shown = exploreClinicIdentityKeys(miamiBotox);
      final exclusion = exploreCurrentProcedureExclusionKeys(
        shownKeys: shown,
      );
      expect(
        exploreClinicBlockedFromCurrentProcedureDiscovery(
          miamiBotox,
          currentProcedureExclusionKeys: exclusion,
        ),
        isTrue,
      );
    });
  });

  group('clinic + family opportunity identity', () {
    test('same host is independent per procedure family', () {
      final peelKey = exploreClinicProcedureOpportunityKey(
        miamiPeel,
        procedure: 'chemical peel',
      );
      final botoxKey = exploreClinicProcedureOpportunityKey(
        miamiBotox,
        procedure: 'Botox',
      );
      expect(peelKey, 'host:miamiskinspa.com|peel');
      expect(botoxKey, 'host:miamiskinspa.com|botox');
      expect(peelKey, isNot(botoxKey));
    });

    test('two Botox rows for the same clinic still collide', () {
      final a = exploreClinicProcedureOpportunityKey(
        miamiBotox,
        procedure: 'Botox',
      );
      final b = exploreClinicProcedureOpportunityKey(
        miamiBotox,
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(a, b);
    });

    test('All tab may show the same clinic on Peels and Botox', () {
      final used = <String>{
        exploreAllTabSlotOpportunityKey(miamiPeel, pill: 'Peels'),
      };
      expect(
        used.contains(
          exploreAllTabSlotOpportunityKey(miamiBotox, pill: 'Botox'),
        ),
        isFalse,
      );
      expect(
        used.contains(
          exploreAllTabSlotOpportunityKey(miamiPeel, pill: 'Peels'),
        ),
        isTrue,
      );
    });
  });

  group('Miami Skin Spa multi-service pricing page', () {
    const html = '''
      <table>
        <tr><td>VI Chemical Peels</td><td>\$350</td></tr>
        <tr><td>Dysport and Xeomin</td><td>start at \$13 per unit</td></tr>
      </table>
    ''';

    test('Peels still extracts \$350 independently of Botox', () {
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://miamiskinspa.com/pricing',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'chemical peel',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 350);
      expect(picked.currency, 'USD');
      expect(picked.procedureFamily, 'peel');
    });

    test('Botox extracts Dysport/Xeomin \$13 per unit as variant', () {
      final rows = extractPriceEvidence(
        html: html,
        sourceUrl: 'https://miamiskinspa.com/pricing',
      );
      final picked = selectEvidenceForProcedure(
        rows: rows,
        procedure: 'Botox',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 13);
      expect(picked.currency, 'USD');
      expect(picked.priceType, PriceType.perUnit);
      expect(picked.procedureFamily, 'botox');

      final relation = classifyProcedureRelation(
        requestedProcedure: 'Botox',
        label: picked.rawProcedureText,
        evidence: '${picked.rawPriceText}\n${picked.rawEvidence}',
        sourceUrl: picked.sourceUrl,
      );
      expect(relation.relation, ProcedureRelation.variant);
      expect(relation.logToken, 'variant');
      expect(relation.eligibleForFromPrice, isTrue);
    });
  });
}
