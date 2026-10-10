"""The backend cannot count amounts the app will reject as display-ready."""
import unittest

from price_fixtures import e, quote
from amount_policy import plausible_amount_band, procedure_amount_is_plausible


class AmountPolicy(unittest.TestCase):
    def test_surgical_total_and_explicit_unit_rate_have_different_scope(self):
        self.assertFalse(procedure_amount_is_plausible(290, 'EUR', 'rhinoplasty'))
        self.assertFalse(procedure_amount_is_plausible(18, 'EUR', 'hair_transplant', 'FUE 18–45 €'))
        self.assertTrue(procedure_amount_is_plausible(18, 'EUR', 'hair_transplant', 'FUE 18 € per graft'))
        self.assertFalse(procedure_amount_is_plausible(18, 'EUR', 'hair_transplant', 'effective cost per graft 18 €'))
        self.assertTrue(procedure_amount_is_plausible(1500, 'USD', 'rhinoplasty'))
        self.assertTrue(procedure_amount_is_plausible(5, 'EUR', 'botox', 'Botox 5 € per unit'))
        self.assertFalse(procedure_amount_is_plausible(5, 'EUR', 'botox', 'Botox session 5 €'))

    def test_currency_bands_match_existing_client_policy_without_conversion(self):
        self.assertEqual(plausible_amount_band('TRY', 'rhinoplasty'), (15000, 3500000))
        self.assertEqual(plausible_amount_band('RON', 'hair_transplant'), (1500, 500000))
        self.assertEqual(plausible_amount_band('GBP', 'breast_augmentation'), (4000, 100000))
        self.assertEqual(plausible_amount_band('AED', 'botox'), (8, 3200))
        self.assertEqual(plausible_amount_band('KRW', 'filler'), (12000, 10000000))

    def test_ineligible_fresh_and_cached_totals_do_not_count_as_ready(self):
        row = quote()
        for procedure, amount, label in [
            ('rhinoplasty', 290, 'Nasal Surgery (Rhinoplasty)'),
            ('hair_transplant', 18, 'FUE - Follicular Unit Extraction'),
        ]:
            raw = f'{label} | {amount} EUR'
            evidence = e.ExtractedEvidence(
                price_min=amount, currency='EUR', raw_procedure_text=procedure,
                raw_price_text=f'{amount} EUR', raw_evidence=raw,
                source_url=row.source_url, extraction_method='table_row')
            self.assertEqual(e.validate_evidence(evidence, raw)[3], 'implausible_amount')
            cached = row.model_copy(update={'procedure_canonical': procedure,
                'raw_procedure_text': label, 'raw_evidence': raw,
                'price_min': amount, 'price_max': None, 'currency': 'EUR'})
            self.assertFalse(e.trusted_price_result(cached))
            self.assertFalse(e._app_can_show_row(cached))
            self.assertEqual(e.trusted_price_failure(cached), 'implausible_amount')


if __name__ == '__main__':
    unittest.main()
