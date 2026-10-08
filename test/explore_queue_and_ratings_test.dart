import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/services/explore_discovery_transport.dart';
import '../lib/services/google_places_service.dart';

void main() {
  setUp(GooglePlacesService.resetQuotaCircuitBreaker);

  test('queue acceptance retries the identical body after timeout', () async {
    final bodies = <String>[];
    final client = MockClient((request) async {
      bodies.add(request.body);
      if (bodies.length == 1) throw TimeoutException('busy');
      return http.Response('{"job_id":"same-job"}', 200);
    });
    final response = await postExploreDiscoveryJobWithRetry(client: client,
      uri: Uri.parse('http://localhost/discover-jobs'),
      body: '{"city":"Madrid","client_focus_seq":2}',
      isCurrent: () => true, retryDelay: Duration.zero);
    expect(response?.statusCode, 200);
    expect(bodies, hasLength(2));
    expect(bodies[0], bodies[1]);
    client.close();
  });

  test('a tab switch suppresses a stale foreground retry', () async {
    var current = true;
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      current = false;
      throw TimeoutException('first request still running');
    });
    final response = await postExploreDiscoveryJobWithRetry(client: client,
      uri: Uri.parse('http://localhost/discover-jobs'), body: '{}',
      isCurrent: () => current, retryDelay: Duration.zero);
    expect(response, isNull);
    expect(calls, 1);
    client.close();
  });

  test('Places returns identity and rating from a single search request', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.path, '/v1/places:searchText');
      final mask = request.headers['X-Goog-FieldMask'] ?? request.headers['x-goog-fieldmask'];
      expect(mask, contains('places.rating'));
      expect(mask, contains('places.userRatingCount'));
      expect(mask, contains('places.websiteUri'));
      return http.Response(jsonEncode({'places': [{
        'id': 'aster-place', 'displayName': {'text': 'Aster Clinic'},
        'formattedAddress': 'Test Street, Madrid, Spain',
        'websiteUri': 'https://aster.example', 'rating': 4.8,
        'userRatingCount': 321, 'location': {'latitude': 40.4, 'longitude': -3.7},
      }]}), 200);
    });
    final service = GooglePlacesService(client: client, apiKey: 'test-only');
    final result = await service.lookupClinic(clinicName: 'Aster Clinic', city: 'Madrid');
    expect(result?.rating, 4.8);
    expect(result?.reviewsTotal, 321);
    expect(result?.name, 'Aster Clinic');
    expect(calls, 1);
    client.close();
  });

  test('failed Places HTTP is retryable rather than a cached identity miss', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (calls == 1) return http.Response('{"error":{"status":"UNAVAILABLE"}}', 503);
      return http.Response('{"places":[{"id":"aster","displayName":{"text":"Aster"},"rating":4.7}]}', 200);
    });
    final service = GooglePlacesService(client: client, apiKey: 'test-only');
    await expectLater(service.lookupClinic(clinicName: 'Aster', city: 'Madrid'), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final result = await service.lookupClinic(clinicName: 'Aster', city: 'Madrid');
    expect(result?.rating, 4.7);
    expect(calls, 2);
    client.close();
  });
}
