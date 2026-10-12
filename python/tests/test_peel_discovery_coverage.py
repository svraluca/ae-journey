"""Peel discovery expands leads without inventing original provider fees."""
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote
import vertical_search as v


class PeelQueries(unittest.TestCase):
    def test_variants_use_the_requested_city_and_existing_chemical_aliases(self):
        for city, cc in [('Ankara', 'TR'), ('İstanbul', 'TR'), ('Valencia', 'ES')]:
            queries = v.CATALOG.queries('chemical_peel', city, cc, e.local_terms_for,
                                        stage='subtypes')
            self.assertEqual(len(queries), 2)
            self.assertTrue(all(city in q and q.endswith(' price') for q in queries))
            for group in v.Catalog.peel_search_groups:
                self.assertTrue(all(e.contains_requested_procedure(term, 'chemical_peel')
                                    for term in group))
            self.assertFalse(any(term in ' '.join(queries).lower()
                                 for term in ['carbon laser', 'hydrafacial', 'microdermabrasion']))
        self.assertEqual(v.CATALOG.queries('botox', 'Ankara', 'TR', e.local_terms_for,
                                          stage='subtypes'), [])

    def test_explicit_paid_allowance_is_never_increased(self):
        self.assertEqual(v.progressive_serper_cap('chemical_peel'), 6)
        self.assertEqual(v.progressive_serper_cap('botox'), 4)
        for budget in [1, 2, 4, 5, 6, 20]:
            self.assertLessEqual(v.progressive_serper_cap('chemical_peel', budget), budget)


class PeelSearchPolicy(unittest.IsolatedAsyncioTestCase):
    async def run_search(self, *, budget=0, initial=0, primary_succeeds=False):
        calls = []
        async def discover(req):
            calls.append(req)
            rows = []
            if primary_succeeds and req.progressive_stage == 'primary':
                for n in range(6):
                    rows.append(quote(f'Provider {n} Clinic', f'provider{n}.example', city='Ankara')
                        .model_copy(update={'procedure_canonical': 'chemical_peel',
                            'raw_procedure_text': 'BioRePeel',
                            'raw_evidence': 'Our BioRePeel facial treatment | 250 EUR',
                            'price_min': 250, 'price_max': 250, 'currency': 'EUR'}))
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, results=rows,
                searched_urls=len(rows), fetched_pages=len(rows),
                queries=req.query_override, diagnostics=e.DiscoveryDiagnostics(
                    serper_requests_attempted=len(req.query_override)))
        with patch.dict(os.environ, {'ENABLE_DEEP_DISCOVERY': 'true',
                'ENABLE_MULTILINGUAL_SEARCH': 'true', 'ENABLE_MARKETPLACE_RESCUE': 'true',
                'ENABLE_EXA_RESCUE': 'false', 'ENABLE_FIRESTORE': 'false'}), \
                patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
                patch.object(e, 'firestore_upsert_clinic_directory', new=AsyncMock(return_value=0)), \
                patch.object(e.GooglePlacesClient, 'configured', False), \
                patch.object(e, 'discover', side_effect=discover):
            await v.run_progressive(e, city='Ankara', country_code='TR', procedure='chemical_peel',
                stored_pool=[], desired_new=8, limit=8, debug=True,
                serper_request_budget=budget, initial_serper_requests=initial)
        return calls

    async def test_sparse_peels_reach_priced_menus_before_broad_articles_and_variants(self):
        calls = await self.run_search()
        self.assertEqual([r.progressive_stage for r in calls],
                         ['marketplace', 'primary', 'local', 'subtypes'])
        self.assertEqual(sum(r.serper_request_cap for r in calls), 6)
        self.assertEqual(calls[1].query_override, ['chemical peel Ankara price'])
        self.assertEqual(calls[-1].procedure, 'chemical_peel')

    async def test_four_request_allowance_and_prior_requests_leave_no_extra_spend(self):
        calls = await self.run_search(budget=4)
        self.assertNotIn('subtypes', [r.progressive_stage for r in calls])
        self.assertEqual(sum(r.serper_request_cap for r in calls), 4)
        calls = await self.run_search(budget=4, initial=2)
        self.assertEqual(sum(r.serper_request_cap for r in calls), 2)

    async def test_goal_met_does_not_buy_variant_queries(self):
        calls = await self.run_search(primary_succeeds=True)
        self.assertEqual([r.progressive_stage for r in calls], ['marketplace', 'primary'])


class PeelDirectoryNavigation(unittest.IsolatedAsyncioTestCase):
    async def test_fifth_directory_page_reaches_seven_verified_profile_menus(self):
        directory = 'https://www.whatclinic.com/beauty-clinics/turkey/ankara/chemical-peel'
        documents, profiles = {}, []
        for page in range(5):
            cards = []
            for n in range(2 if page < 2 else 1):
                index = len(profiles)
                url = f'https://www.whatclinic.com/beauty-clinics/turkey/ankara/provider-{index}-clinic'
                profiles.append(url)
                cards.append(f'<div class="search-listing" data-clinic-id="{index + 1}">'
                    f'<h3><a class="nocss-brochure-link" href="{url}">Provider {index} Clinic</a></h3>'
                    '<span class="address">Ankara, Turkey</span><div class="treatment-container">'
                    '<span class="title">Chemical Peel</span><span class="price-holder">€999</span>'
                    '</div></div>')
                documents[url] = (f'<title>Provider {index} Clinic in Ankara, Turkey</title>'
                    f'<h1>Provider {index} Clinic</h1><span class="address">Ankara, Turkey</span>'
                    '<div data-id="41"><span class="name">Chemical Peel</span>'
                    f'<span class="price_container">{100 + index * 10} EUR</span></div>')
            url = directory + (f'?page={page}' if page else '')
            next_link = f'<a href="?page={page + 1}" rel="next">Next &gt;</a>' if page < 4 else ''
            documents[url] = ('<title>Chemical Peel in Ankara</title>' + ''.join(cards) + next_link)
        fetched = []
        async def fetch(url):
            fetched.append(url)
            return documents.get(url)
        with patch.dict(os.environ, {'ENABLE_FIRESTORE': 'false'}), \
                patch.object(e.GooglePlacesClient, 'configured', False), \
                patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
                patch.object(e, 'fetch_html', side_effect=fetch):
            result = await e.discover(e.DiscoverRequest(city='Ankara', country_code='TR',
                procedure='chemical_peel', limit=8, persist=False, debug=True, search_mode='site_focus',
                priority_site_urls=[directory], enable_serper=False, interactive_fast=True,
                hybrid_interactive=True, skip_places_bootstrap=True, progressive_stop_count=8))
        self.assertEqual(len(result.results), 7)
        self.assertTrue(set(profiles).issubset(fetched))
        self.assertIn(directory + '?page=4', fetched)
        self.assertFalse(any('page=5' in url for url in fetched))
        self.assertTrue(all(e._app_can_show_row(row) for row in result.results))
        self.assertEqual({row.price_min for row in result.results}, set(range(100, 170, 10)))
        self.assertFalse(any(row.source_url.startswith(directory) for row in result.results))

    def test_review_footer_is_not_a_clinic_original_currency_rescue(self):
        profile = 'https://www.whatclinic.com/beauty-clinics/turkey/ankara/provider-clinic'
        html = ('<a href="https://uk.trustpilot.com/">Trustpilot reviews</a>'
                '<a href="https://provider.example/">Visit clinic website</a>')
        self.assertEqual(e.marketplace_outbound_official_candidates(profile, html),
                         ['https://provider.example/'])


if __name__ == '__main__':
    unittest.main()
