"""Published fee dates survive extraction, cache serialization and revalidation."""
from datetime import datetime, timedelta, timezone
import unittest

from marketplace_price_freshness import bookimed_price_date, marketplace_price_date_failure
from price_fixtures import e, quote


def page(menu_date="29.03.2025", *, clinic_id=7, amount=300,
         label="Fillers injection", row_date="2025-02-08T11:04:15.000+00:00",
         state=True):
    script = (f'<script>window.__NUXT__=(function(a,b,c,d){{return {{data:[{{'
              'content:{clinic:{id:a}},prices:[{operation_prices:[{'
              f'operation:{{id:934,name:b,alias:"fillers-injection",name_forms:{{base_form:b}}}},'
              f'prices:{{id:17,clinic_id:{clinic_id},price_to:{amount},price_from:{amount},'
              'currency:c,entity:"operations",entity_id:934,updated_at:d}}]}]}]}}'
              f'(7,"{label}","USD","{row_date}"));</script>') if state else ""
    date = f'Last price update — {menu_date}.' if menu_date else ""
    return ('<title>Aster Clinic | Bookimed</title><p>Istanbul, Turkey</p>'
            '<div id="prices"><h2>Treatments prices in the clinic</h2>' + date
            + '<table class="clinic-prices__table"><tr class="clinic-prices__table-tr">'
              '<td>Fillers injection</td><td>$300</td></tr></table></div>' + script)


class ExplicitMarketplaceDates(unittest.TestCase):
    def test_own_price_date_beats_newer_menu_summary(self):
        result = bookimed_price_date(page(), "Fillers injection", 300, None, "USD")
        self.assertEqual(result, ("2025-02-08T11:04:15.000+00:00",
                                  "updated_at=2025-02-08T11:04:15.000+00:00",
                                  "provider_procedure_price_record"))

    def test_foreign_clinic_or_changed_fee_does_not_supply_row_date(self):
        for opts in [{"clinic_id": 8}, {"amount": 400}, {"label": "Rhinoplasty"}]:
            with self.subTest(opts=opts):
                result = bookimed_price_date(page(**opts), "Fillers injection", 300, None, "USD")
                self.assertEqual((result[0], result[2]), ("2025-03-29", "provider_tariff_menu"))

    def test_canonical_or_prefixed_extraction_label_cannot_bypass_old_row_date(self):
        for label in ["Dermal Filler", "treatment Fillers injection"]:
            result = bookimed_price_date(page(), label, 300, None, "USD",
                                        "treatment Fillers injection $300")
            self.assertEqual(result[0], "2025-02-08T11:04:15.000+00:00")
            self.assertEqual(result[2], "provider_procedure_price_record")

    def test_literal_decoder_never_executes_expressions(self):
        html = page().replace('"2025-02-08T11:04:15.000+00:00"', 'dangerousFunction()')
        self.assertEqual(bookimed_price_date(html, "Fillers injection", 300, None, "USD")[0], "2025-03-29")

    def test_invalid_explicit_row_date_is_not_hidden_by_menu_fallback(self):
        result = bookimed_price_date(page(row_date="not a date"), "Fillers injection", 300, None, "USD")
        self.assertEqual(marketplace_price_date_failure(result[0], result[2]), "marketplace_price_date_invalid")

    def test_ambiguous_slash_date_is_not_guessed(self):
        result = bookimed_price_date(page("03/04/2026", state=False), "Fillers injection", 300, None, "USD")
        self.assertEqual(result[0], "")
        self.assertEqual(marketplace_price_date_failure(result[0], result[2]), "marketplace_price_date_ambiguous")

    def test_undated_menu_stays_undated_and_footer_is_not_fee_metadata(self):
        html = page("", state=False) + '<footer>Last price update — 01.01.2001.</footer>'
        result = bookimed_price_date(html, "Fillers injection", 300, None, "USD")
        self.assertEqual(result, ("", "", ""))
        self.assertEqual(marketplace_price_date_failure(result[0]), "")

    def test_explicit_user_retention_keeps_a_published_fee_without_renewing_its_date(self):
        now = datetime(2026, 10, 11, tzinfo=timezone.utc)
        self.assertEqual(marketplace_price_date_failure("2025-01-15", "user_retained_published_fee", now=now), "")
        self.assertEqual(marketplace_price_date_failure("2030-01-01", "user_retained_published_fee", now=now), "marketplace_price_date_future")
        self.assertEqual(marketplace_price_date_failure("not a date", "user_retained_published_fee", now=now), "marketplace_price_date_invalid")

    def test_old_source_dates_do_not_expire_fees_but_future_and_invalid_dates_reject(self):
        now = datetime(2026, 10, 10, 12, tzinfo=timezone.utc)
        self.assertEqual(marketplace_price_date_failure((now-timedelta(days=365)).isoformat(), now=now), "")
        self.assertEqual(marketplace_price_date_failure((now-timedelta(days=366)).isoformat(), now=now), "")
        self.assertEqual(marketplace_price_date_failure("2001-01-01", now=now), "")
        self.assertEqual(marketplace_price_date_failure("2030-01-01", now=now), "marketplace_price_date_future")
        self.assertEqual(marketplace_price_date_failure("last Tuesday", now=now), "marketplace_price_date_invalid")
        self.assertEqual(marketplace_price_date_failure("2026-10-10T14:00:00+02:00", now=now), "")

    def test_live_validation_keeps_published_fee_and_its_old_source_date(self):
        html = page("01.01.2001", row_date="2001-01-01T00:00:00Z")
        evidence = e.ExtractedEvidence(raw_procedure_text="Fillers injection", raw_price_text="$300",
            price_min=300, currency="USD", raw_evidence="Fillers injection $300",
            source_url="https://us-uk.bookimed.com/clinic/aster/", extraction_method="table_row")
        accepted = e.validate_evidence(evidence, e.page_text(html), html, "Istanbul")
        self.assertTrue(accepted[0], accepted[3])
        self.assertEqual(evidence.source_price_updated_at, "2001-01-01T00:00:00Z")

    def test_cached_marketplace_date_cannot_be_refreshed_by_serialization(self):
        row = quote().model_copy(update={"source_type": "marketplace",
            "source_url": "https://us-uk.bookimed.com/clinic/aster/",
            "source_location_text": "Provider locality: Abu Dhabi",
            "evidence_type": "marketplace_service_menu",
            "source_price_updated_at": "2001-01-01", "source_price_date_basis": "provider_tariff_menu"})
        restored = e.ClinicPriceResult.model_validate(row.model_dump())
        self.assertEqual(restored.source_price_updated_at, "2001-01-01")
        self.assertTrue(e.trusted_price_result(restored), e.trusted_price_failure(restored))
        self.assertTrue(e._app_can_show_row(restored))
        stale = restored.model_copy(update={"price_extract_revision": "e32"})
        self.assertFalse(e._app_can_show_row(stale))

    def test_official_fee_replacement_uses_its_own_date(self):
        row = quote().model_copy(update={"source_type": "marketplace",
            "source_url": "https://us-uk.bookimed.com/clinic/aster/",
            "source_price_updated_at": "2001-01-01", "source_price_date_basis": "provider_tariff_menu"})
        evidence = e.ExtractedEvidence(raw_procedure_text="Dermal Fillers", raw_price_text="€300",
            price_min=300, currency="EUR", raw_evidence="Dermal Fillers €300",
            source_url="https://aster.example/prices/", extraction_method="table_row")
        replaced = e.apply_official_marketplace_verification(row,
            e.SearchHit(title="Aster", url="https://aster.example/prices/"), True,
            [(evidence, "official_price_menu", .97)])
        self.assertEqual(replaced.source_type, "official_clinic")
        self.assertEqual(replaced.source_price_updated_at, "")
        self.assertEqual(replaced.price_min, 300)


if __name__ == "__main__":
    unittest.main()
