"""Regressions for layouts reproduced from the public-page audit.

Small fictional pages preserve the relevant markup. No HTTP/API/Firestore calls.
"""
import asyncio
import json
from pathlib import Path
import socket
import sys
import unittest
from unittest.mock import patch

import dotenv
import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
with patch.object(dotenv, "load_dotenv", return_value=False):
    import aesthetic_price_discovery_v11_67 as e


def page(body):
    return ('<html><title>Aster Medical Clinic</title>' + body
            + '<footer>Our clinic: Main Street, Dubai. Book an appointment.</footer></html>')


def accepted(body, url="https://aster.example/services/botox/"):
    html = page(body)
    result = []
    for evidence in e.extract_price_evidence(html, url, "botox"):
        ok, own, confidence, _, kind = e.validate_evidence(evidence, e.page_text(html), html, "Dubai")
        if not ok:
            continue
        row = e.ClinicPriceResult(
            price_extract_revision=e.PRICE_EXTRACT_REVISION,
            clinic_name="Aster Medical Clinic", city="Dubai", procedure_canonical="botox",
            procedure_display_name="Botox", price_min=evidence.price_min,
            price_max=evidence.price_max, currency=evidence.currency, qualifier=evidence.qualifier,
            unit=evidence.unit, source_url=url, source_host=e.host_of(url),
            source_type="official_clinic", evidence_type=kind, clinic_own_price=own,
            city_match=e.strong_local_page_evidence(html, e.page_text(html), "Dubai", url),
            identity_verified=False, confidence=confidence,
            procedure_detail=e.procedure_detail(evidence.raw_evidence, "botox", evidence.raw_price_text),
            raw_procedure_text=evidence.raw_procedure_text, raw_evidence=evidence.raw_evidence,
            official_price_found=True, official_procedure_verified=True,
        )
        if e._app_can_show_row(row):
            result.append((row, evidence))
    return result


class PriceLayouts(unittest.TestCase):
    def setUp(self):
        token = e._hybrid_parse_memo.set({"__city__": "Dubai"})
        self.addCleanup(e._hybrid_parse_memo.reset, token)
        blocker = patch.object(socket.socket, "connect", side_effect=AssertionError("Network disabled"))
        blocker.start()
        self.addCleanup(blocker.stop)

    def test_currency_prefix_price_before_sentence_period(self):
        for literal, amount in [("AED 1,800.", 1800), ("EUR 1.800.", 1800),
                                ("USD 18.50.", 18.5), ("AED 1,800,", 1800)]:
            with self.subTest(literal=literal):
                matches = list(e.iter_exact_price_matches(literal))
                self.assertEqual([value for _, value, _ in matches], [amount])
        found = accepted('<h2>Botox pricing</h2><p>Botox at our clinic starts from AED 1,800.</p>')
        self.assertTrue(found)
        self.assertEqual({row.price_min for row, _ in found}, {1800})

    def test_starting_price_before_brand_in_one_fact_list_is_owned(self):
        found = accepted('<h1>Wrinkle smoothing</h1><ul>'
                         '<li>Starting Price: From 499 AED per area</li>'
                         '<li>Brands Available: Botox, Dysport</li></ul>',
                         "https://aster.example/wrinkle-smoothing/")
        self.assertTrue(found)
        self.assertEqual({(row.price_min, row.unit) for row, _ in found}, {(499, "area")})
        self.assertTrue(all(row.clinic_own_price for row, _ in found))

    def test_price_and_brand_in_separate_lists_do_not_bind(self):
        found = accepted('<h1>Wrinkle smoothing</h1>'
                         '<ul><li>Starting Price: From 499 AED per area</li></ul>'
                         '<h2>Products</h2><ul><li>Brands Available: Botox</li></ul>')
        self.assertFalse(found)

    def test_hair_botox_quick_facts_is_not_injectable(self):
        self.assertFalse(accepted('<h1>Hair Botox</h1><ul>'
                                  '<li>Starting Price: From 499 AED</li>'
                                  '<li>Brands Available: Botox</li></ul>'))

    def test_table_inherits_currency_header_without_pricing_dose_column(self):
        found = accepted('<h2>Botox prices</h2><table><caption>Botox areas</caption>'
                         '<tr><th>Area</th><th>Price Range (AED)</th><th>Units</th></tr>'
                         '<tr><td>Upper face</td><td>700 – 1,500</td><td>35–55</td></tr>'
                         '<tr><td>Lip filler</td><td>800</td><td>1</td></tr></table>')
        self.assertTrue(found)
        self.assertEqual({(row.price_min, row.price_max) for row, _ in found}, {(700, 1500)})

    def test_area_rows_inherit_only_their_table_heading(self):
        found = accepted('<h2>Botox cost</h2><table><tr><th>Option</th><th>Price</th></tr>'
                         '<tr><td>1 Area</td><td>AED 549</td></tr>'
                         '<tr><td>3 Areas</td><td>AED 999</td></tr></table>'
                         '<h2>Chemical peel</h2><table><tr><th>Option</th><th>Price</th></tr>'
                         '<tr><td>1 Area</td><td>AED 350</td></tr></table>')
        self.assertEqual({row.price_min for row, _ in found}, {549, 999})
        details = {row.price_min: row.procedure_detail for row, _ in found}
        self.assertEqual(details[549], "Single area")
        self.assertEqual(details[999], "Three areas")

    def test_per_unit_price_header_is_distinct_from_dose_column(self):
        found = accepted('<h2>Botox prices</h2><table><tr><th>Treatment</th>'
                         '<th>Price per unit (AED)</th><th>Units required</th></tr>'
                         '<tr><td>Botox</td><td>42</td><td>60</td></tr></table>')
        self.assertEqual({(row.price_min, row.unit) for row, _ in found}, {(42, "unit")})

    def test_current_discount_column_cannot_reintroduce_original_price(self):
        found = accepted('<h2>Botox brand prices</h2><table><tr><th>Brand</th>'
                         '<th>After Discount – upper face (AED)</th><th>Price (AED)</th></tr>'
                         '<tr><td>Botox</td><td>700</td><td>900</td></tr></table>')
        self.assertEqual({row.price_min for row, _ in found}, {700})
        self.assertTrue(any(ev.original_price_min == 900 for _, ev in found))

    def test_named_offer_column_is_current_and_preserves_vial_basis(self):
        for offer_heading in ['EN OFERTA', 'On offer', 'Sale price']:
            html = page('<h2>Lip filler prices</h2><table>'
                '<tr><td>Treatment</td><td>Vial</td><td>Price</td>'
                f'<td>{offer_heading}</td></tr>'
                '<tr><td>Lip filler</td><td>1 vial</td><td>400€</td><td>330€</td></tr>'
                '</table>')
            url = 'https://aster.example/lip-filler/'
            candidates = e.extract_price_evidence(html, url, 'filler')
            valid = [ev for ev in candidates if e.validate_evidence(
                ev, e.page_text(html), html, 'Dubai')[0]]
            self.assertTrue(valid, offer_heading)
            self.assertEqual({ev.price_min for ev in valid}, {330})
            chosen = next(ev for ev in valid if ev.extraction_method == 'scoped_tariff_table_row')
            self.assertEqual(chosen.original_price_min, 400)
            self.assertEqual(chosen.qualifier, 'promo')
            self.assertIn('1 vial', chosen.raw_procedure_text)

    def test_no_currency_is_guessed_from_the_search_city(self):
        found = accepted('<h2>Botox prices</h2><table><tr><th>Option</th><th>Price</th></tr>'
                         '<tr><td>Upper face</td><td>700</td></tr></table>')
        self.assertFalse(found)

    def test_comparison_article_table_is_not_owned_clinic_tariff(self):
        found = accepted('<h1>Botox prices compared across other clinics</h1>'
                         '<p>Average cost in other clinics varies.</p><table><caption>Botox prices</caption>'
                         '<tr><th>Area</th><th>Price (AED)</th></tr>'
                         '<tr><td>Upper face</td><td>700</td></tr></table>',
                         "https://aster.example/blog/botox-price-comparison/")
        self.assertFalse(found)

    def test_shared_city_path_and_foreign_only_path_remain_distinct(self):
        shared = "https://clinic.example/services/botox-in-abu-dhabi-and-al-ain/"
        self.assertFalse(e.foreign_price_source_path(shared, "Abu Dhabi"))
        self.assertFalse(e.foreign_price_source_path(shared, "Al Ain"))
        self.assertTrue(e.foreign_price_source_path(shared, "Dubai"))
        self.assertTrue(e.foreign_price_source_path(
            "https://abudhabi.example/botox-in-dubai/?q=abu-dhabi", "Abu Dhabi"))
        self.assertTrue(e.foreign_price_source_path("https://clinic.example/botox-al-ain/", "Abu Dhabi"))

    def test_multiple_structured_branches_select_the_search_city_identity(self):
        data = [
            {"@type": "MedicalClinic", "name": "Cedar Medical Clinic",
             "address": {"addressLocality": "Dubai"}},
            {"@type": "MedicalClinic", "name": "Aster Medical Clinic",
             "address": {"addressLocality": "Abu Dhabi"}},
        ]
        html = '<script type="application/ld+json">' + json.dumps(data) + '</script>'
        self.assertEqual(e.guess_clinic_name_from_html(html, "https://clinic.example/", city="Dubai"),
                         "Cedar Medical Clinic")
        self.assertEqual(e.guess_clinic_name_from_html(html, "https://clinic.example/", city="Abu Dhabi"),
                         "Aster Medical Clinic")

    def test_published_cosmetic_scope_beats_mixed_headline_range(self):
        found = accepted('<h2>Botox price list</h2>'
                         '<p>Our Botox prices start from AED 200–3,700.</p>'
                         '<table><caption>Botox areas</caption><tr><th>Area</th><th>Price (AED)</th></tr>'
                         '<tr><td>Upper face</td><td>700 – 1,500</td></tr>'
                         '<tr><td>Gummy smile</td><td>200 – 600</td></tr></table>')
        selected = e.dedupe_live_results([row for row, _ in found])
        self.assertEqual(len(selected), 1)
        self.assertEqual((selected[0].price_min, selected[0].price_max), (700, 1500))


class FetchEvidence(unittest.IsolatedAsyncioTestCase):
    async def test_health_reports_matching_parser_and_worker_versions(self):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=e.app),
                                     base_url="http://test") as client:
            response = await client.get("/health")
        data = response.json()
        self.assertEqual(data["version"], "0.11.93")
        self.assertEqual(data["worker_version"], data["version"])
        self.assertTrue(data["progressive_jobs"])

    async def test_http_403_is_recorded_as_access_failure_without_reading_its_price(self):
        client = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda req: httpx.Response(403, text="Botox AED 900", headers={"content-type": "text/html"})))
        self.addAsyncCleanup(client.aclose)
        state = {"client": client, "semaphore": asyncio.Semaphore(1), "cache": {},
                 "inflight": {}, "lock": asyncio.Lock()}
        url = "https://aster.example/botox/"
        with patch.object(e, "_fetch_state", return_value=state):
            self.assertIsNone(await e.fetch_html(url))
        self.assertEqual(state["failures"][(url, False)], "http_403")


if __name__ == "__main__":
    unittest.main()
