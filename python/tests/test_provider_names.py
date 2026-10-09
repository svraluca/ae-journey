"""Public provider names must survive hostname fallbacks and revalidation."""
import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import AsyncMock, patch

from price_fixtures import e, quote
from explore_index_jobs import IndexJobs, MarketRequest


def provider_page(name, host):
    schema = {"@type": ["Person", "Organization"],
              "@id": f"https://{host}/#person", "name": name}
    return (f'<title>Botox | {name}</title>'
            f'<script type="application/ld+json">{json.dumps(schema)}</script>'
            '<p>Our clinic in Springfield. Book an appointment.</p>')


class ProviderNames(unittest.IsolatedAsyncioTestCase):
    async def test_source_metadata_keeps_unicode_name_without_homepage_fetch(self):
        cases = [('Op. Dr. Akın Şahin', 'drakinsahin.com'),
                 ('Dr. Amélie Müller', 'drameliemuller.example'),
                 ('Клиника Аврора', 'aurora.example')]
        for name, host in cases:
            with self.subTest(name=name), patch.object(e, 'fetch_html', new=AsyncMock(return_value='')) as fetch:
                resolved = await e.resolve_clinic_name(provider_page(name, host),
                    f'https://{host}/botox/', 'Botox prices 2026', 'Springfield')
                self.assertEqual(resolved, name)
                fetch.assert_not_awaited()

    def test_compact_transliterated_doctor_identity_is_not_a_weak_service_title(self):
        self.assertFalse(e.weak_business_name('Op. Dr. Akın Şahin',
            'İstanbul', 'https://drakinsahin.com/bonta/'))
        self.assertTrue(e.weak_business_name('Massage Springfield',
            'Springfield', 'https://aurora.example/'))

    async def test_foreign_structured_organization_does_not_override_own_site(self):
        html = ('<title>Aurora Clinic</title>'
                '<script type="application/ld+json">'
                '{"@type":"Organization","url":"https://regulator.example/",'
                '"name":"Regulator Organization"}</script>')
        home = '<meta property="og:site_name" content="Aurora Clinic">'
        with patch.object(e, 'fetch_html', new=AsyncMock(return_value=home)):
            self.assertEqual(await e.resolve_clinic_name(html,
                'https://aurora.example/treatments/', city='Springfield'), 'Aurora Clinic')


class RefreshedProviderNames(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.service = IndexJobs(e, str(Path(directory.name) / 'jobs.sqlite3'))
        self.req = MarketRequest(city='Springfield', procedure='botox', country_code='US')
        self.row = quote(city='Springfield', origin='live_search').model_copy(
            update={'source_location_text': 'Our clinic in Springfield'})
        self.market = self.service.key(self.req)

    async def test_live_tariff_refresh_repairs_cached_name_without_changing_fee(self):
        stored = self.row.model_copy(update={
            'clinic_name': 'Dra Meliemuller',
            'source_url': 'https://drameliemuller.example/prices/',
            'source_host': 'drameliemuller.example',
            'official_website': 'https://drameliemuller.example/'})
        self.service.store.source_check(self.market, stored.source_url)
        html = provider_page('Dr. Amélie Müller', stored.source_host) + (
            '<h2>Our Botox tariff</h2><table><tr><td>Botox 3 areas</td>'
            '<td>900 AED</td></tr></table>')
        with patch.object(self.service, 'index', new=AsyncMock(return_value={
                'display_results': [stored.model_dump()]})), \
                patch.object(self.service, 'static_html', new=AsyncMock(return_value=html)), \
                patch.object(e, 'firestore_upsert_results', new=AsyncMock()):
            refreshed = await self.service.refresh_known(self.req)
        self.assertEqual(len(refreshed['display_results']), 1)
        row = refreshed['display_results'][0]
        self.assertEqual(row['clinic_name'], 'Dr. Amélie Müller')
        self.assertEqual(row['price_min'], 900)
        self.assertEqual(row['currency'], 'AED')
        self.assertEqual(row['source_url'], stored.source_url)
