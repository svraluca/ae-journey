import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_renderer_client.dart';

void main() {
  group('Headless renderer client', () {
    test('1. Endpoint tolerates trailing slashes and a bare host', () {
      expect(
        exploreRendererEndpoint('https://renderer.run.app/')?.toString(),
        'https://renderer.run.app/render',
      );
      expect(
        exploreRendererEndpoint('renderer.run.app')?.toString(),
        'https://renderer.run.app/render',
      );
      expect(exploreRendererEndpoint('   '), isNull);
    });

    test('2. Token is sent as a bearer only when present', () {
      expect(
        exploreRendererHeaders('abc123'),
        {'Content-Type': 'application/json', 'Authorization': 'Bearer abc123'},
      );
      expect(exploreRendererHeaders('  '), {
        'Content-Type': 'application/json',
      });
    });

    test('3. Request asks for one page and nothing else', () {
      expect(
        jsonDecode(exploreRendererRequestBody('https://tajmeel.ae/prices')),
        {'url': 'https://tajmeel.ae/prices'},
      );
    });

    test('4. Loopback and private targets are never rendered', () {
      expect(exploreRendererAllowsUrl('https://tajmeel.ae/prices'), isTrue);
      expect(exploreRendererAllowsUrl('http://localhost:8080/x'), isFalse);
      expect(exploreRendererAllowsUrl('http://127.0.0.1/x'), isFalse);
      expect(exploreRendererAllowsUrl('http://192.168.1.4/x'), isFalse);
      expect(
        exploreRendererAllowsUrl('http://metadata.google.internal/'),
        isFalse,
      );
      expect(exploreRendererAllowsUrl(''), isFalse);
    });

    test('5. Only the html field is read; junk yields nothing', () {
      final ok = exploreParseRenderedHtml(
        '{"html":"<table><td>750 AED</td></table>","statusCode":200}',
      );
      expect(ok.html, '<table><td>750 AED</td></table>');
      expect(ok.usable, isTrue);

      for (final junk in ['{"html":""}', 'not json', '[]', '']) {
        expect(exploreParseRenderedHtml(junk).usable, isFalse, reason: junk);
      }
    });

    test('6. A rendered Cloudflare block page is not the clinic page', () {
      final blocked = exploreParseRenderedHtml(
        '{"html":"<html><body>Attention Required! Cloudflare</body></html>",'
        '"statusCode":403}',
      );
      expect(blocked.html, isNotEmpty);
      expect(blocked.statusCode, 403);
      expect(blocked.usable, isFalse);
    });
  });
}
