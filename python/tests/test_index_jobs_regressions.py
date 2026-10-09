"""Read-only index and four-card API regressions with real local job state."""
import asyncio
import sqlite3
import tempfile
import threading
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, patch

from pydantic import ValidationError
from price_fixtures import e, quote
from explore_index_jobs import IndexJobs, JobStore, MarketRequest


class IndexPriceTrust(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.service = IndexJobs(e, str(Path(directory.name) / 'jobs.sqlite3'))
        self.req = MarketRequest(city='Springfield', procedure='botox', country_code='US')
        self.row = quote(city='Springfield', origin='live_search').model_copy(
            update={'source_location_text': 'Our clinic in Springfield'})
        self.market = self.service.key(self.req)
        self.service.store.source_check(self.market, self.row.source_url, 'no_price')

    async def test_index_read_cannot_restore_a_quarantined_persisted_live_row(self):
        with patch.object(e, 'firestore_load_results', new=AsyncMock(return_value=[])), \
                patch.object(e, 'firestore_enabled', return_value=False), \
                patch.object(self.service.store, 'latest_results', return_value=[self.row.model_dump()]):
            indexed = await self.service.index(self.req)
        self.assertEqual(indexed['display_results'], [])
        self.assertEqual(self.service.store.rejected_sources(self.market),
                         {self.row.source_url: 'no_price'})

    async def test_fresh_verified_discovery_can_clear_rejection_in_same_country(self):
        rows = self.service.safe_rows([self.row], self.req.city, self.req.procedure,
            country_code=self.req.country_code, recover_quarantined=True)
        self.assertEqual([row.source_url for row in rows], [self.row.source_url])
        self.assertEqual(self.service.store.rejected_sources(self.market), {})

    async def test_other_country_rejection_does_not_hide_this_market(self):
        rows = self.service.safe_rows([self.row], self.req.city, self.req.procedure,
                                     country_code='CA')
        self.assertEqual(len(rows), 1)
        self.assertIn(self.row.source_url, self.service.store.rejected_sources(self.market))

    async def test_publisher_and_cached_cost_guide_flags_cannot_enter_index(self):
        for url in ['https://www.elle.com/es/belleza/a123456/arrugas/',
                    'https://aster.example/precios-madrid-guia-doctor/']:
            row = self.row.model_copy(update={'source_url': url,
                'source_host': e.host_of(url), 'official_website': url})
            self.assertEqual(self.service.safe_rows([row], self.req.city,
                self.req.procedure, country_code=self.req.country_code), [])

    async def test_refresh_quarantines_an_explicit_nonownership_disclaimer(self):
        html = ('<html><title>Aster Medical Clinic Springfield</title>'
                '<p>Los precios son indicativos de la media en España. '
                'No representan los precios aplicados en la consulta.</p></html>')
        with patch.object(self.service, 'index', new=AsyncMock(return_value={
                'display_results': [self.row.model_dump()]})), \
                patch.object(self.service, 'static_html', new=AsyncMock(return_value=html)):
            result = await self.service.refresh_known(self.req)
        self.assertEqual(result['display_results'], [])
        self.assertIn(self.row.source_url, result['invalidated_source_urls'])
        self.assertEqual(self.service.store.rejected_sources(self.market)[self.row.source_url],
                         'page_disclaims_clinic_prices')

    async def test_known_page_refresh_replaces_the_old_amount_with_live_evidence(self):
        html = ('<html><title>Aster Medical Clinic Springfield</title>'
                '<h1>Botox prices</h1><table><tr><td>Botox 3 areas</td>'
                '<td><del>$350</del> <ins>$275</ins></td></tr></table>'
                '<footer>Our clinic in Springfield. Book an appointment.</footer></html>')
        with patch.object(self.service, 'index', new=AsyncMock(return_value={
                'display_results': [self.row.model_dump()]})), \
                patch.object(self.service, 'static_html', new=AsyncMock(return_value=html)), \
                patch.object(e, 'firestore_upsert_results', new=AsyncMock()):
            result = await self.service.refresh_known(self.req)
        self.assertEqual([row['price_min'] for row in result['display_results']], [275])
        self.assertIn('275', result['display_results'][0]['raw_evidence'])
        self.assertNotIn('350', result['display_results'][0]['raw_evidence'])


class FourCardRequests(unittest.TestCase):
    def test_compare_defaults_and_explicit_limits_never_allow_a_fifth_card(self):
        for model in [MarketRequest, e.HybridDiscoverRequest]:
            with self.subTest(model=model.__name__):
                self.assertEqual(model(city='Valencia', procedure='botox').display_limit, 4)
                for invalid in [0, 5, 8]:
                    with self.assertRaises(ValidationError):
                        model(city='Valencia', procedure='botox', display_limit=invalid)


class SQLiteResponsiveness(unittest.IsolatedAsyncioTestCase):
    async def test_job_poll_does_not_wait_for_two_busy_validation_batches(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        service = IndexJobs(e, str(Path(directory.name) / 'jobs.sqlite3'))
        req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
        job = service.store.enqueue(service.key(req), req.model_dump())
        both_started = threading.Barrier(3)
        release = threading.Event()

        def blocked_validation(*args, **kwargs):
            both_started.wait(timeout=2)
            release.wait(timeout=2)
            return []

        with patch.object(service, 'safe_rows', side_effect=blocked_validation):
            batches = [asyncio.create_task(service.validated_rows([], req)) for _ in range(2)]
            try:
                await asyncio.to_thread(both_started.wait, 2)
                polled = await asyncio.wait_for(service.store_call('get', job['job_id']), timeout=0.5)
                self.assertEqual(polled['status'], 'queued')
                self.assertFalse(release.is_set())
            finally:
                release.set()
                await asyncio.gather(*batches)

    async def assert_loop_survives_sqlite_lock(self, operation, path):
        # A real competing SQLite transaction keeps the operation waiting.
        # The lock holder releases immediately after an event-loop heartbeat;
        # its timeout bounds this test when the old code blocks that heartbeat.
        lock = sqlite3.connect(path, check_same_thread=False)
        self.addCleanup(lock.close)
        lock.execute('BEGIN EXCLUSIVE')
        heartbeat = threading.Event()
        observations = []

        def release_lock():
            observations.append(heartbeat.wait(timeout=0.5))
            lock.rollback()

        holder = threading.Thread(target=release_lock)
        holder.start()
        timer = asyncio.get_running_loop().call_later(0.02, heartbeat.set)
        try:
            result = await operation()
        finally:
            timer.cancel()
            heartbeat.set()
            await asyncio.to_thread(holder.join)
        self.assertEqual(observations, [True], 'SQLite blocked other API requests')
        return result

    async def test_index_quarantine_lookup_does_not_block_the_api_loop(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        service = IndexJobs(e, str(Path(directory.name) / 'jobs.sqlite3'))
        service._store = JobStore(service.path)
        req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
        row = quote(city='Madrid')
        with patch.object(e, 'firestore_load_results', new=AsyncMock(return_value=[row])), \
                patch.object(e, 'firestore_enabled', return_value=True):
            indexed = await self.assert_loop_survives_sqlite_lock(
                lambda: service.index(req), service.path)
        self.assertEqual(indexed['verified_count'], 1)

    async def test_first_queue_initialization_does_not_block_the_api_loop(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = str(Path(directory.name) / 'jobs.sqlite3')
        JobStore(path)
        service = IndexJobs(e, path)
        req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
        self.addAsyncCleanup(service.stop)
        async def hold_worker():
            # Queue acceptance is under test; discovery must stay offline.
            await asyncio.Event().wait()

        with patch.object(service, 'run', side_effect=hold_worker):
            queued = await self.assert_loop_survives_sqlite_lock(
                lambda: service.enqueue(req), path)
        self.assertTrue(queued['enqueued'])
        self.assertEqual(queued['status'], 'queued')
        await service.stop()


class DisplayAndRotationPools(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.service = IndexJobs(e, str(Path(directory.name) / 'jobs.sqlite3'))
        self.req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
        self.rows = [quote(name=f'Aster Medical Clinic {i}', host=f'aster-{i}.example', city='Madrid')
                     for i in range(7)]
        self.payload = [row.model_dump(mode='json') for row in self.rows]

    async def test_index_caps_display_but_preserves_seven_rotation_candidates(self):
        with patch.object(e, 'firestore_load_results', new=AsyncMock(return_value=self.rows)), \
                patch.object(e, 'firestore_enabled', return_value=True):
            result = await self.service.index(self.req)
        self.assertEqual(len(result['display_results']), 4)
        self.assertEqual(result['displayed_count'], 4)
        self.assertEqual(len(result['candidate_results']), 7)
        self.assertEqual(result['verified_count'], 7)

    async def test_partial_completed_and_reused_tickets_never_expose_a_fifth_display_slot(self):
        store = self.service.store
        queued = store.enqueue(self.service.key(self.req), self.req.model_dump())
        job = store.claim()
        for size in [2, 5, 7]:
            store.update_progress(job, self.payload[:size])
            partial = store.get(queued['job_id'])
            self.assertEqual(len(partial['display_results']), min(4, size))
            self.assertEqual(len(partial['candidate_results']), size)
        store.finish(job, self.payload)
        for result in [store.get(job['job_id']),
                       store.enqueue(self.service.key(self.req), self.req.model_dump())]:
            self.assertEqual(result['status'], 'completed')
            self.assertEqual(len(result['display_results']), 4)
            self.assertEqual(len(result['candidate_results']), 7)
        self.assertEqual(len(store.latest_results(self.service.key(self.req))), 7)

    async def test_worker_failure_retains_candidates_beyond_the_four_display_slots(self):
        store = self.service.store
        store.enqueue(self.service.key(self.req), self.req.model_dump())
        job = store.claim()
        store.update_progress(job, self.payload)
        with patch.object(self.service, 'discover_with_progress',
                          new=AsyncMock(side_effect=asyncio.TimeoutError)):
            await self.service.run_one(job)
        result = store.get(job['job_id'])
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(len(result['display_results']), 4)
        self.assertEqual(result['candidate_results'], self.payload)
