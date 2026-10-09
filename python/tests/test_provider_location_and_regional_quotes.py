"""Provider geography must outrank search labels and marketplace offices."""
import json
import unittest
from price_fixtures import e, quote

URL = 'https://us-uk.bookimed.com/clinic/aster-clinic/'


def profile(locality, *, publisher_city='Istanbul'):
    data = {'@type': 'MedicalWebPage', 'url': URL, 'mainEntity': {
        '@type': 'Hospital', 'url': URL, 'name': 'Aster Clinic',
        'address': {'addressLocality': locality}}, 'publisher': {
        '@type': 'Organization', 'address': {'addressLocality': publisher_city}},
        'relatedLink': {'@type': 'Hospital', 'url': URL + 'recommended/',
                        'address': {'addressLocality': publisher_city}}}
    return (f'<title>Aster Clinic</title><h1>Aster Clinic</h1>'
            f'<script type="application/ld+json">{json.dumps(data)}</script>'
            '<p>Chemical Peel cost starts from $72.</p>'
            f'<footer><address>Platform office: {publisher_city}</address></footer>')


class ProviderLocationAndQuotes(unittest.TestCase):
    def test_foreign_profile_cannot_use_platform_office_or_related_provider(self):
        html = profile('Kuala Lumpur')
        self.assertEqual(e.marketplace_provider_locations(html, URL), ['Kuala Lumpur'])
        self.assertFalse(e.strong_local_page_evidence(html, e.page_text(html), 'Istanbul', URL))
        self.assertTrue(e.strong_local_page_evidence(html, e.page_text(html), 'Kuala Lumpur', URL))

    def test_provider_locality_is_not_limited_to_a_static_city_dictionary(self):
        for city in ['Istanbul', 'São Paulo', 'Accra', 'Chiang Mai']:
            html = profile(city, publisher_city='London')
            with self.subTest(city=city):
                self.assertTrue(e.strong_local_page_evidence(html, e.page_text(html), city, URL))
                self.assertFalse(e.strong_local_page_evidence(html, e.page_text(html), 'Madrid', URL))

    def test_global_office_footer_is_not_positive_location_proof(self):
        html = '<title>Aster Clinic</title><h1>Aster Clinic</h1><footer><address>Istanbul</address></footer>'
        self.assertFalse(e.strong_local_page_evidence(html, e.page_text(html), 'Istanbul', URL))

    def test_cached_provider_proof_overrides_generated_search_city(self):
        row = quote(city='Istanbul').model_copy(update={
            'source_location_text': 'Provider locality: Kuala Lumpur'})
        self.assertEqual(e.trusted_price_failure(row), 'foreign_provider_locality')
        self.assertFalse(e.trusted_price_result(row))
        self.assertTrue(e.trusted_price_result(row.model_copy(update={
            'source_location_text': 'Provider locality: Istanbul'})))

    def test_marketplace_cache_without_provider_location_needs_a_source_recheck(self):
        row = quote(city='Istanbul').model_copy(update={
            'source_type': 'marketplace', 'source_url': URL,
            'source_location_text': ''})
        self.assertEqual(e.trusted_price_failure(row), 'marketplace_provider_location_missing')
        self.assertFalse(e.trusted_price_result(row))

    def test_regional_prices_on_local_provider_page_are_not_its_tariff(self):
        html = ('<title>Aster Clinic</title><h1>Liquid Rhinoplasty (Nose Filler)</h1>'
                '<p>Turkey Price: ~€150 – €900 per area/syringe</p>'
                '<p>World Price: €500 – €1,500 per area/syringe</p><footer>Istanbul</footer>')
        rows = e.extract_price_evidence(html, 'https://aster.example/filler/nose/', 'filler')
        self.assertTrue(rows, 'Exercise actual extraction, not an empty fixture')
        self.assertFalse(any(e.validate_evidence(row, e.page_text(html), html, 'Istanbul')[0] for row in rows))

    def test_general_hospital_fee_qa_is_not_a_clinic(self):
        url = 'https://medical-info.example/s-s-s/dudak-dolgu-fiyati/'
        text = 'Devlet hastanelerinde 1 ml hyaluronik asit dolgu fiyatları: 1000 TL'
        self.assertEqual(e.classify_page_source(url, text), 'directory')

    def test_brand_price_examples_on_a_qa_portal_are_not_an_owned_menu(self):
        url = 'https://medical-info.example/s-s-s/1-ml-dudak-dolgusu-fiyat-nedir'
        html = ('<h1>1 ml dudak dolgusu fiyat nedir?</h1>'
                '<p>1 ml dudak dolgusu fiyatı ortalama 6500 TL ile 11000 TL arasındadır.</p>'
                '<p>1 ml dudak dolgusu fiyatlarının bazı örnekleri şunlardır:</p>'
                '<ul><li>Teosyal Kiss: 8.500 TL - 10.500 TL</li></ul>')
        self.assertEqual(e.classify_page_source(url, e.page_text(html)), 'directory')
        rows = e.extract_price_evidence(html, url, 'filler')
        self.assertFalse(any(e.validate_evidence(row, e.page_text(html), html, 'Istanbul')[0] for row in rows))


if __name__ == '__main__':
    unittest.main()
