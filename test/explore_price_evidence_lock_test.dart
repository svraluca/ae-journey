import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_evidence.dart';
import 'package:glowpass/services/explore_price_evidence_lock.dart';
import 'package:glowpass/services/explore_procedure_relation.dart';

void main() {
  group('evidence lock', () {
    test('literal amount must exist in source HTML', () {
      expect(
        exploreAmountLiterallyInSource(
          '<p>Lip Filler — Starting AED 990</p>',
          990,
        ),
        isTrue,
      );
      expect(
        exploreAmountLiterallyInSource(
          '<p>Breast Augmentation AED 30,000</p>',
          30000,
        ),
        isTrue,
      );
      expect(
        exploreAmountLiterallyInSource('<p>No price here</p>', 990),
        isFalse,
      );
    });

    test('accepts exact lip filler starting price', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'Lip Filler',
        rawPriceText: 'Starting AED 990',
        priceMin: 990,
        priceMax: 990,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/fillers',
        extractionMethod: PriceExtractionMethod.listItem,
        rawEvidence: 'Lip Filler — Starting AED 990',
        confidence: 0.9,
      );
      final lock = lockExplorePriceEvidence(
        candidate: row,
        procedure: 'lip filler',
        sourceHtmlOrText: '<p>Lip Filler — Starting AED 990</p>',
      );
      expect(lock.accepted, isTrue);
      expect(lock.relation!.relation, ProcedureRelation.variant);
    });

    test('rejects bundle breast aug + lift', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'Breast Augmentation + Breast Lift',
        rawPriceText: 'AED 45,000',
        priceMin: 45000,
        priceMax: 45000,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/packages',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence: 'Breast Augmentation + Breast Lift AED 45,000',
        confidence: 0.9,
      );
      final lock = lockExplorePriceEvidence(
        candidate: row,
        procedure: 'breast augmentation',
        sourceHtmlOrText:
            '<p>Breast Augmentation + Breast Lift AED 45,000</p>',
      );
      expect(lock.accepted, isFalse);
      expect(lock.relation?.relation, ProcedureRelation.bundle);
    });

    test('rejects market average filler copy', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'Fillers',
        rawPriceText: 'AED 1,000–2,000',
        priceMin: 1000,
        priceMax: 2000,
        currency: 'AED',
        sourceUrl: 'https://clinic.example/fillers-cost-in-dubai',
        extractionMethod: PriceExtractionMethod.textProximity,
        rawEvidence:
            'Fillers in Dubai generally cost AED 1,000–2,000 per syringe',
        confidence: 0.5,
      );
      final lock = lockExplorePriceEvidence(
        candidate: row,
        procedure: 'lip filler',
        sourceHtmlOrText:
            '<p>Fillers in Dubai generally cost AED 1,000–2,000</p>',
      );
      expect(lock.accepted, isFalse);
      expect(
        lock.relation?.relation,
        ProcedureRelation.marketInformation,
      );
    });

    test('accepts Arabic clinic quote with English slug label', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'rhinoplasty',
        rawPriceText:
            'تبدأ تكلفة عملية تجميل الأنف في دبي من 30,000 درهم',
        priceMin: 30000,
        priceMax: 30000,
        currency: 'AED',
        sourceUrl: 'https://novomed.com/rhinoplasty',
        extractionMethod: PriceExtractionMethod.textProximity,
        rawEvidence:
            'تبدأ تكلفة عملية تجميل الأنف في دبي من 30,000 درهم ولكن يمكن أن تختلف',
        confidence: 0.8,
      );
      final lock = lockExplorePriceEvidence(
        candidate: row,
        procedure: 'rhinoplasty nose job',
        sourceHtmlOrText:
            '<p>تبدأ تكلفة عملية تجميل الأنف في دبي من 30,000 درهم</p>',
      );
      expect(lock.accepted, isTrue);
    });

    test('rejects Arabic average-cost market table label', () {
      const row = ExtractedPriceEvidence(
        rawProcedureText: 'متوسط تكلفة تكبير الثدي في دبي · تكبير الثدي القياسي',
        rawPriceText: '15,000 – 30,000 درهم',
        priceMin: 15000,
        priceMax: 30000,
        currency: 'AED',
        sourceUrl: 'https://vowclinic.com/ar/cost',
        extractionMethod: PriceExtractionMethod.htmlTable,
        rawEvidence:
            'متوسط تكلفة تكبير الثدي في دبي · تكبير الثدي القياسي 15,000 – 30,000 درهم',
        confidence: 0.8,
      );
      final lock = lockExplorePriceEvidence(
        candidate: row,
        procedure: 'breast augmentation',
        sourceHtmlOrText:
            '<p>متوسط تكلفة تكبير الثدي في دبي 15,000 – 30,000 درهم</p>',
      );
      expect(lock.accepted, isFalse);
      expect(
        lock.relation?.relation,
        ProcedureRelation.marketInformation,
      );
    });
  });
}
