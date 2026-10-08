import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/openai_service.dart';

void main() {
  group('exploreFillShouldKeepTopUpAlive', () {
    test('2 Firestore + liveTarget 2 + google 0 keeps session alive', () {
      // Exact user-reported freeze: pricedFinal compared to liveGoogleTarget
      // used to yield 2 < 2 → false and detach the progress listener.
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 2,
          uiVisibleTarget: 4,
          googleShownCount: 0,
          liveGoogleTarget: 2,
          hasPendingBackgroundWork: true,
          paused: false,
        ),
        isTrue,
      );
    });

    test('does not keep alive when visible target already met', () {
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 4,
          uiVisibleTarget: 4,
          googleShownCount: 0,
          liveGoogleTarget: 2,
          hasPendingBackgroundWork: true,
          paused: false,
        ),
        isFalse,
      );
    });

    test('does not keep alive without pending background work', () {
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 2,
          uiVisibleTarget: 4,
          googleShownCount: 0,
          liveGoogleTarget: 2,
          hasPendingBackgroundWork: false,
          paused: false,
        ),
        isFalse,
      );
    });

    test('preview fills never keep shared key alive', () {
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 1,
          uiVisibleTarget: 4,
          googleShownCount: 0,
          liveGoogleTarget: 1,
          hasPendingBackgroundWork: true,
          paused: false,
          isPreviewFill: true,
        ),
        isFalse,
      );
    });

    test('live under target alone keeps session alive', () {
      expect(
        exploreFillShouldKeepTopUpAlive(
          pricedFinal: 3,
          uiVisibleTarget: 4,
          googleShownCount: 1,
          liveGoogleTarget: 2,
          hasPendingBackgroundWork: true,
          paused: false,
        ),
        isTrue,
      );
    });
  });

  group('exploreFillShouldMarkMixComplete', () {
    test('focused tab at 2 cards is NOT mix-complete', () {
      // Former bug: !isPreviewFill alone marked complete at pricedFinal=1–2.
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 2,
          uiVisibleTarget: 4,
          paused: false,
          isPreviewFill: false,
          trulyExhausted: false,
        ),
        isFalse,
      );
    });

    test('visible target reached marks complete', () {
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 4,
          uiVisibleTarget: 4,
          paused: false,
          isPreviewFill: false,
          trulyExhausted: false,
        ),
        isTrue,
      );
    });

    test('true exhaustion marks complete even under target', () {
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 2,
          uiVisibleTarget: 4,
          paused: false,
          isPreviewFill: false,
          trulyExhausted: true,
        ),
        isTrue,
      );
    });

    test('preview never marks shared focused key complete', () {
      expect(
        exploreFillShouldMarkMixComplete(
          pricedFinal: 1,
          uiVisibleTarget: 1,
          paused: false,
          isPreviewFill: true,
          trulyExhausted: true,
        ),
        isFalse,
      );
    });
  });

  group('filler discovery query waves', () {
    test('localized filler queries include brand cues', () {
      final qs = exploreLocalizedSearchQueries(
        procedure: 'dermal filler lips cheeks',
        city: 'Tiranë',
        pill: 'Fillers',
        countryCode: 'AL',
        maxQueries: 8,
      );
      expect(qs.length, greaterThanOrEqualTo(2));
      final blob = qs.join(' ').toLowerCase();
      expect(
        blob.contains('filler') ||
            blob.contains('juvederm') ||
            blob.contains('restylane') ||
            blob.contains('teosyal'),
        isTrue,
      );
    });

    test('bilingual pair stays bounded for wave 1', () {
      final pair = exploreBilingualSearchPair(
        procedure: 'dermal filler lips cheeks',
        city: 'Tiranë',
        pill: 'Fillers',
        countryCode: 'AL',
        maxPair: 2,
      );
      expect(pair.length, lessThanOrEqualTo(2));
      expect(pair, isNotEmpty);
    });
  });
}
