"""Published offers must survive discovery and arrive before optional crawls."""
import asyncio
import json
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote


def profile(url, label="Botox injections", price="$150 - $300", city="Istanbul"):
    slug = url.split('/clinic/')[1].split('/')[0]
    name = 'Aster Medical Clinic ' + slug
    data = {'@type': 'MedicalWebPage', 'url': url, 'mainEntity': {
        '@type': 'Hospital', 'url': url, 'name': name,
        'address': {'addressLocality': city}}}
    return (f'<title>{name}</title><h1>{name}</h1>'
            f'<script type="application/ld+json">{json.dumps(data)}</script>'
            '<h2>Treatments prices in the clinic</h2><table>'
            f'<tr><td>{label}</td><td>{price}</td></tr></table>')


class PriceContext(unittest.TestCase):
    def test_inline_bold_does_not_drop_national_average_qualifiers(self):
        html = ('<title>Aster Clinic</title><h1>Botoks fiyatları</h1><p>'
                '<strong>Botoks fiyatları 2026</strong>, Türkiye genelinde ortalama olarak '
                '<strong>5.000 TL ile 15.000 TL</strong> arasındadır.</p>'
                '<footer>Our clinic in Istanbul</footer>')
        rows = e.extract_price_evidence(html, 'https://aster.example/botoks-fiyatlari/', 'botox')
        self.assertTrue(rows)
        self.assertFalse(any(e.validate_evidence(r, e.page_text(html), html, 'Istanbul')[0]
                             for r in rows))

    def test_real_menu_on_page_with_an_average_paragraph_remains_valid(self):
        html = ('<title>Aster Clinic</title><h1>Botox prices</h1>'
                '<p>National average Botox prices: $150 - $300.</p>'
                '<h2>Our clinic price list</h2><table><tr><td>Botox 3 areas</td>'
                '<td>$275</td></tr></table><footer>Our clinic in Istanbul</footer>')
        rows = e.extract_price_evidence(html, 'https://aster.example/prices/', 'botox')
        accepted = [r for r in rows if e.validate_evidence(r, e.page_text(html), html, 'Istanbul')[0]]
        self.assertTrue(accepted)
        self.assertTrue(all(r.price_min == 275 for r in accepted))

    def test_old_revision_cannot_be_presented_as_current_verification(self):
        row = quote(city='Istanbul')
        self.assertTrue(e._app_can_show_row(row))
        for old in ['', 'e27', 'e20']:
            self.assertFalse(e._app_can_show_row(row.model_copy(update={'price_extract_revision': old})))

    def test_category_cached_as_owned_price_is_rejected_before_counting(self):
        row = quote(city='Istanbul').model_copy(update={
            'source_url': 'https://us-uk.bookimed.com/clinics/country=turkey/procedure=botox-injections/',
            'source_type': 'marketplace', 'clinic_own_price': True,
            'evidence_type': 'marketplace_service_menu',
            'source_location_text': 'Provider locality: Istanbul'})
        self.assertFalse(e._app_can_show_row(row))
        self.assertEqual(e.classify_source('https://www.mymeditravel.com/dermal-fillers-procedures-in-istanbul-turkey'), 'directory')

    def test_dedicated_marketplace_round_opens_eight_profiles(self):
        hits = [e.SearchHit(title='', url=f'https://us-uk.bookimed.com/clinic/provider-{n}/') for n in range(10)]
        req = e.DiscoverRequest(city='Istanbul', procedure='botox', hybrid_interactive=True,
                                progressive_stage='marketplace')
        selected, counts = e.select_discovery_work(hits, req, lambda h: h.url)
        self.assertGreaterEqual(len(selected), 8)
        self.assertLessEqual(len(selected), 10)
        self.assertEqual(counts['marketplace'], 8)


class ProviderMenuDelivery(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.enterContext(patch.dict(os.environ, {'ENABLE_FIRESTORE': 'false',
            'ENABLE_BACKGROUND_REFRESH': 'false', 'ENABLE_MARKETPLACE_OFFICIAL_VERIFICATION': 'true'}))
        self.enterContext(patch.object(e.GooglePlacesClient, 'configured', False))
        self.enterContext(patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])))
        self.resolver = self.enterContext(patch.object(e, 'resolve_marketplace_official_site',
                                                       new=AsyncMock(side_effect=AssertionError('Optional crawl held up a verified menu'))))

    async def discover(self, urls, procedure='botox'):
        return await e.discover(e.DiscoverRequest(city='Istanbul', procedure=procedure,
            country_code='TR', persist=False, debug=True, limit=12, search_mode='site_focus',
            priority_site_urls=urls, enable_serper=False, interactive_fast=True,
            hybrid_interactive=True, skip_places_bootstrap=True, progressive_stage='marketplace',
            progressive_stop_count=12))

    async def test_eight_discovered_profile_urls_keep_literal_ranges(self):
        urls = [f'https://us-uk.bookimed.com/clinic/provider-{n}/' for n in range(8)]
        with patch.object(e, 'fetch_html', new=AsyncMock(side_effect=lambda u: profile(u) if u in urls else None)):
            result = await self.discover(urls)
        rows = [r for r in result.results if e._app_can_show_row(r)]
        self.assertEqual(len(rows), 8)
        self.assertTrue(all((r.price_min, r.price_max) == (150, 300) for r in rows))
        self.resolver.assert_not_awaited()

    async def test_menu_partial_arrives_while_unrelated_page_is_still_waiting(self):
        menu = 'https://us-uk.bookimed.com/clinic/aster-hospital/'
        slow = 'https://slow-clinic.example/prices/'
        release, started = asyncio.Event(), asyncio.Event()
        async def fetch(url):
            if url == slow:
                started.set()
                await release.wait()
                return None
            return profile(url) if url == menu else None
        queue = asyncio.Queue()
        token = e._hybrid_progress.set(queue)
        try:
            with patch.object(e, 'fetch_html', side_effect=fetch):
                task = asyncio.create_task(self.discover([menu, slow]))
                try:
                    await asyncio.wait_for(started.wait(), 2)
                    while True:
                        event = await asyncio.wait_for(queue.get(), 3)
                        if event.get('event') == 'partial':
                            break
                    self.assertFalse(task.done())
                    self.assertEqual(event['display_results'][0]['price_max'], 300)
                finally:
                    release.set()
                    await task
        finally:
            e._hybrid_progress.reset(token)
        self.resolver.assert_not_awaited()

    async def test_all_six_families_deliver_a_local_priced_menu(self):
        for canonical, label, price in [
            ('botox', 'Botox injections', '$150 - $300'),
            ('filler', 'Fillers injection', '$250 - $400'),
            ('chemical_peel', 'Chemical Peel', '$100 - $150'),
            ('rhinoplasty', 'Rhinoplasty', '$3500 - $4500'),
            ('breast_augmentation', 'Breast augmentation', '$4000 - $5000'),
            ('hair_transplant', 'FUE Hair Transplant', '$2000 - $2500'),
        ]:
            with self.subTest(procedure=canonical):
                url = f'https://us-uk.bookimed.com/clinic/aster-{canonical.replace("_", "-")}/'
                with patch.object(e, 'fetch_html', new=AsyncMock(return_value=profile(url, label, price))):
                    result = await self.discover([url], canonical)
                self.assertEqual(len([r for r in result.results if e._app_can_show_row(r)]), 1)

    async def test_unpriced_default_profile_follows_its_specific_treatment_menu(self):
        root = 'https://us-uk.bookimed.com/clinic/aster-clinic/'
        service = root + 'procedure=chemical-peel/'
        pages = {root: profile(root, 'Chemical Peel', 'Price on request'),
                 service: profile(root, 'Chemical Peel', '$150 - $300')}
        with patch.object(e, 'fetch_html', new=AsyncMock(side_effect=lambda u: pages.get(u))):
            result = await self.discover([root], 'chemical_peel')
        rows = [r for r in result.results if e._app_can_show_row(r)]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0].price_min, rows[0].price_max), (150, 300))
        self.assertEqual(rows[0].source_url, service)

    async def test_specific_treatment_url_does_not_use_a_different_provider_address(self):
        root = 'https://us-uk.bookimed.com/clinic/aster-clinic/'
        other = 'https://us-uk.bookimed.com/clinic/other-clinic/'
        self.assertEqual(e.marketplace_provider_locations(profile(root), root + 'procedure=chemical-peel/'), ['Istanbul'])
        self.assertEqual(e.marketplace_provider_locations(profile(other), root + 'procedure=chemical-peel/'), [])

    async def test_istanbul_query_cannot_relabel_a_foreign_profile(self):
        url = 'https://us-uk.bookimed.com/clinic/premier-clinic/'
        with patch.object(e, 'fetch_html', new=AsyncMock(return_value=profile(url, city='Kuala Lumpur'))):
            result = await self.discover([url])
        self.assertEqual(result.results, [])


if __name__ == '__main__':
    unittest.main()
