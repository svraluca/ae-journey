"""A localized marketplace fee is only a lead to an independently owned fee."""
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e
import vertical_search


def profile(name, website, *, localized=False):
    menu = ('<div data-id="41"><span class="name">Chemical Peel</span>'
            '<span class="price_container">1200 RON</span></div>' if localized else
            '<div data-id="41"><span class="name">Chemical Peel</span>'
            '<span class="price_container">Price on request</span></div>')
    return (f'<title>{name} in Izmir, Turkey</title><h1>{name}</h1>'
            '<span class="address">Medical Road, Izmir, Turkey</span>'
            + ('<a class="link-country-selector">Romania</a>' if localized else '')
            + menu + f'<a href="{website}">Visit clinic website</a>')


def clinic_root(name, *, city='Izmir', priced=False):
    body = ('<h2>Our clinic price list</h2><table><tr><td>Chemical peel</td>'
            '<td>200 EUR</td></tr></table>' if priced else
            '<a href="/treatment-menu/">Chemical peel prices</a>')
    return (f'<title>{name}</title><h1>{name}</h1><h2>Chemical Peel</h2>'
            + body + f'<footer>Our clinic: Medical Road, {city}, Turkey. Book an appointment.</footer>')


class OwnedSourceRescue(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        vertical_search.REJECTIONS.rows.clear()
        self.enterContext(patch.dict(os.environ, {
            'ENABLE_FIRESTORE': 'false', 'ENABLE_BACKGROUND_REFRESH': 'false',
            'SERPER_API_KEY': '', 'GOOGLE_PLACES_API_KEY': '',
        }))
        self.enterContext(patch.object(e.GooglePlacesClient, 'configured', False))
        self.enterContext(patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])))
        self.search = self.enterContext(patch.object(e.SerperClient, 'search',
            new=AsyncMock(side_effect=AssertionError('Official navigation cannot buy another search'))))

    async def discover(self, documents, profiles):
        fetched = []
        async def fetch(url):
            fetched.append(url)
            return documents.get(url)
        with patch.object(e, 'fetch_html', side_effect=fetch):
            result = await e.discover(e.DiscoverRequest(
                city='Izmir', procedure='chemical_peel', country_code='TR',
                limit=8, persist=False, debug=True, search_mode='site_focus',
                priority_site_urls=profiles, enable_serper=False, interactive_fast=True,
                hybrid_interactive=True, skip_places_bootstrap=True,
                progressive_stage='marketplace', progressive_stop_count=8))
        self.search.assert_not_awaited()
        return result, fetched

    async def check_owned_navigation(self, localized):
        market = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/aster-clinic'
        root = 'https://aster-clinic.example/'
        menu = root + 'treatment-menu/'
        documents = {market: profile('Aster Clinic', root, localized=localized),
                     root: clinic_root('Aster Clinic'),
                     menu: clinic_root('Aster Clinic', priced=True)}
        result, fetched = await self.discover(documents, [market])
        self.assertEqual(len(result.results), 1)
        row = result.results[0]
        self.assertEqual((row.price_min, row.currency), (200, 'EUR'))
        self.assertEqual(row.source_url, menu)
        self.assertEqual(row.source_type, 'official_clinic')
        self.assertTrue(row.clinic_own_price)
        self.assertEqual(row.source_currency_basis, '')
        self.assertEqual(fetched.count(market), 1)
        self.assertIn(menu, fetched)

    async def test_unpriced_profile_follows_actual_owned_website_and_tariff(self):
        await self.check_owned_navigation(False)

    async def test_localized_fee_is_replaced_only_by_independently_published_original(self):
        await self.check_owned_navigation(True)

    async def test_other_clinic_outbound_link_cannot_supply_the_price(self):
        market = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/aster-clinic'
        wrong = 'https://cedar-clinic.example/'
        result, fetched = await self.discover({
            market: profile('Aster Clinic', wrong, localized=True),
            wrong: clinic_root('Cedar Clinic', city='Ankara', priced=True)}, [market])
        self.assertEqual(result.results, [])
        self.assertIn(wrong, fetched)

    async def test_matching_brand_cannot_relabel_its_other_city_tariff(self):
        market = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/aster-clinic'
        wrong_city = 'https://aster-clinic.example/'
        result, _ = await self.discover({
            market: profile('Aster Clinic', wrong_city, localized=True),
            wrong_city: clinic_root('Aster Clinic', city='Ankara', priced=True)}, [market])
        self.assertEqual(result.results, [])

    async def test_only_two_profile_outbound_probes_run_in_one_round(self):
        documents, profiles, roots = {}, [], []
        for name in ['Aster', 'Cedar', 'Birch']:
            market = f'https://www.whatclinic.com/beauty-clinics/turkey/izmir/{name.lower()}-clinic'
            root = f'https://{name.lower()}-clinic.example/'
            profiles.append(market)
            roots.append(root)
            documents[market] = profile(name + ' Clinic', root)
            documents[root] = clinic_root(name + ' Clinic', priced=True)
        result, fetched = await self.discover(documents, profiles)
        self.assertEqual(len(result.results), 2)
        self.assertEqual(len({url for url in fetched if url in roots}), 2)
        self.assertTrue(all(row.source_type == 'official_clinic' for row in result.results))


if __name__ == '__main__':
    unittest.main()
