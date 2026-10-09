"""Offline reproductions of the treatment and tariff boundaries in the audit."""
import socket
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from price_fixtures import e, quote


def page(body):
    return ("<html><title>Aster Medical Clinic</title>" + body
            + "<footer>Our clinic: Main Street, Madrid. Book an appointment.</footer></html>")


def accepted(body, procedure, url="https://aster.example/precios/"):
    html = page(body)
    text = e.page_text(html)
    result = []
    for evidence in e.extract_price_evidence(html, url, procedure):
        ok, own, confidence, _, kind = e.validate_evidence(evidence, text, html, "Madrid")
        if not ok:
            continue
        canonical = e.canonicalize_procedure(procedure)
        row = e.ClinicPriceResult(
            price_extract_revision=e.PRICE_EXTRACT_REVISION,
            clinic_name="Aster Medical Clinic", city="Madrid", procedure_canonical=canonical,
            procedure_display_name=e.published_procedure_display_name(
                canonical, evidence.raw_procedure_text, evidence.raw_evidence, evidence.raw_price_text),
            price_min=evidence.price_min, price_max=evidence.price_max, currency=evidence.currency,
            qualifier=evidence.qualifier, unit=evidence.unit, source_url=url, source_host=e.host_of(url),
            source_type="official_clinic", evidence_type=kind, clinic_own_price=own,
            city_match=e.strong_local_page_evidence(html, text, "Madrid", url),
            identity_verified=True, confidence=confidence,
            procedure_detail=e.procedure_detail(evidence.raw_evidence, canonical, evidence.raw_price_text),
            raw_procedure_text=evidence.raw_procedure_text, raw_evidence=evidence.raw_evidence,
            official_price_found=True, official_procedure_verified=True,
        )
        if e.trusted_price_result(row):
            result.append(row)
    return result


class TreatmentScope(unittest.TestCase):
    def setUp(self):
        blocker = patch.object(socket.socket, "connect", side_effect=AssertionError("Network disabled"))
        blocker.start()
        self.addCleanup(blocker.stop)

    def test_spanish_chin_and_lips_keep_their_own_prices(self):
        body = ("<h2>Dermal fillers</h2><table>"
                "<tr><td>Relleno de labios 1 ml</td><td>250 EUR</td></tr>"
                "<tr><td>Relleno de mentón 1 ml</td><td>350 EUR</td></tr></table>")
        self.assertEqual({r.price_min for r in accepted(body, "lip filler")}, {250})
        self.assertEqual({r.price_min for r in accepted(body, "chin filler")}, {350})
        self.assertEqual({r.price_min for r in accepted(body, "filler")}, {250, 350})
        self.assertEqual(e.requested_filler_areas("Lipolysis in China"), set())

    def test_surgical_chin_does_not_inherit_filler_heading(self):
        body = ("<h2>Dermal fillers</h2><table>"
                "<tr><td>Chin augmentation (surgical implant)</td><td>3200 EUR</td></tr>"
                "<tr><td>Lip filler 1 ml</td><td>250 EUR</td></tr></table>")
        self.assertEqual({r.price_min for r in accepted(body, "filler")}, {250})
        self.assertFalse(accepted("<h2>Chin filler</h2><p>Mentoplastia quirúrgica con implante 3200 EUR</p>", "filler"))
        self.assertTrue(accepted("<p>Our non-surgical chin filler (hyaluronic acid) 350 EUR</p>", "filler"))

    def test_skinbooster_toxin_bundle_and_adjacent_mesotherapy_are_not_botox(self):
        body = ("<h2>Neuromoduladores</h2><table>"
                "<tr><td>NeuroSkin (Skinbooster + Neuromoduladores)</td><td>510 EUR</td></tr>"
                "<tr><td>Botox 3 zonas</td><td>350 EUR</td></tr>"
                "<tr><td>Mesoterapia NCTF 1 sesión</td><td>210 EUR</td></tr></table>")
        self.assertEqual({r.price_min for r in accepted(body, "botox")}, {350})

    def test_friend_pack_is_conditional_but_single_person_tariff_is_valid(self):
        body = ("<div><h2>Pack Amigas (Aumento de labios o tratamiento antiarrugas)</h2>"
                "<p>Ven con una amiga y disfruten de un precio especial. 250 EUR por persona</p></div>"
                "<h2>Lip filler</h2><p>Our lip filler 1 ml 350 EUR</p>")
        self.assertEqual({r.price_min for r in accepted(body, "filler")}, {350})

    def test_credit_ceiling_is_not_the_procedure_fee(self):
        body = ("<h2>Chin filler</h2><p>Financiación de tratamientos hasta 2500 EUR en 48 cuotas.</p>"
                "<h2>Lip filler</h2><p>Our lip filler 1 ml 350 EUR. Financing available.</p>")
        self.assertEqual({r.price_min for r in accepted(body, "filler")}, {350})

    def test_current_single_vial_column_beats_old_and_double_vial_prices(self):
        body = ("<h2>PRECIOS ÁCIDO HIALURÓNICO</h2><table>"
                "<tr><th>PRECIOS</th><th>ANTES</th><th>1VIAL (AHORA)</th><th>2VIALES (AHORA)</th></tr>"
                "<tr><td>Precio Aumento de Labios</td><td>400 EUR</td><td>330 EUR</td><td></td></tr>"
                "<tr><td>Precio Ojeras</td><td>400 EUR</td><td>349 EUR</td><td>649 EUR</td></tr>"
                "<tr><td>Precio Skinbooster</td><td>350 EUR</td><td>250 EUR</td><td>500 EUR</td></tr></table>")
        rows = accepted(body, "filler")
        self.assertEqual({r.price_min for r in rows}, {330, 349})
        self.assertTrue(any(r.price_min == 349 and "1VIAL" in r.raw_evidence for r in rows))

    def test_compact_lip_augmentation_range_does_not_borrow_hydration_price(self):
        body = ("<h2>Precios y opciones</h2><div class='e-con-inner'>"
                "<div><p>Aumento de labios (precio depende del producto)</p></div>"
                "<div><p>de <span>349 EUR</span> a <span>380 EUR</span></p></div></div>"
                "<div class='e-con-inner'><div><p>Hidratación de labios (precio depende del producto)</p></div>"
                "<div><p>de 250 EUR a 330 EUR</p></div></div>")
        rows = accepted(body, "lip filler")
        self.assertEqual({(r.price_min, r.price_max) for r in rows}, {(349, 380)})
        self.assertTrue(all("Aumento de labios" in r.raw_evidence for r in rows))

    def test_cached_bundle_surgery_and_financing_fail_the_serving_gate(self):
        base = quote(city="Madrid")
        for canonical, evidence, amount, reason in [
            ("botox", "NeuroSkin (Skinbooster + Neuromoduladores) 510 EUR", 510, "package_not_procedure"),
            ("filler", "Chin filler | Mentoplastia quirúrgica con implante 3200 EUR", 3200, "surgical_chin_not_filler"),
            ("filler", "Dermal filler | Financiación hasta 2500 EUR en 48 cuotas", 2500, "monthly_financing"),
        ]:
            with self.subTest(evidence=evidence):
                row = base.model_copy(update={"procedure_canonical": canonical,
                    "raw_procedure_text": "Botox" if canonical == "botox" else "Dermal filler",
                    "raw_evidence": evidence, "price_min": amount, "currency": "EUR"})
                self.assertFalse(e.trusted_price_result(row))
                self.assertEqual(e.trusted_price_failure(row), reason)

    def test_unknown_breast_method_is_not_a_display_suffix(self):
        self.assertEqual(e.breast_augmentation_display_name("Breast augmentation 6000 EUR"), "Breast augmentation")
        self.assertEqual(e.breast_augmentation_detail("Breast augmentation 6000 EUR"), "Method not specified")
        self.assertEqual(e.breast_augmentation_display_name("Breast augmentation with implants 6000 EUR"),
                         "Breast augmentation · With implants")


class SpanishSurgeryAndApproximation(unittest.TestCase):
    def test_general_city_market_range_is_rejected_but_own_range_survives(self):
        for market in [
            "El precio de una rinoplastia suele oscilar entre 10.000 EUR y 20.000 EUR dependiendo del cirujano y la clínica.",
            "Los precios de rinoplastia en Madrid varían entre 6500 y 10000 euros.",
            "El precio de la rinoplastia en España oscila entre 5000 y 10000 euros.",
        ]:
            with self.subTest(market=market):
                self.assertFalse(accepted("<h2>Rinoplastia</h2><p>" + market + "</p>", "rhinoplasty"))
        rows = accepted("<h2>Rinoplastia ultrasónica</h2><p>El precio de nuestra rinoplastia en nuestra clínica es de 7000 EUR a 9000 EUR.</p>", "rhinoplasty")
        self.assertEqual({(r.price_min, r.price_max, r.qualifier) for r in rows}, {(7000, 9000, "range")})

    def test_market_price_disclaimer_overrides_a_literal_tariff_table(self):
        body = ("<p>Los precios son indicativos de la media en España. No representan los precios aplicados en la consulta del doctor.</p>"
                "<table><tr><td>Rinoplastia primaria</td><td>7000 EUR</td></tr>"
                "<tr><td>Breast augmentation with implants</td><td>6000 EUR</td></tr></table>")
        self.assertFalse(accepted(body, "rhinoplasty"))
        self.assertFalse(accepted(body, "breast_augmentation"))
        self.assertTrue(accepted("<table><tr><td>Rinoplastia primaria</td><td>7000 EUR</td></tr></table>", "rhinoplasty"))

    def test_primary_ultrasonic_technique_is_not_revision_or_trauma(self):
        body = ("<table><tr><td>Rinoplastia ultrasónica primaria</td><td>7500 EUR a 9000 EUR</td></tr>"
                "<tr><td>Rinoplastia secundaria</td><td>9000 EUR a 19000 EUR</td></tr>"
                "<tr><td>Rinoplastia post-traumática</td><td>10000 EUR a 20000 EUR</td></tr></table>")
        self.assertEqual({(r.price_min, r.price_max) for r in accepted(body, "rhinoplasty")}, {(7500, 9000)})

    def test_approximate_owned_quotes_preserve_their_range(self):
        rows = accepted("<h2>Rinoplastia</h2><p>El precio aproximado de nuestra rinoplastia en nuestra clínica es de 10.000 EUR a 20.000 EUR.</p>", "rhinoplasty")
        self.assertEqual({(r.price_min, r.price_max, r.qualifier) for r in rows}, {(10000, 20000, "approximate")})
        rows = accepted("<h2>Botox</h2><p>El costo del tratamiento de botox depende del número de viales, pero suele rondar los 300 EUR.</p>", "botox")
        self.assertEqual({(r.price_min, r.qualifier) for r in rows}, {(300, "approximate")})

    def test_approximate_duration_does_not_qualify_an_exact_fee(self):
        rows = accepted("<h2>Botox</h2><p>Approximately 15 minutes. Our Botox 3 areas fee: 350 EUR.</p>", "botox")
        self.assertEqual({(r.price_min, r.qualifier) for r in rows}, {(350, "exact")})

    def test_cached_approximation_is_not_reformatted_as_exact_or_from(self):
        base = quote(city="Madrid")
        for procedure, evidence, amount, upper in [
            ("botox", "Our Botox fee usually costs approximately 300 EUR", 300, None),
            ("rhinoplasty", "El precio aproximado de nuestra rinoplastia es 10000 EUR a 20000 EUR", 10000, 20000),
        ]:
            row = base.model_copy(update={"procedure_canonical": procedure,
                "raw_evidence": evidence, "price_min": amount, "price_max": None,
                "qualifier": "exact", "currency": "EUR"})
            normalized, changed = e.normalize_cached_explicit_price_floor(row)
            self.assertTrue(changed)
            self.assertEqual((normalized.price_min, normalized.price_max, normalized.qualifier),
                             (amount, upper, "approximate"))

    def test_spanish_booking_platform_is_not_an_official_clinic(self):
        text = "Aster no es un consultorio médico. Al reservarlo NO se está contratando la operación. Pago directo al cirujano."
        self.assertEqual(e.classify_page_source("https://aster.example/madrid/cirugia-plastica/", text), "directory")
        self.assertEqual(e.classify_page_source("https://aster.example/precios/", "Our medical clinic. Book a consultation."), "official_clinic")
        self.assertEqual(e.classify_page_source("https://aster.example/madrid/", "Clinic listing. " * 3000 + text), "directory")
        cached = quote(city="Madrid").model_copy(update={
            "source_url": "https://www.bonomedico.es/madrid/cirugia-plastica/",
            "source_host": "www.bonomedico.es", "source_type": "official_clinic"})
        self.assertFalse(e.trusted_price_result(cached))
        self.assertEqual(e.trusted_price_failure(cached), "classify_source")


class CachedAreaRequests(unittest.IsolatedAsyncioTestCase):
    async def test_same_family_cache_keeps_only_the_requested_area(self):
        body = ("<h2>Dermal fillers</h2><table>"
                "<tr><td>Lip filler 1 ml</td><td>250 EUR</td></tr>"
                "<tr><td>Chin filler 1 ml</td><td>350 EUR</td></tr></table>")
        rows = accepted(body, "filler")
        self.assertTrue(rows)
        docs = [SimpleNamespace(to_dict=lambda row=row: {"result": row.model_dump(),
                "last_verified_at": datetime.now(timezone.utc)}) for row in rows]
        client = MagicMock()
        client.collection.return_value.where.return_value.limit.return_value.stream.return_value = docs
        with patch.object(e, "firestore_enabled", return_value=True), \
                patch.object(e, "_firestore_client", return_value=client):
            lips = await e.firestore_load_results("Madrid", "lip filler", read_only=True)
            chin = await e.firestore_load_results("Madrid", "chin filler", read_only=True)
        self.assertEqual({row.price_min for row in lips}, {250})
        self.assertEqual({row.price_min for row in chin}, {350})


if __name__ == "__main__":
    unittest.main()
