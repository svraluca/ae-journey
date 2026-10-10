"""Public HTML requests identify their actual client and respect refusals."""
import asyncio
import unittest
from unittest.mock import patch

import httpx

from price_fixtures import e


class PublicFetchIdentity(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        state = e._FETCH_LOOP_STATE.pop(asyncio.get_running_loop(), None)
        if state is not None:
            await state['client'].aclose()

    def install_transport(self, handler):
        client_class = httpx.AsyncClient

        def create_client(**kwargs):
            return client_class(transport=httpx.MockTransport(handler), **kwargs)

        self.enterContext(patch.object(e.httpx, 'AsyncClient', side_effect=create_client))

    async def test_public_profile_accepts_real_client_without_old_browser_identity(self):
        requests = []
        html = '<html><h1>Aster Clinic</h1><p>Dermal fillers: EUR 250</p></html>'

        def handler(request):
            requests.append(request)
            # Models the live failure: the server refuses obsolete browser claims.
            if 'Mozilla/' in request.headers.get('user-agent', ''):
                return httpx.Response(403, text='Client-OldBrowserSpam')
            return httpx.Response(200, text=html,
                                  headers={'content-type': 'text/html'})

        self.install_transport(handler)
        result = await e.fetch_html('https://marketplace.example/clinic/aster/')
        self.assertEqual(result, html)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].headers['user-agent'],
                         f'python-httpx/{httpx.__version__}')
        self.assertEqual(requests[0].headers['accept'],
                         'text/html,application/xhtml+xml')
        self.assertEqual(requests[0].headers['accept-language'], 'en-US,en;q=0.8')

    async def test_access_refusal_is_cached_without_retrying_a_different_identity(self):
        requests = []

        def handler(request):
            requests.append(request)
            return httpx.Response(403, text='<p>Dermal fillers EUR 250</p>',
                                  headers={'content-type': 'text/html'})

        self.install_transport(handler)
        url = 'https://marketplace.example/clinic/blocked/'
        self.assertIsNone(await e.fetch_html(url))
        self.assertIsNone(await e.fetch_html(url))
        self.assertEqual(len(requests), 1)
        state = e._fetch_state()
        self.assertEqual(state['failures'][(url, False)], 'http_403')


if __name__ == '__main__':
    unittest.main()
