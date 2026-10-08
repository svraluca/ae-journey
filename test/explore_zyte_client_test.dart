import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_zyte_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('Zyte client returns only browserHtml and ignores AI fields', () async {
    final mock = MockClient((request) async {
      expect(request.url.toString(), 'https://api.zyte.com/v1/extract');
      final body = jsonDecode(request.body) as Map;
      expect(body['browserHtml'], isTrue);
      expect(body.containsKey('product'), isFalse);
      expect(body.containsKey('customAttributes'), isFalse);
      return http.Response(
        jsonEncode({
          'browserHtml': '<html><body>Botox AED 42/unit</body></html>',
          'product': {'price': '999'},
          'customAttributes': {'price': 123},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final client = ExploreZyteClient(apiKey: 'test-key', httpClient: mock);
    final html = await client.fetchBrowserHtml('https://clinic.example/botox');
    expect(html, contains('Botox AED 42'));
    expect(html, isNot(contains('999')));
  });

  test('Zyte client skips sitemap / xml URLs', () async {
    expect(
      ExploreZyteClient.isUnsupportedUrl(
        'https://www.mediclinic.ae/en/corporate/health-knowledge/botox.html',
      ),
      isTrue,
    );
    final mock = MockClient((request) async {
      fail('must not call Zyte for sitemaps');
      return http.Response('', 500);
    });
    final client = ExploreZyteClient(apiKey: 'test-key', httpClient: mock);
    expect(
      await client.fetchBrowserHtml(
        'https://novomed.com/services-sitemap2.xml',
      ),
      isEmpty,
    );
  });
}
