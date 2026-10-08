import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glowpass/services/explore_serp_provider.dart';

void main() {
  group('Discovery provider', () {
    test('1. Serper leads, then DataForSEO, then SerpApi', () {
      expect(
        exploreSerpProviderKind(
          serperApiKey: 'serper',
          dataForSeoLogin: 'me@glowpass.app',
          dataForSeoPassword: 'pw',
          serpApiKey: 'serp',
        ),
        ExploreSerpProviderKind.serper,
      );
      expect(
        exploreSerpProviderKind(
          serperApiKey: '  ',
          dataForSeoLogin: 'me@glowpass.app',
          dataForSeoPassword: 'pw',
          serpApiKey: 'serp',
        ),
        ExploreSerpProviderKind.dataForSeo,
      );
      expect(
        exploreSerpProviderKind(
          serperApiKey: '',
          dataForSeoLogin: 'me@glowpass.app',
          dataForSeoPassword: '   ',
          serpApiKey: 'serp',
        ),
        ExploreSerpProviderKind.serpApi,
      );
      expect(
        exploreSerpProviderKind(
          serperApiKey: '',
          dataForSeoLogin: '',
          dataForSeoPassword: '',
          serpApiKey: '',
        ),
        ExploreSerpProviderKind.none,
      );
    });

    test('1b. Serper asks Google plainly and reads URLs, not prices', () {
      expect(
        exploreSerperEndpoint().toString(),
        'https://google.serper.dev/search',
      );
      expect(exploreSerperHeaders(' key ')['X-API-KEY'], 'key');

      final body = exploreSerperRequestBody(
        query: 'بوتوكس سعر Dubai',
        hl: 'ar',
        gl: 'ae',
      );
      expect(body['q'], 'بوتوكس سعر Dubai');
      expect(body['hl'], 'ar');
      expect(body['gl'], 'ae');
      // Serper serves one page whatever `num` asks for, and asking for more
      // only doubled the response time.
      expect(body.containsKey('num'), isFalse);
      // Unmapped markets omit the country instead of being forced to the US.
      expect(exploreSerperRequestBody(query: 'botox nairobi'), isNot(contains('gl')));
      expect(exploreSerperRequestBody(query: 'q', gl: 'uk')['gl'], 'gb');

      // A spent or wrong key must stop the provider, a hiccup must not.
      expect(exploreSerperKeyUnusable(401), isTrue);
      expect(exploreSerperKeyUnusable(403), isTrue);
      expect(exploreSerperKeyUnusable(429), isFalse);
      expect(exploreSerperKeyUnusable(503), isFalse);
      expect(
        exploreSerperOutOfCredits(
          400,
          '{"message":"Not enough credits","statusCode":400}',
        ),
        isTrue,
      );
      expect(exploreSerperOutOfCredits(400, '{"message":"bad query"}'), isFalse);

      final hits = exploreParseSerperOrganic(
        jsonDecode('''
        {
          "organic": [
            {
              "title": "Botox Dubai | Prices",
              "link": "https://euromedclinicdubai.com/botox",
              "snippet": "Botox from AED 1200 per area",
              "displayedLink": "euromedclinicdubai.com"
            },
            {"title": "no link"}
          ],
          "answerBox": {"snippet": "Botox costs AED 800"}
        }
        '''),
      );
      expect(hits, hasLength(2));
      expect(hits.first.link, 'https://euromedclinicdubai.com/botox');
      expect(hits.first.displayedLink, 'euromedclinicdubai.com');
    });

    test('2. Dubai queries carry the UAE location and Arabic language', () {
      expect(exploreDataForSeoLocationCode('ae'), 2784);
      expect(exploreDataForSeoLocationCode('uk'), 2826);
      expect(exploreDataForSeoLocationCode('ro'), 2642);
      expect(exploreDataForSeoLocationCode('zz'), isNull);

      final body = exploreDataForSeoRequestBody(
        query: 'اسعار البوتوكس دبي',
        hl: 'ar',
        gl: 'ae',
      );
      expect(body, hasLength(1));
      expect(body.first['keyword'], 'اسعار البوتوكس دبي');
      expect(body.first['location_code'], 2784);
      expect(body.first['language_code'], 'ar');
      expect(body.first['depth'], 10);
    });

    test('2b. DataForSEO city sweeps go deep, site: stays shallow', () {
      expect(exploreDataForSeoDepth('بوتوكس سعر Dubai'), 30);
      expect(exploreDataForSeoDepth('Botox prices in Dubai'), 30);
      expect(
        exploreDataForSeoDepth('Lucia Clinic Botox price site:luciaclinic.com'),
        10,
      );
      expect(
        exploreDataForSeoRequestBody(
          query: 'Botox prices in Dubai',
          gl: 'ae',
          depth: exploreDataForSeoDepth('Botox prices in Dubai'),
        ).first['depth'],
        30,
      );
    });

    test('3. Unmapped markets fall back to google.com instead of failing', () {
      final body = exploreDataForSeoRequestBody(
        query: 'botox nairobi price',
        gl: '',
      );
      expect(body.first['location_code'], 2840);
      expect(body.first['language_code'], 'en');
    });

    test('4. Auth header is Basic base64(login:password)', () {
      expect(
        exploreDataForSeoAuthHeader('me@glowpass.app', 'pw'),
        'Basic ${base64Encode(utf8.encode('me@glowpass.app:pw'))}',
      );
      expect(
        exploreDataForSeoEndpoint().toString(),
        'https://api.dataforseo.com/v3/serp/google/organic/live/regular',
      );
    });

    test('5. Organic rows give URL + title only; no price channel', () {
      final decoded = jsonDecode('''
{
  "status_code": 20000,
  "tasks": [{
    "status_code": 20000,
    "result": [{
      "items": [
        {"type": "people_also_ask", "title": "How much does botox cost?"},
        {
          "type": "organic",
          "title": "Botox Dubai — Price List",
          "url": "https://tajmeel.ae/prices",
          "description": "Botox from AED 750 per area",
          "breadcrumb": "https://tajmeel.ae > prices"
        },
        {"type": "organic", "title": "", "url": "", "description": ""}
      ]
    }]
  }]
}
''');
      final hits = exploreParseDataForSeoOrganic(decoded);
      expect(hits, hasLength(1));
      expect(hits.first.link, 'https://tajmeel.ae/prices');
      expect(hits.first.title, 'Botox Dubai — Price List');
      expect(hits.first.snippet, 'Botox from AED 750 per area');
      expect(hits.first.displayedLink, 'https://tajmeel.ae > prices');
    });

    test('6. Task errors surface instead of parsing as empty success', () {
      expect(
        exploreDataForSeoStatusError(
          jsonDecode('{"status_code":40100,"status_message":"Auth failed"}'),
        ),
        contains('40100'),
      );
      expect(
        exploreDataForSeoStatusError(
          jsonDecode(
            '{"status_code":20000,"tasks":[{"status_code":40501,'
            '"status_message":"Invalid Field"}]}',
          ),
        ),
        contains('40501'),
      );
      expect(
        exploreDataForSeoStatusError(
          jsonDecode(
            '{"status_code":20000,"tasks":[{"status_code":20000,"result":[]}]}',
          ),
        ),
        '',
      );
      expect(exploreDataForSeoStatusError('nope'), isNotEmpty);
    });

    test('7. Account problems disable the provider, SE hiccups only retry', () {
      ExploreDataForSeoStatus statusOf(String body) =>
          exploreDataForSeoStatus(jsonDecode(body));

      final bad = statusOf('{"status_code":40100,"status_message":"Unauth"}');
      expect(bad.providerUnusable, isTrue);
      expect(bad.retryable, isFalse);

      // 40101 is Google failing, not our credentials — retry, never disable.
      final broke = statusOf(
        '{"status_code":20000,"tasks":[{"status_code":40101,'
        '"status_message":"Internal SE Server Error."}]}',
      );
      expect(broke.providerUnusable, isFalse);
      expect(broke.retryable, isTrue);

      final funds = statusOf(
        '{"status_code":20000,"tasks":[{"status_code":40210,'
        '"status_message":"Insufficient Funds."}]}',
      );
      expect(funds.providerUnusable, isTrue);

      final throttled = statusOf(
        '{"status_code":20000,"tasks":[{"status_code":40202,'
        '"status_message":"rate-limit per minute"}]}',
      );
      expect(throttled.rateLimited, isTrue);
      expect(throttled.providerUnusable, isFalse);

      final empty = statusOf(
        '{"status_code":20000,"tasks":[{"status_code":40102,'
        '"status_message":"No Search Results."}]}',
      );
      expect(empty.noResults, isTrue);

      final fine = statusOf(
        '{"status_code":20000,"tasks":[{"status_code":20000,"result":[]}]}',
      );
      expect(fine.ok, isTrue);
      expect(fine.logLine, '');
    });

    test('8. SerpApi rows still parse while the fallback exists', () {
      final hits = exploreParseSerpApiOrganic(
        jsonDecode('''
{"organic_results": [
  {
    "title": "Fillers Dubai",
    "link": "https://skin111.com/price-list",
    "snippet": "Lip filler 1,900 AED",
    "displayed_link": "skin111.com > price-list"
  },
  {"snippet": ""}
]}
'''),
      );
      expect(hits, hasLength(1));
      expect(hits.first.link, 'https://skin111.com/price-list');
      expect(hits.first.displayedLink, 'skin111.com > price-list');
    });
  });
}
