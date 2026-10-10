"""Provider tariffs versus informational prices, including Turkish ranges."""
import os
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote
import vertical_search as v


class ProviderTariffs(unittest.TestCase):
    def test_whatclinic_named_service_card_keeps_its_own_range(self):
        url = 'https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/aster-clinic'
        html = ('<title>Aster Clinic</title><p>Istanbul, Turkey</p>'
                '<div data-id="41"><span class="name">Chemical Peel</span>'
                '<span class="price_container"><span class="price">800 €</span> - '
                '<span class="price">900 €</span></span></div>'
                '<div data-id="42"><span class="name">Mesotherapy</span>'
                '<span class="price_container">350 €</span></div>')
        rows = e.extract_price_evidence(html, url, 'chemical_peel')
        accepted = [(row, e.validate_evidence(row, e.page_text(html), html, 'İstanbul')) for row in rows]
        menus = [row for row, result in accepted if result[0] and result[-1] == 'marketplace_service_menu']
        self.assertTrue(menus)
        self.assertTrue(all((row.price_min, row.price_max, row.currency) == (800,900,'EUR') for row in menus))

    def test_informational_average_table_is_not_a_clinic_tariff_in_any_locale(self):
        for disclaimer in ['Yukarıdaki değerler ortalamadır; kesin ücret muayenede netleşir.',
                           'These prices are only averages; contact us for your quote.',
                           'Estos precios son estimaciones; solicite su presupuesto.']:
            html = ('<title>Aster Clinic</title><h2>Rhinoplasty</h2><table>'
                    '<tr><th>Treatment</th><th>Average price</th><th>Range</th></tr>'
                    '<tr><td>Rhinoplasty</td><td>~135.000 ₺</td><td>90.000 – 180.000 ₺</td></tr>'
                    f'</table><p>{disclaimer}</p><footer>İstanbul</footer>')
            rows = e.extract_price_evidence(html, 'https://aster.example/rhinoplasty/', 'rhinoplasty')
            self.assertTrue(rows)
            with self.subTest(disclaimer=disclaimer):
                self.assertFalse(any(e.validate_evidence(row, e.page_text(html), html, 'İstanbul')[0] for row in rows))
        cached = quote().model_copy(update={
            'evidence_type':'official_treatment_page', 'procedure_canonical':'rhinoplasty',
            'raw_procedure_text':'Rhinoplasty', 'raw_evidence':'Rhinoplasty ~135.000 ₺',
            'currency':'TRY', 'price_min':135000, 'price_max':None})
        self.assertFalse(e.trusted_price_result(cached))

    def test_average_after_upper_endpoint_survives_extraction_and_is_rejected(self):
        html = ('<title>Aster Clinic</title><h2>Meme büyütme ameliyatı ne kadar ortalama?</h2>'
                '<p>Meme büyütme ameliyatı fiyatı 120.000 TL ile 200.000 TL ortalama aralığındadır.</p>'
                '<footer>İstanbul</footer>')
        rows = e.extract_price_evidence(html, 'https://aster.example/meme-buyutme/', 'breast_augmentation')
        self.assertTrue(rows)
        self.assertFalse(any(e.validate_evidence(row, e.page_text(html), html, 'İstanbul')[0] for row in rows))

    def test_actual_turkish_range_retains_both_bounds_and_source_quote(self):
        for connector in ['ile', 'ila', '–']:
            html = ('<title>Aster Clinic</title><h2>Fiyat listesi</h2><table>'
                    '<tr><th>İşlem</th><th>Ücret</th></tr>'
                    f'<tr><td>Kimyasal peeling</td><td>1.500 TL {connector} 2.500 TL</td></tr>'
                    '</table><footer>İstanbul</footer>')
            rows = e.extract_price_evidence(html, 'https://aster.example/prices/', 'chemical_peel')
            accepted = [row for row in rows if e.validate_evidence(row, e.page_text(html), html, 'İstanbul')[0]]
            with self.subTest(connector=connector):
                self.assertTrue(accepted)
                self.assertTrue(all((row.price_min, row.price_max) == (1500, 2500) for row in accepted))
                self.assertTrue(all('2.500 TL' in row.raw_evidence for row in accepted))

    def test_cached_range_requires_quoted_upper_bound_and_never_a_midpoint(self):
        for low, high in [(135000, None), (90000, 999999)]:
            row = quote().model_copy(update={
                'procedure_canonical':'rhinoplasty', 'procedure_display_name':'Rhinoplasty',
                'raw_procedure_text':'Rhinoplasty', 'raw_evidence':'Rhinoplasty | 90.000 TL – 180.000 TL',
                'currency':'TRY', 'price_min':low, 'price_max':high, 'qualifier':'range'})
            self.assertFalse(e.trusted_price_result(row))
            self.assertTrue(e.trusted_price_failure(row))

    def test_provider_profile_table_is_a_marketplace_fee_but_category_is_not(self):
        html = ('<title>Aster Hospital in Turkey | Bookimed</title><p>Turkey, Istanbul</p>'
                '<h2>Treatment prices</h2><table><tr><th>Treatment</th><th>Price</th></tr>'
                '<tr><td>Chemical Peel</td><td>$150 - $300</td></tr></table>'
                '<p>A chemical peel may cost around €150.</p>')
        for url, expected in [
            ('https://us-uk.bookimed.com/clinic/aster-hospital/procedure=chemical-peel/', True),
            ('https://us-uk.bookimed.com/clinics/country=turkey/procedure=chemical-peel/', False),
        ]:
            rows = e.extract_price_evidence(html, url, 'chemical_peel')
            accepted = [(row, e.validate_evidence(row, e.page_text(html), html, 'İstanbul')) for row in rows]
            accepted = [(row, result) for row, result in accepted if result[0]]
            self.assertEqual(bool(accepted), expected, url)
            if expected:
                self.assertTrue(any(row.currency == 'USD' and row.price_min == 150 and row.price_max == 300
                    and result[-1] == 'marketplace_service_menu' for row, result in accepted))
                self.assertFalse(any(row.currency == 'EUR' for row, _ in accepted))
                self.assertTrue(all(result[-1] == 'marketplace_service_menu' for row, result in accepted
                    if row.extraction_method in {'scoped_tariff_table_row','table_row'}))


class SparsePriceDiscovery(unittest.IsolatedAsyncioTestCase):
    async def test_exa_retains_provider_menu_leads_but_not_category_estimates(self):
        requests = []
        async def discover(req):
            requests.append(req)
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, country_code='TR',
                queries=req.query_override or [], results=[], searched_urls=0, fetched_pages=0,
                diagnostics=e.DiscoveryDiagnostics(serper_requests_attempted=len(req.query_override or [])))
        profile = 'https://us-uk.bookimed.com/clinic/aster-hospital/procedure=chemical-peel/'
        category = 'https://us-uk.bookimed.com/clinics/country=turkey/procedure=chemical-peel/'
        with patch.dict(os.environ, {'ENABLE_FIRESTORE':'false', 'ENABLE_DEEP_DISCOVERY':'true',
            'ENABLE_MULTILINGUAL_SEARCH':'true', 'ENABLE_EXA_RESCUE':'true'}), \
            patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
            patch.object(e.GooglePlacesClient, 'configured', False), \
            patch.object(v.ExaClient, 'search', new=AsyncMock(return_value=[e.SearchHit(title='Aster Hospital',url=profile),e.SearchHit(title='Clinics in Turkey',url=category)])), \
            patch.object(e, 'discover', side_effect=discover):
            await v.run_progressive(e, city='İstanbul', procedure='chemical_peel', country_code='TR',
                stored_pool=[], desired_new=6, limit=8, display_limit=4, debug=False,
                app_fast=True, background_collection=False, client_known_clinic_hosts=[])
        exa = next(r for r in requests if r.progressive_stage == 'exa')
        self.assertEqual(exa.priority_site_urls, [profile])
        self.assertEqual(sum(r.serper_request_cap for r in requests), 4)

    async def test_sparse_local_prices_try_provider_platforms_within_four_searches(self):
        requests = []
        async def discover(req):
            requests.append(req)
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, country_code='TR',
                queries=req.query_override or [], results=[], searched_urls=0, fetched_pages=0,
                diagnostics=e.DiscoveryDiagnostics(serper_requests_attempted=len(req.query_override or [])))
        with patch.dict(os.environ, {'ENABLE_FIRESTORE':'false', 'ENABLE_DEEP_DISCOVERY':'true',
            'ENABLE_MULTILINGUAL_SEARCH':'true', 'ENABLE_EXA_RESCUE':'false'}), \
            patch.object(e, 'firestore_load_clinic_directory', new=AsyncMock(return_value=[])), \
            patch.object(e.GooglePlacesClient, 'configured', False), \
            patch.object(e, 'discover', side_effect=discover):
            await v.run_progressive(e, city='İstanbul', procedure='chemical_peel', country_code='TR',
                stored_pool=[], desired_new=6, limit=8, display_limit=4, debug=False,
                app_fast=True, background_collection=False, client_known_clinic_hosts=[])
        self.assertEqual([r.progressive_stage for r in requests], ['marketplace','local'])
        self.assertTrue(any('site:bookimed.com/clinic/' in q for q in requests[0].query_override))
        self.assertTrue(any('site:whatclinic.com' in q for q in requests[0].query_override))
        self.assertLessEqual(sum(r.serper_request_cap for r in requests), 4)


if __name__ == '__main__':
    unittest.main()
