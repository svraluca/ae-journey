"""Cheap source probes must not hold up new provider menus or lose partials."""
import asyncio
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote
import vertical_search as v
from explore_index_jobs import IndexJobs, JobStore, MarketRequest, DisplayFeedbackRequest


class MenuScope(unittest.TestCase):
    url = 'https://us-uk.bookimed.com/clinic/aster-clinic/procedure=chemical-peel/'

    def evidence(self, amount=700, title='Chemical Peel'):
        return e.ExtractedEvidence(raw_procedure_text=title,
            raw_price_text=f'${amount}', raw_evidence=f'{title} ${amount}',
            price_min=amount, currency='USD', source_url=self.url,
            extraction_method='html_table')

    def page(self, description):
        return ('<h1>Chemical Peel in Aster Clinic</h1>'
                '<div class="clinic-page__description">'+description+'</div>')

    def test_unexplained_generic_amount_cannot_choose_between_options(self):
        html = self.page('Our chemical peel package costs $800. The standard chemical '
                         'peel option costs $300. Both options are available.')
        row = self.evidence()
        self.assertTrue(e.marketplace_menu_scope_conflict(row, html))
        self.assertEqual(e.validate_evidence(row, e.page_text(html), html, 'Istanbul')[3],
                         'ambiguous_marketplace_service_scope')

    def test_matching_price_and_explicit_scope_remain_eligible(self):
        html = self.page('Our chemical peel package costs $800. The standard chemical '
                         'peel option costs $300. Both options are available.')
        self.assertFalse(e.marketplace_menu_scope_conflict(self.evidence(300), html))
        self.assertFalse(e.marketplace_menu_scope_conflict(
            self.evidence(700, 'Chemical Peel with Dermamelan Mask'), html))

    def test_consultation_or_travel_prices_do_not_create_option_conflicts(self):
        html = self.page('Chemical Peel costs $700. Consultation $50. Hotel $90.')
        self.assertFalse(e.marketplace_menu_scope_conflict(self.evidence(), html))

    def test_duplicate_treatment_tabs_do_not_consume_other_clinics_slots(self):
        urls = [f'https://us-uk.bookimed.com/clinic/provider-{n}/' for n in range(8)]
        urls = [urls[0], urls[0]+'procedure=botox-injections/',
                urls[0]+'procedure=fillers-injection/', *urls[1:]]
        req = e.DiscoverRequest(city='Istanbul', procedure='filler',
            hybrid_interactive=True, progressive_stage='marketplace')
        hits = [e.SearchHit(title='Istanbul clinic', url=u) for u in urls]
        selected, counts = e.select_discovery_work(hits, req, lambda h: h.url)
        providers = {e.bookimed_treatment_profile_url(h.url, req.procedure).split('/procedure=')[0]
                     for h in selected}
        self.assertEqual(counts['marketplace'], 8)
        self.assertEqual(len(providers), 8)

    def test_saved_source_lane_also_counts_each_marketplace_provider_once(self):
        root = 'https://us-uk.bookimed.com/clinic/aster-clinic/'
        urls = [root, root+'procedure=botox-injections/',
                'https://us-uk.bookimed.com/clinic/cedar-clinic/']
        req = e.DiscoverRequest(city='Istanbul',procedure='botox',
            search_mode='site_focus',priority_site_urls=urls,hybrid_interactive=True)
        selected, _ = e.select_discovery_work(
            [e.SearchHit(title='Istanbul clinic',url=u) for u in urls],req,lambda h:h.url)
        self.assertEqual(len(selected),2)

    def test_saved_tariff_order_survives_keyword_rich_marketplace_urls(self):
        urls = ['https://aster.example/pricing', 'https://cedar.example/package/',
                'https://us-uk.bookimed.com/clinic/birch-clinic/procedure=breast-augmentation/']
        req = e.DiscoverRequest(city='Izmir', procedure='breast_augmentation',
            search_mode='site_focus', priority_site_urls=urls, hybrid_interactive=True)
        hits = [e.SearchHit(title='Clinic', url=url) for url in reversed(urls)]
        selected, _ = e.select_discovery_work(hits, req, lambda h: h.url)
        self.assertEqual([hit.url for hit in selected], urls)


class FastSourcePolicy(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.enterContext(patch.dict(os.environ, {'ENABLE_FIRESTORE':'false',
            'ENABLE_DEEP_DISCOVERY':'true', 'ENABLE_MARKETPLACE_RESCUE':'true',
            'ENABLE_EXA_RESCUE':'false', 'GOOGLE_PLACES_API_KEY':''}))
        self.enterContext(patch.object(e.GooglePlacesClient, 'configured', False))
        self.enterContext(patch.object(e, 'firestore_load_clinic_directory',
            new=AsyncMock(return_value=[e.SearchHit(title='Aster',url='https://aster.example/')])))
        self.enterContext(patch.object(e, 'firestore_upsert_clinic_directory', new=AsyncMock()))

    def response(self, req, rows=None):
        return e.DiscoverResponse(city=req.city, procedure=req.procedure,
            country_code='TR', queries=req.query_override or [], results=rows or [],
            searched_urls=0, fetched_pages=0, diagnostics=e.DiscoveryDiagnostics(
                serper_requests_attempted=len(req.query_override or [])))

    async def run_search(self, **kwargs):
        return await v.run_progressive(e, city='Istanbul',procedure='filler',
            country_code='TR',stored_pool=[],desired_new=6,limit=8,debug=True,**kwargs)

    async def test_actual_saved_source_is_rechecked_before_speculative_hosts(self):
        url='https://us-uk.bookimed.com/clinic/aster-clinic/procedure=fillers-injection/'
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda r:self.response(r))) as discover:
            await self.run_search(saved_source_urls=[url])
        first=discover.await_args_list[0].args[0]
        self.assertEqual(first.progressive_stage,'saved_sources')
        self.assertEqual(first.priority_site_urls,[url])
        self.assertFalse(first.enable_serper)
        self.assertEqual(discover.await_args_list[1].args[0].progressive_stage,'primary')
        self.assertEqual(discover.await_args_list[2].args[0].progressive_stage,'marketplace')
        self.assertLessEqual(sum(c.args[0].serper_request_cap for c in discover.await_args_list),4)

    async def test_sparse_market_opens_provider_menus_before_slow_known_hosts(self):
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda r:self.response(r))) as discover:
            await self.run_search()
        self.assertEqual(discover.await_args_list[0].args[0].progressive_stage,'primary')
        self.assertEqual(discover.await_args_list[1].args[0].progressive_stage,'marketplace')
        self.assertEqual(discover.await_args_list[2].args[0].progressive_stage,'known_domains')

    async def test_source_probe_deadline_preserves_a_card_before_fallback_search(self):
        row=quote(amount=350,city='Istanbul').model_copy(update={
            'currency':'EUR','procedure_canonical':'filler',
            'procedure_display_name':'Dermal filler','procedure_detail':'',
            'raw_procedure_text':'Dermal filler','raw_price_text':'350 EUR',
            'raw_evidence':'Dermal filler 350 EUR'})
        events=asyncio.Queue();token=e._hybrid_progress.set(events)
        async def discover(req):
            if req.progressive_stage=='saved_sources':
                await e._emit_hybrid_partial([e._display_from_live(row,'live_search')])
                await e._emit_hybrid_status(fetched_pages=1)
                await asyncio.Event().wait()
            return self.response(req)
        try:
            with patch.object(v,'SAVED_SOURCE_SECONDS',.05),patch.object(e,'discover',side_effect=discover):
                responses,rows,_=await asyncio.wait_for(self.run_search(
                    saved_source_urls=[row.source_url]),1)
        finally:
            e._hybrid_progress.reset(token)
        self.assertEqual(len(rows),1)
        self.assertEqual(responses[0].fetched_pages,1)
        self.assertTrue(any(event.get('progress',{}).get('stage_timed_out')
            for event in list(events._queue)))

    async def test_source_probe_deadline_keeps_unfinished_urls_for_next_stage(self):
        pending = 'https://cedar.example/prices/'
        calls = []
        async def discover(req):
            calls.append(req)
            if req.progressive_stage == 'saved_sources':
                await asyncio.Event().wait()
            return self.response(req)
        with patch.object(v, 'SAVED_SOURCE_SECONDS', .02), \
             patch.object(e, 'discover', side_effect=discover):
            await asyncio.wait_for(self.run_search(saved_source_urls=[pending]), 1)
        self.assertIn(pending, calls[1].priority_site_urls)
        self.assertEqual(calls[1].progressive_stage, 'primary')

    async def test_old_local_database_price_passes_only_its_url_to_discovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            service=IndexJobs(e,str(Path(tmp)/'jobs.sqlite3'))
            req=MarketRequest(city='Istanbul',procedure='botox',country_code='TR')
            old=quote(city='Istanbul').model_copy(update={'price_extract_revision':'e28'})
            prior=service.store.enqueue(service.key(req),req.model_dump())
            prior=service.store.claim()
            service.store.finish(prior,[old.model_dump(mode='json')])
            job=service.store.enqueue(service.key(req),req.model_dump(),cooldown=0)
            job=service.store.claim()
            captured=[]
            async def hybrid(request):
                captured.append(request)
                return e.HybridDiscoverResponse(city='Istanbul',procedure='botox')
            with patch.object(e,'_discover_hybrid_impl',side_effect=hybrid):
                result=await service.discover_with_progress(job,req)
            self.assertEqual(captured[0].saved_source_urls,[old.source_url])
            self.assertEqual(result.display_results,[])
            self.assertEqual(result.candidate_results,[])


class HybridCompletion(unittest.IsolatedAsyncioTestCase):
    async def test_later_round_keeps_four_earlier_cards_in_every_partial(self):
        rows = [e.ClinicPriceResult.model_validate(quote(name=name + ' Medical Clinic',
            host=name.lower() + '.example').model_dump())
            for name in ['Aster', 'Cedar', 'Birch', 'Oak', 'Pine']]
        queue = asyncio.Queue()
        token = e._hybrid_progress.set(queue)
        async def discover(req):
            found = rows[:4] if req.progressive_stage == 'saved_sources' else (
                rows[4:] if req.progressive_stage == 'primary' else [])
            await e._emit_hybrid_partial([e._display_from_live(r, 'live_search') for r in found])
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, queries=[],
                results=found, searched_urls=0, fetched_pages=len(found),
                diagnostics=e.DiscoveryDiagnostics())
        try:
            with patch.dict(os.environ, {'ENABLE_FIRESTORE':'false',
                    'GOOGLE_PLACES_API_KEY':'', 'ENABLE_MULTILINGUAL_SEARCH':'false'}), \
                 patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
                 patch.object(e, 'firestore_upsert_clinic_directory', new=AsyncMock()), \
                 patch.object(e, 'discover', side_effect=discover):
                await v.run_progressive(e, city='Abu Dhabi', procedure='botox', country_code='AE',
                    stored_pool=[], desired_new=6, limit=8, debug=True,
                    saved_source_urls=[r.source_url for r in rows[:4]])
        finally:
            e._hybrid_progress.reset(token)
        counts = [len(event['display_results']) for event in list(queue._queue)
                  if event.get('event') == 'partial']
        self.assertGreater(len(counts), 1)
        self.assertEqual(set(counts), {4})

    async def test_six_progressive_stages_keep_verified_cards_and_error_labels(self):
        stages = ['saved_sources', 'primary', 'marketplace', 'known_domains', 'local', 'places']
        responses = [e.DiscoverResponse(city='Abu Dhabi', procedure='botox', queries=[],
            results=[], searched_urls=0, fetched_pages=0,
            search_errors=[stage + ' unavailable'],
            diagnostics=e.DiscoveryDiagnostics(progressive_stage=stage)) for stage in stages]
        row = e.ClinicPriceResult.model_validate(quote().model_dump())
        with patch.dict(os.environ, {'ENABLE_FIRESTORE':'false', 'ENABLE_APP_BRIDGE':'false'}), \
             patch.object(e, 'firestore_is_available', new=AsyncMock(return_value=False)), \
             patch.object(e, 'run_growth_search', new=AsyncMock(return_value=(responses, [row], False))):
            result = await e._discover_hybrid_impl(e.HybridDiscoverRequest(
                city='Abu Dhabi', procedure='botox', country_code='AE',
                stream_progress=True, serper_first=True, debug=True,
                force_full_growth_search=True, economical_growth=True))
        self.assertEqual(len(result.display_results), 1)
        self.assertEqual(set(result.growth_diagnostics), set(stages))
        self.assertEqual(set(result.growth_search_errors), set(stages))

    async def test_marketplace_identity_parse_leaves_event_loop_available(self):
        released = threading.Event()
        observed = []
        def profile(*args):
            observed.append(released.wait(timeout=1))
            return 'Aster Medical Clinic'
        asyncio.get_running_loop().call_later(.01, released.set)
        with patch.object(e, 'marketplace_profile_name', side_effect=profile):
            name = await e.resolve_clinic_name('<title>Aster Medical Clinic</title>',
                'https://us-uk.bookimed.com/clinic/aster-clinic/', city='Izmir')
        self.assertEqual(name, 'Aster Medical Clinic')
        self.assertEqual(observed, [True])


class VisibleTextReuse(unittest.TestCase):
    def test_repeated_consumers_reuse_text_but_changed_html_keeps_new_fee_and_footer(self):
        token = e._hybrid_parse_memo.set({'__city__':'Izmir'})
        try:
            html = '<p>Botox €300</p><div>' + ('clinic information ' * 4000) + '</div><footer>Izmir</footer>'
            with patch.object(e, 'BeautifulSoup', wraps=e.BeautifulSoup) as parse:
                first = e.page_text(html)
                self.assertEqual(e.page_text(html), first)
                updated = e.page_text(html.replace('€300', '€350'))
            self.assertIn('Izmir', first)
            self.assertIn('€350', updated)
            self.assertNotIn('€300', updated)
            self.assertEqual(parse.call_count, 2)
        finally:
            e._hybrid_parse_memo.reset(token)


class DisplayAcknowledgement(unittest.TestCase):
    def test_first_card_is_ready_while_collection_keeps_foreground_priority(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=JobStore(str(Path(tmp)/'jobs.sqlite3'))
            job=store.enqueue('Istanbul|filler',{'client_id':'phone','focus_seq':1,
                'mode':'foreground','display_limit':4})
            ready=store.acknowledge_display(job['job_id'],DisplayFeedbackRequest(
                client_id='phone',focus_seq=1,display_seq=1,displayed_count=1))
            self.assertTrue(ready['display_ready']);self.assertFalse(ready['display_filled'])
            self.assertEqual(store.get(job['job_id'])['priority'],100)
            filled=store.acknowledge_display(job['job_id'],DisplayFeedbackRequest(
                client_id='phone',focus_seq=1,display_seq=2,displayed_count=4))
            self.assertTrue(filled['display_filled'])
            self.assertEqual(store.get(job['job_id'])['priority'],70)


if __name__ == '__main__':
    unittest.main()
