"""Location and tariff ownership regressions using fictional offline pages."""
import socket
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
with patch.object(dotenv, "load_dotenv", return_value=False):
    import aesthetic_price_discovery_v11_67 as e


class CityAndBranchOwnership(unittest.TestCase):
    def setUp(self):
        blocker = patch.object(socket.socket, "connect", side_effect=AssertionError("Network disabled"))
        blocker.start()
        self.addCleanup(blocker.stop)

    def test_city_names_are_complete_tokens(self):
        for text, city in [
            ("A comparison of Botox prices", "Paris"),
            ("Aromatherapy clinic", "Roma"),
            ("Romanian clinic", "Roma"),
            ("Milana Medical Clinic", "Milan"),
            ("Londoners enjoy this treatment", "London"),
        ]:
            with self.subTest(text=text, city=city):
                self.assertFalse(e.city_in_text(text, city))

    def test_priced_treatment_name_beats_generic_botox_heading(self):
        self.assertEqual(e.published_procedure_display_name(
            'botox', 'Botox', 'Toxina botulínica (3 zonas) | 250 €', '250 €'),
            'Toxina botulínica (3 zonas)')

    def test_city_tokens_preserve_aliases_accents_and_url_separators(self):
        for text, city in [
            ("Our clinic in PARIS.", "Paris"),
            ("București, Romania", "Bucharest"),
            ("Tiranë clinic", "Tirana"),
            ("Botox in Abu-Dhabi", "Abu Dhabi"),
            ("/botox_in_abu_dhabi/", "Abu Dhabi"),
            ("/prices/new-york/", "New York"),
            ("Brooklyn, NY", "New York"),
        ]:
            with self.subTest(text=text, city=city):
                self.assertTrue(e.city_in_text(text, city))

    def test_substrings_do_not_create_foreign_city_conflicts(self):
        for text in ["Aromatherapy clinic", "A comparison of prices", "Milana Medical Clinic"]:
            with self.subTest(text=text):
                self.assertEqual(e.foreign_city_conflict(text, "Dubai"), "")
        self.assertEqual(e.foreign_city_conflict("Our clinic in Rome", "Dubai"), "rome")

    def test_comparison_word_cannot_supply_paris_contact_location(self):
        html = ("<html><title>Aster Clinic</title><h2>Botox</h2>"
                "<p>Botox 200 EUR</p><footer>A comparison of treatment prices</footer></html>")
        self.assertFalse(e.strong_local_page_evidence(
            html, e.page_text(html), "Paris", "https://aster.example/"))

    def test_explicit_foreign_tariff_scope_beats_local_seo_and_footer_mentions(self):
        for evidence, city in [
            ("Botox Dubai | Prices in Abu Dhabi: Botox AED 700", "Dubai"),
            ("Botox prices in Abu Dhabi Our Botox treatment 700 AED Dubai and Abu Dhabi", "Dubai"),
            ("Botox Valencia | Precio del injerto capilar en Oviedo | Nuestro precio es 3090€", "Valencia"),
        ]:
            with self.subTest(evidence=evidence):
                self.assertTrue(e.foreign_quoted_price_city(evidence, city))

    def test_shared_branch_scope_and_local_price_stay_valid(self):
        for evidence in [
            "Prices in Dubai: Botox AED 700",
            "Prices in Abu Dhabi and Dubai: Botox AED 700",
            "Prices in Dubai and Abu Dhabi: Botox AED 700",
            "Botox 700 AED | Our clinics in Dubai and Abu Dhabi",
        ]:
            with self.subTest(evidence=evidence):
                self.assertFalse(e.foreign_quoted_price_city(evidence, "Dubai"))

    def test_broad_extraction_cannot_rescue_a_foreign_branch_tariff(self):
        html = ("<html><title>Botox prices Dubai | Aster clinic</title>"
                "<h2>Botox prices in Abu Dhabi</h2><p>Our Botox treatment 700 AED</p>"
                "<footer>Dubai and Abu Dhabi</footer></html>")
        rows = e.extract_price_evidence(html, "https://aster.example/prices/", "botox")
        self.assertTrue(rows, "The fixture must produce evidence to exercise validation")
        self.assertFalse([row for row in rows if e.validate_evidence(
            row, e.page_text(html), html, "Dubai")[0]])


if __name__ == "__main__":
    unittest.main()
