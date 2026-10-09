"""Shared multilingual regressions for real treatments versus product names."""
import json
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

from price_fixtures import e, quote
from injectable_scope import injectable_scope_rejection
from test_treatment_scope_regressions import accepted

ROOT = Path(__file__).resolve().parents[2]
CASES = json.loads((ROOT / 'test/fixtures/injectable_scope_cases.json').read_text())


class InjectableScope(unittest.TestCase):
    def test_shared_worldwide_cases(self):
        for case in CASES:
            with self.subTest(case=case['id']):
                self.assertEqual(injectable_scope_rejection(
                    case['procedure'], case['label'], case['evidence'],
                    case['provider'], case['source_url']), case['expected'])

    def test_legacy_flags_cannot_certify_hair_products_creams_or_pens(self):
        base = quote(city='Madrid')
        for case in CASES:
            if case['expected'] is None:
                continue
            with self.subTest(case=case['id']):
                row = base.model_copy(update={
                    'procedure_canonical': case['procedure'],
                    'raw_procedure_text': case['label'],
                    'raw_evidence': case['evidence'] + ' | 350 EUR',
                    'procedure_detail': '', 'price_min': 350, 'currency': 'EUR',
                    'clinic_name': case['provider'], 'source_url': case['source_url'],
                    'source_type': e.classify_source(case['source_url']),
                    'official_price_found': True, 'official_procedure_verified': True,
                })
                self.assertFalse(e.trusted_price_result(row))
                self.assertEqual(e.trusted_price_failure(row), case['expected'])

    def test_topical_row_cannot_borrow_the_injectable_heading(self):
        body = ('<h2>Dermal fillers</h2><table>'
                '<tr><td>Dermal filler crema cosmética</td><td>350 EUR</td></tr>'
                '<tr><td>Relleno de labios con inyecciones 1 ml</td><td>330 EUR</td></tr></table>')
        self.assertEqual({r.price_min for r in accepted(body, 'filler')}, {330})

    def test_anesthesia_does_not_disqualify_the_injection(self):
        self.assertTrue(accepted('<p>Our lip filler with numbing cream 350 EUR</p>', 'filler'))

    def test_source_without_priced_filler_cannot_supply_a_filler_card(self):
        self.assertFalse(accepted('<h2>Dermatology</h2><p>Our facial cream 350 EUR</p>'
                                  '<p>We do not offer dermal fillers.</p>', 'filler'))

    @staticmethod
    def fresha_page(offers, body=''):
        return ('<html><title>Aster Nails - Madrid | Fresha</title>'
                '<script type="application/ld+json">' + json.dumps(offers) + '</script>'
                + body + '</html>')

    @staticmethod
    def offer(category, description, price=199):
        return {'@type': 'Offer', 'price': price, 'priceCurrency': 'EUR',
                'url': 'https://www.fresha.com/a/aster-nails-madrid/booking?offerItemId=s:2',
                'category': category, 'itemOffered': {'@type': 'Service',
                'name': 'Aumento de labios', 'category': category, 'description': description}}

    def test_authoritative_fresha_menu_does_not_fall_back_to_unqualified_prose(self):
        html = self.fresha_page([
            self.offer('OFERTAS', 'INCLUYE 1 VIAL', 150),
            self.offer('HYALURON PEN', 'INCLUYE 1 VIAL', 199)],
            '<h2>Aumento de labios</h2><p>150 EUR</p>')
        self.assertEqual(e.extract_price_evidence(html,
            'https://www.fresha.com/a/aster-nails-madrid', 'filler'), [])

    def test_captured_public_fresha_offers_do_not_certify_medical_fillers(self):
        html = (ROOT / 'test/fixtures/cleopatra_fresha_offers.html').read_text()
        self.assertEqual(e.extract_price_evidence(html,
            'https://www.fresha.com/a/cleopatra-nails-madrid-calle-arroyo-21-wmsg3rrr', 'filler'), [])

    def test_fresha_preserves_the_exact_service_technique_and_offer_identity(self):
        html = self.fresha_page([self.offer('MEDICINA ESTÉTICA', 'Inyecciones. INCLUYE 1 VIAL', 330)])
        rows = e.extract_price_evidence(html, 'https://www.fresha.com/a/aster-nails-madrid', 'filler')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].price_min, 330)
        self.assertEqual(rows[0].unit, 'vial')
        self.assertIn('MEDICINA ESTÉTICA', rows[0].raw_evidence)
        self.assertIn('Inyecciones', rows[0].raw_evidence)
        self.assertIn('offerItemId=s:2', rows[0].source_url)

    def test_booksy_bare_botox_at_hair_nail_provider_is_rejected(self):
        html = ('<html><title>Aster Hair Nails Studio</title>'
                '<div data-testid="services-list-item-root">'
                '<span data-testid="service-name">Tratamiento Botox</span>'
                '<span data-testid="service-variant-price">80 EUR</span></div></html>')
        self.assertEqual(e.extract_price_evidence(html,
            'https://booksy.com/es-es/123_aster-hair-nails-studio_53009_madrid', 'botox'), [])


class CachedScopeCleanup(unittest.IsolatedAsyncioTestCase):
    async def test_normal_cache_cleanup_marks_noninjectable_evidence_inactive(self):
        base = quote(city='Madrid')
        row = base.model_copy(update={'clinic_name': 'Aster Hair Nails Studio',
            'raw_procedure_text': 'Tratamiento Botox', 'raw_evidence': 'Tratamiento Botox | 80 EUR',
            'procedure_detail': '', 'price_min': 80, 'currency': 'EUR'})
        document = MagicMock()
        document.to_dict.return_value = {'active': True, 'result': row.model_dump()}
        client = MagicMock()
        client.collection.return_value.where.return_value.limit.return_value.stream.return_value = [document]
        with patch.object(e, 'firestore_enabled', return_value=True), \
                patch.object(e, '_firestore_client', return_value=client):
            self.assertEqual(await e.firestore_deactivate_weak_results('Madrid', 'botox'), 1)
        payload = document.reference.set.call_args.args[0]
        self.assertFalse(payload['active'])
        self.assertEqual(payload['inactive_reason'], 'noninjectable_botox')


if __name__ == '__main__':
    unittest.main()
