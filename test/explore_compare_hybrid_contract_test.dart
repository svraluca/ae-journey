import 'dart:async';
import 'dart:convert';

import 'package:glowpass/services/explore_price_sanity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_price_discovery_tool.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> _card({
  required String name,
  required String origin,
  required String url,
  required String sourceType,
  required String evidence,
  required num price,
  String currency = 'EUR',
  String procedure = 'Botox',
  bool own = true,
}) {
  return {
    'clinic_name': name,
    'price_extract_revision': kExplorePriceExtractRevision,
    'origin': origin,
    'price_min': price,
    'currency': currency,
    'source_url': url,
    'source_type': sourceType,
    'evidence_type': evidence,
    'clinic_own_price': own,
    'city_match': true,
    'raw_procedure_text': procedure,
    'procedure_display_name': procedure,
    'raw_evidence': '$procedure $price $currency',
    'raw_price_text': '$price $currency',
  };
}

MockClient _client(
  FutureOr<Object?> Function(http.Request request) onDiscover, {
  bool healthOk = true,
}) {
  return MockClient((request) async {
    if (request.url.path == '/health') {
      if (!healthOk) {
        throw http.ClientException('Connection refused', request.url);
      }
      return http.Response('{"ok":true,"version":"0.11.92"}', 200);
    }
    final body = onDiscover(request);
    if (body is Future) {
      final resolved = await body;
      if (resolved is http.Response) return resolved;
      return http.Response(jsonEncode(resolved), 200);
    }
    if (body is http.Response) return body;
    return http.Response(jsonEncode(body), 200);
  });
}

class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._delegate);

  final http.Client _delegate;
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (isClosed) throw StateError('The caller-owned client was closed');
    return _delegate.send(request);
  }

  @override
  void close() {
    isClosed = true;
    _delegate.close();
  }
}

void main() {
  group('compare hybrid contract', () {
    test('laser hair removal is not rewritten as a transplant', () {
      expect(
        ExplorePriceDiscoveryTool.procedureForTool(
          'laser hair removal',
          pill: 'Hair',
        ),
        'laser hair removal',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool(
          'hair transplant FUE',
          pill: 'Hair',
        ),
        'hair transplant',
      );
      expect(
        ExplorePriceDiscoveryTool.procedureForTool(
          'lip filler',
          pill: 'Fillers',
        ),
        'lip filler',
      );
      expect(
        ExplorePriceDiscoveryTool.rowMatchesRequestedProcedure(
          const ExploreDiscoveryToolRow(
            priceExtractRevision: kExplorePriceExtractRevision,
            clinicName: 'Cheek Room',
            priceMin: 180,
            currency: 'EUR',
            sourceUrl: 'https://cheek.example/prices',
            rawProcedureText: 'Cheek filler',
            rawEvidence: 'Cheek filler 180 EUR',
            rawPriceText: '180 EUR',
            clinicOwnPrice: true,
            cityMatch: true,
            sourceType: 'official_clinic',
            evidenceType: 'official_price_menu',
            procedureDisplayName: 'Cheek filler',
            qualifier: 'exact',
          ),
          'lip filler',
        ),
        isFalse,
      );
    });

    test('keeps 2 Firestore and 2 live clinics from public pages', () async {
      Map<String, Object?>? sent;
      final tool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) {
          sent = jsonDecode(request.body) as Map<String, Object?>;
          return {
            'display_results': [
              _card(
                name: 'Saved One',
                origin: 'firestore',
                url: 'https://saved-one.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 150,
              ),
              _card(
                name: 'Saved Two',
                origin: 'firestore',
                url: 'https://saved-two.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_treatment_page',
                price: 200,
              ),
              _card(
                name: 'Fresha Clinic',
                origin: 'live_search',
                url: 'https://www.fresha.com/a/fresha-clinic-tirane',
                sourceType: 'marketplace',
                evidence: 'marketplace_service_menu',
                price: 8000,
                currency: 'ALL',
                own: false,
              ),
              _card(
                name: 'Booksy Clinic',
                origin: 'live_search',
                url: 'https://booksy.com/en-us/booksy-clinic',
                sourceType: 'marketplace',
                evidence: 'marketplace_service_menu',
                price: 180,
              ),
              _card(
                name: 'Extra Cached',
                origin: 'firestore_fallback',
                url: 'https://extra.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 999,
              ),
            ],
            'fallback_reason': '',
            'adaptive_new_clinics_missing': 0,
            'card_diagnostics': [
              'firestore | Saved One | 150 EUR | official_clinic/official_price_menu | https://saved-one.al/botox',
              'live_search | Fresha Clinic | 8000 ALL | marketplace/marketplace_service_menu | https://www.fresha.com/a/fresha-clinic-tirane',
            ],
          };
        }),
      );

      final outcome = await tool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
        pill: 'Botox',
      );
      expect(sent?['strict_new_clinics'], isFalse);
      expect(sent?['stored_count'], 2);
      expect(sent?['fresh_count'], 2);
      expect(outcome.searchCompleted, isTrue);
      // Overflow stays available until the Compare screen's final validator.
      expect(outcome.rows, hasLength(5));
      expect(outcome.rows.map((row) => row.origin).toList(), [
        'firestore',
        'firestore',
        'live_search',
        'live_search',
        'firestore_fallback',
      ]);
      expect(
        outcome.rows.map((row) => row.clinicName),
        contains('Extra Cached'),
      );
      expect(outcome.rows[2].currency, 'ALL');
      expect(outcome.rows[2].priceMin, 8000);
      expect(outcome.rows[2].sourceUrl, contains('fresha.com'));
      expect(
        outcome.verificationReport,
        contains('live_search | Fresha Clinic'),
      );
    });

    test('empty live slots are filled from other Firestore clinics', () async {
      final tool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) {
          return {
            'display_results': [
              _card(
                name: 'Saved One',
                origin: 'firestore',
                url: 'https://saved-one.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 150,
              ),
              _card(
                name: 'Saved Two',
                origin: 'firestore',
                url: 'https://saved-two.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 180,
              ),
              _card(
                name: 'Saved Three',
                origin: 'firestore_fallback',
                url: 'https://saved-three.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 200,
              ),
              _card(
                name: 'Saved Four',
                origin: 'firestore_fallback',
                url: 'https://saved-four.al/botox',
                sourceType: 'official_clinic',
                evidence: 'official_treatment_page',
                price: 250,
              ),
              _card(
                name: 'Saved One',
                origin: 'firestore_fallback',
                url: 'https://saved-one.al/botox-again',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 150,
              ),
            ],
            'fallback_reason': 'live_search_shortage_filled_from_firestore',
            'fallback_used': true,
            'stored_available': 4,
            'novel_live_available': 0,
          };
        }),
      );
      final outcome = await tool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
      );
      expect(outcome.rows.map((row) => row.clinicName).toList(), [
        'Saved One',
        'Saved Two',
        'Saved Three',
        'Saved Four',
      ]);
      expect(outcome.rows.map((row) => row.origin).toList(), [
        'firestore',
        'firestore',
        'firestore_fallback',
        'firestore_fallback',
      ]);
    });

    test(
      'reports one missing live clinic instead of padding the list',
      () async {
        final tool = ExplorePriceDiscoveryTool(
          baseUrl: 'http://127.0.0.1:8080',
          client: _client((request) {
            return {
              'display_results': [
                _card(
                  name: 'Saved One',
                  origin: 'firestore',
                  url: 'https://saved-one.al/botox',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 150,
                ),
                _card(
                  name: 'Saved Two',
                  origin: 'firestore',
                  url: 'https://saved-two.al/botox',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 180,
                ),
                _card(
                  name: 'New Clinic',
                  origin: 'live_search',
                  url: 'https://new-clinic.al/prices',
                  sourceType: 'official_clinic',
                  evidence: 'official_treatment_page',
                  price: 220,
                ),
                _card(
                  name: 'Saved One',
                  origin: 'live_search',
                  url: 'https://saved-one.al/botox-again',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 150,
                ),
              ],
              'fallback_reason': 'missing_live_slot',
              'adaptive_new_clinics_missing': 1,
            };
          }),
        );
        final outcome = await tool.discoverHybrid(
          city: 'Tirane',
          procedure: 'Botox',
        );
        expect(outcome.searchCompleted, isTrue);
        expect(outcome.rows.map((row) => row.clinicName).toList(), [
          'Saved One',
          'Saved Two',
          'New Clinic',
        ]);
        expect(outcome.missingLiveSlots, 1);
        expect(outcome.fallbackReason, 'missing_live_slot');
      },
    );

    test('an unreachable server is not a completed search', () async {
      final tool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) => const {}, healthOk: false),
      );
      final outcome = await tool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
      );
      expect(outcome.searchCompleted, isFalse);
      expect(outcome.rows, isEmpty);
      expect(outcome.failure, contains('Connection refused'));
    });

    test(
      'cancellation preserves the injected client for the next selection',
      () async {
        final started = Completer<void>();
        final firstResponse = Completer<Object?>();
        var discoveryRequests = 0;
        final client = _TrackingClient(
          _client((request) {
            expect(request.url.path, '/discover-hybrid');
            discoveryRequests++;
            if (discoveryRequests == 1) {
              started.complete();
              return firstResponse.future;
            }
            return {
              'display_results': [
                _card(
                  name: 'Current Clinic',
                  origin: 'live_search',
                  url: 'https://current.al/fillers',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 180,
                  procedure: 'dermal filler',
                ),
              ],
            };
          }),
        );
        addTearDown(client.close);
        final tool = ExplorePriceDiscoveryTool(
          baseUrl: 'http://127.0.0.1:8080',
          client: client,
        );

        final previous = tool.discoverHybrid(
          city: 'Tirane',
          procedure: 'Botox',
        );
        await started.future.timeout(const Duration(seconds: 2));
        tool.abortInFlightDiscover();
        expect(client.isClosed, isFalse);
        firstResponse.complete({
          'display_results': [
            _card(
              name: 'Previous Clinic',
              origin: 'live_search',
              url: 'https://previous.al/botox',
              sourceType: 'official_clinic',
              evidence: 'official_price_menu',
              price: 100,
            ),
          ],
        });

        final cancelled = await previous;
        expect(cancelled.searchCompleted, isFalse);
        expect(cancelled.failure, 'cancelled');
        expect(cancelled.rows, isEmpty);

        final current = await tool.discoverHybrid(
          city: 'Tirane',
          procedure: 'dermal filler',
        );
        expect(current.searchCompleted, isTrue);
        expect(current.rows.single.clinicName, 'Current Clinic');
        expect(discoveryRequests, 2);
        expect(client.isClosed, isFalse);
      },
    );

    test('plain JSON and NDJSON both yield the same cards', () async {
      final jsonTool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) {
          return {
            'display_results': [
              _card(
                name: 'JSON Clinic',
                origin: 'firestore',
                url: 'https://json.al/price',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 100,
              ),
            ],
          };
        }),
      );
      final ndjsonTool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) {
          final body = [
            jsonEncode({
              'event': 'partial',
              'display_results': [
                _card(
                  name: 'JSON Clinic',
                  origin: 'firestore',
                  url: 'https://json.al/price',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 100,
                ),
              ],
            }),
            jsonEncode({
              'event': 'done',
              'body': {
                'display_results': [
                  _card(
                    name: 'JSON Clinic',
                    origin: 'firestore',
                    url: 'https://json.al/price',
                    sourceType: 'official_clinic',
                    evidence: 'official_price_menu',
                    price: 100,
                  ),
                  _card(
                    name: 'Treatwell Clinic',
                    origin: 'live_search',
                    url: 'https://www.treatwell.co.uk/place/treatwell-clinic/',
                    sourceType: 'marketplace',
                    evidence: 'marketplace_profile',
                    price: 90,
                    own: false,
                  ),
                ],
                'fallback_reason': 'missing_live_slot',
                'adaptive_new_clinics_missing': 1,
              },
            }),
          ].join('\n');
          return http.Response(body, 200);
        }),
      );
      final jsonOutcome = await jsonTool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
      );
      final streamOutcome = await ndjsonTool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
      );
      expect(jsonOutcome.searchCompleted, isTrue);
      expect(jsonOutcome.rows.single.clinicName, 'JSON Clinic');
      expect(streamOutcome.searchCompleted, isTrue);
      expect(streamOutcome.rows, hasLength(2));
      expect(streamOutcome.rows.last.sourceUrl, contains('treatwell'));
      expect(streamOutcome.missingLiveSlots, 1);
    });

    test('simulator reaches loopback and a phone uses the configured URL', () {
      expect(
        ExplorePriceDiscoveryTool.hardwareMachineIsIosSimulator('arm64'),
        isTrue,
      );
      expect(
        ExplorePriceDiscoveryTool.hardwareMachineIsIosSimulator('iPhone15,2'),
        isFalse,
      );
      expect(
        ExplorePriceDiscoveryTool.urlsFor(
          loopbackReachesServer: true,
          deployedUrl: '',
          devUrl: '',
        ),
        ['http://127.0.0.1:8080'],
      );
      expect(
        ExplorePriceDiscoveryTool.urlsFor(
          loopbackReachesServer: true,
          deployedUrl: 'https://prices.example',
          devUrl: 'http://192.168.1.20:8080',
        ),
        ['http://192.168.1.20:8080', 'https://prices.example'],
      );
      expect(
        ExplorePriceDiscoveryTool.urlsFor(
          loopbackReachesServer: false,
          deployedUrl: '',
          devUrl: '',
        ),
        isEmpty,
      );
      expect(
        ExplorePriceDiscoveryTool.urlsFor(
          loopbackReachesServer: false,
          deployedUrl: 'https://prices.example',
          devUrl: 'http://192.168.1.20:8080',
        ),
        ['https://prices.example', 'http://192.168.1.20:8080'],
      );
    });

    test(
      'three verified prices stay three and report the missing live slot',
      () async {
        final tool = ExplorePriceDiscoveryTool(
          baseUrl: 'http://127.0.0.1:8080',
          client: _client((request) {
            return {
              'display_results': [
                _card(
                  name: 'Saved One',
                  origin: 'firestore',
                  url: 'https://saved-one.al/botox',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 150,
                ),
                _card(
                  name: 'Saved Two',
                  origin: 'firestore',
                  url: 'https://saved-two.al/botox',
                  sourceType: 'official_clinic',
                  evidence: 'official_price_menu',
                  price: 200,
                ),
                _card(
                  name: 'New Clinic',
                  origin: 'live_search',
                  url: 'https://new.al/botox',
                  sourceType: 'official_clinic',
                  evidence: 'official_treatment_page',
                  price: 180,
                ),
              ],
              'fallback_reason': 'missing_live_slot',
              'fallback_used': true,
              'stored_available': 4,
              'novel_live_available': 1,
              'adaptive_new_clinics_missing': 1,
              'growth_exhausted_reason':
                  'no_additional_eligible_clinic_in_searched_sources',
              'quality_reject_samples': [
                'no_price_evidence: https://example.al/menu',
              ],
            };
          }),
        );
        final outcome = await tool.discoverHybrid(
          city: 'Tirane',
          procedure: 'Botox',
        );
        expect(outcome.rows, hasLength(3));
        expect(outcome.storedAvailable, 4);
        expect(outcome.novelLiveAvailable, 1);
        expect(outcome.fallbackUsed, isTrue);
        expect(outcome.missingLiveSlots, 1);
        expect(
          outcome.growthExhaustedReason,
          'no_additional_eligible_clinic_in_searched_sources',
        );
        expect(outcome.rejectionReasons.single, contains('no_price_evidence'));
        expect(outcome.pythonSummary, contains('novel_live_available=1'));
      },
    );

    test('the visible tab is not held behind another tab', () async {
      final started = <String>[];
      final tool = ExplorePriceDiscoveryTool(
        baseUrl: 'http://127.0.0.1:8080',
        client: _client((request) async {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final procedure = '${body['procedure']}';
          started.add(procedure);
          if (procedure == 'botox') {
            await Future<void>.delayed(const Duration(milliseconds: 600));
          }
          return {
            'display_results': [
              _card(
                name: procedure,
                origin: 'live_search',
                url: 'https://$procedure.example/price',
                sourceType: 'official_clinic',
                evidence: 'official_price_menu',
                price: 100,
                procedure: procedure,
              ),
            ],
          };
        }),
      );
      final background = tool.discoverHybrid(
        city: 'Tirane',
        procedure: 'Botox',
        priority: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final watch = Stopwatch()..start();
      final visible = await tool.discoverHybrid(
        city: 'Tirane',
        procedure: 'dermal filler',
        pill: 'Fillers',
        priority: true,
      );
      watch.stop();
      expect(visible.searchCompleted, isTrue);
      expect(visible.rows.single.clinicName, 'dermal filler');
      expect(watch.elapsedMilliseconds, lessThan(500));
      expect(started, contains('dermal filler'));
      await background;
    });
  });
}
