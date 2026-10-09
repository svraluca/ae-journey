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


class FourCardRequests(unittest.TestCase):
    def test_compare_defaults_and_explicit_limits_never_allow_a_fifth_card(self):
        for model in [MarketRequest, e.HybridDiscoverRequest]:
            with self.subTest(model=model.__name__):
                self.assertEqual(model(city='Valencia', procedure='botox').display_limit, 4)
                for invalid in [0, 5, 8]:
                    with self.assertRaises(ValidationError):
                        model(city='Valencia', procedure='botox', display_limit=invalid)


class SQLiteResponsiveness(unittest.IsolatedAsyncioTestCase):
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
