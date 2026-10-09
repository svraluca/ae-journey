"""Source ownership, price-line binding, packages and currency preservation."""
import json
from pathlib import Path
import unittest
from price_fixtures import e, quote

CASES = json.loads((Path(__file__).parents[2] / 'verification/fixtures/tariff_scope.json').read_text())


class TariffScope(unittest.TestCase):
    def test_fresh_evidence_obeys_the_same_price_owner_rules(self):
        for case in CASES:
            evidence = e.ExtractedEvidence(raw_procedure_text=case['procedure'],
                raw_price_text=f"{case['amount']} {case['currency']}", price_min=case['amount'],
                currency=case['currency'], raw_evidence=case['evidence'],
                source_url='https://aster.example/prices/', extraction_method='table_row')
            with self.subTest(case=case['name']):
                result = e.validate_evidence(evidence, case['evidence'], city='Istanbul')
                self.assertEqual(result[0], case['accepted'], result[3])
                if not case['accepted']:
                    self.assertEqual(result[3], case['reason'])

    def test_saved_rows_obey_shared_price_owner_cases(self):
        for case in CASES:
            row = quote().model_copy(update={
                'procedure_canonical':case['canonical'], 'raw_procedure_text':case['procedure'],
                'procedure_detail':'', 'price_min':case['amount'], 'price_max':None,
                'currency':case['currency'], 'raw_evidence':case['evidence']})
            with self.subTest(case=case['name']):
                failure = e.trusted_price_failure(row)
                self.assertEqual(not bool(failure), case['accepted'], failure)
                if not case['accepted']:
                    self.assertEqual(failure, case['reason'])

    def test_country_tables_cannot_supply_fees_for_any_procedure(self):
        headings = ['Ülkelere Göre Fiyatlar', 'Şehirlere Göre Fiyatlar',
                    'Prices by country', 'Cost across cities', 'Precios por países',
                    'Prix par pays', 'Preise nach Land', 'Prezzi per paese']
        for canonical, label in [('botox','Botox'), ('filler','Dermal filler'),
                ('chemical_peel','Chemical peel'), ('rhinoplasty','Rhinoplasty'),
                ('breast_augmentation','Breast augmentation'), ('hair_transplant','Hair transplant')]:
            for heading in headings:
                html = (f'<title>Aster Clinic</title><h1>{label}</h1><h2>{heading}</h2>'
                        f'<table><tr><th>Country</th><th>{label} price</th></tr>'
                        f'<tr><td>{label} Turkey</td><td>€3,000</td></tr>'
                        f'<tr><td>{label} France</td><td>€6,000</td></tr></table><footer>Istanbul</footer>')
                with self.subTest(procedure=canonical, heading=heading):
                    rows = e.extract_price_evidence(html, 'https://aster.example/prices/', canonical)
                    self.assertFalse(any(e.validate_evidence(r, e.page_text(html), html, 'Istanbul')[0] for r in rows))

    def test_owned_parallel_currency_menu_preserves_base_and_graft_condition(self):
        html = ('<title>Aster Clinic</title><h2>Aster Clinic Hair Transplant Prices</h2><table>'
                '<tr><th>Package</th><th>Price EUR</th><th>Price USD</th></tr>'
                '<tr><td>Micro Sapphire DHI</td><td>From €3,290 (up to 4,000 grafts) + €700 upgrade</td>'
                '<td>From $3,800</td></tr></table><footer>Istanbul</footer>')
        rows = e.extract_price_evidence(html, 'https://aster.example/treatments/', 'hair_transplant')
        menus = [r for r in rows if e.validate_evidence(r,e.page_text(html),html,'Istanbul')[0]]
        self.assertTrue(menus)
        self.assertEqual({(r.price_min,r.currency) for r in menus}, {(3290,'EUR')})
        self.assertTrue(all('4,000 grafts' in r.raw_evidence and 'DHI' in r.raw_procedure_text for r in menus))
        self.assertTrue(all('up to 4,000 grafts' in e.procedure_detail(r.raw_evidence,'hair_transplant',r.raw_price_text)
                            for r in menus))

    def test_whatclinic_does_not_invent_a_base_currency(self):
        for currency, low, high in [('EUR',800,900),('RON',4276,4810)]:
            html = (f'<title>Aster Clinic</title><p>Istanbul</p><div data-id="41">'
                    f'<span class="name">Chemical Peel</span><span class="price_container">'
                    f'<span class="price">{low} {currency}</span> - '
                    f'<span class="price">{high} {currency}</span></span></div>')
            url = 'https://www.whatclinic.com/beauty-clinics/turkey/istanbul/aster-clinic'
            rows = e.extract_price_evidence(html,url,'chemical_peel')
            menus = [r for r in rows if e.validate_evidence(r,e.page_text(html),html,'Istanbul')[0]]
            self.assertTrue(menus)
            self.assertEqual({(r.price_min,r.price_max,r.currency) for r in menus}, {(low,high,currency)})
