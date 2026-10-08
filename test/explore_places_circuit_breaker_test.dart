import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/google_places_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    GooglePlacesService.resetQuotaCircuitBreaker();
    // Drain any stuck permits from failed assertions.
    while (GooglePlacesService.inFlightHttpForTest > 0) {
      GooglePlacesService.releasePlacesHttpPermit();
    }
  });

  test('Places 429 trips circuit breaker and skips further calls', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        '{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}',
        429,
        headers: {'content-type': 'application/json'},
      );
    });
    final places = GooglePlacesService(client: client, apiKey: 'test-key');
    expect(GooglePlacesService.quotaCircuitOpen, isFalse);

    final first = await places.lookupClinic(
      clinicName: 'Cronos Med',
      city: 'Timisoara',
    );
    expect(first, isNull);
    expect(GooglePlacesService.quotaCircuitOpen, isTrue);
    expect(calls, 1);

    final second = await places.lookupClinic(
      clinicName: 'Olariuclinics',
      city: 'Timisoara',
    );
    expect(second, isNull);
    // Circuit open — no second HTTP call.
    expect(calls, 1);

    final search = await places.searchText(
      query: 'botox clinic Timisoara',
      city: 'Timisoara',
    );
    expect(search, isEmpty);
    expect(calls, 1);
  });

  test('after breaker opens only in-flight Places calls may finish', () async {
    var calls = 0;
    final started = <Completer<void>>[];
    final client = MockClient((request) async {
      final n = ++calls;
      final gate = Completer<void>();
      started.add(gate);
      await gate.future;
      if (n == 1) {
        return http.Response(
          '{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}',
          429,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '{"places":[{"id":"places/p2","displayName":{"text":"Clinic B"},'
        '"formattedAddress":"Tm","rating":4.5,"userRatingCount":10,'
        '"location":{"latitude":45.7,"longitude":21.2},"types":["spa"]}]}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final a = GooglePlacesService(client: client, apiKey: 'test-key');
    final b = GooglePlacesService(client: client, apiKey: 'test-key');

    // searchText = one HTTP each — cleaner concurrency proof than lookupClinic.
    final first = a.searchText(query: 'clinic A Timisoara', city: 'Timisoara');
    final second = b.searchText(query: 'clinic B Timisoara', city: 'Timisoara');
    await Future<void>.delayed(Duration.zero);
    expect(started.length, 2);
    expect(GooglePlacesService.inFlightHttpForTest, greaterThanOrEqualTo(2));

    started[0].complete();
    final firstResult = await first;
    expect(firstResult, isEmpty);
    expect(GooglePlacesService.quotaCircuitOpen, isTrue);

    // Second in-flight request is allowed to finish after breaker opens.
    started[1].complete();
    final secondResult = await second;
    expect(secondResult, isNotEmpty);

    final before = calls;
    final third = await a.searchText(
      query: 'clinic C Timisoara',
      city: 'Timisoara',
    );
    expect(third, isEmpty);
    expect(calls, before); // no new HTTP after breaker
  });
}
