import 'dart:async';
import 'dart:convert';

import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/services/explore_price_discovery_tool.dart';
import '../lib/services/explore_compare_mix.dart';

Map<String, Object?> quote(String name, String host, int amount) => {
  'clinic_name': name,
  'price_extract_revision': kExplorePriceExtractRevision,
  'city': 'Abu Dhabi',
  'procedure_canonical': 'botox',
  'procedure_display_name': 'Botox',
  'raw_procedure_text': 'Cosmetic Botox',
  'raw_evidence': 'Cosmetic Botox injections from $amount AED',
  'price_min': amount,
  'currency': 'AED',
  'qualifier': 'from',
  'source_url': 'https://$host/prices/',
  'official_website': 'https://$host/',
  'source_type': 'official_clinic',
  'evidence_type': 'official_price_menu',
  'clinic_own_price': true,
  'city_match': true,
  'origin': 'firestore',
  'last_verified_at': '2026-08-05T10:00:00Z',
};

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json'});

http.Response health() => jsonResponse({'ok': true, 'version': '0.11.93', 'progressive_jobs': true});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('progress-only updates keep the same card fingerprint', () {
    final row = quote('Aster Medical Center', 'aster.example', 700);
    ExploreDiscoveryJob snapshot(Map<String, Object?> price, int pages) =>
        ExploreDiscoveryJob.fromJson({
          'job_id': 'peels', 'status': 'running',
          'display_results': [price], 'progress': {'fetched_pages': pages},
        });
    final first = snapshot(row, 1);
    expect(first.rowsFingerprint, snapshot(row, 17).rowsFingerprint);
    expect(first.rowsFingerprint,
        isNot(snapshot({...row, 'price_max': 900}, 17).rowsFingerprint));
    expect(first.rowsFingerprint,
        isNot(snapshot({...row, 'raw_evidence': 'Botox at our clinic 700 AED'}, 17).rowsFingerprint));
  });

  test('price index returns both workers rows and preserves verification date', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/health') return health();
      expect(request.url.path, '/price-index');
      final body = jsonDecode(request.body) as Map;
      expect(body['procedure'], 'botox');
      return jsonResponse({'display_results': [
        quote('Aster Medical Center', 'aster.example', 900),
        quote('Cedar Aesthetic Clinic', 'cedar.example', 799),
      ]});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.loadIndexedPrices(city: 'Abu Dhabi', procedure: 'Botox');
    expect(result.searchCompleted, isTrue);
    expect(result.rows.map((row) => row.priceMin), [900, 799]);
    expect(result.rows.first.lastVerifiedAt, DateTime.utc(2026, 8, 5, 10));
    expect(paths, ['/health', '/price-index']);
  });

  test('an empty index is a valid snapshot', () async {
    final client = MockClient((request) async => request.url.path == '/health'
        ? health() : jsonResponse({'display_results': []}));
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.loadIndexedPrices(city: 'Abu Dhabi', procedure: 'Botox');
    expect(result.searchCompleted, isTrue);
    expect(result.rows, isEmpty);
  });

  test('four display slots keep all seven job candidates available for rotation', () {
    final candidates = [for (var i = 0; i < 7; i++)
      quote('Medical Clinic $i', 'medical-$i.example', 900)];
    for (final status in ['running', 'completed']) {
      final job = ExploreDiscoveryJob.fromJson({
        'job_id': 'pooled', 'status': status,
        'display_results': candidates.take(4).toList(),
        'candidate_results': candidates,
      });
      expect(job.rows, hasLength(7));
      final visible = selectExploreCompareRows<ExploreDiscoveryToolRow>(
        saved: job.rows, live: const [],
        sameProvider: (a, b) => a.clinicName == b.clinicName,
      );
      expect(visible, hasLength(4));
    }
  });

  test('poll deadline includes a stalled health request', () async {
    final gate = Completer<http.Response>();
    final client = MockClient((_) => gate.future);
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final state = await tool.readDiscoveryJob('slow',
        deadline: const Duration(milliseconds: 20));
    expect(state, isNull);
    expect(tool.lastFailure, contains('TimeoutException'));
    gate.complete(health());
  });

  test('poll budget stops loading and retains prices without failing the server job', () async {
    final gate = Completer<http.Response>();
    final client = MockClient((_) => gate.future);
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final job = ExploreDiscoveryJob.fromJson({
      'job_id': 'still-running', 'status': 'running',
      'display_results': [quote('Aster Medical Center', 'aster.example', 900)],
    });
    final timer = Stopwatch()..start();
    final states = await tool.watchDiscoveryJob(job,
        budget: const Duration(milliseconds: 40),
        pollInterval: const Duration(milliseconds: 1)).toList();
    expect(timer.elapsedMilliseconds, lessThan(500));
    expect(states.last.pollingStopped, isTrue);
    expect(states.last.status, 'running');
    expect(states.last.isFinished, isFalse);
    expect(states.last.rowsFingerprint, job.rowsFingerprint);
    expect(states.last.message, contains('still running'));
    gate.complete(health());
  });

  test('a malformed index is a failure, not a completed empty market', () async {
    final client = MockClient((request) async => request.url.path == '/health'
        ? health() : jsonResponse({'message': 'wrong server'}));
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.loadIndexedPrices(city: 'Abu Dhabi', procedure: 'Botox');
    expect(result.searchCompleted, isFalse);
    expect(result.failure, contains('Invalid price-index response'));
  });

  test('the price-read deadline includes a stalled health check', () async {
    final gate = Completer<http.Response>();
    final client = MockClient((request) => gate.future);
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.loadIndexedPrices(
      city: 'Abu Dhabi', procedure: 'Botox',
      deadline: const Duration(milliseconds: 20),
    );
    gate.complete(health());
    expect(result.searchCompleted, isFalse);
    expect(result.failure, contains('TimeoutException'));
  });

  test('known-price refresh uses its own bounded endpoint', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/health') return health();
      expect(request.url.path, '/refresh-prices');
      return jsonResponse({'display_results': [
        quote('Aster Medical Center', 'aster.example', 950),
      ]});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.refreshKnownPrices(city: 'Abu Dhabi', procedure: 'Botox');
    expect(result.searchCompleted, isTrue);
    expect(result.rows.single.priceMin, 950);
  });

  test('a failed refresh does not report a successful empty result', () async {
    final client = MockClient((request) async => request.url.path == '/health'
        ? health() : jsonResponse({'detail': 'timeout'}, 504));
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final result = await tool.refreshKnownPrices(city: 'Abu Dhabi', procedure: 'Botox');
    expect(result.searchCompleted, isFalse);
  });

  test('an empty market can enqueue a background job', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/health') return health();
      expect(request.url.path, '/discover-jobs');
      return jsonResponse({'job_id': 'new-job', 'status': 'queued',
        'enqueued': true, 'display_results': []});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final job = await tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Botox');
    expect(job, isNotNull);
    expect(job!.id, 'new-job');
    expect(job.isFinished, isFalse);
  });

  test('running job delivers two saved plus two new before completion', () async {
    var polls = 0;
    var healthCalls = 0;
    final saved = [quote('Aster Medical Center', 'aster.example', 900),
                   quote('Cedar Medical Center', 'cedar.example', 799)];
    final fresh = [
      {...quote('Elm Medical Center', 'elm.example', 850), 'origin': 'live_search'},
      {...quote('Oak Medical Center', 'oak.example', 950), 'origin': 'live_search'},
    ];
    final client = MockClient((request) async {
      if (request.url.path == '/health') {
        healthCalls++;
        return health();
      }
      if (request.url.path == '/discover-jobs') {
        final body = jsonDecode(request.body) as Map;
        expect(body['display_limit'], 4);
        expect(body['client_stored_count'], 2);
        expect(body['client_known_clinic_hosts'], ['aster.example', 'cedar.example']);
        return jsonResponse({'job_id': 'progressive-job', 'status': 'queued', 'enqueued': true});
      }
      expect(request.url.path, '/discover-jobs/progressive-job');
      polls++;
      return jsonResponse({
        'job_id': 'progressive-job', 'status': polls == 1 ? 'running' : 'completed',
        'display_results': [...saved, ...fresh],
        'progress': {'phase': polls == 1 ? 'verified_results' : 'completed',
                     'fresh_count': 2, 'desired_fresh': 2, 'shortfall_reason': 'target_met'},
      });
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final job = await tool.enqueueDiscoveryJob(
      city: 'Abu Dhabi', procedure: 'Botox', clientStoredCount: 2,
      knownClinicHosts: ['aster.example', 'cedar.example'],
    );
    final states = await tool.watchDiscoveryJob(job!,
      budget: const Duration(seconds: 1), pollInterval: const Duration(milliseconds: 1)).toList();
    expect(states.map((state) => state.status), ['queued', 'running', 'completed']);
    final visible = selectExploreCompareRows<ExploreDiscoveryToolRow>(
      saved: states[1].rows.where((row) => row.origin == 'firestore'),
      live: states[1].rows.where((row) => row.origin == 'live_search'),
      sameProvider: (a, b) => a.clinicName == b.clinicName,
    );
    expect(visible.length, 4);
    expect(visible.where((row) => row.origin == 'live_search').length, 2);
    expect(states.last.progress['shortfall_reason'], 'target_met');
    expect(healthCalls, 1);
  });

  test('validated marketplace service menu survives the host filter', () {
    final data = {
      ...quote('Elm Medical Center', 'elm.example', 850),
      'source_url': 'https://www.fresha.com/a/elm-medical-center-abu-dhabi-abc',
      'source_type': 'marketplace', 'evidence_type': 'marketplace_service_menu',
      'clinic_own_price': false,
    };
    final row = ExplorePriceDiscoveryTool.rowFromJson(data);
    expect(row, isNotNull);
    expect(ExplorePriceDiscoveryTool.canUseMarketplacePrice(row!), isTrue);
    final generic = ExplorePriceDiscoveryTool.rowFromJson({
      ...data, 'evidence_type': 'marketplace_profile',
    });
    expect(generic, isNotNull);
    expect(ExplorePriceDiscoveryTool.canUseMarketplacePrice(generic!), isFalse);
    expect(ExplorePriceDiscoveryTool.rowFromJson({...data, 'city_match': false}), isNull);
  });

  test('completed short search and queued search have distinct messages', () {
    const queued = ExploreDiscoveryJob(id: 'one', status: 'queued');
    final completed = ExploreDiscoveryJob.fromJson({
      'job_id': 'one', 'status': 'completed',
      'display_results': [quote('Aster Medical Center', 'aster.example', 900)],
      'progress': {'fresh_count': 0, 'shortfall_reason': 'page_fetch_budget_exhausted'},
    });
    expect(queued.message, contains('Preparing'));
    expect(completed.message, contains('Search finished'));
    expect(completed.progress['shortfall_reason'], 'page_fetch_budget_exhausted');
    expect(completed.isFinished, isTrue);
  });

  test('a recently completed ticket includes its results without another poll', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path == '/health') return health();
      expect(request.url.path, '/discover-jobs');
      return jsonResponse({'job_id': 'finished-job', 'status': 'completed',
        'enqueued': false, 'reason': 'recently_finished', 'display_results': [
          quote('Cedar Aesthetic Clinic', 'cedar.example', 799),
        ]});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final job = await tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Botox');
    final states = await tool.watchDiscoveryJob(job!).toList();
    expect(states.single.isFinished, isTrue);
    expect(states.single.rows.single.priceMin, 799);
    expect(paths, ['/health', '/discover-jobs']);
  });

  test('wrong-city and unowned prices are rejected by the row parser', () {
    final row = quote('Aster Medical Center', 'aster.example', 900);
    expect(ExplorePriceDiscoveryTool.rowFromJson({...row, 'city_match': false}), isNull);
    expect(ExplorePriceDiscoveryTool.rowFromJson({...row, 'clinic_own_price': false}), isNull);
  });

  test('published price unit is preserved in a backend row', () {
    final row = ExplorePriceDiscoveryTool.rowFromJson({
      ...quote('Aster Medical Center', 'aster.example', 42),
      'unit': 'unit', 'raw_evidence': 'Botox AED 42 per unit',
    });
    expect(row, isNotNull);
    expect(row!.unit, 'unit');
  });

  test('clinic-name search returns a real identity without requiring a price', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/health') return health();
      expect(request.url.path, '/search-clinics');
      return jsonResponse({'results': [{
        'title': 'Cedar Aesthetic Clinic', 'subtitle': 'Abu Dhabi', 'type': 'clinic',
        'official_website': 'https://cedar.example/', 'rating': 0, 'reviews': 0,
      }]});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    final found = await tool.searchClinics(city: 'Abu Dhabi', query: 'Cedar');
    expect(found.single['type'], 'clinic');
    expect(found.single.containsKey('price_min'), isFalse);
  });

  test('clinic-name endpoint failure can be surfaced to the screen', () async {
    final client = MockClient((request) async => request.url.path == '/health'
        ? health() : jsonResponse({'detail': 'unavailable'}, 503));
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    await expectLater(tool.searchClinics(
      city: 'Abu Dhabi', query: 'Cedar', throwOnFailure: true,
    ), throwsStateError);
  });

  test('selected procedure uses a foreground ticket with a stable client and ordered focus', () async {
    final bodies = <Map>[];
    final client = MockClient((request) async {
      if (request.url.path == '/health') return health();
      bodies.add(jsonDecode(request.body) as Map);
      return jsonResponse({'job_id': 'focus-${bodies.length}', 'status': 'queued'});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    tool.focusDiscovery('peel');
    await tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Peels',
      pill: 'Peels', foreground: true, focusKey: 'peel');
    tool.focusDiscovery('hair');
    await tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Hair',
      pill: 'Hair', foreground: true, focusKey: 'hair');
    await tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Botox');
    expect(bodies[0]['mode'], 'foreground');
    expect(bodies[1]['mode'], 'foreground');
    expect(bodies[2]['mode'], 'background');
    expect(bodies[0]['display_limit'], 4);
    expect(bodies[1]['focus_seq'], greaterThan(bodies[0]['focus_seq'] as int));
    expect(bodies[0]['client_id'], isNotEmpty);
    expect(bodies[1]['client_id'], bodies[0]['client_id']);
  });

  test('a previous pill delayed by health cannot reclaim foreground focus', () async {
    final healthStarted = Completer<void>();
    final healthGate = Completer<http.Response>();
    Map? body;
    final client = MockClient((request) async {
      if (request.url.path == '/health') {
        healthStarted.complete();
        return healthGate.future;
      }
      body = jsonDecode(request.body) as Map;
      return jsonResponse({'job_id': 'old-focus', 'status': 'queued'});
    });
    addTearDown(client.close);
    final tool = ExplorePriceDiscoveryTool(client: client, baseUrl: 'http://test');
    tool.focusDiscovery('peel');
    final pending = tool.enqueueDiscoveryJob(city: 'Abu Dhabi', procedure: 'Peels',
      foreground: true, focusKey: 'peel', reason: 'user');
    await healthStarted.future;
    tool.focusDiscovery('hair');
    healthGate.complete(health());
    await pending;
    expect(body!['mode'], 'background');
    expect(body!['reason'], 'thin_market');
  });

  test('running progress and finished short results have different messages', () {
    const running = ExploreDiscoveryJob(id: 'peel', status: 'running',
      progress: {'fetched_pages': 17});
    expect(running.message, contains('17 pages checked'));
    expect(running.isFinished, isFalse);
    final completed = ExploreDiscoveryJob.fromJson({
      'job_id': 'peel', 'status': 'completed',
      'display_results': [quote('Aster Medical Center', 'aster.example', 900)],
    });
    expect(completed.message, contains('Search finished'));
    expect(completed.isFinished, isTrue);
  });
}
