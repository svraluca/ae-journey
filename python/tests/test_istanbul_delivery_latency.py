"""Cheap source probes must not hold up new provider menus or lose partials."""
import asyncio
import os
import tempfile
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
        self.assertEqual(discover.await_args_list[1].args[0].progressive_stage,'marketplace')
        self.assertLessEqual(sum(c.args[0].serper_request_cap for c in discover.await_args_list),4)

    async def test_sparse_market_opens_provider_menus_before_slow_known_hosts(self):
        with patch.object(e,'discover',new=AsyncMock(side_effect=lambda r:self.response(r))) as discover:
            await self.run_search()
        self.assertEqual(discover.await_args_list[0].args[0].progressive_stage,'marketplace')
        self.assertEqual(discover.await_args_list[1].args[0].progressive_stage,'known_domains')

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
