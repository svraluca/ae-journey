"""Verified partials survive unfinished searches; conversions keep provenance."""
import tempfile
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, patch
from price_fixtures import e, quote
from explore_index_jobs import IndexJobs, MarketRequest


class PartialIndex(unittest.IsolatedAsyncioTestCase):
    async def test_running_then_paused_job_is_readable_before_completion(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = IndexJobs(e, str(Path(tmp) / 'jobs.sqlite3'))
            req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
            service.store.enqueue(service.key(req), req.model_dump())
            job = service.store.claim()
            good = quote(city='Madrid', amount=330)
            retail = good.model_copy(update={'procedure_canonical': 'chemical_peel',
                'raw_procedure_text': 'PRX-T33 bottle 4 ml',
                'raw_evidence': 'PRX-T33 bottle 4 ml | 85 EUR',
                'price_min': 85, 'currency': 'EUR'})
            service.store.update_progress(job, [good.model_dump(), retail.model_dump()])
            with patch.object(e, 'firestore_enabled', return_value=False), \
                 patch.object(e, 'firestore_load_results', new=AsyncMock(return_value=[])):
                result = await service.index(req)
                self.assertEqual(result['display_results'][0]['price_min'], 330)
                self.assertEqual(result['verified_count'], 1)
                service.store.release(job)
                result = await service.index(req)
                self.assertEqual(result['verified_count'], 1)
                resumed = service.store.claim()
                service.store.finish(resumed, [good.model_dump()])
                peel_req = req.model_copy(update={'procedure': 'chemical_peel'})
                service.store.enqueue(service.key(peel_req), peel_req.model_dump())
                peel_job = service.store.claim()
                service.store.update_progress(peel_job, [retail.model_dump()])
                peel = await service.index(peel_req)
                self.assertEqual(peel['verified_count'], 0)

    async def test_local_partial_and_firestore_are_merged_without_cross_city_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = IndexJobs(e, str(Path(tmp) / 'jobs.sqlite3'))
            req = MarketRequest(city='Madrid', procedure='botox', country_code='ES')
            service.store.enqueue(service.key(req), req.model_dump())
            job = service.store.claim()
            service.store.update_progress(job, [quote(city='Madrid').model_dump()])
            other = quote(name='Cedar Medical Clinic', host='cedar.example', city='Madrid')
            wrong = quote(name='Birch Medical Clinic', host='birch.example', city='Valencia')
            with patch.object(e, 'firestore_enabled', return_value=True), \
                 patch.object(e, 'firestore_load_results', new=AsyncMock(return_value=[other, wrong])):
                result = await service.index(req)
            self.assertEqual(result['verified_count'], 2)


class ConvertedPricePolicy(unittest.TestCase):
    def test_published_conversion_marker_is_distinct_from_provider_currency(self):
        self.assertEqual(e.marketplace_currency_basis('<li class="link-country-selector">France</li>',
            'https://www.whatclinic.com/beauty-clinics/turkey/izmir/aster-clinic'), 'platform_converted')
        self.assertEqual(e.marketplace_currency_basis('<li class="link-country-selector">France</li>',
            'https://aster.example/prices'), '')

    def test_approved_eur_conversion_does_not_certify_ron_or_another_platform(self):
        base = quote(city='Madrid', amount=150).model_copy(update={
            'source_url': 'https://www.whatclinic.com/beauty-clinics/spain/madrid/aster-clinic',
            'source_type': 'marketplace', 'evidence_type': 'marketplace_service_menu',
            'source_location_text': 'Provider locality: Madrid, Spain',
            'clinic_own_price': False, 'procedure_canonical': 'chemical_peel',
            'raw_procedure_text': 'Chemical Peel', 'procedure_detail': '',
            'raw_evidence': 'Chemical Peel | 150 EUR', 'currency': 'EUR',
            'source_currency_basis': 'platform_converted'})
        self.assertTrue(e.trusted_price_result(base))
        self.assertEqual(base.source_currency_basis, 'platform_converted')
        for override in [{'currency': 'RON', 'raw_evidence': 'Chemical Peel | 150 RON'},
                         {'source_url': 'https://us-uk.bookimed.com/clinic/aster-clinic/'}]:
            row = base.model_copy(update=override)
            self.assertFalse(e.trusted_price_result(row))
            self.assertEqual(e.trusted_price_failure(row), 'marketplace_conversion_currency_unstable')


if __name__ == '__main__': unittest.main()
