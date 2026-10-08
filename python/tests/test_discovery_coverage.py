"""Regressions for organic recall, live tariff navigation and published titles."""
import asyncio
from contextlib import ExitStack
import json
import os
import socket
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from price_fixtures import e, page, quote


class DiscoveryCoverage(unittest.TestCase):
    def test_simple_google_query_precedes_uae_variations(self):
        for city in ["Abu Dhabi", "Dubai"]:
            for procedure in ["chemical_peel", "rhinoplasty", "breast_augmentation", "hair_transplant"]:
                queries = e.build_queries(city, procedure, "AE", "expanded",
                                          full_growth=True, economical_growth=True)
                self.assertEqual(queries[0], f"{e.display_name(procedure)} {city} price")
                self.assertNotIn('"', queries[0])

    def test_one_seo_domain_cannot_crowd_out_other_providers(self):
        hits = [e.SearchHit(title="Chemical peel Abu Dhabi price", snippet="Our peel AED 700",
                            url=f"https://aster.example/prices/peel-{i}/") for i in range(12)]
        hits += [e.SearchHit(title="Chemical peel Abu Dhabi price", snippet="Our peel AED 800",
                             url=f"https://provider{i}.example/prices/") for i in range(7)]
        req = e.DiscoverRequest(city="Abu Dhabi", procedure="chemical_peel", hybrid_interactive=True)
        selected, _ = e.select_discovery_work(hits, req, lambda row: 0)
        hosts = [e.host_of(row.url) for row in selected]
        self.assertEqual(len(set(hosts[:8])), 8)

    def test_real_tariff_link_precedes_homepage_and_guessed_prices(self):
        req = e.DiscoverRequest(city="Abu Dhabi", procedure="chemical_peel", hybrid_interactive=True,
                                search_mode="site_focus", priority_site_urls=["https://aster.example/menu/"])
        hits = [e.SearchHit(title="Aster Medical Clinic", url=url, query="known_host_tariff")
                for url in ["https://aster.example/", "https://aster.example/prices/",
                            "https://aster.example/menu/", "https://cedar.example/"]]
        selected, _ = e.select_discovery_work(hits, req, lambda row: 0)
        self.assertEqual(selected[0].url, "https://aster.example/menu/")
        self.assertEqual(selected[1].url, "https://cedar.example/")

    def test_numeric_clinic_name_owns_only_its_matching_quote(self):
        text = "Chemical peel at 360 Cure Medical Center ranges from AED 400 to AED 700."
        self.assertTrue(e.clinic_paragraph_matches_site(text, "https://www.360curemedical.ae/"))
        self.assertFalse(e.clinic_paragraph_matches_site(text, "https://othermedical.ae/"))

    def test_iran_quote_is_not_a_local_uae_price_despite_saved_city_match(self):
        row = quote(amount=1500).model_copy(update={
            "procedure_canonical": "rhinoplasty", "currency": "USD",
            "raw_procedure_text": "Rhinoplasty", "procedure_detail": "Primary rhinoplasty",
            "raw_evidence": "The cost of rhinoplasty in Iran ranges from 1500 USD to 3500 USD.",
        })
        self.assertFalse(e.trusted_price_result(row))
        self.assertEqual(e.trusted_price_failure(row), "foreign_quoted_price_country")
        self.assertFalse(e.foreign_quoted_price_country(
            "Our rhinoplasty treatment from 5000 USD; our surgeon trained in Iran.", "Abu Dhabi"))

    def test_filler_title_keeps_romanian_menu_product_and_dosage(self):
        title = "Augmentare buze cu acid hialuronic Teosyal RHA Kiss 1 ml"
        self.assertEqual(e.published_procedure_display_name("filler", title, title + " | 1650 RON"), title)
        self.assertEqual(e.published_procedure_display_name(
            "filler", "Russian Lip Filler 1 ml", "Russian Lip Filler 1 ml | 1200 AED"),
            "Russian Lip Filler 1 ml")
        self.assertEqual(e.published_procedure_display_name(
            "filler", "Umplere cearcăne", "Umplere cearcăne | 1600 RON"), "Umplere cearcăne")

    def test_filler_generic_title_uses_bound_row_not_next_menu_service(self):
        self.assertEqual(e.published_procedure_display_name(
            "filler", "Dermal Filler", "Lip filler 1 ml | 1200 AED"), "Lip filler")
        self.assertEqual(e.published_procedure_display_name(
            "filler", "How much do dermal fillers cost?", "Cheek filler 1 ml | 1600 AED"),
            "Cheek filler")

    def test_card_tariff_layout_keeps_name_product_and_matching_price(self):
        html = ('<html><title>Aster Clinic Brașov</title><h1>Aster Clinic</h1>'
                '<h2>Servicii la clinica din Brașov</h2><div class="service-card">'
                '<h3>Mărire buze cu acid hialuronic Amalian</h3>'
                '<div><s>1797 lei</s><strong>1497 lei</strong></div></div>'
                '<footer>Clinica Brașov</footer></html>')
        rows = e.extract_price_evidence(html, "https://aster.example/prices/", "filler")
        matching = [row for row in rows if row.price_min == 1497]
        self.assertTrue(matching)
        self.assertTrue(any(row.raw_procedure_text == "Mărire buze cu acid hialuronic Amalian"
                            for row in matching))

    def test_plain_css_tariff_preserves_the_full_priced_label(self):
        self.assertEqual(e.filler_price_row_name(
            '/ml Umplere șanțuri nazo-geniene Injectare acid hialuronic (per ml) 1200 RON/ml',
            '1200 RON'), 'Umplere șanțuri nazo-geniene Injectare acid hialuronic (per ml)')

    def test_country_comparison_does_not_become_a_local_menu_from_price_slug(self):
        html = ('<html><title>Rhinoplasty price</title><h1>Aster Clinic</h1>'
                '<p>International rhinoplasty prices, including Dubai and Abu Dhabi.</p>'
                '<h2>Rhinoplasty Price Comparison Table</h2>'
                '<table><tr><th>Country</th><th>Minimum Price</th><th>Maximum Price</th></tr>'
                '<tr><td>Iran</td><td>1500 USD</td><td>3500 USD</td></tr>'
                '<tr><td>Turkey</td><td>2500 USD</td><td>5000 USD</td></tr></table>'
                '<h2>Rhinoplasty cost at Aster Clinic</h2>'
                '<p>At Aster Clinic the cost of rhinoplasty starts from 1500 USD.</p></html>')
        url = "https://aster.example/rhinoplasty-price/"
        text = e.page_text(html)
        self.assertTrue(e.comparative_market_article_context(url, text))
        self.assertFalse(e.strong_local_page_evidence(html, text, "Abu Dhabi", url))
        rows = e.extract_price_evidence(html, url, "rhinoplasty")
        self.assertTrue(rows)
        self.assertFalse(any(e.validate_evidence(row, text, html, "Abu Dhabi")[0] for row in rows))

    def test_nonfacial_prices_are_rejected_without_dropping_a_facial_row(self):
        intimate = quote(amount=1650, city="Brașov").model_copy(update={
            "procedure_canonical": "filler", "currency": "RON",
            "raw_procedure_text": "Augmentarea zonei intime cu acid hialuronic 1 ml",
            "raw_evidence": "Augmentarea zonei intime cu acid hialuronic 1 ml | 1650 RON",
        })
        self.assertFalse(e.trusted_price_result(intimate))
        self.assertEqual(e.trusted_price_failure(intimate), "nonfacial_tariff_scope")
        facial = intimate.model_copy(update={
            "raw_procedure_text": "Augmentare buze cu acid hialuronic 1 ml",
            "raw_evidence": "Augmentare buze cu acid hialuronic 1 ml | 1650 RON",
        })
        self.assertTrue(e.trusted_price_result(facial))
        self.assertFalse(e.nonfacial_tariff_scope("filler", "Augmentare buze 1 ml | 1650 RON"))
        self.assertTrue(e.nonfacial_tariff_scope("chemical_peel", "Peeling chimic zona intimă | 750 RON"))
        self.assertFalse(e.nonfacial_tariff_scope("chemical_peel", "BioRePeel față | 350 RON"))


class OrganicNavigation(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.dict(os.environ, {
            "ENABLE_FIRESTORE": "false", "AUTO_PERSIST_SEARCH_RESULTS": "false",
            "ENABLE_BACKGROUND_REFRESH": "false", "SERPER_API_KEY": "",
            "GOOGLE_PLACES_API_KEY": "", "GOOGLE_MAPS_API_KEY": "",
            "ENABLE_PLACES_CITY_BOOTSTRAP": "false", "ENABLE_PLACES_IDENTITY_LOOKUP": "false",
        }))
        self.stack.enter_context(patch.object(socket.socket, "connect", side_effect=AssertionError("Offline")))
        self.stack.enter_context(patch.object(e, "firestore_load_clinic_directory", new=AsyncMock(return_value=[])))

    async def navigate(self, procedure, label, amount, root_body=""):
        # Search returns homepages, never the price URLs used as controls.
        slow = "https://slow.example/"
        roots = [f"https://provider{i}.example/" for i in range(8)]
        menu_urls = [url + "treatment-menu/" for url in roots]
        gate = asyncio.Event()
        fetched = []
        async def fetch(url):
            fetched.append(url)
            if url == slow:
                await gate.wait()
                return None
            if url in roots:
                i = roots.index(url)
                return (f'<html><title>Aster {i} Medical Clinic</title><h1>Aster {i} Medical Clinic</h1>'
                        f'<h2>{label}</h2><a href="/treatment-menu/">Treatment prices</a>'
                        f'{root_body}<footer>Our clinic: Test Street, Abu Dhabi</footer></html>')
            if url in menu_urls:
                return page(f"Aster {menu_urls.index(url)} Medical Clinic", label, amount)
            return None
        hits = [e.SearchHit(title=f"Aster {i} Medical Clinic {label} Abu Dhabi", url=url,
                            snippet="Published treatment menu", query=f"{label} Abu Dhabi price")
                for i, url in enumerate([*roots, slow])]
        self.stack.enter_context(patch.object(e, "fetch_html", side_effect=fetch))
        self.stack.enter_context(patch.object(e.SerperClient, "search", new=AsyncMock(return_value=hits)))
        queue = asyncio.Queue()
        token = e._hybrid_progress.set(queue)
        task = asyncio.create_task(e.discover(e.DiscoverRequest(
            city="Abu Dhabi", procedure=procedure, country_code="AE", limit=8, search_mode="expanded",
            hybrid_interactive=True, full_growth=True, economical_growth=True, skip_places_bootstrap=True)))
        try:
            async def eight_before_slow_root():
                while True:
                    event = await queue.get()
                    if event["event"] == "partial" and len(event["display_results"]) == 8:
                        return event
            event = await asyncio.wait_for(eight_before_slow_root(), 12)
            self.assertFalse(task.done(), "The unrelated root is still stalled")
            self.assertTrue(set(menu_urls).issubset(fetched))
            self.assertTrue(all(row["price_min"] == amount for row in event["display_results"]))
        finally:
            gate.set()
            await asyncio.wait_for(task, 12)
            e._hybrid_progress.reset(token)

    async def test_peel_menus_publish_before_unrelated_root_finishes(self):
        await self.navigate("chemical_peel", "Chemical peel", 550)

    async def test_breast_menus_publish_before_unrelated_root_finishes(self):
        await self.navigate("breast_augmentation", "Breast augmentation", 20000)

    async def test_rhinoplasty_menus_publish_before_unrelated_root_finishes(self):
        await self.navigate("rhinoplasty", "Rhinoplasty", 25000)

    async def test_hair_menus_publish_before_unrelated_root_finishes(self):
        await self.navigate("hair_transplant", "FUE hair transplant", 6000)

    async def test_rejected_root_quote_does_not_block_following_a_local_menu(self):
        await self.navigate("rhinoplasty", "Rhinoplasty", 25000,
            '<p>The cost of rhinoplasty in Iran ranges from 1500 USD to 3500 USD.</p>')

    async def test_explicit_twelve_request_budget_is_not_silently_expanded(self):
        caps = []
        async def discover(req):
            caps.append(req.serper_request_cap)
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, queries=[],
                results=[], searched_urls=0, fetched_pages=0,
                diagnostics=e.DiscoveryDiagnostics(
                    serper_requests_attempted=req.serper_request_cap,
                    unpriced_local_provider_hosts=["cedar.example"]))
        self.stack.enter_context(patch.object(e, "discover", side_effect=discover))
        await e.run_growth_search("Abu Dhabi", "chemical_peel", "AE", [], 8, 20, True,
            app_fast=True, serper_first=True, force_full_growth_search=True, serper_request_budget=12)
        self.assertEqual(caps, [2, 2])  # primary then local, no repetitive rescue
        self.assertLessEqual(sum(caps), 12)

    async def test_discovered_navigation_survives_into_site_focus(self):
        calls = []
        tariff = "https://cedar.example/face-menu/"
        async def discover(req):
            calls.append(req)
            return e.DiscoverResponse(city=req.city, procedure=req.procedure, queries=[],
                results=[] if len(calls) == 1 else [quote(host="cedar.example", origin="live_search")],
                searched_urls=1, fetched_pages=1, crawled_urls=["https://cedar.example/"],
                diagnostics=e.DiscoveryDiagnostics(
                    pending_price_navigation_urls=[tariff], unpriced_local_provider_hosts=["cedar.example"]))
        self.stack.enter_context(patch.object(e, "discover", side_effect=discover))
        self.stack.enter_context(patch.object(e, "enrich_new_operator_identities", new=AsyncMock(side_effect=lambda rows,*args: rows)))
        await e.run_growth_search("Abu Dhabi", "botox", "AE", [], 1, 4, True,
            serper_first=True, force_full_growth_search=True, serper_request_budget=12)
        self.assertEqual([req.search_mode for req in calls], ["expanded", "site_focus"])
        self.assertEqual(calls[1].priority_site_urls, [tariff])
        self.assertFalse(calls[1].enable_serper)

    async def test_serper_sends_requested_market_and_scopes_cache_by_locale(self):
        requests = []
        def handler(request):
            requests.append(json.loads(request.content))
            return httpx.Response(200, json={"organic": [{"title": "Aster Medical Clinic",
                "link": "https://aster.example/", "snippet": "Chemical peel Abu Dhabi"}]})
        client_class = httpx.AsyncClient
        def mocked_client(**kwargs):
            return client_class(transport=httpx.MockTransport(handler), **kwargs)
        get = self.stack.enter_context(patch.object(e, "serp_cache_get", new=AsyncMock(return_value=None)))
        put = self.stack.enter_context(patch.object(e, "serp_cache_put", new=AsyncMock(return_value=True)))
        self.stack.enter_context(patch.object(e.httpx, "AsyncClient", side_effect=mocked_client))
        client = e.SerperClient(request_cap=1)
        client.api_key = "test-only"
        client.country_code, client.language, client.min_interval = "AE", "en", 0
        await client.search("chemical peel Abu Dhabi price", 20)
        self.assertEqual(requests[0]["q"], "chemical peel Abu Dhabi price")
        self.assertEqual((requests[0]["gl"], requests[0]["hl"], requests[0]["num"]), ("ae", "en", 20))
        self.assertEqual(get.call_args.args[0], put.call_args.args[0])
        client.country_code = "US"
        self.assertNotEqual(get.call_args.args[0], client.cache_query("chemical peel Abu Dhabi price"))


if __name__ == "__main__":
    unittest.main()
