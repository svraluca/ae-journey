import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_procedure_family.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_url_discovery.dart';

void main() {
  group('procedureRelation classification', () {
    test('breast augmentation is exact', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'breast augmentation',
        label: 'Breast augmentation',
        evidence: 'Breast augmentation from AED 25000',
        sourceUrl: 'https://clinic.example/breast-augmentation',
      );
      expect(r.relation, ProcedureRelation.exact);
      expect(r.eligibleForFromPrice, isTrue);
    });

    test('breast augmentation + lift is bundle', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'breast augmentation',
        label: 'Breast augmentation + breast lift',
        evidence: 'Package from AED 45000',
        sourceUrl: 'https://clinic.example/packages/breast',
      );
      expect(r.relation, ProcedureRelation.bundle);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('breast implant removal is different_procedure', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'breast augmentation',
        label: 'Breast implant removal',
        evidence: 'Explant from AED 18000',
        sourceUrl: 'https://clinic.example/breast-implant-removal',
      );
      expect(r.relation, ProcedureRelation.differentProcedure);
    });

    test('breast reduction / lift alone are different_procedure', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Breast reduction',
          sourceUrl: 'https://clinic.example/breast-reduction',
        ).relation,
        ProcedureRelation.differentProcedure,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Mastopexy / breast lift',
          sourceUrl: 'https://clinic.example/breast-lift',
        ).relation,
        ProcedureRelation.differentProcedure,
      );
    });

    test('lip filler 1ml is variant', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: 'Lip filler 1ml',
        evidence: 'Lip filler 1ml AED 990',
        sourceUrl: 'https://clinic.example/fillers',
      );
      expect(r.relation, ProcedureRelation.variant);
      expect(r.eligibleForFromPrice, isTrue);
    });

    test('Fillmed Lips brand row is filler FROM (not ambiguous)', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: 'Fillmed Lips',
        evidence: 'Fillmed Lips 250 Euro',
        sourceUrl: 'https://olariuclinics.ro/tarife/',
      );
      expect(r.eligibleForFromPrice, isTrue);
      expect(
        r.relation,
        anyOf(ProcedureRelation.exact, ProcedureRelation.variant),
      );
      expect(r.reason, isNot(contains('unmatched_procedure_signal')));
    });

    test('face tox + syringes filler is a bundle, not filler FROM', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: 'Full upper face tox + 2 syringes filler',
        evidence: r'$ 1500',
        sourceUrl: 'https://clinic.example/pricing',
      );
      expect(r.relation, ProcedureRelation.bundle);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('lip flip is botox, not a filler FROM', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: 'Lip Flip Standalone Treatment Session',
        evidence: r'$ 100',
        sourceUrl: 'https://lovethenuyou.com/pricing',
        pageHasFamilyWitness: true,
      );
      expect(r.eligibleForFromPrice, isFalse);
      expect(
        looksLikeInheritableAreaOnlyLabel(
          label: 'Lip Flip Standalone Treatment Session',
          requestedFamily: 'filler',
        ),
        isFalse,
      );
    });

    test('1 syringe filler is a filler variant', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: r'$700 1 syringe filler',
        evidence: r'$700 1 syringe filler',
        sourceUrl: 'https://lovethenuyou.com/pricing',
      );
      expect(r.eligibleForFromPrice, isTrue);
    });

    test('PEEL ADD ON is add_on, not peel FROM', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'chemical peel facial',
        label: 'PEEL ADD ON',
        evidence: r'$200',
        sourceUrl: 'https://clinic.example/pricing',
      );
      expect(r.relation, ProcedureRelation.addOn);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('typical sessions ranging is market copy even with a dollar window', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'dermal filler lips cheeks',
        label: 'filler',
        evidence:
            'Prices vary depending on the type and amount of filler used, '
            'with typical sessions ranging from \$500 to \$800 per syringe',
        sourceUrl: 'https://clinic.example/lips-fillers',
        clinicOwnQuoted: true,
      );
      expect(r.relation, ProcedureRelation.marketInformation);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('filler + botox package is bundle', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'lip filler',
        label: '1ml filler + Botox 3 areas',
        evidence: 'Combo package AED 2500',
        sourceUrl: 'https://clinic.example/packages',
      );
      expect(r.relation, ProcedureRelation.bundle);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('botox per unit is variant', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'Botox',
        evidence: 'AED 42 per unit',
        sourceUrl: 'https://clinic.example/botox',
      );
      expect(r.relation, ProcedureRelation.variant);
      expect(r.eligibleForFromPrice, isTrue);
    });

    test('botox + filler package is bundle', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'Botox + filler package',
        evidence: 'Botox and filler package AED 3500',
        sourceUrl: 'https://clinic.example/packages/botox-filler',
      );
      expect(r.relation, ProcedureRelation.bundle);
    });

    test('finance URL and named other-family row are not rhinoplasty', () {
      final finance = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Nose Reshaping (Rhinoplasty)',
        evidence: 'Nose Reshaping (Rhinoplasty) £6,625',
        sourceUrl: 'https://www.harleymedical.co.uk/nose-job-on-finance',
        clinicOwnQuoted: true,
      );
      expect(finance.eligibleForFromPrice, isFalse);
      expect(finance.reason, 'treatment_finance_page');

      final breastOnRhinoUrl = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Breast Surgery',
        evidence: 'Breast Surgery £5,995',
        sourceUrl: 'https://www.harleymedical.co.uk/nose-job-cost',
      );
      expect(breastOnRhinoUrl.relation, ProcedureRelation.differentProcedure);
      expect(breastOnRhinoUrl.eligibleForFromPrice, isFalse);

      final browOnRhinoUrl = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Brow Lift',
        evidence: 'Brow Lift £6,300',
        sourceUrl: 'https://www.harleymedical.co.uk/nose-job-cost',
      );
      expect(browOnRhinoUrl.relation, ProcedureRelation.differentProcedure);
      expect(browOnRhinoUrl.eligibleForFromPrice, isFalse);
    });

    test('complete pricing guide URL is market_information', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Ethnic Rhinoplasty',
        evidence: 'Ethnic rhinoplasty £7,000–£15,000',
        sourceUrl:
            'https://ardakucukguven.com/rhinoplasty-cost-in-london-complete-pricing-guide/',
        clinicOwnQuoted: true,
      );
      expect(r.relation, ProcedureRelation.marketInformation);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('market average copy is market_information', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Rhinoplasty',
        evidence:
            'The average cost of rhinoplasty in Dubai is typically AED 20,000. '
            'Common prices across clinics generally range from 15,000 to 30,000.',
        sourceUrl: 'https://clinic.example/plastic-surgery-cost-in-dubai/',
      );
      expect(r.relation, ProcedureRelation.marketInformation);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('Face Clinic targeted add-on is not a Botox FROM', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'botox',
        evidence:
            'Targeted Areas (Bunny Lines, Chin) £90 each when added to another '
            'anti-wrinkle treatment, or £180 as a standalone treatment',
        sourceUrl: 'https://facecliniclondon.com/prices',
      );
      expect(r.relation, ProcedureRelation.addOn);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('tip rhinoplasty is not the generic FROM', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Tip rhinoplasty',
        evidence: 'Tip rhinoplasty from £4,900',
        sourceUrl: 'https://londonprivatehospital.uk/treatments/rhinoplasty/',
      );
      expect(r.relation, ProcedureRelation.differentProcedure);
      expect(r.eligibleForFromPrice, isFalse);
    });

    test('Forma RF copy is not a Botox zone inherit', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'Forma',
        evidence:
            'Forma starts at \$300 for a single lower-face session, '
            'with package and area-based pricing for full face.',
        sourceUrl: 'https://www.miamiskinspa.com/services/forma',
      );
      expect(r.eligibleForFromPrice, isFalse);
      expect(
        exploreUrlConflictsWithProcedure(
          'https://www.miamiskinspa.com/services/forma',
          'Botox anti-wrinkle injection',
        ),
        isTrue,
      );
      expect(
        matchRawProcedureLabel(
          'Forma',
          requestedProcedure: 'Botox anti-wrinkle injection',
        ).rejectReason,
        'wrong_family_energy_device',
      );
      expect(
        looksLikeInheritableAreaOnlyLabel(
          label: '1 Area',
          requestedFamily: 'botox',
        ),
        isTrue,
      );
      expect(
        looksLikeInheritableAreaOnlyLabel(
          label: 'Forma',
          requestedFamily: 'botox',
        ),
        isFalse,
      );
    });

    test('filler dissolving and masseter are not filler FROM', () {
      expect(
        matchRawProcedureLabel(
          'London’s Expert Filler Dissolving Clinic',
          requestedProcedure: 'dermal filler lips cheeks',
        ).rejectReason,
        'wrong_family_hyaluronidase',
      );
      expect(
        matchRawProcedureLabel(
          'Masseter teeth grinding (bruxism) · jawline slimming',
          requestedProcedure: 'dermal filler lips cheeks',
        ).rejectReason,
        'wrong_family_masseter_not_filler',
      );
    });

    test('1-area Botox on a mixed botox-fillers URL stays eligible', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'Botox (1 Area)',
        evidence: 'Botox (1 Area) £175',
        sourceUrl:
            'https://sw11clinic-clapham.co.uk/aesthetic-medicine-in-clapham-expert-botox-fillers-skin-treatments/',
      );
      expect(r.eligibleForFromPrice, isTrue);
      expect(r.relation, isNot(ProcedureRelation.bundle));
    });

    test('closed rhinoplasty stays eligible', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'rhinoplasty nose job',
        label: 'Closed Rhinoplasty',
        evidence: 'Closed Rhinoplasty from £6,900',
        sourceUrl: 'https://londonprivatehospital.uk/treatments/rhinoplasty/',
      );
      expect(r.eligibleForFromPrice, isTrue);
    });

    test('official /prices outranks a treatment landing', () {
      expect(
        looksLikeOfficialPriceListUrl('https://facecliniclondon.com/prices'),
        isTrue,
      );
      expect(
        looksLikeOfficialPriceListUrl(
          'https://skinlogicaesthetics.co.uk/price-list/',
        ),
        isTrue,
      );
      expect(
        looksLikeOfficialPriceListUrl(
          'https://skinlogicaesthetics.co.uk/cosmelan-peel/',
        ),
        isFalse,
      );
      final menu = procedureRelationUrlScore(
        sourceUrl: 'https://skinlogicaesthetics.co.uk/price-list/',
        procedure: 'chemical peel facial',
      );
      final landing = procedureRelationUrlScore(
        sourceUrl: 'https://skinlogicaesthetics.co.uk/cosmelan-peel/',
        procedure: 'chemical peel facial',
      );
      expect(menu, greaterThan(landing));
      final guide = procedureRelationUrlScore(
        sourceUrl: 'https://www.cadoganclinic.com/price-guide/',
        procedure: 'rhinoplasty nose job',
      );
      final maleLanding = procedureRelationUrlScore(
        sourceUrl: 'https://www.cadoganclinic.com/for-men/rhinoplasty-for-men/',
        procedure: 'rhinoplasty nose job',
      );
      final staleCost = procedureRelationUrlScore(
        sourceUrl: 'https://www.cadoganclinic.com/rhinoplasty-cost',
        procedure: 'rhinoplasty nose job',
      );
      expect(guide, greaterThan(maleLanding));
      expect(guide, greaterThan(staleCost));
      expect(
        looksLikeOfficialPriceListUrl('https://drmarktam.co.uk/fees/'),
        isTrue,
      );
      expect(
        procedureRelationUrlScore(
          sourceUrl: 'https://drmarktam.co.uk/fees/',
          procedure: 'hair transplant FUE',
        ),
        greaterThan(
          procedureRelationUrlScore(
            sourceUrl: 'https://drmarktam.co.uk/fue-hair-transplant/',
            procedure: 'hair transplant FUE',
          ),
        ),
      );
    });
  });

  group('selectEvidence respects relation before price', () {
    test('exact breast beats cheaper lift/bundle', () {
      const exact = ExtractedPriceEvidence(
        rawProcedureText: 'Breast augmentation',
        rawPriceText: 'from AED 28000',
        priceMin: 28000,
        priceMax: 28000,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/breast-augmentation',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Breast augmentation from AED 28000',
        confidence: 0.9,
      );
      const cheaperBundle = ExtractedPriceEvidence(
        rawProcedureText: 'Breast augmentation + breast lift',
        rawPriceText: 'from AED 22000',
        priceMin: 22000,
        priceMax: 22000,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/packages/breast-combo',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Breast augmentation + breast lift from AED 22000',
        confidence: 0.95,
      );
      const liftOnly = ExtractedPriceEvidence(
        rawProcedureText: 'Breast lift',
        rawPriceText: 'from AED 15000',
        priceMin: 15000,
        priceMax: 15000,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/breast-lift',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Breast lift from AED 15000',
        confidence: 0.95,
      );
      final picked = selectEvidenceForProcedure(
        rows: [cheaperBundle, liftOnly, exact],
        procedure: 'breast augmentation',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 28000);
      expect(picked.rawProcedureText.toLowerCase(), contains('augmentation'));
    });

    test('botox per-unit beats cheaper filler combo on same page', () {
      const perUnit = ExtractedPriceEvidence(
        rawProcedureText: 'Botox',
        rawPriceText: 'AED 42/unit',
        priceMin: 42,
        priceMax: 42,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/cosmetic-injectables/botox',
        extractionMethod: PriceExtractionMethod.listItem,
        rawEvidence: 'Botox starts from AED 42 per unit',
        confidence: 0.9,
        priceType: PriceType.perUnit,
      );
      const combo = ExtractedPriceEvidence(
        rawProcedureText: 'Botox + filler package',
        rawPriceText: 'AED 1999',
        priceMin: 1999,
        priceMax: 1999,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/packages/botox-filler',
        extractionMethod: PriceExtractionMethod.listItem,
        rawEvidence: 'Botox + filler package AED 1999',
        confidence: 0.99,
      );
      final picked = selectEvidenceForProcedure(
        rows: [combo, perUnit],
        procedure: 'Botox anti-wrinkle injection',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 42);
    });

    test('hair filler / hair mesotherapy are not facial dermal filler', () {
      const hairFiller = ExtractedPriceEvidence(
        rawProcedureText: 'Hair Filler',
        rawPriceText: 'from 163 61 €',
        priceMin: 163.61,
        priceMax: 163.61,
        currency: 'EUR',
        sourceUrl: 'https://studio24.bg/en/dr-kalyasheva-s686',
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: 'Hair Filler · from 163 61 €',
        confidence: 0.95,
        priceType: PriceType.from,
      );
      const hairMeso = ExtractedPriceEvidence(
        rawProcedureText: 'Hair mesotherapy',
        rawPriceText: 'from 40 90 €',
        priceMin: 40.9,
        priceMax: 40.9,
        currency: 'EUR',
        sourceUrl: 'https://studio24.bg/en/dr-kalyasheva-s686',
        extractionMethod: PriceExtractionMethod.wooCommerce,
        rawEvidence: 'Hair mesotherapy · from 40 90 €',
        confidence: 0.95,
        priceType: PriceType.from,
      );
      final picked = selectEvidenceForProcedure(
        rows: [hairFiller, hairMeso],
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNull);
    });

    test('1 syringe filler beats cheaper lip flip on the same menu', () {
      const lipFlip = ExtractedPriceEvidence(
        rawProcedureText: 'Lip Flip Standalone Treatment Session',
        rawPriceText: r'$ 100',
        priceMin: 100,
        priceMax: 100,
        currency: 'USD',
        sourceUrl: 'https://lovethenuyou.com/pricing',
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: r'Lip Flip Standalone Treatment Session $ 100',
        confidence: 0.9,
      );
      const syringe = ExtractedPriceEvidence(
        rawProcedureText: r'$700 1 syringe filler',
        rawPriceText: r'$700',
        priceMin: 700,
        priceMax: 700,
        currency: 'USD',
        sourceUrl: 'https://lovethenuyou.com/pricing',
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: r'$700 1 syringe filler',
        confidence: 0.9,
      );
      const bundle = ExtractedPriceEvidence(
        rawProcedureText: 'Full upper face tox + 2 syringes filler',
        rawPriceText: r'$1500',
        priceMin: 1500,
        priceMax: 1500,
        currency: 'USD',
        sourceUrl: 'https://lovethenuyou.com/pricing',
        extractionMethod: PriceExtractionMethod.domBlock,
        rawEvidence: r'Full upper face tox + 2 syringes filler $1500',
        confidence: 0.95,
      );
      final picked = selectEvidenceForProcedure(
        rows: [lipFlip, bundle, syringe],
        procedure: 'dermal filler lips cheeks',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 700);
      expect(picked.rawProcedureText.toLowerCase(), contains('syringe'));
    });

    test('URL with extra procedure names loses to dedicated treatment URL', () {
      const dedicated = ExtractedPriceEvidence(
        rawProcedureText: 'Lip filler',
        rawPriceText: 'from AED 990',
        priceMin: 990,
        priceMax: 990,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/dermal-fillers/lip-filler',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Lip filler from AED 990',
        confidence: 0.85,
      );
      const packageUrl = ExtractedPriceEvidence(
        rawProcedureText: 'Lip filler',
        rawPriceText: 'from AED 800',
        priceMin: 800,
        priceMax: 800,
        currency: 'AED',
        sourceUrl:
            'https://clinic.example/packages/botox-filler-laser-combo',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Lip filler from AED 800',
        confidence: 0.95,
      );
      final picked = selectEvidenceForProcedure(
        rows: [packageUrl, dedicated],
        procedure: 'lip filler',
      );
      expect(picked, isNotNull);
      expect(picked!.priceMin, 990);
      expect(picked.sourceUrl, contains('lip-filler'));
    });
  });

  group('anatomy never establishes procedure family', () {
    test('Botox forehead / 1 area / brands are eligible', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Botox forehead',
          evidence: 'Botox forehead \$250',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Botox 1 area',
          evidence: 'Botox 1 area \$250',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Dysport glabella',
          evidence: 'Dysport glabella \$200',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Xeomin forehead',
          evidence: 'Xeomin forehead \$220',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: 'Botox masseter',
          evidence: 'Botox masseter \$350',
        ).eligibleForFromPrice,
        isTrue,
      );
    });

    test('Endolift JawLine can never be a Botox price', () {
      final r = classifyProcedureRelation(
        requestedProcedure: 'Botox anti-wrinkle injection',
        label: 'Endolift JawLine (Under Chin)',
        evidence: 'Endolift JawLine (Under Chin) \$499',
        sourceUrl: 'https://clinic.example/endolift-jawline',
      );
      expect(r.eligibleForFromPrice, isFalse);
      expect(r.relation, ProcedureRelation.differentProcedure);
      expect(
        r.reason.contains('endolift') || r.reason.contains('energy_device'),
        isTrue,
      );
    });

    test('competing families on anatomy labels stay different', () {
      for (final label in [
        'HIFU jawline',
        'Jawline filler',
        'Chin filler',
        'Morpheus jawline',
      ]) {
        final r = classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: label,
          evidence: '$label \$300',
        );
        expect(r.eligibleForFromPrice, isFalse, reason: label);
        expect(r.relation, ProcedureRelation.differentProcedure, reason: label);
      }
    });

    test('bare anatomy / injectables stay ambiguous without Botox witness', () {
      for (final label in ['Focus Frown', 'Injectables', 'Jawline', 'Chin']) {
        final r = classifyProcedureRelation(
          requestedProcedure: 'Botox',
          label: label,
          evidence: '$label \$199',
        );
        expect(r.eligibleForFromPrice, isFalse, reason: label);
        expect(
          r.relation,
          anyOf(
            ProcedureRelation.ambiguous,
            ProcedureRelation.differentProcedure,
          ),
          reason: label,
        );
      }
    });

    test('parent Botox Pricing + Frown Lines inherits; Injectables does not', () {
      final inherited = classifyProcedureRelation(
        requestedProcedure: 'Botox',
        label: 'Frown Lines',
        evidence: 'Frown Lines \$199',
        parentHeading: 'Botox Pricing',
      );
      expect(inherited.eligibleForFromPrice, isTrue);
      expect(inherited.relation, ProcedureRelation.variant);

      final generic = classifyProcedureRelation(
        requestedProcedure: 'Botox',
        label: 'Frown Lines',
        evidence: 'Frown Lines \$199',
        parentHeading: 'Injectables',
      );
      expect(generic.eligibleForFromPrice, isFalse);
    });

    test('other families: identity first, then area', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'lip filler',
          label: 'Lip filler',
          evidence: 'Lip filler \$400',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'lip filler',
          label: 'Botox jawline',
          evidence: 'Botox jawline \$350',
        ).relation,
        ProcedureRelation.differentProcedure,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'laser hair removal',
          label: 'Laser hair removal underarm',
          evidence: 'Laser hair removal underarm \$80',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'laser hair removal',
          label: 'Botox underarm',
          evidence: 'Botox underarm \$200',
        ).eligibleForFromPrice,
        isFalse,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'chemical peel',
          label: 'Chemical peel',
          evidence: 'Chemical peel \$150',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'chemical peel',
          label: 'Hydrafacial',
          evidence: 'Hydrafacial \$180',
        ).eligibleForFromPrice,
        isFalse,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'rhinoplasty',
          label: 'Primary rhinoplasty',
          evidence: 'Primary rhinoplasty £6000',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'rhinoplasty',
          label: 'Non-surgical rhinoplasty filler',
          evidence: 'Non-surgical rhinoplasty filler £800',
        ).eligibleForFromPrice,
        isFalse,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Breast implants',
          evidence: 'Breast implants £5000',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Breast reduction',
          evidence: 'Breast reduction £4500',
        ).relation,
        ProcedureRelation.differentProcedure,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'hair transplant FUE',
          label: 'FUE hair transplant',
          evidence: 'FUE hair transplant £3000',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'hair transplant FUE',
          label: 'PRP hair',
          evidence: 'PRP hair £250',
        ).eligibleForFromPrice,
        isFalse,
      );
    });

    test('Chisinau Romanian and Russian Botox labels are eligible', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox anti-wrinkle injection',
          label: 'Toxina botulinică 1 zonă facial',
          evidence: 'Toxina botulinică 1 zonă facial 70 EUR',
          sourceUrl: 'https://www.sancos.md/lista-de-preturi',
        ).eligibleForFromPrice,
        isTrue,
      );
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'Botox anti-wrinkle injection',
          label: 'Ботокс лица (одна зона)',
          evidence: 'Ботокс лица (одна зона) 70 EUR',
          sourceUrl: 'https://www.sancos.md/ru/lista-de-preturi',
        ).eligibleForFromPrice,
        isTrue,
      );
    });

    test('chin/cheek silicone implant is not breast augmentation', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Mărirea bărbiei, pomeților, nasului cu implant siliconic',
          evidence: 'Mărirea bărbiei, pomeților, nasului cu implant siliconic 24.800 MDL',
          sourceUrl: 'https://anatolietaran.com/preturi',
        ).eligibleForFromPrice,
        isFalse,
      );
      expect(
        matchRawProcedureLabel(
          'Mărirea bărbiei, pomeților, nasului cu implant siliconic',
          requestedProcedure: 'breast augmentation',
        ).accepted,
        isFalse,
      );
    });

    test('areola correction is not the breast augmentation FROM', () {
      expect(
        classifyProcedureRelation(
          requestedProcedure: 'breast augmentation',
          label: 'Correction of areolas (in case of breast augmentation)',
          evidence: 'Correction of areolas (in case of breast augmentation) 800 €',
          sourceUrl: 'https://www.chirurgie-estetica.md/en/prices/',
        ).eligibleForFromPrice,
        isFalse,
      );
    });
  });
}
