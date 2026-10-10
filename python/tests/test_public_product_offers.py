"""Product themes must preserve treatment scope and the current own price."""
import socket
import json
import unittest
from unittest.mock import patch

from price_fixtures import e, quote
from test_treatment_scope_regressions import accepted


def product(label, amount, old=''):
    price = f'<del>€{old}</del><ins>€{amount}</ins>' if old else f'€{amount}'
    return ('<li class="product"><div><header><h2><a>' + label + '</a></h2></header>'
            '<span class="price">' + price + '</span></div></li>')


class ProductOffers(unittest.TestCase):
    def setUp(self):
        blocker = patch.object(socket.socket, 'connect', side_effect=AssertionError('Network disabled'))
        blocker.start()
        self.addCleanup(blocker.stop)

    def test_custom_headers_keep_single_surgery_price_and_drop_combo_prefixes(self):
        body = '<ul class="products">' + ''.join([
            product('Breast Augmentation All-Inclusive Package', '4300'),
            product('Non-Surgical Breast Augmentation Package', '8200'),
            product('360 Lipo + Breast Augmentation', '6100', '8000'),
            product('Breast Augmentation + Rhinoplasty', '6500'),
            product('Best Friends Breast Augmentation Package (2 People)', '6900'),
        ]) + '</ul>'
        rows = accepted(body, 'breast_augmentation', 'https://aster.example/packages/')
        self.assertEqual({r.price_min for r in rows}, {4300})
        self.assertTrue(all(r.clinic_own_price for r in rows))
        self.assertTrue(any('All-inclusive package' in r.procedure_detail for r in rows))

    def test_summary_title_is_not_required_to_have_default_product_class(self):
        rows = accepted('<div class="summary entry-summary"><header><h2>'
                        'Breast Augmentation All-Inclusive Package</h2></header>'
                        '<p class="price">€4300</p></div>',
                        'breast_augmentation', 'https://aster.example/breast-package/')
        self.assertEqual({r.price_min for r in rows}, {4300})
        self.assertTrue(all(r.clinic_own_price for r in rows))

    def test_single_rhinoplasty_sale_keeps_current_amount_and_conditions(self):
        body = '<ul class="products">' + product(
            'Closed Rhinoplasty All-Inclusive Package', '3200', '3700') + product(
            'Hair Transplant + Rhinoplasty', '5100', '5900') + '</ul>'
        rows = accepted(body, 'rhinoplasty', 'https://aster.example/packages/')
        self.assertEqual({r.price_min for r in rows}, {3200})
        html = '<html><title>Aster Clinic</title>' + body + '</html>'
        evidence = e.extract_price_evidence(html, 'https://aster.example/packages/', 'rhinoplasty')
        offer = next(ev for ev in evidence if ev.extraction_method == 'woocommerce_service_offer')
        self.assertEqual(offer.original_price_min, 3700)
        self.assertEqual(offer.qualifier, 'promo')
        self.assertIn('All-inclusive package', rows[0].procedure_detail)

    def test_nested_product_cannot_supply_its_price_to_outer_unpriced_title(self):
        body = ('<ul class="products"><li class="product"><h2>Breast Augmentation</h2>'
                + product('Hair Transplant + Rhinoplasty', '5100') + '</li>'
                + product('Breast Augmentation', '4300') + '</ul>')
        self.assertEqual({r.price_min for r in accepted(body, 'breast_augmentation')}, {4300})

    def test_cached_surgery_combo_is_rejected_even_when_evidence_lost_prefix(self):
        for canonical, label in [
            ('breast_augmentation', '360 Lipo + Breast Augmentation'),
            ('rhinoplasty', 'Hair Transplant + Rhinoplasty'),
            ('hair_transplant', 'Hair Transplant + Rhinoplasty'),
            ('breast_augmentation', 'Non-Surgical Breast Augmentation'),
        ]:
            row = quote(amount=5100).model_copy(update={
                'procedure_canonical': canonical, 'currency': 'EUR',
                'raw_procedure_text': label,
                'raw_evidence': e.display_name(canonical) + ' | 5100 EUR',
            })
            self.assertFalse(e.trusted_price_result(row), label)
            self.assertEqual(e.trusted_price_failure(row), 'package_not_procedure', label)

    def test_own_product_tariff_is_not_rejected_for_unrelated_article_intro(self):
        body = ('<h1>Breast augmentation</h1><p>Average cost in other clinics varies.</p>'
                '<ul class="products">' + product('Breast Augmentation Package', '4300') + '</ul>')
        self.assertEqual({r.price_min for r in accepted(body, 'breast_augmentation',
                         'https://aster.example/services/breast/')}, {4300})

    def test_branded_fee_clause_keeps_owner_and_excludes_same_paragraph_market_range(self):
        body = ('<h1>Breast augmentation</h1><p>Breast augmentation in Turkey is often '
                'quoted at approximately €3400–€5200. Aster breast augmentation packages '
                'start from €4300, with the final quote confirmed after assessment.</p>')
        rows = accepted(body, 'breast_augmentation', 'https://aster.example/blog/breast/')
        self.assertEqual({r.price_min for r in rows}, {4300})
        self.assertTrue(all(r.clinic_own_price and r.qualifier == 'from' for r in rows))
        self.assertTrue(all('Aster breast augmentation' in r.raw_evidence for r in rows))

    def test_named_fee_preserves_unpriced_implant_exclusion(self):
        rows = accepted('<p>Aster breast augmentation starts from €4300. '
                        'Implant cost is excluded.</p>', 'breast_augmentation')
        self.assertTrue(rows)
        self.assertTrue(all('Implant cost is excluded' in r.raw_evidence for r in rows))
        self.assertTrue(all(e.implant_cost_excluded(r.raw_evidence) for r in rows))

    def test_other_providers_brand_does_not_own_the_articles_market_range(self):
        body = ('<p>Other Clinic breast augmentation packages start from €4300.</p>'
                '<p>Aster explains that average breast augmentation costs in Turkey '
                'are €3400–€5200 across other clinics.</p>')
        self.assertFalse(accepted(body, 'breast_augmentation', 'https://aster.example/blog/breast/'))

    def test_own_package_prose_does_not_become_the_procedure_title(self):
        statement = ('Aster Clinic offers a fully transparent Rhinoplasty package '
                     'starting from €3200 with no hidden charges.')
        rows = accepted('<p>' + statement + '</p>', 'rhinoplasty')
        self.assertTrue(rows)
        self.assertTrue(all(row.procedure_display_name == 'Rhinoplasty' for row in rows))

    def test_medical_business_schema_beats_a_staff_physician_on_the_same_host(self):
        graph = [
            {'@type': ['MedicalBusiness', 'Organization'], 'name': 'Aster Clinic',
             'url': 'https://aster.example/'},
            {'@type': 'Physician', 'name': 'Dr. Jane Example',
             'url': 'https://aster.example/our-doctor/'},
        ]
        html = '<script type="application/ld+json">' + json.dumps(graph) + '</script>'
        self.assertEqual(e.structured_business_name(html, 'Madrid', 'https://aster.example/', True),
                         'Aster Clinic')

    def test_custom_current_and_retired_price_classes_bind_to_one_package(self):
        body = ('<section><div><h1>All-Inclusive Breast Augmentation Package</h1>'
                '<div><span class="ba-hero-price-current">€4300</span>'
                '<span class="ba-hero-price-old">€6100</span></div>'
                '<span>Save 30% - All-Inclusive Package</span></div></section>'
                '<p>Average breast augmentation costs in other clinics vary.</p>')
        rows = accepted(body, 'breast_augmentation', 'https://aster.example/breast-package/')
        self.assertEqual({row.price_min for row in rows}, {4300})
        self.assertTrue(all(row.qualifier == 'promo' for row in rows))
        self.assertTrue(all('All-inclusive package' in row.procedure_detail for row in rows))
        evidence = e.extract_price_evidence(body, 'https://aster.example/breast-package/', 'breast_augmentation')
        self.assertEqual(next(ev for ev in evidence if ev.extraction_method == 'current_service_offer').original_price_min, 6100)

    def test_custom_current_markup_cannot_certify_a_market_comparison(self):
        body = ('<div><h1>Average Breast Augmentation Cost</h1>'
                '<span class="hero-price-current">€4300</span>'
                '<span class="hero-price-old">€6100</span></div>')
        self.assertFalse(accepted(body, 'breast_augmentation', 'https://aster.example/blog/comparison/'))
