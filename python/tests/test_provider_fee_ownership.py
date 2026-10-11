"""Clinic fees must stay separate from literal city/country estimates.

The Nişantaşı paragraph and Clineca DOM fragments were read live on
2026-10-10. The remaining fictional articles exercise the same ownership
boundary without claiming that blocked third-party pages were fetched.
"""
import unittest

from price_fixtures import e, quote


class ProviderFeeOwnership(unittest.TestCase):
    def accepted(self, html, url="https://aster.example/rhinoplasty/", procedure="rhinoplasty"):
        text = e.page_text(html)
        candidates = e.extract_price_evidence(html, url, procedure)
        self.assertTrue(candidates, "Exercise actual extracted price candidates")
        return [row for row in candidates
                if e.validate_evidence(row, text, html, "Istanbul")[0]]

    def test_qa_portal_price_table_is_not_a_treating_clinic(self):
        html = ('<title>Hastalar Soruyor</title><h2>Teosyal Kiss Lip Filler</h2>'
                '<table><tr><td>Teosyal Kiss Lip Filler</td><td>8500 TRY</td></tr></table>')
        self.assertFalse(self.accepted(html, 'https://www.hastalarsoruyor.com/teosyal-kiss/', 'filler'))

    def test_live_hospital_estimate_does_not_become_its_own_fee(self):
        html = ("<title>Nişantaşı Hastanesi</title><h2>Burun estetiği kaç TL 2025?</h2>"
                "<p>Burun estetiği için 2025’te 40.000 ile 380.000 TL arasında "
                "bir fiyat bekleniyor.</p><footer>İstanbul</footer>")
        self.assertFalse(self.accepted(html,
            "https://nisantasihastanesi.com.tr/burun-estetigi/"))

    def test_city_starting_price_is_not_owned_because_booking_is_available(self):
        for statement in [
            "Rhinoplasty prices in Istanbul start from €2,500. Book now.",
            "İstanbul’da rinoplasti fiyatı €2.500'dan başlamaktadır.",
            "Rhinoplasty prices in Quito start from €2,500. Appointment available.",
        ]:
            with self.subTest(statement=statement):
                html = f"<title>Aster Clinic</title><h2>Rhinoplasty</h2><p>{statement}</p>"
                self.assertFalse(self.accepted(html))

    def test_indicative_table_heading_survives_a_compact_row_adapter(self):
        html = ("<title>Aster Clinic</title><h2>Indicative market range</h2>"
                "<table><tr><th>Procedure</th><th>Price</th></tr>"
                "<tr><td>Rhinoplasty</td><td>€2,000–€5,500</td></tr></table>")
        self.assertFalse(self.accepted(html))

    def test_owned_quote_in_same_article_survives_country_estimate(self):
        html = ("<title>Aster Clinic</title><h1>Rhinoplasty costs</h1>"
                "<p>Rhinoplasty prices in Turkey generally range from €2,000 to €5,500.</p>"
                "<p>At our clinic the cost of rhinoplasty is $4,000–$5,000.</p>"
                "<address>Our clinic: Istanbul</address>")
        rows = self.accepted(html, "https://aster.example/blog/rhinoplasty-prices/")
        self.assertTrue(rows)
        self.assertEqual({(r.price_min, r.price_max, r.currency) for r in rows},
                         {(4000, 5000, "USD")})

    def test_dutch_own_clinic_fee_is_distinct_from_country_prose(self):
        html = ("<title>Aster Clinic</title><h1>Neuscorrectie</h1>"
                "<p>Neuscorrectie prijzen in Turkije: €2,000–€5,500.</p>"
                "<p>In onze kliniek kost een primaire neuscorrectie $4,000–$5,000.</p>"
                "<address>Istanbul</address>")
        rows = self.accepted(html, "https://aster.example/nl/neuscorrectie/")
        self.assertEqual({(r.price_min, r.price_max, r.currency) for r in rows},
                         {(4000, 5000, "USD")})

    def test_live_clineca_menu_preserves_range_and_rejects_neighbor_fragment(self):
        html = ("<title>Clineca Istanbul</title><h2>Pricing &amp; what’s included</h2>"
                '<div><a class="fact"><div class="k">Ear Surgery</div>'
                '<div class="v">€3,375–4,800</div></a>'
                '<a class="fact"><div class="k">Rhinoplasty</div>'
                '<div class="v">€2,500–3,800</div></a>'
                '<a class="fact"><div class="k">Teeth Veneers</div>'
                '<div class="v">€2,500–6,000</div></a></div>')
        rows = self.accepted(html, "https://www.clineca.com/pricing")
        self.assertTrue(rows)
        self.assertEqual({(r.price_min, r.price_max) for r in rows}, {(2500, 3800)})

    def test_citywide_example_and_no_online_fee_disclaimer_is_not_a_provider_tariff(self):
        html = ("<title>Aster Clinic</title><h2>Burun Estetiği Fiyatları</h2>"
                "<p>Mevzuat gereği internet ortamında net fiyat paylaşımı yapılmamaktadır. "
                "İstanbul genelinde burun estetiği fiyatları geniş bir aralıkta değerlendirilmektedir. "
                "İlk kez burun estetiği olacak hastalarda fiyatlar örneğin; 75.000 TL – 150.000 TL "
                "aralığından başlarken, daha kapsamlı işlemlerde maliyetler değişir.</p>")
        self.assertFalse(self.accepted(html))

    def test_saved_owned_flag_cannot_certify_market_article(self):
        for raw in [
            "Rhinoplasty prices in Istanbul start from €2,500. Book now.",
            "Burun estetiği için 40.000 ile 380.000 TL arasında bir fiyat bekleniyor.",
        ]:
            is_try = "TL" in raw
            row = quote().model_copy(update={
                "source_url": "https://aster.example/rhinoplasty/",
                "procedure_canonical": "rhinoplasty", "procedure_detail": "",
                "raw_procedure_text": "Rhinoplasty", "raw_evidence": raw,
                "price_min": 40000 if is_try else 2500,
                "price_max": 380000 if is_try else None,
                "currency": "TRY" if is_try else "EUR",
                "evidence_type": "official_treatment_page", "clinic_own_price": True,
            })
            with self.subTest(raw=raw):
                self.assertFalse(e.trusted_price_result(row))
                self.assertTrue(e.trusted_price_failure(row))

    def test_original_owned_menu_is_allowed_for_any_city(self):
        for city in ["Istanbul", "Ankara", "Quito"]:
            html = ("<title>Aster Clinic</title><h1>Our prices</h1>"
                    "<table><tr><td>Rhinoplasty</td><td>€2,500–€3,800</td></tr></table>"
                    f"<address>{city}</address>")
            rows = self.accepted(html, "https://aster.example/pricing")
            self.assertEqual({(r.price_min, r.price_max) for r in rows}, {(2500, 3800)})


if __name__ == "__main__":
    unittest.main()
