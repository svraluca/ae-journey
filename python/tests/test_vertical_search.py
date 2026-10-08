"""Offline policy + real verifier integration; provider calls are mocked."""
import asyncio
import json
import os
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, patch

import httpx

from price_fixtures import e, quote
import vertical_search as v


class Configuration(unittest.TestCase):
    def test_catalogs_load_once_and_aliases_are_selected(self):
        with patch.object(Path, 'read_text', side_effect=AssertionError('request reopened config')):
            self.assertEqual(len(v.CATALOG.countries), 249)
            self.assertEqual(len(v.CATALOG.procedures), 151)
            self.assertEqual(v.CATALOG.key('Daxxify'), 'botulinum_toxin')
            self.assertEqual(v.CATALOG.key('Morpheus8'), 'rf_microneedling')
            self.assertEqual(e.canonicalize_procedure('Morpheus8'), 'rf_microneedling')
            self.assertTrue(v.CATALOG.queries('botox', 'Madrid', 'ES', e.local_terms_for))

    def test_query_budgets_and_natural_local_terms(self):
        for procedure in ['hair_transplant', 'chemical_peel', 'breast_augmentation']:
            self.assertEqual(v.CATALOG.queries(procedure, 'Valencia', 'ES', e.local_terms_for)[0],
                             procedure.replace('_', ' ')+' Valencia price')
        for cc, city, word in [('TR', 'Izmir', 'botoks'), ('AE', 'Sharjah', 'بوتوكس'),
                               ('RO', 'Timisoara', 'botox')]:
            primary = v.CATALOG.queries('botox', city, cc, e.local_terms_for)
            local = v.CATALOG.queries('botox', city, cc, e.local_terms_for, stage='local')
            self.assertLessEqual(len(primary), 2)
            self.assertLessEqual(len(local), 2)
            self.assertIn(word, local[0])
            self.assertTrue(all(city in q for q in primary+local))
            self.assertFalse(any('filler' in q.lower() or 'Dysport' in q for q in primary+local))

    def test_currency_config_never_requires_official_currency(self):
        for currency, text in [('EUR', '220 EUR'), ('USD', '240 USD'), ('GBP', '200 GBP'),
                               ('AED', '900 AED'), ('JPY', '40000 JPY')]:
            html = f'<title>Aster Clinic</title><h2>Botox</h2><p>Our Botox treatment {text}</p><footer>Izmir</footer>'
            found = [r for r in e.extract_price_evidence(html, 'https://aster.example/prices/', 'botox')
                     if e.validate_evidence(r, e.page_text(html), html, 'Izmir')[0]]
            self.assertTrue(any(r.currency == currency for r in found), currency)
        self.assertEqual(v.CATALOG.currency_aliases()['TL'], 'TRY')
        self.assertEqual(v.CATALOG.country('TR')['official_currency'], 'TRY')

    def test_negative_ttls_and_market_scoping(self):
        clock = [0]
        cache = v.ReasonCache(lambda: clock[0], capacity=3)
        cache.put(('Valencia','botox','url'), 'blocked')
        cache.put(('Valencia','filler','url'), 'directory')
        clock[0] = 301
        self.assertEqual(cache.get(('Valencia','botox','url')), '')
        self.assertEqual(cache.get(('Valencia','filler','url')), 'directory')
        self.assertEqual(cache.get(('Madrid','filler','url')), '')


class ProgressivePolicy(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.enterContext(patch.dict(os.environ, {'ENABLE_FIRESTORE':'false',
            'SERPER_API_KEY':'', 'GOOGLE_PLACES_API_KEY':'', 'EXA_API_KEY':'',
            'ENABLE_EXA_RESCUE':'true', 'ENABLE_DEEP_DISCOVERY':'true',
            'ENABLE_MULTILINGUAL_SEARCH':'true', 'ENABLE_PROGRESSIVE_DISCOVERY':'true'}))
        self.directory = self.enterContext(patch.object(e, 'firestore_load_clinic_directory',
                                                       new=AsyncMock(return_value=[])))
        self.learned = self.enterContext(patch.object(e, 'firestore_upsert_clinic_directory',
                                                      new=AsyncMock(return_value=0)))
        self.exa = self.enterContext(patch.object(v.ExaClient, 'search', new=AsyncMock(return_value=[])))
        self.places = self.enterContext(patch.object(e.GooglePlacesClient, 'discover_city_clinic_websites',
                                                    new=AsyncMock(return_value=[])))
        v.REJECTIONS.rows.clear()

    def response(self, req, count=0):
        names = ['Aster', 'Cedar', 'Birch', 'Elm', 'Oak', 'Maple'][:count]
        return e.DiscoverResponse(city=req.city, procedure=req.procedure, country_code='ES',
            queries=req.query_override or [], results=[quote(name+' Medical Clinic',
                name.lower()+'.example', city=req.city, age=0) for name in names],
            searched_urls=count, fetched_pages=count, diagnostics=e.DiscoveryDiagnostics(
                serper_requests_attempted=len(req.query_override or [])))

    async def run_search(self, stored=None, **kwargs):
        return await e.run_growth_search(city='Valencia', procedure='botox', country_code='ES',
            stored_pool=stored or [], desired_new=6, limit=8, debug=True,
            app_fast=True, serper_first=True, **kwargs)

    async def test_six_saved_skip_every_provider(self):
        req=e.DiscoverRequest(city='Valencia',procedure='botox')
        stored=self.response(req,6).results
        with patch.object(e,'discover',new=AsyncMock()) as discover:
            result=await self.run_search(stored)
        discover.assert_not_awaited();self.exa.assert_not_awaited();self.places.assert_not_awaited()
        self.assertTrue(result[2])

    async def test_primary_six_stops_before_local_exa_places(self):
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda req:self.response(req,6))) as discover:
            _,rows,_=await self.run_search()
        self.assertEqual(len(rows),6)
        self.learned.assert_awaited_once()
        self.assertEqual(len(self.learned.await_args.args[2]), 6)
        self.assertTrue(all('botox' in hit.directory_capabilities for hit in self.learned.await_args.args[2]))
        self.assertEqual([call.args[0].progressive_stage for call in discover.await_args_list],['primary'])
        self.exa.assert_not_awaited();self.places.assert_not_awaited()

    async def test_insufficient_switches_from_primary_to_local_to_exa(self):
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda req:self.response(req))) as discover:
            await self.run_search()
        stages=[call.args[0] for call in discover.await_args_list]
        self.assertEqual([r.progressive_stage for r in stages],['primary','local'])
        self.assertEqual(sum(r.serper_request_cap for r in stages),4)
        self.exa.assert_awaited_once()
        self.assertNotIn(self.exa.await_args.args[0],stages[0].query_override)

    async def test_known_domain_reused_before_paid_search(self):
        self.directory.return_value=[e.SearchHit(title='Aster',url='https://aster.example/')]
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda req:self.response(req,6))) as discover:
            await self.run_search()
        req=discover.await_args.args[0]
        self.assertEqual(req.progressive_stage,'known_domains')
        self.assertFalse(req.enable_serper)
        self.assertEqual(req.priority_site_hosts,['aster.example'])
        self.exa.assert_not_awaited()

    async def test_background_pass_can_continue_after_six_are_stored(self):
        req=e.DiscoverRequest(city='Valencia',procedure='botox')
        stored=self.response(req,6).results
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda req:self.response(req))) as discover:
            await self.run_search(stored, background_collection=True)
        self.assertTrue(discover.await_count)
        self.assertTrue(all(call.args[0].progressive_stop_count == 6 for call in discover.await_args_list))

    async def test_arbitrary_city_country_lookup_cached(self):
        v.CITY_COUNTRIES.rows.clear()
        with patch.object(e.GooglePlacesClient,'configured',True), patch.object(
                e.GooglePlacesClient,'resolve_country_for_city',new=AsyncMock(return_value='JP')) as resolve:
            self.assertEqual(await v.resolve_country(e,'Fukuoka'),'JP')
            self.assertEqual(await v.resolve_country(e,'Fukuoka'),'JP')
            self.assertEqual(resolve.await_count,1)
        self.assertEqual(v.CATALOG.country_from_address('Fukuoka, Japan'),'JP')

    async def test_progressive_round_does_not_add_hidden_searches(self):
        with patch.object(e.SerperClient,'search',new=AsyncMock(return_value=[])) as search:
            await e.discover(e.DiscoverRequest(city='Valencia',procedure='botox',country_code='ES',
                search_mode='expanded',progressive_stage='primary',query_override=['botox Valencia price'],
                serper_request_cap=1,skip_places_bootstrap=True,hybrid_interactive=True,full_growth=True))
        self.assertEqual(search.await_count,1)


class ExaAdapter(unittest.IsolatedAsyncioTestCase):
    async def test_url_only_request_is_cached_and_failure_is_safe(self):
        saved=[]
        async def get(*args):return saved[0] if saved else None
        async def put(query,num,page,rows):saved.append(rows);return True
        requests=[]
        def handle(request):
            requests.append(request)
            return httpx.Response(200,json={'results':[{'title':'Aster','url':'https://aster.example/prices'}]})
        original=httpx.AsyncClient
        with patch.dict(os.environ,{'EXA_API_KEY':'test'}), patch.object(e,'serp_cache_get',side_effect=get), \
             patch.object(e,'serp_cache_put',side_effect=put), patch.object(v.httpx,'AsyncClient',
                 side_effect=lambda **kw:original(transport=httpx.MockTransport(handle),**kw)):
            provider=v.ExaClient(e)
            first=await provider.search('official clinic fees Valencia','ES')
            second=await provider.search('official clinic fees Valencia','ES')
        self.assertEqual(first,second);self.assertEqual(provider.calls,1)
        self.assertEqual(len(requests),1)
        self.assertNotIn('contents',json.loads(requests[0].content))
        with patch.dict(os.environ,{'EXA_API_KEY':'test'}), \
             patch.object(e,'serp_cache_get',new=AsyncMock(return_value=None)), \
             patch.object(v.httpx.AsyncClient,'post',new=AsyncMock(side_effect=httpx.ConnectError('offline'))):
            provider=v.ExaClient(e)
            self.assertEqual(await provider.search('query','ES'),[])
            self.assertEqual(provider.calls,1)
            self.assertEqual(provider.last_error,'exa_request_failed')
