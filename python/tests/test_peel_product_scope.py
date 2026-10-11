"""Real verifier regressions for peel treatment fees versus retail amounts."""
import json
from pathlib import Path
import unittest

from price_fixtures import e, quote
from test_treatment_scope_regressions import accepted

CASES = json.loads((Path(__file__).resolve().parents[2] /
                    'test/fixtures/peel_product_scope_cases.json').read_text())


class PeelProductScope(unittest.TestCase):
    def test_shared_cases_through_extraction_and_serving_gate(self):
        for case in CASES:
            with self.subTest(case=case['id']):
                body = (f"<table><tr><td>{case['amount']} EUR</td>"
                        f"<td>{case['label']}</td></tr></table>" if case.get('price_first') else
                        f"<p>{case['label']} | {case['amount']} EUR</p>")
                rows = accepted(f"<h2>Our clinic prices</h2>{body}", 'chemical peel',
                                case.get('url', 'https://aster.example/prices/'))
                self.assertEqual({r.price_min for r in rows},
                                 set() if case['reject'] else {case['amount']})

    def test_mixed_menu_keeps_session_but_not_retail_row(self):
        rows = accepted('<h2>Chemical peel prices</h2><table>'
                        '<tr><td>Our PRX-T33 bottle 4 ml</td><td>85 EUR</td></tr>'
                        '<tr><td>Our PRX-T33 facial treatment per session</td>'
                        '<td>180 EUR</td></tr></table>', 'chemical peel')
        self.assertEqual({r.price_min for r in rows}, {180})

    def test_cached_product_cannot_be_certified_by_legacy_flags(self):
        base = quote(city='Madrid')
        for case in CASES:
            if not case['reject'] or 'url' in case:
                continue
            with self.subTest(case=case['id']):
                row = base.model_copy(update={
                    'procedure_canonical': 'chemical_peel',
                    'raw_procedure_text': case['label'], 'procedure_detail': '',
                    'raw_evidence': f"{case['label']} | {case['amount']} EUR",
                    'price_min': case['amount'], 'currency': 'EUR',
                    'official_price_found': True, 'official_procedure_verified': True,
                })
                self.assertFalse(e.trusted_price_result(row))
                self.assertEqual(e.trusted_price_failure(row), 'peel_product_not_procedure')


if __name__ == '__main__':
    unittest.main()
