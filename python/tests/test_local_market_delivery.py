"""Source-language names and first-round local discovery, without live APIs."""
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote
import vertical_search as v


class SourceLanguageTitles(unittest.TestCase):
    def test_cached_amount_needs_literal_source_evidence(self):
        row = quote()
        self.assertTrue(e.trusted_price_result(row))
        row.price_min = row.price_max = 1200
        self.assertEqual(e.trusted_price_failure(row), 'missing_literal_price_evidence')

    def test_turkish_market_estimates_cannot_be_clinic_owned(self):
        for claim in ['Dudak dolgusu fiyatları genellikle 10.000 TL',
                      'Dolgu fiyatları ortalama 45.000 TL',
                      'Botoks fiyatları 2026’da genellikle 6.500 TL',
                      'Saç ekimi maliyeti 60.000 TL ile 90.000 TL arasında değişir']:
            with self.subTest(claim=claim):
                self.assertTrue(e.generic_multi_clinic_price_context(claim))
        self.assertFalse(e.generic_multi_clinic_price_context('Kliniğimizde dudak dolgusu 10.000 TL'))

    def test_all_compare_families_keep_source_names(self):
        for family, title in [
            ('botox', 'Botoks fiyatları 2026'),
            ('filler', 'Dudak dolgusu 1 ml'),
            ('chemical_peel', 'Kimyasal peeling'),
            ('rhinoplasty', 'Burun estetiği'),
            ('breast_augmentation', 'Meme büyütme'),
            ('hair_transplant', 'Saç ekimi FUE'),
        ]:
            with self.subTest(family=family):
                expected = 'Botoks' if family == 'botox' else title
                self.assertEqual(e.published_procedure_display_name(family, title, ''), expected)

    def test_duplicated_turkish_article_copy_never_becomes_a_title(self):
        text = 'Botoks Fiyatları 2026 Botoks fiyatları 2026’da genellikle'
        self.assertEqual(e.published_procedure_display_name('botox', text, ''), 'Botoks')
        self.assertEqual(e.published_procedure_display_name('botox', 'Botoks',
                         'Botoks | 5.000 TL', '5.000 TL'), 'Botoks')

    def test_source_script_is_preserved(self):
        self.assertEqual(e.published_procedure_display_name('filler', 'فيلر الشفاه 1 مل', ''),
                         'فيلر الشفاه 1 مل')


class LocalFirstSearch(unittest.IsolatedAsyncioTestCase):
    async def test_local_round_precedes_english_for_every_configured_market(self):
        with patch.dict(os.environ, {'ENABLE_FIRESTORE': 'false', 'ENABLE_DEEP_DISCOVERY': 'true',
             'ENABLE_MULTILINGUAL_SEARCH': 'true', 'ENABLE_EXA_RESCUE': 'false'}), \
             patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
             patch.object(e, 'firestore_upsert_clinic_directory', new=AsyncMock()), \
             patch.object(e.GooglePlacesClient, 'configured', False):
            # Country configuration chooses the language, not clinic/city exceptions.
            for cc, city, term in [('TR', 'İstanbul', 'botoks'), ('ES', 'Valencia', 'botox'),
                                   ('AE', 'Sharjah', 'بوتوكس'), ('GB', 'York', 'botox')]:
                requests = []
                async def discover(req):
                    requests.append(req)
                    return e.DiscoverResponse(city=city, procedure='botox', country_code=cc,
                        queries=req.query_override or [], results=[], searched_urls=0, fetched_pages=0,
                        diagnostics=e.DiscoveryDiagnostics(serper_requests_attempted=len(req.query_override or [])))
                with patch.object(e, 'discover', side_effect=discover):
                    await v.run_progressive(e, city=city, procedure='botox', country_code=cc,
                        stored_pool=[], desired_new=6, limit=8, display_limit=4, debug=False,
                        app_fast=True, background_collection=False, client_known_clinic_hosts=[])
                with self.subTest(country=cc):
                    official = [r for r in requests if r.progressive_stage in {'local','primary'}]
                    self.assertEqual(official[0].progressive_stage, 'primary' if cc == 'GB' else 'local')
                    self.assertIn(term, official[0].query_override[0])
                    self.assertLessEqual(sum(r.serper_request_cap for r in requests), 4)


if __name__ == '__main__':
    unittest.main()
