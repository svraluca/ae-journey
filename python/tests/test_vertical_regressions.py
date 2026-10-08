"""Offline regressions for bounded provider search and country input handling."""
import os
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from price_fixtures import e, quote
import vertical_search as v


class CountryInputs(unittest.TestCase):
    def test_country_code_whitespace(self):
        self.assertEqual(v.CATALOG.country(' es ')['country_name'], 'Spain')

    def test_country_suffix_accepts_iso_codes_and_comma_names(self):
        for address, code in [
            ('Alajuela, CR', 'CR'),
            ('Seoul, Korea, Republic of', 'KR'),
            ('Istanbul, Turkey', 'TR'),
            ('Hanoi, Vietnam', 'VN'),
        ]:
            with self.subTest(address=address):
                self.assertEqual(v.CATALOG.country_from_address(address), code)
        self.assertEqual(v.CATALOG.country_from_address('Japan Clinic, Valencia'), '')
        self.assertEqual(v.CATALOG.country_from_address(''), '')


class ExaResponseShapes(unittest.IsolatedAsyncioTestCase):
    async def search(self, payload):
        original = httpx.AsyncClient
        transport = httpx.MockTransport(lambda request: httpx.Response(200, json=payload))
        with patch.dict(os.environ, {'EXA_API_KEY': 'offline-test-key'}), \
                patch.object(e, 'serp_cache_get', new=AsyncMock(return_value=None)), \
                patch.object(e, 'serp_cache_put', new=AsyncMock()), \
                patch.object(v.httpx, 'AsyncClient',
                             side_effect=lambda **kw: original(transport=transport, **kw)):
            provider = v.ExaClient(e)
            rows = await provider.search('official clinic fees Valencia', 'ES')
        return provider, rows

    async def test_nonobject_response_is_a_safe_provider_failure(self):
        provider, rows = await self.search([])
        self.assertEqual(rows, [])
        self.assertEqual(provider.last_error, 'exa_request_failed')

    async def test_nonlist_results_is_a_safe_provider_failure(self):
        for invalid in [None, {}, 'not a result list']:
            with self.subTest(results=invalid):
                provider, rows = await self.search({'results': invalid})
                self.assertEqual(rows, [])
                self.assertEqual(provider.last_error, 'exa_request_failed')

    async def test_malformed_items_do_not_discard_valid_urls(self):
        _, rows = await self.search({'results': [None, 123, 'bad', {},
            {'url': 'javascript:alert(1)'}, {'title': 'Aster', 'url': 'https://aster.example/prices'}]})
        self.assertEqual([row.url for row in rows], ['https://aster.example/prices'])

    async def test_provider_cannot_return_more_than_requested_eight_urls(self):
        _, rows = await self.search({'results': [
            {'url': f'https://clinic{n}.example/prices'} for n in range(12)
        ]})
        self.assertEqual(len(rows), 8)


class ProgressiveInputs(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.enterContext(patch.dict(os.environ, {
            'ENABLE_FIRESTORE': 'false', 'SERPER_API_KEY': '',
            'GOOGLE_PLACES_API_KEY': '', 'EXA_API_KEY': '',
            'ENABLE_DEEP_DISCOVERY': 'false', 'ENABLE_PROGRESSIVE_DISCOVERY': 'true',
        }))
        self.enterContext(patch.object(e, 'firestore_load_clinic_directory',
                                      new=AsyncMock(return_value=[])))
        self.enterContext(patch.object(e, 'firestore_upsert_clinic_directory', new=AsyncMock()))
        self.discover = self.enterContext(patch.object(e, 'discover', new=AsyncMock(
            side_effect=self.empty_response)))

    @staticmethod
    def empty_response(req):
        return e.DiscoverResponse(city=req.city, procedure=req.procedure, country_code='ES',
            queries=req.query_override or [], results=[], searched_urls=0, fetched_pages=0,
            diagnostics=e.DiscoveryDiagnostics(
                serper_requests_attempted=len(req.query_override or [])))

    async def run_search(self, stored=None, **kwargs):
        return await e.run_growth_search(
            city='Valencia', procedure='botox', country_code='ES', stored_pool=stored or [],
            desired_new=6, limit=8, debug=True, app_fast=True, serper_first=True, **kwargs)

    async def test_six_copies_of_one_clinic_do_not_satisfy_threshold(self):
        saved = quote(city='Valencia')
        _, _, enough = await self.run_search([saved.model_copy(deep=True) for _ in range(6)])
        self.assertFalse(enough)
        self.discover.assert_awaited_once()
        self.assertEqual(self.discover.await_args.args[0].progressive_stop_count, 5)

    async def test_excluded_saved_url_cannot_satisfy_threshold(self):
        stored = [quote(f'Clinic {n}', f'clinic{n}.example', city='Valencia') for n in range(6)]
        _, _, enough = await self.run_search(stored, excluded_source_urls=[stored[0].source_url])
        self.assertFalse(enough)
        self.discover.assert_awaited_once()
        req = self.discover.await_args.args[0]
        self.assertEqual(req.progressive_stop_count, 1)
        self.assertIn(stored[0].source_url, req.previously_fetched_urls)

    async def test_already_spent_requests_reduce_remaining_caller_budget(self):
        await self.run_search(serper_request_budget=3, initial_serper_requests=2)
        self.assertEqual(sum(call.args[0].serper_request_cap
                             for call in self.discover.await_args_list), 1)

    async def test_exhausted_caller_budget_does_not_add_search_requests(self):
        await self.run_search(serper_request_budget=2, initial_serper_requests=2)
        self.discover.assert_not_awaited()

    async def test_normalize_and_validate_known_hosts_before_capping(self):
        hosts = ['bad host'] * 6 + [' WWW.ASTER.EXAMPLE ', 'aster.example',
                                  'https://invalid.example/', 'cedar.example']
        await self.run_search(client_known_clinic_hosts=hosts)
        self.assertEqual(self.discover.await_args_list[0].args[0].progressive_stage,
                         'known_domains')
        self.assertEqual(self.discover.await_args_list[0].args[0].priority_site_hosts,
                         ['aster.example', 'cedar.example'])


if __name__ == '__main__':
    unittest.main()
