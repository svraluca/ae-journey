"""A category is a navigation lead; only fetched provider tariffs are prices."""
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e
import vertical_search as v


class WhatClinicQueries(unittest.TestCase):
    def test_each_compare_family_searches_the_platform_treatment_category(self):
        for city, country in [('İzmir', 'TR'), ('Valencia', 'ES'), ('Bucharest', 'RO')]:
            for procedure, (section, slug) in v.Catalog.whatclinic_categories.items():
                with self.subTest(city=city, procedure=procedure):
                    queries = v.CATALOG.queries(procedure, city, country,
                                                e.local_terms_for, stage='marketplace')
                    self.assertEqual(len(queries), 2)
                    self.assertIn(f'site:whatclinic.com/{section}/', queries[0])
                    self.assertIn(f'"{city}"', queries[0])
                    self.assertIn(f'inurl:{slug}', queries[0])
                    self.assertIn('site:bookimed.com/clinic/', queries[1])
                    # Country/province hierarchy comes from the actual search
                    # result, not from a guessed city-to-province override.
                    self.assertNotIn('-province', queries[0])

    def test_other_procedures_keep_the_generic_platform_search(self):
        queries = v.CATALOG.queries('microneedling', 'Valencia', 'ES',
                                    e.local_terms_for, stage='marketplace')
        self.assertIn('site:whatclinic.com "Valencia"', queries[0])
        self.assertIn('microneedling', queries[0])

    def test_directory_navigation_leads_require_the_actual_requested_locality(self):
        local = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/dermal-fillers'
        self.assertTrue(v.marketplace_discovery_lead(e, local, 'Izmir', 'TR'))
        for url in [
            'https://www.whatclinic.com/beauty-clinics/turkey/dermal-fillers',
            'https://www.whatclinic.com/beauty-clinics/turkey/ankara/dermal-fillers',
            'https://www.whatclinic.com/beauty-clinics/spain/izmir/dermal-fillers',
            'https://us-uk.bookimed.com/clinics/country=turkey/procedure=fillers-injection/',
        ]:
            with self.subTest(url=url):
                self.assertFalse(v.marketplace_discovery_lead(e, url, 'Izmir', 'TR'))


class CategoryToPublishedProfiles(unittest.IsolatedAsyncioTestCase):
    async def test_cold_category_query_finds_four_distinct_profile_tariffs(self):
        await self.check_category_pipeline()

    async def test_saved_directory_lead_finds_profiles_without_a_search_credential(self):
        await self.check_category_pipeline(saved=True)

    async def check_category_pipeline(self, saved=False):
        city = 'Izmir'
        directory = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/dermal-fillers'
        names = ['Aster', 'Cedar', 'Birch', 'Elm']
        documents = {}
        # Navigation categories precede the clinic cards on real WhatClinic
        # pages. They must never consume the provider-profile shortlist.
        navigation = ''.join(f'<a href="/beauty-clinics/turkey/izmir/other-treatment-{n}">'
                             f'Treatment {n}</a>' for n in range(20))
        cards = []
        expected = set()
        for index, name in enumerate(names):
            url = f'https://www.whatclinic.com/beauty-clinics/turkey/izmir/{name.lower()}-clinic'
            low, high = 310 + index * 10, 410 + index * 10
            expected.add((f'{name} Clinic', low, high, 'EUR'))
            cards.append(
                f'<div class="search-listing" data-clinic-id="{index + 1}"><div class="title-section"><h3>'
                f'<a class="nocss-brochure-link" href="{url}">{name} Clinic</a></h3>'
                f'<span class="address">{index + 1} Medical Road, Izmir, Turkey</span></div>'
                '<div class="treatment-container"><span class="title">Dermal Fillers</span>'
                '<span class="price-holder">€999</span></div></div>')
            # The directory quote deliberately differs from the profile. The
            # latter must be fetched and verified before any card is emitted.
            documents[url] = (
                f'<title>{name} Clinic in Izmir, Turkey</title>'
                f'<h1>{name} Clinic</h1><span class="address">Izmir, Turkey</span>'
                '<div data-id="41"><span class="name">Dermal Fillers</span>'
                f'<span class="price_container"><span class="price">{low} €</span> - '
                f'<span class="price">{high} €</span></span></div>'
                '<div data-id="42"><span class="name">Chemical Peel</span>'
                '<span class="price_container">60 €</span></div>')
        documents[directory] = (
            '<title>Dermal Fillers in Izmir, Turkey • Check Prices &amp; Reviews</title>'
            '<h1>Dermal Fillers in Izmir</h1><p>Choose from 100 clinics. Prices from €25.</p>'
            f'<nav>{navigation}</nav>{"".join(cards)}')
        fetched, queries = [], []

        async def fetch(url):
            fetched.append(url)
            return documents.get(url)

        async def search(self, query, *args, **kwargs):
            queries.append(query)
            self.requests_attempted += 1
            if not saved and query.startswith('site:whatclinic.com/'):
                return [e.SearchHit(title='Dermal Fillers in Izmir', url=directory,
                                    snippet='Choose from 100 clinics; prices from €25.', query=query)]
            return []

        with patch.dict(os.environ, {'ENABLE_FIRESTORE': 'false',
                'ENABLE_DEEP_DISCOVERY': 'true', 'ENABLE_MULTILINGUAL_SEARCH': 'true',
                'ENABLE_MARKETPLACE_RESCUE': 'true', 'ENABLE_EXA_RESCUE': 'false'}), \
                patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
                patch.object(e.GooglePlacesClient, 'configured', False), \
                patch.object(e.SerperClient, 'search', new=search), \
                patch.object(e, 'fetch_html', side_effect=fetch):
            responses, rows, _ = await v.run_progressive(e, city=city, procedure='filler',
                country_code='TR', stored_pool=[], desired_new=6, limit=8,
                display_limit=4, debug=True,
                saved_source_urls=[directory] if saved else [])
        actual = {(r.clinic_name, r.price_min, r.price_max, r.currency) for r in rows}
        self.assertEqual(actual, expected)
        self.assertEqual(len({r.source_url for r in rows}), 4)
        self.assertTrue(all(r.source_url != directory and e._app_can_show_row(r) for r in rows))
        self.assertTrue(all(r.price_min not in {25, 999} for r in rows))
        self.assertTrue(set(documents).issubset(set(fetched)))
        self.assertFalse(any('other-treatment' in url for url in fetched))
        self.assertLessEqual(len(queries), 4)
        self.assertTrue(any(r.diagnostics.marketplace_category_pages_expanded for r in responses))


class CurrentPublishedTariffs(unittest.TestCase):
    def test_review_paid_amount_and_neighbor_fee_are_not_current_tariffs(self):
        url = 'https://www.whatclinic.com/beauty-clinics/turkey/izmir/aster-clinic'
        # Current WhatClinic DOM: popular treatments are div[data-id], and
        # full service menus are separate .treatment_item makesOffer cards.
        html = (
            '<title>Aster Clinic in Izmir</title><span class="address">Izmir, Turkey</span>'
            '<div class="review review-container" property="review" typeof="Review">'
            '<div class="review-date">28.01.2019</div><h4 class="title" property="headline">'
            'I am thrilled with my results</h4><div class="review-small-text">'
            '<span property="itemReviewed" typeof="Service">Lip Filler</span> • Paid: 25 €'
            '</div></div>'
            '<div data-id="43"><span class="name">Dermal Fillers</span>'
            '<span class="price_container"><span class="price">179 €</span>'
            '<span class="from">-</span><span class="price">268 €</span></span></div>'
            '<div class="treatment_list">'
            '<div class="grouped_treatment treatment_item" property="makesOffer" typeof="Offer">'
            '<span class="group_heading">Jaw Filler</span><div class="treatment_body">'
            '<h4 property="name">Jaw Filler (1 hour)</h4></div></div>'
            '<div class="grouped_treatment treatment_item" property="makesOffer" typeof="Offer">'
            '<span class="group_heading">Lip Filler</span>'
            '<div class="treatment_price" property="priceSpecification" typeof="PriceSpecification">'
            '<div class="price_container"><span class="price" property="minPrice">179 €</span>'
            '<span class="from">-</span><span class="price" property="maxPrice">357 €</span>'
            '</div></div><div class="treatment_body"><h4 property="name">Lip Filler (30 mins)</h4>'
            '</div></div></div>')
        accepted = [row for row in e.extract_price_evidence(html, url, 'filler')
                    if e.validate_evidence(row, e.page_text(html), html, 'Izmir')[0]]
        self.assertTrue(accepted)
        self.assertEqual({(r.price_min, r.price_max, r.currency) for r in accepted},
                         {(179, 268, 'EUR'), (179, 357, 'EUR')})
        self.assertFalse(any('Jaw Filler' in r.raw_evidence or 'Paid:' in r.raw_evidence
                             for r in accepted))

    def test_review_only_profile_has_no_published_price(self):
        url = 'https://www.whatclinic.com/beauty-clinics/spain/valencia/aster-clinic'
        html = ('<title>Aster Clinic in Valencia</title><span class="address">Valencia, Spain</span>'
                '<div class="review" property="review" typeof="Review">'
                '<h4>Lip filler was amazing</h4><span property="itemReviewed">Lip Filler</span>'
                ' • Paid: 250 €</div>')
        self.assertFalse(any(e.validate_evidence(row, e.page_text(html), html, 'Valencia')[0]
                             for row in e.extract_price_evidence(html, url, 'filler')))


if __name__ == '__main__':
    unittest.main()
