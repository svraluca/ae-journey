"""Directory discovery must preserve clinic, locality and tariff ownership."""
import json
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e


def profile_html(url, locality, region, street='Medical Road'):
    schema = {'@type': 'MedicalClinic', 'name': 'Aster Clinic', 'url': url,
              'address': {'streetAddress': street, 'addressLocality': locality,
                          'addressRegion': region, 'addressCountry': 'Spain'}}
    return f'<script type="application/ld+json">{json.dumps(schema)}</script>'


class ProviderScope(unittest.TestCase):
    def test_district_requires_owned_city_address_and_profile_hierarchy(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/manises/aster-clinic'
        html = profile_html(url, 'Manises', 'Valencia')
        self.assertTrue(e.strong_local_page_evidence(html, '', 'Valencia', url))
        self.assertIn('Valencia', e.marketplace_provider_location_context(html, url, 'Valencia'))
        # A search city in the URL cannot replace a foreign actual address.
        foreign = profile_html(url, 'Madrid', 'Madrid')
        self.assertFalse(e.strong_local_page_evidence(foreign, '', 'Valencia', url))
        # A city-named street cannot override a peer city, either.
        foreign_street = profile_html(url, 'Madrid', 'Madrid', 'Valencia Road')
        self.assertFalse(e.strong_local_page_evidence(foreign_street, '', 'Valencia', url))

    def test_matching_state_is_not_new_york_city(self):
        url = 'https://www.whatclinic.com/beauty-clinics/us/new-york/aster-clinic'
        html = profile_html(url, 'Albany', 'New York')
        self.assertFalse(e.strong_local_page_evidence(html, '', 'New York', url))

    def test_next_page_is_published_same_category_navigation(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/dermal-fillers'
        html = ('<a href="https://unrelated.example/fillers?page=1">Next</a>'
                '<a href="/beauty-clinics/spain/madrid/dermal-fillers?page=1">Next</a>'
                '<a href="/beauty-clinics/spain/valencia/dermal-fillers?page=1" rel="next">2</a>')
        self.assertEqual(e.whatclinic_next_category_url(url, html), url + '?page=1')

    def test_menu_link_uses_verified_dom_anchor_without_changing_page(self):
        url = 'https://us-uk.bookimed.com/clinic/aster/'
        html = '<section class="clinic-prices" id="prices"><table><tr><td>Filler $250</td></tr></table></section>'
        self.assertEqual(e.published_marketplace_menu_url(html, url), url + '#prices')
        nested = '<div id="prices"><section class="clinic-prices"><table><tr><td>Filler $250</td></tr></table></section></div>'
        self.assertEqual(e.published_marketplace_menu_url(nested, url), url + '#prices')
        self.assertEqual(e.published_marketplace_menu_url(html, url + '#existing'), url + '#existing')
        self.assertEqual(e.published_marketplace_menu_url('<h2>Prices</h2>', url), url)

    def test_wrinkle_category_price_requires_its_own_injectable_description(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/aster-clinic'
        def offer(description):
            return ('<div class="treatment_item" property="makesOffer" typeof="Offer">'
                    '<div class="treatment_price"><div class="price_container">from 180 €</div></div>'
                    '<div class="treatment_body"><h4 property="name">Treatment for Wrinkles</h4>'
                    f'<p>{description}</p></div></div>')
        self.assertEqual(e.extract_price_evidence(offer('Laser facial rejuvenation'), url, 'botox'), [])
        rows = e.extract_price_evidence(offer('Botulinum toxin injections for expression lines.'), url, 'botox')
        self.assertTrue(rows)
        self.assertTrue(all(row.price_min == 180 and 'Botulinum toxin' in row.raw_evidence for row in rows))
        # A different service's Botox mention cannot certify this fee.
        self.assertEqual(e.extract_price_evidence(
            offer('Laser facial rejuvenation') + '<h3>Botox injections also available</h3>', url, 'botox'), [])

    def test_upper_bound_is_not_an_exact_fee(self):
        url = 'https://www.whatclinic.com/hair-loss/spain/valencia/aster-clinic'
        html = ('<div data-id="1"><span class="name">Hair Transplant</span>'
                '<span class="price_container">up to 1990 €</span></div>')
        self.assertEqual(e.extract_price_evidence(html, url, 'hair_transplant'), [])

    def test_direct_clinic_travel_support_is_not_agency_proof(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/aster-clinic'
        html = ('<div property="description">Our clinic performs filler injections. '
                'We organize airport transfers and aftercare appointments with our doctors.</div>')
        self.assertFalse(e.marketplace_profile_is_intermediary(html, url))


class IntermediaryAdmission(unittest.IsolatedAsyncioTestCase):
    async def test_intermediary_menu_does_not_become_a_treating_clinic(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/aster-consultance'
        html = (profile_html(url, 'Valencia', 'Valencia')
                + '<h1>Aster Consultance</h1><div property="description">'
                  'We organize appointments and accommodation. After arrival you see the clinic '
                  'and meet your doctor.</div>'
                  '<div data-id="1"><span class="name">Dermal Fillers</span>'
                  '<span class="price_container">300 € - 800 €</span></div>')
        with patch.object(e, 'fetch_html', new=AsyncMock(return_value=html)), \
                patch.object(e.GooglePlacesClient, 'configured', False):
            result = await e.discover(e.DiscoverRequest(
                city='Valencia', procedure='filler', country_code='ES', enable_serper=False,
                skip_places_bootstrap=True, search_mode='site_focus', priority_site_urls=[url]))
        self.assertEqual(result.results, [])
        self.assertTrue(any(row.reason == 'marketplace_intermediary'
                            for row in result.diagnostics.reject_samples))


if __name__ == '__main__':
    unittest.main()
