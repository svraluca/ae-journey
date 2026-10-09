"""Bounded discovery policy around the existing price verifier; no UI or prices here."""
from __future__ import annotations

import asyncio
from collections import OrderedDict
import json
import os
from pathlib import Path
import re
import time
import unicodedata

import httpx


def normalized(value):
    return ' '.join(''.join(c for c in unicodedata.normalize('NFKD', value or '')
                           if not unicodedata.combining(c)).casefold().split())


class Catalog:
    # API/storage compatibility: existing Flutter families keep their keys.
    family_keys = {
        'botox': 'botulinum_toxin', 'filler': 'dermal_filler_general',
        'chemical_peel': 'chemical_peel_superficial',
        'breast_augmentation': 'breast_augmentation_implants',
        'hair_transplant': 'hair_transplant_fue', 'rhinoplasty': 'rhinoplasty',
    }

    def __init__(self, directory):
        directory = Path(directory)
        self.countries = json.loads((directory / 'countries_v2_final.json').read_text())['countries']
        self.procedures = json.loads((directory / 'procedures_v3_expanded.json').read_text())['procedures']
        self.aliases = {}
        for key, spec in self.procedures.items():
            for term in [key, spec['display_name_en'],
                         *(s for terms in spec.get('synonyms', {}).values() for s in terms)]:
                self.aliases.setdefault(normalized(term), key)

    def key(self, procedure):
        return self.family_keys.get(procedure, self.aliases.get(normalized(procedure), procedure))

    def spec(self, procedure):
        return self.procedures.get(self.key(procedure), {})

    def country(self, code):
        return self.countries.get((code or '').strip().upper(), {})

    def country_from_address(self, address):
        # Prefer structured addressComponents upstream. This suffix fallback
        # uses all 249 countries, never a list of capital cities.
        tail = normalized((address or '').split(',')[-1])
        aliases = {'uk': 'GB', 'usa': 'US', 'uae': 'AE', 'turkey': 'TR',
                   'vietnam': 'VN', 'korea, republic of': 'KR'}
        if tail in aliases:
            return aliases[tail]
        if tail.upper() in self.countries:
            return tail.upper()
        full = normalized(address)
        for name, code in aliases.items():
            if full == name or full.endswith(', ' + name):
                return code
        for code, spec in self.countries.items():
            name = normalized(spec['country_name'])
            if (tail == normalized(spec.get('alpha3', '')) and tail) or full == name or full.endswith(', ' + name):
                return code
        return ''

    def queries(self, procedure, city, country, local_terms, *, stage='primary'):
        spec = self.spec(procedure)
        synonyms = spec.get('synonyms', {})
        term = (synonyms.get('en') or [spec.get('display_name_en', procedure.replace('_', ' '))])[0]
        if procedure in {'chemical_peel', 'hair_transplant', 'breast_augmentation'}:
            # A general pill must not silently narrow to the first configured
            # subtype (superficial, FUE, implants) during discovery.
            term = procedure.replace('_', ' ')
        if stage == 'primary':
            return [f'{term} {city} price', f'{term} {city} clinic price list']
        if stage == 'semantic':
            label = term
            return [f'Clinics in {city} publishing their own treatment fees for {label}; '
                    'official treatment pages and clinic price menus']
        config = self.country(country)
        for language in config.get('search_languages', []):
            if language == 'en':
                continue
            terms = synonyms.get(language) or local_terms(procedure, language)
            words = config.get('search_terms', {}).get(language, {}).get('price_terms', [])
            if terms and words:
                # One language, one primary local synonym, two price intents.
                return list(dict.fromkeys(f'{terms[0]} {city} {w}' for w in words[:2]))
        return []

    def currency_aliases(self):
        owners = {}
        for spec in self.countries.values():
            for code, aliases in spec.get('currency_aliases', {}).items():
                for alias in [code, *aliases]:
                    owners.setdefault(alias, set()).add(code)
        # Shared $, kr, etc. cannot establish currency by country alone.
        return {alias: next(iter(codes)) for alias, codes in owners.items() if len(codes) == 1}


# Imported once per worker process; requests never reopen these files.
CATALOG = Catalog(Path(__file__).with_name('config'))
MIN_DISPLAY, GOOD_ENOUGH, TARGET = 4, 6, 8


class ReasonCache:
    ttl = {'directory': 7 * 86400, 'market_average': 86400,
           'wrong_city': 86400, 'wrong_procedure': 86400,
           'consultation_fee': 86400, 'no_price': 6 * 3600,
           'blocked': 300, 'fetch_failed': 60}

    def __init__(self, clock=time.monotonic, capacity=4096):
        self.clock, self.capacity, self.rows = clock, capacity, OrderedDict()

    def get(self, key):
        row = self.rows.get(key)
        if row and row[0] > self.clock():
            self.rows.move_to_end(key)
            return row[1]
        self.rows.pop(key, None)
        return ''

    def put(self, key, reason):
        if reason not in self.ttl:
            return
        self.rows[key] = (self.clock() + self.ttl[reason], reason)
        self.rows.move_to_end(key)
        while len(self.rows) > self.capacity:
            self.rows.popitem(last=False)


REJECTIONS = ReasonCache()
CITY_COUNTRIES = ReasonCache(capacity=2048)


async def resolve_country(engine, city, supplied=''):
    if supplied and supplied.strip().upper() in CATALOG.countries:
        return supplied.strip().upper()
    hint = engine.country_hint_for_city(city)
    if hint:
        return hint
    key = normalized(city)
    entry = CITY_COUNTRIES.rows.get(key)
    if entry and entry[0] > time.monotonic():
        return entry[1]
    places = engine.GooglePlacesClient()
    country = await places.resolve_country_for_city(city) if places.configured else ''
    CITY_COUNTRIES.rows[key] = (time.monotonic() + (86400 if country else 300), country)
    while len(CITY_COUNTRIES.rows) > CITY_COUNTRIES.capacity:
        CITY_COUNTRIES.rows.popitem(last=False)
    return country


class ExaClient:
    """URL-only rescue. A discovery hit is never a price or identity assertion."""
    def __init__(self, engine):
        self.engine = engine
        self.calls = 0
        self.cache_hits = 0
        self.last_error = ''

    async def search(self, query, country):
        key = f'exa::{country}::{query}'
        cached = await self.engine.serp_cache_get(key, 8, 1)
        if cached is not None:
            self.cache_hits += 1
            return cached
        token = os.getenv('EXA_API_KEY', '').strip()
        if not token:
            return []
        self.calls += 1
        try:
            async with httpx.AsyncClient(timeout=8) as client:
                response = await client.post('https://api.exa.ai/search',
                    headers={'x-api-key': token},
                    json={'query': query, 'type': 'auto', 'numResults': 8})
                response.raise_for_status()
                payload = response.json()
                if not isinstance(payload, dict) or not isinstance(payload.get('results'), list):
                    raise ValueError('Invalid Exa results')
                rows = [self.engine.SearchHit(title=str(r.get('title') or ''),
                            url=r['url'], query='exa:' + query)
                        for r in payload['results']
                        if isinstance(r, dict) and isinstance(r.get('url'), str)
                        and r['url'].startswith(('https://', 'http://'))][:8]
            await self.engine.serp_cache_put(key, 8, 1, rows)
            return rows
        except (httpx.HTTPError, ValueError, KeyError):
            self.last_error = 'exa_request_failed'
            return []


async def run_progressive(engine, *, city, procedure, country_code, stored_pool,
                          desired_new, limit, debug, client_known_clinic_hosts=None,
                          excluded_source_urls=None, serper_request_budget=0,
                          display_limit=4, background_collection=False,
                          initial_serper_requests=0, **unused):
    """Reuse discover() for every verification gate; replace only orchestration."""
    started = time.monotonic()
    excluded = set(excluded_source_urls or [])
    stored = engine.dedupe_live_results([r for r in stored_pool
        if r.source_url not in excluded and engine._app_can_show_row(r)])
    goal = min(20, len(stored)+desired_new) if background_collection else GOOD_ENOUGH
    if len(stored) >= goal or desired_new <= 0:
        return [], [], True
    country = await resolve_country(engine, city, country_code)
    selected = engine.canonicalize_procedure(procedure)
    directory = await engine.firestore_load_clinic_directory(city)
    priced_hosts = {engine.stored_provider_identity_host(r) for r in stored}
    hosts = list(dict.fromkeys(h.strip().lower().removeprefix('www.')
        for h in [*(client_known_clinic_hosts or []), *(engine.host_of(h.url) for h in directory)]
        if isinstance(h, str) and re.fullmatch(
            r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?',
            h.strip().lower())))
    hosts = [h for h in hosts if h and h not in priced_hosts
             and engine.classify_source('https://' + h) == 'official_clinic'][:6]
    fetched = set(excluded)
    responses, merged, pending = [], [], []
    spent, exa_calls, places_calls = 0, 0, 0
    remaining = max(0, serper_request_budget - max(0, initial_serper_requests)) if serper_request_budget > 0 else 4
    total_serper_cap = min(4, remaining)
    deep = engine.env_bool('ENABLE_DEEP_DISCOVERY', True)
    stages = ['known_domains']
    # Search the market's language first. A slow English round must not hold
    # local tariff pages behind its fetch/navigation budget. Paid search caps
    # and verification gates remain the same; English is the fallback round.
    local_queries = CATALOG.queries(selected, city, country, engine.local_terms_for, stage='local')
    local_first = engine.env_bool('ENABLE_MULTILINGUAL_SEARCH', True) and bool(local_queries)
    stages.append('local' if local_first else 'primary')
    if deep and local_first:
        stages.append('primary')
    if deep:
        if engine.env_bool('ENABLE_EXA_RESCUE', False):
            stages.append('exa')
        stages.append('places')
    # Total fast <=24 HTML GETs; total deep <=32 HTML GETs. Per-URL inflight
    # dedupe and the existing bounded HTTP pool still apply.
    limits = {'known_domains': 8, 'primary': 16, 'local': 12, 'exa': 10, 'places': 10}
    for stage in stages:
        if len(stored) + len(merged) >= goal:
            break
        queries, urls, stage_hosts = [], [], []
        if stage == 'known_domains':
            stage_hosts = hosts
            if not hosts:
                continue
        elif stage in {'primary', 'local'}:
            queries = CATALOG.queries(selected, city, country, engine.local_terms_for, stage=stage)
            queries = queries[:min(2, max(0, total_serper_cap-spent))]
            if not queries:
                continue
            urls = pending[:12]
        elif stage == 'exa':
            provider = ExaClient(engine)
            hits = await provider.search(CATALOG.queries(selected, city, country,
                                        engine.local_terms_for, stage='semantic')[0], country)
            exa_calls += provider.calls
            urls = [h.url for h in hits if engine.classify_source(h.url) == 'official_clinic']
            if not urls:
                await engine._emit_hybrid_status(round=stage, exa_calls=exa_calls,
                                                provider_error=provider.last_error)
                continue
        else:
            places = engine.GooglePlacesClient()
            if not places.configured:
                continue
            found = await places.discover_city_clinic_websites(city,
                engine.search_profile(country, city)[0], procedure=procedure,
                max_websites=6, max_queries=2)
            places_calls += places.requests_attempted
            for hit in found:
                hit.directory_verified = True
                hit.directory_verification_source = 'google_places'
            if found:
                await engine.firestore_upsert_clinic_directory(city, country, found)
            stage_hosts = [engine.host_of(h.url) for h in found
                           if engine.host_of(h.url) not in priced_hosts]
            if not stage_hosts:
                continue
        await engine._emit_hybrid_status(phase='searching', round=stage, queries=queries,
            search_country_code=country, verified_count=len(stored)+len(merged),
            serper_requests=spent, exa_calls=exa_calls, places_calls=places_calls)
        budget = {'left': limits[stage], 'blocked': 0, 'lock': asyncio.Lock()}
        token = engine._interactive_fetch_budget.set(budget)
        progress_token = engine._hybrid_round_progress_base.set({
            'fetched_pages': sum(r.fetched_pages for r in responses), 'serper_requests': spent})
        try:
            response = await engine.discover(engine.DiscoverRequest(
                city=city, procedure=procedure, country_code=country or None,
                limit=min(20, max(TARGET, limit)), persist=False, debug=debug,
                search_mode='expanded' if queries else 'site_focus',
                progressive_stage=stage, query_override=queries,
                progressive_stop_count=max(1, goal-len(stored)-len(merged)),
                interactive_fast=True, economical_growth=True, hybrid_interactive=True,
                skip_places_bootstrap=True, enable_serper=bool(queries),
                serper_request_cap=len(queries), priority_site_hosts=stage_hosts,
                priority_site_urls=[u for u in urls if u not in fetched][:40],
                previously_fetched_urls=sorted(fetched),
                known_clinic_hosts=sorted(priced_hosts)))
        finally:
            engine._interactive_fetch_budget.reset(token)
            engine._hybrid_round_progress_base.reset(progress_token)
        responses.append(response)
        fetched.update(response.crawled_urls)
        diag = response.diagnostics
        if diag:
            spent += diag.serper_requests_attempted
            diag.progressive_stage = stage
            diag.exa_requests = exa_calls
            diag.places_discovery_queries += places_calls
            pending = list(dict.fromkeys([*diag.pending_price_navigation_urls,
                                          *diag.selected_official_candidate_urls, *pending]))
        merged = engine.dedupe_live_results([r for r in engine.merge_live_results(responses)
                     if r.source_url not in excluded and engine._app_can_show_row(r)
                     and not any(engine.same_clinic_identity(r, s) for s in stored)])
        priced_hosts.update(engine.official_identity_host(r) for r in merged)
        await engine._emit_hybrid_status(phase='round_complete', round=stage,
            verified_count=len(stored)+len(merged), fresh_count=len(merged),
            serper_requests=spent, exa_calls=exa_calls, places_calls=places_calls,
            fetched_pages=sum(r.fetched_pages for r in responses),
            elapsed_ms=round((time.monotonic()-started)*1000),
            good_enough=GOOD_ENOUGH, target=TARGET)
        await engine._emit_hybrid_partial([
            *stored, *(engine._display_from_live(r, 'live_search') for r in merged)
        ][:display_limit])
        # Reuse a newly verified official domain for another procedure in this
        # city. Preserve any established Places identity/rating from the index.
        existing = {engine.host_of(hit.url): hit for hit in directory}
        learned = []
        for row in merged:
            if row.source_type != 'official_clinic' or not row.city_match or not row.clinic_own_price:
                continue
            website = row.official_website or engine.official_site_root(row.source_url)
            host = engine.host_of(website)
            old = existing.get(host)
            hit = old.model_copy(deep=True) if old else engine.SearchHit(title=row.clinic_name, url=website)
            hit.directory_verified = True
            hit.directory_verification_source = hit.directory_verification_source or 'verified_price_page'
            hit.directory_capabilities = list(dict.fromkeys([*hit.directory_capabilities,
                                                           engine.canonicalize_procedure(procedure)]))
            learned.append(hit)
        if learned:
            try:
                await engine.firestore_upsert_clinic_directory(city, country, learned)
            except Exception:
                await engine._emit_hybrid_status(index_write_error='clinic_directory_update_failed')
        if diag:
            reasons = {'directory_unverified': 'directory', 'comparative_market_article': 'market_average',
                       'generic_multi_clinic_price': 'market_average',
                       'foreign_quoted_price_city': 'wrong_city', 'consultation_fee': 'consultation_fee'}
            accepted_urls = {r.source_url for r in merged}
            for sample in diag.reject_samples:
                reason = reasons.get(sample.reason)
                if reason and sample.url not in accepted_urls:
                    REJECTIONS.put((engine.fold(city), procedure, sample.url), reason)
    print('[GP SEARCH] ' + json.dumps(dict(city=city, procedure=procedure, country=country,
          strategy='progressive', background_collection=background_collection,
          stages=[r.diagnostics.progressive_stage for r in responses if r.diagnostics],
          firestore_cards=len(stored), verified=len(stored)+len(merged), serper=spent,
          exa=exa_calls, places=places_calls, cheap_fetches=sum(r.fetched_pages for r in responses),
          rendered_fetches=0, elapsed_ms=round((time.monotonic()-started)*1000))), flush=True)
    return responses, merged, len(stored)+len(merged) >= goal
