
"""
Aesthetic Procedure Price Discovery v0.11.88 — provider tariffs and sparse-price rescue

Main fixes vs v0.5:
- hard reject retail skincare/product pages for injectable procedures
- "hyaluronic acid" alone is NOT enough to count as dermal filler
- price ranges must be syntactically attached to the currency/price phrase
- duration ranges like "20–30 minutes" can no longer overwrite €150
- rejects negated filler evidence ("no dermal fillers")
- rejects ambiguous multi-price comparison rows
- better clinic identity resolution from homepage/domain
- generic titles like "Page 3 of 4" can never become clinic names
- Google Places remains optional but useful for identity/location/rating
- service-section binding prevents previous-service prices leaking into filler
- marketplace SERP results must mention the requested city before fetch
- local no-price clinic pages get a domain-specific follow-up price search
- weak service titles like "Massage Tirana" are resolved via homepage/domain
- country-aware primary-language procedure searches
- filler/implant/toxin brand query expansion (Juvederm, Teosyal, Restylane, etc.)
- marketplace search expansion across Fresha, WhatClinic, Booksy and Treatwell
- local marketplace category pages are used as discovery leads for provider profiles
- filler brand/product-line extraction is kept separate from canonical procedure
- country can be inferred from city through Google Places when country_code is omitted

Run:
    python3 -m uvicorn aesthetic_price_discovery_v11_67:app --reload --port 8080
"""

from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from contextvars import ContextVar
import hashlib
import json
import math
import os
import re
import sys
import threading
import time
import unicodedata
import weakref
from datetime import datetime, timezone
from difflib import SequenceMatcher
from functools import lru_cache
from html import unescape
from typing import Literal
from urllib.parse import urlparse, urlunparse, urljoin, quote, urlencode

import httpx
from bs4 import BeautifulSoup
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
import vertical_search
from injectable_scope import injectable_scope_rejection

try:
    from google.cloud import firestore
except Exception:
    firestore = None

# The .env key wins over an older SERPER_API_KEY left in the process environment.
load_dotenv(override=True)


# ============================================================
# Models
# ============================================================

class DiscoverRequest(BaseModel):
    city: str = Field(min_length=2)
    procedure: str = Field(min_length=2)
    country_code: str | None = None
    limit: int = Field(default=5, ge=1, le=20)
    persist: bool = False
    debug: bool = True
    search_mode: Literal["standard", "expanded", "deep", "rescue", "site_focus"] = "standard"
    interactive_fast: bool = False
    refresh_places: bool = False
    full_growth: bool = False
    economical_growth: bool = False
    enable_serper: bool = True
    serper_request_cap: int = Field(default=0, ge=0, le=100)
    hybrid_interactive: bool = False
    adaptive_rescue: bool = False
    previously_fetched_urls: list[str] = []
    # The app runs this expanded round alone. Lead with booking menus
    # instead of the English "price list" queries, which return blogs.
    app_fast_queries: bool = False
    # A hybrid search crawls only clinics absent from this procedure/city's
    # trusted Firestore price pool. The tariff refresh runs separately.
    known_clinic_hosts: list[str] = Field(default_factory=list)
    known_clinic_names: list[str] = Field(default_factory=list)
    # Clinics already verified in this city for another procedure. Search
    # their tariff pages first. They are not an exclusion list.
    priority_site_hosts: list[str] = Field(default_factory=list)
    # URLs discovered in an earlier round, never caller-supplied prices.
    priority_site_urls: list[str] = Field(default_factory=list, max_length=40)
    # Round 0 already loaded or filled the city clinic directory.
    skip_places_bootstrap: bool = False
    # Verified directory domains crawled in the immediately preceding round.
    # An unpriced homepage/service page is a reason to try a site query next.
    previous_round_verified_hosts: list[str] = Field(default_factory=list)
    progressive_stage: str = ""
    query_override: list[str] | None = Field(default=None, max_length=2)
    progressive_stop_count: int = Field(default=6, ge=1, le=20)


class SearchHit(BaseModel):
    title: str
    url: str
    snippet: str = ""
    query: str = ""
    place_id: str = ""
    place_name: str = ""
    place_address: str = ""
    place_rating: float | None = None
    place_user_rating_count: int | None = None
    place_types: list[str] = []
    place_primary_type: str = ""
    directory_verified: bool = False
    directory_relevance_score: float = 0.0
    directory_capabilities: list[str] = []
    directory_was_inactive: bool = False
    directory_evidence_pages: int = 0
    directory_verification_source: str = ""


class PlaceIdentity(BaseModel):
    name: str
    formatted_address: str = ""
    website: str = ""
    rating: float | None = None
    user_rating_count: int | None = None
    place_id: str = ""
    city_match: bool = False


class ExtractedEvidence(BaseModel):
    raw_procedure_text: str
    raw_price_text: str
    price_min: float
    price_max: float | None = None
    currency: str
    unit: str = "procedure"
    qualifier: Literal["exact", "from", "range", "approximate", "promo", "unknown"] = "unknown"
    original_price_min: float | None = None
    original_price_max: float | None = None
    raw_evidence: str
    source_url: str
    extraction_method: str


class ClinicPriceResult(BaseModel):
    clinic_name: str
    city: str
    procedure_canonical: str
    procedure_display_name: str
    procedure_detail: str = ""
    product_brand: str = ""
    product_line: str = ""
    price_min: float
    price_max: float | None = None
    currency: str
    qualifier: str
    unit: str
    original_price_min: float | None = None
    original_price_max: float | None = None
    source_url: str
    source_host: str
    official_website: str = ""
    source_type: Literal["official_clinic", "marketplace", "directory", "social", "unknown"]
    evidence_type: Literal[
        "official_price_menu",
        "official_treatment_page",
        "marketplace_service_menu",
        "marketplace_profile",
        "official_article",
        "official_page",
        "unknown",
    ] = "unknown"
    clinic_own_price: bool
    city_match: bool
    identity_verified: bool
    rating: float | None = None
    user_rating_count: int | None = None
    confidence: float = Field(ge=0, le=1)
    raw_procedure_text: str
    raw_evidence: str
    price_scope: str = ""  # e.g. package_including_travel; shown with the price
    # Preserve tariff headings separately from price evidence and branch menus.
    source_location_text: str = ""

    # Verification/provenance added in v0.11.41.
    price_verification_status: str = ""
    official_procedure_verified: bool = False
    official_price_found: bool = False
    official_price_override: bool = False
    marketplace_price_capture: str = ""
    marketplace_source_url: str = ""
    marketplace_source_host: str = ""
    marketplace_price_min: float | None = None
    marketplace_price_max: float | None = None
    marketplace_currency: str = ""
    marketplace_raw_evidence: str = ""
    # Public business identifiers extracted from the provider's own legal,
    # contact or imprint page. They are identity evidence, never price proof.
    legal_identifiers: list[str] = Field(default_factory=list)
    legal_identity_urls: list[str] = Field(default_factory=list)
    legal_entity_names: list[str] = Field(default_factory=list)
    operator_contacts: list[str] = Field(default_factory=list)


class RejectSample(BaseModel):
    url: str
    reason: str
    detail: str = ""


class DiscoveryDiagnostics(BaseModel):
    progressive_stage: str = ""
    exa_requests: int = 0
    negative_cache_hits: int = 0
    search_mode: str = ""
    selected_official_candidate_urls: list[str] = Field(default_factory=list)
    unpriced_local_provider_hosts: list[str] = Field(default_factory=list)
    pending_price_navigation_urls: list[str] = Field(default_factory=list)
    search_country_code: str = ""
    search_language: str = ""
    rejected_fetch_failed: int = 0
    rejected_http_blocked: int = 0
    firestore_clinics_known_before_search: int = 0
    existing_clinic_urls_skipped: int = 0
    indexed_price_discovery_queries: list[str] = []
    indexed_price_uncached_queries: list[str] = []
    indexed_price_candidate_urls: list[str] = []
    indexed_price_serp_samples: list[dict[str, str]] = []
    serp_queries: int = 0
    adaptive_site_query_hosts: list[str] = []
    adaptive_site_query_texts: list[str] = []
    adaptive_site_queries: int = 0
    adaptive_site_urls: int = 0
    adaptive_site_candidate_urls: list[str] = []
    procedure_subdomain_probed_urls: list[str] = []
    procedure_subdomain_candidate_urls: list[str] = []
    procedure_subdomain_reject_samples: list[dict[str, str]] = []
    adaptive_followup_page_budget_blocked: bool = False
    interactive_fetch_budget_exhausted: bool = False
    serp_results_per_query: int = 0
    serp_hits_total: int = 0
    unique_urls: int = 0
    pages_attempted: int = 0
    pages_fetched: int = 0
    pages_with_procedure_text: int = 0
    pages_with_price_candidates: int = 0
    price_candidates_total: int = 0
    rejected_market_context: int = 0
    rejected_bad_identity: int = 0
    rejected_city: int = 0
    rejected_foreign_city: int = 0
    rejected_retail_product: int = 0
    rejected_retail_evidence_blocks: int = 0
    rejected_procedure_negation: int = 0
    rejected_ambiguous_multi_price: int = 0
    rejected_marketplace_category: int = 0
    rejected_marketplace_serp_city: int = 0
    rejected_marketplace_url_geo: int = 0
    marketplace_category_pages_expanded: int = 0
    marketplace_profile_urls: int = 0
    rejected_price_before_procedure: int = 0
    rejected_no_price: int = 0
    site_followup_queries: int = 0
    site_followup_urls: int = 0
    serper_rate_limit_retries: int = 0
    serper_request_cap: int = 0
    serper_cache_hits: int = 0
    serper_cache_writes: int = 0
    serper_free_account_num_fallbacks: int = 0
    serper_effective_num_cap: int = 20
    serper_configured: bool = False
    serper_requests_attempted: int = 0
    serper_requests_succeeded: int = 0
    serper_requests_failed: int = 0
    serper_requests_skipped: int = 0
    serper_disabled: bool = False
    serper_disabled_reason: str = ""
    serper_last_error: str = ""
    brightdata_serp_configured: bool = False
    brightdata_serp_requests_attempted: int = 0
    brightdata_serp_requests_succeeded: int = 0
    brightdata_serp_requests_failed: int = 0
    brightdata_serp_hits_total: int = 0
    brightdata_serp_fallback_used: bool = False
    brave_search_configured: bool = False
    brave_search_requests_attempted: int = 0
    brave_search_requests_succeeded: int = 0
    brave_search_requests_failed: int = 0
    brave_search_hits_total: int = 0
    brave_search_cache_hits: int = 0
    brave_search_used: bool = False
    marketplace_names_cleaned: int = 0
    official_article_rows: int = 0
    places_discovery_queries: int = 0
    places_candidate_websites: int = 0
    places_query_texts: list[str] = []
    places_candidate_names: list[str] = []
    places_candidate_hosts: list[str] = []
    places_provider_category_queries: int = 0
    serp_directory_candidates: int = 0
    serp_directory_candidate_hosts: list[str] = []
    serp_directory_verified: int = 0
    serp_directory_added: int = 0
    serp_directory_linked_official_resolved: int = 0
    serp_directory_linked_official_hosts: list[str] = []
    serp_directory_rejected: list[str] = []
    serp_page2_queries: int = 0
    serp_page2_hits_total: int = 0
    serp_page2_candidate_hosts: list[str] = []
    places_results_total: int = 0
    places_results_with_website: int = 0
    places_internal_links_discovered: int = 0
    places_api_status: int = 0
    places_api_error: str = ""
    places_requests_attempted: int = 0
    places_requests_succeeded: int = 0
    places_quota_blocked: bool = False
    clinic_directory_cached: int = 0
    clinic_directory_used: int = 0
    clinic_directory_all_names: list[str] = []
    clinic_directory_all_hosts: list[str] = []
    clinic_directory_all_capabilities: list[str] = []
    clinic_directory_bootstrap_added: int = 0
    clinic_directory_internal_links: int = 0
    price_navigation_candidate_urls: list[str] = []
    selected_internal_urls: list[str] = []
    fetch_slots_before_internal: int | None = None
    known_firestore_clinics: list[dict[str, str]] = []
    clinic_directory_deactivated: int = 0
    clinic_directory_rejected_irrelevant: int = 0
    clinic_directory_rejected_retail: int = 0
    clinic_directory_rejected_agency: int = 0
    places_rejected_clinics: list[str] = []
    places_miss_but_local_page_accepted: int = 0
    selected_marketplace_profiles: int = 0
    selected_marketplace_urls: list[str] = []
    whatclinic_price_blocks_found: int = 0
    whatclinic_snippet_price_candidates: int = 0
    whatclinic_category_results_rejected: int = 0
    whatclinic_weak_marketplace_evidence_rejected: int = 0
    selected_price_like_official: int = 0
    selected_directory_roots: int = 0
    selected_directory_names: list[str] = []
    selected_directory_hosts: list[str] = []
    selected_general_web: int = 0
    marketplace_official_checks: int = 0
    marketplace_official_variant_checks: int = 0
    marketplace_official_site_crawls: int = 0
    marketplace_official_sites_matched: int = 0
    marketplace_official_sites_from_directory: int = 0
    marketplace_official_weak_directory_skipped: int = 0
    marketplace_official_directory_superseded: int = 0
    marketplace_official_sites_from_search: int = 0
    marketplace_official_sites_from_linked_discovery_page: int = 0
    marketplace_official_sites_from_profile_link: int = 0
    marketplace_official_sites_from_domain_probe: int = 0
    marketplace_official_sites_from_brand_identity_probe: int = 0
    marketplace_official_domain_probe_attempts: int = 0
    marketplace_official_domain_probe_matches: int = 0
    marketplace_official_domain_probe_rejected_no_procedure: int = 0
    marketplace_official_resolution_search_queries: int = 0
    marketplace_official_sites_cached: int = 0
    marketplace_official_procedure_confirmed: int = 0
    marketplace_official_prices_found: int = 0
    marketplace_prices_overridden: int = 0
    marketplace_official_no_price: int = 0
    marketplace_official_unresolved: int = 0
    marketplace_snippet_prices_rejected: int = 0
    accepted_rows_before_dedupe: int = 0
    accepted_rows_after_dedupe: int = 0
    accepted_candidate_clinics: list[str] = []
    trusted_candidate_clinics: list[str] = []
    trusted_novel_candidate_clinics: list[str] = []
    trust_rejected_rows: int = 0
    trust_reject_samples: list[str] = []
    reject_samples: list[RejectSample] = []


class DiscoverResponse(BaseModel):
    city: str
    procedure: str
    country_code: str = ""
    primary_language: str = "en"
    queries: list[str]
    results: list[ClinicPriceResult]
    searched_urls: int
    fetched_pages: int
    search_errors: list[str] = []
    diagnostics: DiscoveryDiagnostics | None = None
    crawled_urls: list[str] = Field(default_factory=list, exclude=True)


class HybridDiscoverRequest(BaseModel):
    city: str = Field(min_length=2)
    procedure: str = Field(min_length=2)
    country_code: str | None = None
    stored_count: int = Field(default=6, ge=0, le=10)
    fresh_count: int = Field(default=2, ge=0, le=10)
    display_limit: int = Field(default=4, ge=1, le=4)
    # A server job can fill the UI and keep collecting a larger market pool.
    collection_target: int = Field(default=0, ge=0, le=40)
    background_collection: bool = False
    enable_growth_search: bool = True
    max_growth_rounds: int = Field(default=4, ge=1, le=4)
    fast_interactive_search: bool = True
    force_full_growth_search: bool = False

    # Economical by default: crawl the existing verified clinic directory
    # first, then use a tightly capped SERP rescue only if fresh results are
    # still missing.
    economical_growth: bool = True

    # Demand-driven jobs start with the web index; optional Places discovery
    # must not delay the first procedure-and-city price search.
    serper_first: bool = False

    # v0.11.41 app bridge:
    # Python stays the "hunter"; it seeds the existing Firebase candidate/url
    # queues but never writes directly to Explore's verified-price collection.
    sync_app_bridge: bool = False
    # No deployed JS consumer for staging was present in the supplied files.
    # The app can still reverify candidate identities and cached price URLs.
    sync_app_staging: bool = False

    debug: bool = True
    # App paints stored cards before the live search finishes.
    stream_progress: bool = False
    # Prefer stored_count saved and fresh_count new clinics. By default,
    # verified overflow from either source fills missing slots up to the limit.
    # Strict mode disables that fallback for diagnostic callers.
    strict_new_clinics: bool = False
    # Flutter reports candidates rejected by its final price validator. A
    # bounded continuation must not count or fetch those same URLs again.
    excluded_source_urls: list[str] = Field(default_factory=list, max_length=40)
    # Discovery-only hints from the app's separately verified Firestore pool.
    # No client price is accepted or persisted by the Python server.
    client_stored_count: int = Field(default=0, ge=0, le=40)
    client_known_clinic_hosts: list[str] = Field(default_factory=list, max_length=40)
    client_known_clinic_names: list[str] = Field(default_factory=list, max_length=40)
    # 0 uses MAX_ADAPTIVE_TOTAL_SERPER_REQUESTS. A short city may raise this
    # in-process cap (it is not a Serper credit balance).
    serper_request_budget: int = Field(default=0, ge=0, le=40)


class DisplayClinicPrice(ClinicPriceResult):
    origin: Literal[
        "firestore",
        "live_search",
        "firestore_fallback",
        "live_fallback",
    ]
    last_verified_at: str = ""
    cache_age_days: int | None = None


class HybridDiscoverResponse(BaseModel):
    city: str
    procedure: str
    country_code: str = ""
    strategy: str = "2_firestore_2_new_live"
    firestore_enabled: bool = False
    firestore_available: bool = False
    stored_available: int = 0
    client_stored_available: int = 0
    known_firestore_clinics: list[dict[str, str]] = []
    live_available: int = 0
    desired_new_for_display: int = 0
    novel_live_available: int = 0
    existing_operator_aliases: list[dict[str, str]] = Field(default_factory=list)
    rotation_persisted: bool = False
    official_tariff_refresh_diagnostics: dict = Field(default_factory=dict)
    tariff_serper_network_requests: int = 0
    persisted_count: int = 0
    app_bridge_enabled: bool = False
    app_candidates_synced: int = 0
    app_site_urls_synced: int = 0
    app_evidence_staged: int = 0
    newly_discovered_count: int = 0
    genuinely_new_count: int = 0
    corrected_reverification_count: int = 0
    quality_rejected_count: int = 0
    quality_reject_samples: list[str] = Field(default_factory=list)
    genuinely_new_clinics: list[str] = Field(default_factory=list)
    corrected_reverification_clinics: list[str] = Field(default_factory=list)
    stabilized_clinic_names: list[dict[str, str]] = Field(default_factory=list)
    refreshed_existing_count: int = 0
    weak_firestore_deactivated: int = 0
    whatclinic_firestore_normalized: int = 0
    cached_units_normalized: int = 0
    economical_growth_used: bool = False
    serper_network_requests_total: int = 0
    serper_cache_hits_total: int = 0
    brave_search_requests_total: int = 0
    brave_search_used: bool = False
    growth_search_used: bool = False
    growth_rounds: list[str] = []
    adaptive_rescue_used: bool = False
    adaptive_site_focus_used: bool = False
    adaptive_new_clinics_missing: int = 0
    adaptive_serper_budget_remaining: int = 0
    growth_exhausted: bool = False
    growth_exhausted_reason: str = ""
    growth_stopped_for_cache_sufficiency: bool = False
    fallback_used: bool = False
    fallback_reason: str = ""
    card_diagnostics: list[str] = Field(default_factory=list)
    stored_results: list[DisplayClinicPrice] = []
    fresh_results: list[DisplayClinicPrice] = []
    fallback_results: list[DisplayClinicPrice] = []
    display_results: list[DisplayClinicPrice] = []
    # Preserve overflow for the app's final validator before limiting to four.
    candidate_results: list[DisplayClinicPrice] = Field(default_factory=list)
    live_search_diagnostics: DiscoveryDiagnostics | None = None
    growth_diagnostics: dict[str, DiscoveryDiagnostics] = {}
    search_errors: list[str] = []
    growth_search_errors: dict[str, list[str]] = {}


class RefreshTargetsResponse(BaseModel):
    firestore_available: bool
    targets_seen: int = 0
    targets_refreshed: int = 0
    rows_persisted: int = 0
    errors: list[str] = []


class CityBootstrapResponse(BaseModel):
    city: str
    country_code: str = ""
    firestore_available: bool = False
    cached_before: int = 0
    places_configured: bool = False
    places_requests_attempted: int = 0
    places_requests_succeeded: int = 0
    places_status: int = 0
    places_error: str = ""
    places_quota_blocked: bool = False
    places_candidates: int = 0
    websites_verified: int = 0
    directory_added: int = 0
    directory_deactivated: int = 0
    directory_rejected_irrelevant: int = 0
    directory_rejected_retail: int = 0
    directory_rejected_agency: int = 0
    directory_reactivated: int = 0
    directory_rescued_by_price_evidence: int = 0
    directory_total: int = 0
    rejected_clinics: list[dict] = []
    clinics: list[dict] = []



# ============================================================
# Procedure normalization
# ============================================================

PROCEDURES = {
    "filler": {
        "display": "Dermal Filler",
        "aliases": [
            "dermal filler", "filler", "fillers", "lip filler", "lip fillers",
            "hyaluronic acid filler", "hyaluronic filler",
            "filler buze", "mărire buze", "marire buze",
            "filler buzësh", "filler buzesh",
            "mbushës buzësh", "mbushes buzesh",
            "филър", "хиалуронов филър",
            "relleno dérmico", "aumento labial", "filler labbra",
            "dolgu", "dudak dolgusu",
            "ajakfeltöltés", "hialuronsavas feltöltés",
        ],
    },
    "botox": {
        "display": "Botox",
        "aliases": [
            "botox", "botulinum toxin", "anti wrinkle injection", "baby botox",
            "botulino", "toksina botulinike", "toxina botulinica",
            "toxina botulínica", "ботокс", "botoks",
            "ránctalanítás", "botulinum toxin",
        ],
    },
    "chemical_peel": {
        "display": "Chemical Peel",
        "aliases": [
            "chemical peel", "chemical peels", "chemical peeling", "peeling chimic",
            "peeling chimique", "peeling chimico", "peeling quimico",
            "peeling kimik", "biorepeel", "biorepeelcl3", "biorepeel cl3", "bio repeel", "vi peel", "pca peel",
            "jessner peel", "glytone peel", "prx-t33", "cosmelan",
            "light peels", "light peel", "medium peels", "medium peel",
            "deep peels", "deep peel", "superficial peels", "superficial peel",
            "yellow peels", "yellow peel", "glycolic acid peel", "salicylic acid peel", "tca peel",
            "пилинг", "химичен пилинг",
            "kémiai hámlasztás", "kémiai peeling", "savas hámlasztás",
        ],
    },
    "breast_augmentation": {
        "display": "Breast Augmentation",
        "aliases": [
            "breast augmentation", "breast implants", "augmentation mammoplasty",
            "breast enlargement", "augmentation mastopexy", "breast lift with implants",
            "mamoplastia de aumento", "aumento de pecho", "aumento de mamas",
            "breast fat transfer", "fat transfer breast augmentation",
            "mellnagyobbitas", "mellnagyobbítás",
            "mastoplastica additiva", "mastoplastica addittiva",
            "aumento seno", "protesi mammarie",
            "zmadhim gjoksi", "zmadhimi i gjirit", "zmadhimi i gjoksit",
            "implante gjoksi",
            "увеличаване на бюст", "гръдни импланти",
        ],
    },
    "rhinoplasty": {
        "display": "Rhinoplasty",
        "aliases": [
            "rhinoplasty", "nose job", "rinoplastica",
            "rinoplastie", "rinoplastika", "rinoplastikë",
            "rinoplastikës", "rinoplastikën", "ринопластика",
            "nasenkorrektur", "rhinoplastik",
            "orrplasztika",
        ],
    },
    "hair_transplant": {
        "display": "Hair Transplant",
        "aliases": [
            "hair transplant", "fue hair transplant", "dhi hair transplant",
            "trapianto capelli", "trapianto di capelli", "trapianto dei capelli",
            "transplant de par", "transplant păr",
            "transplant flokësh", "mbjellje flokësh",
            "transplanti i flokëve", "mbjellja e flokëve",
            "transplanti", "transplantin e flokeve",
            "saç ekimi", "трансплантация на коса",
            "hajbeültetés", "hajátültetés",
        ],
    },
}


def fold_impl(text: str) -> str:
    if text.isascii():
        return re.sub(r"\s+", " ", text.lower()).strip()
    normalized = unicodedata.normalize("NFKD", text)
    normalized = "".join(ch for ch in normalized if not unicodedata.combining(ch))
    return re.sub(r"\s+", " ", normalized.lower()).strip()


@lru_cache(maxsize=65536)
def _fold_cached(text: str) -> str:
    return fold_impl(text)


def fold(text: str) -> str:
    text = text or ""
    return _fold_cached(text) if len(text) <= 256 else fold_impl(text)


def canonicalize_procedure(raw: str) -> str:
    f = fold(raw)
    if not f:
        return "other"
    if f in PROCEDURES:
        return f
    catalog_key = vertical_search.CATALOG.aliases.get(f)
    if catalog_key:
        reverse = {v: k for k, v in vertical_search.CATALOG.family_keys.items()}
        # Preserve the current six API families; specific subtypes remain
        # available to future callers without adding 151 pills to Flutter.
        if catalog_key in reverse:
            return reverse[catalog_key]
    # "Laser hair removal" contains the word hair. It is not a transplant.
    if "hair removal" in f or "laser hair" in f:
        return "laser_hair_removal"
    for canonical, spec in PROCEDURES.items():
        local = globals().get("PROCEDURE_LOCAL_TERMS", {}).get(canonical, {})
        for alias in [*spec["aliases"], *(term for terms in local.values() for term in terms)]:
            a = fold(alias)
            if a in f or f in a:
                return canonical
    return catalog_key or re.sub(r"[^a-z0-9]+", "_", f).strip("_") or "other"


def display_name(canonical: str) -> str:
    return PROCEDURES.get(canonical, {}).get("display", vertical_search.CATALOG.spec(canonical).get(
        "display_name_en", canonical.replace("_", " ").title()))


def aliases_for(raw: str) -> list[str]:
    c = canonicalize_procedure(raw)
    # Search translations must also match the rows on the fetched tariff.
    local = globals().get("PROCEDURE_LOCAL_TERMS", {}).get(c, {})
    return list(dict.fromkeys([
        *PROCEDURES.get(c, {}).get("aliases", [raw.strip()]),
        *(term for terms in vertical_search.CATALOG.spec(c).get("synonyms", {}).values() for term in terms),
        *(term for terms in local.values() for term in terms),
    ]))


# ============================================================
# City normalization
# ============================================================

CITY_ALIASES = {
    "tirana": ["tirana", "tiranë", "tirane"],
    "sofia": ["sofia", "софия"],
    "bucharest": ["bucharest", "bucurești", "bucuresti"],
    "milan": ["milan", "milano"],
    "istanbul": ["istanbul", "İstanbul"],
    "paris": ["paris"],
    "madrid": ["madrid"],
    "barcelona": ["barcelona"],
    "new york": ["new york", "new york city", "new-york", "nyc", "manhattan",
                 "brooklyn", "queens", "bronx", "staten island"],
}

FOREIGN_CITY_MARKS = [
    "birmingham", "london", "manchester", "leeds", "liverpool",
    "glasgow", "edinburgh", "rome", "roma", "milan", "milano",
    "paris", "sofia", "bucharest", "bucuresti", "istanbul",
    "ankara", "izmir", "dubai", "abu dhabi", "new york",
    "miami", "los angeles",
    # Romanian and neighboring city path tokens. A page that also names the
    # searched city is kept; the URL path gate below still rejects /preturi/iasi/
    # on a Timișoara search even when the menu mentions both cities.
    "iasi", "brasov", "cluj", "constanta", "sibiu", "oradea",
    "craiova", "chisinau", "timisoara",
]


def canonical_city(city: str) -> str:
    f = fold(city)
    for c, aliases in CITY_ALIASES.items():
        if any(fold(a) == f for a in aliases):
            return c
    return f


def aliases_for_city(city: str) -> list[str]:
    return CITY_ALIASES.get(canonical_city(city), [city])


def _city_token_in_text(text: str, name: str) -> bool:
    """Match complete city words, including URL separators and accents."""
    words = re.findall(r"[^\W_]+", fold(name))
    if not words:
        return False
    pattern = r"(?<![^\W_])" + r"[\W_]+".join(map(re.escape, words)) + r"(?![^\W_])"
    return bool(re.search(pattern, fold(text)))


def city_in_text(text: str, city: str) -> bool:
    f = fold(text).replace("_", " ")
    if canonical_city(city) == "new york":
        # Borough names are NYC. A state name alone in an explicitly foreign
        # address must not make an upstate/Westchester clinic a city clinic.
        borough = re.search(r"\b(?:nyc|manhattan|brooklyn|queens|bronx|staten island)\b", f)
        if borough:
            return True
        if re.search(r"\b(?:clifton park|westchester|white plains|long island|"
                     r"huntington|cedarhurst|great neck|albany|new jersey)\b", f):
            return False
        return bool(re.search(r"\bnew[ -]york(?: city)?\b", f))
    return any(_city_token_in_text(f, a) for a in aliases_for_city(city))


def address_matches_search_city(address: str, city: str) -> bool:
    """Places address must be the searched city or its metro, not a peer city."""
    if not (address or "").strip():
        return False
    if city_in_text(address, city):
        return True
    folded = fold(address)
    for area in CITY_METRO_AREAS.get(canonical_city(city), ()):
        if _city_token_in_text(folded, area):
            return True
    return False


def foreign_city_conflict(text: str, city: str) -> str:
    f = fold(text)
    targets = {fold(a) for a in aliases_for_city(city)}
    for mark in FOREIGN_CITY_MARKS:
        fm = fold(mark)
        if fm in targets:
            continue
        if _city_token_in_text(f, fm):
            return mark
    return ""


def foreign_quoted_price_city(evidence: str, city: str) -> bool:
    """A local SEO title must not turn a foreign-city tariff into a local quote."""
    if not evidence or not city:
        return False
    # A branch tariff heading outranks an SEO title or shared contact footer.
    marks = set(FOREIGN_CITY_MARKS) | {fold(a) for a in aliases_for_city(city)}
    names = "|".join(re.escape(mark) for mark in sorted(marks, key=len, reverse=True))
    branch = re.search(
        r"\b(?:precio|precios|coste|costo|price|prices|pricing|cost|tariff|fee)\b"
        r"[^|:!?€$]{0,85}?\b(?:en|in)\s+"
        rf"((?:{names})(?!\w)(?:\s*(?:and|y|&|/)\s*(?:{names})(?!\w))*)",
        fold(evidence),
    )
    if branch and not city_in_text(branch.group(1), city):
        return True
    # A tariff heading supplies its own branch scope, including cities absent
    # from the legacy city dictionary. Navigation elsewhere cannot override it.
    scope = re.search(r"(?i:(?:precio|coste|costo|price|cost)\b[^|:!?€$]{0,85}\b(?:en|in)\s+)"
                      r"([A-ZÁÉÍÓÚÜÑ][^|:!?€$\d]{1,45})\s*[|:]", evidence)
    if scope and not address_matches_search_city(scope.group(1).strip(), city):
        return True
    if city_in_text(evidence, city):
        return False
    foreign = foreign_city_conflict(evidence, city)
    if not foreign:
        return False
    return bool(re.search(r"(?:precio|coste|costo|cost|costs|price|prices|pricing|tariff|fee|أسعار|تكلفة).{0,64}" +
                          re.escape(fold(foreign)), fold(evidence), re.I))


def foreign_provider_without_local_price_proof(row) -> bool:
    """A request's city label is not proof that a foreign-named clinic is local."""
    identity = f"{row.clinic_name} {host_of(row.source_url)}"
    if not foreign_city_conflict(identity, row.city) or city_in_text(identity, row.city):
        return False
    proof = f"{urlparse(row.source_url).path} {row.raw_evidence or ''}"
    return not city_in_text(proof, row.city)


# ============================================================
# Search query generation
# ============================================================

# country -> primary search language + common local words meaning price.
# English is always searched too because many clinics publish bilingual pages.
COUNTRY_SEARCH_PROFILE = {
    "AL": ("sq", ["çmimi", "çmimet", "cmimi", "cmimet"]),
    "RO": ("ro", ["preț", "prețuri", "pret", "preturi"]),
    "MD": ("ro", ["preț", "prețuri", "pret", "preturi"]),
    "BG": ("bg", ["цена", "цени"]),
    "IT": ("it", ["prezzo", "prezzi", "tariffe"]),
    "TR": ("tr", ["fiyat", "fiyatları", "fiyatlar"]),
    "FR": ("fr", ["prix", "tarifs"]),
    "ES": ("es", ["precio", "precios", "tarifas"]),
    "DE": ("de", ["preis", "preise", "kosten"]),
    "PT": ("pt", ["preço", "preços", "valor"]),
    "PL": ("pl", ["cena", "cennik", "ceny"]),
    "GR": ("el", ["τιμή", "τιμές", "κόστος"]),
    "CZ": ("cs", ["cena", "ceník", "ceny"]),
    "HU": ("hu", ["ár", "árak", "árlista"]),
    "HR": ("hr", ["cijena", "cijene", "cjenik"]),
    "RS": ("sr", ["cena", "cene", "cenovnik"]),
    "GB": ("en", ["price", "prices", "cost"]),
    "US": ("en", ["price", "prices", "cost"]),
    "AE": ("ar", ["السعر", "الأسعار", "price"]),
    "SA": ("ar", ["السعر", "الأسعار", "price"]),
}

# Fast offline hints. If a city is not listed and Google Places is configured,
# v0.7 can infer the country asynchronously.
CITY_COUNTRY_HINTS = {
    "tirana": "AL", "tirane": "AL",
    "bucharest": "RO", "bucuresti": "RO", "bucurești": "RO",
    "sofia": "BG",
    "milan": "IT", "milano": "IT", "rome": "IT", "roma": "IT",
    "istanbul": "TR", "izmir": "TR", "ankara": "TR",
    "paris": "FR",
    "madrid": "ES", "barcelona": "ES",
    "berlin": "DE", "munich": "DE", "münchen": "DE",
    "lisbon": "PT", "lisboa": "PT",
    "warsaw": "PL", "warszawa": "PL",
    "athens": "GR", "athina": "GR",
    "prague": "CZ", "praha": "CZ",
    "budapest": "HU",
    "zagreb": "HR",
    "belgrade": "RS", "beograd": "RS",
    "london": "GB", "manchester": "GB", "birmingham": "GB",
    "leeds": "GB", "glasgow": "GB", "edinburgh": "GB",
    "liverpool": "GB", "bristol": "GB", "cardiff": "GB",
    "belfast": "GB", "brighton": "GB", "leicester": "GB",
    "southampton": "GB", "nottingham": "GB", "sheffield": "GB",
    "derby": "GB", "newcastle": "GB",
    "dubai": "AE", "abu dhabi": "AE", "sharjah": "AE",
    "riyadh": "SA", "jeddah": "SA", "doha": "QA", "kuwait": "KW",
    "timisoara": "RO", "iasi": "RO", "brasov": "RO", "bacau": "RO",
    "cluj": "RO", "cluj-napoca": "RO", "constanta": "RO", "sibiu": "RO",
    "oradea": "RO", "galati": "RO", "ploiesti": "RO", "craiova": "RO",
    "chisinau": "MD",
    "new york": "US", "nyc": "US",
    "lyon": "FR",
}

PROCEDURE_LOCAL_TERMS = {
    "filler": {
        "sq": ["filler buzësh", "mbushës buzësh", "filler dermal"],
        "ro": ["filler buze", "filler dermal", "injectare acid hialuronic"],
        "bg": ["дермален филър", "филър за устни", "хиалуронов филър"],
        "it": ["filler labbra", "filler dermico", "acido ialuronico labbra"],
        "tr": ["dudak dolgusu", "dermal dolgu", "hyaluronik dolgu"],
        "fr": ["injection acide hyaluronique", "filler lèvres", "comblement lèvres"],
        "es": ["aumento de labios", "relleno dérmico", "relleno de labios", "ácido hialurónico labios"],
        "de": ["lippen filler", "hyaluron filler", "lippenunterspritzung"],
        "pt": ["preenchimento labial", "preenchimento dérmico"],
        "pl": ["wypełnianie ust", "kwas hialuronowy usta"],
        "el": ["υαλουρονικό χείλη", "filler χειλιών"],
        "cs": ["výplň rtů", "kyselina hyaluronová rty"],
        "hu": ["ajakfeltöltés", "hialuronsavas feltöltés"],
        "hr": ["fileri za usne", "hijaluronski fileri"],
        "sr": ["fileri za usne", "hijaluronski fileri"],
        "ar": ["فيلر الشفاه", "حقن الفيلر", "حمض الهيالورونيك للشفاه"],
    },
    "botox": {
        "sq": ["botox", "toksina botulinike"],
        "ro": ["botox", "toxina botulinică"],
        "bg": ["ботокс", "ботулинов токсин"],
        "it": ["botox", "tossina botulinica"],
        "tr": ["botoks", "botulinum toksini"],
        "fr": ["botox", "toxine botulique"],
        "es": ["botox", "neuromoduladores", "toxina botulínica", "neuromodulador"],
        "de": ["botox", "botulinumtoxin"],
        "hu": ["botox", "ránctalanítás", "botulinum toxin"],
        "ar": ["بوتوكس", "سم البوتولينوم"],
    },
    "chemical_peel": {
        "hu": ["kémiai hámlasztás", "kémiai peeling"],
        "sq": ["peeling kimik", "peeling fytyre"],
        "ro": ["peeling chimic"],
        "bg": ["химичен пилинг"],
        "it": ["peeling chimico"],
        "tr": ["kimyasal peeling"],
        "fr": ["peeling chimique"],
        "es": ["peeling químico", "peelings químicos", "peeling de ácido salicílico", "peeling de ácido glicólico", "peeling médico"],
        "de": ["chemisches peeling"],
        "ar": ["تقشير كيميائي"],
    },
    "breast_augmentation": {
        "hu": ["mellnagyobbítás", "mellimplantátum"],
        "sq": ["zmadhimi i gjirit", "implante gjoksi"],
        "ro": ["implant mamar", "mărire sâni", "augmentare mamară",
               "implanturi mamare", "implante mamare", "implantul mamar",
               "mărire de sâni", "mărire a sânilor", "mărirea sânilor"],
        "bg": ["уголемяване на бюст", "гръдни импланти"],
        "it": ["mastoplastica additiva", "protesi mammarie"],
        "tr": ["meme büyütme", "meme implantı"],
        "fr": ["augmentation mammaire", "implants mammaires"],
        "es": ["aumento de pecho", "implantes mamarios"],
        "de": ["brustvergrößerung", "brustimplantate"],
        "ar": ["تكبير الثدي", "زراعة الثدي"],
    },
    "rhinoplasty": {
        "hu": ["orrplasztika"],
        "sq": ["rinoplastikë", "operacion hunde"],
        "ro": ["rinoplastie"],
        "bg": ["ринопластика"],
        "it": ["rinoplastica"],
        "tr": ["rinoplasti", "burun estetiği"],
        "fr": ["rhinoplastie"],
        "es": ["rinoplastia"],
        "de": ["nasenkorrektur", "rhinoplastik"],
        "ar": ["تجميل الأنف"],
    },
    "hair_transplant": {
        "hu": ["hajbeültetés", "hajátültetés"],
        "sq": ["transplant flokësh", "mbjellje flokësh"],
        "ro": ["transplant de păr"],
        "bg": ["трансплантация на коса"],
        "it": ["trapianto capelli"],
        "tr": ["saç ekimi"],
        "fr": ["greffe de cheveux"],
        "es": ["trasplante capilar"],
        "de": ["haartransplantation"],
        "ar": ["زراعة الشعر"],
    },
}

# Brands/products are query expansion and metadata, never a separate canonical
# procedure. A brand hit must still pass treatment-context and retail rejection.
PROCEDURE_BRANDS = {
    "filler": [
        "Juvederm", "Teosyal", "Restylane", "Stylage", "Belotero",
        "Revolax", "Neauvia", "Aliaxin", "Saypha", "Yvoire",
        "Elasty", "MaiLi", "Perfectha", "Pluryal", "Fillmed Art Filler",
        "Luminera",
    ],
    "botox": [
        "Botox", "Dysport", "Azzalure", "Bocouture", "Xeomin", "Nabota",
    ],
    "chemical_peel": [
        "BioRePeel", "PRX-T33", "Cosmelan", "Dermamelan",
    ],
    "breast_augmentation": [
        "Motiva", "Mentor", "Polytech", "Sebbin", "Nagor",
    ],
}

FILLER_PRODUCT_LINES = {
    "Juvederm": [
        "Volbella", "Volift", "Voluma", "Ultra 2", "Ultra 3", "Ultra 4",
        "Smile", "Volux",
    ],
    "Teosyal": [
        "RHA 1", "RHA 2", "RHA 3", "RHA 4", "Kiss", "Redensity 2",
        "Ultra Deep", "Deep Lines",
    ],
    "Restylane": [
        "Kysse", "Lyft", "Defyne", "Refyne", "Volyme",
    ],
    "Belotero": ["Balance", "Intense", "Volume", "Lips"],
    "Stylage": ["S", "M", "L", "XL", "Special Lips"],
    "Revolax": ["Fine", "Deep", "Sub-Q"],
    "Neauvia": ["Intense", "Stimulate", "Organic"],
}

MARKETPLACE_SEARCH_DOMAINS = [
    "fresha.com", "whatclinic.com", "booksy.com", "treatwell.com",
    "hirefrederick.com",
]

TREATWELL_DOMAINS_BY_COUNTRY = {
    "GB": "treatwell.co.uk",
    "DE": "treatwell.de",
    "FR": "treatwell.fr",
    "ES": "treatwell.es",
    "IT": "treatwell.it",
    "NL": "treatwell.nl",
    "BE": "treatwell.be",
    "AT": "treatwell.at",
    "CH": "treatwell.ch",
}


def marketplace_search_domains(country_code: str | None) -> list[str]:
    domains = [
        "fresha.com",
        "whatclinic.com",
        "booksy.com",
        "hirefrederick.com",
    ]
    cc = (country_code or "").upper()
    domains.append(TREATWELL_DOMAINS_BY_COUNTRY.get(cc, "treatwell.com"))
    # Preserve order and uniqueness.
    return list(dict.fromkeys(domains))


def country_hint_for_city(city: str) -> str:
    return CITY_COUNTRY_HINTS.get(fold(city), "")


def search_profile(country_code: str | None, city: str) -> tuple[str, list[str]]:
    cc = (country_code or country_hint_for_city(city) or "").upper()
    config = vertical_search.CATALOG.country(cc)
    for language in config.get("search_languages", []):
        words = config.get("search_terms", {}).get(language, {}).get("price_terms", [])
        if words:
            return language, words
    return COUNTRY_SEARCH_PROFILE.get(cc, ("en", ["price", "prices", "cost"]))


def local_terms_for(procedure: str, language: str) -> list[str]:
    canonical = canonicalize_procedure(procedure)
    return list(PROCEDURE_LOCAL_TERMS.get(canonical, {}).get(language, []))


def brands_for(procedure: str) -> list[str]:
    return list(PROCEDURE_BRANDS.get(canonicalize_procedure(procedure), []))


def detect_product_brand(text: str, procedure: str) -> str:
    t = fold(text)
    for brand in brands_for(procedure):
        if fold(brand) in t:
            return brand
    return ""


def detect_product_line(text: str, procedure: str) -> str:
    if canonicalize_procedure(procedure) != "filler":
        return ""
    brand = detect_product_brand(text, procedure)
    if not brand:
        return ""
    t = fold(text)
    for line in FILLER_PRODUCT_LINES.get(brand, []):
        if fold(line) in t:
            return line
    return ""


LOCAL_CLINIC_WORDS = {
    "sq": ["klinikë estetike", "qendër estetike", "mjekësi estetike"],
    "ro": ["clinică estetică", "medicină estetică", "clinică dermatologică"],
    "bg": ["естетична клиника", "естетична медицина"],
    "it": ["clinica estetica", "medicina estetica"],
    "tr": ["estetik klinik", "medikal estetik"],
    "fr": ["clinique esthétique", "médecine esthétique"],
    "es": ["clínica estética", "medicina estética"],
    "de": ["ästhetische klinik", "ästhetische medizin"],
    "pt": ["clínica estética", "medicina estética"],
    "pl": ["klinika medycyny estetycznej", "klinika estetyczna"],
    "el": ["αισθητική κλινική", "αισθητική ιατρική"],
    "cs": ["estetická klinika", "estetická medicína"],
    "hu": ["esztétikai klinika", "esztétikai medicina"],
    "hr": ["estetska klinika", "estetska medicina"],
    "sr": ["estetska klinika", "estetska medicina"],
    "ar": ["عيادة تجميل", "طب تجميلي"],
    "en": ["aesthetic clinic", "medical aesthetics clinic", "cosmetic clinic"],
}


def local_clinic_words(language: str) -> list[str]:
    return list(LOCAL_CLINIC_WORDS.get(language, LOCAL_CLINIC_WORDS["en"]))


def places_bootstrap_queries(city: str, language: str, procedure: str) -> list[str]:
    """Text Search strings for a new city's clinic directory.

    Filler does not search dental, cosmetic-dentist, or wellness categories.
    The caller spends at most two of these on a city that has no directory yet.
    """
    canonical = canonicalize_procedure(procedure) if procedure else ""
    if canonical == "filler" and language == "ro":
        return [
            f"clinică estetică {city}",
            f"dermatologie estetică {city}",
            f"chirurgie plastică {city}",
            f"acid hialuronic {city}",
        ]
    if canonical == "filler":
        return [
            f"aesthetic clinic {city}",
            f"dermatology clinic {city}",
            f"plastic surgery clinic {city}",
            f"hyaluronic acid filler {city}",
        ]
    queries: list[str] = []
    if canonical:
        terms = local_terms_for(canonical, language) or [display_name(canonical)]
        queries.append(f"{terms[0]} {city}")
    for word in local_clinic_words(language)[:2]:
        queries.append(f"{word} {city}")
    if f"plastic surgery clinic {city}" not in queries:
        queries.append(f"plastic surgery clinic {city}")
    seen: set[str] = set()
    kept: list[str] = []
    for query in queries:
        key = fold(query)
        if key in seen:
            continue
        seen.add(key)
        kept.append(query)
    return kept




def canonicalize_fresha_venue_url(url: str) -> str:
    """Booking links omit the service menu. The venue page has it."""
    match = re.search(
        r"https?://[^/]*fresha\.com(?:/[a-z]{2}(?:-[a-z]{2})?)?/a/([^/?#]+)",
        url or "",
        re.I,
    )
    if not match:
        return url
    return f"https://www.fresha.com/a/{match.group(1)}"


def _local_market_fast_queries(
    city: str,
    country_code: str,
    english_market_term: str,
    local_market_term: str,
) -> list[str]:
    """Six searches for a clinic tariff in that country's own language."""
    cc = country_code.upper()
    _lang, price_words = search_profile(cc, city)
    currency_token = {
        "HU": "Ft",
        "RO": "lei",
        "BG": "лв",
        "GB": "£",
        "TR": "TL",
        "PL": "zł",
        "CZ": "Kč",
        "US": "$",
        "AE": "AED",
    }.get(cc, "€")
    tld = {
        "HU": "hu", "RO": "ro", "IT": "it", "DE": "de", "FR": "fr",
        "ES": "es", "PL": "pl", "CZ": "cz", "TR": "com.tr", "GB": "uk",
        "BG": "bg", "GR": "gr", "HR": "hr", "RS": "rs", "PT": "pt",
    }.get(cc, "")
    price = price_words[0] if price_words else "price"
    local = local_market_term or english_market_term
    queries = [
        f'"{english_market_term}" "{city}" "{currency_token}"',
        f'"{local}" "{city}" "{price}"',
        f'"{english_market_term}" "{city}" "price list"',
        f'"{english_market_term}" "{city}" "{price}" clinic',
    ]
    if tld:
        queries.append(
            f'site:.{tld} "{english_market_term}" "{city}" "{price}"'
        )
    # Keep both marketplace families inside the default six-query cap.
    queries.insert(3, f'site:whatclinic.com "{city}" "{english_market_term}"')
    queries.insert(4, f'site:fresha.com/a/ "{city}" "{english_market_term}"')
    return queries


def localized_surgery_queries(
    city: str, procedure: str, country_code: str = "", rescue: bool = False,
) -> list[str]:
    """Keep local synonyms inside the small request cap, for any city."""
    language, prices = search_profile(country_code, city)
    canonical = canonicalize_procedure(procedure)
    english = display_name(canonical)
    terms = local_terms_for(canonical, language) or [english]
    price = prices[0] if prices else "price"
    tariff = prices[1] if len(prices) > 1 else price
    country = (country_code or country_hint_for_city(city) or "").upper()
    if rescue:
        return [
            f'{terms[min(2, len(terms) - 1)]} "{city}" {tariff} surgery',
            f'{terms[min(1, len(terms) - 1)]} "{city}" {country} clinic',
            f'"{english}" "{city}" cost surgeon',
            f'{terms[0]} "{city}" {price} hospital',
        ]
    return [
        f'{terms[0]} "{city}" {price}',
        f'{terms[min(1, len(terms) - 1)]} "{city}" {tariff}',
        f'{terms[min(2, len(terms) - 1)]} "{city}" {country} {price}',
        f'"{english}" "{city}" "price list"',
        f'{terms[0]} "{city}" clinic',
        f'"{english}" "{city}" hospital prices',
    ]


def _app_fast_query_list(
    city: str,
    canonical: str,
    english_market_term: str,
    local_market_term: str,
    brands: list[str],
    country_code: str = "",
) -> list[str]:
    """Six searches that reach a priced menu, not a comparison article."""
    cc = (country_code or country_hint_for_city(city) or "").upper()
    if canonical in {"rhinoplasty", "breast_augmentation"} and cc != "AL":
        return localized_surgery_queries(city, canonical, cc)
    # Albania's priced menus are on Fresha. Other countries publish tariffs
    # on their own sites, in forint, lei, and the local word for price.
    if cc and cc != "AL":
        return _local_market_fast_queries(
            city, cc, english_market_term, local_market_term,
        )
    if canonical == "chemical_peel":
        terms = ["BioRePeel", "peeling", local_market_term, english_market_term]
    elif canonical == "hair_transplant":
        # Graft prices are on clinic tariffs. Fresha-only queries never
        # reach those pages, so the six-query budget stays empty.
        return [
            f'"{local_market_term}" "{city}" "€"',
            f'"transplant flokësh" "{city}" cmimi',
            f'"mbjellje flokësh" "{city}" "€"',
            f'"FUE" "{city}" "€" clinic',
            f'"{english_market_term}" "{city}" "€"',
            f'site:fresha.com/a/ "{city}" "hair transplant"',
        ]
    elif canonical == "botox":
        terms = ["Botox", "Baby Botox", local_market_term]
    elif canonical == "filler":
        terms = [local_market_term, "lip filler", english_market_term]
    elif canonical == "breast_augmentation":
        # Surgery tariffs are on clinic pages, not salon booking menus.
        italian = "mastoplastica additiva"
        return [
            f'"{italian}" "{city}" "€"',
            f'"{italian}" "{city}" "prezzi"',
            f'"zmadhimi i gjoksit" "{city}" "€"',
            f'"{local_market_term}" "{city}" "€"',
            f'"{english_market_term}" "{city}" "€" clinic',
            f'"{local_market_term}" "{city}" cmimi',
        ]
    else:
        terms = [local_market_term, brands[0] if brands else "", english_market_term]
    queries = []
    for term in terms:
        term = str(term or "").strip()
        if not term:
            continue
        queries.append(f'site:fresha.com/a/ "{city}" "{term}"')
        queries.append(f'site:fresha.com "{city}" "{term}"')
    queries.append(f'"{local_market_term}" "{city}" "€"')
    queries.append(f'site:booksy.com "{city}" "{english_market_term}"')
    return queries


def build_queries(
    city: str,
    procedure: str,
    country_code: str | None = None,
    search_mode: str = "standard",
    interactive_fast: bool = False,
    full_growth: bool = False,
    economical_growth: bool = False,
    app_fast_queries: bool = False,
) -> list[str]:
    canonical = canonicalize_procedure(procedure)
    lang, price_words = search_profile(country_code, city)
    english_aliases = aliases_for(procedure)
    local_terms = local_terms_for(procedure, lang)
    brands = brands_for(procedure)
    clinic_words = local_clinic_words(lang)

    queries: list[str] = []
    standard_brand_limit = int(os.getenv("MAX_BRAND_QUERIES", "6"))
    local_anchor = local_terms[0] if local_terms else (
        "lip filler" if canonical == "filler" else display_name(canonical)
    )
    price_word = price_words[0] if price_words else "price"
    english_market_term = (
        "lip filler" if canonical == "filler" else display_name(canonical)
    )
    local_market_term = local_terms[0] if local_terms else english_market_term
    lead_brand = brands[0] if brands else ""

    if app_fast_queries and search_mode == "expanded" and not full_growth:
        queries = _app_fast_query_list(
            city, canonical, english_market_term, local_market_term, brands,
            country_code or "",
        )
    elif search_mode == "standard":
        # Round 1: broad/high-recall queries.

        # Botox pages are frequently indexed under variant names or booking
        # providers rather than a generic "Botox price" title. Put a compact
        # set of high-yield queries before the interactive query cap.
        if canonical == "botox":
            local_price_anchor = (
                price_words[0] if price_words else "price"
            )
            queries.extend(
                [
                    f'"Baby Botox" "{city}" "€"',
                    f'"Full Botox" "{city}" "€"',
                    f'"Botox" "{city}" "€"',
                    f'"Botox" "{city}" "Lek"',
                    f'"Botox" "{city}" "from €"',
                    f'"Botox" "{city}" "EU"',
                    f'"Botox" "{city}" "{local_price_anchor}"',
                    f'site:hirefrederick.com "{city}" "Botox"',
                ]
            )
        # A cosmetic-surgery quote is more often published on a clinic's own
        # treatment/tariff page than on a salon booking marketplace. Under the
        # economical six-query cap these searches must precede marketplaces.
        if canonical in {"rhinoplasty", "breast_augmentation"}:
            if (country_code or country_hint_for_city(city) or "").upper() == "AL":
                italian_terms = PROCEDURE_LOCAL_TERMS.get(canonical, {}).get("it", [])
                if italian_terms:
                    queries.extend([
                        f'"{italian_terms[0]}" "{city}" "tariffa"',
                        f'"{italian_terms[0]}" "{city}" "€"',
                    ])
            queries.extend([
                f'"{english_market_term}" "{city}" "€" clinic',
                f'"{local_market_term}" "{city}" "€"',
            ])
        # Put profile-oriented marketplace searches first so they cannot be
        # crowded out by long brand expansion later in the query list.
        whatclinic_currency = {
            "AL": "Lek",
            "RO": "RON",
            "GB": "£",
            "US": "$",
            "AE": "AED",
            "TR": "TRY",
        }.get((country_code or "").upper(), price_word)

        queries.extend(
            [
                f'site:whatclinic.com "{city}" "{english_market_term}" "{whatclinic_currency}"',
                f'site:whatclinic.com/cosmetic-plastic-surgery "{city}" "{english_market_term}" "{whatclinic_currency}"',
                f'site:whatclinic.com "{city}" "{english_market_term}"',
                f'site:fresha.com/a/ "{city}" "{english_market_term}"',
                f'site:booksy.com "{city}" "{english_market_term}"',
                f'site:treatwell.com "{city}" "{english_market_term}"',
                f'site:hirefrederick.com "{city}" "{english_market_term}"',
            ]
        )

        for term in english_aliases[:3]:
            queries.append(f'"{term}" "{city}" price')

        for term in local_terms[:3]:
            for local_price in price_words[:2]:
                queries.append(f'"{term}" "{city}" {local_price}')

        for brand in brands[:standard_brand_limit]:
            queries.append(
                f'"{brand}" "{city}" "{local_anchor}" {price_word}'
            )

        for domain in marketplace_search_domains(country_code):
            queries.append(
                f'site:{domain} "{city}" "{english_market_term}"'
            )
            if fold(local_market_term) != fold(english_market_term):
                queries.append(
                    f'site:{domain} "{city}" "{local_market_term}"'
                )
            if lead_brand:
                queries.append(
                    f'site:{domain} "{city}" "{lead_brand}"'
                )

    elif search_mode == "expanded":
        # Round 2: deliberately different query families.

        if canonical in {"rhinoplasty", "breast_augmentation"}:
            if (country_code or country_hint_for_city(city) or "").upper() == "AL":
                italian_terms = PROCEDURE_LOCAL_TERMS.get(canonical, {}).get("it", [])
                if italian_terms:
                    queries.extend([
                        f'"{italian_terms[0]}" "{city}" "prezzi"',
                        f'"{italian_terms[0]}" "{city}" "all inclusive"',
                    ])
                # The local language is essential for hospital articles such
                # as Starmed's; do not spend the whole six-query budget on IT.
                queries.extend([
                    f'"{local_market_term}" "{city}" "euro"',
                    f'"{local_market_term}" "{city}" "kostoja"',
                ])
            queries.extend([
                f'"{english_market_term}" "{city}" "price" hospital',
                f'"{local_market_term}" "{city}" "{price_word}"',
            ])

        # Explicit full-growth gets a small set of intentionally broad,
        # unquoted provider-discovery queries. These are identity/URL
        # discovery only; search snippets never become trusted prices.
        if full_growth:
            rescue_terms = [
                english_market_term,
                local_market_term,
            ]
            for term in rescue_terms:
                term = str(term or "").strip()
                if not term:
                    continue
                queries.extend(
                    [
                        f"{term} {city} {country_code or ''}".strip(),
                        f"{term} {city} price",
                        f"{term} {city} aesthetic treatments",
                    ]
                )

            # Botox is frequently offered by dental / wellness /
            # multispecialty clinics that do not rank for "aesthetic clinic".
            if canonical == "botox":
                queries.extend(
                    [
                        f"botox {city} medical aesthetics",
                        f"botox {city} facial aesthetics",
                        f"botox {city} dental aesthetics",
                        f"botox {city} wellness clinic",
                    ]
                )
        # Target tariffs, treatment menus, provider profiles, and brands that
        # were not consumed by the standard round.
        for term in english_aliases[:3]:
            queries.extend(
                [
                    f'"{term}" "{city}" "price list"',
                    f'"{term}" "{city}" pricing clinic',
                    f'"{term}" "{city}" treatment clinic',
                ]
            )

        for term in local_terms[:3]:
            queries.append(
                f'"{term}" "{city}" "{price_word}" clinic'
            )
            for clinic_word in clinic_words[:2]:
                queries.append(
                    f'"{term}" "{city}" "{clinic_word}"'
                )

        # Put path-oriented searches before the longer brand expansion so
        # tariff/treatment-page discovery cannot be truncated by query caps.
        queries.extend(
            [
                f'"{english_market_term}" "{city}" inurl:prices',
                f'"{english_market_term}" "{city}" inurl:pricing',
                f'"{english_market_term}" "{city}" inurl:price-list',
                f'"{english_market_term}" "{city}" inurl:treatments',
                f'"{english_market_term}" "{city}" inurl:services',
            ]
        )

        expanded_brand_limit = int(
            os.getenv("MAX_EXPANDED_BRAND_QUERIES", "6")
        )
        for brand in brands[
            standard_brand_limit:
            standard_brand_limit + expanded_brand_limit
        ]:
            queries.extend(
                [
                    f'"{brand}" "{city}" price',
                    f'"{brand}" "{city}" clinic',
                ]
            )

        queries.extend(
            [
                f'site:fresha.com/a/ "{city}" "{english_market_term}"',
                f'site:booksy.com "{city}" "{english_market_term}" price',
                f'site:whatclinic.com "{city}" "{english_market_term}" clinic',
                f'site:treatwell.com "{city}" "{english_market_term}" price',
                f'site:hirefrederick.com "{city}" "{english_market_term}"',
            ]
        )

    elif search_mode == "rescue":
        # An extra round only when the earlier rounds did not produce enough
        # distinct clinics. Query clinic-owned prices in several languages on
        # page one; a page-two search often repeats providers without prices.
        italian_terms = PROCEDURE_LOCAL_TERMS.get(canonical, {}).get("it", [])
        rescue_terms = [local_market_term, english_market_term, *italian_terms[:1]]
        # Reach booking providers not covered by the initial tariff searches.
        if canonical in {"rhinoplasty", "breast_augmentation"}:
            queries.extend([
                f'{local_market_term} {city} {price_word}',
                f'{english_market_term} {city} plastic surgeon price list',
                f'"{local_market_term}" "{city}" inurl:arak',
                f'"{english_market_term}" "{city}" inurl:prices',
            ])
        else:
            queries.extend([
                f'"{local_market_term}" "{city}" "{price_word}" clinic',
                f'"{english_market_term}" "{city}" "price list" hospital',
                f'site:booksy.com "{city}" "{english_market_term}"',
                f'site:treatwell.com "{city}" "{english_market_term}"',
            ])
        for term in dict.fromkeys(rescue_terms):
            queries.append(f'"{term}" "{city}" "€" clinic')
        for term in dict.fromkeys(rescue_terms):
            queries.append(f'"{term}" "{city}" "{price_word}" hospital')
        if (country_code or country_hint_for_city(city) or "").upper() == "AL":
            queries.extend([
                f'"{local_market_term}" "{city}" "cmimi" klinika',
                f'"{local_market_term}" "{city}" "kostoja" spitali',
                f'"{english_market_term}" "{city}" "starts from" clinic',
            ])

    elif search_mode == "site_focus":
        # Search only verified clinic domains below, after reading the city
        # directory; broad searches consumed the previous rescue round.
        pass

    else:
        # Round 3: deeper search page + clinic vocabulary + product-line names.
        # discover() requests Serper page=2 for this mode.
        for clinic_word in clinic_words[:3]:
            queries.extend(
                [
                    f'"{clinic_word}" "{city}" "{english_market_term}"',
                    f'"{clinic_word}" "{city}" "{price_word}"',
                ]
            )

        for term in english_aliases[:3]:
            queries.extend(
                [
                    f'"{city}" "{term}" "book online"',
                    f'"{city}" "{term}" menu',
                    f'"{city}" "{term}" tariff',
                ]
            )

        for term in local_terms[:2]:
            queries.extend(
                [
                    f'"{city}" "{term}" "{clinic_words[0]}"',
                    f'"{city}" "{term}" "{price_word}"',
                ]
            )

        if canonical == "filler":
            product_lines = []
            for brand, lines in FILLER_PRODUCT_LINES.items():
                for line in lines[:2]:
                    product_lines.append((brand, line))

            for brand, line in product_lines[:12]:
                queries.append(
                    f'"{brand}" "{line}" "{city}" price'
                )

        # Deeper marketplace/provider queries.
        queries.extend(
            [
                f'site:fresha.com/a/ "{city}" "{english_market_term}" price',
                f'site:booksy.com "{city}" "{english_market_term}"',
                f'site:whatclinic.com "{city}" "{english_market_term}"',
                f'site:hirefrederick.com "{city}" "{english_market_term}"',
                f'"{city}" "{english_market_term}" "official website"',
            ]
        )

    # Local synonyms must survive the six-query cap in full-growth too.
    if canonical in {"rhinoplasty", "breast_augmentation"} and search_mode in {
        "standard", "expanded", "rescue",
    }:
        localized = localized_surgery_queries(
            city, canonical, country_code or "", rescue=search_mode == "rescue",
        )
        if (country_code or country_hint_for_city(city) or "").upper() == "AL":
            italian = local_terms_for(canonical, "it")
            if italian:
                localized[2] = f'{italian[0]} "{city}" prezzi'
        queries = localized + queries

    # Bounded live searches must ask for a tariff before spending their cap
    # on generic provider listings. Keep local surgery synonyms first where
    # those are the language of the published tariff.
    if economical_growth and full_growth and search_mode in {"expanded", "rescue"}:
        cc = (country_code or country_hint_for_city(city) or "").upper()
        if canonical not in {"rhinoplasty", "breast_augmentation"} or cc == "AE":
            currency = {"AE": "AED", "HU": "Ft", "RO": "lei", "MD": "MDL",
                        "BG": "лв", "GB": "GBP", "US": "USD", "TR": "TL",
                        "PL": "zł", "CZ": "Kč"}.get(cc, "EUR" if cc else "")
            if search_mode == "expanded":
                tariff_queries = [
                    f'{english_market_term} {city} price',
                    f'"{english_market_term}" "{city}" cost',
                    f'"{local_market_term}" "{city}" {price_word}',
                    f'"{english_market_term}" "{city}" "price list"',
                ]
                if currency:
                    tariff_queries.insert(1, f'"{english_market_term}" "{city}" "{currency}"')
            else:
                tariff_queries = [
                    f'"{english_market_term}" "{city}" "prices start"',
                    f'"{english_market_term}" "{city}" "starting price"',
                    f'"{local_market_term}" "{city}" {price_words[-1] if price_words else "prices"} clinic',
                    f'"{english_market_term}" "{city}" "pricing"',
                ]
            queries = tariff_queries + queries

    if canonical == "chemical_peel" and full_growth and economical_growth:
        # These are treatment names in real menus, including menus that never
        # use the generic phrase "chemical peel". Give them bounded slots.
        if search_mode == "expanded":
            queries.insert(2, f'"BioRePeel" "{city}" price')
            if (country_code or country_hint_for_city(city) or "").upper() == "US":
                queries.insert(3, f'"VI Peel" "{city}" price')
        elif search_mode == "rescue":
            queries.insert(0, f'"PCA Peel" "{city}" pricing')
            queries.insert(1, f'"VI Peel" "{city}" cost')

    if (canonical == "hair_transplant" and full_growth and economical_growth
            and (country_code or country_hint_for_city(city) or "").upper() == "AL"):
        if search_mode == "expanded":
            queries = [f'trapianto di capelli "{city}" prezzi',
                       f'mbjellja e flokeve "{city}" cmimi'] + queries
        elif search_mode == "rescue":
            queries = [f'trapianto di capelli "{city}" costo clinica',
                       f'transplanti i flokeve "{city}" cmimet'] + queries

    if economical_growth and full_growth and search_mode in {"expanded", "rescue"}:
        # Reserve two of the existing six requests for an independent source
        # lane. The gather below runs these alongside official-site queries.
        platform_queries = [
            f'site:whatclinic.com {english_market_term} {city} price',
            f'site:bookimed.com {english_market_term} {city} price',
        ]
        if canonical == "chemical_peel" and search_mode == "expanded":
            queries.insert(2, f'peel {city} price')
            if (country_code or country_hint_for_city(city) or "").upper() == "US":
                queries = [f'chemical peel {city} price', f'peel {city} price',
                           f'BioRePeel {city} price', f'VI Peel {city} price'] + queries
        queries = queries[:4] + platform_queries + queries[4:]

    # Local-language tariffs must survive the bounded search budget. Keep
    # different synonyms in rescue, rather than repeating English phrases.
    # This depends on country/language, never a whitelist of seeded cities.
    if (lang != "en" and local_terms and economical_growth
            and canonical not in {"rhinoplasty", "breast_augmentation"}
            and (country_code or country_hint_for_city(city) or "").upper() != "AE"
            and search_mode in {"standard", "expanded", "rescue"}):
        variants = list(dict.fromkeys(local_terms))
        if search_mode == "rescue" and len(variants) > 1:
            variants = variants[1:] + variants[:1]
        price_alt = price_words[-1] if price_words else "prices"
        local_queries = [
            f'{variants[0]} {city} {price_word}',
            f'{variants[min(1, len(variants)-1)]} {city} {price_alt}',
            f'{variants[-1]} {city} {price_alt} {clinic_words[0]}',
        ]
        broad = f'{"peel" if canonical == "chemical_peel" else english_market_term} {city} price'
        platform_queries = [f'site:whatclinic.com {english_market_term} {city} price',
                            f'site:bookimed.com {english_market_term} {city} price']
        if search_mode == "rescue":
            local_queries = [f'"{term}" "{city}" {price_alt} clinic'
                             for term in variants[:3]]
            broad = f'"{english_market_term}" "{city}" "starting price"'
            platform_queries = [f'site:whatclinic.com "{local_market_term}" "{city}"',
                                f'site:bookimed.com "{local_market_term}" "{city}"']
        # Retain a broad query and independent marketplace leads, without
        # letting branded US peel names displace local-language tariffs.
        queries = [broad, *local_queries, *platform_queries, *queries]

    seen = set()
    deduped = []

    for q in queries:
        key = fold(q)
        if key not in seen:
            seen.add(key)
            deduped.append(q)

    if economical_growth:
        if search_mode == "standard":
            max_queries = int(
                os.getenv(
                    "MAX_ECONOMICAL_STANDARD_SERP_QUERIES",
                    "6",
                )
            )
        elif search_mode == "expanded":
            max_queries = int(
                os.getenv(
                    "MAX_ECONOMICAL_EXPANDED_SERP_QUERIES",
                    "6",
                )
            )
        elif search_mode == "rescue":
            max_queries = int(os.getenv("MAX_ADAPTIVE_RESCUE_BROAD_QUERIES", "4"))
        elif search_mode == "site_focus":
            max_queries = 0
        else:
            max_queries = int(
                os.getenv(
                    "MAX_ECONOMICAL_DEEP_SERP_QUERIES",
                    "4",
                )
            )
    elif search_mode == "standard":
        max_queries = int(
            os.getenv(
                "MAX_HYBRID_SEARCH_QUERIES"
                if interactive_fast
                else "MAX_SEARCH_QUERIES",
                "16" if interactive_fast else "28",
            )
        )
    elif search_mode == "expanded":
        max_queries = int(
            os.getenv("MAX_EXPANDED_SEARCH_QUERIES", "34")
        )
    else:
        max_queries = int(
            os.getenv("MAX_DEEP_SEARCH_QUERIES", "28")
        )

    return deduped[:max_queries]


# ============================================================
# Source classification
# ============================================================

MARKETPLACES = {
    "bookimed.com",
    "fresha.com",
    "whatclinic.com",
    "booksy.com",
    "treatwell.com",
    "hirefrederick.com",
    "wupdoc.com",
}
DIRECTORIES = {
    # Editorial publishers are not the treating provider, even if an article
    # quotes a real surgeon's fee and mentions the requested city.
    "elle.com", "vogue.com", "vogue.es", "hola.com", "telva.com",
    "cosmopolitan.com", "harpersbazaar.com", "nytimes.com", "theguardian.com",
    "clinicpoint.com", "doctoralia.es", "multiestetica.com", "gorgeousgetaways.com",
    # Explicitly disclaims being a medical practice; sells reservation vouchers.
    "bonomedico.es",
    "beautyforqueens.com", "cliniciestetice.ro", "clinici-estetice.ro",
    "qunomedical.com", "estheticon.com", "realself.com",
    "beautynailhairsalons.com",
    "albest.al",
    "gjithebiznesi.com",
    "gjejbiznese.com",
    "cybo.com",
    "wanderlog.com",
    "duaoferta.com",
    "dentavacation.com",
    "easybook.ai",
    "rumio.al",
    "doctoranytime.gr",
    "dentaldepartures.com",
    "wupdoc.com",
    "123.clinic",
    # This site explicitly describes itself as a partner of several clinics;
    # a service price on it cannot be assigned to a particular hospital.
    "albaniadoctor.net",
    # The site states it is a medical tourism agency and arranges cosmetic
    # surgery through a network of clinicians; its package is not a clinic fee.
    "albmedtour.it",
    "qanomed.com",
    "clinicbooking.com", "clinichunter.com", "placidway.com", "flymedi.com", "flyhospital.com",
    "medigence.com", "allhospital.info",
    "medgo.hu", "plasztikai-sebesz-budapest.hu", "sebeszem.hu",
    # Doctor-booking directories. A city service page lists many clinics;
    # it is not itself a clinic tariff.
    "miodottore.it", "dottori.it", "doctoralia.it", "doctoralia.com",
    "doctolib.it", "doctolib.fr", "docplanner.com",
    "injectablesbooking.it",
}
SOCIAL = {"instagram.com", "facebook.com", "tiktok.com"}


def is_marketplace_host(host: str) -> bool:
    h = (host or "").lower().removeprefix("www.")
    if any(h == x or h.endswith("." + x) for x in MARKETPLACES):
        return True
    # Treatwell uses country TLDs (treatwell.co.uk, treatwell.de, ...).
    return h == "treatwell.com" or h.startswith("treatwell.") or ".treatwell." in h


def host_of(url: str) -> str:
    try:
        raw = urlparse(url or "").hostname or ""
    except Exception:
        return ""
    host = raw.lower().removeprefix("www.").strip(".")
    # Percent-encoded widget ids (ht-ctc-chat%20number=…) are not DNS names.
    # Skip them instead of letting IDNA/httpx fail the NDJSON stream.
    if not host or any(ch in host for ch in " %/?#@="):
        return ""
    if not re.fullmatch(r"[a-z0-9.-]+", host) or "." not in host:
        return ""
    return host


def safe_http_urljoin(base_url: str, href: str) -> str:
    """An invalid widget href must not abort the discovery stream."""
    try:
        absolute = urljoin(base_url, str(href or "").strip()).split("#")[0]
        parsed = urlparse(absolute)
        if parsed.scheme not in {"http", "https"} or not host_of(absolute):
            return ""
        if parsed.username or parsed.password:
            return ""
        _ = parsed.port
        return absolute
    except (ValueError, TypeError, UnicodeError):
        return ""


def classify_source(url: str) -> str:
    h = host_of(url)
    if re.search(r"/(?:demo|template|example)[-/]", urlparse(url).path, re.I):
        return "directory"
    if "wupdoc.com" in h and not re.fullmatch(
        r"/albania/[a-z0-9-]+-d-[a-z0-9]+/?",
        (urlparse(url).path or "").lower(),
    ):
        return "directory"
    if is_marketplace_host(h):
        return "marketplace"
    if (any(h == x or h.endswith("." + x) for x in DIRECTORIES)
            or re.search(r"(?:^|\.)injectablesbooking\.[a-z.]+$", h)):
        return "directory"
    if any(h == x or h.endswith("." + x) for x in SOCIAL):
        return "social"
    return "official_clinic" if h else "unknown"


def facilitator_profile_page_context(
    url: str,
    text: str,
) -> bool:
    """Recognise a provider profile hosted by a medical-travel platform.

    The host list can never be complete.  A provider-specific path plus
    several platform/facilitator signals is enough to treat the page like a
    marketplace profile, but never like the provider's own tariff.
    """
    path = fold(urlparse(url or "").path)
    body = fold(text or "")[:30000]
    provider_path = bool(re.search(
        r"/(?:clinic|clinics|hospital|hospitals|doctor|doctors)/[^/]{2,}/?$",
        path,
    ))
    signals = (
        "medical tourism", "medical travel", "free quote", "get a quote",
        "best price guarantee", "partner clinic", "partner clinics",
        "travel coordination", "airport transfer", "compare clinics",
        "verified clinic", "verified hospital",
    )
    return provider_path and sum(token in body for token in signals) >= 2


def directory_like_page_context(
    url: str,
    text: str,
) -> bool:
    """Detect directory/listing pages on previously unknown domains."""
    path = fold(urlparse(url or "").path)
    body = fold(text or "")
    if "no es un consultorio medico" in body and re.search(
            r"(?:reserv\w*.*no se esta contratando la operacion|pago.*(?:direct\w*|cirujano))", body):
        return True
    if ("independent editorial resource" in body
            and "not affiliated with any clinic" in body):
        return True
    if "indicative price" in body and "find a clinic" in body and "treatment guide" in body:
        return True
    strong_pairs = (
        ("add listing", "select your plan"),
        ("add your listing", "user registration"),
        ("find the best surgeon", "book appointment"),
        ("compare clinics", "request a quote"),
        ("claimed listing", "save share"),
    )
    if any(first in body and second in body for first, second in strong_pairs):
        return True
    listing_path = bool(re.search(
        r"/(?:country|countries|city|cities|list|listing|providers?)/",
        path,
    ))
    market_copy = bool(re.search(
        r"\b(?:average|typical|claimed)\s+(?:price|cost)|"
        r"(?:price|cost)\s+in\s+[a-z]{3,30}\s+is\s+between\b",
        body,
    ))
    platform_controls = sum(token in body for token in (
        "add listing", "sign up", "select your plan", "user registration",
        "all providers", "browse clinics", "compare providers",
    ))
    return listing_path and (market_copy or platform_controls >= 2)


def classify_page_source(url: str, text: str = "") -> str:
    """Classify the fetched page, not just its hostname.

    Known hosts remain authoritative.  Unknown platforms are recognised from
    their page role so a directory cannot become an ``official_clinic`` merely
    because its domain has not yet been added to a static list.
    """
    static = classify_source(url)
    if static != "official_clinic":
        return static
    if facilitator_profile_page_context(url, text):
        return "marketplace"
    if directory_like_page_context(url, text):
        return "directory"
    return static


def news_report_url(url: str) -> bool:
    """A news or investigation URL is not a clinic tariff."""
    path = fold(urlparse(url or "").path)
    return bool(re.search(
        r"/(?:unpublished|artikull|article|articles|lajme|news|opinion)(?:/|$)",
        path,
    ))


def country_price_guide_path(url: str) -> bool:
    """A country cost guide is not a clinic's own tariff.

    ``med-spa-prices-list-costs-in-usa`` contains the word "prices", so it
    must not take the price-menu exemption.
    """
    path = fold(urlparse(url or "").path).replace("_", "-")
    if re.search(r"(?:cuanto-cuesta|precio).{0,65}(?:espana|espanya)(?:/|$)", path):
        return True
    return bool(re.search(
        r"(?:cost|price)s?.{0,48}"
        r"(?:usa|uk|canada|australia|united-states|united-kingdom)\b",
        path,
    ))


def cross_country_price_comparison(text: str) -> bool:
    body = fold(text or "")
    if not re.search(r"(?:price|cost)[\s\w]{0,32}comparison\s+table|"
                     r"\bcountry\s+(?:minimum|min)\s+price", body):
        return False
    destinations = {code for code, names in COUNTRY_CODE_DISPLAY_NAMES.items()
                    if any(re.search(r"(?<!\w)" + re.escape(fold(name)) + r"(?!\w)", body)
                           for name in names)}
    return len(destinations) >= 2


def comparative_market_article_context(
    url: str,
    text: str,
) -> bool:
    """Return true for country/city comparison copy, not a local tariff."""
    path = fold(urlparse(url or "").path)
    if page_disclaims_clinic_prices(text):
        return True
    # Cached fragments can omit the page's ownership disclaimer. A titled
    # editorial cost guide must be fetched again, not trusted as a tariff.
    if (re.search(r"(?:^|[-/])(?:guia|guide)(?:[-/]|$)", path)
            and re.search(r"(?:precio|price|cost)", path)
            and not re.fullmatch(r"/(?:price|pricing|precio|precios)[-_](?:guide|guia)/?", path)):
        return True
    # Check this before the price-menu exemption. A slug that both says
    # "prices" and names another country is a market guide.
    if country_price_guide_path(url):
        return True
    # A /...-price/ slug does not turn a country comparison into a local menu.
    if cross_country_price_comparison(text):
        return True
    body = fold(text or "")[:12000]
    if re.search(r"\b(?:precio orientativo (?:en|de)|precios orientativos|rangos orientativos|"
                 r"rinoplastia en espana puede estar|precio de rinoplastia en espana|"
                 r"en clinicas low cost|en clinicas especializadas de calidad)\b", body):
        return True
    # A published tariff can include a "how much does it cost" FAQ and still
    # be the clinic's own menu.
    if is_price_menu_path(url):
        return False
    body = fold(text or "")[:12000]
    question = bool(re.search(
        r"\b(?:how much|what does|cat costa|cât costă|quanto costa|"
        r"combien coute|costul|cost of|price of)\b",
        body,
    ))
    comparison = bool(re.search(
        r"\b(?:average|typical|compared|comparison|versus|vs|"
        r"prices? in|costs? in|costul .* in|costul .* în)\b",
        body,
    ))
    foreign_path = bool(re.search(
        r"(?:cost|price|pret|prezzo).*(?:uk|usa|canada|australia|"
        r"france|franta|italy|turkey|romania|albania)",
        path,
    ))
    # "Dermal fillers cost in the UK" is a market article, not a local tariff.
    foreign_market = bool(re.search(
        r"\b(?:costs?|prices?)\s+in\s+(?:the\s+)?"
        r"(?:uk|u\.k\.|usa|u\.s\.|united kingdom|united states|"
        r"italy|turkey|romania|france|germany)\b",
        body,
    ))
    # A country guide ("costs 50% less than Italy", "prices range from")
    # is not the clinic's own tariff line.
    market_range = bool(re.search(
        r"\b(?:in meno rispetto|rispetto all|costa in media|"
        r"prices range from|prezzi variano|indicatively from|"
        r"varioje nga|mund te varioje|"
        r"sa kushton|kushton rreth|costa circa|costa intorno|"
        r"costs around|mesatarisht|"
        # "Results may vary" and "on average after 4 months" are a clinic
        # disclaimer and a duration, not a national price survey.
        # "The cost can vary depending on the number of areas" is the
        # clinic's own dosing caveat.
        r"(?:price|cost)s?\s+(?:can|may)\s+vary"
        r"(?!\s*,?\s*(?:especially\s+)?depending\s+on)|"
        r"on average(?!\s+(?:after|within|in)\b))\b",
        body,
    )) and not bool(re.search(
        r"\b(?:noi offriamo|our prices|cmimet tona|price list)\b",
        body,
    ))
    geography = {
        word
        for words in COUNTRY_CODE_DISPLAY_NAMES.values()
        for word in words
        if len(word) >= 4 and word in body
    }
    geography.update(
        word for word in ("london", "lyon", "paris", "istanbul", "bucharest", "tirana")
        if word in body
    )
    return foreign_path or foreign_market or market_range or (
        (question or comparison) and len(geography) >= 2
    )


FOREIGN_PRICE_PATH_COUNTRIES = {
    "AL": ("turkey", "turkiye", "turchia", "turkei", "istanbul", "kosovo", "italy", "italia"),
    "RO": ("turkey", "turkiye", "turchia", "turkei", "istanbul", "albania", "tirana"),
    "BG": ("turkey", "turkiye", "turchia", "turkei", "istanbul", "albania", "tirana"),
}

# Same peer cities as Flutter _kExplorePeerCityMarks, plus the aliases
# already used for city slugs (Milan/Milano, New York, Istanbul, Sofia).
# A path token from another row is a different city. A footer that names
# that city does not make this path local, and a Places rating does not either.
PEER_CITY_MARKS = (
    ("dubai", ("dubai",)),
    ("al ain", ("al ain", "al-ain", "alain")),
    ("abu dhabi", ("abu dhabi", "abudhabi", "abu-dhabi")),
    ("sharjah", ("sharjah",)),
    ("riyadh", ("riyadh",)),
    ("jeddah", ("jeddah",)),
    ("doha", ("doha",)),
    ("kuwait", ("kuwait",)),
    ("london", ("london",)),
    ("manchester", ("manchester",)),
    ("birmingham", ("birmingham",)),
    ("leeds", ("leeds",)),
    ("glasgow", ("glasgow",)),
    ("edinburgh", ("edinburgh",)),
    ("liverpool", ("liverpool",)),
    ("bristol", ("bristol",)),
    ("newcastle", ("newcastle", "newcastle upon tyne")),
    ("nottingham", ("nottingham",)),
    ("derby", ("derby",)),
    ("sheffield", ("sheffield",)),
    ("cardiff", ("cardiff",)),
    ("belfast", ("belfast",)),
    ("brighton", ("brighton",)),
    ("leicester", ("leicester",)),
    ("southampton", ("southampton",)),
    ("timisoara", ("timisoara",)),
    ("chisinau", ("chisinau", "kishinev")),
    ("bucharest", ("bucharest", "bucuresti")),
    ("iasi", ("iasi",)),
    ("brasov", ("brasov",)),
    ("bacau", ("bacau",)),
    ("cluj", ("cluj", "cluj-napoca", "cluj napoca")),
    ("constanta", ("constanta",)),
    ("sibiu", ("sibiu",)),
    ("oradea", ("oradea",)),
    ("galati", ("galati",)),
    ("ploiesti", ("ploiesti",)),
    ("craiova", ("craiova",)),
    ("budapest", ("budapest", "budapesta")),
    ("tirane", ("tirane", "tirana")),
    ("durres", ("durres",)),
    ("vlore", ("vlore", "vlora")),
    ("shkoder", ("shkoder", "shkodra")),
    ("milan", ("milan", "milano")),
    ("rome", ("rome", "roma")),
    ("istanbul", ("istanbul",)),
    ("sofia", ("sofia",)),
    ("paris", ("paris",)),
    ("lyon", ("lyon",)),
    ("new york", ("new york", "new-york", "nyc")),
)

# A commune in the searched city's metro is still that city. Dumbrăvița is
# Timișoara; a Bacău or Iași street is not.
CITY_METRO_AREAS = {
    "timisoara": ("dumbravita", "ghiroda", "giroc", "mosnita"),
}


def _city_slug_forms(alias: str) -> set[str]:
    """Packed and dashed forms of one city label. Short fragments are ignored."""
    folded = fold(alias or "")
    if not folded:
        return set()
    packed = re.sub(r"[^a-z0-9]+", "", folded)
    dashed = re.sub(r"[^a-z0-9]+", "-", folded).strip("-")
    forms = set()
    for form in (packed, dashed):
        if len(re.sub(r"[^a-z0-9]", "", form)) >= 4:
            forms.add(form)
    return forms


def _url_slug_forms(url: str) -> set[str]:
    """City-shaped tokens in the path and query, including abu-dhabi."""
    parsed = urlparse(url or "")
    blob = f"{parsed.path} {parsed.query}".replace("_", "-")
    folded = fold(blob)
    parts = [part for part in re.split(r"[^a-z0-9]+", folded) if part]
    forms = {part for part in parts if len(part) >= 4}
    for left, right in zip(parts, parts[1:]):
        if len(left) + len(right) < 4:
            continue
        forms.add(f"{left}-{right}")
        forms.add(f"{left}{right}")
    return forms


def _search_city_slug_forms(city: str) -> set[str]:
    forms: set[str] = set()
    for alias in (*aliases_for_city(city), canonical_city(city), city or ""):
        forms |= _city_slug_forms(alias)
    for _key, aliases in PEER_CITY_MARKS:
        peer_forms: set[str] = set()
        for alias in aliases:
            peer_forms |= _city_slug_forms(alias)
        if peer_forms & forms:
            forms |= peer_forms
    return forms


def _city_path_tokens(city: str) -> set[str]:
    tokens: set[str] = set()
    for form in _search_city_slug_forms(city):
        tokens.update(part for part in re.split(r"[^a-z0-9]+", form) if part)
    return tokens


def foreign_price_source_path(url: str, city: str) -> bool:
    """A path or slug that names a different city is not this city's price.

    Only the URL path and query are inspected. A footer that says the chain
    also has a clinic elsewhere does not locate the tariff, and a Places
    rating in the searched city does not make /prices/{other-city}/ local.
    """
    parsed = urlparse(url or "")
    path = fold(parsed.path).replace("_", "-")
    if not path and not parsed.query:
        return False
    tokens = set(re.split(r"[^a-z0-9]+", path))
    country = (country_hint_for_city(city) or "").upper()
    foreign = FOREIGN_PRICE_PATH_COUNTRIES.get(country, ())
    if any(token in tokens for token in foreign):
        return True
    forms = _url_slug_forms(url)
    if not forms:
        return False
    search_forms = _search_city_slug_forms(city)
    # A shared tariff explicitly scoped to both cities is local to either.
    # Query parameters and the hostname cannot rescue a foreign-only path.
    path_forms = _url_slug_forms(parsed._replace(query="", fragment="").geturl())
    if search_forms & path_forms:
        return False
    for _key, aliases in PEER_CITY_MARKS:
        peer_forms: set[str] = set()
        for alias in aliases:
            peer_forms |= _city_slug_forms(alias)
        if not peer_forms or peer_forms & search_forms:
            continue
        if peer_forms & forms:
            return True
    return False


# Menu stems by search language. English "prices" is always tried as well,
# after the local stem, because many clinics publish a bilingual tariff.
PRICE_MENU_STEMS = {
    "en": ("prices", "tariffs", "fees"),
    "ro": ("preturi", "tarife"),
    "it": ("prezzi", "listino", "tariffe"),
    "fr": ("tarifs", "prix"),
    "de": ("preise", "preisliste"),
    "es": ("precios", "tarifas"),
    "pt": ("precos",),
    "hu": ("arak", "arlista"),
    "pl": ("cennik",),
    "sq": ("cmimet",),
    "tr": ("fiyatlar",),
    "ar": ("prices",),
    "nl": ("prijzen", "tarieven"),
    "cs": ("cenik",),
    "hr": ("cjenik",),
    "sr": ("cenovnik",),
}

PROCEDURE_MENU_STEMS = {
    "filler": {
        "ro": ("injectare-acid-hialuronic", "fillere", "acid-hialuronic"),
        "en": ("dermal-filler", "lip-filler", "hyaluronic-acid"),
        "it": ("filler-labbra", "acido-ialuronico"),
        "fr": ("acide-hyaluronique",),
        "de": ("lippenunterspritzung",),
        "es": ("relleno-dermico",),
        "hu": ("ajakfeltoltes",),
    },
    "botox": {
        "ro": ("injectare-toxina-botulinica",),
        "en": ("botox", "anti-wrinkle"),
        "it": ("botox",),
        "fr": ("botox",),
        "de": ("botox",),
    },
    "chemical_peel": {
        "ro": ("peeling-chimic",),
        "en": ("chemical-peel", "chemical-peels"),
        "fr": ("peeling-chimique",),
        "it": ("peeling-chimico",),
        "de": ("chemisches-peeling",),
        "es": ("peeling-quimico",),
    },
    "rhinoplasty": {
        "en": ("rhinoplasty",),
        "it": ("rinoplastica",),
        "ro": ("rinoplastie",),
        "fr": ("rhinoplastie",),
        "de": ("nasenkorrektur",),
    },
    "breast_augmentation": {
        "en": ("breast-augmentation",),
        "it": ("mastoplastica-additiva",),
        "ro": ("augmentare-mamara",),
        "fr": ("augmentation-mammaire",),
        "de": ("brustvergroesserung",),
    },
    "hair_transplant": {
        "en": ("hair-transplant",),
        "it": ("trapianto-capelli",),
        "tr": ("sac-ekimi",),
        "ro": ("transplant-de-par",),
    },
}


def known_host_tariff_urls(
    hosts: list[str],
    city: str,
    procedure: str = "",
    country_code: str = "",
) -> list[str]:
    """Bounded seeds; real navigation supplies city/procedure-specific paths."""
    language = search_profile(country_code, city)[0]
    stems = list(PRICE_MENU_STEMS.get(language, ())) or ["prices"]
    cleaned: list[str] = []
    for raw in hosts:
        host = (raw or "").lower().removeprefix("www.").strip()
        if not re.fullmatch(r"[a-z0-9.-]+", host) or "." not in host:
            continue
        if host not in cleaned:
            cleaned.append(host)
    cleaned = cleaned[:12]
    roots = [f"https://{host}/" for host in cleaned]
    rest = [f"https://{host}/{stems[0]}/" for host in cleaned]
    return [url for url in roots + rest if not foreign_price_source_path(url, city)]


def priority_site_queries(hosts: list[str], city: str, procedure: str) -> list[str]:
    """site:host queries for clinics already priced on another procedure."""
    proc = canonicalize_procedure(procedure)
    slug = fold(canonical_city(city)).replace(" ", "-")
    if proc == "filler":
        term = (
            'acid hialuronic OR fillere OR "injectare acid hialuronic" '
            "OR preturi OR tarife"
        )
    else:
        term = display_name(proc)
    queries: list[str] = []
    for raw in hosts:
        host = (raw or "").lower().removeprefix("www.").strip()
        if not re.fullmatch(r"[a-z0-9.-]+", host) or "." not in host:
            continue
        queries.append(f"site:{host} {term} {slug}".strip())
    return queries


# ============================================================
# Retail/product rejection
# ============================================================

RETAIL_URL_TOKENS = [
    "/product-page/", "/product/", "/products/", "/shop/",
    "/collections/", "/cart", "/category/skincare", "/store/",
]

RETAIL_TEXT_TERMS = [
    "raktaron", "kosarba", "webshop",  # Hungarian product stock/cart copy.
    "add to cart", "buy now", "shopping cart", "buy online",
    "night cream", "day cream", "face cream", "eye cream",
    "serum", "tonic lotion", "toner", "cleanser", "moisturizer",
    "moisturiser", "shampoo", "conditioner", "body lotion",
    "skin care", "skincare", "cosmetic product",
    "wholesale", "supplier", "distributor", "box of", "pack of",
    "training course", "masterclass", "academy",
]

INJECTABLE_FILLER_POSITIVE = [
    "aumento de labios", "aumento labial", "relleno de labios", "relleno dermico",
    "relleno de hialuronico", "rellenos con acido hialuronico",
    "relleno con acido hialuronico", "relleno facial", "rellenos faciales",
    "acido hialuronico labios", "acido ialuronico labbra",
    "injection acide hyaluronique", "comblement levres", "filler levres",
    "preenchimento labial", "preenchimento dermico", "dudak dolgusu",
    "ajakfeltoltes", "hialuronsavas feltoltes", "lippenunterspritzung",
    "dermalen filar", "филър за устни", "дермален филър",
    "lip filler", "dermal filler", "filler injection", "injectable filler",
    "chin filler", "jawline filler", "nasolabial filler", "tear trough filler",
    "under eye filler", "under-eye filler", "rhinofiller", "nose filler",
    "cheek filler", "temple filler", "hyaluronic filler",
    "lip augmentation", "filler 1 ml", "filler 0.5 ml", "filler 2 ml",
    "per syringe", "syringe",
    "acid hialuronic", "acid hyaluronic", "fillere",
    "injectare acid hialuronic", "injectare acid hyaluronic",
    # Use the same explicit service aliases that drive local discovery.
    *(fold(term) for terms in PROCEDURE_LOCAL_TERMS.get('filler', {}).values() for term in terms),
]

FILLER_TREATMENT_CONTEXT = [
    "lip", "lips", "cheek", "chin", "jawline", "nasolabial",
    "tear trough", "under eye", "under-eye", "nose", "rhinofiller",
    "temple", "facial", "face", "injection", "injectable", "treatment",
    "appointment", "book", "clinic", "aesthetic", "1 ml", "0.5 ml",
    "2 ml", "syringe",
]


def brand_treatment_match(text: str) -> bool:
    t = fold(text)
    brand = detect_product_brand(t, "filler")
    if not brand:
        return False
    if any(term in t for term in RETAIL_TEXT_TERMS):
        return False
    return any(term in t for term in FILLER_TREATMENT_CONTEXT)


def is_hard_retail_url(url: str, procedure: str) -> bool:
    """
    Reject the whole page only for explicit shop/product URL structures.
    Mixed clinic price lists are allowed through and filtered block-by-block.
    """
    if canonicalize_procedure(procedure) != "filler":
        return False

    u = url.lower()
    return any(tok in u for tok in RETAIL_URL_TOKENS)


def is_retail_evidence_block(text: str, procedure: str) -> bool:
    if canonicalize_procedure(procedure) != "filler":
        return False
    if injectable_scope_rejection("filler", evidence=text):
        return True

    t = fold(text)

    hard_negative = any(
        term in t
        for term in [
            "add to cart", "buy now", "buy online", "shopping cart",
            "wholesale", "supplier", "distributor",
            "training course", "masterclass", "academy",
        ]
    )
    if hard_negative:
        return True

    retailish = any(term in t for term in RETAIL_TEXT_TERMS)
    if retailish and not (
        any(term in t for term in INJECTABLE_FILLER_POSITIVE)
        or brand_treatment_match(t)
    ):
        return True

    return False


def is_retail_product_page(url: str, text: str, procedure: str) -> bool:
    """
    Compatibility helper. Whole-page rejection is URL-driven; short snippets
    may still be classified as retail evidence.
    """
    if is_hard_retail_url(url, procedure):
        return True

    if len(text or "") <= 1400:
        return is_retail_evidence_block(text, procedure)

    return False


def injectable_filler_match(text: str) -> bool:
    if injectable_scope_rejection("filler", evidence=text):
        return False
    t = fold(text)
    if any(term in t for term in INJECTABLE_FILLER_POSITIVE):
        return True
    if re.search(r"\brellenos?\b.{0,30}\b(?:menton|barbilla|pomulos|mejillas|mandibula|ojeras)\b", t):
        return True
    # Romanian menus abbreviate acid hialuronic as AH. Do not match that
    # inside a longer word.
    if re.search(r"\bah\b", t):
        return True

    # Brand-only clinic menus are common:
    # "Juvederm Volift 1 ml — €180".
    return brand_treatment_match(t)


# ============================================================
# Serper
# ============================================================

_SERPER_SHARED_LOCK = asyncio.Lock()
_SERPER_SHARED_LAST_STARTED = 0.0


async def _wait_for_shared_serper_slot(min_interval: float):
    global _SERPER_SHARED_LAST_STARTED
    async with _SERPER_SHARED_LOCK:
        loop = asyncio.get_running_loop()
        now = loop.time()
        wait = min_interval - (now - _SERPER_SHARED_LAST_STARTED)
        if wait > 0:
            await asyncio.sleep(wait)
        _SERPER_SHARED_LAST_STARTED = loop.time()



def parse_brightdata_serp_payload(
    body: str,
    query: str,
) -> list[SearchHit]:
    """Parse Bright Data SERP output. Search results are discovery-only."""
    try:
        decoded = json.loads(body)
    except Exception:
        decoded = None

    out = []
    seen = set()

    def add(row):
        if not isinstance(row, dict):
            return
        url = str(
            row.get("link")
            or row.get("url")
            or row.get("href")
            or ""
        ).strip()
        if not url.startswith(("http://", "https://")) or url in seen:
            return
        seen.add(url)
        out.append(
            SearchHit(
                title=str(row.get("title") or row.get("name") or "").strip(),
                url=url,
                snippet=str(
                    row.get("snippet")
                    or row.get("description")
                    or row.get("desc")
                    or ""
                ).strip(),
                query=query,
            )
        )

    if isinstance(decoded, dict):
        for key in (
            "organic",
            "organic_results",
            "results",
            "organicResults",
            "general",
        ):
            rows = decoded.get(key)
            if isinstance(rows, list):
                for row in rows:
                    add(row)

    if not out and isinstance(body, str) and "http" in body:
        for m in re.finditer(
            r'href=["\'](https?://(?!www\.google\.)[^"\']+)["\']',
            body,
            re.I,
        ):
            add({"url": m.group(1)})
            if len(out) >= 10:
                break

    return out


def parse_brave_search_payload(
    payload: dict,
    query: str,
) -> list[SearchHit]:
    """Parse Brave Web Search results as discovery leads only."""
    rows = ((payload or {}).get("web") or {}).get("results") or []
    output = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        url = str(row.get("url") or "").strip()
        if not url.startswith(("http://", "https://")) or url in seen:
            continue
        seen.add(url)
        output.append(SearchHit(
            title=clean_name(str(row.get("title") or "")),
            url=url,
            snippet=clean_name(str(row.get("description") or "")),
            query=query,
        ))
    return output




_SERP_MEMORY_CACHE: dict[str, dict] = {}


def _serp_cache_key(
    query: str,
    num: int,
    page: int,
) -> str:
    raw = f"{fold(query)}|{int(num)}|{int(page)}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


async def serp_cache_get(
    query: str,
    num: int,
    page: int,
) -> list[SearchHit] | None:
    if not env_bool("ENABLE_SERP_CACHE", True):
        return None

    key = _serp_cache_key(query, num, page)
    now = time.time()

    mem = _SERP_MEMORY_CACHE.get(key)
    if mem and float(mem.get("expires_at", 0)) > now:
        try:
            return [
                SearchHit.model_validate(x)
                for x in mem.get("rows", [])
            ]
        except Exception:
            _SERP_MEMORY_CACHE.pop(key, None)

    if not firestore_enabled():
        return None

    def _load():
        client = _firestore_client()
        if client is None:
            return None
        try:
            snap = client.collection(
                os.getenv(
                    "FIRESTORE_SERP_CACHE_COLLECTION",
                    "aesthetic_serp_cache",
                )
            ).document(key).get()
            if not snap.exists:
                return None
            data = snap.to_dict() or {}
            if float(data.get("expires_at", 0)) <= time.time():
                return None
            return data
        except Exception:
            return None

    data = await asyncio.to_thread(_load)
    if not data:
        return None

    rows = data.get("rows", [])
    _SERP_MEMORY_CACHE[key] = {
        "expires_at": float(data.get("expires_at", now)),
        "rows": rows,
    }

    try:
        return [SearchHit.model_validate(x) for x in rows]
    except Exception:
        return None


async def serp_cache_put(
    query: str,
    num: int,
    page: int,
    rows: list[SearchHit],
) -> bool:
    if not env_bool("ENABLE_SERP_CACHE", True):
        return False

    ttl_days = max(
        1,
        int(os.getenv("SERP_CACHE_TTL_DAYS", "14")),
    )
    expires_at = time.time() + ttl_days * 86400
    key = _serp_cache_key(query, num, page)
    payload_rows = [row.model_dump() for row in rows]

    _SERP_MEMORY_CACHE[key] = {
        "expires_at": expires_at,
        "rows": payload_rows,
    }

    if not firestore_enabled():
        return True

    def _save():
        client = _firestore_client()
        if client is None:
            return False
        try:
            client.collection(
                os.getenv(
                    "FIRESTORE_SERP_CACHE_COLLECTION",
                    "aesthetic_serp_cache",
                )
            ).document(key).set(
                {
                    "query": query,
                    "num": int(num),
                    "page": int(page),
                    "rows": payload_rows,
                    "expires_at": expires_at,
                    "updated_at": datetime.now(timezone.utc),
                },
                merge=True,
            )
            return True
        except Exception:
            return False

    return await asyncio.to_thread(_save)



def serper_free_account_pattern_error(
    status_code: int,
    body: str,
) -> bool:
    return (
        int(status_code) == 400
        and "query pattern not allowed for free accounts"
        in fold(body or "")
    )



class SerperClient:
    def __init__(
        self,
        enabled: bool = True,
        request_cap: int = 0,
    ):
        self.api_key = os.getenv("SERPER_API_KEY", "").strip()
        self.enabled = bool(enabled)
        self.request_cap = max(0, int(request_cap or 0))
        self.country_code = ""
        self.language = ""
        self._budget_lock = asyncio.Lock()
        self.timeout = 12
        self.min_interval = float(os.getenv("SERPER_MIN_INTERVAL_SECONDS", "0.32"))
        self.max_429_retries = int(os.getenv("SERPER_429_RETRIES", "3"))
        self.rate_limit_retries = 0
        self.cache_hits = 0
        self.cache_writes = 0
        self.free_account_num_fallbacks = 0
        self.effective_num_cap = 20
        self.requests_attempted = 0
        self.requests_succeeded = 0
        self.requests_failed = 0
        self.requests_skipped = 0
        self.disabled = False
        self.disabled_reason = ""
        self.last_error = ""

        self.brightdata_api_key = os.getenv(
            "BRIGHTDATA_API_KEY",
            "",
        ).strip()
        self.brightdata_serp_zone = os.getenv(
            "BRIGHTDATA_SERP_ZONE",
            "",
        ).strip()
        self.brightdata_enabled = (
            env_bool("USE_BRIGHTDATA", True)
            and bool(self.brightdata_api_key)
            and bool(self.brightdata_serp_zone)
        )
        self.brightdata_requests_attempted = 0
        self.brightdata_requests_succeeded = 0
        self.brightdata_requests_failed = 0
        self.brightdata_hits_total = 0
        self.brightdata_fallback_used = False
        self.brave_api_key = os.getenv("BRAVE_SEARCH_API_KEY", "").strip()
        self.brave_enabled = env_bool("USE_BRAVE_SEARCH_RESCUE", True) and bool(
            self.brave_api_key
        )
        self.brave_requests_attempted = 0
        self.brave_requests_succeeded = 0
        self.brave_requests_failed = 0
        self.brave_hits_total = 0
        self.brave_cache_hits = 0
        self.brave_used = False

    async def brave_search(
        self,
        query: str,
        *,
        count: int = 10,
        country_code: str = "",
        language: str = "en",
        offset: int = 0,
    ) -> list[SearchHit]:
        """Query an independent index only during the final novelty rescue."""
        if not self.brave_enabled:
            return []
        self.brave_used = True
        cache_query = f"brave::{query}"
        cache_count = max(1, min(int(count), 20))
        cached = await serp_cache_get(cache_query, cache_count, int(offset) + 1)
        if cached is not None:
            self.brave_cache_hits += 1
            return cached
        self.brave_requests_attempted += 1
        params = {
            "q": query,
            "count": max(1, min(int(count), 20)),
            "offset": max(0, min(int(offset), 9)),
            "search_lang": (language or "en")[:2].lower(),
            "safesearch": "moderate",
        }
        if country_code and len(country_code) == 2:
            params["country"] = country_code.upper()
        try:
            async with httpx.AsyncClient(
                timeout=float(os.getenv("BRAVE_SEARCH_TIMEOUT_SECONDS", "12")),
                follow_redirects=True,
            ) as client:
                response = await client.get(
                    "https://api.search.brave.com/res/v1/web/search",
                    headers={
                        "Accept": "application/json",
                        "X-Subscription-Token": self.brave_api_key,
                    },
                    params=params,
                )
        except Exception:
            self.brave_requests_failed += 1
            return []
        if response.status_code >= 400:
            self.brave_requests_failed += 1
            return []
        try:
            rows = parse_brave_search_payload(response.json(), query)
        except Exception:
            self.brave_requests_failed += 1
            return []
        self.brave_requests_succeeded += 1
        self.brave_hits_total += len(rows)
        await serp_cache_put(cache_query, cache_count, int(offset) + 1, rows)
        return rows

    async def _brightdata_search(
        self,
        query: str,
    ) -> list[SearchHit]:
        if not self.brightdata_enabled:
            return []

        self.brightdata_fallback_used = True
        self.brightdata_requests_attempted += 1

        target = "https://www.google.com/search?" + urlencode({
            "q": query,
            "num": "10",
            "hl": "en",
            "brd_json": "1",
        })

        try:
            async with httpx.AsyncClient(
                timeout=float(
                    os.getenv(
                        "BRIGHTDATA_SERP_TIMEOUT_SECONDS",
                        "22",
                    )
                ),
                follow_redirects=True,
            ) as client:
                r = await client.post(
                    "https://api.brightdata.com/request",
                    headers={
                        "Authorization": (
                            f"Bearer {self.brightdata_api_key}"
                        ),
                        "Content-Type": "application/json",
                    },
                    json={
                        "zone": self.brightdata_serp_zone,
                        "url": target,
                        "format": "raw",
                        "method": "GET",
                    },
                )
        except Exception:
            self.brightdata_requests_failed += 1
            return []

        if r.status_code >= 400:
            self.brightdata_requests_failed += 1
            return []

        rows = parse_brightdata_serp_payload(
            r.text,
            query,
        )
        self.brightdata_requests_succeeded += 1
        self.brightdata_hits_total += len(rows)
        return rows

    async def _wait_for_slot(self):
        await _wait_for_shared_serper_slot(self.min_interval)

    async def _reserve_network_request(self) -> bool:
        async with self._budget_lock:
            if (
                self.request_cap > 0
                and self.requests_attempted >= self.request_cap
            ):
                self.requests_skipped += 1
                return False
            self.requests_attempted += 1
            return True

    def cache_query(self, query: str) -> str:
        # Locale changes Google's results; a US cache is not a UAE cache.
        if not self.country_code and not self.language:
            return query
        return f"__serper_locale__/{self.country_code.lower()}/{self.language} {query}"

    async def search(
        self,
        query: str,
        num: int = 10,
        page: int = 1,
        refresh_cache: bool = False,
    ) -> list[SearchHit]:
        cache_num = max(1, min(int(num), 20))
        cached = None if refresh_cache else await serp_cache_get(
            self.cache_query(query),
            cache_num,
            int(page),
        )
        if cached is not None:
            self.cache_hits += 1
            return cached

        if not self.enabled:
            self.requests_skipped += 1
            return []

        if not self.api_key:
            fallback = await self._brightdata_search(query)
            if fallback:
                return fallback
            raise RuntimeError("SERPER_API_KEY is not configured")

        if self.disabled:
            self.requests_skipped += 1
            fallback = await self._brightdata_search(query)
            if fallback:
                return fallback
            raise RuntimeError(
                f"Serper disabled for this request: {self.disabled_reason}"
            )

        last_error = None

        for attempt in range(self.max_429_retries + 1):
            if self.disabled:
                self.requests_skipped += 1
                fallback = await self._brightdata_search(query)
                if fallback:
                    return fallback
                raise RuntimeError(
                    f"Serper disabled for this request: {self.disabled_reason}"
                )

            await self._wait_for_slot()

            # Other concurrent searches may have discovered a terminal account
            # error while this coroutine was waiting for the shared slot.
            if self.disabled:
                self.requests_skipped += 1
                fallback = await self._brightdata_search(query)
                if fallback:
                    return fallback
                raise RuntimeError(
                    f"Serper disabled for this request: {self.disabled_reason}"
                )

            effective_num = max(
                1,
                min(
                    int(num),
                    int(self.effective_num_cap),
                    20,
                ),
            )

            if not await self._reserve_network_request():
                return []

            async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True) as client:
                r = await client.post(
                    "https://google.serper.dev/search",
                    headers={
                        "X-API-KEY": self.api_key,
                        "Content-Type": "application/json",
                    },
                    json={
                        "q": query,
                        "num": effective_num,
                        **({"gl": self.country_code.lower()} if self.country_code else {}),
                        **({"hl": self.language} if self.language else {}),
                        **({"page": int(page)} if int(page) > 1 else {}),
                    },
                )

            if r.status_code == 429:
                self.rate_limit_retries += 1
                last_error = f"Serper HTTP 429: {r.text[:300]}"
                self.last_error = last_error

                if attempt < self.max_429_retries:
                    retry_after = r.headers.get("retry-after")
                    try:
                        delay = float(retry_after) if retry_after else (0.75 + attempt * 0.75)
                    except Exception:
                        delay = 0.75 + attempt * 0.75
                    await asyncio.sleep(delay)
                    continue

                self.requests_failed += 1
                raise RuntimeError(last_error)

            if (
                serper_free_account_pattern_error(
                    r.status_code,
                    r.text,
                )
                and effective_num > 10
            ):
                # Some Serper accounts reject the same otherwise-valid query
                # when num=20. Fall back to the free-compatible 10-result
                # request and remember the cap for every later coroutine in
                # this discovery run.
                self.effective_num_cap = 10
                self.free_account_num_fallbacks += 1
                self.last_error = (
                    "Serper free-account compatibility fallback: "
                    "num capped at 10"
                )
                continue

            if r.status_code >= 400:
                self.requests_failed += 1
                self.last_error = f"Serper HTTP {r.status_code}: {r.text[:300]}"

                body_lower = (r.text or "").lower()
                if (
                    r.status_code in {400, 401, 402, 403}
                    and any(
                        marker in body_lower
                        for marker in [
                            "not enough credits",
                            "insufficient credits",
                            "insufficient balance",
                            "quota exhausted",
                        ]
                    )
                ):
                    self.disabled = True
                    self.disabled_reason = "credits_exhausted"

                    fallback = await self._brightdata_search(query)
                    if fallback:
                        return fallback

                raise RuntimeError(self.last_error)

            data = r.json()
            if isinstance(data, dict) and (data.get("error") or data.get("message")) and not data.get("organic"):
                self.requests_failed += 1
                message = str(data.get("error") or data.get("message") or "")
                self.last_error = f"Serper response error: {message}"[:500]

                msg_lower = message.lower()
                if any(
                    marker in msg_lower
                    for marker in [
                        "not enough credits",
                        "insufficient credits",
                        "insufficient balance",
                        "quota exhausted",
                    ]
                ):
                    self.disabled = True
                    self.disabled_reason = "credits_exhausted"

                    fallback = await self._brightdata_search(query)
                    if fallback:
                        return fallback

                raise RuntimeError(self.last_error)

            self.requests_succeeded += 1
            rows = [
                SearchHit(
                    title=str(x.get("title") or "").strip(),
                    url=str(x.get("link") or "").strip(),
                    snippet=str(x.get("snippet") or "").strip(),
                    query=query,
                )
                for x in (data.get("organic") or [])
                if str(x.get("link") or "").strip()
            ]
            if await serp_cache_put(
                self.cache_query(query),
                cache_num,
                int(page),
                rows,
            ):
                self.cache_writes += 1
            return rows

        self.requests_failed += 1
        self.last_error = last_error or "Serper request failed"
        raise RuntimeError(self.last_error)


# ============================================================
# Fetch
# ============================================================

_interactive_fetch_budget: ContextVar[dict | None] = ContextVar(
    "interactive_fetch_budget", default=None,
)
_hybrid_parse_memo: ContextVar[dict | None] = ContextVar(
    "hybrid_parse_memo", default=None,
)
_hybrid_progress: ContextVar[asyncio.Queue | None] = ContextVar(
    "hybrid_progress", default=None,
)
_hybrid_round_progress_base: ContextVar[dict | None] = ContextVar(
    "hybrid_round_progress_base", default=None,
)


async def _reserve_interactive_fetch(url: str = "") -> bool:
    budget = _interactive_fetch_budget.get()
    if budget is None:
        return True
    async with budget["lock"]:
        if budget["left"] <= 0:
            budget["blocked"] = int(budget.get("blocked") or 0) + 1
            return False
        budget["left"] -= 1
        return True


UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 Chrome/126.0 Safari/537.36"
)


_FETCH_LOOP_STATE = weakref.WeakKeyDictionary()


def _fetch_state():
    loop = asyncio.get_running_loop()
    state = _FETCH_LOOP_STATE.get(loop)
    if state is None:
        limit = max(1, int(os.getenv("MAX_HTTP_CONCURRENCY", "12")))
        client = httpx.AsyncClient(
            timeout=float(os.getenv("REQUEST_TIMEOUT_SECONDS", "12")),
            limits=httpx.Limits(max_connections=limit, max_keepalive_connections=min(limit, 8)),
            follow_redirects=True,
            headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.8"},
        )
        state = {"client": client, "semaphore": asyncio.Semaphore(limit),
                 "lock": asyncio.Lock(), "cache": {}, "inflight": {}}
        _FETCH_LOOP_STATE[loop] = state
    return state


def _has_recent_html_fetch(url: str) -> bool:
    """True when this request already fetched the page through the pool."""
    if not url:
        return False
    try:
        state = _FETCH_LOOP_STATE.get(asyncio.get_running_loop())
    except RuntimeError:
        return False
    if state is None:
        return False
    cached = state["cache"].get((url, False))
    return bool(cached and cached[0] > time.monotonic() and cached[1])


async def _fetch_document(url: str, *, xml: bool = False) -> str | None:
    if not host_of(url):
        return None
    state = _fetch_state()
    key = (url, xml)
    now = time.monotonic()
    async with state["lock"]:
        cached = state["cache"].get(key)
        if cached and cached[0] > now:
            return cached[1]
        task = state["inflight"].get(key)
        if task is None:
            async def download():
                # Sitemap and robots probes are not clinic price pages. Counting
                # them against the interactive cap was ending the round before
                # a priced menu could be opened.
                if not xml and not await _reserve_interactive_fetch(url):
                    return None
                try:
                    async with state["semaphore"]:
                        response = await state["client"].get(
                            url,
                            timeout=min(
                                float(os.getenv("REQUEST_TIMEOUT_SECONDS", "12")),
                                float(os.getenv("MAX_INTERACTIVE_REQUEST_TIMEOUT_SECONDS", "7"))
                                if _interactive_fetch_budget.get() is not None else 60,
                            ),
                            headers={"Accept": (
                                "application/xml,text/xml,text/plain,text/html,*/*;q=0.5"
                                if xml else "text/html,application/xhtml+xml"
                            )},
                        )
                    # Procedure microsites are trusted by parent-domain
                    # ownership. A root subdomain redirecting to an unrelated
                    # host must not inherit the parent's clinic identity.
                    original_host = host_of(url)
                    if (not xml and len(original_host.split(".")) >= 3
                            and not original_host.startswith("www.")
                            and (urlparse(url).path or "/") == "/"
                            and not related_clinic_hosts(
                                host_of(str(getattr(response, "url", url))), original_host,
                            )):
                        return None
                    content_type = (response.headers.get("content-type") or "").lower()
                    state.setdefault("failures", {}).pop(key, None)
                    if response.status_code >= 400 or (
                        not xml and "text/html" not in content_type
                        and "application/xhtml+xml" not in content_type
                    ):
                        state["failures"][key] = (
                            f"http_{response.status_code}" if response.status_code >= 400
                            else "non_html_response"
                        )
                        return None
                    return response.text[:2_000_000]
                except Exception as exc:
                    state.setdefault("failures", {})[key] = f"fetch_{type(exc).__name__}"
                    return None

            task = asyncio.create_task(download())
            state["inflight"][key] = task
    try:
        result = await asyncio.shield(task)
    except asyncio.CancelledError:
        raise
    finally:
        if task.done():
            async with state["lock"]:
                if state["inflight"].get(key) is task:
                    state["inflight"].pop(key, None)
                    result_value = None if task.cancelled() else task.result()
                    failure = state.get("failures", {}).get(key, "")
                    ttl = (900 if result_value is not None else 300
                           if failure in {"http_403", "http_429"} else 45)
                    state["cache"][key] = (time.monotonic() + ttl, result_value)
                    if len(state["cache"]) > 512:
                        expired = [k for k, (expiry, _) in state["cache"].items()
                                   if expiry <= time.monotonic()]
                        for old in expired:
                            state["cache"].pop(old, None)
                            state.get("failures", {}).pop(old, None)
                        while len(state["cache"]) > 512:
                            state["cache"].pop(next(iter(state["cache"])))
    return result


async def fetch_html(url: str) -> str | None:
    return await _fetch_document(url)


async def fetch_text_document(url: str) -> str | None:
    return await _fetch_document(url, xml=True)


def normalize_dom_price_boundaries(soup):
    """Keep repeated offer badges from joining into a thousands amount.

    Real markup can say <span>FROM 499</span><span>499 AED</span>.
    The DOM boundary is significant; flattening it as "499 499 AED" would
    fabricate 499,499 AED. Only an identical, qualified badge is separated.
    """
    for node in soup.find_all(['span', 'strong', 'b']):
        text = node.get_text(' ', strip=True)
        if len(text) > 90:
            continue
        amounts = list(iter_exact_price_matches(text))
        if len(amounts) != 1:
            continue
        previous = node.find_previous_sibling()
        if previous is None:
            continue
        badge = previous.get_text(' ', strip=True)
        match = re.fullmatch(r'(?:from|starting\s+from|starts?\s+from|nga|de\s+la)\s+'
                             r'([\d.,]+)', badge, re.I)
        if match and to_num(match.group(1)) == amounts[0][1]:
            previous.insert_after(' | ')


def page_text(html: str) -> str:
    soup = BeautifulSoup(html, "lxml")
    for t in soup(["script", "style", "noscript"]):
        t.decompose()
    normalize_dom_price_boundaries(soup)
    text = " ".join(soup.stripped_strings)
    if len(text) <= 50000:
        return text
    # Long hospital menus put their actual address in the footer. Keep that
    # city witness as well as the existing body limit; never infer a city from
    # a search query just because the visible-text slice lost the address.
    tail_start = max(50000, len(text) - 6000)
    return text[:50000] + "\n" + text[tail_start:]


# ============================================================
# Marketplace profile check
# ============================================================


WHATCLINIC_CATEGORY_SLUGS = {
    "dermal-fillers", "dermal-filler",
    "lip-augmentation", "lip-filler", "lip-fillers",
    "cheek-filler", "chin-filler", "jaw-filler",
    "collagen-dermal-filler", "fat-dermal-filler",
    "marionette-lines-filler", "nasolabial-folds-treatment",
    "medical-aesthetics", "microneedling", "chemical-peel",
    "mesotherapy", "laser-hair-removal", "treatment-for-wrinkles",
    "rhinoplasty", "breast-implants", "breast-augmentation",
    "hair-transplant", "facelift", "blepharoplasty", "liposuction",
}


def is_whatclinic_category_result(
    url: str,
    title: str = "",
    snippet: str = "",
    city: str = "",
) -> bool:
    if url and "whatclinic.com" not in host_of(url):
        return False

    if url:
        parts = [x for x in (urlparse(url).path or "").lower().split("/") if x]
        last = parts[-1] if parts else ""
        if last in WHATCLINIC_CATEGORY_SLUGS:
            return True

    raw_blob = f"{title} {snippet}"
    blob = fold(raw_blob)

    if "check prices reviews" in blob:
        return True

    if re.search(r"\bchoose\s+from\s+\d+\b.*\bclinics?\b", blob):
        return True

    title_f = fold(title)
    treatment_markers = [
        "dermal filler", "lip filler", "lip augmentation",
        "cheek filler", "chin filler", "jaw filler",
        "chemical peel", "microneedling", "botox",
        "rhinoplasty", "breast augmentation", "hair transplant",
        "facelift", "blepharoplasty", "liposuction",
    ]
    if city and any(title_f.startswith(x) for x in treatment_markers):
        if f"in {fold(city)}" in title_f:
            return True

    return False


def is_probable_single_business_hit(hit: SearchHit, city: str = "") -> bool:
    if not is_probable_single_business_page(hit.url):
        return False

    if "whatclinic.com" in host_of(hit.url):
        return not is_whatclinic_category_result(
            hit.url,
            hit.title,
            hit.snippet,
            city,
        )

    return True


def is_probable_single_business_page(url: str) -> bool:
    h = host_of(url)
    p = (urlparse(url).path or "").lower()
    parts = [x for x in p.split("/") if x]

    if "wupdoc.com" in h:
        # /find/... is a category and contains unrelated clinic prices.
        return bool(re.fullmatch(r"/albania/[a-z0-9-]+-d-[a-z0-9]+/?", p))

    if "bookimed.com" in h:
        return bool(re.fullmatch(r"/clinic/[a-z0-9-]+/(?:procedure=[a-z0-9-]+/)?", p))

    if "fresha.com" in h:
        return "/a/" in p

    if "booksy.com" in h:
        return (
            len(parts) >= 2
            and not any(x in p for x in ["/s/", "/l/", "/search", "/category", "/categories", "/explore"])
        )

    if "whatclinic.com" in h:
        # WhatClinic profile URLs and treatment-category URLs can both have
        # exactly four path segments:
        #   /cosmetic-plastic-surgery/albania/tirana/dr-gera-tagani-clinic
        #   /beauty-clinics/albania/tirana/dermal-fillers
        # Distinguish the last slug instead of rejecting all 4-segment URLs.
        if len(parts) < 4:
            return False

        last = fold(parts[-1].replace("-", " "))
        category_terms = {
            "dermal fillers", "dermal filler", "lip filler", "lip fillers",
            "lip augmentation", "cheek filler", "chin filler",
            "jaw filler", "collagen dermal filler", "marionette lines filler",
            "fat dermal filler", "fat filler", "medical aesthetics",
            "microneedling", "chemical peel", "mesotherapy",
            "laser hair removal", "treatment for wrinkles", "rhinoplasty",
            "breast implants", "breast augmentation", "hair transplant",
            "facelift", "blepharoplasty", "liposuction",
        }

        if last in category_terms or parts[-1] in WHATCLINIC_CATEGORY_SLUGS:
            return False

        return True

    if "treatwell.com" in h:
        return any(x in p for x in ["/place/", "/venue/", "/salon/"])

    if "hirefrederick.com" in h:
        # Public booking pages are usually one business slug at the root.
        return (
            len(parts) >= 1
            and not any(
                x in p
                for x in [
                    "/search", "/admin", "/login", "/signup",
                    "/privacy", "/terms", "/support",
                ]
            )
        )

    return False



MARKETPLACE_LOCALE_COUNTRY = {
    "en-gb": "GB",
    "en-us": "US",
    "en-au": "AU",
    "en-nz": "NZ",
    "it-it": "IT",
    "fr-fr": "FR",
    "es-es": "ES",
    "de-de": "DE",
}

COUNTRY_NAME_CODES = {
    "albania": "AL",
    "romania": "RO",
    "bulgaria": "BG",
    "italy": "IT",
    "turkey": "TR",
    "united-kingdom": "GB",
    "united-states": "US",
    "australia": "AU",
    "new-zealand": "NZ",
    "brazil": "BR",
    "france": "FR",
    "spain": "ES",
}

MARKETPLACE_BRAND_NAMES = {
    "fresha", "whatclinic", "booksy", "treatwell",
    "hirefrederick", "frederick", "marketing suite",
    "fresha - instantly book salons and spas nearby",
}


def marketplace_url_geo_conflict(
    url: str,
    city: str,
    country_code: str | None = None,
) -> bool:
    if classify_source(url) != "marketplace":
        return False

    cc = (country_code or country_hint_for_city(city) or "").upper()
    host = host_of(url)
    path = urlparse(url).path.lower()

    if "fresha.com" in host:
        m = re.search(r"/in/([a-z]{2})-([^/]+)", path)
        if m:
            explicit_cc = m.group(1).upper()
            if cc and explicit_cc != cc:
                return True

            loc = m.group(2).replace("-", " ")
            if foreign_city_conflict(loc, city) and not city_in_text(loc, city):
                return True

    if "booksy.com" in host:
        parts = [p for p in path.split("/") if p]
        if parts:
            locale_cc = MARKETPLACE_LOCALE_COUNTRY.get(parts[0])
            if cc and locale_cc and locale_cc != cc:
                return True

    if "whatclinic.com" in host:
        for country_name, country_cc in COUNTRY_NAME_CODES.items():
            if f"/{country_name}/" in path and cc and country_cc != cc:
                return True

    if "treatwell.co.uk" in host and cc and cc != "GB":
        return True

    return False


def _title_candidates(html: str, serp_title: str = "") -> list[str]:
    soup = BeautifulSoup(html, "lxml")
    out = []

    for prop in ["og:title", "twitter:title"]:
        node = (
            soup.find("meta", attrs={"property": prop})
            or soup.find("meta", attrs={"name": prop})
        )
        if node and node.get("content"):
            out.append(str(node.get("content")).strip())

    if soup.title and soup.title.string:
        out.append(soup.title.string.strip())

    if serp_title:
        out.append(serp_title.strip())

    return [x for x in out if x]


def _clean_marketplace_title(title: str, platform: str, city: str) -> str:
    s = clean_name(title)

    if platform.lower() == "hirefrederick":
        s = re.sub(
            r"^\s*Marketing\s+Suite\s*::\s*",
            "",
            s,
            flags=re.I,
        ).strip()

    s = re.sub(
        r"\s*[|–—-]\s*(?:Fresha|WhatClinic|Booksy|Treatwell|HireFrederick|Frederick)\s*$",
        "",
        s,
        flags=re.I,
    )
    s = re.sub(r"\s*-\s*Book Online.*$", "", s, flags=re.I)
    s = re.sub(r"\s*-\s*Prices?, Reviews?.*$", "", s, flags=re.I)

    if platform.lower() == "whatclinic":
        if city:
            s = re.sub(
                rf"\s+in\s+{re.escape(city)}\b.*$",
                "",
                s,
                flags=re.I,
            ).strip()
        s = re.sub(
            r"\s*[•|]\s*Read\s+\d+\s+Reviews?.*$",
            "",
            s,
            flags=re.I,
        ).strip()

        sf = fold(s)
        if any(sf.startswith(x) for x in [
            "dermal filler", "lip filler", "lip augmentation",
            "cheek filler", "chin filler", "jaw filler",
        ]):
            return ""

    parts = [clean_name(x) for x in re.split(r"\s+[|–—-]\s+", s) if clean_name(x)]
    if parts:
        first = parts[0]
        if (
            valid_name(first)
            and fold(first) not in MARKETPLACE_BRAND_NAMES
            and not first.lower().startswith(platform.lower())
        ):
            return first

    if valid_name(s) and fold(s) not in MARKETPLACE_BRAND_NAMES:
        return s

    return ""


def _fresha_name_from_url(url: str, city: str) -> str:
    m = re.search(r"/a/([^/?]+)", urlparse(url).path, re.I)
    if not m:
        return ""

    slug = re.sub(r"-[a-z0-9]{7,12}$", "", m.group(1), flags=re.I)
    words = slug.split("-")
    city_words = {fold(a) for a in aliases_for_city(city)}

    stop = len(words)
    for i, word in enumerate(words):
        if fold(word) in city_words:
            stop = i
            break

    candidate_words = words[:stop]
    if not candidate_words:
        return ""

    name = " ".join(w.capitalize() for w in candidate_words)
    return name if valid_name(name) else ""


def marketplace_profile_name(
    html: str,
    url: str,
    serp_title: str = "",
    city: str = "",
) -> str:
    page_role = classify_page_source(
        url,
        page_text(html) if html else "",
    )
    if page_role != "marketplace":
        return ""

    host = host_of(url)
    platform = (
        "Fresha" if "fresha.com" in host
        else "WhatClinic" if "whatclinic.com" in host
        else "Booksy" if "booksy.com" in host
        else "HireFrederick" if "hirefrederick.com" in host
        else "Wupdoc" if "wupdoc.com" in host
        else "Treatwell" if "treatwell" in host
        else domain_brand(url)
    )

    for title in _title_candidates(html, serp_title):
        name = _clean_marketplace_title(title, platform, city)
        if name:
            return name

    structured = structured_business_name(html)
    if (
        structured
        and valid_name(structured)
        and fold(structured) not in MARKETPLACE_BRAND_NAMES
        and platform.lower() not in structured.lower()
    ):
        return structured

    if platform == "Fresha":
        return _fresha_name_from_url(url, city)

    parts = [p for p in urlparse(url).path.split("/") if p]
    if parts:
        last = re.sub(r"[-_]+", " ", parts[-1])
        last = re.sub(r"\b\d{4,}\b.*$", "", last).strip()
        candidate = " ".join(w.capitalize() for w in last.split())
        if valid_name(candidate):
            return candidate

    return ""




def expand_marketplace_category_links(
    base_url: str,
    html: str,
    city: str,
    limit: int = 12,
) -> list[str]:
    soup = BeautifulSoup(html, "lxml")
    base_host = host_of(base_url)
    out: list[str] = []
    seen = set()

    def consider(raw_url: str):
        if len(out) >= limit:
            return

        raw_url = (raw_url or "").replace("\\/", "/")
        absolute = safe_http_urljoin(base_url, raw_url)

        if not absolute.startswith("http"):
            return
        if host_of(absolute) != base_host:
            return
        if absolute == base_url:
            return
        if not is_probable_single_business_page(absolute):
            return
        if absolute in seen:
            return

        seen.add(absolute)
        out.append(absolute)

    for a in soup.find_all("a", href=True):
        consider(str(a.get("href") or ""))

    if len(out) < limit:
        raw = html.replace("\\/", "/")

        if "fresha.com" in base_host:
            patterns = [
                r'https?://(?:www\.)?fresha\.com/a/[A-Za-z0-9_%/?=&.\-]+',
                r'["\'](/a/[A-Za-z0-9_%/?=&.\-]+)["\']',
            ]
        elif "whatclinic.com" in base_host:
            patterns = [
                r'https?://(?:www\.)?whatclinic\.com/[A-Za-z0-9_%/?=&.\-]+',
            ]
        elif "booksy.com" in base_host:
            patterns = [
                r'https?://(?:www\.)?booksy\.com/[A-Za-z0-9_%/?=&.\-]+',
            ]
        elif "treatwell" in base_host:
            patterns = [
                r'https?://[^"\']*treatwell[^"\']*/(?:place|venue|salon)/[A-Za-z0-9_%/?=&.\-]+',
            ]
        else:
            patterns = []

        for pattern in patterns:
            for match in re.finditer(pattern, raw, re.I):
                candidate = match.group(1) if match.lastindex else match.group(0)
                consider(candidate)
                if len(out) >= limit:
                    break
            if len(out) >= limit:
                break

    return out


# ============================================================
# Identity resolution
# ============================================================

GENERIC_NAMES = {
    "whatclinic", "whatclinic.com", "fresha", "fresha.com", "booksy",
    "booksy.com", "treatwell", "treatwell.com",
    "hirefrederick", "hirefrederick.com", "frederick",
    "lip filler",
    "dermal filler", "filler", "prices", "price list", "clinic",
    "beauty clinics", "lip augmentation",
}

GENERIC_NAME_PATTERNS = [
    r"^page\s+\d+\s+of\s+\d+$",
    r"^page\s+\d+$",
    r"^author$",
    r"^blog$",
    r"^home$",
]


def clean_name(s: str) -> str:
    # Search titles and JSON-LD frequently contain HTML entities.  Keeping
    # ``&amp;`` in the persisted name makes the same provider look like a new
    # identity on a later crawl, so decode before any comparison/display use.
    value = s or ""
    if "&" in value:
        value = unescape(value)
    return re.sub(r"\s+", " ", value).strip(" |-–—:")


def valid_name(s: str) -> bool:
    n = clean_name(s)

    if len(n) < 3 or len(n) > 100:
        return False

    # A page/article/service title is not a clinic name.
    if re.search(r"[€£$]\s*\d|\d\s*[€£$]", n):
        return False

    if re.search(
        r"\b(?:how much|everything you need|guide to|"
        r"treatment in|treatment albania|care in albania|"
        r"medical tourism|price from|prices from|cost from|"
        r"rhinoplasty in (?:albania|tirana)|breast augmentation in (?:albania|tirana)|"
        r"from\s+[€£$]|vs\s+[€£$])\b",
        n,
        re.I,
    ):
        return False

    if n.lower() in GENERIC_NAMES:
        return False

    if any(re.fullmatch(p, n, re.I) for p in GENERIC_NAME_PATTERNS):
        return False

    if re.fullmatch(
        r"(?:price|prices|cost|costs|procedure|treatment|filler|botox|lip augmentation)",
        n,
        re.I,
    ):
        return False

    return True


def domain_brand(url: str) -> str:
    host = (urlparse(url).hostname or "").lower().replace("www.", "")
    labels = host.split(".")
    # A language subdomain such as al.clinic.com is not the clinic's name.
    if len(labels) >= 3 and labels[0] in {"al", "sq", "en", "it", "de", "fr", "ro"}:
        labels = labels[1:]
    stem = labels[0].replace("-", " ").strip()

    # Make common concatenated clinic domains readable:
    # velurspa -> Velur Spa, hysadental -> Hysa Dental.
    if " " not in stem:
        for suffix in (
            "medicalclinic", "healthclinic", "aestheticclinic", "beautyclinic",
            "clinic", "dental", "hospital", "aesthetics", "aesthetic", "beauty", "spa",
        ):
            if stem.endswith(suffix) and len(stem) > len(suffix) + 2:
                stem = stem[:-len(suffix)] + " " + suffix
                break

    return " ".join(x.capitalize() for x in stem.split()) if valid_name(stem) else ""


GENERIC_SERVICE_NAME_TERMS = {
    "massage", "massages", "treatment", "treatments", "aesthetic",
    "aesthetics", "beauty", "dermatology", "cosmetic", "cosmetics",
}


def weak_business_name(name: str, city: str, url: str) -> bool:
    if not valid_name(name):
        return True

    n = fold(name)
    brand = fold(domain_brand(url))

    # "Massage Tirana" is a service/location title, not the provider brand.
    if city and city_in_text(name, city):
        if any(term in n for term in GENERIC_SERVICE_NAME_TERMS):
            return True

    # If a short service/title name has no lexical relation to the site's domain
    # brand, inspect the homepage before trusting it.
    brand_words = {w for w in re.findall(r"[a-z0-9]+", brand) if len(w) >= 4}
    name_words = {w for w in re.findall(r"[a-z0-9]+", n) if len(w) >= 4}
    if brand_words and name_words and not (brand_words & name_words):
        if len(name_words) <= 4:
            return True

    return False


def homepage_url(url: str) -> str:
    p = urlparse(url)
    return urlunparse((p.scheme or "https", p.netloc, "/", "", "", ""))


def structured_business_name(html: str, city: str = "", url: str = "") -> str:
    soup = BeautifulSoup(html, "lxml")
    candidates = []

    for node in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = node.string or node.get_text(" ", strip=True)

        if not raw:
            continue

        try:
            data = json.loads(raw)
        except Exception:
            continue

        stack = data if isinstance(data, list) else [data]

        while stack:
            item = stack.pop()

            if isinstance(item, dict):
                typ = item.get("@type")
                types = typ if isinstance(typ, list) else [typ]

                if any(
                    t in {
                        "MedicalClinic", "LocalBusiness", "HealthAndBeautyBusiness",
                        "Dentist", "Physician", "Organization", "BeautySalon", "Hospital",
                    }
                    for t in types
                ):
                    name = clean_name(str(item.get("name") or ""))
                    if valid_name(name):
                        # Staff Physician nodes can share the clinic address.
                        # Prefer the clinic identity, preserving doctors as a
                        # fallback for a genuine individual practice.
                        business = any(t in {"MedicalClinic", "LocalBusiness", "HealthAndBeautyBusiness",
                            "Dentist", "BeautySalon", "Hospital"} for t in types)
                        priority = 0 if business else (1 if "Physician" in types else 2)
                        address = item.get("address")
                        if isinstance(address, dict):
                            location = " ".join(str(address.get(key) or "") for key in (
                                "streetAddress", "addressLocality", "addressRegion", "addressCountry",
                            ))
                        else:
                            location = str(address or "")
                        # A page can contain several real branch identities.
                        # Prefer the clinic in this city, not the first branch
                        # or a nested regulator/award Organization.
                        references = [str(item.get(k) or '') for k in ('url', '@id')]
                        same_source = bool(url and any(host_of(reference) == host_of(url)
                            for reference in references if reference.startswith(('https://', 'http://'))))
                        local = bool(city and city_in_text(location, city))
                        candidates.append((0 if same_source else 1, priority, 0 if local else 1, name))

                for value in item.values():
                    if isinstance(value, (dict, list)):
                        stack.append(value)

            elif isinstance(item, list):
                stack.extend(item)

    return min(candidates, key=lambda item: item[:3])[3] if candidates else ""


def guess_clinic_name_from_html(html: str, url: str, serp_title: str = "", city: str = "") -> str:
    structured = structured_business_name(html, city, url)
    if structured:
        return structured

    soup = BeautifulSoup(html, "lxml")

    site = soup.find("meta", attrs={"property": "og:site_name"})
    if site and site.get("content"):
        name = clean_name(str(site["content"]))
        if valid_name(name):
            return name

    candidates = []
    if soup.title and soup.title.string:
        candidates.append(soup.title.string.strip())

    if serp_title:
        candidates.append(serp_title)

    for title in candidates:
        parts = re.split(r"\s+[|\-—–•]\s+", title)

        for part in reversed(parts):
            p = clean_name(part)
            if valid_name(p) and not re.search(
                r"\b(price|cost|filler|botox|augmentation|albania vs|2026)\b",
                p,
                re.I,
            ):
                return p

    return ""


def brandish_business_name(name: str, url: str, city: str = "") -> str:
    if not name:
        return ""

    name = clean_name(name)
    parts = [clean_name(x) for x in re.split(r"\s+[|–—-]\s+", name) if clean_name(x)]
    if len(parts) <= 1:
        return name

    domain = fold(domain_brand(url))
    domain_words = {w for w in re.findall(r"[a-z0-9]+", domain) if len(w) >= 3}

    best = name
    best_score = -999

    for part in parts:
        if not valid_name(part):
            continue

        p = fold(part)
        words = {w for w in re.findall(r"[a-z0-9]+", p) if len(w) >= 3}
        overlap = len(words & domain_words)

        score = overlap * 5
        if re.search(r"\b(clinic|hospital|spa|dental|aesthetic|beauty|medical)\b", p):
            score += 2
        if re.search(r"\b(price|prices|cost|surgery in|2026|guide|article)\b", p):
            score -= 4
        if city and city_in_text(part, city) and len(words) <= 3:
            score -= 2

        if score > best_score:
            best_score = score
            best = part

    return best if valid_name(best) else name




async def resolve_clinic_name(
    html: str,
    url: str,
    serp_title: str = "",
    city: str = "",
) -> str:
    page_role = classify_page_source(url, await asyncio.to_thread(page_text, html) if html else "")
    if page_role == "marketplace":
        marketplace_name = marketplace_profile_name(html, url, serp_title, city)
        if marketplace_name:
            return marketplace_name

    # 1) current page structured/site identity
    name = await asyncio.to_thread(guess_clinic_name_from_html, html, url, serp_title, city)
    name = brandish_business_name(name, url, city) if name else ""

    if not valid_name(name):
        name = ""

    articleish = bool(
        not name
        or re.search(r"\b(page \d+|prices?|cost|2026|article|blog)\b", name, re.I)
    )
    weak = weak_business_name(name, city, url) if name else True

    # 2) Weak/article/service titles should be resolved from the homepage.
    if articleish or weak:
        hp = homepage_url(url)
        hp_html = await fetch_html(hp)
        if hp_html:
            hp_name = await asyncio.to_thread(guess_clinic_name_from_html, hp_html, hp, "", city)
            hp_name = brandish_business_name(hp_name, hp, city) if hp_name else ""
            if valid_name(hp_name) and not weak_business_name(hp_name, city, hp):
                name = hp_name
            elif valid_name(hp_name) and not name:
                name = hp_name

    # 3) If page/homepage title still looks like a service/location label and
    # conflicts with the domain brand, prefer the domain brand.
    brand = domain_brand(url)
    if brand and (not valid_name(name) or weak_business_name(name, city, url)):
        name = brand

    return name if valid_name(name) else ""


def tariff_location_context(html: str) -> str:
    """Explicit price/package headings; global branch lists are not proof."""
    memo = _hybrid_parse_memo.get()
    key = ('tariff_location_context', html or '')
    if memo is not None and key in memo:
        return memo[key]
    soup = BeautifulSoup(html or "", "lxml")
    for node in soup(['nav', 'footer', 'header']):
        node.decompose()
    lines = []
    for node in soup.find_all(['title', 'h1', 'h2', 'h3']):
        line = node.get_text(' ', strip=True)
        if re.search(r'\b(?:prices?|costs?|pricing|tariff|package|offer|preturi|tarife)\b', fold(line)):
            lines.append(line[:220])
    context = '\n'.join(dict.fromkeys(lines))[:2000]
    if memo is not None:
        memo[key] = context
    return context


def tariff_location_conflict(context: str, city: str) -> bool:
    lines = (context or '').splitlines()
    localized = [line for line in lines if city_in_text(line, city)]
    # A page may publish separate branch menus. Do not infer a foreign-only
    # tariff when it explicitly includes the requested city as well.
    return not localized and any(foreign_city_conflict(line, city) for line in lines)


def strong_local_page_evidence(html: str, text: str, city: str, url: str) -> bool:
    """Require location in business metadata/contact chrome, not article prose.

    Previous versions searched the complete body.  A comparison article that
    happened to mention Bucharest therefore looked like a Bucharest clinic.
    """
    if not city:
        return False
    if tariff_location_conflict(tariff_location_context(html), city):
        return False
    if classify_page_source(url, text) == "directory":
        return False
    # Price ownership is checked per tariff below. General cost prose must
    # not erase a clinic's actual structured/contact address.
    if country_price_guide_path(url) or cross_country_price_comparison(text):
        return False
    soup = BeautifulSoup(html, "lxml")
    structured_locations: list[str] = []
    structured_localities: list[str] = []
    for node in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = node.string or node.get_text(" ", strip=True)
        try:
            data = json.loads(raw) if raw else None
        except Exception:
            data = None
        stack = data if isinstance(data, list) else [data]
        while stack:
            item = stack.pop()
            if isinstance(item, dict):
                address = item.get("address")
                if isinstance(address, dict):
                    if address.get("addressLocality"):
                        structured_localities.append(str(address["addressLocality"]))
                    structured_locations.append(" ".join(str(address.get(k) or "") for k in (
                        "streetAddress", "addressLocality", "addressRegion", "addressCountry",
                    )))
                elif isinstance(address, str):
                    structured_locations.append(address)
                for value in item.values():
                    if isinstance(value, (dict, list)):
                        stack.append(value)
            elif isinstance(item, list):
                stack.extend(item)
    if canonical_city(city) == "new york" and structured_localities:
        # "New York" in addressRegion means the state, not the city. The
        # actual locality must be NYC or one of its five boroughs.
        return any(city_in_text(locality, city) for locality in structured_localities)
    if city_in_text(" ".join(structured_locations), city):
        return True
    if any(foreign_city_conflict(location, city) for location in structured_locations):
        # A real foreign business address outranks mentions of the search
        # city in SEO titles, navigation menus and treatment articles.
        return False

    addresses = [node.get_text(" ", strip=True)
                 for node in soup.select("address, [itemprop='address']")]
    if any(city_in_text(address, city) for address in addresses):
        return True
    if any(foreign_city_conflict(address, city) for address in addresses):
        return False

    chrome = []
    for node in soup.select(
        "address, footer, [itemprop='address'], [class*='contact'], [id*='contact'], "
        "[class*='location'], [id*='location'], [class*='address'], [id*='address']"
    ):
        classes = set(node.get("class") or [])
        if classes & {"elementor-location-single", "elementor-location-archive"}:
            # Elementor calls its page-template container a "location".
            # It contains article prose, not the clinic's postal location.
            continue
        chrome.append(node.get_text(" ", strip=True))
    if city_in_text(" ".join(chrome), city):
        return True

    provider_identity = f"{domain_brand(url)} {host_of(url)}"
    if (foreign_city_conflict(provider_identity, city)
            and not city_in_text(provider_identity, city)):
        # A foreign-city provider's SEO landing page is not branch evidence.
        # Its business address/contact chrome must establish this city.
        return False

    title = soup.title.string if soup.title and soup.title.string else ""

    meta = " ".join(
        str(t.get("content") or "")
        for t in soup.find_all("meta")
        if t.get("name") in {"description"}
        or t.get("property") in {"og:title", "og:description"}
    )

    # A compact clinic page may keep its address in an ordinary paragraph.
    # Require a credible business identity as well as the city, so mere article
    # prose cannot pass this fallback (comparison pages were rejected above).
    page_identity = guess_clinic_name_from_html(html, url, "")
    if city_in_text(text, city) and page_identity and (
        re.search(
            r"\b(?:clinic|clinica|klinika|hospital|spital|medical|"
            r"aesthetic|estetic|surgery|chirurg)\w*\b",
            fold(f"{page_identity} {text[:3000]}"),
        )
        or clinic_identity_similarity(page_identity, domain_brand(url)) >= 0.55
    ):
        return True

    # Title/meta/URL are acceptable for a provider/tariff page only after the
    # comparison/directory gates above.  General body prose is never used.
    return city_in_text(f"{title} {meta} {url}", city)


# ============================================================
# Google Places
# ============================================================

_PLACES_COOLDOWN_UNTIL = 0.0
_PLACES_COOLDOWN_REASON = ""



def provider_categories_for_procedure(procedure: str) -> list[str]:
    """Provider-category hints used only WITH the requested procedure.

    These fragments are never searched alone in procedure-aware full growth.
    They are combined with the requested procedure so we do not flood Places
    with unrelated dental / wellness / ENT / hospital businesses.
    """
    canonical = canonicalize_procedure(procedure)
    mapping = {
        "botox": [
            "dental clinic",
            "cosmetic dentist",
            "wellness clinic",
            "medical spa",
            "dermatology clinic",
            "skin clinic",
        ],
        "filler": [
            "dermatology clinic",
            "skin clinic",
            "aesthetic clinic",
            "plastic surgery clinic",
        ],
        "chemical_peel": [
            "dermatology clinic",
            "skin clinic",
            "medical spa",
            "aesthetic clinic",
        ],
        "hair_transplant": [
            "dermatology clinic",
            "plastic surgery clinic",
            "medical center",
        ],
        "rhinoplasty": [
            "ENT clinic",
            "plastic surgery clinic",
            "cosmetic surgery clinic",
            "medical center",
        ],
        "breast_augmentation": [
            "plastic surgery clinic",
            "cosmetic surgery clinic",
            "medical center",
        ],
    }
    return list(mapping.get(canonical, [
        "aesthetic clinic",
        "medical aesthetics",
        "dermatology clinic",
        "medical spa",
    ]))



class GooglePlacesClient:
    def __init__(self):
        self.api_key = os.getenv("GOOGLE_PLACES_API_KEY", "").strip()
        self.timeout = float(os.getenv("GOOGLE_PLACES_TIMEOUT_SECONDS", "10"))
        self.last_status = 0
        self.last_error = ""
        self.results_total = 0
        self.results_with_website = 0
        self.requests_attempted = 0
        self.requests_succeeded = 0
        self.quota_blocked = False
        self.queries_used: list[str] = []

    @property
    def configured(self):
        return bool(self.api_key)

    async def _search(self, query: str, max_results: int | None = None):
        global _PLACES_COOLDOWN_UNTIL, _PLACES_COOLDOWN_REASON

        if not self.configured:
            self.last_error = "GOOGLE_PLACES_API_KEY is missing"
            return []

        if time.monotonic() < _PLACES_COOLDOWN_UNTIL:
            self.quota_blocked = True
            self.last_status = 429
            self.last_error = _PLACES_COOLDOWN_REASON or "Google Places temporarily paused after quota/rate-limit error"
            return []

        if max_results is None:
            max_results = int(os.getenv("GOOGLE_PLACES_MAX_RESULTS_PER_QUERY", "20"))
        max_results = max(1, min(int(max_results), 20))
        self.requests_attempted += 1

        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                r = await client.post(
                    "https://places.googleapis.com/v1/places:searchText",
                    headers={
                        "X-Goog-Api-Key": self.api_key,
                        "X-Goog-FieldMask": (
                            "places.id,places.displayName,places.formattedAddress,"
                            "places.websiteUri,places.rating,places.userRatingCount,"
                            "places.types,places.primaryType,places.businessStatus,places.addressComponents"
                        ),
                        "Content-Type": "application/json",
                    },
                    json={"textQuery": query, "maxResultCount": max_results},
                )

            self.last_status = r.status_code

            if r.status_code >= 400:
                try:
                    payload = r.json()
                    self.last_error = str(
                        payload.get("error", {}).get("message")
                        or payload.get("error")
                        or r.text
                    )[:500]
                except Exception:
                    self.last_error = (r.text or f"HTTP {r.status_code}")[:500]

                # Do not continue hammering Text Search after a 429. The
                # cooldown is process-wide so expanded/deep rounds also stop.
                if r.status_code == 429:
                    self.quota_blocked = True
                    cooldown = max(60, int(os.getenv("GOOGLE_PLACES_429_COOLDOWN_SECONDS", "600")))
                    _PLACES_COOLDOWN_UNTIL = time.monotonic() + cooldown
                    _PLACES_COOLDOWN_REASON = self.last_error
                return []

            self.requests_succeeded += 1
            self.last_error = ""
            rows = r.json().get("places") or []
            self.results_total += len(rows)
            self.results_with_website += sum(1 for p in rows if str(p.get("websiteUri") or "").strip())
            return rows

        except Exception as exc:
            self.last_status = 0
            self.last_error = str(exc)[:500]
            return []

    async def discover_city_clinic_websites(
        self,
        city: str,
        language: str,
        procedure: str = "",
        max_websites: int = 40,
        max_queries: int | None = None,
    ) -> list[SearchHit]:
        """Discover public clinic websites for the city.

        Normal discovery remains city-wide. Explicit full-growth may also pass
        a procedure so provider categories such as dental, wellness,
        dermatology, ENT or plastic surgery can be explored. Google Places is
        identity/discovery only; it never supplies trusted price evidence.
        """
        if not self.configured:
            return []

        if max_queries is None:
            max_queries = int(os.getenv("GOOGLE_PLACES_CITY_QUERY_BUDGET", "2"))
        max_queries = max(1, min(int(max_queries), 8))

        queries = places_bootstrap_queries(city, language, procedure)
        self.queries_used = list(queries[:max_queries])
        min_reviews = int(os.getenv("GOOGLE_PLACES_MIN_REVIEWS", "5"))
        candidates: dict[str, SearchHit] = {}

        for query in queries[:max_queries]:
            rows = await self._search(query)
            if self.quota_blocked and not rows:
                break

            for p in rows:
                if str(p.get("businessStatus") or "").upper() != "OPERATIONAL":
                    continue
                address = str(p.get("formattedAddress") or "")
                website = str(p.get("websiteUri") or "").strip()
                name = str((p.get("displayName") or {}).get("text") or "").strip()
                rating = p.get("rating")
                review_count = p.get("userRatingCount")
                place_id = str(p.get("id") or "").strip()

                if not website or not name:
                    continue
                if not address_matches_search_city(address, city):
                    continue
                reviews = review_count if isinstance(review_count, int) else 0
                if reviews < min_reviews:
                    continue
                host = host_of(website)
                # Places can return Instagram/Facebook as a website; those are
                # not persisted as official clinic websites.
                if not host or bad_host(website) or classify_source(website) != "official_clinic":
                    continue

                hit = SearchHit(
                    title=name,
                    url=website,
                    snippet=address,
                    query=f"google_places_city:{query}",
                    place_id=place_id,
                    place_name=name,
                    place_address=address,
                    place_rating=rating,
                    place_user_rating_count=review_count,
                    place_types=[str(x) for x in (p.get("types") or [])],
                    place_primary_type=str(p.get("primaryType") or ""),
                )
                prev = candidates.get(host)
                if prev is None or (reviews, (rating or 0)) > ((prev.place_user_rating_count or 0), (prev.place_rating or 0)):
                    candidates[host] = hit

        ranked = sorted(
            candidates.values(),
            key=lambda h: (-(h.place_user_rating_count or 0), -(h.place_rating or 0), fold(h.title)),
        )
        return ranked[:max_websites]

    async def resolve_country_for_city(self, city: str) -> str:
        if not self.configured or not city.strip():
            return ""
        rows = await self._search(city, max_results=3)
        for place in rows:
            for component in place.get("addressComponents", []):
                if "country" in component.get("types", []):
                    code = str(component.get("shortText") or "").upper()
                    if code in vertical_search.CATALOG.countries:
                        return code
            resolved = vertical_search.CATALOG.country_from_address(str(place.get("formattedAddress") or ""))
            if resolved:
                return resolved
            f = fold(str(place.get("formattedAddress") or ""))
            known = {
                "albania": "AL", "romania": "RO", "bulgaria": "BG",
                "italy": "IT", "turkey": "TR", "france": "FR",
                "spain": "ES", "germany": "DE", "united kingdom": "GB",
                "united states": "US", "united arab emirates": "AE",
            }
            for country_name, code in known.items():
                if country_name in f:
                    return code
        return ""

    async def resolve_clinic(self, clinic_name: str, city: str, source_url: str) -> PlaceIdentity | None:
        # Disabled by default because doing one Places Text Search per page is
        # expensive and unnecessary once the city clinic directory exists.
        if not self.configured or not env_bool("ENABLE_PLACES_IDENTITY_LOOKUP", False):
            return None
        queries = []
        if clinic_name.strip():
            queries.append(f"{clinic_name} {city}")
        brand = domain_brand(source_url)
        if brand and brand.lower() != clinic_name.lower():
            queries.append(f"{brand} {city}")
        for q in queries[:1]:
            rows = await self._search(q, max_results=5)
            for p in rows:
                address = str(p.get("formattedAddress") or "")
                if not city_in_text(address, city):
                    continue
                return PlaceIdentity(
                    name=str((p.get("displayName") or {}).get("text") or clinic_name).strip(),
                    formatted_address=address,
                    website=str(p.get("websiteUri") or ""),
                    rating=p.get("rating"),
                    user_rating_count=p.get("userRatingCount"),
                    place_id=str(p.get("id") or ""),
                    city_match=True,
                )
        return None


# ============================================================
# Price extraction
# ============================================================

CURRENCY_PATTERNS = {
    "AED": r"(?:\bAED\b|\bDhs?\b|د\.?\s*إ\.?|درهم)",
    "SAR": r"(?:\bSAR\b|ر\.?\s*س\.?)",
    "QAR": r"(?:\bQAR\b|ر\.?\s*ق\.?)",
    "KWD": r"(?:\bKWD\b|د\.?\s*ك\.?)",
    "BHD": r"(?:\bBHD\b|د\.?\s*ب\.?)",
    "OMR": r"(?:\bOMR\b|ر\.?\s*ع\.?)",
    "CAD": r"(?:\bCAD\b|C\$|Can\$)",
    "AUD": r"(?:\bAUD\b|A\$|AU\$)",
    "NZD": r"(?:\bNZD\b|NZ\$)",
    "HKD": r"(?:\bHKD\b|HK\$)",
    "SGD": r"(?:\bSGD\b|S\$)",
    "BRL": r"(?:\bBRL\b|R\$)",
    "MXN": r"(?:\bMXN\b|Mex\$)",
    "PLN": r"(?:\bPLN\b|zł)",
    "CZK": r"(?:\bCZK\b|Kč)",
    "KRW": r"(?:\bKRW\b|₩|원)",
    "INR": r"(?:\bINR\b|₹)",
    "THB": r"(?:\bTHB\b|฿)",
    "EUR": r"(?:€|\bEUR\b|\bEU\b|\beuros?\b)",
    "GBP": r"(?:£|\bGBP\b)",
    "USD": r"(?:\$|\bUSD\b)",
    "ALL": r"(?:\bALL\b|\bLek(?:ë|e)?\b)",
    "RON": r"(?:\bRON\b|\blei\b)",
    "BGN": r"(?:\bBGN\b|\bлв\b)",
    "TRY": r"(?:\bTRY\b|\bTL\b|₺)",
    # Hungarian menus write 68.000 Ft. Without this, only a stray $ is read.
    "HUF": r"(?:\bHUF\b|\bFt\b|\bforint(?:ot)?\b)",
}

# Explicit ISO codes used by the worldwide Flutter locale table. Symbols
# shared by several currencies are not guessed from the city.
for _iso_code in (
    "CHF JPY CNY MYR IDR CLP SEK NOK DKK ZAR MDL MKD RSD UAH ISK "
    "KZT AZN AMD GEL BDT PKR NGN KES PHP TWD VND EGP JOD LBP IQD "
    "TND DZD UYU DOP GTQ BOB PYG CRC HNL"
).split():
    CURRENCY_PATTERNS[_iso_code] = rf"\b{_iso_code}\b"
for _iso_code in ("PEN", "COP", "ARS", "BAM", "MAD"):
    CURRENCY_PATTERNS[_iso_code] = rf"(?-i:\b{_iso_code}\b)"

# Load worldwide recognition from config, without inferring a currency from
# the search city's official currency. Existing carefully tuned symbols stay.
for _alias, _code in vertical_search.CATALOG.currency_aliases().items():
    if _code not in CURRENCY_PATTERNS:
        CURRENCY_PATTERNS[_code] = rf"(?-i:\b{re.escape(_code)}\b)"
    if len(_alias) >= 3 and _alias != _code and _alias not in {"dollar", "dollars"}:
        CURRENCY_PATTERNS[_code] += rf"|(?<!\w){re.escape(_alias)}(?!\w)"

MIN_PLAUSIBLE = {
    "EUR": 10, "GBP": 10, "USD": 10,
    "ALL": 500, "RON": 20, "BGN": 10, "TRY": 100,
    "HUF": 2000,
    "AED": 10, "SAR": 10, "QAR": 10, "KWD": 1, "BHD": 1, "OMR": 1,
}

MAX_PLAUSIBLE = {
    "EUR": 100000, "GBP": 100000, "USD": 150000,
    "ALL": 20_000_000, "RON": 1_000_000,
    "BGN": 500_000, "TRY": 5_000_000,
    "HUF": 50_000_000,
    "AED": 1_000_000, "SAR": 1_000_000, "QAR": 1_000_000,
    "KWD": 100_000, "BHD": 100_000, "OMR": 100_000,
    "JPY": 50_000_000, "KRW": 500_000_000, "IDR": 500_000_000,
    "VND": 500_000_000, "INR": 20_000_000, "CLP": 100_000_000,
    "COP": 500_000_000, "PKR": 50_000_000,
}

AMOUNT_TOKEN = r"(?:\d{1,3}(?:[.\s,]\d{3})+(?:[.,]\d{2})?|\d{1,6}(?:[.,]\d{1,2})?)"

_CURRENCY_MATCHERS = [(code, re.compile(pattern, re.I))
                      for code, pattern in CURRENCY_PATTERNS.items()]
_CURRENCY_ALT = "|".join(f"(?:{p})" for p in CURRENCY_PATTERNS.values())
_PRICE_MATCHERS = [
    re.compile(rf"(?P<currency>{_CURRENCY_ALT})\s*(?P<amount>{AMOUNT_TOKEN})(?!\d|[.,]\d)", re.I),
    re.compile(rf"(?<![\w.,])(?P<amount>{AMOUNT_TOKEN})\s*(?P<currency>{_CURRENCY_ALT})", re.I),
]


def to_num(raw: str):
    s = raw.replace("\u00a0", " ").replace(" ", "").strip()

    if re.fullmatch(r"\d{1,3}([.,]\d{3})+", s):
        return float(re.sub(r"[.,]", "", s))

    if re.fullmatch(r"\d{1,3}(?:[.,]\d{3})+[.,]\d{2}", s):
        split = max(s.rfind(","), s.rfind("."))
        return float(re.sub(r"[.,]", "", s[:split]) + "." + s[split + 1:])

    if "," in s and "." not in s:
        parts = s.split(",")
        s = s.replace(",", ".") if len(parts[-1]) <= 2 else s.replace(",", "")
    else:
        s = s.replace(",", "")

    try:
        return float(s)
    except Exception:
        return None


def currency_of(text: str) -> str:
    for code, pattern in _CURRENCY_MATCHERS:
        if pattern.search(text):
            return code
    return ""


def plausible(amount: float, currency: str) -> bool:
    return (
        MIN_PLAUSIBLE.get(currency, 10)
        <= amount
        <= MAX_PLAUSIBLE.get(currency, 200000)
    )


def procedure_negated(text: str, procedure: str) -> bool:
    if canonicalize_procedure(procedure) != "filler":
        return False

    t = fold(text)

    patterns = [
        r"\bno\s+(?:dermal\s+)?fillers?\b",
        r"\bwithout\s+(?:dermal\s+)?fillers?\b",
        r"\bnot\s+(?:a\s+)?filler\b",
    ]

    if not any(re.search(p, t) for p in patterns):
        return False

    cleaned = t
    for p in patterns:
        cleaned = re.sub(p, " ", cleaned)

    # If a positive injectable treatment remains, don't reject.
    return not injectable_filler_match(cleaned)


FILLER_AREA_TERMS = (
    ("lip", ("lip", "lips", "lip augmentation", "buze", "buzesh", "labbra", "labios", "labial", "levres")),
    ("cheek", ("cheek", "cheeks", "malar", "pometi", "pomulos", "mejillas")),
    ("jaw", ("jawline", "jaw", "mandibula", "mandibular")),
    ("chin", ("chin", "menton", "mento", "barbilla", "mental filler")),
    ("tear", ("tear trough", "under eye", "under-eye", "ojeras", "cearcane")),
    ("nose", ("rhinofiller", "nose filler", "nasal filler", "rinomodelacion")),
    ("nasolabial", ("nasolabial",)),
)
_FILLER_AREA_PATTERNS = tuple((key, re.compile(
    r"(?<!\w)(?:" + "|".join(re.escape(fold(term)) for term in terms) + r")(?!\w)",
)) for key, terms in FILLER_AREA_TERMS)


def requested_filler_areas(procedure: str) -> set[str]:
    """Areas named by the request. A generic filler request names none."""
    folded = fold(procedure)
    found = set()
    for key, pattern in _FILLER_AREA_PATTERNS:
        if pattern.search(folded):
            found.add(key)
    return found


def filler_area_conflict(procedure: str, text: str) -> bool:
    """True when the request names one filler area and the line names another."""
    wanted = requested_filler_areas(procedure)
    if len(wanted) != 1:
        return False
    present = requested_filler_areas(text)
    if not present:
        return False
    return wanted.isdisjoint(present)


def contains_requested_procedure(text: str, procedure: str) -> bool:
    canonical = canonicalize_procedure(procedure)

    if canonical == "filler":
        # This is intentionally stricter than alias matching.
        # "hyaluronic acid" in skincare is NOT dermal filler.
        # A lip-filler request does not accept a cheek-only line.
        if filler_area_conflict(procedure, text):
            return False
        return injectable_filler_match(text)

    folded = fold(text)
    if canonical == "hair_transplant" and (
        "hair removal" in folded or "laser hair" in folded
    ):
        return False
    if canonical == "laser_hair_removal" and (
        "transplant" in folded or re.search(r"\b(?:fue|dhi)\b", folded)
    ) and "hair removal" not in folded and "laser hair" not in folded:
        return False

    return any(fold(a) in folded for a in aliases_for(procedure))


def first_procedure_position(text: str, procedure: str) -> int:
    """Return the earliest explicit treatment-label position."""
    t = fold(text)
    terms = (
        INJECTABLE_FILLER_POSITIVE + brands_for(procedure)
        if canonicalize_procedure(procedure) == "filler"
        else aliases_for(procedure)
    )
    positions = []
    for term in terms:
        pos = t.find(fold(term))
        if pos >= 0:
            positions.append(pos)
    return min(positions) if positions else -1



BOTOX_NONINJECTABLE_PATTERNS = [
    r"\banti[ -]?frizz\b",
    r"\b(?:anti[ -]?)?encresp\w*\b",
    r"\bbotox\s+(?:capilar|capillaire)\b",
    r"\bbotox[\s-]*like\b",
    r"\bhair\s+botox\b",
    r"\bbotox\s+hair\b",
    r"\bcapillary\s+botox\b",
    r"\bbotox\s+brow\s+lamination\b",
    r"\bbrow\s+lamination\b",
    r"\bbotox\s+lash\s+lift\b",
    r"\blash\s+lift\b",
    r"\blash(?:es)?\s+botox\b",
    r"\bbotox\s+lash(?:es)?\b",
    r"\bhair\s+salon\b",
    r"\b(?:peluqueria|perruqueria|coiffeur|kapper|kappers)\b",
    r"\bsalon\s+de\s+coiffure\b",
    r"\bbrazilian\s+keratin\b",
]


def botox_noninjectable_context(text: str) -> bool:
    """Reject cosmetic/hair products that use the word Botox but are not injections."""
    t = fold(text)
    if "botox" not in t and "botulin" not in t:
        return False

    if any(re.search(p, t, re.I) for p in BOTOX_NONINJECTABLE_PATTERNS):
        return True

    # Brow/lash hydration or regeneration products are not botulinum toxin.
    beauty_appendage = any(
        token in t
        for token in [
            "eyelash", "eyelashes", "lashes", "lash",
            "qerpik", "vetull", "brow lamination",
        ]
    )
    product_language = any(
        token in t
        for token in [
            "hydrating", "hidrat", "regenerat", "nourish",
            "strengthen", "forcim", "qimeve", "product",
        ]
    )
    return beauty_appendage and product_language


def nearest_heading_context(node) -> str:
    """Return the nearest preceding heading for list/card evidence."""
    if node is None:
        return ""

    try:
        heading = node.find_previous(["h1", "h2", "h3", "h4", "h5", "h6"])
    except Exception:
        heading = None

    if heading is None:
        return ""

    text = " ".join(heading.stripped_strings).strip()
    return text[:180]


def contextual_block_text(node, text: str) -> str:
    heading = nearest_heading_context(node)
    if not heading:
        return text

    ft = fold(text)
    fh = fold(heading)
    if fh and fh in ft:
        return text

    return f"{heading} | {text}".strip()


def requested_procedure_spans(text: str, procedure: str) -> list[tuple[int, int]]:
    spans = []
    terms = aliases_for(procedure)
    if canonicalize_procedure(procedure) == "filler":
        terms = [*terms, *INJECTABLE_FILLER_POSITIVE]
    for alias in terms:
        a = fold(alias)
        if not a:
            continue
        rx = re.compile(r"(?<!\w)" + re.escape(a) + r"(?!\w)", re.I)
        spans.extend((m.start(), m.end()) for m in rx.finditer(fold(text)))
    return sorted(set(spans))


def other_procedure_between(
    text: str,
    start: int,
    end: int,
    procedure: str,
) -> bool:
    if end <= start:
        return False

    requested = canonicalize_procedure(procedure)
    segment = fold(text)[start:end]

    for canonical, spec in PROCEDURES.items():
        if canonical == requested:
            continue
        for alias in spec.get("aliases", []):
            a = fold(alias)
            if not a or len(a) < 4:
                continue
            if re.search(r"(?<!\w)" + re.escape(a) + r"(?!\w)", segment, re.I):
                return True
    return False


def procedure_unit_of(text: str, procedure: str) -> str:
    unit = unit_of(text)
    if canonicalize_procedure(procedure) == "botox":
        # Botox prices should never inherit filler syringe-volume units.
        if unit == "ml" or unit.endswith(" ml"):
            return "procedure"
    return unit


def botox_variant_detail(
    raw: str,
    raw_price_text: str = "",
) -> str:
    f = fold(raw)

    variants = [
        ("Baby Botox", ["baby botox", "botox per bebe", "botox për bebe"]),
        ("Full Botox", ["full botox"]),
        ("Full face", ["full face", "upper and lower face"]),
        ("Three areas", ["3 areas", "three areas", "three ageing zones", "3 zonas", "tres zonas",
                         "frente + entrecejo + patas de gallo", "forehead + glabella + crow's feet"]),
        ("Single area", ["1 area", "one area", "single area", "one zone"]),
        ("Crow's feet", ["patas de gallo"]),
        ("Glabella", ["entrecejo"]),
        ("Forehead", ["en la frente"]),
        ("Upper face / forehead / glabella / eyes", [
            "full upper face", "upper face",
            "forehead, interbrow, eyes", "forehead", "interbrow",
            "glabella", "crow's feet", "crows feet",
            "balli", "ndermjet vetulla", "ndërmjet vetulla",
        ]),
        ("Masseter / bruxism", [
            "masseter", "massette", "bruxism", "bruksiz",
            "jaw tightening", "face slimming",
        ]),
        ("Add-on area", [
            "eyebrow lift", "lip flip", "bunny", "mesobotox",
            "gummy smile",
            "trapezius", "tip of the nose", "nose tip",
            "corner of the mouth", "corner of lip",
            "additional selected",
        ]),
        ("Axillary / hyperhidrosis", [
            "axillar", "axillary", "hyperhidrosis", "hiperhidro",
            "antiperspirant",
        ]),
        ("Migraine", ["migraine", "migraines", "migrena", "migrenës", "headaches"]),
        ("Fox eyes", ["fox eyes", "sytë e dhelprës", "syte e dhelpres"]),
        ("Nose", ["narrowing of the nose", "nose botox", "ngushtimi i hund"]),
        ("Upper lip", ["upper lip", "buza e siperme", "buza e sipërme"]),
        ("Neck / chin", ["neck and chin", "neck", "chin", "qafa", "mjekra"]),
    ]

    price_pos = -1
    if raw_price_text:
        price_pos = f.find(fold(raw_price_text))

    candidates = []
    for label, terms in variants:
        for term in terms:
            t = fold(term)
            pos = f.find(t)
            if pos < 0:
                continue

            if price_pos >= 0:
                # The label has to sit immediately before this price. A later
                # menu row, or a price that falls between them, is a different
                # treatment.
                if pos > price_pos:
                    continue
                distance = price_pos - (pos + len(t))
                if distance > 72:
                    continue
                between = f[pos + len(t):price_pos]
                if list(iter_exact_price_matches(between)):
                    continue
                candidates.append((distance, label))
            else:
                candidates.append((pos, label))

    if not candidates:
        return ""

    candidates.sort(key=lambda x: x[0])
    return candidates[0][1]


def botox_nonprimary_variant(
    detail: str,
    raw: str = "",
    unit: str = "",
) -> bool:
    """A smaller or different Botox line is not the standard treatment price.

    Baby Botox, neck, fox eyes, and a per-vial charge stay off a generic
    Botox card. Full Botox and the upper-face zones stay on it.
    """
    folded_unit = fold(unit or "")
    if folded_unit in {"vial", "flacon", "fiala", "syringe"}:
        return True

    folded_raw = fold(raw or "")
    if "baby botox" in folded_raw or "botox per bebe" in folded_raw:
        return True
    if re.search(r"(?:/\s*shishe\b|\bper\s+shishe\b)", folded_raw):
        return True

    folded_detail = fold(detail or "")
    nonprimary = (
        "baby botox",
        "masseter",
        "bruxism",
        "face slimming",
        "axillar",
        "axillary",
        "hyperhidrosis",
        "migraine",
        "migrena",
        "fox eyes",
        "upper lip",
        "neck",
        "add-on",
        "mesobotox",
    )
    if folded_detail and any(term in folded_detail for term in nonprimary):
        return True
    if folded_detail == "nose":
        return True

    if not folded_detail:
        if "baby botox" in folded_raw or "botox per bebe" in folded_raw:
            return True
        if re.search(r"\bqafes\b", folded_raw):
            return True
    return False


BOTOX_MEDICAL_INDICATIONS = (
    "rectal fissure",
    "anal fissure",
    "hemorrhoid",
    "haemorrhoid",
    "rectal abscess",
    "overactive bladder",
    "achalasia",
    "strabismus",
    "cervical dystonia",
    "blepharospasm",
    "hemifacial spasm",
)


def botox_medical_indication(text: str) -> bool:
    """A medical use of the toxin is not a cosmetic anti-wrinkle price."""
    folded = fold(text or "")
    return any(term in folded for term in BOTOX_MEDICAL_INDICATIONS)


def botox_result_is_trusted(row: ClinicPriceResult) -> bool:
    if row.procedure_canonical != "botox":
        return True

    if botox_noninjectable_context(row.raw_evidence):
        return False
    if botox_medical_indication(
        f"{row.procedure_detail} {row.raw_evidence}"
    ):
        return False

    unit = fold(row.unit or "")
    if unit == "ml" or unit.endswith(" ml"):
        return False

    # A vial, a baby dose, or an unrelated medical indication is not the
    # standard cosmetic Botox price. These rows can remain discovery leads.
    if botox_nonprimary_variant(row.procedure_detail, row.raw_evidence, row.unit):
        return False
    detail = fold(row.procedure_detail or "")
    raw = fold(row.raw_evidence or "")
    non_cosmetic = (
        "hyperhidrosis", "iperidrosi", "iperhidroza", "migraine",
        "migrena", "bruxism", "bruxismo", "axillar", "axillary",
    )
    if any(term in detail for term in non_cosmetic):
        return False
    if any(term in raw for term in non_cosmetic) and not detail:
        # A multi-service page without a bound cosmetic treatment label is
        # ambiguous even if the page also mentions cosmetic Botox elsewhere.
        return False

    # Legacy broad evidence often mixed several services and had no usable
    # Botox variant/detail. Re-discover it rather than trusting stale binding.
    prices = list(iter_exact_price_matches(row.raw_evidence or ""))
    if len(prices) >= 2 and not (row.procedure_detail or "").strip():
        return False

    return True


def price_is_bound_to_procedure(
    text: str,
    price_match,
    procedure: str,
    method: str,
) -> bool:
    """
    Bind a price to the closest requested treatment and prevent section leakage.
    """
    proc_pos = first_procedure_position(text, procedure)
    if proc_pos < 0:
        return False

    # Table rows can legitimately put the price column before the service column.
    if method == "table_row":
        return True

    if method == "whatclinic_service_pair":
        return abs(proc_pos - price_match.start()) <= 220

    spans = requested_procedure_spans(text, procedure)
    preceding = [
        span
        for span in spans
        if span[0] <= price_match.start()
    ]

    if not preceding:
        return False

    nearest = max(preceding, key=lambda s: s[0])

    # A distant treatment heading should not own arbitrary later prices.
    if price_match.start() - nearest[1] > 360:
        return False
    # Once a label has its amount, a later amount cannot inherit that label
    # through an unrelated treatment the canonical alias list does not know.
    # Explicit old/current promotion pairs keep their current amount.
    earlier_prices = list(iter_exact_price_matches(text[nearest[1]:price_match.start()]))
    if earlier_prices and promo_price_for_match(text, price_match) is None:
        return False

    # If another canonical procedure begins between the requested treatment and
    # this price, the price belongs to that later section instead.
    if other_procedure_between(
        text,
        nearest[1],
        price_match.start(),
        procedure,
    ):
        return False

    return True


def botox_amount_owned_by_filler(text: str, amount: float, currency: str) -> bool:
    """A Botox heading after a filler amount cannot relabel that amount."""
    prices = list(iter_exact_price_matches(text or ""))
    conflicts = 0
    for index, (match, value, code) in enumerate(prices):
        if code != currency or abs(value - amount) > .011:
            continue
        start = prices[index - 1][0].end() if index else 0
        prefix = fold(text[start:match.start()])
        toxin = list(re.finditer(r"\b(?:botox|botulin\w*|neuromodula[td]\w*)\b", prefix))
        filler = list(re.finditer(r"\b(?:hyaluronic\s+acid|acid[ou]\s+hialuronic[ou]?|fillers?|"
                                  r"skin[ -]?boosters?|mesotherap\w*|mesoterapia|nctf|hifu)\b", prefix))
        if toxin and (not filler or toxin[-1].start() > filler[-1].start()):
            return False
        if filler:
            conflicts += 1
    return conflicts > 0


def unit_of(text: str) -> str:
    t = fold(text)
    if re.search(r"\b(?:botox|dysport|xeomin|nabota|botulin\w*|toxin\w*)\b.{0,30}\(\s*1\s+units?\s*\)", t):
        return "unit"
    if re.search(r"\bper\s+grafts?\b|/\s*grafts?\b", t):
        return "graft"
    m = re.search(r"\b(\d+(?:[.,]\d+)?)\s*ml\b", t)

    if m:
        return f"{m.group(1).replace(',', '.')} ml"

    if re.search(
        r"\bper\s*(?:vial|fiala|fiale|ampoule|shishe)\b"
        r"|/\s*(?:vial|fiala|fiale|ampoule|shishe)\b",
        t,
    ):
        return "vial"
    if re.search(r"\bper\s*syringe\b|/\s*syringe\b", t):
        return "syringe"
    if re.search(r"\bper\s*ml\b|/\s*ml\b", t):
        return "ml"
    if re.search(r"\bper\s*area\b|/\s*area\b", t):
        return "area"
    if re.search(r"\bper\s*unit\b|/\s*unit\b", t):
        return "unit"
    if re.search(r"\bper\s*session\b|/\s*session\b", t):
        return "session"

    return "procedure"


def qualifier(text: str, lo: float, hi: float | None) -> str:
    t = fold(text)

    # Approximation must describe this monetary amount. A nearby approximate
    # duration or dosage must not qualify an otherwise exact tariff.
    for match, amount, _ in iter_exact_price_matches(text):
        if abs(amount - lo) > .011:
            continue
        prefix = fold(text[max(0, match.start() - 110):match.start()])
        if re.search(
            r"\b(?:approximately|approx\.?|roughly|around|about|circa|"
            r"aproximad[oa]|aproximadamente|aproximativ|alrededor\s+de|"
            r"(?:suele\s+)?rondar?|en\s+torno\s+a)\b[^\d]{0,100}$", prefix,
        ):
            return "approximate"

    # If extraction found two attached numeric endpoints, this is a real range
    # even when the surrounding phrase says "range from X to Y".
    if hi is not None and hi > lo:
        return "range"

    if any(re.match(r"\s*\+", text[m.end():])
           for m, value, _ in iter_exact_price_matches(text)
           if abs(value - lo) < .011):
        return "from"

    if re.search(
        r"\b(from|starting from|starts from|de la|desde|a partir|nga|fillon nga|ab)\b",
        t,
    ) or re.search(r"\b(?:starting|starts?)\s+(?:at|price|cost)\b|\b(?:aed|eur|usd|gbp|ron)\s+starts?\b", t) or re.search(r"\b(?:a\s+partire\s+da|da)\s*(?:€|eur|euro)?\s*\d", t):
        return "from"
    if re.search(r"\b(?:huf|ft|forint)\s*-?\s*t(?:ol|el)\b", t):
        return "from"

    return "exact"


def filler_volume_is_retail_like(text: str) -> bool:
    """A clinic syringe (1 ml, 2 ml) is not a shop SKU.

    Reject only an explicit purchase: box of, pack of, buy online, cart.
    """
    t = fold(text)
    return any(term in t for term in (
        "box of", "pack of", "buy online", "buy now", "add to cart",
        "shopping cart", "webshop", "raktaron", "kosarba",
    ))


def iter_exact_price_matches(text: str):
    # Compile global-currency patterns once, not for every DOM fragment.
    spans = []
    for pat in _PRICE_MATCHERS:
        for m in pat.finditer(text):
            amount = to_num(m.group("amount"))
            currency = currency_of(m.group(0))

            # "250 € 30 min" is EUR 250 followed by a duration. The
            # currency-first regex must not take the euro sign for EUR 30.
            if (m.start("currency") < m.start("amount")
                    and re.match(r"\s*(?:min(?:ute|uto)?s?|hrs?|hours?|horas?)\b",
                                 text[m.end():], re.I)):
                continue

            if amount is None or not currency:
                continue

            if not plausible(amount, currency):
                # A printed unit rate is not a session total. Keep small
                # graft rates only when the unit is attached to this amount.
                after = text[m.end():m.end() + 25]
                before = text[max(0, m.start() - 25):m.start()]
                graft_rate = (1 <= amount <= 50 and (
                    re.match(r'\s*(?:per\s+|/\s*)grafts?\b', after, re.I)
                    or re.search(r'\bper\s+grafts?\s*[:=]?\s*$', before, re.I)))
                if not graft_rate:
                    continue
            # In "€7000 €3500", the second € belongs to 3500. The
            # suffix pattern must not re-emit "7000 €" across that boundary.
            if any(not (m.end() <= start or m.start() >= end) for start, end in spans):
                continue
            spans.append(m.span())
            yield m, amount, currency


def price_amount_is_incentive(text: str, price_match) -> bool:
    """Reject a saving, voucher or gift value, not a discounted payable price.

    Scope the wording to this amount, so an unrelated promotion elsewhere on
    an official price menu cannot invalidate its actual treatment quote.
    """
    before = fold(re.split(r"[|;\n]", text[max(0, price_match.start() - 100):price_match.start()])[-1])
    after = fold(re.split(r"[|;\n]", text[price_match.end():price_match.end() + 100])[0])
    return bool(
        re.search(r"\b(?:save(?:\s+up\s+to)?|saving(?:s)?\s+(?:of|up\s+to)|"
                  r"(?:discount|gift|bonus)\s+(?:package|voucher)(?:\s+worth)?|"
                  r"(?:gift|bonus)\s+(?:value|worth)|kedvezmenycsomag|"
                  r"ajandek(?:csomag)?\s+erteke)\s*[:=-]?\s*$", before)
        or re.search(r"^\s*(?:worth\b.{0,65}\b(?:discount|gift|bonus)|"
                     r"(?:price\s+)?discount\b|off\b|erteku\b|"
                     r"(?:worth\s+)?(?:gift|bonus)\s+(?:package|voucher)|"
                     r"kedvezmeny(?:csomag)?\b)", after)
    )



def iter_descending_promo_pairs(text: str):
    """Yield old->new price pairs such as `nga 250 EU në 170 EU`.

    A descending explicit connector is treated as a promotion, not a numeric
    range. This is generic for sale/offer pages and preserves the original
    price separately.
    """
    matches = sorted(iter_exact_price_matches(text), key=lambda item: item[0].start())
    if len(matches) < 2:
        return

    for i in range(len(matches) - 1):
        m1, a1, c1 = matches[i]
        m2, a2, c2 = matches[i + 1]

        if c1 != c2 or a2 >= a1:
            continue

        between = fold(text[m1.end():m2.start()])
        around = fold(
            text[
                max(0, m1.start() - 90):
                min(len(text), m2.end() + 90)
            ]
        )

        connector = bool(
            re.search(
                r"(?:\bto\b|\bne\b|\bnë\b|→|->|=>)",
                between,
                re.I,
            )
        )
        # Clinic menus print the crossed-out list price then the current
        # price with nothing between them: "€ 8000 € 3800".
        # A starting-price qualifier can be repeated on the current amount:
        # "from 8 750 EUR from 6 100 EUR". It does not name another service.
        bare_pair = bool(re.fullmatch(
            r"\s*(?:(?:from|starting\s+from|starts?\s+from|de\s+la|desde|"
            r"a\s+partir\s+de|a\s+partire\s+da|nga|ab)\s*)?[€$£\s]*",
            between or "",
        ))
        promo_signal = any(
            token in around
            for token in [
                "promo", "promotion", "offer", "ofert",
                "discount", "zbrit", "sale", "happy",
            ]
        )

        # A descending from/to pair is itself strong promo evidence; explicit
        # promo language makes the rule even safer.
        if not connector and not promo_signal and not bare_pair:
            continue

        yield m1, m2, a1, a2, c1


def promo_price_for_match(text: str, price_match):
    for old_m, new_m, old_price, new_price, currency in (
        iter_descending_promo_pairs(text) or []
    ):
        if (
            new_m.start() == price_match.start()
            and new_m.end() == price_match.end()
        ):
            return new_price, old_price, currency
    return None


def find_attached_range(text: str, currency: str, price_match) -> tuple[float, float] | None:
    """
    IMPORTANT:
    Only detects a range when the range itself is syntactically tied to the
    currency/price phrase. It never scans for an unrelated nearby numeric range.

    Accepts:
      €150–€200
      €150–200
      150–200 EUR
      150 EUR – 200 EUR

    Does NOT interpret:
      "€150 ... takes 20–30 minutes"
    as €20–€30.
    """
    curr_pat = CURRENCY_PATTERNS[currency]

    local = text[max(0, price_match.start() - 50): min(len(text), price_match.end() + 70)]

    patterns = [
        rf"\bentre\s+(?P<a>{AMOUNT_TOKEN})\s*(?:{curr_pat})?\s*(?:y|u|a)\s*(?P<b>{AMOUNT_TOKEN})\s*(?P<c>{curr_pat})",
        rf"(?P<c1>{curr_pat})\s*(?P<a>{AMOUNT_TOKEN})\s*(?:-|–|—|to|ile|ila)\s*(?:(?P<c2>{curr_pat})\s*)?(?P<b>{AMOUNT_TOKEN})",
        rf"(?<![\w.,])(?P<a>{AMOUNT_TOKEN})\s*(?:-|–|—|to|ile|ila)\s*(?P<b>{AMOUNT_TOKEN})\s*(?P<c>{curr_pat})",
        rf"(?<![\w.,])(?P<a>{AMOUNT_TOKEN})\s*(?P<c1>{curr_pat})\s*(?:-|–|—|to|a|ile|ila)\s*(?P<b>{AMOUNT_TOKEN})\s*(?P<c2>{curr_pat})",
        rf"(?:varia\s+tra|between|tra)\s+(?P<c1>{curr_pat})\s*(?P<a>{AMOUNT_TOKEN})\s*(?:e|and)\s*(?P<c2>{curr_pat})\s*(?P<b>{AMOUNT_TOKEN})",
    ]

    for pat in patterns:
        rm = re.search(pat, local, re.I)

        if not rm:
            continue

        # The detected range must contain the exact price token currently
        # being evaluated. Otherwise a nearby following service range can leak
        # backwards into the previous service price.
        local_start = max(0, price_match.start() - 50)
        range_start = local_start + rm.start()
        range_end = local_start + rm.end()

        if not (
            range_start <= price_match.start()
            and range_end >= price_match.end()
        ):
            continue

        a = to_num(rm.group("a"))
        b = to_num(rm.group("b"))

        if a is None or b is None:
            continue

        if not plausible(a, currency) or not plausible(b, currency):
            continue

        return min(a, b), max(a, b)

    return None


def ambiguous_multi_price_block(text: str, procedure: str) -> bool:
    """
    Reject rows/fragments with multiple unrelated price bands + comparison/saving
    signals because ownership/column semantics are unclear.

    Example:
      "Lip fillers €250–€300 per vial €400–€600 Up to 50%"
    """
    if not contains_requested_procedure(text, procedure):
        return False

    curr_alt = "|".join(f"(?:{p})" for p in CURRENCY_PATTERNS.values())

    attached_ranges = re.findall(
        rf"(?:{curr_alt})?\s*{AMOUNT_TOKEN}\s*(?:-|–|—|to)\s*(?:{curr_alt})?\s*{AMOUNT_TOKEN}\s*(?:{curr_alt})?",
        text,
        re.I,
    )

    t = fold(text)

    comparison = (
        "%" in text
        or "save" in t
        or "up to" in t
        or "compared" in t
        or "uk" in t
        or "italy" in t
        or "turkey" in t
    )

    return len(attached_ranges) >= 2 and comparison


def price_amount_is_financing(text: str, match) -> bool:
    """A monthly installment is not the price of the procedure."""
    after = fold((text or "")[match.end():match.end() + 70])
    before = fold((text or "")[max(0, match.start() - 70):match.start()])
    local = fold(priced_line_text(text, match=match))
    if (re.search(r"\b(?:financi\w*|credit\w*|prestamo|cuotas?|installments?|monthly\s+payment)\b", local)
            and re.search(r"\b(?:hasta|up\s+to|maximum|maximo)\s*(?:eur|usd|gbp|aed|€|£|\$)?\s*$", before)):
        return True
    return bool(re.match(
        r"\s*(?:/\s*(?:month|mo)\b|per\s+month\b|a\s+month\b|"
        r"(?:al|in)\s+mese\b|\blunare\b)", after,
    ) or re.search(
        r"(?:monthly\s+(?:payment|installment)|financ(?:ing|e)|rate\s+lunare)"
        r"(?:\s+(?:from|for|of|starting|at|da))?\s*$", before,
    ))


def price_amount_is_add_on(text: str, match) -> bool:
    return bool(re.match(r'\s+(?:as\s+(?:an?\s+)?)?add[- ]on\b',
                         (text or '')[match.end():match.end() + 50], re.I))


def add_evidence(
    out: list[ExtractedEvidence],
    seen: set,
    text: str,
    url: str,
    procedure: str,
    method: str,
):
    if injectable_scope_rejection(canonicalize_procedure(procedure),
            evidence=text, source_url=url):
        return
    if not contains_requested_procedure(text, procedure):
        return

    if procedure_negated(text, procedure):
        return

    if (
        canonicalize_procedure(procedure) == "botox"
        and botox_noninjectable_context(text)
    ):
        return

    if is_retail_evidence_block(text, procedure):
        return

    if filler_volume_is_retail_like(text):
        return

    if ambiguous_multi_price_block(text, procedure):
        return

    promo_pairs = list(iter_descending_promo_pairs(text) or [])
    promo_old_spans = {
        (old_m.start(), old_m.end())
        for old_m, _new_m, _old, _new, _currency in promo_pairs
    }

    for m, amount, currency in iter_exact_price_matches(text):
        if any(
            not (m.end() <= start or m.start() >= end)
            for start, end in promo_old_spans
        ):
            # Do not expose the crossed-out/original amount as a current price.
            # The same digits can match both "€ 8000" and "8000 €".
            continue

        if not price_is_bound_to_procedure(text, m, procedure, method):
            continue
        if price_amount_is_incentive(text, m):
            continue
        if price_amount_is_financing(text, m):
            continue
        if price_amount_is_add_on(text, m):
            continue
        if (canonicalize_procedure(procedure) == "botox"
                and botox_amount_owned_by_filler(text, amount, currency)):
            continue

        line = priced_line_text(text, match=m)
        if not contains_requested_procedure(line, procedure):
            continue
        if canonicalize_procedure(procedure) == "filler":
            first_price = next(iter_exact_price_matches(line), None)
            label = line[:first_price[0].start()] if first_price else line
            if filler_area_conflict(procedure, label) or surgical_chin_quote(line, url):
                continue
        # Breast rows stay extracted so implant and implant+lift remain
        # separate. Trust, not extraction, drops the combo from Compare.
        if (
            procedure_line_is_bundle(line, procedure)
            and canonicalize_procedure(procedure) != "breast_augmentation"
        ):
            continue
        window = line if line else text[max(0, m.start() - 180): min(len(text), m.end() + 220)]

        if procedure_negated(window, procedure):
            continue

        if canonicalize_procedure(procedure) == "filler":
            if not injectable_filler_match(window):
                continue
            if filler_volume_is_retail_like(window):
                continue

        promo = promo_price_for_match(text, m)
        attached = find_attached_range(text, currency, m)

        original_lo = None
        original_hi = None

        if promo:
            lo, original_lo, _promo_currency = promo
            hi = None
        elif attached:
            lo, hi = attached
        else:
            lo, hi = amount, None

        key = (
            round(lo, 2),
            round(hi or 0, 2),
            currency,
            fold(window),
        )

        if key in seen:
            continue

        seen.add(key)

        label = display_name(canonicalize_procedure(procedure))
        if canonicalize_procedure(procedure) in {"filler", "chemical_peel", "hair_transplant"}:
            label = tariff_price_row_name(window, procedure, m.group(0)) or label
        if canonicalize_procedure(procedure) == "breast_augmentation":
            bound = breast_price_row_text(text, m.group(0), lo, currency)
            if breast_row_is_other_surgery(bound):
                continue
            # Keep the literal priced label; the subtype must not come from
            # an adjacent lift, implant-replacement or fat-transfer row.
            first_price = next(iter_exact_price_matches(bound), None)
            listed = bound[:first_price[0].start()] if first_price else bound
            listed = re.sub(
                r"\s*(?:from|starting\s+from|starts?\s+from|de\s+la|nga|ab)\s*$",
                "", listed, flags=re.I,
            ).strip(" |·:;–-")
            if listed and len(listed) <= 160:
                label = listed
            window = bound

        out.append(
            ExtractedEvidence(
                raw_procedure_text=label,
                raw_price_text=m.group(0).strip(),
                price_min=lo,
                price_max=hi,
                currency=currency,
                unit=procedure_unit_of(window, procedure),
                qualifier=(
                    ("from" if qualifier(window, lo, hi) == "from" else "promo")
                    if promo
                    else qualifier(window, lo, hi)
                ),
                original_price_min=original_lo,
                original_price_max=original_hi,
                raw_evidence=window.strip(),
                source_url=url,
                extraction_method=method,
            )
        )




def _whatclinic_procedure_regexes(procedure: str) -> list[re.Pattern]:
    canonical = canonicalize_procedure(procedure)

    if canonical == "filler":
        terms = [
            "nasolabial filler", "marionette lines filler",
            "collagen dermal filler", "dermal fillers", "dermal filler",
            "lip fillers", "lip filler", "lip augmentation",
            "cheek filler", "chin filler", "jaw filler",
            "rhinofiller", "fillers", "filler",
        ]
    else:
        terms = sorted(set(aliases_for(procedure)), key=len, reverse=True)

    return [
        re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.I)
        for term in terms if term
    ]


def extract_whatclinic_targeted_text_evidence(
    text: str,
    url: str,
    procedure: str,
) -> list[ExtractedEvidence]:
    """Return only prices tightly attached to the requested treatment.

    A WhatClinic snippet/profile can contain multiple treatments and prices.
    Evidence is bounded at the next treatment label, so a generic Dermal
    Fillers price cannot inherit the following "Cheek Filler" label.
    """
    if not text:
        return []

    raw_spans = []
    for rx in _whatclinic_procedure_regexes(procedure):
        raw_spans.extend((m.start(), m.end()) for m in rx.finditer(text))

    # Prefer the longest label when aliases overlap, e.g. keep
    # "Cheek Filler" rather than the inner generic "Filler".
    ordered = sorted(
        set(raw_spans),
        key=lambda s: (s[0], -(s[1] - s[0])),
    )
    spans = []
    for span in ordered:
        if any(
            span[0] >= kept[0] and span[1] <= kept[1]
            for kept in spans
        ):
            continue
        spans.append(span)
    spans.sort()

    out: list[ExtractedEvidence] = []
    seen = set()

    for idx, (start, end) in enumerate(spans):
        next_start = (
            spans[idx + 1][0]
            if idx + 1 < len(spans)
            else min(len(text), end + 190)
        )

        # Search only until the next treatment label. This still leaves enough
        # room for attached ranges such as "10191 Lek - 27793 Lek".
        after = text[end:next_start]
        after_matches = list(iter_exact_price_matches(after))

        if after_matches:
            pm, _amount, _currency = after_matches[0]
            # Keep the whole bounded service fragment so find_attached_range()
            # can see the second endpoint, but never include the next service.
            block = text[start:next_start].strip(" .,:;-")
            add_evidence(
                out, seen, block, url, procedure, "whatclinic_service_pair"
            )
            continue

        # Some WhatClinic HTML layouts render the price immediately BEFORE
        # the heading. Bound this backwards to the previous treatment label.
        previous_end = spans[idx - 1][1] if idx > 0 else max(0, start - 120)
        before = text[previous_end:start]
        before_matches = list(iter_exact_price_matches(before))

        if before_matches:
            pm, _amount, _currency = before_matches[-1]

            # A previous price may be used only when it is directly adjacent
            # to the treatment heading. Search snippets often contain:
            #   "BBL from 504332 Lek. All Treatments ... Lip Filler"
            # and that BBL price must NEVER be attached to Lip Filler.
            gap = before[pm.end():]
            gap_compact = re.sub(r"[\s\W_]+", "", gap, flags=re.UNICODE)

            if gap_compact:
                # Any intervening word/digit means the price belongs to other
                # content, not to this treatment heading.
                continue

            # Also keep the adjacency small even if it is punctuation only.
            if len(gap) > 24:
                continue

            local_price_start = previous_end + pm.start()
            block_start = max(previous_end, local_price_start - 35)
            block = text[block_start:end].strip(" .,:;-")
            add_evidence(
                out, seen, block, url, procedure, "whatclinic_service_pair"
            )

    return out


def whatclinic_result_is_trusted(row: ClinicPriceResult) -> bool:
    host = row.source_host or host_of(row.source_url)
    if "whatclinic.com" not in host:
        return True

    if is_whatclinic_category_result(
        row.source_url,
        row.clinic_name,
        row.raw_evidence,
        row.city,
    ):
        return False

    if not is_probable_single_business_page(row.source_url):
        return False

    candidates = extract_whatclinic_targeted_text_evidence(
        row.raw_evidence,
        row.source_url,
        row.procedure_canonical,
    )

    if not candidates:
        return False

    def close(a, b):
        if a is None or b is None:
            return a is None and b is None
        return abs(float(a) - float(b)) < 0.01

    for e in candidates:
        if not close(e.price_min, row.price_min):
            continue
        if row.price_max is not None and not close(e.price_max, row.price_max):
            continue
        return True

    return False


def normalize_whatclinic_cached_result(
    row: ClinicPriceResult,
) -> ClinicPriceResult:
    """Repair legacy broad WhatClinic evidence without changing its price.

    Older rows could have a correct generic Dermal Fillers price but a broad
    `raw_evidence` containing the following Cheek/Chin/Jaw services. That made
    `procedure_detail()` assign the wrong anatomy. We locate the tightly-bound
    evidence fragment matching the already stored price and regenerate the
    derived fields from that fragment.
    """
    host = row.source_host or host_of(row.source_url)
    if "whatclinic.com" not in host:
        return row

    candidates = extract_whatclinic_targeted_text_evidence(
        row.raw_evidence,
        row.source_url,
        row.procedure_canonical,
    )

    def close(a, b):
        if a is None or b is None:
            return a is None and b is None
        return abs(float(a) - float(b)) < 0.01

    matches = []
    for e in candidates:
        if not close(e.price_min, row.price_min):
            continue
        if row.price_max is not None and not close(e.price_max, row.price_max):
            continue
        matches.append(e)

    if not matches:
        return row

    # The shortest matching fragment is normally the most specific service
    # block and least likely to include the next treatment.
    evidence = min(matches, key=lambda e: len(e.raw_evidence or ""))

    payload = row.model_dump()
    payload["raw_evidence"] = evidence.raw_evidence
    payload["raw_procedure_text"] = evidence.raw_procedure_text
    payload["procedure_detail"] = procedure_detail(
        evidence.raw_evidence,
        row.procedure_canonical,
    )
    payload["qualifier"] = (
        evidence.qualifier
        if evidence.qualifier and evidence.qualifier != "unknown"
        else row.qualifier
    )
    payload["unit"] = evidence.unit or row.unit

    return ClinicPriceResult.model_validate(payload)


async def firestore_normalize_whatclinic_results(
    city: str,
    procedure: str,
) -> int:
    """Persist corrected bounded evidence/details for active WhatClinic rows."""
    if not firestore_enabled():
        return 0

    def _normalize():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_results_collection_name())
        search_key = _search_key(city, procedure)

        try:
            docs = list(
                collection.where(
                    "search_key",
                    "==",
                    search_key,
                ).limit(200).stream()
            )
        except Exception:
            return 0

        changed = 0
        now = datetime.now(timezone.utc)

        for doc in docs:
            data = doc.to_dict() or {}
            if data.get("active") is False:
                continue

            raw = data.get("result")
            if not isinstance(raw, dict):
                continue

            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue

            row, range_normalized = normalize_cached_explicit_price_floor(row)
            if range_normalized:
                try:
                    doc.reference.set(
                        {
                            "result": row.model_dump(),
                            "price_floor_normalized_at": now,
                            "updated_at": now,
                        },
                        merge=True,
                    )
                except Exception:
                    pass

            if "whatclinic.com" not in (
                row.source_host or host_of(row.source_url)
            ):
                continue

            # Do not "repair" a row that fails the strict source/price checks.
            # The existing weak-row cleanup will deactivate it instead.
            if not whatclinic_result_is_trusted(row):
                continue

            normalized = normalize_whatclinic_cached_result(row)

            if normalized.model_dump() == row.model_dump():
                continue

            try:
                doc.reference.set(
                    {
                        "result": normalized.model_dump(),
                        "updated_at": now,
                    },
                    merge=True,
                )
                changed += 1
            except Exception:
                continue

        return changed

    try:
        return await asyncio.to_thread(_normalize)
    except Exception:
        return 0



def extract_whatclinic_service_price_evidence(
    html: str,
    url: str,
    procedure: str,
) -> list[ExtractedEvidence]:
    """Extract only treatment-level prices from an individual WhatClinic profile.

    WhatClinic can place the numeric price immediately *before* the treatment
    heading in the DOM. The generic forward-looking parser can miss that. This
    routine pairs the requested treatment heading only with its closest bounded
    previous/next siblings, preventing a generic page-level "prices from ..."
    value from being assigned to the treatment.
    """
    if "whatclinic.com" not in host_of(url):
        return []
    if not is_probable_single_business_page(url):
        return []
    if is_whatclinic_category_result(url):
        return []

    soup = BeautifulSoup(html or "", "lxml")
    for t in soup(["script", "style", "noscript"]):
        t.decompose()

    out: list[ExtractedEvidence] = []
    seen = set()

    service_headings = soup.find_all(["h2", "h3", "h4", "h5", "strong", "b"])
    # Current provider menus use named spans inside individual service cards.
    # Keep the same small-card binding rather than promoting a page fragment.
    service_headings += soup.select('div[data-id] > span.name')
    for heading in service_headings:
        title = " ".join(heading.stripped_strings).strip()
        if not title or not contains_requested_procedure(title, procedure):
            continue

        # Collect only very close siblings. Do not climb to the entire section,
        # because that can contain prices for unrelated treatments.
        prev_parts = []
        sib = heading
        for _ in range(3):
            sib = sib.find_previous_sibling()
            if sib is None:
                break
            s = " ".join(sib.stripped_strings).strip()
            if s and len(s) <= 260:
                prev_parts.insert(0, s)
            # Stop once a different treatment heading is reached.
            if getattr(sib, "name", "") in {"h2", "h3", "h4", "h5"}:
                break

        next_parts = []
        sib = heading
        for _ in range(3):
            sib = sib.find_next_sibling()
            if sib is None:
                break
            s = " ".join(sib.stripped_strings).strip()
            if s and len(s) <= 260:
                next_parts.append(s)
            if getattr(sib, "name", "") in {"h2", "h3", "h4", "h5"}:
                break

        candidates = []
        if prev_parts:
            candidates.append(" ".join(prev_parts + [title]))
        if next_parts:
            candidates.append(" ".join([title] + next_parts))

        # Some templates wrap a price and heading in a small card.
        parent = heading.parent
        if parent is not None:
            parent_text = " ".join(parent.stripped_strings).strip()
            if 5 <= len(parent_text) <= 500:
                candidates.append(parent_text)

        for block in candidates:
            for evidence in extract_whatclinic_targeted_text_evidence(
                block, url, procedure
            ):
                key = (
                    round(evidence.price_min, 2),
                    round(evidence.price_max or 0, 2),
                    evidence.currency,
                    fold(evidence.raw_evidence),
                )
                if key in seen:
                    continue
                seen.add(key)
                out.append(evidence)

    return out


def extract_whatclinic_serp_price_evidence(
    hit: SearchHit,
    procedure: str,
    city: str,
) -> list[ExtractedEvidence]:
    """Strict WhatClinic SERP fallback.

    Only individual clinic profiles are eligible. The returned amount is the
    numeric price closest to the requested treatment label.
    """
    if "whatclinic.com" not in host_of(hit.url):
        return []

    if not is_probable_single_business_hit(hit, city):
        return []

    block = " ".join(x for x in [hit.title, hit.snippet] if x).strip()

    if not block:
        return []
    if not city_in_text(f"{block} {hit.url}", city):
        return []
    if not contains_requested_procedure(block, procedure):
        return []

    return extract_whatclinic_targeted_text_evidence(
        block,
        hit.url,
        procedure,
    )


def marketplace_price_evidence_is_strong(
    evidence: ExtractedEvidence,
    procedure: str,
) -> bool:
    """Final marketplace guard: procedure and numeric price must be one block."""
    if classify_source(evidence.source_url) != "marketplace":
        return True
    if not contains_requested_procedure(evidence.raw_evidence, procedure):
        return False
    if not list(iter_exact_price_matches(evidence.raw_evidence)):
        return False

    host = host_of(evidence.source_url)
    if "bookimed.com" in host:
        # Country/category ranges belong to no individual provider.
        if not is_probable_single_business_page(evidence.source_url):
            return False
        if evidence.extraction_method in {"page_window", "marketplace_snippet"}:
            return False
    if "whatclinic.com" in host:
        # Never accept a WhatClinic category page or loose page-window match.
        if not is_probable_single_business_page(evidence.source_url):
            return False
        if is_whatclinic_category_result(
            evidence.source_url, "", evidence.raw_evidence, ""
        ):
            return False
        if evidence.extraction_method == "page_window":
            return False

    return True


def fresha_service_matches(name: str, procedure: str) -> bool:
    """A Fresha service title, not a sentence that merely mentions the word."""
    canonical = canonicalize_procedure(procedure)
    if nonfacial_tariff_scope(canonical, name):
        return False
    if contains_requested_procedure(name, procedure):
        return True
    folded = fold(name)
    if canonical == "chemical_peel":
        if any(fold(brand) in folded for brand in brands_for(procedure)):
            return True
        # "Peeling corporal/sales" is a body scrub, not proof of a chemical
        # facial peel. Never manufacture a requested procedure in the label.
        return False
    if canonical == "hair_transplant":
        return any(
            term in folded
            for term in ("hair transplant", "fue", "dhi", "mbjellje flok", "transplant flok")
        )
    return any(fold(brand) in folded for brand in brands_for(procedure))


def fresha_offer_evidence(
    html: str,
    url: str,
    procedure: str,
) -> list[ExtractedEvidence] | None:
    """Read bookable service prices from Fresha's JSON-LD menu."""
    if "fresha.com" not in host_of(url) or not html:
        return None
    soup = BeautifulSoup(html, "lxml")
    offers = []

    def walk(node) -> None:
        if isinstance(node, dict):
            if node.get("@type") == "Offer" and node.get("price") not in (None, ""):
                item = node.get("itemOffered") or {}
                name = item.get("name") if isinstance(item, dict) else ""
                description = item.get("description", "") if isinstance(item, dict) else ""
                category = item.get("category", "") if isinstance(item, dict) else ""
                offers.append((str(name or ""), node.get("price"), node.get("priceCurrency"),
                               str(description or ""), str(category or node.get("category", "")),
                               str(node.get("url", ""))))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    for node in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = node.string or node.get_text() or ""
        try:
            walk(json.loads(raw))
        except Exception:
            continue

    if not offers:
        return None
    # Empty after filtering means the authoritative service menu rejected all
    # offers. Never resurrect those offers through a prose/DOM fallback.
    out = []
    seen = set()
    canonical = canonicalize_procedure(procedure)
    provider = soup.title.get_text(" ", strip=True) if soup.title else ""
    for name, price, currency, description, category, offer_url in offers:
        name = re.sub(r"\s+", " ", unescape(name)).strip()
        if not name or not fresha_service_matches(name, procedure):
            continue
        scope = " | ".join(part for part in (name, category, description) if part)
        if injectable_scope_rejection(canonical, name, scope, provider, url):
            continue
        if canonical == "botox" and botox_noninjectable_context(name):
            continue
        code = str(currency or "").upper()
        if code == "LEK":
            code = "ALL"
        if not re.fullmatch(r"[A-Z]{3}", code):
            continue
        try:
            amount = float(price)
        except (TypeError, ValueError):
            continue
        if not plausible(amount, code):
            continue
        key = (fold(scope), round(amount, 2), code)
        if key in seen:
            continue
        seen.add(key)
        label = name
        volume = re.search(r"(\d+(?:[.,]\d+)?)\s*ml\b", scope, re.I)
        unit = (
            f"{volume.group(1).replace(',', '.')} ml"
            if volume and canonical == "filler"
            else "vial" if re.search(r"\b(?:1|one)\s*vial\b", scope, re.I) else "procedure"
        )
        raw = f"{scope} | {amount:g} {code}"
        out.append(ExtractedEvidence(
            raw_procedure_text=label[:160],
            raw_price_text=f"{amount:g} {code}",
            price_min=amount,
            currency=code,
            unit=unit,
            qualifier="exact",
            raw_evidence=raw,
            source_url=offer_url if offer_url.startswith(url.rstrip("/") + "/booking") else url,
            extraction_method="fresha_offer",
        ))
        if len(out) >= 8:
            break
    return out


def retired_price_markup(node) -> bool:
    """Only explicit obsolete-price markup can remove a literal amount."""
    classes = " ".join(node.get("class", []))
    retired = bool(set(node.get('class', [])) & {'screen-reader-text', 'sr-only'}) and bool(re.search(
        r'^(?:el precio original era|the original price was|original price(?: was)?)\s*:',
        node.get_text(' ', strip=True), re.I,
    )) or node.name in {"del", "s", "strike"} or bool(re.search(
        r"(?:^|\s|__)(?:price[-_]+(?:old|original|previous|was)|"
        r"(?:old|original|previous|was)[-_]+price)(?:[-_][\w-]+)?(?:\s|$)",
        classes, re.I,
    )) or bool(re.search(
        r"text-decoration(?:-line)?\s*:[^;]*line-through",
        node.get("style", ""), re.I,
    ))
    return retired and bool(re.search(r"\d", node.get_text(" ", strip=True)))


def extract_current_dom_price_rows(soup, out, seen, url, procedure):
    """Read the active amount in the same DOM row as its retired price.

    Afterwards remove retired nodes from every fallback path, including full
    page windows. A crossed-out amount alone must never become a current card.
    """
    old_nodes = [node for node in soup.find_all(True) if retired_price_markup(node)]
    rows = {}
    for old in old_nodes:
        old_text = old.get_text(" ", strip=True)
        old_prices = list(iter_exact_price_matches(old_text))
        if not old_prices:
            # Some sites put the currency outside the <del> amount.
            currency = currency_of(old.parent.get_text(" ", strip=True))
            values = re.findall(AMOUNT_TOKEN, old_text)
            amount = to_num(values[0]) if len(values) == 1 else None
            if currency and amount is not None:
                old_prices = [(None, amount, currency)]
        parent = old.parent
        for _ in range(7):
            if parent is None:
                break
            text = parent.get_text(" ", strip=True)
            if len(text) > 760:
                break
            if contains_requested_procedure(text, procedure):
                # An ancestor containing several other menu rows is not the
                # retired amount's own row, even on a short test/menu page.
                prices = {(amount, currency) for _, amount, currency in iter_exact_price_matches(text)}
                if len(prices) > 2:
                    break
                rows.setdefault(id(parent), (parent, []))[1].extend(old_prices)
                break
            parent = parent.parent
    # Remove nested retired nodes from the outside in.
    for old in old_nodes:
        if old.parent is not None:
            old.decompose()
    for parent, old_prices in rows.values():
        if parent.parent is None:
            continue
        text = parent.get_text(" ", strip=True)
        begin = len(out)
        add_evidence(out, seen, text, url, procedure, "dom_current_price_row")
        for evidence in out[begin:]:
            originals = [amount for _, amount, currency in old_prices
                         if currency == evidence.currency and amount != evidence.price_min]
            if len(set(originals)) == 1:
                evidence.original_price_min = originals[0]


def extract_owned_tariff_lists(soup, out, seen, url, procedure):
    """A clinic-owned introduction can apply to its immediately following list."""
    for listing in soup.find_all(['ul', 'ol']):
        introduction = listing.find_previous_sibling(['p', 'div'])
        if introduction is None:
            continue
        intro = introduction.get_text(' ', strip=True)
        if (len(intro) > 450 or not contains_requested_procedure(intro, procedure)
                or not re.search(r'\b(?:cost|price|pricing|tariff)\b', intro, re.I)
                or not clinic_paragraph_matches_site(intro, url)):
            continue
        named = re.search(r'\bat\s+(.{3,100}?)\s+(?:ranges?|starts?|costs?)\b', intro, re.I)
        if not named:
            continue
        # Preserve the actual named owner, not the surrounding SEO cost prose.
        # The immediately adjacent list supplies the treatment and its amount.
        owner = named.group(1).strip(' ,:;')
        for item in listing.find_all('li', recursive=False):
            line = item.get_text(' ', strip=True)
            if len(line) > 200 or not contains_requested_procedure(line, procedure):
                continue
            # These lists often place the type after a currency-prefix range.
            # Keep the price in the same DOM item and move only its own label.
            tail = re.search(r'\s+for\s+(.{1,100})$', line, re.I)
            if tail and contains_requested_procedure(tail.group(1), procedure):
                line = f'{tail.group(1)} | {line[:tail.start()].strip()}'
            start = len(out)
            add_evidence(out, seen, line, url, procedure, 'owned_tariff_list')
            for ev in out[start:]:
                ev.raw_evidence = f'At {owner}: | {ev.raw_evidence}'


def extract_named_dom_tariff_rows(soup, out, seen, url, procedure):
    """A menu widget's title and amount must come from its same list item."""
    for item in soup.select('.elementor-price-table'):
        title = item.select_one('.elementor-price-table__heading')
        price = item.select_one('.elementor-price-table__price')
        if title is None or price is None:
            continue
        label = title.get_text(' ', strip=True)
        subheading = item.select_one('.elementor-price-table__subheading')
        prefix = subheading.get_text(' ', strip=True) if subheading else ''
        if contains_requested_procedure(label, procedure):
            add_evidence(out, seen, f'{label} | {prefix} {price.get_text(" ", strip=True)}',
                         url, procedure, 'dom_tariff_row')

    # A treatment page may put its tariff in a compact labelled facts card.
    # Require an explicit sole treatment H1 and a directly adjacent value.
    headings = soup.find_all('h1')
    if len(headings) == 1:
        label = headings[0].get_text(' ', strip=True)
        if (contains_requested_procedure(label, procedure)
                and not any(contains_requested_procedure(label, other)
                            for other in PROCEDURES if other != canonicalize_procedure(procedure))):
            for node in soup.find_all(['dt', 'div', 'span']):
                if not re.fullmatch(r'(?:precio(?: orientativo)?|starting price|treatment price|price)',
                                    node.get_text(' ', strip=True), re.I):
                    continue
                value = node.find_next_sibling()
                if value is None:
                    continue
                amount = value.get_text(' ', strip=True)
                if len(amount) < 80 and list(iter_exact_price_matches(amount)):
                    add_evidence(out, seen, f'{label} | {node.get_text(" ", strip=True)}: {amount}',
                                 url, procedure, 'dom_tariff_row')

    # WooCommerce also sells appointments. Keep the current price paired
    # with its own title, even if malformed HTML nests adjacent products.
    for title in soup.select('.woocommerce-loop-product__title'):
        price = title.find_next_sibling('span', class_='price')
        if price is None:
            continue
        current = price.find('ins') or price
        label = title.get_text(' ', strip=True)
        if contains_requested_procedure(label, procedure):
            begin = len(out)
            add_evidence(out, seen, f'{label} | {current.get_text(" ", strip=True)}',
                         url, procedure, 'dom_current_price_row')
            for ev in out[begin:]:
                ev.raw_procedure_text = label

    # Avada/Fusion tariff rows use sibling columns rather than table cells.
    # Bind only the small inner row, never the complete multi-service menu.
    for item in soup.select('.fusion-builder-row-inner'):
        line = item.get_text(' ', strip=True)
        prices = list(iter_exact_price_matches(line))
        if (5 <= len(line) <= 260 and len(prices) == 1
                and contains_requested_procedure(line, procedure)):
            add_evidence(out, seen, line, url, procedure, 'dom_tariff_row')

    # Wix booking pages publish one service title and an accessible duplicate
    # of its price. Select the visible price once and preserve its qualifier.
    for item in soup.select('[data-hook="body-children-wrapper"]'):
        title = item.select_one('[data-hook="title-and-tagline-title"]')
        price = item.select_one('[data-hook="details-price"]')
        if title is None or price is None:
            continue
        label, amount = title.get_text(' ', strip=True), price.get_text(' ', strip=True)
        if contains_requested_procedure(label, procedure):
            start = len(out)
            add_evidence(out, seen, f'{label} | {amount}', url, procedure, 'dom_tariff_row')
            for ev in out[start:]:
                ev.raw_procedure_text = label

    # Price grids name the treatment once, then list areas/doses. Inherit a
    # heading only inside its own direct sibling grid, with one price/card.
    for heading in soup.find_all(['h2', 'h3']):
        label = heading.get_text(' ', strip=True)
        if len(label) > 100 or not contains_requested_procedure(label, procedure):
            continue
        grid = heading.find_next_sibling('div')
        if grid is None or 'grid' not in grid.get('class', []):
            continue
        for card in grid.find_all('div', recursive=False):
            title = card.find(['h3', 'h4'])
            text = card.get_text(' ', strip=True)
            prices = list(iter_exact_price_matches(text))
            if title is None or len(text) > 400 or len(prices) != 1:
                continue
            service = f'{label} - {title.get_text(" ", strip=True)}'
            start = len(out)
            add_evidence(out, seen, f'{service} | {prices[0][0].group(0)}', url, procedure, 'dom_tariff_row')
            for ev in out[start:]:
                ev.raw_procedure_text = service

    for item in soup.select('li.elementor-price-list-item'):
        title = item.select_one('.elementor-price-list-title')
        price = item.select_one('.elementor-price-list-price')
        if title is None or price is None:
            continue
        label = title.get_text(' ', strip=True)
        amount = price.get_text(' ', strip=True)
        if not contains_requested_procedure(label, procedure):
            continue
        if not list(iter_exact_price_matches(amount)):
            continue
        start = len(out)
        add_evidence(out, seen, f'{label} | {amount}', url, procedure, 'dom_tariff_row')
        for ev in out[start:]:
            ev.raw_procedure_text = label

    # A price-table widget may name only the injected area in each feature.
    # Inherit Botox only from an explicit page title, and bind the amount to
    # that same short item. Never infer it from a general aesthetic homepage.
    page_title = soup.title.get_text(' ', strip=True) if soup.title else ''
    if (canonicalize_procedure(procedure) != 'botox'
            or not contains_requested_procedure(page_title, procedure)):
        return
    area_label = re.compile(
        r'(?:patas\s+de\s+gallo|frente|entrecejo|forehead|glabella|'
        r'crow[’\x27]?s?\s+feet)(?:\s*\+\s*(?:patas\s+de\s+gallo|'
        r'frente|entrecejo|forehead|glabella|crow[’\x27]?s?\s+feet))*', re.I)
    for item in soup.select('.elementor-price-table__features-list li'):
        line = item.get_text(' ', strip=True)
        if len(line) > 160 or ':' not in line:
            continue
        label, amount = (part.strip() for part in line.rsplit(':', 1))
        if not area_label.fullmatch(label) or len(list(iter_exact_price_matches(amount))) != 1:
            continue
        start = len(out)
        title = f'Botox - {label}'
        add_evidence(out, seen, f'{title} | {amount}', url, procedure, 'dom_tariff_row')
        for ev in out[start:]:
            ev.raw_procedure_text = title


def extract_scoped_tariff_table_rows(soup, out, seen, url, procedure):
    """Inherit only a table's explicit treatment scope and price currency.

    Dose/count columns are not prices. Multiple price columns are ambiguous
    unless one is explicitly the current discounted column. No city-based
    currency guesses and no inheritance across neighbouring tables.
    """
    for table in soup.find_all("table"):
        caption = table.find("caption")
        scope = (caption.get_text(" ", strip=True) if caption else "")
        if not contains_requested_procedure(scope, procedure):
            scope = nearest_heading_context(table)
        if not contains_requested_procedure(scope, procedure):
            heading = table.find_previous(['h1','h2','h3','h4','h5','h6'])
            if heading is not None and int(heading.name[1]) >= 3:
                parent_heading = heading.find_previous(['h1','h2'])
                if parent_heading is not None:
                    parent_scope = parent_heading.get_text(' ',strip=True)
                    if contains_requested_procedure(parent_scope, procedure):
                        scope = parent_scope
        if scope and any(contains_requested_procedure(scope, other)
               for other in PROCEDURES
               if other != canonicalize_procedure(procedure)):
            continue
        rows = [tr for tr in table.find_all("tr") if tr.find_parent("table") is table]
        if not rows:
            continue
        header = rows[0].find_all(["th", "td"], recursive=False)
        if any(int(cell.get("colspan", 1)) != 1 or int(cell.get("rowspan", 1)) != 1
               for cell in header):
            continue  # multi-level brand matrices need their own column model
        headings = [cell.get_text(" ", strip=True) for cell in header]
        injectable_scope = (canonicalize_procedure(procedure) == "filler"
                            and bool(re.search(r"\b(?:precio|precios|tarifas?)\b.*\bacido\s+hialuronico\b", fold(scope)))
                            and any(re.search(r"\b\d*\s*viales?\b", fold(label)) for label in headings))
        price_columns = [i for i, label in enumerate(headings)
                         if i > 0 and re.search(r"\b(?:price|prices|cost|tariff|fee|discount|offer|sale|precio|precios|pvp|antes|ahora|oferta)\b", label, re.I)
                         and not re.search(r"\b(?:dose|quantity|average|typical|market|national|other|units?\s+(?:typical|required))\b", label, re.I)]
        current_columns = [i for i in price_columns
                           if re.search(r"\b(?:after\s+discount|discounted|current|now|offer|sale|ahora|oferta)\b", headings[i], re.I)]
        if len(current_columns) > 1:
            doses = [(i, re.search(r'\b(\d+)\s*(?:vials?|viales|ml|syringes?)\b', headings[i], re.I))
                     for i in current_columns]
            if all(match for _, match in doses):
                current_columns = [min(doses, key=lambda pair: int(pair[1].group(1)))[0]]
        if len(current_columns) == 1:
            column = current_columns[0]
        elif len(price_columns) == 1:
            column = price_columns[0]
        else:
            continue
        if column == 0:
            continue
        inherited_currency = currency_of(headings[column]) or currency_of(scope)
        for tr in rows[1:]:
            cells = tr.find_all(["th", "td"], recursive=False)
            if len(cells) > len(headings) or len(cells) <= column:
                continue
            label = cells[0].get_text(" ", strip=True)
            price = cells[column].get_text(" ", strip=True)
            if not label or not price:
                continue
            if (injectable_scope and not contains_requested_procedure(label, procedure)
                    and not requested_filler_areas(label)
                    and not re.search(r"\b(?:relleno\s+de\s+arrugas|codigo\s+de\s+barras|"
                                      r"surco\s+nasogen\w*|lineas\s+marionetas)\b", fold(label))):
                # Hyaluronic-acid menus also sell skinboosters/body treatments;
                # only an explicit facial filler row inherits this table scope.
                continue
            scoped = contains_requested_procedure(scope, procedure) or injectable_scope
            if not scoped and not contains_requested_procedure(label, procedure):
                continue
            if not currency_of(price):
                if not inherited_currency or not re.fullmatch(
                        rf"(?:from\s+|starting\s+from\s+|nga\s+|de\s+la\s+)?"
                        rf"{AMOUNT_TOKEN}(?:\s*(?:-|–|—|to)\s*{AMOUNT_TOKEN})?", price, re.I):
                    continue
                price = f"{price} {inherited_currency}"
            if any(contains_requested_procedure(label, other)
                   for other in PROCEDURES
                   if other != canonicalize_procedure(procedure)):
                continue
            start = len(out)
            treatment = '' if contains_requested_procedure(label, procedure) else display_name(canonicalize_procedure(procedure))
            if (canonicalize_procedure(procedure) == 'breast_augmentation'
                    and re.search(r'\b(?:silicone|saline|implants?)\b', scope, re.I)):
                treatment = re.sub(r'^cost\s+of\s+|\s+(?:cost|prices?|in\s+.+)$', '', scope, flags=re.I).strip()
            basis = re.search(r'\bper\s+(?:units?|areas?|zones?|grafts?|syringes?|sessions?|ml)\b',
                              headings[column], re.I)
            unit_label = f' {basis.group(0)}' if basis else ''
            dose = re.search(r'\b\d+\s*(?:vials?|viales|ml|syringes?)\b', headings[column], re.I)
            if dose:
                unit_label = f' {dose.group(0)}'
            if not dose:
                for index, heading in enumerate(headings):
                    if index in {0, column} or index >= len(cells):
                        continue
                    if re.fullmatch(r'(?:vials?|viales?|ml|syringes?)', heading, re.I):
                        dose_text = cells[index].get_text(' ', strip=True)
                        if re.fullmatch(r'\d+\s*(?:vials?|viales?|ml|syringes?)', dose_text, re.I):
                            unit_label = f' {dose_text}'
                            break
            if re.search(r'\bstarting\s+(?:price|cost)|\b(?:from|starts?)\b', headings[column], re.I):
                price = f'from {price}'
            add_evidence(out, seen, f"{treatment} | {label}{unit_label}: {price}",
                         url, procedure, "scoped_tariff_table_row")
            if len(current_columns) == 1:
                originals = [i for i in price_columns if i < len(cells) and re.search(
                    r'\b(?:before|old|original|previous|antes)\b', headings[i], re.I)]
                if not originals:
                    originals = [i for i in price_columns if i != column and i < len(cells)]
                if len(originals) == 1:
                    original = cells[originals[0]].get_text(" ", strip=True)
                    old_prices = list(iter_exact_price_matches(original))
                    old_amount = old_prices[0][1] if len(old_prices) == 1 else to_num(original)
                    for evidence in out[start:]:
                        if old_amount is not None and old_amount > evidence.price_min:
                            evidence.original_price_min = old_amount
                            evidence.qualifier = "promo"
            if len(out) > start:
                # Once a header identifies the selected tariff, fallback
                # windows cannot attach another column's amount to its label.
                for index, cell in enumerate(cells):
                    if index not in {0, column} and currency_of(cell.get_text(' ', strip=True)):
                        cell.clear()


def extract_owned_comparison_columns(soup, out, seen, url, procedure):
    """Use the explicitly named clinic column, never a foreign comparator."""
    brand = domain_brand(url)
    site_key = _clinic_compare_key(soup.title.get_text(' ', strip=True) if soup.title else '')
    foreign_words = {fold(word) for words in FOREIGN_PRICE_PATH_COUNTRIES.values() for word in words}
    for table in soup.find_all('table'):
        rows = table.find_all('tr')
        if len(rows) < 2:
            continue
        headings = [node.get_text(' ', strip=True) for node in rows[0].find_all(['th','td'], recursive=False)]
        foreign = [i for i,label in enumerate(headings) if i and any(word in fold(label).split() for word in foreign_words)]
        own = [i for i,label in enumerate(headings) if i and i not in foreign
               and not re.search(r'\b(?:other|average|median|altri|altre|medi|medie)\b', fold(label))
               and ((brand and clinic_identity_similarity(label, brand) >= .7)
                    or (len(_clinic_compare_key(label)) >= 7 and _clinic_compare_key(label) in site_key))]
        if not foreign or len(own) != 1:
            continue
        for tr in rows[1:]:
            cells = tr.find_all(['th','td'], recursive=False)
            if len(cells) != len(headings) or any(int(c.get('colspan',1)) != 1 for c in cells):
                continue
            label, price = cells[0].get_text(' ', strip=True), cells[own[0]].get_text(' ', strip=True)
            if contains_requested_procedure(label, procedure) and len(list(iter_exact_price_matches(price))) == 1:
                add_evidence(out, seen, f'{label} | {headings[own[0]]}: {price}', url, procedure,
                             'clinic_comparison_column')
        # These are comparison columns, not crossed-out former tariffs.
        # Remove them from this private parse tree so fallback extraction
        # cannot turn "Italy €7000 | this clinic €3500" into a promotion.
        for tr in rows:
            cells = tr.find_all(['th','td'], recursive=False)
            if len(cells) == len(headings):
                for index in foreign:
                    cells[index].decompose()


def extract_semantic_tariff_cards(soup, out, seen, url, procedure):
    """Explicit pricing widgets contain one treatment and one payable price."""
    for card in soup.select('.mkdf-pi-content-holder, .pricing-card, .price-card, [data-price-card], .e-con-inner'):
        label_node = (card.find(['h2','h3','h4','h5','h6']) or card.select_one('[class*="pi-title"]')
                      or card.find('p'))
        if not label_node:
            continue
        label = label_node.get_text(' ', strip=True)
        text = card.get_text(' ', strip=True)
        if not contains_requested_procedure(label, procedure) or len(text) > 600:
            continue
        prices = list(iter_exact_price_matches(text))
        attached = find_attached_range(text, prices[0][2], prices[0][0]) if prices else None
        one_tariff = len(prices) == 1 or (len(prices) == 2 and attached is not None
                     and prices[0][2] == prices[1][2] and set(attached) == {prices[0][1], prices[1][1]})
        if not one_tariff or any(contains_requested_procedure(label, other)
                                  for other in PROCEDURES if other != canonicalize_procedure(procedure)):
            continue
        # Preserve any fee, monthly-payment or package qualifications so the
        # common validation gates can reject or describe this exact offer.
        add_evidence(out, seen, text, url, procedure, 'semantic_tariff_card')


def extract_scoped_graft_cards(soup, out, seen, url, procedure):
    """A compact tariff card may inherit an explicit surgical hair heading.

    The unit must be printed in that same card. PRP/non-surgical sections
    and cards containing multiple amounts cannot borrow the surgical scope.
    """
    if canonicalize_procedure(procedure) != 'hair_transplant':
        return
    for heading in soup.find_all(['h3', 'h4']):
        label = heading.get_text(' ', strip=True)
        if re.search(r'\brepair\b|\brevision\b|\bbeard\b|\beyebrow\b|\bmoustache\b|\bmustache\b',
                     fold(label)):
            continue
        scope_node = heading.find_previous(['h1', 'h2'])
        scope = scope_node.get_text(' ', strip=True) if scope_node else ''
        if (not contains_requested_procedure(scope, procedure)
                or re.search(r'non[- ]?surgical|without\s+surgery|\bprp\b|stem\s+cell', fold(scope))):
            continue
        parent = heading.parent
        for _ in range(4):
            if parent is None:
                break
            text = parent.get_text(' ', strip=True)
            if len(text) > 650 or len(parent.find_all(['h3', 'h4'])) != 1:
                break
            if unit_of(text) == 'graft' and len(list(iter_exact_price_matches(text))) == 1:
                add_evidence(out, seen, f'{scope} | {text}', url, procedure, 'scoped_graft_card')
                break
            parent = parent.parent


def extract_standalone_tariff_sentences(soup, out, seen, url, procedure):
    """An explicitly printed standalone fee supersedes an add-on fee."""
    for paragraph in soup.find_all('p'):
        text = paragraph.get_text(' ', strip=True)
        if len(text) > 1000 or 'standalone' not in fold(text):
            continue
        matches = list(iter_exact_price_matches(text))
        for index, (match, amount, currency) in enumerate(matches):
            after = text[match.end():match.end() + 65]
            if not re.match(r'\s+(?:as\s+(?:a\s+)?)?(?:standalone|stand-alone)\s+treatment\b', after, re.I):
                continue
            preceding = text[:matches[index-1][0].start()] if index else text[:match.start()]
            labels = requested_procedure_spans(preceding, procedure)
            if not labels:
                continue
            start, end = labels[-1]
            label = preceding[start:end]
            add_evidence(out, seen, f'{label} | {match.group(0)} as standalone treatment',
                         url, procedure, 'standalone_tariff_sentence')


def extract_parallel_tariff_columns(soup, out, seen, url, procedure):
    """Read explicitly headed visual tables, including Tilda price grids.

    Pair only one unambiguous treatment column and one price column in the
    same table, with equal row counts. Responsive copies must be identical.
    A missing price or a second differing tariff column fails closed.
    """
    for grid in soup.select(".t396__artboard, [data-tariff-table]"):
        labels = set()
        tariffs = set()
        for column in grid.select(".tn-atom, [data-tariff-column]"):
            strings = list(column.stripped_strings)
            if not strings or len(strings) > 350:
                continue
            header = fold(strings[0]).strip(":")
            if header in {"treatment", "treatments", "service", "services", "procedure"}:
                names = tuple(node.get_text(" ", strip=True)
                              for node in column.find_all(["span", "strong", "b"])
                              if not node.find(["span", "strong", "b"])
                              and node.get_text(" ", strip=True) != strings[0])
                if 2 <= len(names) <= 40 and not any(currency_of(name) for name in names):
                    labels.add(names)
            elif header in {"price", "prices", "fee", "fees", "tariff"}:
                # Each non-heading text node must be a complete explicit
                # amount. No inference of currency or row from whitespace.
                values = tuple(strings[1:])
                if 2 <= len(values) <= 40 and all(
                    len(list(iter_exact_price_matches(value))) == 1
                    and re.fullmatch(r"[\d\s.,€$£₺+–—\-]+(?:AED|EUR|USD|GBP|ALL|HUF|RON|lei|lek)?"
                                     r"|(?:AED|EUR|USD|GBP|ALL|HUF|RON|lei|lek)\s*[\d\s.,+]+",
                                     value, re.I)
                    for value in values
                ):
                    tariffs.add(values)
        if len(labels) != 1 or len(tariffs) != 1:
            continue
        names, prices = next(iter(labels)), next(iter(tariffs))
        if len(names) != len(prices):
            continue
        for name, price in zip(names, prices):
            if contains_requested_procedure(name, procedure):
                add_evidence(out, seen, f"{name} | Price: {price}", url, procedure,
                             "aligned_tariff_columns")


def extract_price_evidence(
    html: str,
    url: str,
    procedure: str,
) -> list[ExtractedEvidence]:
    memo = _hybrid_parse_memo.get()
    memo_key = (url, canonicalize_procedure(procedure), memo.get("__city__", "") if memo is not None else "")
    if memo is not None and memo_key in memo:
        return memo[memo_key]
    if classify_source(url) == "marketplace" and not is_probable_single_business_page(url):
        return []
    text_all = page_text(html)

    if is_hard_retail_url(url, procedure):
        return []

    fresha_offers = fresha_offer_evidence(html, url, procedure)
    if fresha_offers is not None:
        if memo is not None:
            memo[memo_key] = fresha_offers
        return fresha_offers

    soup = BeautifulSoup(html, "lxml")

    for t in soup(["script", "style", "noscript"]):
        t.decompose()
    normalize_dom_price_boundaries(soup)

    out = []
    seen = set()

    # Booksy exposes service/variant boundaries. A duration, review, or the
    # next service must never supply the price for the current service.
    booksy_rows = soup.select('[data-testid="services-list-item-root"]') if host_of(url) == "booksy.com" else []
    if booksy_rows:
        for row in booksy_rows:
            name = row.select_one('[data-testid="service-name"]')
            if name is None:
                continue
            for price in row.select('[data-testid="service-variant-price"]'):
                add_evidence(out, seen,
                             f"{name.get_text(' ', strip=True)} | {price.get_text(' ', strip=True)}",
                             url, procedure, "semantic_block")
        if memo is not None:
            memo[memo_key] = out
        return out

    extract_owned_comparison_columns(soup, out, seen, url, procedure)
    extract_current_dom_price_rows(soup, out, seen, url, procedure)
    extract_named_dom_tariff_rows(soup, out, seen, url, procedure)
    extract_scoped_tariff_table_rows(soup, out, seen, url, procedure)
    extract_owned_tariff_lists(soup, out, seen, url, procedure)
    extract_semantic_tariff_cards(soup, out, seen, url, procedure)
    extract_scoped_graft_cards(soup, out, seen, url, procedure)
    extract_standalone_tariff_sentences(soup, out, seen, url, procedure)
    extract_parallel_tariff_columns(soup, out, seen, url, procedure)
    # Quick-facts menus may put the starting price before the product label.
    # Bind only the priced item and the explicit brand/treatment item from
    # this same compact list; navigation or a distant page mention cannot bind.
    for facts in soup.find_all(["ul", "dl"]):
        fact_text = facts.get_text(" ", strip=True)
        if not 10 <= len(fact_text) <= 1000:
            continue
        items = facts.find_all(["li", "dt", "dd"], recursive=False)
        priced = [item.get_text(" ", strip=True) for item in items
                  if re.search(r"\b(?:starting\s+price|treatment\s+pric(?:e|ing)|cost)\b",
                               item.get_text(" ", strip=True), re.I)
                  and list(iter_exact_price_matches(item.get_text(" ", strip=True)))]
        labels = [item.get_text(" ", strip=True) for item in items
                  if re.search(r"\b(?:brands?\s+available|products?\s+(?:used|available)|"
                               r"procedure|treatment\s+name)\b",
                               item.get_text(" ", strip=True), re.I)
                  and contains_requested_procedure(item.get_text(" ", strip=True), procedure)]
        if len(priced) != 1 or len(labels) != 1:
            continue
        heading = nearest_heading_context(facts)
        if (botox_noninjectable_context(f"{heading} {fact_text}")
                or any(contains_requested_procedure(heading, other)
                       for other in PROCEDURES
                       if other != canonicalize_procedure(procedure))):
            continue
        add_evidence(out, seen,
                     f"{display_name(canonicalize_procedure(procedure))} | {priced[0]} | {labels[0]}",
                     url, procedure, "procedure_quick_facts")
    # Never reintroduce an obsolete amount through a flattened page window.
    text_all = " ".join(soup.stripped_strings)[:50000]

    if "wupdoc.com" in host_of(url) and is_probable_single_business_page(url):
        # The profile's price menu is below reviews and a large global nav.
        # Read only the treatment row under this ONE clinic's menu.
        menu = soup.find(
            lambda tag: tag.name in {"h2", "h3", "h4"}
            and "treatments & price" in fold(tag.get_text(" ", strip=True))
        )
        if menu:
            for node in menu.next_elements:
                if getattr(node, "name", None) in {"h2", "h3"} and node is not menu:
                    break
                if getattr(node, "name", None) != "a":
                    continue
                label = node.get_text(" ", strip=True)
                if not contains_requested_procedure(label, procedure):
                    continue
                tail = []
                for sibling in node.next_elements:
                    if sibling is node:
                        continue
                    if getattr(sibling, "name", None) == "a":
                        break
                    if isinstance(sibling, str):
                        value = sibling.strip()
                        if value:
                            tail.append(value)
                    if len(" ".join(tail)) >= 95:
                        break
                fragment = f"{label} {' '.join(tail)[:95]}"
                add_evidence(out, seen, fragment, url, procedure, "service_section")

    # 0. WhatClinic treatment-level blocks. Their markup often places the
    # price immediately before the service heading.
    if "whatclinic.com" in host_of(url):
        wc = extract_whatclinic_service_price_evidence(html, url, procedure)
        for item in wc:
            key = (
                round(item.price_min, 2),
                round(item.price_max or 0, 2),
                item.currency,
                fold(item.raw_evidence),
            )
            if key not in seen:
                seen.add(key)
                out.append(item)

    # 1. Table rows
    for tr in soup.find_all("tr"):
        text = " ".join(tr.stripped_strings)
        if 5 <= len(text) <= 700:
            add_evidence(out, seen, text, url, procedure, "table_row")

    # Split a paragraph containing primary and combined/secondary surgery
    # prices into clauses, so the two prices cannot borrow each other's label.
    for paragraph in soup.find_all("p"):
        statement = paragraph.get_text(" ", strip=True)
        if len(list(iter_exact_price_matches(statement))) < 2:
            continue
        clauses = re.split(
            r",?\s+\b(?:ndërsa|whereas|while|mentre)\b\s+",
            statement, flags=re.I,
        )
        if len(clauses) < 2:
            continue
        for clause in clauses:
            if (len(list(iter_exact_price_matches(clause))) == 1
                    and contains_requested_procedure(clause, procedure)):
                add_evidence(out, seen, clause, url, procedure, "procedure_clause")

    # A local clinic blog may state its own tariff in a paragraph beneath a
    # procedure heading, after a separate national-market comparison. Scope
    # the price to that paragraph and require the site's own business name.
    for paragraph in soup.find_all("p"):
        statement = paragraph.get_text(" ", strip=True)
        if not statement or not list(iter_exact_price_matches(statement)):
            continue
        if not re.search(r"\b(?:n[eë]\s+klinik[eë]n|presso\s+la\s+clinica|at\s+.{2,100}?\b(?:clinic|center))\b", fold(statement)):
            continue
        own_host = domain_brand(url)
        if not clinic_paragraph_matches_site(statement, url):
            continue
        heading = paragraph.find_previous(["h1", "h2", "h3", "h4"])
        if (contains_requested_procedure(statement, procedure)
                or heading and contains_requested_procedure(heading.get_text(" ", strip=True), procedure)):
            # A later, unpriced invitation to a FREE consultation does not
            # change the preceding, explicitly owned treatment tariff.
            first_price = next(iter_exact_price_matches(statement), None)
            if first_price:
                stop = re.search(r"[.!?](?:\s|$)", statement[first_price[0].end():])
                if stop:
                    end = first_price[0].end() + stop.end()
                    invitation = statement[end:].strip()
                    if (re.match(r"(?:please\s+)?(?:call|contact|book|schedule)\b", invitation, re.I)
                            and re.search(r"\bfree\b.{0,45}\bconsultation\b", invitation, re.I)
                            and not list(iter_exact_price_matches(invitation))
                            and not implant_cost_excluded(invitation)):
                        statement = statement[:end].strip()
            add_evidence(out, seen,
                         f"{display_name(canonicalize_procedure(procedure))} | {statement}",
                         url, procedure, "clinic_owned_paragraph")

    # Some single-procedure microsites show "package €X" in a price heading;
    # the procedure name appears in the page heading/URL rather than the box.
    if (any(fold(term) in fold(urlparse(url).path) for term in aliases_for(procedure)[:4])
            or ("rinoplastica" in host_of(url) and canonicalize_procedure(procedure) == "rhinoplasty")):
        for heading in soup.find_all(["h2", "h3", "h4"]):
            offer = heading.get_text(" ", strip=True)
            if (list(iter_exact_price_matches(offer))
                    and re.search(r"\b(?:pacchetto|package|rinoplastica|rhinoplasty)\b", fold(offer))):
                add_evidence(out, seen,
                             f"{display_name(canonicalize_procedure(procedure))} | {offer}",
                             url, procedure, "procedure_landing_offer")

    # 2. Service/list cards
    for node in soup.find_all(["li", "article", "section"]):
        text = " ".join(node.stripped_strings)
        text = contextual_block_text(node, text)
        if 5 <= len(text) <= 760:
            add_evidence(out, seen, text, url, procedure, "semantic_block")

    # 3. A procedure card often puts the label in one heading and its price in
    # the immediately following heading (common on Romanian clinic sites).
    # Capture the first single-price sibling before building the wider block,
    # so a later septoplasty/revision card cannot contaminate the primary row.
    # Price-only headings can live in a separate layout wrapper from a long
    # preceding treatment heading. Bind only adjacent semantic headings.
    previous_title = ""
    for h in soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "p"]):
        title = h.get_text(" ", strip=True)
        if not title:
            continue
        prices = list(iter_exact_price_matches(title))
        if (len(title) <= 32 and len(prices) == 1
                and contains_requested_procedure(previous_title, procedure)
                and not list(iter_exact_price_matches(previous_title))):
            add_evidence(out, seen, f"{previous_title} | {title}", url,
                         procedure, "heading_price_pair")
        previous_title = title if h.name != "p" and len(title) <= 180 else ""

    for h in soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6", "strong", "b"]):
        title = " ".join(h.stripped_strings)
        if not contains_requested_procedure(title, procedure):
            continue
        sibling = h
        for _ in range(5):
            sibling = sibling.find_next_sibling()
            if sibling is None:
                break
            sibling_text = " ".join(sibling.stripped_strings)
            if not sibling_text:
                continue
            sibling_is_heading = getattr(sibling, "name", "") in {
                "h1", "h2", "h3", "h4", "h5", "h6"
            }
            if not sibling_is_heading:
                continue
            prices = list(iter_exact_price_matches(sibling_text))
            if len(prices) == 1:
                add_evidence(
                    out, seen, f"{title} {sibling_text}", url, procedure,
                    "heading_price_pair",
                )
                break
            if contains_requested_procedure(sibling_text, procedure):
                break

    # Elementor menus put the treatment name and its price in successive
    # headings, not in the same parent. A short "Botox:" heading covers the
    # zone lines that follow until the next section.
    section = ""
    pending = ""
    for heading in soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6"]):
        title = " ".join(heading.stripped_strings)
        # Empty layout headings between a procedure and its amount carry no
        # new section. Clearing the anchor lost valid Elementor surgery menus.
        if not title:
            continue
        if len(title) > 80:
            section = ""
            pending = ""
            continue
        prices = list(iter_exact_price_matches(title))
        if len(prices) == 1 and len(title) <= 24 and pending:
            add_evidence(
                out, seen, f"{pending} {title}", url, procedure,
                "heading_price_pair",
            )
            pending = ""
            continue
        if prices:
            pending = ""
            continue
        if (
            contains_requested_procedure(title, procedure)
            and len(fold(title)) <= 24
        ):
            section = title
            pending = title
            continue
        if (section and canonicalize_procedure(procedure) in {"botox", "filler"}
                and not fold(title).endswith(":")):
            pending = f"{section} {title}"
            continue
        section = ""
        pending = ""

    # 4. Heading + following siblings
    for h in soup.find_all(["h1", "h2", "h3", "h4", "h5", "strong", "b"]):
        title = " ".join(h.stripped_strings)

        if not contains_requested_procedure(title, procedure):
            continue

        parts = [title]
        sib = h

        for _ in range(4):
            sib = sib.find_next_sibling()

            if sib is None:
                break

            s = " ".join(sib.stripped_strings)

            if s:
                parts.append(s)

        joined = " ".join(parts)

        if len(joined) <= 1000:
            add_evidence(
                out,
                seen,
                joined,
                url,
                procedure,
                "heading_siblings",
            )

    # 5. Parent climb for Elementor/card layouts
    for node in soup.find_all(string=True):
        txt = (node or "").strip()

        if not txt or not contains_requested_procedure(txt, procedure):
            continue

        parent = node.parent

        for level in range(1, 5):
            if not parent:
                break

            block = " ".join(parent.stripped_strings)
            block = contextual_block_text(parent, block)

            if 5 <= len(block) <= 1260:
                add_evidence(
                    out,
                    seen,
                    block,
                    url,
                    procedure,
                    f"parent_{level}",
                )

            parent = parent.parent

    # 6. Bounded full-page window fallback
    fpage = fold(text_all)

    # For filler, use only explicit injectable cues rather than "hyaluronic acid".
    search_terms = (
        INJECTABLE_FILLER_POSITIVE
        if canonicalize_procedure(procedure) == "filler"
        else aliases_for(procedure)
    )

    for term in search_terms:
        pos = fpage.find(fold(term))

        if pos < 0:
            continue

        block = text_all[max(0, pos - 280): min(len(text_all), pos + 720)]

        add_evidence(
            out,
            seen,
            block,
            url,
            procedure,
            "page_window",
        )

    if memo is not None:
        memo[memo_key] = out
    return out


# ============================================================
# Evidence ownership/context validation
# ============================================================

NEGATIVE_MARKET_PATTERNS = [
    r"\bpromedio\b|\b(?:precio|coste|costo)s?\s+medi[oa]s?\b",
    r"\baverage\s+(?:price|cost)\b",
    r"\baround\s+(?:€|eur|£|gbp|\$|usd|lek|all)?\s*\d",
    r"\babout\s+(?:€|eur|£|gbp|\$|usd|lek|all)?\s*\d",
    r"\bapproximately\s+(?:€|eur|£|gbp|\$|usd|lek|all)?\s*\d",
    r"\broughly\s+(?:€|eur|£|gbp|\$|usd|lek|all)?\s*\d",
    r"\btypical(?:ly)?\s+(?:price|cost|range|costs?)\b",
    r"\bprices?\s+in\s+[a-zà-ÿ\s]{2,40}\s+(?:range|start|are)\b",
    r"\bcosts?\s+in\s+[a-zà-ÿ\s]{2,40}\b",
    r"\bgenerally\s+(?:cost|costs|range|ranges|start|starts)\b",
    r"\bcompared\s+(?:to|with)\b",
    r"\bmarket\s+(?:average|price|rate)\b",
    r"\bcan\s+cost\b",
    r"\bmay\s+cost\b",
    r"\btypically\s+costs?\b",
    r"\bpatients?\s+can\s+save\b",
    r"\bsave\s+up\s+to\s+\d{1,3}\s*%",
    r"\bbis\s+zu\s+\d{1,3}\s*%",
    r"\b(?:durchschnitt|durchschnittlich)\b",
    r"\bersparnis\b",
]

POSITIVE_OWNERSHIP_PATTERNS = [
    r"\bour\s+(?:price|prices|package|packages)\b",
    r"\bprice\s+list\b",
    r"\bbook\s+now\b",
    r"\bbook(?:ing)?\b",
    r"\bofert",
    r"\bappointment\b",
    r"\bstarting\s+from\b",
    r"\bstarts?\s+from\b",
    r"\bat\s+[A-Z][A-Za-z0-9&' .-]{2,60}\s*,?\s*(?:treatments?|prices?|fillers?)\b",
    r"\btek\s+ne\s+nis\s+nga\b",
]


def market_info(text: str) -> bool:
    return any(re.search(p, fold(text), re.I) for p in NEGATIVE_MARKET_PATTERNS)


def pricing_prose_title(text: str) -> bool:
    """Local-language price headlines are evidence, not service names."""
    return bool(re.search(
        r"\b(?:precio|precios|coste|costo|promedio|desde|cuanto|entre los|"
        r"prix|tarifs?|combien|a partir|prezzo|prezzi|quanto|ab|durchschnitt)\b",
        fold(text),
    ))


def seasonal_offer_needs_confirmation(text: str) -> bool:
    """A month-only campaign is not a confirmed current evergreen tariff.

    Keep this independent of the current month: without an explicit validity
    year/end date the recurring validity cannot be inferred from a stale page.
    """
    t = fold(text)
    months = (r"january|february|march|april|may|june|july|august|september|october|november|december|"
              r"enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre")
    return bool(re.search(
        rf"\b(?:promo\w*|oferta|offer)\b.{{0,110}}\b(?:{months})\b|"
        rf"\b(?:{months})\b.{{0,45}}\b(?:promo\w*|offer)\b|"
        rf"\b(?:durante el mes de|during the month of)\s+(?:{months})\b",
        t,
    ))


def own_language(text: str) -> bool:
    # Keep original case for clinic-name ownership pattern.
    return any(re.search(p, text, re.I) for p in POSITIVE_OWNERSHIP_PATTERNS)


def clinic_paragraph_matches_site(text: str, url: str) -> bool:
    """A named clinic in a tariff paragraph must match this official host."""
    brand = domain_brand(url)
    if clinic_identity_similarity(text, brand) >= .55:
        return True
    label = re.search(r'\b(?:ne\s+kliniken|presso\s+la\s+clinica|at)\s+'
                      r'([a-z0-9][a-z0-9 -]{2,100}?)(?:\s*[,.:;]|\s+(?:kostoja|cmimi|costo|prezzo|ranges?|starts?)\b)',
                      fold(text))
    if not label:
        return False
    named = _clinic_compare_key(label.group(1))
    host_key = _clinic_compare_key(brand)
    if len(named) < 6:
        return False
    # A service suffix attached to the clinic's actual name is common in
    # domains. Only that suffix can differ; another clinic's quote fails.
    if host_key == named or any(host_key == named + suffix
                               for suffix in ('hair','clinic','medical','aesthetics')):
        return True
    service_suffix = r'(?:plasticsurgery|hairtransplant(?:nyc)?(?:center)?|hairrestoration|medicalcenter|medical|aesthetics|clinic)$'
    named_core = re.sub(service_suffix, '', named)
    host_core = re.sub(service_suffix, '', host_key)
    return len(named_core) >= 6 and named_core == host_core


def comparative_clinic_table_prices(
    html: str, url: str, procedure: str,
) -> set[tuple[float, str]]:
    """Identify the clinic column when a tariff compares other countries.

    An Italian price in a table headed 'Prezzi Italia | [Clinic]' is a
    comparison, even when the entire table appears on the clinic's website.
    """
    if "<table" not in html.lower():
        return set()
    memo = _hybrid_parse_memo.get()
    key = ("comparison_table_prices", url, canonicalize_procedure(procedure))
    if memo is not None and key in memo:
        return memo[key]
    out: set[tuple[float, str]] = set()
    soup = BeautifulSoup(html, "lxml")
    brand = domain_brand(url)
    # A clinic may operate multiple brands on one official domain. Match the
    # column to the site's title when it names a distinct aesthetic unit.
    site_title_key = _clinic_compare_key(
        soup.title.get_text(" ", strip=True) if soup.title else ""
    )
    foreign_words = {
        fold(word) for words in FOREIGN_PRICE_PATH_COUNTRIES.values()
        for word in words
    }
    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        if not rows:
            continue
        heading = [cell.get_text(" ", strip=True)
                   for cell in rows[0].find_all(["th", "td"], recursive=False)]
        if len(heading) < 3:
            continue
        country_columns = [i for i, label in enumerate(heading)
                           if any(word in fold(label).split() for word in foreign_words)]
        clinic_columns = [i for i, label in enumerate(heading)
                          if i not in country_columns and i > 0
                          and not re.search(
                              r"\b(?:other|others|average|mean|median|"
                              r"altri|altre|medi|medie)\b", fold(label), re.I,
                          )
                          and ("clinic" in fold(label) or "klin" in fold(label)
                               or "hospital" in fold(label) or "spital" in fold(label)
                               or (brand and clinic_identity_similarity(label, brand) >= 0.7)
                               or (len(_clinic_compare_key(label)) >= 7
                                   and _clinic_compare_key(label) in site_title_key
                                   and not any(word in fold(label) for word in [
                                       "average", "median", "prezzi medi",
                                       "other clinic", "altre clinic", "altri paesi",
                                   ])))]
        if not country_columns or len(clinic_columns) != 1:
            continue
        own_index = clinic_columns[0]
        for tr in rows[1:]:
            cells = [cell.get_text(" ", strip=True)
                     for cell in tr.find_all(["th", "td"], recursive=False)]
            if len(cells) <= own_index or not has_procedure(cells[0], procedure):
                continue
            if canonicalize_procedure(procedure) == "rhinoplasty" and nonprimary_rhinoplasty_variant(cells[0]):
                continue
            for _match, amount, currency in iter_exact_price_matches(cells[own_index]):
                out.add((round(amount, 2), currency))
    if memo is not None:
        memo[key] = out
    return out


def unresolved_comparison_table_prices(
    html: str, procedure: str,
) -> set[tuple[float, str]]:
    """Prices in a foreign comparison table with no identifiable owned column.

    Without a confirmed own column neither the foreign price nor an 'other
    clinics' price is safe to publish as this clinic's tariff.
    """
    if "<table" not in html.lower():
        return set()
    memo = _hybrid_parse_memo.get()
    key = ("unresolved_comparison_table_prices", id(html),
           canonicalize_procedure(procedure))
    if memo is not None and key in memo:
        return memo[key]
    out: set[tuple[float, str]] = set()
    foreign_words = {
        fold(word) for words in FOREIGN_PRICE_PATH_COUNTRIES.values()
        for word in words
    }
    soup = BeautifulSoup(html, "lxml")
    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        if len(rows) < 2:
            continue
        headings = [cell.get_text(" ", strip=True)
                    for cell in rows[0].find_all(["th", "td"], recursive=False)]
        if len(headings) < 3 or not any(
            any(word in fold(label).split() for word in foreign_words)
            for label in headings[1:]
        ):
            continue
        for tr in rows[1:]:
            cells = [cell.get_text(" ", strip=True)
                     for cell in tr.find_all(["th", "td"], recursive=False)]
            if len(cells) < 3 or not has_procedure(cells[0], procedure):
                continue
            if (canonicalize_procedure(procedure) == "rhinoplasty"
                    and nonprimary_rhinoplasty_variant(cells[0])):
                continue
            for cell in cells[1:]:
                for _match, amount, currency in iter_exact_price_matches(cell):
                    out.add((round(amount, 2), currency))
    if memo is not None:
        memo[key] = out
    return out


def branded_official_menu_evidence(
    url: str, full_page_text: str, evidence: ExtractedEvidence,
) -> bool:
    """Recognize a compact treatment/price entry under 'Price [site brand]'.

    Some official lists put the clinic's name in the price column but use a
    general surgery URL. Keep the treatment and its single amount in the same
    extracted block; a page-wide brand label alone proves no price ownership.
    """
    brand = _clinic_compare_key(domain_brand(url))
    if len(brand) < 5:
        return False
    labels = re.finditer(
        r"\b(?:prezzo|prezzi|price|prices|cmimi|tarifa)\s+(?:di\s+)?"
        r"([a-z][a-z0-9&'-]*(?:\s+[a-z][a-z0-9&'-]*){0,2})",
        fold(full_page_text[:5000]),
    )
    if not any(
        _clinic_compare_key(" ".join(label.group(1).split()[:n])) == brand
        for label in labels for n in (1, 2, 3)
    ):
        return False
    raw = evidence.raw_evidence or ""
    if (len(raw) > 320
            or not has_procedure(raw, evidence.raw_procedure_text)
            or market_info(raw)
            or generic_multi_clinic_price_context(raw)):
        return False
    exact = list(iter_exact_price_matches(raw))
    return (
        len(exact) == 1
        and round(exact[0][1], 2) == round(evidence.price_min, 2)
        and exact[0][2] == evidence.currency
        and evidence.price_max is None
    )


def classify_evidence_type(
    url: str,
    html: str,
    full_page_text: str,
    evidence: ExtractedEvidence,
) -> str:
    source = classify_page_source(url, full_page_text)
    path = urlparse(url).path.lower()
    head = fold(full_page_text[:2200])
    local = fold(evidence.raw_evidence)

    if source == "marketplace":
        if (
            " book" in f" {local}"
            or evidence.extraction_method
            in {
                "table_row", "semantic_block", "heading_siblings", "heading_price_pair",
                "service_section", "whatclinic_service_pair", "fresha_offer",
                "scoped_tariff_table_row", "dom_tariff_row", "aligned_tariff_columns",
            }
        ):
            return "marketplace_service_menu"
        return "marketplace_profile"

    if source != "official_clinic":
        return "unknown"

    article_path = bool(
        re.search(
            r"(?:/blog/|/news/|/author/|/unpublished/|/artikull/|/article/|/lajme/|/opinion/|-vs-|how-much|"
            r"button-nose-|"
            r"cost-(?:uk|italy|turkey|albania)|"
            r"(?:surgery|fillers?|botox)-in-[a-z-]+-prices|2026)",
            path,
            re.I,
        )
    )

    article_head = any(
        phrase in head
        for phrase in [
            "compared with", "compared to", "average cost",
            "how much does", "prices in the uk", "prices in italy",
            "prices in turkey",
        ]
    )

    if (
        is_price_menu_path(url)
        or evidence.extraction_method in {'clinic_comparison_column', 'semantic_tariff_card',
                                          'scoped_graft_card', 'standalone_tariff_sentence'}
        or (evidence.extraction_method in {'scoped_tariff_table_row', 'owned_tariff_list', 'dom_tariff_row'}
            and not article_path and not generic_multi_clinic_price_context(full_page_text))
        or "price list" in local
        or "pricelist" in local
        or branded_official_menu_evidence(url, full_page_text, evidence)
    ):
        return "official_price_menu"

    if article_path or article_head or comparative_market_article_context(
        url, full_page_text,
    ):
        return "official_article"

    if (
        re.search(
            r"/(?:treatment|treatments|service|services|service-page|procedure|procedures|"
            r"tratamiento|tratamientos|servicios|trattamenti|soins|behandlungen|trajtime)(?:/|$)",
            path,
        )
        or any(
            cue in local
            for cue in [
                "book", "appointment", "per vial", "per syringe",
                "1 ml", "0.5 ml", "2 ml",
            ]
        )
        or evidence.extraction_method
        in {
            "table_row", "semantic_block", "heading_siblings",
            "heading_price_pair", "service_section",
            "procedure_quick_facts", "scoped_tariff_table_row", "aligned_tariff_columns",
        }
    ):
        return "official_treatment_page"

    return "official_page"





COUNTRY_CODE_DISPLAY_NAMES = {
    "AL": {"albania", "albanian"},
    "RO": {"romania", "romanian"},
    "GB": {"uk", "united kingdom", "britain", "british"},
    "US": {"usa", "united states", "american"},
    "IT": {"italy", "italian"},
    "TR": {"turkey", "turkish"},
    "FR": {"france", "french"},
    "ES": {"spain", "spanish"},
    "DE": {"germany", "german"},
    "AE": {"uae", "united arab emirates", "emirates"},
    "IR": {"iran", "iranian", "إيران", "ايران"},
    "IN": {"india", "indian"},
}


def foreign_quoted_price_country(evidence: str, city: str) -> bool:
    """The destination of a treatment quote must match the requested city.

    USD is a currency, not proof that a clinic is in the United States.
    Conversely, a local Maps label cannot relocate a rhinoplasty quote in Iran.
    """
    requested = country_hint_for_city(city)
    if not requested or not evidence:
        return False
    text = fold(evidence)
    for country, names in COUNTRY_CODE_DISPLAY_NAMES.items():
        if country == requested:
            continue
        for name in names:
            # Match a priced treatment destination, not a doctor nationality.
            destination = re.escape(fold(name))
            if re.search(
                r"(?:\b(?:costs?|prices?|pricing|tariffs?|fees?|prezzi|prezzo|costo)\b|تكلفة|أسعار)"
                r"[^.!?\n|]{0,80}(?:\bin\s+(?:the\s+)?|في\s+)"
                + destination + r"(?!\w)", text,
            ):
                return True
    return False

CURRENCY_HOME_COUNTRY = {
    "GBP": "GB",
    "USD": "US",
}


def is_price_menu_path(url: str) -> bool:
    path = urlparse(url or "").path.lower()
    if re.search(r"/(?:blog|news|author)(?:/|$)", path):
        return False
    if country_price_guide_path(url):
        return False
    return bool(
        re.search(
            r"(?:/|[-_])(?:price-list|pricelist|pricing|prices?|tariff|tariffs|"
            r"pret|preț|preturi|prețuri|tarife|"
            r"preise|preisliste|gebuhren|gebuehren|prezzi|listino|tariffe|"
            r"precos|preços|precio|precios|tarifas|prix|tarifs|"
            r"arak|árak|arlista|árlista|"
            r"fees|fee|cmime(?:t|ve)?|çmime(?:t|ve)?)(?:/|$|[-_]|\.(?:html?|php|aspx?)$)",
            path,
            re.I,
        )
    )


def surrounding_evidence_context(
    full_page_text: str,
    raw_evidence: str,
    raw_price_text: str = "",
    radius_before: int = 1400,
    radius_after: int = 500,
) -> str:
    if not full_page_text:
        return ""

    fpage = fold(full_page_text)
    needles = [
        fold(raw_evidence or "")[:120],
        fold(raw_price_text or ""),
    ]

    pos = -1
    for needle in needles:
        if not needle:
            continue
        pos = fpage.find(needle)
        if pos >= 0:
            break

    if pos < 0:
        return ""

    return full_page_text[
        max(0, pos - radius_before):
        min(len(full_page_text), pos + radius_after)
    ]


def foreign_market_price_context(
    evidence: ExtractedEvidence,
    full_page_text: str,
    city: str = "",
) -> bool:
    """Reject foreign-market comparison prices on clinic-owned editorial pages."""
    home_cc = (country_hint_for_city(city) or "").upper()
    currency_cc = CURRENCY_HOME_COUNTRY.get(
        (evidence.currency or "").upper()
    )

    if not home_cc or not currency_cc or home_cc == currency_cc:
        return False

    local = fold(
        surrounding_evidence_context(
            full_page_text,
            evidence.raw_evidence,
            evidence.raw_price_text,
        )
    )

    if not local:
        return False

    foreign_names = COUNTRY_CODE_DISPLAY_NAMES.get(currency_cc, set())
    foreign_signal = any(name in local for name in foreign_names)

    if currency_cc == "GB":
        foreign_signal = foreign_signal or any(
            token in local
            for token in [
                "nhs",
                "private treatment prices",
                "covered by the nhs",
                "insurance cover",
            ]
        )

    if currency_cc == "US":
        foreign_signal = foreign_signal or any(
            token in local
            for token in [
                "medicare",
                "medicaid",
                "insurance coverage",
                "united states",
            ]
        )

    return foreign_signal


def agency_or_directory_page_context(full_page_text: str) -> bool:
    text = fold(full_page_text or "")
    if not text:
        return False

    terms = [
        "medical tourism agency",
        "medical tourism facilitator",
        "medical travel",
        "partner clinics",
        "compare clinics",
        "find a clinic",
        "travel package",
        "tour package",
        "airport transfer",
        "hotel accommodation",
        "arrange your trip",
    ]

    return sum(1 for term in terms if term in text) >= 2


def explicit_multi_provider_agency(full_page_text: str) -> bool:
    """A broker cannot claim an unnamed partner's fee as its own clinic fee."""
    body = fold(full_page_text or "")
    agency = any(term in body for term in (
        "medical tourism agency", "medical travel agency",
        "agenzia di turismo medico", "agence de tourisme medical",
    ))
    network = any(term in body for term in (
        "network of medical professionals", "network of clinics",
        "partner clinics", "partners with several private clinics",
        "rete di professionisti medici", "selected network",
    ))
    facilitator = any(term in body for term in (
        "we connect international patients", "we connect patients",
        "connect you with", "match you with a clinic",
        "comparing our vetted clinics", "compare our vetted clinics",
        "the clinic delivers your treatment", "clinics we list",
    ))
    travel_coordinator = any(term in body for term in (
        "full travel coordination", "airport transfers and hotel bookings",
        "we confirm your clinic dates", "arrange the practical side",
        "whole trip coordinated", "travel support",
    ))
    return (
        agency and network
        or network and facilitator and travel_coordinator
        or facilitator and "partner clinic" in body and travel_coordinator
    )


def marketplace_profile_local_starting_price(
    evidence: ExtractedEvidence,
    source: str,
) -> bool:
    """Allow only the explicitly labelled provider price in a comparison card.

    Provider profiles sometimes show ``EU average €9,000 | Albania from
    €2,000``.  Both numbers are extracted, but only the number syntactically
    attached to a starting-price marker can become the marketplace quote.
    """
    if source != "marketplace":
        return False
    raw = evidence.raw_evidence or ""
    for match, amount, currency in iter_exact_price_matches(raw):
        if (round(amount, 2) != round(evidence.price_min, 2)
                or currency != evidence.currency):
            continue
        prefix = fold(raw[max(0, match.start() - 28):match.start()])
        if re.search(
            r"(?:\bfrom|\bstarting\s+from|\bstarts?\s+from|\bnga|"
            r"\bde\s+la|\bdesde|\bab|\ba\s+partire\s+da)\s*$",
            prefix,
        ):
            return True
    return False



THIRD_PARTY_PROVIDER_CUES = (
    "clinic", "clinique", "klinika", "medical", "med", "dental",
    "aesthetic", "aesthetics", "beauty", "spa", "hospital",
    "center", "centre", "doctor", "dr ",
)


def third_party_provider_price_context(
    evidence: ExtractedEvidence,
) -> bool:
    """Detect a provider-labelled quote living on somebody else's page."""
    raw = re.sub(
        r"\s+",
        " ",
        str(evidence.raw_evidence or "").replace("\u00a0", " "),
    ).strip()
    if not raw:
        return False

    # Common directory/guide layout: `Provider | Service | Price`.
    m = re.match(
        r"^([A-Za-zÀ-ÿ0-9&'’ .-]{2,70})\s*\|\s*",
        raw,
        re.I,
    )
    if not m:
        return False

    label = clean_name(m.group(1))
    folded = fold(label)

    # Generic menu departments are not named competing providers.
    if folded in {'aesthetic medicine', 'cosmetic medicine', 'aesthetic treatments',
                  'medicina estetica', 'medecine esthetique', 'asthetische medizin',
                  'plastic, aesthetic and reconstructive surgery', 'trichology and hair surgery'}:
        return False

    if not any(cue in folded for cue in THIRD_PARTY_PROVIDER_CUES):
        return False

    # A treatment label such as "Botox | €200" is not a provider.
    if canonicalize_procedure(label) in PROCEDURES:
        return False

    host_brand = domain_brand(evidence.source_url)
    if not host_brand:
        return True

    # Matching clinic-owned brand is allowed.
    return clinic_identity_similarity(label, host_brand) < 0.55


def cached_market_or_third_party_row_needs_revalidation(
    row: ClinicPriceResult,
) -> bool:
    if row.source_type != "official_clinic":
        return False

    raw = row.raw_evidence or ""
    if (row.evidence_type != "official_price_menu"
            and not own_language(raw)
            and not clinic_paragraph_matches_site(raw, row.source_url)
            and re.search(r"(?:~|≈)\s*" + AMOUNT_TOKEN, raw)):
        # A stripped estimate table can lose its average-price heading. Its
        # unowned approximate fragment needs a fresh source check.
        return True
    if comparative_market_article_context(row.source_url, raw):
        return True
    if generic_multi_clinic_price_context(raw):
        return True
    if market_info(raw) and not (own_language(raw) or clinic_paragraph_matches_site(raw, row.source_url)):
        return True

    pseudo = ExtractedEvidence(
        raw_procedure_text=row.raw_procedure_text or row.procedure_canonical,
        raw_price_text=str(row.price_min),
        price_min=row.price_min,
        price_max=row.price_max,
        currency=row.currency,
        unit=row.unit,
        qualifier=row.qualifier
        if row.qualifier in {"exact", "from", "range", "approximate", "promo", "unknown"}
        else "unknown",
        original_price_min=row.original_price_min,
        original_price_max=row.original_price_max,
        raw_evidence=raw,
        source_url=row.source_url,
        extraction_method="cached_revalidation",
    )
    return third_party_provider_price_context(pseudo)


def rhinoplasty_price_column_conflict(row: ClinicPriceResult) -> bool:
    """Guard against cached travel/foreign-market columns as surgery fees.

    A legacy result can claim ownership and high confidence while its raw
    evidence still shows that its amount belongs to a different table column.
    Keep genuinely single-priced tariffs and short two-price ranges.
    """
    if canonicalize_procedure(row.procedure_canonical) != "rhinoplasty":
        return False
    raw = fold(row.raw_evidence or "")
    amount = round(row.price_min, 2)
    for match in re.finditer(
        r"\b(?:midis|between)\s+([\d.,]+)\s+(?:dhe|and|to)\s+"
        r"([\d.,]+)\s*(?:euro|eur|€)", raw,
    ):
        low, high = to_num(match.group(1)), to_num(match.group(2))
        if (low is not None and high is not None and low < high
                and round(high, 2) == amount):
            return True
    price_matches = sorted(iter_exact_price_matches(raw), key=lambda x: x[0].start())
    if len(price_matches) >= 4 and round(price_matches[0][1], 2) != amount:
        return True
    from_price = re.search(
        r"\b(?:from|nga|ab|de\s+la|desde|a\s+partire\s+da)\s*"
        r"(?:€|eur|euro)?\s*([\d.,]+)",
        raw,
    )
    if from_price and "%" in raw and len(price_matches) >= 2:
        own_amount = to_num(from_price.group(1))
        if own_amount is not None and round(own_amount, 2) != amount:
            return True
    return False


def normalize_cached_explicit_price_floor(
    row: ClinicPriceResult,
) -> tuple[ClinicPriceResult, bool]:
    """Mark the lower endpoint of a published range as a starting price.

    The correction is deliberately conservative: the stored amount must be
    the lower bound of a syntactically attached range in its own literal
    evidence. Keep that lowest amount for display, but never call it exact.
    """
    previous_payload = row.model_dump()
    row = normalize_breast_price_result(row)
    if row.raw_evidence:
        symbol_currency = []
        if "£" in row.raw_evidence:
            symbol_currency.append("GBP")
        if "€" in row.raw_evidence:
            symbol_currency.append("EUR")
        if "$" in row.raw_evidence:
            symbol_currency.append("USD")
        if len(set(symbol_currency)) == 1 and symbol_currency[0] != row.currency:
            row = row.model_copy(update={"currency": symbol_currency[0]})
            changed_currency = True
        else:
            changed_currency = False
    else:
        changed_currency = False
    changed_currency = changed_currency or row.model_dump() != previous_payload
    if row.raw_evidence and qualifier(row.raw_evidence, row.price_min, row.price_max) == "approximate":
        upper = row.price_max
        for match, amount, currency in iter_exact_price_matches(row.raw_evidence):
            if currency == row.currency and abs(amount - row.price_min) <= .011:
                attached = find_attached_range(row.raw_evidence, currency, match)
                if attached and abs(attached[0] - row.price_min) <= .011:
                    upper = attached[1]
                break
        updated = row.model_copy(update={"qualifier": "approximate", "price_max": upper})
        return updated, changed_currency or updated.model_dump() != row.model_dump()
    if row.price_max is not None or not row.raw_evidence:
        return row, changed_currency
    for old_m, _new_m, old_price, new_price, currency in (
        iter_descending_promo_pairs(row.raw_evidence) or []
    ):
        if (currency == row.currency
                and round(old_price, 2) == round(row.price_min, 2)
                and new_price < old_price):
            payload = row.model_dump()
            payload.update(
                price_min=new_price,
                price_max=None,
                qualifier=("from" if qualifier(row.raw_evidence, new_price, None) == "from" else "promo"),
                original_price_min=old_price,
            )
            return ClinicPriceResult.model_validate(payload), True
    for match, amount, currency in iter_exact_price_matches(row.raw_evidence):
        if (currency != row.currency
                or round(amount, 2) != round(row.price_min, 2)):
            continue
        attached = find_attached_range(row.raw_evidence, currency, match)
        if (not attached
                or round(attached[0], 2) != round(row.price_min, 2)
                or attached[1] <= attached[0]):
            continue
        payload = row.model_dump()
        payload.update(price_min=attached[0], price_max=None, qualifier="from")
        return ClinicPriceResult.model_validate(payload), True
    return row, changed_currency


def consultation_fee_evidence(evidence: ExtractedEvidence) -> bool:
    """A first-visit or consultation fee is not the procedure price."""
    price_text = getattr(evidence, "raw_price_text", "") or ""
    blob = fold(evidence.raw_evidence or "")
    needle = fold(price_text)
    if not needle:
        hit = next((m for m, amount, cur in iter_exact_price_matches(blob)
                    if abs(amount - evidence.price_min) < .011 and cur == evidence.currency), None)
        needle = hit.group(0) if hit else ""
    window = blob
    if needle and needle in blob:
        i = blob.find(needle)
        window = blob[max(0, i - 90): i + len(needle) + 48]
    return bool(re.search(
        r"\b(?:first visit|initial visit|prima visita|visita iniziale|"
        r"consultation(?:\s+fee)?|consult fee|"
        r"new patient (?:fee|visit)|primera visita|consulta inicial|"
        r"aesthetic medicine appointment|"
        r"free if treatment is performed)\b|"
        r"\bappointment\b.{0,45}\d.{0,35}\bredeemable\b",
        window,
    ))


def page_disclaims_clinic_prices(raw: str) -> bool:
    """An explicit estimate disclaimer overrides menu/table ownership cues."""
    text = fold(raw or "").replace('ı', 'i')
    return bool(re.search(
        r"no\s+representan\s+los\s+precios\s+(?:aplicados|cobrados)|"
        r"(?:prices?|fees?)\s+(?:do\s+not|don't)\s+represent\b.{0,70}"
        r"(?:our\s+(?:clinic|consultation|fees?|prices?)|clinic\s+(?:fees?|prices?))|"
        r"(?:not\s+our\s+(?:menu|prices?|tariff)|no\s+son\s+nuestros\s+precios)|"
        r"\b(?:these|listed)\s+(?:prices|fees|figures)\s+are\s+(?:only\s+)?(?:averages|estimates)\b|"
        r"\b(?:fiyatlar|ucretler|degerler|rakamlar)\s+(?:sadece\s+)?ortalamadir\b|"
        r"\b(?:bu|yukaridaki)\s+(?:fiyatlar|ucretler|degerler|rakamlar)\s+ortalama\s+olup\b|"
        r"\b(?:estos|los)\s+(?:precios|importes)\s+son\s+(?:solo\s+)?(?:promedios|estimaciones)\b", text,
    ))


def generic_multi_clinic_price_context(raw: str) -> bool:
    """A national or multi-clinic estimate is not this clinic's own quote."""
    local = fold(raw or "")
    if localized_market_price_context(raw):
        return True
    if (re.search(r"\b(?:el|los)\s+(?:precio|coste|costo)s?\s+(?:de|del)\b[^.!?\n|]{0,90}"
                  r"\ben\s+[a-z ]{2,40}\b(?:varian?|oscila[n]?|suele[n]?\s+oscilar)\b", local)
            and not re.search(r"\b(?:nuestra|nuestro|nuestras|nuestros)\b", local)):
        return True
    return page_disclaims_clinic_prices(raw) or bool(re.search(
        r"\b(?:depending on (?:your needs and )?the clinic|"
        r"(?:clinics?|providers?) like|(?:many|other|different) clinics? charge|"
        r"(?:si aggira|si colloca) generalmente|prezzo medio|prezzi medi|"
        r"(?:cmimet|kostot)\s+[^.]{0,100}\s+ne\s+(?:shqiperi|albania)\s+variojne|"
        r"(?:cmimet|prices)\s+variojne|"
        r"\brreth\s+\d+\s+klinika\b|"
        r"average (?:price|cost)|typical (?:price|cost)|"
        r"promedio|(?:precio|coste|costo)s?\s+medi[oa]s?|"
        r"depend(?:e|iendo)\s+(?:del\s+cirujano\s+y\s+)?(?:de\s+)?(?:la\s+clinica|del\s+centro)|"
        r"(?:en|entre)\s+(?:otras|distintas|diferentes|varias)\s+clinicas|"
        r"clinicas? low cost|precio orientativo (?:en|de)|precios orientativos|rangos orientativos)\b",
        local,
    ))


def localized_market_price_context(raw: str) -> bool:
    """A Turkish market estimate is not a provider fee, even on its website."""
    text = fold(raw or '').replace('ı', 'i')
    return bool(re.search(
        r'\b(?:fiyat\w*|ucret\w*|maliyet\w*)\b(?:[^.!?\n|]|\.(?=\d)){0,100}'
        r'\b(?:genellikle|ortalama|degis\w*|arasinda)\b|'
        r'\b(?:genellikle|ortalama|genel olarak)\b(?:[^.!?\n|]|\.(?=\d)){0,100}'
        r'\b(?:fiyat\w*|ucret\w*|maliyet\w*|tl|try)\b|'
        r'\bne kadar ortalama\b', text))


def nonprimary_rhinoplasty_variant(raw: str) -> bool:
    """Do not substitute revision/septal/tip surgery for primary rhinoplasty."""
    if re.search(r"\brinoplastia\s+parcial\b", fold(raw)):
        return True
    return bool(re.search(
        r"\b(?:liquid\s+rhinoplasty|non[- ]?surgical\s+rhinoplasty|nose\s+fillers?|"
        r"revision|secondary|tertiary|ethnic\s+rhinoplasty|septo[- ]?rhinoplasty|"
        r"masodlagos\s+orrplasztika|orrplasztika\s*\(\s*csak\s+porc|orrhegyplasztika|"
        r"nem[- ]sebeszi\s+orrplasztika|orrsoveny\s*(?:mutet|korrekcio)|"
        r"rinosettoplastica|rinoseptoplastica|rhinoseptoplast(y|ie)|"
        r"rinoplastica\s+(?:di\s+)?(?:secondaria|revisione)|"
        r"rinoplastik[a-z]*\s+(?:sekondare|sekundare)|"
        r"rhino[- ]?septoplasty|tip rhinoplasty|nose tip rhinoplasty|"
        r"alar base reduction|post[- ]?traumat\w*\s+rhinoplasty|"
        r"rinoplastia\s+post[- ]?traumat\w*|post[- ]?traumatic\w*|"
        r"rinoplastica funzionale|functional rhinoplasty|"
        r"rinoplastik[a-z]*\s+e\s+kombinuar\s+me\s+septoplastik[a-z]*|"
        r"septo[- ]?nasenkorrektur|s?sekundare nasenkorrektur|"
        r"rinoseptoplastie|septorinoplastie|"
        r"rinoplastie\s+(?:secundara|de\s+revizie|functionala)|"
        r"rinoplastie\s*(?:si|cu|\+|&)\s*(?:dev(?:i)?atie\s+de\s+sept|septoplastie)|"
        r"rinocorectie|micsorare\s+nari|"
        r"rino(?:septo|setto)plastia|septo(?:rrino|rino)plastia|"
        r"rinoplastia\s+(?:secundaria|de\s+revision|funcional|racial|etnica)|"
        r"reduccion\s+alar|punta\s+nasal|"
        r"rhino(?:septo|sept)plastie|septo[- ]?rhinoplastie|"
        r"rhinoplastie\s+(?:secondaire|de\s+revision|fonctionnelle|ultrasonique)|"
        r"pointe\s+du\s+nez|"
        r"(?:revizyon|sekonder|fonksiyonel)\s+rinoplasti|septorinoplasti|"
        r"burun\s+ucu\s+estetigi|"
        r"(?:revizionna|vtorichna|funktsionalna)\s+rinoplastika|"
        r"septorinoplastika|vr[aă]h\s+na\s+nosa|"
        r"(?:ревизионна|вторична|функционална)\s+ринопластика|"
        r"септоринопластика|връх\s+на\s+носа)\b",
        fold(raw or ""),
    ))


def breast_price_row_text(
    text: str, raw_price_text: str = "", price_min: float | None = None,
    currency: str = "",
) -> str:
    """Bound the subtype to the service owning this exact numeric amount."""
    matches = sorted(iter_exact_price_matches(text or ""), key=lambda item: item[0].start())
    target = next((item for item in matches
                   if price_min is not None and abs(item[1] - price_min) < .011
                   and (not currency or item[2] == currency)), None)
    if target is None and raw_price_text:
        target = next((item for item in matches
                       if fold(item[0].group(0)) == fold(raw_price_text)), None)
    target = target or (matches[0] if matches else None)
    if target is None:
        return (text or "").strip()
    anchor = target[0]
    previous = [item for item in matches if item[0].end() <= anchor.start()]
    start = previous[-1][0].end() if previous else 0
    # Repeated "from" and bare old/current amounts belong to the same row.
    if previous and re.fullmatch(
        r"\s*(?:(?:from|starting\s+from|de\s+la|nga|ab)\s*)?[€$£\s]*",
        fold(text[start:anchor.start()]),
    ):
        old = previous[-1][0]
        before_old = [item for item in previous if item[0].end() <= old.start()]
        start = before_old[-1][0].end() if before_old else 0
    end = anchor.end()
    following = next((item for item in matches if item[0].start() >= end), None)
    if (following and following[2] == target[2] and
            re.fullmatch(r"\s*(?:to|[-–—])\s*", text[end:following[0].start()], re.I)):
        end = following[0].end()
    fragment = text[start:end].strip(" |·:;–-\n")
    services = list(re.finditer(
        r"augmentation\s+mastopexy|breast\s+(?:augmentation|enlargement|fat\s+transfer|"
        r"lift|reduction|reconstruction|implant(?:s|\s+(?:replacement|removal))?)|"
        r"mastoplastica\s+(?:additt?iva|riduttiva)|mastopessi|aumento\s+seno|"
        r"mellnagyobbitas|mellfelvarras|mellkisebbites|"
        r"zmadhim\w*\s+(?:i\s+)?(?:gjoks|gjir)|zvogelim\w*\s+(?:i\s+)?gj|"
        r"marir\w*\s+(?:(?:de|a)\s+)?san\w*|augmentare\w*\s+mamar\w*|"
        r"(?:schimbar\w*|inlocuir\w*|indepartar\w*)\s+(?:a\s+)?(?:implant\w*|protez\w*)",
        fold(fragment),
    ))
    service = services[-1] if services else None
    if len(services) > 1:
        first, second = services[0], services[1]
        between = fold(fragment[first.end():second.start()])
        if ("mastopexy" in first.group(0)
                or re.search(r"\(\s*$|\b(?:and|plus|with)\s*$|\+\s*$", between)):
            service = first
    if service:
        modifier = re.search(r"\b(?:silicone|saline|mentor|motiva)\s*$", fragment[:service.start()], re.I)
        fragment = fragment[modifier.start() if modifier else service.start():]
    if not service and re.fullmatch(
        r"\s*(?:(?:from|starting\s+from|nga|ab)\s*)?", text[:anchor.start()], re.I,
    ):
        # Price-first table cells may put their label after the amount.
        tail_end = next((item[0].start() for item in matches
                         if item[0].start() >= anchor.end()), len(text))
        tail = text[anchor.end():tail_end]
        if contains_requested_procedure(tail, "breast_augmentation"):
            fragment = f"{tail.strip()} {anchor.group(0)}"
    # Preserve the immediately attached price qualification.
    attached_note = re.match(r"\s*(\([^()]{1,240}\))", text[anchor.end():])
    if attached_note and implant_cost_excluded(attached_note.group(1)):
        fragment += " " + attached_note.group(1)
    installment = re.match(
        r"\s*((?:/\s*(?:month|mo)\b|per\s+month\b|a\s+month\b|"
        r"(?:al|in)\s+mese\b|lunare\b))", text[anchor.end():], re.I,
    )
    if installment:
        fragment += installment.group(0)
    return fragment


def implant_cost_excluded(text: str) -> bool:
    t = fold(text or "")
    return bool(re.search(
        r"(?:nu\s+include|nu\s+includ|fara\s+costul|exclud(?:e[sd]?|ing)|"
        r"does\s+not\s+include|not\s+including|hors|ohne|sin)"
        r"\s+(?:(?:the|cost|costul|of|de|des|der)\s+){0,3}(?:implant\w*|protez\w*|prothes\w*)|"
        r"(?:implant\w*|protez\w*|prothes\w*)\s+(?:(?:are|is|costs?)\s+){0,2}"
        r"(?:not\s+included|excluded|extra|separately|nu\s+sunt\s+incluse|non\s+inclusi)", t,
    ))


def breast_row_is_other_surgery(text: str) -> bool:
    t = fold(text or "")
    if re.search(
        r"\b(?:replacement|exchange|removal|explantation|reconstruction|reduction|"
        r"revision|gynecomastia|gynaecomastia)\b|riduttiv|zvogelimi|"
        r"mellkisebbites|implantatumcsere|"
        r"\b(?:schimbar\w*|inlocuir\w*|indepartar\w*|explantar\w*|"
        r"reconstruct\w*|reduct\w*|micsorar\w*|revizie)\b",
        t,
    ):
        return True
    lift = bool(re.search(
        r"mastopex\w*|mastopessi|breast\s+lift|mellfelvarras|lifting\s+al\s+seno|ridicar\w*",
        t,
    ))
    enlargement = bool(re.search(
        r"augmentation|additt?iva|aumento|zmadhim|mellnagyobbitas|marir\w*|augmentare", t,
    ))
    implants = bool(re.search(r"implant|protesi|prothese|protesis", t))
    return lift and not (enlargement or implants)


def breast_line_is_not_plain_augmentation(text: str) -> bool:
    """Lift-only, reconstruction, and implant+lift are not plain augmentation."""
    if breast_row_is_other_surgery(text):
        return True
    folded = fold(text or "")
    if re.search(r"\b(?:cuanto cuestan los implantes mamarios|por par de implantes|"
                 r"precio de (?:los )?implantes mamarios en espana|implant[- ]only)\b", folded):
        return True
    lift = bool(re.search(
        r"mastopex\w*|mastopessi|breast\s+lift|mellfelvarras|lifting\s+al\s+seno|ridicar\w*",
        folded,
    ))
    with_implant = bool(re.search(
        r"implant|protesi|prothese|protesis|augmentation|additt?iva|aumento",
        folded,
    ))
    return lift and with_implant


def breast_augmentation_detail(raw: str, raw_price_text: str = "") -> str:
    t = fold(breast_price_row_text(raw, raw_price_text))
    if implant_cost_excluded(t):
        return "Implant cost excluded"
    fat = bool(re.search(
        r"fat\s+(?:transfer|graft)|(?:own|autologous|autolog|sajat)\s+(?:fat|zsir)|"
        r"lipofill|lipotransfer|lipomodel|zsiratultet|zsirtolt|grasso|eigenfett|"
        r"grasime\s+proprie|grasa\s+propia|transfert\s+de\s+graisse|me\s+yndyre",
        t,
    ))
    implants = bool(re.search(
        r"implant|protesi|prothese|protesis|\b(?:mentor|motiva|polytech|nagor|allergan)\b|"
        r"\b(?:silicone|saline)\s+breast\b",
        t,
    )) and not bool(re.search(r"without\s+implants?|no\s+implants?|implant\w*\s+nelkul", t))
    lift = bool(re.search(r"mastopex\w*|mastopessi|breast\s+lift|mellfelvarras|lifting\s+al\s+seno|ridicar\w*", t))
    if lift and implants:
        return "Lift + implants"
    if lift and fat:
        return "Lift + fat transfer"
    if fat and implants:
        return "Implants + fat transfer"
    if fat:
        return "Fat transfer"
    if implants:
        return "With implants"
    return "Method not specified"


def breast_augmentation_display_name(raw: str, raw_price_text: str = "") -> str:
    detail = breast_augmentation_detail(raw, raw_price_text)
    return "Breast augmentation" if detail == "Method not specified" else f"Breast augmentation · {detail}"


def normalize_breast_price_result(row: ClinicPriceResult) -> ClinicPriceResult:
    if row.procedure_canonical != "breast_augmentation":
        return row
    bound = breast_price_row_text(row.raw_evidence, price_min=row.price_min, currency=row.currency)
    return row.model_copy(update={
        "procedure_detail": procedure_detail(bound, "breast_augmentation"),
        "procedure_display_name": breast_augmentation_display_name(bound),
        "price_scope": "implant_excluded" if implant_cost_excluded(bound) else row.price_scope,
    })


def breast_price_is_other_surgery(text: str, amount: float) -> bool:
    return breast_row_is_other_surgery(breast_price_row_text(text, price_min=amount))


def priced_line_text(
    text: str,
    amount: float | None = None,
    currency: str = "",
    match=None,
) -> str:
    """The row that owns this amount, not the next row on the menu."""
    raw = text or ""
    matches = list(iter_exact_price_matches(raw))
    if not matches:
        return raw.strip()
    target = None
    if match is not None:
        target = next(
            (item for item in matches if item[0].start() == match.start()),
            None,
        )
    if target is None and amount is not None:
        target = next(
            (
                item for item in matches
                if abs(item[1] - amount) <= 0.011
                and (not currency or item[2] == currency)
            ),
            None,
        )
    target = target or matches[0]
    anchor = target[0]
    previous = [item for item in matches if item[0].end() <= anchor.start()]
    start = previous[-1][0].end() if previous else 0
    # "from 8 750 EUR from 6 100 EUR" is one row. The label sits before the
    # first amount; a gap that is only "from" does not start a new service.
    while previous:
        gap = fold(raw[start:anchor.start()])
        words = re.findall(r"[a-z]{3,}", gap)
        if any(word not in {
            "from", "starting", "starts", "eur", "euro", "lei", "ron",
            "gbp", "usd", "huf", "aed", "all",
        } for word in words):
            break
        previous = previous[:-1]
        start = previous[-1][0].end() if previous else 0
    end = next(
        (item[0].start() for item in matches if item[0].start() >= anchor.end()),
        len(raw),
    )
    following = [item for item in matches if item[0].start() >= anchor.end()]
    if following:
        next_match, next_amount, next_currency = following[0]
        attached = find_attached_range(raw, target[2], anchor)
        gap = raw[anchor.end():next_match.start()]
        if (attached and next_currency == target[2]
                and abs(next_amount-attached[1]) < .011
                and re.fullmatch(r'\s*(?:to|y|u|a|ile|ila|[-–—])\s*', gap, re.I)):
            # Keep the upper endpoint and the label after a currency-prefix
            # range. "AED 400 to AED 700 for light peels" is one tariff.
            end = following[1][0].start() if len(following) > 1 else len(raw)
    later = raw[anchor.end():end]
    cut = re.search(
        r"cosmelan|dermamelan|\bkit\b|home\s*care|home\s*kit|pachet",
        later,
        re.I,
    )
    if cut:
        end = anchor.end() + cut.start()
    return raw[start:end].strip(" |·:;–-\n")


GENERIC_PROCEDURE_LINES = {
    "chemical_peel": (
        "chemical peel", "chemical peeling", "peeling chimic",
        "peeling chimique", "peeling chimico", "peeling kimik",
        "peeling quimico", "chemisches peeling", "kimyasal peeling",
        "kemiai peeling", "kemiai hamlaztas",
    ),
    "filler": (
        "dermal filler", "lip filler", "acid hialuronic",
        "acido ialuronico", "hyaluronic acid", "fillere",
    ),
    "botox": ("botox", "anti wrinkle", "anti-wrinkle", "toxina botulinica"),
    "rhinoplasty": ("rhinoplasty", "rinoplastica", "rinoplastie", "nose job"),
    "breast_augmentation": (
        "breast augmentation", "breast implants", "mastoplastica additiva",
        "augmentare mamara",
    ),
}


def generic_procedure_line(text: str, procedure: str) -> bool:
    canonical = canonicalize_procedure(procedure)
    folded = fold(text or "")
    return any(
        fold(term) in folded
        for term in GENERIC_PROCEDURE_LINES.get(canonical, ())
    )


def procedure_line_is_bundle(text: str, procedure: str) -> bool:
    """A package, kit, or adjacent surgery is not the standard Compare price."""
    canonical = canonicalize_procedure(procedure)
    folded = fold(text or "")
    if not folded:
        return False
    if canonical in {"botox", "filler"} and re.search(
            r"\b(?:en pareja|couples? offer|couples? price|per couple|"
            r"pack\s+amigas?|ven\s+con\s+una\s+amiga|with\s+a\s+friend|friends?\s+(?:offer|pack))\b", folded):
        return True
    if canonical in {"botox", "filler"} and (
        re.search(r"\b(?:botox|botulin\w*|neuromodulad\w*|neuromodulat\w*)\b", folded)
        and re.search(r"\b(?:skin[ -]?boosters?|fillers?|rellenos?|hyaluronic\s+acid|acido\s+hialuronico)\b", folded)
        and re.search(r"\+|&|\b(?:plus|with|and|con|y|cu)\b", folded)
    ):
        return True
    if canonical == "botox" and re.search(
            r"\blabios\s*\+\s*botox\b|\bbotox\s*\+\s*(?:labios|fillers?)\b", folded):
        return True
    if canonical == "chemical_peel":
        first_price = next(iter_exact_price_matches(text), None)
        label = fold(text[:first_price[0].start()] if first_price else text)[-180:]
        if re.search(r'\b(?:[2-9]|[1-9]\d+)\s*(?:sesiones|sessions|sedinte|seances|sitzungen)\b|'
                     r'\b(?:pack|package|series|bono)\s+(?:of\s+|de\s+)?[2-9]\b', label):
            return True
        if re.search(r"\b(?:underarms?|armpits?|bikini|elbows?|knees?)\b|body\s+whitening|"
                     r"carbon\s+(?:laser|peel)|diamond\s+peel|microdermabrasion|laser\s+facial", label):
            return True
        if re.search(r"cosmelan|dermamelan|melanostop", folded):
            return True
        if re.search(r"\bkit\b", folded) and re.search(
            r"home|peel|pachet|package|care", folded,
        ):
            return True
        return False
    if canonical == "filler":
        return filler_volume_is_retail_like(folded)
    if canonical == "rhinoplasty":
        if nonprimary_rhinoplasty_variant(folded):
            return True
        return bool(re.search(
            r"all[- ]inclusive|tutto incluso|flight|hotel|\bvolo\b|\bflug\b",
            folded,
        ))
    if canonical == "breast_augmentation":
        return breast_line_is_not_plain_augmentation(folded)
    if canonical == "botox":
        if botox_medical_indication(folded):
            return True
        return bool(re.search(
            r"hyperhidrosis|iperidrosi|iperhidroza|masseter|bruxism|bruxismo",
            folded,
        ))
    return False


def surgical_chin_quote(text: str, source_url: str = "") -> bool:
    """Chin surgery cannot inherit an adjacent injectable-filler heading."""
    label = fold(text or "")
    path = fold(urlparse(source_url or "").path).replace("-", " ").replace("_", " ")
    # An explicitly non-surgical/injectable mentoplasty is a legitimate filler.
    nonsurgical = bool(re.search(r"\b(?:non[ -]?surgical|sin\s+cirugia|no\s+quirurgic\w*)\b", label))
    cleaned = re.sub(r"\b(?:non[ -]?surgical|sin\s+cirugia|no\s+quirurgic\w*)\b", "", label)
    chin = r"(?:chin|menton|mento|barbilla|mental)"
    implant = r"(?:implants?|implantes?|protesis|prosthes\w*)"
    surgery = r"(?:surg(?:ery|ical)|cirugia|quirurgic\w*|reduccion|reduction)"
    if re.search(rf"\b{chin}\b.{{0,45}}\b(?:{implant}|{surgery})\b|"
                 rf"\b(?:{implant}|{surgery})\b.{{0,45}}\b{chin}\b", cleaned):
        return not nonsurgical
    if not re.search(r"\b(?:mentoplast\w*|genioplast\w*)\b", f"{label} {path}"):
        return False
    injectable = bool(re.search(
        r"\b(?:hyaluronic\s+acid|acido\s+hialuronico|acid\s+hialuronic|inject\w*|inyec\w*)\b", label))
    return not (nonsurgical or injectable)


def validate_evidence(
    evidence: ExtractedEvidence,
    full_page_text: str,
    html: str = "",
    city: str = "",
) -> tuple[bool, bool, float, str, str]:
    source = classify_page_source(evidence.source_url, full_page_text)
    own_phrase = own_language(evidence.raw_evidence)
    if evidence.extraction_method == "clinic_owned_paragraph":
        own_phrase = clinic_paragraph_matches_site(evidence.raw_evidence, evidence.source_url)
    if evidence.extraction_method == "owned_tariff_list":
        own_phrase = clinic_paragraph_matches_site(evidence.raw_evidence, evidence.source_url)
    evidence_type = classify_evidence_type(
        evidence.source_url,
        html,
        full_page_text,
        evidence,
    )
    scope_failure = injectable_scope_rejection(
        canonicalize_procedure(evidence.raw_procedure_text),
        evidence.raw_procedure_text, evidence.raw_evidence, source_url=evidence.source_url,
    )
    if scope_failure:
        return False, False, 0.05, scope_failure, evidence_type
    if page_disclaims_clinic_prices(full_page_text):
        return False, False, 0.10, "page_disclaims_clinic_prices", evidence_type
    if source == "marketplace" and not marketplace_price_evidence_is_strong(
            evidence, evidence.raw_procedure_text):
        return False, False, 0.10, "weak_marketplace_price_binding", evidence_type
    if tariff_location_conflict(tariff_location_context(html), city):
        return False, False, 0.10, "foreign_tariff_heading", evidence_type
    if (source == "official_clinic"
            and evidence_type in {"official_price_menu", "official_treatment_page"}
            and evidence.extraction_method in {"procedure_quick_facts", "scoped_tariff_table_row", "aligned_tariff_columns",
                                              "scoped_graft_card", "standalone_tariff_sentence", "dom_tariff_row"}):
        # These methods bind an explicit treatment/brand and price in one
        # menu. Article/comparison gates below still run before ownership.
        own_phrase = True

    if news_report_url(evidence.source_url):
        return False, False, 0.05, "news_report", "official_article"

    if country_price_guide_path(evidence.source_url):
        return False, False, 0.10, "comparative_market_article", evidence_type
    if cross_country_price_comparison(full_page_text):
        return False, False, 0.10, "cross_country_price_comparison", evidence_type
    if foreign_quoted_price_country(evidence.raw_evidence, city):
        return False, False, 0.10, "foreign_quoted_price_country", evidence_type
    if nonfacial_tariff_scope(canonicalize_procedure(evidence.raw_procedure_text),
            evidence.raw_procedure_text + " " + priced_line_text(
                evidence.raw_evidence, evidence.price_min, evidence.currency)):
        return False, False, 0.10, "nonfacial_tariff_scope", evidence_type

    if consultation_fee_evidence(evidence):
        return False, False, 0.10, "consultation_fee", evidence_type

    if seasonal_offer_needs_confirmation(evidence.raw_evidence):
        return False, False, 0.10, "seasonal_offer_unconfirmed", evidence_type

    if re.search(r'(?:/\s*(?:month|mo)\b|per\s+month|monthly\s+(?:payment|installment)|'
                 r'(?:financing|finance)\s+(?:for|from)|\brate\s+lunare\b)',
                 fold(evidence.raw_evidence)):
        return False, False, 0.10, 'monthly_financing', evidence_type

    if source == "directory":
        return False, False, 0.20, "directory_unverified", evidence_type

    if (
        source == "official_clinic"
        and comparative_market_article_context(
            evidence.source_url, full_page_text,
        )
        and evidence.extraction_method not in {"clinic_owned_paragraph", "clinic_comparison_column"}
        and not (evidence.extraction_method == "heading_price_pair"
                 and clinic_paragraph_matches_site(evidence.raw_evidence, evidence.source_url))
    ):
        return False, False, 0.10, "comparative_market_article", evidence_type

    own_column_prices = comparative_clinic_table_prices(
        html, evidence.source_url, evidence.raw_procedure_text,
    ) if source == "official_clinic" else set()
    if own_column_prices and (
        round(evidence.price_min, 2), evidence.currency
    ) not in own_column_prices:
        return False, False, 0.10, "foreign_comparison_column", evidence_type
    if (source == "official_clinic" and not own_column_prices
            and (round(evidence.price_min, 2), evidence.currency)
            in unresolved_comparison_table_prices(
                html, evidence.raw_procedure_text,
            )):
        return False, False, 0.10, "unresolved_comparison_column", evidence_type

    if foreign_price_source_path(evidence.source_url, city):
        return False, False, 0.10, "foreign_price_source_path", evidence_type
    if foreign_quoted_price_city(evidence.raw_evidence, city):
        return False, False, 0.10, "foreign_quoted_price_city", evidence_type

    line = priced_line_text(
        evidence.raw_evidence, evidence.price_min, evidence.currency,
    )
    if procedure_line_is_bundle(line, evidence.raw_procedure_text or ""):
        return False, False, 0.10, "package_not_procedure", evidence_type

    if source == "official_clinic" and explicit_multi_provider_agency(full_page_text):
        return False, False, 0.10, "multi_provider_agency_price", evidence_type

    if source == "official_clinic" and generic_multi_clinic_price_context(
        evidence.raw_evidence
    ):
        return False, False, 0.15, "generic_multi_clinic_price", evidence_type
    canonical = canonicalize_procedure(evidence.raw_procedure_text)
    line = priced_line_text(evidence.raw_evidence, evidence.price_min, evidence.currency)
    if canonical == "filler" and surgical_chin_quote(line, evidence.source_url):
        return False, False, 0.10, "surgical_chin_not_filler", evidence_type
    if procedure_line_is_bundle(line, canonical):
        return False, False, 0.10, "package_not_procedure", evidence_type

    if (
        canonicalize_procedure(evidence.raw_procedure_text) == "rhinoplasty"
        and nonprimary_rhinoplasty_variant(evidence.raw_evidence)
    ):
        return False, False, 0.15, "nonprimary_rhinoplasty_variant", evidence_type

    if (
        canonicalize_procedure(evidence.raw_procedure_text) == "botox"
        and botox_noninjectable_context(evidence.raw_evidence)
    ):
        return False, False, 0.05, "botox_noninjectable_context", evidence_type

    if (
        market_info(evidence.raw_evidence)
        and not own_phrase
        and not marketplace_profile_local_starting_price(evidence, source)
    ):
        return False, False, 0.20, "market_context", evidence_type

    if (
        source == "official_clinic"
        and not own_phrase
        and third_party_provider_price_context(evidence)
    ):
        return False, False, 0.15, "third_party_provider_quote", evidence_type

    if (
        source == "official_clinic"
        and not own_phrase
        and foreign_market_price_context(
            evidence,
            full_page_text,
            city,
        )
    ):
        return False, False, 0.15, "foreign_market_context", evidence_type

    if (
        source == "official_clinic"
        and not own_phrase
        and agency_or_directory_page_context(full_page_text)
    ):
        return False, False, 0.20, "agency_or_directory_context", evidence_type

    if (
        market_info(full_page_text[:1800])
        and not own_phrase
        and evidence.extraction_method == "page_window"
        and evidence_type != "official_price_menu"
    ):
        return False, False, 0.25, "market_context", evidence_type

    if source == "social":
        return False, False, 0.45, "social_unverified", evidence_type

    if source == "marketplace":
        confidence = 0.90 if evidence_type == "marketplace_service_menu" else 0.76
        return True, False, confidence, "", evidence_type

    if source == "official_clinic":
        # The clinic's own host plus a price-menu path is their tariff,
        # including /prices/{this-city}/. A multi-service menu stays owned.
        if (
            is_price_menu_path(evidence.source_url)
            and not foreign_price_source_path(evidence.source_url, city)
        ):
            return True, True, 0.97, "", "official_price_menu"

        if evidence_type == "official_price_menu":
            return True, True, 0.97, "", evidence_type

        if evidence_type == "official_treatment_page":
            return True, True, 0.93 if own_phrase else 0.90, "", evidence_type

        if evidence_type == "official_article":
            if own_phrase:
                return True, True, 0.86, "", evidence_type
            return True, False, 0.62, "", evidence_type

        return True, bool(own_phrase), 0.80 if own_phrase else 0.70, "", evidence_type

    return False, False, 0.30, "unknown_source", evidence_type


# ============================================================
# Firestore cache + hybrid selection
# ============================================================

_FIRESTORE_CLIENT = None


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def firestore_enabled() -> bool:
    return env_bool("ENABLE_FIRESTORE", False) and firestore is not None


def _firestore_client():
    global _FIRESTORE_CLIENT

    if not firestore_enabled():
        return None

    if _FIRESTORE_CLIENT is not None:
        return _FIRESTORE_CLIENT

    project = os.getenv("FIRESTORE_PROJECT_ID", "").strip() or None

    try:
        _FIRESTORE_CLIENT = firestore.Client(project=project)
    except Exception:
        return None

    return _FIRESTORE_CLIENT


def _results_collection_name() -> str:
    return os.getenv(
        "FIRESTORE_RESULTS_COLLECTION",
        "aesthetic_price_results",
    ).strip()


def _targets_collection_name() -> str:
    return os.getenv(
        "FIRESTORE_TARGETS_COLLECTION",
        "aesthetic_search_targets",
    ).strip()


def _clinics_collection_name() -> str:
    return os.getenv(
        "FIRESTORE_CLINICS_COLLECTION",
        "aesthetic_clinic_directory",
    ).strip()



def _app_candidates_collection_name() -> str:
    return os.getenv(
        "APP_CANDIDATES_COLLECTION",
        "explore_clinic_candidates",
    ).strip()


def _app_site_urls_collection_name() -> str:
    return os.getenv(
        "APP_SITE_URLS_COLLECTION",
        "clinic_site_urls",
    ).strip()


def _app_staging_collection_name() -> str:
    return os.getenv(
        "APP_PYTHON_STAGING_COLLECTION",
        "explore_python_price_staging",
    ).strip()


def _js_encode_doc_id(raw: str) -> str:
    """Mirror JS encodeURIComponent(...).replace(/%/g, '_').slice(0, 400)."""
    encoded = quote(
        str(raw or ""),
        safe="-_.!~*'()",
    ).replace("%", "_")
    return encoded[:400]


def _app_city_key(city: str) -> str:
    return str(city or "").strip().lower()


def _app_normalize_name(name: str) -> str:
    return re.sub(
        r"[^a-z0-9]+",
        " ",
        fold(name or ""),
    ).strip()


def _app_candidate_doc_id(
    city: str,
    name: str,
    website: str = "",
    place_id: str = "",
) -> str:
    ck = _app_city_key(city)
    pid = str(place_id or "").strip()

    if ck and pid:
        return _js_encode_doc_id(f"{ck}|{pid}")

    host = host_of(website or "")
    nn = _app_normalize_name(name)
    raw = (
        f"{ck}|host:{host}|{nn}"
        if host
        else f"{ck}|{nn or name or 'clinic'}"
    )
    return _js_encode_doc_id(raw)


def _app_site_url_doc_id(host_or_url: str) -> str:
    host = host_of(host_or_url) or fold(host_or_url).replace("www.", "", 1)
    return _js_encode_doc_id(host)


def _candidate_website_from_price_row(row: ClinicPriceResult) -> str:
    official = str(row.official_website or "").strip()
    if official and classify_source(official) == "official_clinic":
        return official

    if row.source_type == "official_clinic":
        host = host_of(row.source_url)
        if host:
            scheme = urlparse(row.source_url).scheme or "https"
            return f"{scheme}://{host}/"

    return ""


def _app_bridge_price_rows(
    rows: list[ClinicPriceResult],
) -> list[ClinicPriceResult]:
    """Only safe identities enter the app candidate queue.

    The app's JS verifier remains the authority for whether the price itself is
    trusted and displayable.
    """
    out = []
    seen = set()

    for row in rows:
        if not trusted_price_result(row):
            continue
        if not row.city_match:
            continue
        if row.source_type not in {"official_clinic", "marketplace"}:
            continue
        if not valid_name(row.clinic_name):
            continue

        website = _candidate_website_from_price_row(row)
        key = (
            fold(row.clinic_name),
            host_of(website),
        )
        if key in seen:
            continue

        seen.add(key)
        out.append(normalize_breast_price_result(row))

    return out


def _directory_place_id_map(
    directory_rows: list[SearchHit],
) -> dict[str, str]:
    return {
        host_of(hit.url): str(hit.place_id or "")
        for hit in directory_rows
        if hit.url and hit.place_id
    }


def _directory_name_place_map(
    directory_rows: list[SearchHit],
) -> dict[str, str]:
    return {
        _app_normalize_name(hit.title): str(hit.place_id or "")
        for hit in directory_rows
        if hit.title and hit.place_id
    }


async def firestore_sync_app_candidate_store(
    city: str,
    procedure: str,
    country_code: str,
    price_rows: list[ClinicPriceResult],
    directory_rows: list[SearchHit],
) -> int:
    """Seed the app's existing `explore_clinic_candidates` collection.

    Important: this deliberately does NOT set `priceStatus`, `procedureOffered`
    or any verified flag. The JS `verifyCandidateBatch` pipeline remains the
    judge and can promote a candidate only after its own evidence lock.
    """
    if not firestore_enabled():
        return 0

    canonical = canonicalize_procedure(procedure)
    family = canonical if canonical in PROCEDURES else ""

    # A priced clinic is much more useful to the JS verifier than an unpriced
    # directory entry. Bound the latter to avoid dozens of reads and writes on
    # every interactive request.
    capable_directory = [
        hit
        for hit in directory_rows
        if (
            valid_name(hit.title)
            and classify_source(hit.url) == "official_clinic"
            and canonical in (hit.directory_capabilities or [])
        )
    ]

    price_candidates = _app_bridge_price_rows(price_rows)
    place_by_host = _directory_place_id_map(directory_rows)
    place_by_name = _directory_name_place_map(directory_rows)

    candidates = []
    seen = set()

    directory_cap = max(0, min(12, int(os.getenv("APP_BRIDGE_MAX_DIRECTORY_CANDIDATES", "6"))))
    for hit in sorted(
        capable_directory,
        key=lambda x: (-x.directory_relevance_score, -x.directory_evidence_pages),
    )[:directory_cap]:
        website = hit.url
        name = hit.title
        place_id = str(hit.place_id or "")
        key = (fold(name), host_of(website))
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "name": name,
            "website": website,
            "place_id": place_id,
            "address": "",
            "provider": "python_directory_bridge",
        })

    for row in price_candidates:
        website = _candidate_website_from_price_row(row)
        host = host_of(website)
        name_key = _app_normalize_name(row.clinic_name)
        place_id = (
            place_by_host.get(host, "")
            or place_by_name.get(name_key, "")
        )
        key = (fold(row.clinic_name), host)
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "name": row.clinic_name,
            "website": website,
            "place_id": place_id,
            "address": "",
            "provider": "python_price_bridge",
        })

    if not candidates:
        return 0

    def _write():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_app_candidates_collection_name())
        now = datetime.now(timezone.utc)
        saved = 0

        for c in candidates:
            name = str(c["name"] or "").strip()
            if not name:
                continue

            website = str(c.get("website") or "").strip()
            place_id = str(c.get("place_id") or "").strip()
            normalized_name = _app_normalize_name(name)
            doc_id = _app_candidate_doc_id(
                city,
                name,
                website,
                place_id,
            )
            ref = collection.document(doc_id)

            payload = {
                "cityKey": _app_city_key(city),
                "cityDisplay": city,
                "city": city,
                "countryCode": (country_code or "").upper(),
                "placeId": place_id,
                "name": name,
                "normalizedName": normalized_name,
                "procedure": procedure,
                "discovery_provider": c["provider"],
                "discoveredProcedures": firestore.ArrayUnion([str(procedure)]),
                "discoveryProviders": firestore.ArrayUnion([str(c["provider"])]),
                "lastSeenAt": firestore.SERVER_TIMESTAMP,
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }

            if family:
                payload["procedureFamilies"] = firestore.ArrayUnion([family])

            if website:
                payload["website"] = website
                payload["websiteHost"] = host_of(website)

            # Rediscovery must never reset verified/rejected/retry state.
            try:
                snap = ref.get()
                old = snap.to_dict() if snap.exists else {}
            except Exception:
                old = {}

            # Existing identities and procedure families need no repeated
            # Firestore write. In particular, do not keep refreshing lastSeenAt
            # for every user search (or reset the JS verifier's retry state).
            if old and (
                (not family or family in (old.get("procedureFamilies") or []))
                and (not website or old.get("website"))
                and (not place_id or old.get("placeId"))
            ):
                continue

            if not old.get("firstSeenAt"):
                payload["firstSeenAt"] = now

            if old.get("name"):
                payload.pop("name", None)
                payload.pop("normalizedName", None)

            if old.get("website"):
                payload.pop("website", None)
                payload.pop("websiteHost", None)

            if old.get("placeId"):
                payload.pop("placeId", None)

            ref.set(payload, merge=True)
            saved += 1

        return saved

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return 0


async def firestore_sync_app_site_urls(
    city: str,
    procedure: str,
    rows: list[ClinicPriceResult],
) -> int:
    """Feed successful Python URLs into the app's `clinic_site_urls` cache.

    This lets the JS verifier try a known procedure page before repeating SERP.
    No numeric price is trusted here.
    """
    if not firestore_enabled():
        return 0

    canonical = canonicalize_procedure(procedure)
    family = canonical if canonical in PROCEDURES else ""
    incoming = []

    for row in _app_bridge_price_rows(rows):
        if row.source_type == "official_clinic":
            host_or_url = row.source_url
            url = row.source_url
            success = True
        else:
            official = _candidate_website_from_price_row(row)
            if not official:
                continue
            host_or_url = official
            url = official
            success = bool(row.official_procedure_verified)

        host = host_of(host_or_url)
        if not host or classify_source(f"https://{host}/") != "official_clinic":
            continue

        incoming.append({
            "host": host,
            "url": url,
            "clinic_name": row.clinic_name,
            "success": success,
            "extraction_method": f"python_{row.evidence_type}",
        })

    if not incoming:
        return 0

    def _write():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_app_site_urls_collection_name())
        now = datetime.now(timezone.utc)
        now_iso = now.isoformat()
        touched = 0

        grouped = {}
        for item in incoming:
            grouped.setdefault(item["host"], []).append(item)

        for host, items in grouped.items():
            ref = collection.document(_app_site_url_doc_id(host))

            try:
                snap = ref.get()
                old = snap.to_dict() if snap.exists else {}
            except Exception:
                old = {}

            merged = {}
            for e in old.get("entries", []) or []:
                if isinstance(e, dict) and e.get("url"):
                    merged[str(e["url"])] = dict(e)

            if not merged:
                for u in old.get("urls", []) or []:
                    if u:
                        merged[str(u)] = {
                            "url": str(u),
                            "extractionMethod": "",
                            "procedureFamily": "",
                            "canonicalProcedure": "",
                            "lastSuccessAt": "",
                            "successCount": 0,
                            "failureCount": 0,
                        }

            clinic_name = ""
            added_url = False
            for item in items:
                clinic_name = clinic_name or item["clinic_name"]
                if item["url"] in merged:
                    continue
                added_url = True
                prev = merged.get(item["url"], {})
                success_count = int(prev.get("successCount", 0) or 0)
                failure_count = int(prev.get("failureCount", 0) or 0)
                last_success = str(prev.get("lastSuccessAt", "") or "")

                if item["success"]:
                    success_count += 1
                    last_success = now_iso

                # JS already has this URL and can recheck it when needed.
                # Repeated Python reads must not inflate successCount.
                merged[item["url"]] = {
                    "url": item["url"],
                    "extractionMethod": (
                        item["extraction_method"]
                        or prev.get("extractionMethod", "")
                    ),
                    "procedureFamily": (
                        family
                        or prev.get("procedureFamily", "")
                    ),
                    "canonicalProcedure": (
                        canonical
                        or prev.get("canonicalProcedure", "")
                    ),
                    "lastSuccessAt": last_success,
                    "successCount": success_count,
                    "failureCount": failure_count,
                }

            if not added_url:
                continue
            entries = list(merged.values())[:60]
            ref.set({
                "host": host,
                "clinicName": clinic_name or old.get("clinicName", ""),
                "city": city,
                "lastProcedure": procedure,
                "source": "python_discovery_bridge",
                "urls": [e["url"] for e in entries],
                "entries": entries,
                "updatedAt": firestore.SERVER_TIMESTAMP,
                "updatedAtMs": int(now.timestamp() * 1000),
            }, merge=True)
            touched += 1

        return touched

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return 0


async def firestore_stage_python_price_evidence(
    city: str,
    procedure: str,
    country_code: str,
    rows: list[ClinicPriceResult],
) -> int:
    """Store Python's literal evidence for audit/secondary verification only.

    Flutter does not read this collection and these rows are never marked
    verified. The existing JS trust pipeline may consume it in a later bridge.
    """
    if not firestore_enabled():
        return 0

    safe_rows = _app_bridge_price_rows(rows)
    if not safe_rows:
        return 0

    def _write():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_app_staging_collection_name())
        now = datetime.now(timezone.utc)
        written = 0

        for row in safe_rows:
            website = _candidate_website_from_price_row(row)
            raw = "|".join([
                _app_city_key(city),
                canonicalize_procedure(procedure),
                fold(row.clinic_name),
                row.source_url,
                str(row.price_min),
                str(row.price_max or ""),
                row.currency,
            ])
            doc_id = hashlib.sha1(raw.encode("utf-8")).hexdigest()

            payload = {
                "city": city,
                "cityKey": _app_city_key(city),
                "countryCode": (country_code or "").upper(),
                "clinicName": row.clinic_name,
                "website": website,
                "sourceUrl": row.source_url,
                "sourceHost": row.source_host,
                "sourceType": row.source_type,
                "evidenceType": row.evidence_type,
                "procedure": procedure,
                "procedureFamily": canonicalize_procedure(procedure),
                "procedureCanonical": row.procedure_canonical,
                "procedureDetail": row.procedure_detail,
                "rawProcedureText": row.raw_procedure_text,
                "rawEvidence": row.raw_evidence,
                "priceMin": row.price_min,
                "priceMax": row.price_max,
                "originalPriceMin": row.original_price_min,
                "originalPriceMax": row.original_price_max,
                "currency": row.currency,
                "qualifier": row.qualifier,
                "unit": row.unit,
                "confidence": row.confidence,
                "pythonPriceVerificationStatus": row.price_verification_status,
                "officialProcedureVerified": row.official_procedure_verified,
                "officialPriceFound": row.official_price_found,
                "marketplaceSourceUrl": row.marketplace_source_url,
                "marketplaceRawEvidence": row.marketplace_raw_evidence,
                "status": "pending_js_verification",
                "trustedByFlutter": False,
                "discoveryProvider": "python_v11_43",
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }

            try:
                snap = collection.document(doc_id).get()
                old = snap.to_dict() if snap.exists else {}
            except Exception:
                old = {}

            # A JS verifier may mark this row as reviewed. Repeated discovery
            # must never put a reviewed row back into its pending queue.
            if old:
                continue

            if not old.get("createdAt"):
                payload["createdAt"] = now

            collection.document(doc_id).set(payload, merge=True)
            written += 1

        return written

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return 0


def _search_key(city: str, procedure: str) -> str:
    return f"{canonical_city(city)}|{canonicalize_procedure(procedure)}"


def _clinic_key_from_result(row: ClinicPriceResult) -> str:
    name = fold(row.clinic_name)
    host = fold(row.source_host)
    return f"{name}|{host}"


def _offer_document_id(
    city: str,
    procedure: str,
    row: ClinicPriceResult,
) -> str:
    raw = "|".join(
        [
            _search_key(city, procedure),
            _clinic_key_from_result(row),
            fold(row.unit),
            fold(row.product_brand),
            fold(row.product_line),
        ]
    )
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def _target_document_id(city: str, procedure: str) -> str:
    return hashlib.sha1(
        _search_key(city, procedure).encode("utf-8")
    ).hexdigest()


def _evidence_quality(evidence_type: str) -> int:
    return {
        "official_price_menu": 6,
        "official_treatment_page": 5,
        "marketplace_service_menu": 4,
        "marketplace_profile": 3,
        "official_article": 2,
        "official_page": 1,
        "unknown": 0,
    }.get(evidence_type or "unknown", 0)


def official_tariff_takes_priority(
    existing: ClinicPriceResult, candidate: ClinicPriceResult,
) -> bool:
    """Do not replace this clinic's tariff with its article or treatment copy."""
    return bool(
        existing.source_type == candidate.source_type == "official_clinic"
        and existing.procedure_canonical == candidate.procedure_canonical
        and _clinic_compare_key(existing.clinic_name)
            == _clinic_compare_key(candidate.clinic_name)
        and host_of(existing.source_url) == host_of(candidate.source_url)
        and existing.evidence_type == "official_price_menu"
        and candidate.evidence_type != "official_price_menu"
    )


def _datetime_to_iso(value) -> str:
    if isinstance(value, datetime):
        try:
            return value.astimezone(timezone.utc).isoformat()
        except Exception:
            return value.isoformat()
    return ""


def _age_days(value) -> int | None:
    if not isinstance(value, datetime):
        return None

    try:
        now = datetime.now(timezone.utc)
        dt = value
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return max(0, int((now - dt.astimezone(timezone.utc)).total_seconds() // 86400))
    except Exception:
        return None


async def firestore_is_available() -> bool:
    if not firestore_enabled():
        return False

    def _check():
        client = _firestore_client()
        if client is None:
            return False
        # Lightweight client creation is enough here; real reads/writes below
        # report failures without crashing the live search.
        return True

    return await asyncio.to_thread(_check)


async def firestore_upsert_results(
    city: str,
    procedure: str,
    country_code: str,
    rows: list[ClinicPriceResult],
    discovered_by: str = "live_search",
) -> int:
    if not rows or not firestore_enabled():
        return 0
    rows = [normalize_breast_price_result(row) for row in rows
            if trusted_price_result(row)]
    if not rows:
        return 0

    def _write():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_results_collection_name())
        now = datetime.now(timezone.utc)
        search_key = _search_key(city, procedure)
        canonical = canonicalize_procedure(procedure)
        written = 0

        for row in rows:
            doc_id = _offer_document_id(city, procedure, row)
            ref = collection.document(doc_id)

            try:
                snap = ref.get()
                old = snap.to_dict() if snap.exists else {}
            except Exception:
                old = {}

            if old.get("active") is not False and isinstance(old.get("result"), dict):
                try:
                    previous = ClinicPriceResult.model_validate(old["result"])
                    if official_tariff_takes_priority(previous, row):
                        continue
                except Exception:
                    pass

            payload = {
                "search_key": search_key,
                "city_key": canonical_city(city),
                "city": city,
                "country_code": (country_code or "").upper(),
                "procedure_canonical": canonical,
                "clinic_key": _clinic_key_from_result(row),
                "active": True,
                "result": row.model_dump(),
                "last_seen_at": now,
                "last_verified_at": now,
                "updated_at": now,
                "discovered_by": discovered_by,
                "seen_count": int(old.get("seen_count", 0) or 0) + 1,
            }

            if not old.get("first_seen_at"):
                payload["first_seen_at"] = now

            ref.set(payload, merge=True)
            written += 1

        return written

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return 0



# ============================================================
# Clinic-directory quality gate
# ============================================================

DIRECTORY_AESTHETIC_TERMS = [
    "aesthetic", "aesthetics", "esthetic", "esthetics", "estetike", "estetik",
    "medical aesthetics", "aesthetic medicine", "beauty clinic", "skin clinic",
    "skin care clinic", "dermatology", "dermatolog", "plastic surgery",
    "kirurgji plastike", "cosmetic surgery", "injectable", "injectables",
    "botox", "botulinum", "dermal filler", "lip filler", "filler", "fillers",
    "hyaluronic acid", "acidi hialuronik", "rhinoplasty", "rinoplastika",
    "blepharoplasty", "facelift", "liposuction", "breast augmentation",
    "breast implant", "hair transplant", "mesotherapy", "microneedling",
    "chemical peel", "peeling kimik", "hifu", "skin booster", "profhilo",
    "anti-aging", "anti ageing", "facial treatment", "skin treatment",
]

DIRECTORY_STRONG_PROCEDURE_TERMS = [
    "botox", "botulinum", "dermal filler", "lip filler", "fillers",
    "rhinoplasty", "rinoplastika", "plastic surgery", "kirurgji plastike",
    "blepharoplasty", "facelift", "liposuction", "breast augmentation",
    "breast implant", "hair transplant", "chemical peel", "peeling kimik",
    "microneedling", "hifu", "profhilo", "skin booster", "mesotherapy",
    "acidi hialuronik",
]

DIRECTORY_PROVIDER_TERMS = [
    "our clinic", "klinika jone", "klinika jonë", "our doctors", "our doctor",
    "our surgeons", "our surgeon", "our medical team", "our team",
    "book appointment", "make appointment", "book consultation",
    "free consultation", "patient", "patients", "treatment", "treatments",
    "procedure", "procedures", "clinic", "klinika", "doctor", "surgeon",
]

DIRECTORY_RETAIL_TERMS = [
    "add to cart", "shopping cart", "checkout", "shop now", "buy now",
    "free shipping", "shipping policy", "returns & refunds", "returns and refunds",
    "wishlist", "product catalog", "our products", "online shop", "cosmetics store",
    "wholesale", "distributor", "dyqan", "dyqani", "shporta",
    "shto ne shporte", "shto në shportë", "porosit", "porosia",
    "transporti", "kthimet", "rimbursimet",
    "lista e deshirave", "lista e dëshirave",
]

DIRECTORY_AGENCY_TERMS = [
    "medical tourism agency", "medical tourism facilitator", "medical tourism",
    "medical travel", "travel package", "tour package", "partner clinics",
    "compare clinics", "find a clinic", "tourism services", "travel agency",
    "flight", "flights", "hotel", "accommodation", "airport transfer",
    "companion", "travel arrangements", "arrange your trip",
    "turizem mjekesor", "turizëm mjekësor", "akomodim", "hotel falas",
    "transfer aeroport", "udhetim", "udhëtim",
]

DIRECTORY_UNRELATED_NAME_TERMS = [
    "cardiology", "cardiologist", "kardiolog", "kardiologjike",
    "gastroenterology", "nephrology", "neurology", "urology",
]

DIRECTORY_ENT_NAME_TERMS = [
    "ent clinic", "otolaryngology", "otolaringolog", "rhinology", "rinologji",
]

DIRECTORY_RETAIL_PLACE_TYPES = {
    "cosmetics_store", "clothing_store", "shopping_mall",
    "department_store", "store", "pharmacy",
}

DIRECTORY_AGENCY_PLACE_TYPES = {
    "tour_agency", "travel_agency", "tourist_information_center",
}


DIRECTORY_SERVICE_LINK_HINTS = [
    "service", "services", "treatment", "treatments", "procedure", "procedures",
    "aesthetic", "estetik", "derma", "skin", "injectable", "botox", "filler",
    "rhinoplasty", "rinoplast", "plastic", "surgery", "kirurg", "breast",
    "hair", "transplant", "peel", "microneedling", "hifu", "price", "pricing",
    "cmim", "çmim", "sherbim", "shërbim",
    "prezzi", "listino", "preisliste", "preise", "gebuhren", "gebuehren",
]


def directory_candidate_links(base_url: str, html: str, limit: int = 6) -> list[str]:
    """Pick a few internal service/procedure pages for directory verification."""
    if not html:
        return []

    soup = BeautifulSoup(html, "lxml")
    base_host = host_of(base_url)
    scored = {}

    for a in soup.find_all("a", href=True):
        href = str(a.get("href") or "").strip()
        if not href or href.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue

        absolute = safe_http_urljoin(base_url, href)
        if host_of(absolute) != base_host:
            continue
        if absolute.rstrip("/") == base_url.rstrip("/"):
            continue

        label = " ".join(a.stripped_strings)
        blob = fold(f"{label} {urlparse(absolute).path}")

        if any(x in blob for x in ["privacy", "cookie", "terms", "login", "cart", "checkout"]):
            continue

        score = 0
        for hint in DIRECTORY_SERVICE_LINK_HINTS:
            if fold(hint) in blob:
                score += 3

        # Procedure aliases are especially strong.
        for spec in PROCEDURES.values():
            for alias in spec.get("aliases", []):
                a_fold = fold(alias)
                if len(a_fold) >= 4 and a_fold in blob:
                    score += 5
                    break

        if any(x in blob for x in ["blog", "news", "category", "tag", "author"]):
            score -= 2

        if score <= 0:
            continue

        scored[absolute] = max(score, scored.get(absolute, 0))

    return [
        url for url, _ in sorted(
            scored.items(),
            key=lambda item: (-item[1], len(item[0])),
        )[:limit]
    ]


def _directory_signal_text(html: str, url: str = "") -> str:
    """High-signal page structure, avoiding arbitrary body/footer mentions."""
    soup = BeautifulSoup(html or "", "lxml")
    parts = [url]

    if soup.title:
        parts.append(soup.title.get_text(" ", strip=True))

    for node in soup.find_all(["h1", "h2", "h3", "h4"]):
        parts.append(node.get_text(" ", strip=True))

    # Navigation/service links are useful evidence that the clinic offers a
    # procedure, while random article body text is much noisier.
    for a in soup.find_all("a", href=True):
        label = a.get_text(" ", strip=True)
        href = str(a.get("href") or "")
        if label or href:
            parts.append(f"{label} {href}")

    # JSON-LD service names can also be high-signal.
    for node in soup.find_all("script", attrs={"type": "application/ld+json"}):
        raw = node.string or node.get_text(" ", strip=True)
        if raw:
            parts.append(raw[:12000])

    return fold(" ".join(parts))


def extract_directory_capabilities_from_pages(
    pages: list[tuple[str, str]],
) -> list[str]:
    """Infer procedures from titles/headings/navigation/service URLs.

    This deliberately does not scan every body sentence, which previously made
    unrelated blog/footer mentions look like clinic capabilities.
    """
    signal = " ".join(
        _directory_signal_text(html, url)
        for url, html in pages
        if html
    )

    capabilities = []

    for canonical, spec in PROCEDURES.items():
        aliases = [fold(x) for x in spec.get("aliases", []) if x]
        if any(alias and alias in signal for alias in aliases):
            capabilities.append(canonical)

    return sorted(set(capabilities))


def _directory_url_relevance(url: str) -> int:
    blob = fold(urlparse(url).path)
    score = 0
    for hint in DIRECTORY_SERVICE_LINK_HINTS:
        if fold(hint) in blob:
            score += 2
    for spec in PROCEDURES.values():
        for alias in spec.get("aliases", []):
            a = fold(alias)
            if len(a) >= 4 and a in blob:
                score += 4
                break
    if any(x in blob for x in ["blog", "news", "author", "tag", "category"]):
        score -= 2
    return score


def _sitemap_locs(xml_text: str) -> list[str]:
    if not xml_text:
        return []
    return [
        unescape(x.strip())
        for x in re.findall(r"<loc[^>]*>(.*?)</loc>", xml_text, flags=re.I | re.S)
        if x.strip()
    ]


async def directory_sitemap_candidate_urls(
    base_url: str,
    semaphore: asyncio.Semaphore,
    limit: int = 8,
) -> list[str]:
    """Find service/procedure URLs from sitemap.xml without search APIs."""
    if not host_of(base_url):
        return []
    parsed = urlparse(base_url)
    root = f"{parsed.scheme}://{parsed.netloc}"

    async def fetch(url: str) -> str:
        async with semaphore:
            return await fetch_text_document(url)

    first = await fetch(urljoin(root + "/", "sitemap.xml"))
    if not first:
        return []

    locs = _sitemap_locs(first)
    child_sitemaps = [u for u in locs if u.lower().endswith(".xml")][:2]
    page_urls = [u for u in locs if not u.lower().endswith(".xml")]

    if child_sitemaps:
        children = await asyncio.gather(
            *(fetch(u) for u in child_sitemaps),
            return_exceptions=True,
        )
        for item in children:
            if isinstance(item, Exception) or not item:
                continue
            page_urls.extend(
                u for u in _sitemap_locs(item)
                if not u.lower().endswith(".xml")
            )

    base_host = host_of(base_url)
    scored = {}
    for u in page_urls:
        if host_of(u) != base_host:
            continue
        s = _directory_url_relevance(u)
        if s > 0:
            scored[u] = max(s, scored.get(u, 0))

    ordered = sorted(scored.items(), key=lambda kv: (-kv[1], len(kv[0])))
    return [u for u, _score in ordered[:limit]]


async def firestore_load_trusted_official_hosts(city: str) -> dict[str, list[str]]:
    """Official hosts already supported by trusted clinic-owned saved prices."""
    if not firestore_enabled():
        return {}

    def _read():
        client = _firestore_client()
        if client is None:
            return {}
        try:
            docs = list(
                client.collection(_results_collection_name())
                .where("city_key", "==", canonical_city(city))
                .limit(500)
                .stream()
            )
        except Exception:
            return {}

        hosts = {}
        for doc in docs:
            data = doc.to_dict() or {}
            if data.get("active") is False:
                continue
            raw = data.get("result")
            if not isinstance(raw, dict):
                continue
            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue
            if not trusted_price_result(row):
                continue
            if row.source_type != "official_clinic" or not row.clinic_own_price:
                continue
            host = host_of(row.source_url) or fold(row.source_host)
            if not host:
                continue
            hosts.setdefault(host, [])
            canonical = row.procedure_canonical or ""
            if canonical and canonical not in hosts[host]:
                hosts[host].append(canonical)
        return hosts

    try:
        return await asyncio.to_thread(_read)
    except Exception:
        return {}


async def crawl_directory_site_pages(
    hit: SearchHit,
    homepage_html: str,
    semaphore: asyncio.Semaphore,
) -> list[tuple[str, str]]:
    """Homepage + nav/service links + sitemap-discovered service pages."""
    pages = [(hit.url, homepage_html)]
    limit = max(1, int(os.getenv("CLINIC_DIRECTORY_INTERNAL_PAGES", "8")))
    links = directory_candidate_links(hit.url, homepage_html, limit=limit)

    if len(links) < limit:
        try:
            sitemap_links = await directory_sitemap_candidate_urls(
                hit.url,
                semaphore,
                limit=limit,
            )
        except Exception:
            sitemap_links = []
        for url in sitemap_links:
            if url not in links:
                links.append(url)
            if len(links) >= limit:
                break

    async def fetch_one(url: str):
        async with semaphore:
            html = await fetch_html(url)
        return url, html

    if links:
        children = await asyncio.gather(
            *(fetch_one(url) for url in links[:limit]),
            return_exceptions=True,
        )
        for item in children:
            if isinstance(item, Exception):
                continue
            url, html = item
            if html:
                pages.append((url, html))

    return pages


def clinic_directory_site_quality(
    html: str,
    url: str,
    city: str,
    place_types: list[str] | None = None,
    place_primary_type: str = "",
    business_name: str = "",
) -> tuple[bool, float, str]:
    if not html:
        return False, 0.0, "unreachable"

    if is_obvious_financial_site(html):
        return False, 0.0, "irrelevant_financial_business"

    text = fold(page_text(html))
    url_blob = fold(url)
    host_blob = fold(host_of(url))
    name_blob = fold(business_name)

    types = {fold(x).replace(" ", "_") for x in (place_types or []) if x}
    primary = fold(place_primary_type).replace(" ", "_")

    aesthetic_hits = sum(1 for t in DIRECTORY_AESTHETIC_TERMS if fold(t) in text)
    strong_hits = sum(1 for t in DIRECTORY_STRONG_PROCEDURE_TERMS if fold(t) in text)
    provider_hits = sum(1 for t in DIRECTORY_PROVIDER_TERMS if fold(t) in text)
    retail_hits = sum(1 for t in DIRECTORY_RETAIL_TERMS if fold(t) in text)
    agency_hits = sum(1 for t in DIRECTORY_AGENCY_TERMS if fold(t) in text)

    retail_type = bool(types & DIRECTORY_RETAIL_PLACE_TYPES) or primary in DIRECTORY_RETAIL_PLACE_TYPES
    agency_type = bool(types & DIRECTORY_AGENCY_PLACE_TYPES) or primary in DIRECTORY_AGENCY_PLACE_TYPES

    retail_identity = any(x in f"{name_blob} {host_blob}" for x in ["shop", "store", "dyqan"])
    tourism_identity = any(
        x in f"{name_blob} {host_blob}"
        for x in ["medical tourism", "medicaltourism", "turizem mjekesor", "turizëm mjekësor"]
    )
    unrelated_identity = any(fold(x) in name_blob for x in DIRECTORY_UNRELATED_NAME_TERMS)
    ent_identity = any(fold(x) in name_blob for x in DIRECTORY_ENT_NAME_TERMS)

    if retail_hits >= 3:
        return False, 0.0, "retail"
    if retail_identity and retail_hits >= 1:
        return False, 0.0, "retail"
    if retail_type and retail_hits >= 1 and strong_hits < 2:
        return False, 0.0, "retail"

    if tourism_identity and agency_hits >= 2:
        return False, 0.0, "agency"
    if agency_type and agency_hits >= 2:
        return False, 0.0, "agency"
    if agency_hits >= 4 and provider_hits < 4:
        return False, 0.0, "agency"

    if unrelated_identity and strong_hits < 3:
        return False, 0.0, "irrelevant_specialty"

    if ent_identity and not any(
        fold(x) in text
        for x in ["rhinoplasty", "rinoplastika", "plastic surgery", "kirurgji plastike"]
    ):
        return False, 0.0, "irrelevant_specialty"

    if aesthetic_hits <= 0:
        return False, 0.0, "irrelevant"

    score = (
        0.10 * min(aesthetic_hits, 4)
        + 0.12 * min(strong_hits, 4)
        + 0.04 * min(provider_hits, 4)
    )
    if city_in_text(text[:14000], city):
        score += 0.08
    if any(x in url_blob for x in ["aesthetic", "estetik", "derma", "clinic", "medical", "beauty"]):
        score += 0.04
    score = min(score, 1.0)

    if strong_hits == 0 and provider_hits < 2 and score < 0.45:
        return False, score, "irrelevant"

    if score < float(os.getenv("MIN_CLINIC_DIRECTORY_RELEVANCE", "0.28")):
        return False, score, "irrelevant"

    return True, score, "accepted"


def is_obvious_financial_site(html: str) -> bool:
    """Reject bank navigation misread as a cosmetic 'price' menu.

    This uses the homepage's primary headings and multiple finance services,
    rather than a blacklist of domains or the word 'credit' in a clinic footer.
    """
    if not html:
        return False
    soup = BeautifulSoup(html, "lxml")
    primary = fold(" ".join(
        node.get_text(" ", strip=True)
        for node in [soup.title, *soup.find_all(["h1", "h2"], limit=6)]
        if node
    ))
    if re.search(r"\b(?:clinic|klinika|hospital|spital|surgery|rinoplast)\b", primary):
        return False
    navigation = fold(" ".join(
        a.get_text(" ", strip=True)
        for a in soup.find_all("a", href=True)[:180]
    ))
    combined = f"{primary} {navigation}"
    finance_services = [
        r"\b(?:bank|banka|banking|banke)\b",
        r"\b(?:kredi|credit|loans?)\b",
        r"\b(?:deposit|depozit|depozita)\b",
        r"\b(?:llogari|account|llogarite)\b",
        r"\b(?:kartat|cards?|debit)\b",
        r"\b(?:finance|financa|financiar)\b",
    ]
    return sum(bool(re.search(pattern, combined)) for pattern in finance_services) >= 3


def normalize_directory_clinic_name(name: str, url: str) -> str:
    candidate = clean_name(name or "")
    if (
        not candidate
        or len(candidate) > 70
        or candidate.count(",") >= 2
        or candidate.count("|") >= 2
        or not valid_name(candidate)
    ):
        candidate = clean_name(domain_brand(url))
    return candidate


_MEMORY_CLINIC_DIRECTORY: dict[str, dict[str, SearchHit]] = {}


def _directory_doc_id(city: str, website: str) -> str:
    raw = f"{canonical_city(city)}|{host_of(website)}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def _directory_memory_put(city: str, rows: list[SearchHit]) -> None:
    bucket = _MEMORY_CLINIC_DIRECTORY.setdefault(canonical_city(city), {})
    for row in rows:
        host = host_of(row.url)
        if host:
            bucket[host] = row


def _directory_memory_get(city: str) -> list[SearchHit]:
    return list(_MEMORY_CLINIC_DIRECTORY.get(canonical_city(city), {}).values())


def _directory_memory_remove(city: str, hosts: set[str]) -> None:
    bucket = _MEMORY_CLINIC_DIRECTORY.get(canonical_city(city), {})
    for host in hosts:
        bucket.pop(host, None)


async def firestore_load_clinic_directory(
    city: str,
    max_results: int = 100,
    include_inactive: bool = False,
) -> list[SearchHit]:
    """Load the clinic directory with Firestore as source of truth.

    v0.11.7 merged stale in-memory rows back into the active result set after a
    bootstrap audit. That allowed already-deactivated shops/agencies to be
    crawled again. When Firestore is available, use its current active flag and
    replace the in-memory snapshot rather than unioning old state into it.
    """
    memory = _directory_memory_get(city)
    if not include_inactive:
        memory = [x for x in memory if not x.directory_was_inactive]

    if not firestore_enabled():
        return memory

    def _read():
        client = _firestore_client()
        if client is None:
            return False, []
        try:
            docs = list(
                client.collection(_clinics_collection_name())
                .where("city_key", "==", canonical_city(city))
                .limit(max_results)
                .stream()
            )
        except Exception:
            return False, []

        out = []
        for doc in docs:
            data = doc.to_dict() or {}
            was_inactive = data.get("active") is False
            if was_inactive and not include_inactive:
                continue
            website = str(data.get("official_website") or "").strip()
            name = str(data.get("clinic_name") or "").strip()
            if not website or not name or classify_source(website) != "official_clinic":
                continue
            out.append(SearchHit(
                title=name,
                url=website,
                snippet=city,
                query="clinic_directory",
                place_id=str(data.get("google_place_id") or ""),
                place_name=name,
                place_address=str(data.get("places_address") or city),
                place_rating=(
                    float(data["places_rating"])
                    if data.get("places_rating") is not None
                    else None
                ),
                place_user_rating_count=(
                    int(data["places_user_rating_count"])
                    if data.get("places_user_rating_count") is not None
                    else None
                ),
                directory_verified=True,
                directory_relevance_score=float(data.get("site_relevance_score", 0.0) or 0.0),
                directory_capabilities=[
                    str(x) for x in (data.get("site_capabilities") or []) if x
                ],
                directory_was_inactive=was_inactive,
                directory_evidence_pages=int(data.get("site_evidence_pages", 0) or 0),
                directory_verification_source=str(
                    data.get("verification_source") or ""
                ),
            ))
        return True, out

    try:
        ok, rows = await asyncio.to_thread(_read)
    except Exception:
        ok, rows = False, []

    if not ok:
        return memory

    # Firestore is authoritative. Replace, do not merge with stale memory.
    _MEMORY_CLINIC_DIRECTORY[canonical_city(city)] = {
        host_of(x.url): x for x in rows if host_of(x.url)
    }
    return rows


async def firestore_upsert_clinic_directory(
    city: str,
    country_code: str,
    rows: list[SearchHit],
) -> int:
    """Persist a verified clinic website plus the Places rank used to order fetches.

    Rating and review count sort the city directory. They are never a price.
    """
    _directory_memory_put(city, rows)
    if not rows or not firestore_enabled():
        return len(rows)

    def _write():
        client = _firestore_client()
        if client is None:
            return 0
        collection = client.collection(_clinics_collection_name())
        now = datetime.now(timezone.utc)
        written = 0
        for row in rows:
            if not row.directory_verified or not row.url or not row.title:
                continue
            ref = collection.document(_directory_doc_id(city, row.url))
            payload = {
                "city_key": canonical_city(city),
                "city": city,
                "country_code": (country_code or "").upper(),
                "clinic_name": row.title,
                "official_website": row.url,
                "source_host": host_of(row.url),
                "google_place_id": row.place_id,
                "site_verified": True,
                "site_relevance_score": float(row.directory_relevance_score or 0.0),
                "site_capabilities": sorted(set(row.directory_capabilities or [])),
                "site_evidence_pages": int(row.directory_evidence_pages or 0),
                "verification_source": (
                    row.directory_verification_source
                    or row.query
                    or "crawler"
                ),
                "active": True,
                "inactive_reason": "",
                "deactivated_at": None,
                "last_verified_at": now,
                "updated_at": now,
            }
            if row.place_rating is not None:
                payload["places_rating"] = row.place_rating
            if row.place_user_rating_count is not None:
                payload["places_user_rating_count"] = row.place_user_rating_count
            if row.place_address:
                payload["places_address"] = row.place_address
            try:
                snap = ref.get()
                old = snap.to_dict() if snap.exists else {}
            except Exception:
                old = {}
            if not old.get("created_at"):
                payload["created_at"] = now
            ref.set(payload, merge=True)
            written += 1
        return written

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return 0


async def firestore_deactivate_clinic_directory(city: str, rejected: dict[str,str]) -> int:
    if not rejected: return 0
    hosts={h for h in rejected if h}; _directory_memory_remove(city,hosts)
    if not firestore_enabled(): return len(hosts)
    def _write():
        client=_firestore_client()
        if client is None: return 0
        collection=client.collection(_clinics_collection_name()); now=datetime.now(timezone.utc); changed=0
        for host,reason in rejected.items():
            if not host: continue
            ref=collection.document(_directory_doc_id(city,f"https://{host}/"))
            try:
                snap=ref.get()
                if not snap.exists: continue
                ref.set({"active":False,"inactive_reason":reason,"deactivated_at":now,"updated_at":now},merge=True); changed+=1
            except Exception: continue
        return changed
    try: return await asyncio.to_thread(_write)
    except Exception: return 0


async def revalidate_cached_clinic_directory(
    city: str,
    rows: list[SearchHit],
) -> tuple[list[SearchHit], dict]:
    if not rows:
        return [], {
            "deactivated": 0,
            "reactivated": 0,
            "rescued_by_price_evidence": 0,
            "rejected_irrelevant": 0,
            "rejected_retail": 0,
            "rejected_agency": 0,
            "rejected_clinics": [],
        }

    sem = asyncio.Semaphore(
        max(1, int(os.getenv("CLINIC_DIRECTORY_VERIFY_CONCURRENCY", "8")))
    )
    trusted_official_hosts = await firestore_load_trusted_official_hosts(city)

    async def check(hit: SearchHit):
        async with sem:
            homepage = await fetch_html(hit.url)

        if not homepage:
            # Do not change state because of a temporary site/network failure.
            return hit, "unreachable_keep", hit.directory_relevance_score

        pages = await crawl_directory_site_pages(hit, homepage, sem)
        combined_html = "\n".join(html for _url, html in pages if html)
        combined_text = fold(page_text(combined_html))

        # A crawler/domain-probe row without a Google Place ID needs explicit
        # local evidence on the clinic-owned site. Name-like domains alone are
        # not enough to keep a directory entry active.
        if (
            not hit.place_id
            and not city_in_text(combined_text[:30000], city)
        ):
            return None, "unverified_city", 0.0

        ok, score, reason = clinic_directory_site_quality(
            combined_html,
            hit.url,
            city,
            business_name=hit.title,
        )

        if not ok:
            host = host_of(hit.url)
            if reason == "irrelevant" and host in trusted_official_hosts:
                capabilities = sorted(set(
                    extract_directory_capabilities_from_pages(pages)
                    + trusted_official_hosts.get(host, [])
                ))
                return SearchHit(
                    title=hit.title,
                    url=hit.url,
                    snippet=city,
                    query="clinic_directory",
                    place_id=hit.place_id,
                    place_name=hit.title,
                    place_address=city,
                    directory_verified=True,
                    directory_relevance_score=max(float(score or 0.0), 0.50),
                    directory_capabilities=capabilities,
                    directory_was_inactive=hit.directory_was_inactive,
                    directory_evidence_pages=len(pages),
                    directory_verification_source=(
                        hit.directory_verification_source
                    ),
                ), "rescued_price_evidence", max(float(score or 0.0), 0.50)
            return None, reason, score

        name = normalize_directory_clinic_name(
            await resolve_clinic_name(homepage, hit.url, "", city),
            hit.url,
        ) or hit.title

        capabilities = extract_directory_capabilities_from_pages(pages)

        return SearchHit(
            title=name,
            url=hit.url,
            snippet=city,
            query="clinic_directory",
            place_id=hit.place_id,
            place_name=name,
            place_address=city,
            directory_verified=True,
            directory_relevance_score=score,
            directory_capabilities=capabilities,
            directory_was_inactive=hit.directory_was_inactive,
            directory_evidence_pages=len(pages),
            directory_verification_source=(
                hit.directory_verification_source
            ),
        ), "accepted", score

    processed = await asyncio.gather(
        *(check(x) for x in rows),
        return_exceptions=True,
    )

    accepted = []
    rejected = {}
    rejected_clinics = []
    counts = {
        "deactivated": 0,
        "reactivated": 0,
        "rescued_by_price_evidence": 0,
        "rejected_irrelevant": 0,
        "rejected_retail": 0,
        "rejected_agency": 0,
        "rejected_clinics": rejected_clinics,
    }

    for original, item in zip(rows, processed):
        if isinstance(item, Exception):
            # Preserve previous state on verifier failure.
            if not original.directory_was_inactive:
                accepted.append(original)
            continue

        hit, reason, score = item

        if reason == "unreachable_keep":
            if not original.directory_was_inactive:
                accepted.append(original)
            continue

        if hit is not None:
            accepted.append(hit)
            if reason == "rescued_price_evidence":
                counts["rescued_by_price_evidence"] += 1
            if original.directory_was_inactive:
                counts["reactivated"] += 1
            continue

        host = host_of(original.url)
        if not host:
            continue

        rejected[host] = reason or "irrelevant"
        rejected_clinics.append({
            "clinic_name": original.title,
            "official_website": original.url,
            "reason": reason or "irrelevant",
            "site_relevance_score": round(float(score or 0.0), 3),
            "was_inactive": bool(original.directory_was_inactive),
        })

        if reason == "retail":
            counts["rejected_retail"] += 1
        elif reason == "agency":
            counts["rejected_agency"] += 1
        else:
            counts["rejected_irrelevant"] += 1

    # Only count newly deactivated active rows. Already-inactive rows stay off.
    active_rejected = {
        host_of(original.url): rejected.get(host_of(original.url), "")
        for original in rows
        if not original.directory_was_inactive
        and host_of(original.url) in rejected
    }
    counts["deactivated"] = await firestore_deactivate_clinic_directory(
        city,
        active_rejected,
    )

    _directory_memory_put(city, accepted)

    # Accepted rows are written with active=True, so a false-negative from an
    # older version can recover automatically without another Places request.
    if accepted and firestore_enabled():
        def _update():
            client = _firestore_client()
            if client is None:
                return
            collection = client.collection(_clinics_collection_name())
            now = datetime.now(timezone.utc)

            for row in accepted:
                try:
                    collection.document(_directory_doc_id(city, row.url)).set({
                        "clinic_name": row.title,
                        "site_verified": True,
                        "site_relevance_score": float(row.directory_relevance_score or 0.0),
                        "site_capabilities": sorted(set(row.directory_capabilities or [])),
                        "site_evidence_pages": int(row.directory_evidence_pages or 0),
                        "verification_source": (
                            row.directory_verification_source
                            or "directory_revalidation"
                        ),
                        "active": True,
                        "inactive_reason": "",
                        "deactivated_at": None,
                        "last_verified_at": now,
                        "updated_at": now,
                    }, merge=True)
                except Exception:
                    continue

        try:
            await asyncio.to_thread(_update)
        except Exception:
            pass

    return accepted, counts


async def verify_places_clinic_websites(
    city: str,
    candidates: list[SearchHit],
) -> tuple[list[SearchHit], dict]:
    sem = asyncio.Semaphore(
        max(1, int(os.getenv("CLINIC_DIRECTORY_VERIFY_CONCURRENCY", "8")))
    )

    async def check(hit: SearchHit):
        if classify_source(hit.url) != "official_clinic":
            return None, "irrelevant", 0.0

        async with sem:
            homepage = await fetch_html(hit.url)

        if not homepage:
            return None, "unreachable", 0.0

        text = page_text(homepage)
        if (
            not strong_local_page_evidence(homepage, text, city, hit.url)
            and not city_in_text(hit.place_address, city)
        ):
            return None, "not_local", 0.0

        pages = await crawl_directory_site_pages(hit, homepage, sem)
        combined_html = "\n".join(html for _url, html in pages if html)

        ok, score, reason = clinic_directory_site_quality(
            combined_html,
            hit.url,
            city,
            hit.place_types,
            hit.place_primary_type,
            hit.title,
        )
        if not ok:
            return None, reason, score

        name = normalize_directory_clinic_name(
            await resolve_clinic_name(homepage, hit.url, "", city),
            hit.url,
        )
        if not name:
            return None, "bad_name", score

        return SearchHit(
            title=name,
            url=hit.url,
            snippet=city,
            query="clinic_directory",
            place_id=hit.place_id,
            place_name=name,
            place_address=city,
            place_rating=hit.place_rating,
            place_user_rating_count=hit.place_user_rating_count,
            place_types=hit.place_types,
            place_primary_type=hit.place_primary_type,
            directory_verified=True,
            directory_relevance_score=score,
            directory_capabilities=extract_directory_capabilities_from_pages(pages),
            directory_evidence_pages=len(pages),
        ), "accepted", score

    processed = await asyncio.gather(
        *(check(x) for x in candidates),
        return_exceptions=True,
    )

    out = []
    seen = set()
    rejected_clinics = []
    stats = {
        "rejected_irrelevant": 0,
        "rejected_retail": 0,
        "rejected_agency": 0,
        "rejected_clinics": rejected_clinics,
    }

    for original, item in zip(candidates, processed):
        if isinstance(item, Exception):
            continue

        row, reason, score = item
        if row is None:
            if reason == "retail":
                stats["rejected_retail"] += 1
            elif reason == "agency":
                stats["rejected_agency"] += 1
            elif reason not in {"unreachable", "not_local"}:
                stats["rejected_irrelevant"] += 1

            if reason not in {"unreachable", "not_local"}:
                rejected_clinics.append({
                    "clinic_name": original.title,
                    "official_website": original.url,
                    "reason": reason,
                    "site_relevance_score": round(float(score or 0.0), 3),
                })
            continue

        host = host_of(row.url)
        if not host or host in seen:
            continue

        seen.add(host)
        out.append(row)

    out.sort(key=lambda x: (
        -(x.place_user_rating_count or 0),
        -(x.place_rating or 0),
        -float(x.directory_relevance_score or 0.0),
    ))
    return out, stats


_DIRECTORY_REVALIDATED_UNTIL: dict[str, float] = {}
_DIRECTORY_REVALIDATION_LOCKS = weakref.WeakKeyDictionary()


async def bootstrap_city_clinic_directory(
    city: str,
    country_code: str,
    language: str,
    procedure: str = "",
    force: bool = False,
    max_queries: int | None = None,
) -> tuple[list[SearchHit], dict]:
    cached = await firestore_load_clinic_directory(city, include_inactive=True)
    cached_before = len(cached)
    minimum = int(os.getenv("MIN_CACHED_CLINICS_BEFORE_PLACES", "12"))
    cleanup_stats={"deactivated":0,"reactivated":0,"rescued_by_price_evidence":0,"rejected_irrelevant":0,"rejected_retail":0,"rejected_agency":0,"rejected_clinics":[]}
    city_key = canonical_city(city)
    if env_bool("REVALIDATE_CLINIC_DIRECTORY_ON_BOOTSTRAP", True) and cached:
        locks = _DIRECTORY_REVALIDATION_LOCKS.setdefault(asyncio.get_running_loop(), {})
        lock = locks.setdefault(city_key, asyncio.Lock())
        async with lock:
            if force or time.monotonic() >= _DIRECTORY_REVALIDATED_UNTIL.get(city_key, 0):
                cached,cleanup_stats=await revalidate_cached_clinic_directory(city,cached)
                _DIRECTORY_REVALIDATED_UNTIL[city_key] = time.monotonic() + max(
                    60, int(os.getenv("DIRECTORY_REVALIDATION_TTL_SECONDS", "86400"))
                )
            else:
                cached = [row for row in cached if not row.directory_was_inactive]
    else:
        cached = [row for row in cached if not row.directory_was_inactive]
    if len(cached) >= minimum and not force:
        return cached, {
            "cached_before": cached_before,
            "places_candidates": 0,
            "query_texts": [],
            "candidate_names": [],
            "candidate_hosts": [],
            "verified": len(cached),
            "added": 0,
            "deactivated":cleanup_stats["deactivated"],
            "reactivated":cleanup_stats.get("reactivated",0),
            "rescued_by_price_evidence":cleanup_stats.get("rescued_by_price_evidence",0),
            "rejected_irrelevant":cleanup_stats["rejected_irrelevant"],
            "rejected_retail":cleanup_stats["rejected_retail"],
            "rejected_agency":cleanup_stats["rejected_agency"],
            "rejected_clinics":cleanup_stats.get("rejected_clinics",[]),
            "requests_attempted": 0,
            "requests_succeeded": 0,
            "status": 0,
            "error": "",
            "quota_blocked": False,
        }

    places = GooglePlacesClient()
    if not places.configured:
        return cached, {
            "cached_before": cached_before,
            "places_candidates": 0,
            "query_texts": [],
            "candidate_names": [],
            "candidate_hosts": [],
            "verified": len(cached),
            "added": 0,
            "deactivated":cleanup_stats["deactivated"],
            "reactivated":cleanup_stats.get("reactivated",0),
            "rescued_by_price_evidence":cleanup_stats.get("rescued_by_price_evidence",0),
            "rejected_irrelevant":cleanup_stats["rejected_irrelevant"],
            "rejected_retail":cleanup_stats["rejected_retail"],
            "rejected_agency":cleanup_stats["rejected_agency"],
            "rejected_clinics":cleanup_stats.get("rejected_clinics",[]),
            "requests_attempted": 0,
            "requests_succeeded": 0,
            "status": 0,
            "error": "GOOGLE_PLACES_API_KEY is missing",
            "quota_blocked": False,
        }

    candidates = await places.discover_city_clinic_websites(
        city,
        language,
        procedure=procedure,
        max_websites=int(
            os.getenv(
                "MAX_PLACES_DISCOVERY_WEBSITES",
                "60" if procedure else "30",
            )
        ),
        max_queries=max_queries,
    )
    verified, verify_stats = await verify_places_clinic_websites(city, candidates)

    existing_hosts = {host_of(x.url) for x in cached}
    added_rows = [x for x in verified if host_of(x.url) not in existing_hosts]
    await firestore_upsert_clinic_directory(city, country_code, verified)

    merged = {host_of(x.url): x for x in cached if host_of(x.url)}
    for row in verified:
        merged[host_of(row.url)] = row
    final = list(merged.values())
    _directory_memory_put(city, final)

    return final, {
        "cached_before": cached_before,
        "places_candidates": len(candidates),
        "query_texts": list(places.queries_used),
        "candidate_names": [
            (x.place_name or x.title or domain_brand(x.url))[:120]
            for x in candidates[:50]
        ],
        "candidate_hosts": [
            host_of(x.url)
            for x in candidates[:50]
            if host_of(x.url)
        ],
        "verified": len(verified),
        "added": len(added_rows),
        "deactivated":cleanup_stats["deactivated"],
        "reactivated":cleanup_stats.get("reactivated",0),
        "rescued_by_price_evidence":cleanup_stats.get("rescued_by_price_evidence",0),
        "rejected_irrelevant":cleanup_stats["rejected_irrelevant"]+verify_stats["rejected_irrelevant"],
        "rejected_retail":cleanup_stats["rejected_retail"]+verify_stats["rejected_retail"],
        "rejected_agency":cleanup_stats["rejected_agency"]+verify_stats["rejected_agency"],
        "rejected_clinics":(
            cleanup_stats.get("rejected_clinics",[])
            + verify_stats.get("rejected_clinics",[])
        ),
        "requests_attempted": places.requests_attempted,
        "requests_succeeded": places.requests_succeeded,
        "status": places.last_status,
        "error": places.last_error,
        "quota_blocked": places.quota_blocked,
    }


def cached_foreign_market_row_needs_revalidation(
    row: ClinicPriceResult,
    city: str,
) -> bool:
    if row.source_type != "official_clinic":
        return False

    home_cc = (country_hint_for_city(city) or "").upper()
    currency_cc = CURRENCY_HOME_COUNTRY.get(
        (row.currency or "").upper()
    )

    if not home_cc or not currency_cc or home_cc == currency_cc:
        return False

    if own_language(row.raw_evidence or ""):
        return False

    if is_price_menu_path(row.source_url):
        return False

    # Tirana clinics publish their own tariff in pounds. A short treatment
    # line is that price, not a UK comparison article.
    evidence = row.raw_evidence or ""
    if (
        row.clinic_own_price
        and row.evidence_type in {"official_treatment_page", "official_price_menu"}
        and len(evidence) < 240
        and not comparative_market_article_context(row.source_url, evidence)
    ):
        return False

    return True



def cached_nonclinic_source_row_needs_revalidation(
    row: ClinicPriceResult,
) -> bool:
    """Reject legacy rows whose URL itself is not a clinic-owned source.

    Older versions could persist a directory/guide page while stamping
    `source_type=official_clinic`. Source classification must be recomputed from
    the actual URL at read/cleanup time instead of trusting the stored label.
    """
    actual = classify_page_source(row.source_url, row.raw_evidence or "")

    if actual in {"directory", "social"}:
        return True

    # A marketplace page must remain a marketplace row. It must never be
    # reinterpreted as the clinic's own official site.
    if actual == "marketplace" and row.source_type != "marketplace":
        return True

    official = str(row.official_website or "").strip()
    if (
        row.source_type == "official_clinic"
        and official
        and classify_source(official) in {"directory", "marketplace", "social"}
    ):
        return True

    return False




async def firestore_normalize_cached_units(
    city: str,
    procedure: str,
) -> int:
    """Backfill explicit pricing units from literal cached evidence."""
    if not firestore_enabled():
        return 0

    def _normalize():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_results_collection_name())
        search_key = _search_key(city, procedure)

        try:
            docs = list(
                collection.where(
                    "search_key",
                    "==",
                    search_key,
                ).limit(200).stream()
            )
        except Exception:
            return 0

        now = datetime.now(timezone.utc)
        changed = 0

        for doc in docs:
            data = doc.to_dict() or {}
            if data.get("active") is False:
                continue

            raw = data.get("result")
            if not isinstance(raw, dict):
                continue

            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue

            evidence = (
                row.raw_evidence
                or row.marketplace_raw_evidence
                or row.raw_procedure_text
                or ""
            )
            parsed = procedure_unit_of(
                evidence,
                row.procedure_canonical,
            )

            # Never downgrade a specific unit to the generic default.
            if (
                not parsed
                or parsed == "procedure"
                or parsed == row.unit
            ):
                continue

            payload = row.model_dump()
            payload["unit"] = parsed

            try:
                doc.reference.set(
                    {
                        "result": payload,
                        "unit_normalized_at": now,
                        "updated_at": now,
                    },
                    merge=True,
                )
                changed += 1
            except Exception:
                continue

        return changed

    try:
        return await asyncio.to_thread(_normalize)
    except Exception:
        return 0



async def firestore_deactivate_weak_results(
    city: str,
    procedure: str,
) -> int:
    """
    Deactivate legacy rows that older versions could have persisted even though
    they should not be displayed as clinic-specific prices.
    """
    if not firestore_enabled():
        return 0

    def _clean():
        client = _firestore_client()
        if client is None:
            return 0

        collection = client.collection(_results_collection_name())
        search_key = _search_key(city, procedure)

        try:
            docs = list(
                collection.where(
                    "search_key",
                    "==",
                    search_key,
                ).limit(200).stream()
            )
        except Exception:
            return 0

        now = datetime.now(timezone.utc)
        changed = 0

        for doc in docs:
            data = doc.to_dict() or {}

            if data.get("active") is False:
                continue

            raw = data.get("result")
            if not isinstance(raw, dict):
                continue

            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue

            reason = injectable_scope_rejection(row.procedure_canonical,
                row.raw_procedure_text, f"{row.procedure_detail} {row.raw_evidence}",
                row.clinic_name, row.source_url) or ""

            if reason:
                pass
            elif not row.city_match:
                reason = "city_not_verified"
            elif not valid_name(row.clinic_name):
                reason = "generic_page_title_not_clinic"
            elif cached_nonclinic_source_row_needs_revalidation(row):
                reason = "non_clinic_source_host"
            elif foreign_price_source_path(row.source_url, city):
                reason = "foreign_price_source_path"
            elif (
                row.procedure_canonical == "rhinoplasty"
                and nonprimary_rhinoplasty_variant(
                    f"{row.procedure_detail} {row.raw_evidence}"
                )
            ):
                reason = "nonprimary_rhinoplasty_requires_separate_procedure"
            elif (
                "whatclinic.com" in (row.source_host or host_of(row.source_url))
                and row.source_type == "marketplace"
                and (
                    row.marketplace_price_capture == "search_snippet"
                    or (
                        not row.marketplace_price_capture
                        and not row.official_price_found
                    )
                )
            ):
                # Rows written before v0.11.41 did not record whether a
                # WhatClinic price came from the actual profile or merely a
                # search snippet. Re-verify them instead of trusting stale data.
                reason = "whatclinic_requires_profile_or_official_reverification"
            elif (
                "whatclinic.com" in (row.source_host or host_of(row.source_url))
                and not whatclinic_result_is_trusted(row)
            ):
                reason = "weak_whatclinic_price_binding"
            elif (
                row.procedure_canonical == "botox"
                and not botox_result_is_trusted(row)
            ):
                reason = "weak_or_noninjectable_botox_evidence"
            elif cached_foreign_market_row_needs_revalidation(
                row,
                city,
            ):
                reason = "foreign_market_price_requires_reverification"
            elif cached_market_or_third_party_row_needs_revalidation(row):
                reason = "market_or_third_party_price_not_clinic_owned"
            elif rhinoplasty_price_column_conflict(row):
                reason = "price_belongs_to_other_column_or_range_bound"
            elif (
                row.evidence_type == "official_article"
                and not row.clinic_own_price
            ):
                reason = "generic_article_price_not_clinic_owned"
            elif (
                row.evidence_type in {"official_page", "unknown"}
                and not row.clinic_own_price
            ):
                reason = "weak_unowned_price_evidence"
            elif row.confidence < float(
                os.getenv("MIN_TRUSTED_PRICE_CONFIDENCE", "0.70")
            ):
                reason = "confidence_below_threshold"

            if not reason:
                continue

            try:
                doc.reference.set(
                    {
                        "active": False,
                        "inactive_reason": reason,
                        "deactivated_at": now,
                        "updated_at": now,
                    },
                    merge=True,
                )
                changed += 1
            except Exception:
                continue

        return changed

    try:
        return await asyncio.to_thread(_clean)
    except Exception:
        return 0




async def firestore_load_results(
    city: str,
    procedure: str,
    max_results: int = 60,
    include_stale: bool = False,
    read_only: bool = False,
) -> list[DisplayClinicPrice]:
    if not firestore_enabled():
        return []

    def _read():
        client = _firestore_client()
        if client is None:
            return []

        collection = client.collection(_results_collection_name())
        search_key = _search_key(city, procedure)

        try:
            docs = list(
                collection.where(
                    "search_key",
                    "==",
                    search_key,
                ).limit(max_results).stream()
            )
        except Exception:
            return []

        candidates = []

        for doc in docs:
            data = doc.to_dict() or {}

            if data.get("active") is False:
                continue

            raw_result = data.get("result")
            if not isinstance(raw_result, dict):
                continue

            try:
                row = ClinicPriceResult.model_validate(raw_result)
            except Exception:
                continue

            decoded_name = clean_name(row.clinic_name)
            if decoded_name and decoded_name != row.clinic_name:
                row = row.model_copy(update={"clinic_name": decoded_name})

            row, _range_normalized = normalize_cached_explicit_price_floor(row)

            if foreign_price_source_path(row.source_url, city):
                # Peer-city tariff paths (Cronosmed /preturi/iasi/ stored under
                # Timișoara) must not stay active. Places saying the brand has
                # a local branch does not make that URL a local price.
                try:
                    if read_only:
                        continue
                    now = datetime.now(timezone.utc)
                    doc.reference.set(
                        {
                            "active": False,
                            "inactive_reason": "foreign_price_source_path",
                            "deactivated_at": now,
                            "updated_at": now,
                        },
                        merge=True,
                    )
                except Exception:
                    pass
                continue

            # Seeing a saved row again is not a price recheck. An unknown
            # verification date remains unknown in the serving index.
            last_verified = data.get("last_verified_at")
            max_age_days = max(1, int(os.getenv("MAX_DISPLAY_PRICE_AGE_DAYS", "14")))
            age = _age_days(last_verified)
            if not include_stale and (age is None or age > max_age_days):
                continue
            if not trusted_price_result(row):
                continue

            if "whatclinic.com" in (
                row.source_host or host_of(row.source_url)
            ):
                row = normalize_whatclinic_cached_result(row)

            if (canonicalize_procedure(procedure) == "filler"
                    and filler_area_conflict(procedure,
                        row.raw_procedure_text + " " + tariff_price_row_name(
                            row.raw_evidence, "filler"))):
                continue

            if (
                row.source_type == "official_clinic"
                and row.clinic_own_price
                and not row.price_verification_status
            ):
                payload = row.model_dump()
                payload["price_verification_status"] = "official_price"
                payload["official_price_found"] = True
                payload["official_procedure_verified"] = has_procedure(
                    f"{row.raw_procedure_text} {row.raw_evidence}",
                    row.procedure_canonical,
                )
                payload["official_website"] = (
                    row.official_website
                    or official_site_root(row.source_url)
                )
                row = ClinicPriceResult.model_validate(payload)

            if (
                row.source_type == "marketplace"
                and row.official_website
                and blocked_for_official_resolution(
                    row.official_website
                )
            ):
                payload = row.model_dump()
                payload["official_website"] = ""
                payload["identity_verified"] = False
                payload["official_procedure_verified"] = False
                payload["official_price_found"] = False
                payload["official_price_override"] = False
                payload["price_verification_status"] = (
                    "marketplace_pending_official_verification"
                )
                row = ClinicPriceResult.model_validate(payload)

            if (
                row.source_type == "marketplace"
                and not row.price_verification_status
            ):
                payload = row.model_dump()
                payload["price_verification_status"] = (
                    "legacy_marketplace_price_pending_reverification"
                )
                payload["marketplace_source_url"] = (
                    row.marketplace_source_url or row.source_url
                )
                payload["marketplace_source_host"] = (
                    row.marketplace_source_host or row.source_host
                )
                payload["marketplace_price_min"] = (
                    row.marketplace_price_min
                    if row.marketplace_price_min is not None
                    else row.price_min
                )
                payload["marketplace_price_max"] = (
                    row.marketplace_price_max
                    if row.marketplace_price_max is not None
                    else row.price_max
                )
                payload["marketplace_currency"] = (
                    row.marketplace_currency or row.currency
                )
                payload["marketplace_raw_evidence"] = (
                    row.marketplace_raw_evidence or row.raw_evidence
                )
                row = ClinicPriceResult.model_validate(payload)

            candidates.append(
                (
                    row,
                    last_verified,
                    int(data.get("seen_count", 0) or 0),
                )
            )

        candidates.sort(
            key=lambda item: (
                1 if item[0].city_match else 0,
                _evidence_quality(item[0].evidence_type),
                1 if item[0].identity_verified else 0,
                1 if item[0].clinic_own_price else 0,
                item[0].confidence,
                item[2],
                (
                    item[1].timestamp()
                    if isinstance(item[1], datetime)
                    else 0
                ),
            ),
            reverse=True,
        )

        out = []
        seen_clinics = set()

        for row, last_verified, seen_count in candidates:
            ck = fold(row.clinic_name)

            if ck in seen_clinics:
                continue

            seen_clinics.add(ck)

            payload = row.model_dump()
            payload.update(
                {
                    "origin": "firestore",
                    "last_verified_at": _datetime_to_iso(last_verified),
                    "cache_age_days": _age_days(last_verified),
                }
            )
            out.append(DisplayClinicPrice.model_validate(payload))

        return out

    try:
        return await asyncio.to_thread(_read)
    except Exception:
        return []


async def firestore_load_historical_results(
    city: str,
    procedure: str,
    max_results: int = 300,
) -> list[DisplayClinicPrice]:
    """Load active and inactive identities, without treating them as offers.

    This history exists only to distinguish a never-seen provider from a
    corrected revalidation. Expired or rejected prices loaded here are never
    eligible for display.
    """
    if not firestore_enabled():
        return []

    def _read():
        client = _firestore_client()
        if client is None:
            return []
        try:
            docs = list(client.collection(_results_collection_name()).where(
                "search_key", "==", _search_key(city, procedure),
            ).limit(max_results).stream())
        except Exception:
            return []
        candidates = []
        for doc in docs:
            data = doc.to_dict() or {}
            raw = data.get("result")
            if not isinstance(raw, dict):
                continue
            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue
            decoded_name = clean_name(row.clinic_name)
            if decoded_name and decoded_name != row.clinic_name:
                row = row.model_copy(update={"clinic_name": decoded_name})
            verified = data.get("last_verified_at") or data.get("last_seen_at")
            payload = row.model_dump()
            payload.update(
                origin="firestore",
                last_verified_at=_datetime_to_iso(verified),
                cache_age_days=_age_days(verified),
            )
            candidates.append((
                bool(data.get("active", True)),
                verified.timestamp() if isinstance(verified, datetime) else 0,
                DisplayClinicPrice.model_validate(payload),
            ))
        candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
        return [item[2] for item in candidates]

    try:
        return await asyncio.to_thread(_read)
    except Exception:
        return []


async def firestore_register_target(
    city: str,
    procedure: str,
    country_code: str,
) -> bool:
    if not firestore_enabled():
        return False

    def _write():
        client = _firestore_client()
        if client is None:
            return False

        ref = client.collection(
            _targets_collection_name()
        ).document(_target_document_id(city, procedure))

        now = datetime.now(timezone.utc)

        try:
            snap = ref.get()
            old = snap.to_dict() if snap.exists else {}
        except Exception:
            old = {}

        payload = {
            "search_key": _search_key(city, procedure),
            "city": city,
            "country_code": (country_code or "").upper(),
            "procedure": procedure,
            "procedure_canonical": canonicalize_procedure(procedure),
            "active": True,
            "last_requested_at": now,
            "updated_at": now,
        }

        if not old.get("created_at"):
            payload["created_at"] = now

        ref.set(payload, merge=True)
        return True

    try:
        return await asyncio.to_thread(_write)
    except Exception:
        return False


async def firestore_load_targets(limit: int = 25) -> list[dict]:
    if not firestore_enabled():
        return []

    def _read():
        client = _firestore_client()
        if client is None:
            return []

        try:
            docs = list(
                client.collection(_targets_collection_name())
                .where("active", "==", True)
                .limit(limit)
                .stream()
            )
        except Exception:
            return []

        out = []
        for doc in docs:
            data = doc.to_dict() or {}
            data["_doc_id"] = doc.id
            out.append(data)

        return out

    try:
        return await asyncio.to_thread(_read)
    except Exception:
        return []


async def firestore_update_target_refresh(
    doc_id: str,
    result_count: int,
    error: str = "",
    search_mode: str = "",
    newly_discovered_count: int = 0,
) -> None:
    if not firestore_enabled() or not doc_id:
        return

    def _write():
        client = _firestore_client()
        if client is None:
            return

        ref = client.collection(_targets_collection_name()).document(doc_id)

        try:
            snap = ref.get()
            old = snap.to_dict() if snap.exists else {}
        except Exception:
            old = {}

        ref.set(
            {
                "last_refreshed_at": datetime.now(timezone.utc),
                "last_refresh_result_count": int(result_count),
                "last_refresh_error": error[:500],
                "last_search_mode": search_mode,
                "last_newly_discovered_count": int(newly_discovered_count),
                "refresh_count": int(old.get("refresh_count", 0) or 0) + 1,
            },
            merge=True,
        )

    try:
        await asyncio.to_thread(_write)
    except Exception:
        return


def _display_from_live(
    row: ClinicPriceResult,
    origin: str = "live_search",
) -> DisplayClinicPrice:
    payload = normalize_breast_price_result(row).model_dump()
    payload.update(
        {
            "origin": origin,
            "last_verified_at": datetime.now(timezone.utc).isoformat(),
            "cache_age_days": 0,
        }
    )
    return DisplayClinicPrice.model_validate(payload)


def _copy_display_origin(
    row: DisplayClinicPrice,
    origin: str,
) -> DisplayClinicPrice:
    payload = row.model_dump()
    payload["origin"] = origin
    return DisplayClinicPrice.model_validate(payload)


def _unique_display_rows(
    rows: list[DisplayClinicPrice],
) -> list[DisplayClinicPrice]:
    out = []
    seen = set()

    for row in rows:
        key = _clinic_compare_key(row.clinic_name)
        host = official_identity_host(row)
        if key in seen or any(
            related_clinic_hosts(host, official_identity_host(other))
            for other in out
        ):
            continue
        seen.add(key)
        out.append(row)

    return out


def corrected_starting_price(row: DisplayClinicPrice) -> DisplayClinicPrice:
    """Fix an older cached exact label when its own evidence says 'from'."""
    if (row.qualifier == "exact" and row.price_max is None
            and qualifier(row.raw_evidence or "", row.price_min, None) == "from"):
        return row.model_copy(update={"qualifier": "from"})
    return row


def _clinic_compare_key(name: str) -> str:
    # Normalize punctuation/case so "Klaudia'S" and "Klaudia’s" compare equal.
    return re.sub(r"[^a-z0-9]+", "", fold(name or ""))


def _stored_clinic_keys(
    rows: list[DisplayClinicPrice],
) -> set[str]:
    return {
        _clinic_compare_key(row.clinic_name)
        for row in rows
        if row.clinic_name
    }


def already_stored_clinic_hit(hit: SearchHit, req: DiscoverRequest) -> bool:
    """Reject a known provider before spending a hybrid page-fetch slot.

    Shared marketplace hosts are never excluded wholesale. A name match is
    used only for a verified directory entry or a single-clinic profile.
    """
    if not req.known_clinic_hosts and not req.known_clinic_names:
        return False
    source = classify_source(hit.url)
    if source == "official_clinic" and any(
        related_clinic_hosts(host_of(hit.url), known)
        for known in req.known_clinic_hosts
    ):
        return True
    if not req.known_clinic_names:
        return False
    if hit.directory_verified:
        candidate = hit.place_name
    elif source == "marketplace" and is_probable_single_business_hit(hit, req.city):
        candidate = marketplace_profile_name("", hit.url, hit.title, req.city)
    else:
        candidate = ""
    key = _clinic_compare_key(candidate)
    return bool(
        len(key) >= 5
        and key in {_clinic_compare_key(name) for name in req.known_clinic_names}
    )


def official_identity_host(row: ClinicPriceResult) -> str:
    """Use only an owned clinic domain for brand identity, not a directory."""
    if not row.clinic_own_price:
        return ""
    for url in (row.official_website, row.source_url):
        if classify_source(url) == "official_clinic":
            return host_of(url)
    return ""


def stored_provider_identity_host(row: DisplayClinicPrice) -> str:
    """Host used to exclude providers already represented in Firestore."""
    owned = official_identity_host(row)
    if owned:
        return owned
    website = row.official_website
    if (row.identity_verified and website
            and classify_source(website) == "official_clinic"
            and not blocked_for_official_resolution(website)):
        return host_of(website)
    return ""


def related_clinic_hosts(a: str, b: str) -> bool:
    """Exact host or parent/child subdomain; never merge sibling clinics."""
    return bool(a and b and (a == b or a.endswith("." + b) or b.endswith("." + a)))


LEGAL_ID_LABEL = re.compile(
    r"\b(?:nipt|nuis|vat(?:\s*(?:id|no|number))?|tax\s*(?:id|no|number)|"
    r"cui|cif|cod(?:ul)?\s+fiscal|codice\s+fiscale|partita\s+iva|p\.?\s*iva|"
    r"ust[- .]?id(?:nr)?|steuernummer|siret|siren|nif|nipc|bulstat|eik|"
    r"company\s+(?:registration|register)\s*(?:no|number)?)\b",
    re.I,
)
_LEGAL_IDENTITY_CACHE: dict[
    str,
    tuple[
        float,
        tuple[str, ...],
        tuple[str, ...],
        tuple[str, ...],
        tuple[str, ...],
    ],
] = {}


def _normalize_legal_identifier(value: str) -> str:
    candidate = re.sub(r"[^A-Za-z0-9]", "", value or "").upper()
    if not 6 <= len(candidate) <= 18 or not any(ch.isdigit() for ch in candidate):
        return ""
    if candidate.isdigit() and len(candidate) < 8:
        return ""
    if len(set(candidate)) <= 2:
        return ""
    return candidate


def extract_legal_identifiers(text: str) -> list[str]:
    """Extract labelled public company/tax IDs without guessing from phones."""
    found = set()
    for label in LEGAL_ID_LABEL.finditer(text or ""):
        tail = (text or "")[label.end():label.end() + 55]
        tail = re.sub(r"^[\s:#.=–—-]+", "", tail)
        match = re.match(
            r"(?:[A-Z]{2}\s*[-./]?\s*\d{6,12}|[A-Z]\d{7,10}[A-Z]|"
            r"\d{8,14}|[A-Z0-9]{6,18})\b",
            tail,
            re.I,
        )
        if not match:
            continue
        value = _normalize_legal_identifier(match.group(0))
        if value:
            found.add(value)
    return sorted(found)


LEGAL_ENTITY_SUFFIX = (
    r"(?:sh\.?p\.?k\.?|s\.?r\.?l\.?|s\.?a\.?|srl|spa|ltd\.?|limited|"
    r"llc|inc\.?|gmbh|ag|bv|sasu|sas|sl|s\.l\.|ood|eood)"
)


def _normalize_legal_entity_name(value: str) -> str:
    value = clean_name(value)
    value = re.sub(r"^[\s:;,.-]+|[\s:;,.-]+$", "", value)
    return re.sub(r"[^a-z0-9]+", "", fold(value))


def extract_legal_entity_names(text: str) -> list[str]:
    """Extract labelled operator/controller names from legal pages."""
    raw = unescape(text or "")
    labels = re.compile(
        r"(?:titolare\s+del\s+trattamento(?:\s+dei\s+dati)?|"
        r"data\s+controller|operator(?:ul)?|operated\s+by|owned\s+by|"
        r"legal\s+entity|denumirea\s+(?:societatii|societății)|"
        r"societatea)\s*(?:is|este|e|è|:|-)?\s*",
        re.I,
    )
    candidates: list[str] = []
    for label in labels.finditer(raw):
        tail = raw[label.end():label.end() + 180]
        match = re.search(
            rf"([A-ZÀ-Ý0-9][A-Za-zÀ-ÿ0-9&'’.,-]*"
            rf"(?:\s+[A-Za-zÀ-ÿ0-9&'’.,-]+){{0,8}}\s+{LEGAL_ENTITY_SUFFIX})\b",
            tail,
            re.I,
        )
        if match:
            candidates.append(clean_name(match.group(1)))
    # Also accept a legal-suffix name very near an explicit privacy/controller
    # label when punctuation split the phrase in a way the first expression
    # could not consume.
    found: dict[str, str] = {}
    for candidate in candidates:
        key = _normalize_legal_entity_name(candidate)
        if len(key) >= 5:
            found.setdefault(key, candidate)
    return sorted(found.values(), key=fold)


def extract_operator_contacts(text: str) -> list[str]:
    """Extract exact public emails/phones from contact, privacy or imprint pages."""
    raw = unescape(text or "")
    contacts = set()
    for value in re.findall(
        r"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
        raw,
    ):
        email = value.strip(" .,:;<>[]()\"").lower()
        if not email.endswith(("@example.com", "@example.org")):
            contacts.add(f"email:{email}")
    for match in re.finditer(r"(?<!\w)(\+\s*\d[\d\s()./-]{7,22}\d)(?!\w)", raw):
        digits = re.sub(r"\D", "", match.group(1))
        if 9 <= len(digits) <= 15:
            contacts.add(f"phone:+{digits}")
    return sorted(contacts)


def shared_legal_identifiers(
    first: ClinicPriceResult, second: ClinicPriceResult,
) -> set[str]:
    return set(first.legal_identifiers) & set(second.legal_identifiers)


def shared_legal_entity_names(
    first: ClinicPriceResult, second: ClinicPriceResult,
) -> set[str]:
    left = {_normalize_legal_entity_name(x) for x in first.legal_entity_names}
    right = {_normalize_legal_entity_name(x) for x in second.legal_entity_names}
    return {x for x in left & right if len(x) >= 5}


def shared_operator_contacts(
    first: ClinicPriceResult, second: ClinicPriceResult,
) -> set[str]:
    return set(first.operator_contacts) & set(second.operator_contacts)


def shared_provider_profile_url(
    first: ClinicPriceResult, second: ClinicPriceResult,
) -> bool:
    """Match a corrected provider profile even if its old owner/name was wrong."""
    def normalized(row: ClinicPriceResult) -> str:
        url = row.marketplace_source_url or row.source_url
        parsed = urlparse(url or "")
        path = re.sub(r"/+", "/", parsed.path or "/").rstrip("/")
        if not parsed.hostname or path in {"", "/"}:
            return ""
        provider_path = bool(re.search(
            r"/(?:clinic|clinics|hospital|hospitals|doctor|doctors)/[^/]+$",
            fold(path),
        ))
        if row.source_type != "marketplace" and not provider_path:
            return ""
        return f"{host_of(url)}{path}"
    left, right = normalized(first), normalized(second)
    return bool(left and left == right)


def same_clinic_identity(
    first: ClinicPriceResult,
    second: ClinicPriceResult,
    *,
    allow_legacy_name: bool = True,
) -> bool:
    """Compare providers using owned hosts, public legal IDs, then legacy names.

    A plain name can bridge only rows where at least one side has no verified
    owned host. Two different official domains are never merged by a similar
    display name alone.
    """
    first_host = official_identity_host(first)
    second_host = official_identity_host(second)
    if related_clinic_hosts(first_host, second_host):
        return True
    if shared_legal_identifiers(first, second):
        return True
    if shared_legal_entity_names(first, second):
        return True
    if shared_operator_contacts(first, second):
        return True
    if shared_provider_profile_url(first, second):
        return True
    if not allow_legacy_name:
        return False
    first_name = _clinic_compare_key(first.clinic_name)
    return bool(
        first_name
        and first_name == _clinic_compare_key(second.clinic_name)
        and (not first_host or not second_host)
    )


async def discover_official_legal_identity(
    row: ClinicPriceResult,
    procedure: str,
    language: str,
) -> tuple[list[str], list[str], list[str], list[str]]:
    """Read public operator evidence from owned pages and sitemap fallbacks."""
    host = official_identity_host(row)
    if not host:
        return [], [], [], []
    # IDs already extracted and persisted are durable identity evidence; do
    # not crawl the same contact/imprint pages again on every process start.
    if row.legal_identifiers or row.legal_entity_names or row.operator_contacts:
        return (
            sorted(set(row.legal_identifiers)),
            sorted(set(row.legal_identity_urls)),
            sorted(set(row.legal_entity_names)),
            sorted(set(row.operator_contacts)),
        )
    now = time.monotonic()
    cached = _LEGAL_IDENTITY_CACHE.get(host)
    if cached and cached[0] > now:
        return (
            list(cached[1]),
            list(cached[2]),
            list(cached[3]),
            list(cached[4]),
        )

    root = official_site_root(row.official_website or row.source_url)
    initial_urls = list(dict.fromkeys(
        url for url in (row.source_url, root) if url and host_of(url) == host
    ))
    initial_pages = await asyncio.gather(
        *(fetch_html(url) for url in initial_urls), return_exceptions=True,
    )
    identifiers: set[str] = set(row.legal_identifiers)
    evidence_urls: set[str] = set(row.legal_identity_urls)
    entity_names: set[str] = set(row.legal_entity_names)
    contacts: set[str] = set(row.operator_contacts)
    homepage_html = ""
    for url, html in zip(initial_urls, initial_pages):
        if isinstance(html, Exception) or not html:
            continue
        if url.rstrip("/") == root.rstrip("/"):
            homepage_html = html
        identity_text = page_text(html)
        found_ids = extract_legal_identifiers(identity_text)
        found_names = extract_legal_entity_names(identity_text)
        found_contacts = extract_operator_contacts(identity_text)
        if found_ids or found_names or found_contacts:
            identifiers.update(found_ids)
            entity_names.update(found_names)
            contacts.update(found_contacts)
            evidence_urls.add(url)

    direct_links = official_site_candidate_links(
        root, homepage_html, procedure, language, limit=4, identity_mode=True,
    ) if homepage_html else []
    checked = set(initial_urls)
    identity_links = [url for url in direct_links if url not in checked][:4]
    if identity_links:
        pages = await asyncio.gather(
            *(fetch_html(url) for url in identity_links), return_exceptions=True,
        )
        for url, html in zip(identity_links, pages):
            checked.add(url)
            if isinstance(html, Exception) or not html:
                continue
            identity_text = page_text(html)
            found_ids = extract_legal_identifiers(identity_text)
            found_names = extract_legal_entity_names(identity_text)
            found_contacts = extract_operator_contacts(identity_text)
            if found_ids or found_names or found_contacts:
                identifiers.update(found_ids)
                entity_names.update(found_names)
                contacts.update(found_contacts)
                evidence_urls.add(url)

    # Contact/imprint links are sometimes absent from rendered navigation but
    # present in the sitemap. Reuse the bounded sitemap discovery machinery.
    if not (identifiers or entity_names or contacts):
        sitemap_links = await official_site_sitemap_candidate_links(
            root, procedure, language, limit=4, identity_mode=True,
        )
        sitemap_links = [url for url in sitemap_links if url not in checked][:4]
        pages = await asyncio.gather(
            *(fetch_html(url) for url in sitemap_links), return_exceptions=True,
        )
        for url, html in zip(sitemap_links, pages):
            if isinstance(html, Exception) or not html:
                continue
            identity_text = page_text(html)
            found_ids = extract_legal_identifiers(identity_text)
            found_names = extract_legal_entity_names(identity_text)
            found_contacts = extract_operator_contacts(identity_text)
            if found_ids or found_names or found_contacts:
                identifiers.update(found_ids)
                entity_names.update(found_names)
                contacts.update(found_contacts)
                evidence_urls.add(url)

    ttl = max(300, int(os.getenv("LEGAL_IDENTITY_CACHE_TTL_SECONDS", "86400")))
    packed = (
        tuple(sorted(identifiers)),
        tuple(sorted(evidence_urls)),
        tuple(sorted(entity_names, key=fold)),
        tuple(sorted(contacts)),
    )
    _LEGAL_IDENTITY_CACHE[host] = (now + ttl, *packed)
    return tuple(list(values) for values in packed)


async def enrich_legal_identities(
    rows: list[ClinicPriceResult], procedure: str, language: str,
    eligible_hosts: set[str] | None = None,
) -> list[ClinicPriceResult]:
    """Enrich each official host once and copy its public IDs to all rows."""
    by_host: dict[str, ClinicPriceResult] = {}
    for row in rows:
        host = official_identity_host(row)
        if (host and row.official_website
                and classify_source(row.official_website) == "official_clinic"
                and (eligible_hosts is None or host in eligible_hosts)):
            by_host.setdefault(host, row)
    discovered = await asyncio.gather(*(
        discover_official_legal_identity(row, procedure, language)
        for row in by_host.values()
    ), return_exceptions=True)
    identity_by_host = {}
    for host, result in zip(by_host, discovered):
        if isinstance(result, Exception):
            continue
        identity_by_host[host] = result
    enriched = []
    for row in rows:
        result = identity_by_host.get(official_identity_host(row))
        if not result:
            enriched.append(row)
            continue
        ids, urls, names, contacts = result
        payload = row.model_dump()
        payload["legal_identifiers"] = sorted(set(row.legal_identifiers) | set(ids))
        payload["legal_identity_urls"] = sorted(set(row.legal_identity_urls) | set(urls))
        payload["legal_entity_names"] = sorted(
            set(row.legal_entity_names) | set(names), key=fold,
        )
        payload["operator_contacts"] = sorted(
            set(row.operator_contacts) | set(contacts),
        )
        enriched.append(type(row).model_validate(payload))
    return enriched


def cached_identity_match(
    row: ClinicPriceResult, stored_rows: list[DisplayClinicPrice],
) -> DisplayClinicPrice | None:
    for stored in stored_rows:
        if same_clinic_identity(row, stored):
            return stored
    return None


def _novel_live_rows(
    live_rows: list[DisplayClinicPrice],
    stored_rows: list[DisplayClinicPrice],
) -> list[DisplayClinicPrice]:
    out = []

    for row in live_rows:
        if (not _clinic_compare_key(row.clinic_name)
                or cached_identity_match(row, stored_rows)
                or any(same_clinic_identity(row, other) for other in out)):
            continue
        out.append(row)

    return out


def historical_identity_match(
    row: ClinicPriceResult,
    history: list[DisplayClinicPrice],
) -> DisplayClinicPrice | None:
    """Match prior identity without trusting a stale price or active status."""
    for old in history:
        if same_clinic_identity(row, old):
            return old
    return None


def split_novel_history(
    novel_rows: list[DisplayClinicPrice],
    history: list[DisplayClinicPrice],
) -> tuple[list[DisplayClinicPrice], list[DisplayClinicPrice]]:
    """Return (never-seen, inactive/stale provider reverified correctly)."""
    genuinely_new = []
    corrected = []
    for row in novel_rows:
        (corrected if historical_identity_match(row, history) else genuinely_new).append(row)
    return genuinely_new, corrected


def stabilize_live_clinic_names(
    rows: list[ClinicPriceResult],
    stored_rows: list[DisplayClinicPrice],
) -> tuple[list[ClinicPriceResult], list[dict[str, str]]]:
    """Keep the saved display name when the same official host is rechecked."""
    output = []
    changes = []
    for row in rows:
        host = official_identity_host(row)
        match = next((
            stored for stored in stored_rows
            if related_clinic_hosts(host, official_identity_host(stored))
        ), None)
        if (match is None or not match.clinic_name
                or _clinic_compare_key(match.clinic_name)
                == _clinic_compare_key(row.clinic_name)):
            output.append(row)
            continue
        payload = row.model_dump()
        payload["clinic_name"] = match.clinic_name
        output.append(ClinicPriceResult.model_validate(payload))
        changes.append({
            "host": host,
            "found_name": row.clinic_name,
            "stable_name": match.clinic_name,
        })
    return output, changes


def trusted_price_failure(row: ClinicPriceResult) -> str:
    """Why trusted_price_result rejected this row. Empty when it is trusted."""
    if news_report_url(row.source_url):
        return "news_report"
    if country_price_guide_path(row.source_url):
        return "country_price_guide"
    if (
        row.source_type == "official_clinic"
        and classify_source(row.source_url) != "official_clinic"
    ):
        return "classify_source"
    if not row.city_match:
        return "city_unverified"
    if tariff_location_conflict(row.source_location_text, row.city):
        return "foreign_tariff_heading"
    if not valid_name(row.clinic_name):
        return "bad_identity"
    blob = f"{row.raw_procedure_text} {row.procedure_detail} {row.raw_evidence}"
    scope_failure = injectable_scope_rejection(row.procedure_canonical,
        row.raw_procedure_text, blob, row.clinic_name, row.source_url)
    if scope_failure:
        return scope_failure
    if generic_multi_clinic_price_context(row.raw_evidence):
        return "market_context"
    if not literal_price_claim_is_supported(row):
        return "missing_literal_price_evidence"
    if consultation_fee_evidence(row):
        return "consultation_fee"
    if seasonal_offer_needs_confirmation(row.raw_evidence):
        return "seasonal_offer_unconfirmed"
    if (row.procedure_canonical == "botox"
            and botox_noninjectable_context(f"Botox {row.clinic_name} {row.source_url}")):
        return "noninjectable_provider"
    if row.procedure_canonical == "botox" and botox_noninjectable_context(blob):
        return "noninjectable_botox"
    if row.procedure_canonical == "botox" and botox_amount_owned_by_filler(row.raw_evidence, row.price_min, row.currency):
        return "neighbouring_filler_amount"
    if re.search(r"\brelated\s+products?\b|\bgift\s+(?:voucher|card)\b|\blorem\s+ipsum\b", fold(blob)):
        return "non_treatment_label"
    if not has_procedure(blob, row.procedure_canonical):
        return "has_procedure"
    if foreign_price_source_path(row.source_url, row.city):
        return "foreign_price_source_path"
    if foreign_quoted_price_city(row.raw_evidence, row.city):
        return "foreign_quoted_price_city"
    if foreign_quoted_price_country(row.raw_evidence, row.city):
        return "foreign_quoted_price_country"
    if foreign_provider_without_local_price_proof(row):
        return "foreign_provider_without_local_price_proof"
    if nonfacial_tariff_scope(row.procedure_canonical,
            row.raw_procedure_text + " " + priced_line_text(row.raw_evidence, row.price_min, row.currency)):
        return "nonfacial_tariff_scope"
    line = priced_line_text(row.raw_evidence, row.price_min, row.currency)
    if row.procedure_canonical == "filler" and surgical_chin_quote(line, row.source_url):
        return "surgical_chin_not_filler"
    if procedure_line_is_bundle(line, row.procedure_canonical):
        return "package_not_procedure"
    if (
        row.procedure_canonical == "filler"
        and filler_volume_is_retail_like(row.raw_evidence or "")
    ):
        return "filler_volume_is_retail_like"
    if (
        is_retail_product_page(row.source_url, row.raw_evidence or "", row.procedure_canonical)
        or is_retail_evidence_block(row.raw_evidence or "", row.procedure_canonical)
    ):
        return "retail"
    amounts = []
    for match, amount, currency in iter_exact_price_matches(row.raw_evidence or ""):
        if currency != row.currency:
            continue
        if abs(amount - row.price_min) <= .011 and price_amount_is_financing(row.raw_evidence, match):
            return "monthly_financing"
        if abs(amount - row.price_min) <= .011 and price_amount_is_add_on(row.raw_evidence, match):
            return "add_on_fee"
        bound = price_is_bound_to_procedure(
            row.raw_evidence, match, row.procedure_canonical, "cached_evidence",
        )
        if not bound:
            prices = list(iter_exact_price_matches(row.raw_evidence or ""))
            if not (
                len(prices) == 1
                and len(row.raw_evidence or "") <= 160
                and has_procedure(row.raw_evidence or "", row.procedure_canonical)
            ):
                continue
        amounts.append(amount)
    if not any(abs(amount - row.price_min) <= 0.011 for amount in amounts):
        return "unbound_amount"
    owned_menu = (
        row.source_type == "official_clinic"
        and is_price_menu_path(row.source_url)
        and not foreign_price_source_path(row.source_url, row.city)
    )
    if (
        row.evidence_type in {"official_page", "unknown"}
        and not row.clinic_own_price
        and not owned_menu
    ):
        return "unowned_official_page"
    if row.confidence < float(os.getenv("MIN_TRUSTED_PRICE_CONFIDENCE", "0.70")):
        return "confidence"
    if cached_market_or_third_party_row_needs_revalidation(row):
        return "cached_market_context"
    if not trusted_price_result(row):
        return "other"
    return ""


def literal_price_claim_is_supported(row: ClinicPriceResult) -> bool:
    """Neither an invented midpoint nor a guessed upper bound is a quote."""
    for match, amount, code in iter_exact_price_matches(row.raw_evidence):
        if code != row.currency:
            continue
        attached = find_attached_range(row.raw_evidence, code, match)
        low_matches = abs(amount - row.price_min) < .011 or (
            attached and abs(attached[0] - row.price_min) < .011)
        if not low_matches:
            continue
        if row.price_max is None or abs(row.price_max - row.price_min) < .011:
            return True
        if attached and abs(attached[0] - row.price_min) < .011 and abs(attached[1] - row.price_max) < .011:
            return True
    return False


def trusted_price_result(row: ClinicPriceResult) -> bool:
    """
    Safe persistence/display gate.

    In particular, an official clinic article that merely quotes a general
    market price must not become a clinic-owned app price.
    """
    if not literal_price_claim_is_supported(row):
        return False
    blob = f"{row.raw_procedure_text} {row.procedure_detail} {row.raw_evidence}"
    if injectable_scope_rejection(row.procedure_canonical,
            row.raw_procedure_text, blob, row.clinic_name, row.source_url):
        return False
    if (generic_multi_clinic_price_context(row.raw_evidence)
            or consultation_fee_evidence(row)
            or seasonal_offer_needs_confirmation(row.raw_evidence)):
        return False
    if (row.procedure_canonical == "botox"
            and botox_noninjectable_context(f"Botox {row.clinic_name} {row.source_url}")):
        return False
    if row.procedure_canonical == "botox" and botox_noninjectable_context(blob):
        return False
    if row.procedure_canonical == "botox" and botox_amount_owned_by_filler(row.raw_evidence, row.price_min, row.currency):
        return False
    if re.search(r"\brelated\s+products?\b|\bgift\s+(?:voucher|card)\b|\blorem\s+ipsum\b", fold(blob)):
        return False
    if news_report_url(row.source_url):
        return False
    if country_price_guide_path(row.source_url):
        return False
    if (row.source_type == "official_clinic"
            and classify_source(row.source_url) != "official_clinic"):
        return False
    if not row.city_match or not valid_name(row.clinic_name):
        return False
    if tariff_location_conflict(row.source_location_text, row.city):
        return False
    if not math.isfinite(row.price_min) or row.price_min <= 0:
        return False
    if row.price_max is not None and (
        not math.isfinite(row.price_max) or row.price_max < row.price_min
    ):
        return False
    if not re.fullmatch(r"[A-Z]{3}", row.currency or ""):
        return False
    if urlparse(row.source_url).scheme not in {"http", "https"} or not host_of(row.source_url):
        return False

    if canonicalize_procedure(row.procedure_canonical) != row.procedure_canonical:
        return False
    if not has_procedure(
        f"{row.raw_procedure_text} {row.procedure_detail} {row.raw_evidence}",
        row.procedure_canonical,
    ):
        return False
    if cached_nonclinic_source_row_needs_revalidation(row):
        return False
    if foreign_price_source_path(row.source_url, row.city):
        return False
    if foreign_quoted_price_city(row.raw_evidence, row.city):
        return False
    if foreign_quoted_price_country(row.raw_evidence, row.city):
        return False
    if foreign_provider_without_local_price_proof(row):
        return False
    if nonfacial_tariff_scope(row.procedure_canonical,
            row.raw_procedure_text + " " + priced_line_text(row.raw_evidence, row.price_min, row.currency)):
        return False
    if procedure_line_is_bundle(
        priced_line_text(row.raw_evidence, row.price_min, row.currency),
        row.procedure_canonical,
    ):
        return False
    if row.procedure_canonical == "filler" and surgical_chin_quote(
        priced_line_text(row.raw_evidence, row.price_min, row.currency), row.source_url,
    ):
        return False
    if (
        row.procedure_canonical == "rhinoplasty"
        and nonprimary_rhinoplasty_variant(
            f"{row.procedure_detail} {row.raw_evidence}"
        )
    ):
        return False
    if (
        row.procedure_canonical == "breast_augmentation"
        and breast_price_is_other_surgery(row.raw_evidence or "", row.price_min)
    ):
        return False

    # Never persist a retail product or a decimal suffix (0,53 -> 53).
    if (is_retail_product_page(row.source_url, row.raw_evidence or "", row.procedure_canonical)
            or is_retail_evidence_block(row.raw_evidence or "", row.procedure_canonical)
            or (row.procedure_canonical == "filler"
                and filler_volume_is_retail_like(row.raw_evidence or ""))):
        return False
    amounts = []
    for match, amount, currency in iter_exact_price_matches(row.raw_evidence or ""):
        if currency != row.currency:
            continue
        if abs(amount - row.price_min) <= .011 and price_amount_is_incentive(row.raw_evidence, match):
            return False
        if abs(amount - row.price_min) <= .011 and price_amount_is_financing(row.raw_evidence, match):
            return False
        if abs(amount - row.price_min) <= .011 and price_amount_is_add_on(row.raw_evidence, match):
            return False
        if not price_is_bound_to_procedure(
            row.raw_evidence, match, row.procedure_canonical, "cached_evidence",
        ):
            # Compact table evidence can legitimately put the price first.
            prices = list(iter_exact_price_matches(row.raw_evidence))
            if not (len(prices) == 1 and len(row.raw_evidence) <= 160
                    and has_procedure(row.raw_evidence, row.procedure_canonical)):
                continue
        amounts.append(amount)
        attached = find_attached_range(row.raw_evidence, currency, match)
        if attached:
            amounts.append(attached[0])
    if not any(abs(amount - row.price_min) <= 0.011 for amount in amounts):
        return False
    if any(currency == row.currency and abs(old - row.price_min) <= .011
           for _, _, old, _new, currency in iter_descending_promo_pairs(row.raw_evidence) or []):
        return False

    if not botox_result_is_trusted(row):
        return False

    if cached_market_or_third_party_row_needs_revalidation(row):
        return False

    if rhinoplasty_price_column_conflict(row):
        return False

    # Search snippets are discovery signals, not final clinic prices.
    if (
        row.source_type == "marketplace"
        and row.marketplace_price_capture == "search_snippet"
        and not row.official_price_found
    ):
        return False

    if row.evidence_type == "official_article" and not row.clinic_own_price:
        return False

    owned_menu = (
        row.source_type == "official_clinic"
        and is_price_menu_path(row.source_url)
        and not foreign_price_source_path(row.source_url, row.city)
    )
    if (
        row.evidence_type in {"official_page", "unknown"}
        and not row.clinic_own_price
        and not owned_menu
    ):
        return False

    if row.confidence < float(os.getenv("MIN_TRUSTED_PRICE_CONFIDENCE", "0.70")):
        return False

    return True




def _result_quality(row: ClinicPriceResult) -> tuple:
    # Among equally scoped trusted Botox lines, keep the starting price.
    # Other procedures still prefer the tighter evidence window.
    evidence_rank = (
        -row.price_min
        if row.procedure_canonical in {"botox", "chemical_peel"} or (
            row.procedure_canonical == "hair_transplant" and row.unit == "graft")
        else -len(row.raw_evidence or "")
    )
    line = priced_line_text(row.raw_evidence, row.price_min, row.currency)
    # A bound area/package is more useful than a page-wide starting range
    # that also includes small add-ons or medical indications. Never convert
    # a per-unit quote into an invented total treatment price.
    scoped_cosmetic = (
        row.procedure_canonical == "botox"
        and row.clinic_own_price
        and any(mark in fold(row.procedure_detail or "") for mark in (
            "upper face", "full face", "three areas", "single area", "full botox",
        ))
    )
    return (
        1 if row.city_match else 0,
        1 if scoped_cosmetic else 0,
        _evidence_quality(row.evidence_type),
        1 if row.procedure_canonical != 'chemical_peel' and generic_procedure_line(line, row.procedure_canonical) else 0,
        1 if row.identity_verified else 0,
        1 if row.clinic_own_price else 0,
        1 if row.procedure_canonical == "botox" and row.unit in {"unit", "area", "session"} else 0,
        row.confidence,
        evidence_rank,
    )


def dedupe_live_results(
    rows: list[ClinicPriceResult],
) -> list[ClinicPriceResult]:
    """Keep the strongest row for each host/legal/name identity."""
    best: list[ClinicPriceResult] = []

    for row in rows:
        if not trusted_price_result(row):
            continue

        if not (_clinic_compare_key(row.clinic_name)
                or official_identity_host(row)
                or row.legal_identifiers
                or row.legal_entity_names
                or row.operator_contacts):
            continue

        index = next((
            i for i, previous in enumerate(best)
            if same_clinic_identity(row, previous)
        ), None)
        if index is None:
            best.append(row)
        elif _result_quality(row) > _result_quality(best[index]):
            best[index] = row

    return sorted(
        best,
        key=_result_quality,
        reverse=True,
    )


def merge_live_results(
    responses: list[DiscoverResponse],
) -> list[ClinicPriceResult]:
    """Merge search rounds and keep the best evidence for each clinic."""
    return dedupe_live_results([
        row for response in responses for row in response.results
    ])


async def enrich_new_operator_identities(
    live_rows: list[ClinicPriceResult],
    stored_pool: list[DisplayClinicPrice],
    procedure: str,
    language: str,
) -> list[ClinicPriceResult]:
    """Resolve legal identities once, only when a growth decision is due."""
    if not live_rows:
        return []
    # Every real live official-price row was fetched moments earlier. Requiring
    # that cache entry prevents helper/unit callers from unexpectedly crawling
    # the public web, while preserving automatic production behaviour.
    eligible_hosts = {
        host
        for row in live_rows
        if (host := official_identity_host(row))
        and (row.legal_identifiers
             or row.legal_entity_names
             or row.operator_contacts
             or _has_recent_html_fetch(row.source_url)
             or _has_recent_html_fetch(row.official_website))
    }
    enriched = await enrich_legal_identities(
        live_rows, procedure, language, eligible_hosts=eligible_hosts,
    )
    if any(
        row.legal_identifiers or row.legal_entity_names or row.operator_contacts
        for row in enriched
    ):
        stored_pool[:] = await enrich_legal_identities(
            stored_pool, procedure, language,
        )
    return dedupe_live_results(enriched)


def hybrid_desired_new_count(
    stored_available: int,
    stored_count: int,
    fresh_count: int,
    display_limit: int,
) -> int:
    """How many genuinely new clinics are needed to fill the requested UI."""
    usable_preferred_stored = min(
        max(0, stored_available),
        max(0, stored_count),
    )
    missing_for_display = max(
        0,
        display_limit - usable_preferred_stored,
    )
    return max(fresh_count, missing_for_display)


def growth_shortfall_reason(
    desired: int, found: int, responses: list[DiscoverResponse],
    enabled: bool, max_rounds: int, economical: bool,
    total_budget_exhausted: bool = False,
) -> str:
    """Describe observed search limits; never infer market-wide absence."""
    if found >= desired:
        return "target_met"
    if not enabled:
        return "growth_search_disabled"
    if total_budget_exhausted:
        return "total_serper_budget_exhausted"
    diagnostics = [r.diagnostics for r in responses if r.diagnostics is not None]
    # A depleted HTTP budget in an earlier round does not explain a later
    # site-focused round that found zero eligible URLs to fetch.
    last = diagnostics[-1] if diagnostics else None
    if last and last.brave_search_used and last.brave_search_requests_attempted:
        return "no_additional_eligible_clinic_in_serper_or_brave"
    if last and last.brave_search_used and last.brave_search_cache_hits:
        return "cached_query_space_exhausted_across_serper_and_brave"
    if (
        last
        and last.serper_requests_attempted == 0
        and last.serper_cache_hits > 0
        and not last.brave_search_configured
        and not last.serp_page2_queries
    ):
        return "cached_query_space_exhausted_no_independent_index"
    if last and last.indexed_price_discovery_queries and not last.pages_attempted:
        return "no_eligible_price_urls_after_search"
    # Earlier rounds can hit their *per-round* request cap even when a later
    # round still searched and the whole request has unused credits. Report
    # the last round's constraint instead of implying the account ran dry.
    if last and last.serper_requests_skipped > 0:
        return "serper_request_budget_exhausted"
    if last and last.interactive_fetch_budget_exhausted:
        return "page_fetch_budget_exhausted"
    if any(d.serper_disabled or (d.serp_queries and not d.serper_configured)
           for d in diagnostics):
        return "serper_unavailable"
    if any(r.search_errors for r in responses):
        return "search_errors"
    available_modes = 2 if economical else 3
    if len(responses) < available_modes and max_rounds < available_modes:
        return "round_limit_reached"
    return "no_additional_eligible_clinic_in_searched_sources"



async def round0_official_hosts(
    city: str,
    country_code: str,
    procedure: str,
    known_hosts: list[str],
) -> tuple[list[str], int]:
    """Official hosts to open before any Serper query.

    Known app hosts stay first. A city that already has a clinic directory
    costs zero Places calls. A new city gets at most two Text Search calls.
    Places supplies websites, never prices.
    """
    hosts: list[str] = []

    def add(raw: str) -> None:
        host = (raw or "").lower().removeprefix("www.").strip()
        if not re.fullmatch(r"[a-z0-9.-]+", host) or "." not in host:
            return
        if classify_source(f"https://{host}/") != "official_clinic":
            return
        if host not in hosts:
            hosts.append(host)

    for raw in known_hosts or []:
        add(raw)

    try:
        directory = await firestore_load_clinic_directory(city)
    except Exception:
        directory = []
    ranked_directory = sorted(
        directory,
        key=lambda hit: (
            -(hit.place_user_rating_count or 0),
            -(hit.place_rating or 0),
            fold(hit.title),
        ),
    )
    places_calls = 0
    if not ranked_directory and len(hosts) < 8 and env_bool("ENABLE_PLACES_CITY_BOOTSTRAP", True):
        language = search_profile(country_code, city)[0]
        places = GooglePlacesClient()
        if places.configured:
            found = await places.discover_city_clinic_websites(
                city,
                language,
                procedure=procedure,
                max_websites=12,
                max_queries=2,
            )
            places_calls = places.requests_attempted
            for hit in found:
                hit.directory_verified = True
                hit.directory_verification_source = "google_places"
            if found:
                try:
                    await firestore_upsert_clinic_directory(city, country_code, found)
                except Exception:
                    pass
            ranked_directory = list(found)
    for hit in ranked_directory:
        if classify_source(hit.url) != "official_clinic":
            continue
        add(host_of(hit.url))
        if len(hosts) >= 12:
            break
    return hosts[:12], places_calls


async def run_growth_search(
    city: str,
    procedure: str,
    country_code: str,
    stored_pool: list[DisplayClinicPrice],
    desired_new: int,
    limit: int,
    debug: bool,
    enabled: bool = True,
    max_rounds: int = 3,
    interactive_fast: bool = True,
    cache_sufficient: bool = False,
    force_full_growth_search: bool = False,
    economical_growth: bool = True,
    initial_serper_requests: int = 0,
    app_fast: bool = False,
    stored_count: int = 2,
    fresh_count: int = 2,
    display_limit: int = 4,
    allow_cached_fill: bool = True,
    excluded_source_urls: list[str] | None = None,
    client_known_clinic_hosts: list[str] | None = None,
    client_known_clinic_names: list[str] | None = None,
    serper_request_budget: int = 0,
    serper_first: bool = False,
    background_collection: bool = False,
) -> tuple[
    list[DiscoverResponse],
    list[ClinicPriceResult],
    bool,
]:
    """Adaptive search cascade.

    Always attempts the inexpensive directory pass. Spend on an expanded
    search, then one larger rescue, only while new clinic slots remain empty.
    """
    if app_fast and serper_first and env_bool("ENABLE_PROGRESSIVE_DISCOVERY", True):
        return await vertical_search.run_progressive(sys.modules[__name__],
            city=city, procedure=procedure, country_code=country_code, stored_pool=stored_pool,
            desired_new=desired_new, limit=limit, debug=debug,
            client_known_clinic_hosts=client_known_clinic_hosts,
            excluded_source_urls=excluded_source_urls, serper_request_budget=serper_request_budget,
            display_limit=display_limit, background_collection=background_collection,
            initial_serper_requests=initial_serper_requests)
    if serper_first:
        modes = ["expanded", "site_focus", "rescue"] if enabled else ["standard"]
    elif app_fast and not force_full_growth_search:
        # Stored cards paint first; broaden the source/query families only
        # while verified new slots remain missing.
        modes = ["expanded", "site_focus", "rescue"] if enabled else ["standard"]
    elif economical_growth:
        modes = ["standard", "expanded", "rescue", "site_focus"] if enabled else ["standard"]
    else:
        modes = ["standard", "expanded", "deep"]
        if not enabled:
            modes = ["standard"]

    known_hosts = sorted({host for row in stored_pool
                          if (host := stored_provider_identity_host(row))})
    known_names = sorted({row.clinic_name for row in stored_pool if row.clinic_name})
    stored_host_set = set(known_hosts)
    focus_hosts: list[str] = []
    focus_urls: list[str] = []
    for raw_host in client_known_clinic_hosts or []:
        host = (raw_host or "").lower().removeprefix("www.").strip()
        if not re.fullmatch(r"[a-z0-9.-]+", host) or "." not in host:
            continue
        # Already stored for THIS procedure: keep excluding it. A host verified
        # on another procedure (Botox) is a filler site-focus target, not a skip.
        if host in stored_host_set or host in focus_hosts:
            continue
        focus_hosts.append(host)
    known_names = sorted(set(known_names) | set(client_known_clinic_names or []))
    places_round0_queries = 0
    places_round0_ran = False
    if app_fast and len(stored_pool) < 4 and not serper_first:
        places_round0_ran = True
        ranked_hosts, places_round0_queries = await round0_official_hosts(
            city, country_code, procedure, list(focus_hosts),
        )
        focus_hosts = [host for host in ranked_hosts if host not in stored_host_set]
        print(
            f"[GP HUNTER] round0 places_discovery_queries={places_round0_queries} "
            f"hosts={','.join(focus_hosts[:12])}",
            flush=True,
        )
    if (focus_hosts and not serper_first
            and (force_full_growth_search or len(stored_pool) < 4)):
        # Open known city hosts before a broad Serper round burns the cap.
        modes = ["site_focus", "expanded", "rescue"] if enabled else ["standard"]

    modes = modes[:max(1, min(max_rounds, len(modes)))]
    responses: list[DiscoverResponse] = []
    stopped_for_cache = False
    blocked_sources = set(excluded_source_urls or [])
    already_fetched: set[str] = set(blocked_sources)
    env_serper_cap = max(0, int(os.getenv("MAX_ADAPTIVE_TOTAL_SERPER_REQUESTS", "16")))
    total_serper_budget = (
        serper_request_budget if serper_request_budget > 0 else env_serper_cap
    )
    # serper_request_budget_exhausted is this in-process cap, not an empty
    # Serper account. A short city that has not found a new clinic yet may
    # use a higher cap on this request only.
    if len(stored_pool) < 4 and force_full_growth_search and serper_request_budget <= 0:
        total_serper_budget = max(total_serper_budget, min(32, max(env_serper_cap, 28)))
    total_serper_budget = min(40, max(0, total_serper_budget))
    spent = max(0, initial_serper_requests)

    for i, mode in enumerate(modes):
        missing = max(0, desired_new - len(_novel_live_rows(
            [_display_from_live(row, "live_search") for row in merge_live_results(responses)],
            stored_pool,
        )))
        remaining = max(0, total_serper_budget - spent)
        if (
            economical_growth
            and mode != "standard"
            and remaining == 0
            and not (mode == "site_focus" and focus_hosts)
        ):
            break
        if mode == "site_focus":
            if focus_hosts:
                # Direct GET of /preturi/{city}/. Serper starts on the next round.
                serper_cap = 0
            else:
                site_cap = max(
                    0, int(os.getenv("MAX_ADAPTIVE_SITE_SERPER_REQUESTS", "6"))
                )
                serper_cap = min(
                    remaining,
                    site_cap,
                    4 if app_fast else 6,
                )
                if serper_cap <= 0:
                    break
        elif mode == "rescue":
            # Spend less for a one-clinic deficit, and never exceed the
            # configured network-request cap across the full hybrid request.
            serper_cap = min(
                remaining,
                max(0, int(os.getenv("MAX_ADAPTIVE_EXTRA_SERPER_REQUESTS", "8"))),
                2 + 3 * missing,
            )
            if serper_cap <= 0:
                break
        elif economical_growth and mode == "expanded":
            serper_cap = min(remaining, max(0, int(os.getenv("MAX_INTERACTIVE_SERPER_REQUESTS", "6"))))
            if serper_cap <= 0:
                break
        else:
            serper_cap = 0
        page_budget = max(1, int(os.getenv(
            "MAX_ADAPTIVE_SITE_FETCHES_PER_ROUND" if mode == "site_focus"
            else "MAX_ADAPTIVE_FETCHES_PER_ROUND" if mode == "rescue"
            else "MAX_INTERACTIVE_FETCHES_PER_ROUND",
            "28" if mode == "site_focus" else "40" if mode == "rescue" else "20",
        )))
        if mode == "site_focus" and focus_hosts:
            # At least 12 official GETs before Serper, and never fewer than
            # the city-slug pages for the hosts already in hand.
            page_budget = max(page_budget, 12, min(48, 4 * len(focus_hosts)))
        if app_fast and not force_full_growth_search:
            # Expanded paints the first marketplace menus. Site focus has to
            # open the clinic pages those menus point at, plus a price-page
            # follow-up when the menu itself has no price. Eight slots ended
            # that round while candidate pages were still queued.
            floor = 12 if mode == "site_focus" and focus_hosts else 1
            page_budget = max(
                floor,
                min(page_budget, 36 if mode in {"site_focus", "rescue"} else 24),
            )
        budget = {
            "left": page_budget,
            "blocked": 0,
            "lock": asyncio.Lock(),
        }
        await _emit_hybrid_status(
            phase="searching", round=mode, round_number=i + 1,
            rounds_completed=len(responses), fresh_count=desired_new - missing,
            desired_fresh=desired_new, serper_requests=spent,
        )
        token = _interactive_fetch_budget.set(budget)
        progress_token = _hybrid_round_progress_base.set({
            "fetched_pages": sum(r.fetched_pages for r in responses),
            "serper_requests": spent,
        })
        response = None
        try:
            response = await discover(
                DiscoverRequest(
                city=city,
                procedure=procedure,
                country_code=country_code or None,
                limit=min(20, max(8, limit)),
                persist=False,
                debug=debug,
                search_mode=mode,
                interactive_fast=interactive_fast,
                refresh_places=False,
                full_growth=force_full_growth_search,
                economical_growth=economical_growth,
                hybrid_interactive=True,
                adaptive_rescue=mode in {"rescue", "site_focus"},
                previously_fetched_urls=sorted(already_fetched),
                known_clinic_hosts=known_hosts,
                known_clinic_names=known_names,
                priority_site_hosts=focus_hosts,
                priority_site_urls=focus_urls,
                previous_round_verified_hosts=(
                    responses[-1].diagnostics.selected_directory_hosts
                    if mode == "site_focus" and responses and responses[-1].diagnostics
                    else []
                ),
                enable_serper=(
                    not (economical_growth and mode == "standard")
                    and not (mode == "site_focus" and focus_hosts)
                ),
                serper_request_cap=serper_cap,
                skip_places_bootstrap=places_round0_ran or serper_first,
                app_fast_queries=app_fast,
                )
            )
        finally:
            if response is not None and response.diagnostics is not None:
                response.diagnostics.interactive_fetch_budget_exhausted = (
                    int(budget.get("blocked") or 0) > 0
                )
            _interactive_fetch_budget.reset(token)
            _hybrid_round_progress_base.reset(progress_token)
        responses.append(response)
        if debug and response.diagnostics is not None:
            response.diagnostics.known_firestore_clinics = [
                {"name": row.clinic_name, "official_host": stored_provider_identity_host(row)}
                for row in stored_pool
            ]
        if response.diagnostics is not None:
            if i == 0:
                response.diagnostics.places_discovery_queries = places_round0_queries
                response.diagnostics.places_candidate_hosts = list(focus_hosts[:12])
            spent += response.diagnostics.serper_requests_attempted
        already_fetched.update(response.crawled_urls)
        if response.diagnostics is not None:
            # Continue from the real organic URLs and navigation just found,
            # rather than going back to a fixed list of city-directory roots.
            next_urls = [
                *response.diagnostics.pending_price_navigation_urls,
                *response.diagnostics.selected_official_candidate_urls,
            ]
            focus_urls = list(dict.fromkeys([
                *(url for url in next_urls if url not in already_fetched),
                *(url for url in focus_urls if url not in already_fetched),
            ]))[:40]
            leads = response.diagnostics.unpriced_local_provider_hosts
            focus_hosts = list(dict.fromkeys([
                *leads, *(host_of(url) for url in focus_urls), *focus_hosts,
            ]))[:12]

        merged = [row for row in merge_live_results(responses)
                  if row.source_url not in blocked_sources]
        if app_fast:
            merged = [row for row in merged if _app_can_show_row(row)]
        display = [
            _display_from_live(row, "live_search")
            for row in merged
        ]
        novel = _novel_live_rows(display, stored_pool)
        await _emit_hybrid_status(
            phase="round_complete", round=mode, round_number=i + 1,
            rounds_completed=len(responses), fresh_count=len(novel),
            desired_fresh=desired_new, serper_requests=spent,
            searched_urls=sum(r.searched_urls for r in responses),
            fetched_pages=sum(r.fetched_pages for r in responses),
        )
        if novel and _hybrid_progress.get() is not None:
            shown = compose_hybrid_display(
                stored_pool,
                novel,
                stored_count,
                fresh_count,
                display_limit,
                allow_cached_fill=allow_cached_fill,
            )[3]
            await _emit_hybrid_partial(shown)

        if len(novel) >= desired_new:
            merged = await enrich_new_operator_identities(
                merged,
                stored_pool,
                procedure,
                search_profile(country_code, city)[0],
            )
            novel = _novel_live_rows([
                _display_from_live(row, "live_search") for row in merged
            ], stored_pool)
            if len(novel) >= desired_new:
                return responses, merged, stopped_for_cache

    merged = [row for row in merge_live_results(responses)
              if row.source_url not in blocked_sources]
    if app_fast:
        merged = [row for row in merged if _app_can_show_row(row)]
    merged = await enrich_new_operator_identities(
        merged,
        stored_pool,
        procedure,
        search_profile(country_code, city)[0],
    )
    return responses, merged, stopped_for_cache



def refresh_cached_display_rows_with_live(
    stored_rows: list[DisplayClinicPrice],
    live_rows: list[ClinicPriceResult],
) -> list[DisplayClinicPrice]:
    """Refresh only clinics already present in the original Firestore pool."""
    out = []
    for stored in stored_rows:
        live = next((
            row for row in live_rows
            if same_clinic_identity(row, stored)
        ), None)
        if live is None or official_tariff_takes_priority(stored, live):
            out.append(stored)
            continue

        payload = live.model_dump()
        # Page titles are localized and can change between crawls. The saved
        # identity is the UI label unless an explicit rename workflow exists.
        payload["clinic_name"] = stored.clinic_name
        payload.update(
            {
                "origin": stored.origin,
                "last_verified_at": datetime.now(
                    timezone.utc
                ).isoformat(),
                "cache_age_days": 0,
            }
        )
        out.append(DisplayClinicPrice.model_validate(payload))

    return out


def unpriced_listing_should_search(
    source_type: str,
    clinic_name: str,
    priced: bool,
) -> bool:
    """A named marketplace listing with no price is a lead, not a card."""
    if priced:
        return False
    if source_type not in {"marketplace", "directory"}:
        return False
    return len((clinic_name or "").strip()) >= 2


def unpriced_official_page_should_search(
    source_type: str,
    clinic_name: str,
    priced: bool,
    procedure_on_page: bool,
    city_on_page: bool,
) -> bool:
    """An official procedure page with no price is a lead, not a card."""
    if priced or not procedure_on_page or not city_on_page:
        return False
    if source_type != "official_clinic":
        return False
    return len((clinic_name or "").strip()) >= 2


def unpriced_provider_price_queries(
    clinic_name: str,
    city: str,
    procedure: str,
) -> list[str]:
    """Google query for a clinic's own published price. The snippet is not a price."""
    name = re.sub(r"\s+", " ", (clinic_name or "")).strip().strip('"')
    place = (city or "").strip()
    if len(name) < 2 or len(place) < 2:
        return []
    proc = display_name(canonicalize_procedure(procedure)) or (procedure or "").strip()
    if len(proc) < 2:
        return []
    return [f'"{name}" "{place}" "{proc}" price']


def price_search_hit_is_openable_page(url: str) -> bool:
    """Follow-up hits are pages to open. A search snippet is never a price."""
    host = host_of(url or "")
    if not host or any(
        token in host
        for token in (
            "google.", "bing.com", "duckduckgo.com", "search.yahoo", "yandex.",
        )
    ):
        return False
    source = classify_source(url or "")
    return source in {"official_clinic", "marketplace"}


def compose_hybrid_display(
    stored_pool: list[DisplayClinicPrice],
    fresh_pool: list[DisplayClinicPrice],
    stored_count: int = 2,
    fresh_count: int = 2,
    display_limit: int = 4,
    allow_cached_fill: bool = True,
) -> tuple[
    list[DisplayClinicPrice],
    list[DisplayClinicPrice],
    list[DisplayClinicPrice],
    list[DisplayClinicPrice],
    bool,
    str,
]:
    """
    Preferred output:
      2 cached Firestore clinics + 2 live-search clinics.

    Fallback cascade:
      1. Fill missing live slots with more Firestore clinics.
      2. Fill missing Firestore slots with more live clinics.
      3. Return fewer than display_limit only if there are not enough unique
         verified clinics in either source.
    """
    stored_pool = _unique_display_rows([corrected_starting_price(r) for r in stored_pool])
    fresh_pool = _unique_display_rows(fresh_pool)

    stored_selected = []
    fresh_selected = []
    fallback = []
    used = set()

    for row in stored_pool:
        if len(stored_selected) >= stored_count:
            break
        ck = _clinic_compare_key(row.clinic_name)
        if ck in used:
            continue
        used.add(ck)
        stored_selected.append(_copy_display_origin(row, "firestore"))

    for row in fresh_pool:
        if len(fresh_selected) >= fresh_count:
            break
        ck = _clinic_compare_key(row.clinic_name)
        if ck in used:
            continue
        used.add(ck)
        fresh_selected.append(_copy_display_origin(row, "live_search"))

    display = stored_selected + fresh_selected

    if not allow_cached_fill:
        missing_live = max(0, fresh_count - len(fresh_selected))
        missing_stored = max(0, stored_count - len(stored_selected))
        if missing_live and missing_stored:
            reason = "missing_verified_slots"
        elif missing_live:
            reason = "missing_live_slot"
        elif missing_stored:
            reason = "missing_firestore_slot"
        else:
            reason = ""
        return (
            stored_selected,
            fresh_selected,
            [],
            display[:display_limit],
            bool(reason),
            reason,
        )

    # If live search cannot provide enough NEW display clinics,
    # use additional cached clinics instead of returning an empty UI.
    if len(display) < display_limit:
        for row in stored_pool:
            if len(display) >= display_limit:
                break
            ck = _clinic_compare_key(row.clinic_name)
            if ck in used:
                continue
            used.add(ck)
            f = _copy_display_origin(row, "firestore_fallback")
            fallback.append(f)
            display.append(f)

    # If Firestore is new/empty, use more current live results.
    if len(display) < display_limit:
        for row in fresh_pool:
            if len(display) >= display_limit:
                break
            ck = _clinic_compare_key(row.clinic_name)
            if ck in used:
                continue
            used.add(ck)
            f = _copy_display_origin(row, "live_fallback")
            fallback.append(f)
            display.append(f)

    fallback_used = bool(fallback) or len(stored_selected) < stored_count or len(fresh_selected) < fresh_count

    if not fallback_used:
        reason = ""
    elif len(display) < display_limit:
        reason = "not_enough_unique_verified_clinics"
    elif len(fresh_selected) < fresh_count:
        reason = "live_search_shortage_filled_from_firestore"
    elif len(stored_selected) < stored_count:
        reason = "firestore_shortage_filled_from_live_search"
    else:
        reason = "fallback_used"

    return (
        stored_selected,
        fresh_selected,
        fallback,
        display[:display_limit],
        fallback_used,
        reason,
    )


# Per-process exposure balancing for repeated interactive searches. The
# underlying verified records remain unchanged; only card selection rotates.
_display_rotation_lock = threading.Lock()
_display_rotation_history: dict[str, dict[str, tuple[int, int]]] = {}
_display_rotation_turns: dict[str, int] = {}
_display_rotation_locks = weakref.WeakKeyDictionary()


def compose_rotating_hybrid_display(
    city: str,
    procedure: str,
    stored_pool: list[DisplayClinicPrice],
    fresh_pool: list[DisplayClinicPrice],
    stored_count: int,
    fresh_count: int,
    display_limit: int,
    allow_cached_fill: bool = True,
):
    key = _search_key(city, procedure)
    with _display_rotation_lock:
        if len(_display_rotation_history) >= 1024 and key not in _display_rotation_history:
            oldest = next(iter(_display_rotation_history))
            _display_rotation_history.pop(oldest, None)
            _display_rotation_turns.pop(oldest, None)
        history = _display_rotation_history.setdefault(key, {})
        turn = _display_rotation_turns.get(key, 0) + 1

        def order(rows):
            # Keep ranking relevant: rotate among the best eligible records,
            # then use the remaining trusted records only for empty slots.
            top = max(display_limit * 3, 8)
            indexed = list(enumerate(_unique_display_rows(rows)))
            def score(item):
                index, row = item
                count, last = history.get(_clinic_compare_key(row.clinic_name), (0, -1000))
                offset = (turn - 1) % max(1, min(len(indexed), top))
                return (count, 1 if last == turn - 1 else 0,
                        (index - offset) % max(1, min(len(indexed), top)))
            return [row for _, row in sorted(indexed[:top], key=score)] + [row for _, row in indexed[top:]]

        selection = compose_hybrid_display(
            order(stored_pool), order(fresh_pool),
            stored_count, fresh_count, display_limit,
            allow_cached_fill=allow_cached_fill,
        )
        for row in selection[3]:
            clinic = _clinic_compare_key(row.clinic_name)
            count, _ = history.get(clinic, (0, -1000))
            history[clinic] = (count + 1, turn)
        _display_rotation_turns[key] = turn
        return selection


async def compose_persistent_rotating_hybrid_display(
    city: str, procedure: str, stored_pool: list[DisplayClinicPrice],
    fresh_pool: list[DisplayClinicPrice], stored_count: int,
    fresh_count: int, display_limit: int,
    allow_cached_fill: bool = True,
):
    """Remember visible clinics across Uvicorn reloads when Firestore works."""
    args = (city, procedure, stored_pool, fresh_pool, stored_count,
            fresh_count, display_limit)
    client = _firestore_client() if firestore_enabled() else None
    if client is None:
        return compose_rotating_hybrid_display(
            *args, allow_cached_fill=allow_cached_fill,
        ), False

    key = _search_key(city, procedure)
    loop = asyncio.get_running_loop()
    locks = _display_rotation_locks.setdefault(loop, {})
    lock = locks.setdefault(key, asyncio.Lock())
    async with lock:
        doc_id = hashlib.sha256(key.encode("utf-8")).hexdigest()
        ref = client.collection(os.getenv(
            "FIRESTORE_DISPLAY_ROTATION_COLLECTION", "aesthetic_display_rotation",
        )).document(doc_id)
        try:
            snapshot = await asyncio.to_thread(ref.get)
            if snapshot.exists:
                state = snapshot.to_dict() or {}
                history = {
                    name: (max(0, int(value[0])), max(-1, int(value[1])))
                    for name, value in (state.get("history") or {}).items()
                    if isinstance(value, (list, tuple)) and len(value) == 2
                }
                with _display_rotation_lock:
                    _display_rotation_history[key] = history
                    _display_rotation_turns[key] = max(0, int(state.get("turn", 0)))
            else:
                # Migrate from the older in-memory scheme, which always
                # restarted with the same top cards after an app upgrade.
                with _display_rotation_lock:
                    if key not in _display_rotation_turns and len(stored_pool) > display_limit:
                        _display_rotation_turns[key] = display_limit
        except Exception:
            # In-memory rotation is still preferable to holding up search.
            pass

        selection = compose_rotating_hybrid_display(
            *args, allow_cached_fill=allow_cached_fill,
        )
        with _display_rotation_lock:
            history = _display_rotation_history.get(key, {})
            recent = sorted(history.items(), key=lambda item: -item[1][1])[:80]
            payload = {
                "search_key": key,
                "turn": _display_rotation_turns[key],
                "history": {name: list(counts) for name, counts in recent},
                "updated_at": datetime.now(timezone.utc),
            }
        try:
            await asyncio.to_thread(ref.set, payload)
            return selection, True
        except Exception:
            return selection, False



# ============================================================
# Discovery
# ============================================================

def has_procedure(text: str, procedure: str) -> bool:
    return contains_requested_procedure(text, procedure)


def procedure_detail(
    raw: str,
    canonical: str,
    raw_price_text: str = "",
) -> str:
    parts = []

    if canonical == "botox":
        detail = botox_variant_detail(raw, raw_price_text)
        if detail:
            parts.append(detail)

    if canonical == "filler":
        f = fold(raw)
        if "full face" in f or "full-face" in f:
            parts.append("Full face rejuvenation")
        anatomy = [
            ("Rhinofiller / nose", ["rhinofiller", "rhino filler", "nose filler", "nasal filler"]),
            ("Lip", ["lip filler", "lip augmentation", "filler buze", "filler buzesh", "mbushes buzesh",
                      "marire buze", "augmentare buze", "volumizare buze",
                      "aumento de labios", "aumento labial", "relleno de labios", "lip enhancement"]),
            ("Nasolabial", ["nasolabial", "nasolabiale"]),
            ("Cheek", ["cheek filler", "cheeks filler", "malar filler", "volumizare pometi"]),
            ("Jawline", ["jawline filler", "jaw filler", "mandibular filler"]),
            ("Chin", ["chin filler", "mental filler"]),
            ("Tear trough", ["tear trough", "under eye filler", "under-eye filler", "umplere cearcane"]),
        ]
        for label, terms in anatomy:
            if any(fold(term) in f for term in terms):
                parts.append(label)
                break

        brand = detect_product_brand(raw, "filler")
        line = detect_product_line(raw, "filler")
        if brand:
            parts.append(brand + (f" {line}" if line else ""))

        m = re.search(r"\b(\d+(?:[.,]\d+)?)\s*ml\b", f)
        if m:
            value = float(m.group(1).replace(",", "."))
            if value <= 10:
                parts.append(f"{m.group(1).replace(',', '.')} ml")

    if canonical == "breast_augmentation":
        bound = breast_price_row_text(raw, raw_price_text)
        parts.append(breast_augmentation_detail(bound, raw_price_text))
        brand = detect_product_brand(bound, "breast_augmentation")
        if brand:
            parts.append(brand)
        elif "mentor" in fold(bound):
            parts.append("Mentor implants")

    if canonical == "hair_transplant":
        for method in ("FUE", "DHI", "FUT"):
            if re.search(rf"\b{method}\b", raw, re.I):
                parts.append(method)
                break
        if re.search(r"partial\s+shaved", raw, re.I):
            parts.append("Partially shaved")
        elif re.search(r"\bshaved\b", raw, re.I):
            parts.append("Shaved")

    # Preserve order, no duplicates.
    deduped = []
    for part in parts:
        if part and part not in deduped:
            deduped.append(part)
    return " · ".join(deduped)


def nonfacial_tariff_scope(canonical: str, row_text: str) -> bool:
    if canonical not in {"filler", "chemical_peel"}:
        return False
    folded = fold(unescape(row_text))
    if canonical == "chemical_peel" and re.search(
            r"\b(?:corporal\w*|cuerpo|body|scrub|sales|salt|sugar|autobronceador\w*|"
            r"enzimatic\w*|enzymatic|mechanical|mecanico|microdermabrasion)\b|"
            r"peel\s*off|gommage\s+corporel", folded):
        return True
    return bool(re.search(
        r"\b(?:intim\w*|genital\w*|vagin\w*|vulv\w*|labial?\s+major\w*|penis|penile|buttock\w*)\b|"
        r"\b(?:breast|body)\s+fillers?\b|\bzona\s+corporala\b", folded,
    ))


def filler_price_row_name(evidence: str, raw_price_text: str = "") -> str:
    return tariff_price_row_name(evidence, "filler", raw_price_text)


def clean_published_procedure_title(text: str) -> str:
    """Remove a price-heading suffix without translating the source name.

    This is display-only: ownership/market-price checks keep the untouched
    source evidence. Cleaning an article title cannot verify its amount.
    """
    title = re.sub(r'\s+', ' ', text or '').strip(' |:;-–')
    tail = re.search(
        r'\b(?:fiyat\w*|[üu]cret\w*|prices?|pricing|costs?|precios?|prix|'
        r'tarifs?|prezzi|preise|pre[tț]uri|cennik|prijzen)\b', title, re.I)
    if tail and tail.start() > 0:
        prefix = title[:tail.start()].strip(' |:;-–')
        if not re.match(r'^(?:our|we|how|what)\b', prefix, re.I) and any(has_procedure(prefix, family) for family in
               ('botox', 'filler', 'chemical_peel', 'rhinoplasty',
                'breast_augmentation', 'hair_transplant')):
            title = prefix
    return title


def tariff_price_row_name(evidence: str, procedure: str, raw_price_text: str = "") -> str:
    """Keep the bounded tariff name before its amount, including brand/dose."""
    text = evidence or ""
    prices = list(iter_exact_price_matches(text))
    if not prices:
        return ""
    target = next((item for item in prices if item[0].group(0).strip() == raw_price_text.strip()), prices[0])
    prefix = text[:target[0].start()].strip(" |·:;–-")
    name = prefix.rsplit("|", 1)[-1].strip(" |·:;–-")
    if not name:
        tail = text[prices[-1][0].end():].strip()
        listed = re.fullmatch(r"for\s+(.{1,110})", tail, re.I)
        if listed:
            name = listed.group(1).strip()
    name = re.sub(r"^/?\s*(?:ml|unit|session)\b\s*", "", name, flags=re.I)
    name = re.sub(r"\s+(?:Price|Cost|Fee)(?:\s+Range)?(?:\s*\([A-Z]{3}\))?\s*:?[ ]*$", "", name, flags=re.I)
    name = re.sub(r"^Serviciu\s+Pret\s+", "", name, flags=re.I)
    name = re.sub(r"\s+", " ", name).strip()
    name = re.sub(r'\b\d+(?:[.,]\d+)?\s*%\s*off\b', '', name, flags=re.I)
    name = re.sub(r'\bsave\s+(?:AED|EUR|USD|GBP|[$€£])?\s*\d[\d.,]*\s*(?:AED|EUR|USD|GBP)?\b', '', name, flags=re.I)
    name = re.sub(r'\s+', ' ', name).strip(' |·:')
    name = re.sub(r"\s*(?:starts?\s+from|starting\s+(?:from|at)|from|de\s+la)\s*$", "", name, flags=re.I).strip()
    name = clean_published_procedure_title(name)
    canonical = canonicalize_procedure(procedure)
    requested = (injectable_filler_match(name) if canonical == "filler"
                 else has_procedure(name, canonical))
    if (canonical == 'hair_transplant' and not requested
            and has_procedure(text, canonical)
            and re.match(r'^(?:FUE|DHI|FUT)\b', name, re.I)):
        name = f'Hair Transplant · {name}'
        requested = True
    if (not name or len(name) > 160 or not requested or pricing_prose_title(name)
            or re.search(r"\b(?:our|we|costs?|prices?|starts?|starting|from|average|what|how|ranges?|between)\b", fold(name))):
        return ""
    return name


def published_procedure_display_name(
    canonical: str, raw_procedure_text: str, evidence: str, raw_price_text: str = "",
) -> str:
    raw_procedure_text = clean_published_procedure_title(raw_procedure_text)
    listed = tariff_price_row_name(evidence, canonical, raw_price_text)
    for title in (listed, raw_procedure_text):
        if (canonical == 'filler' and title == listed
                and re.match(r'^(?:lip|cheek|chin|jawline|nasolabial|tear trough) filler\b', title, re.I)
                and (fold(raw_procedure_text) == 'dermal filler' or re.match(r'^(?:how|what)\b', raw_procedure_text, re.I))):
            continue
        if (title and len(title) <= 110 and has_procedure(title, canonical)
                and fold(title) != fold(display_name(canonical))
                and not pricing_prose_title(title)
                and not re.search(r'\b(?:how|what|average|generally|genellikle|ranges?|between)\b', fold(title))
                and not list(iter_exact_price_matches(title))):
            # English breast method subtitles keep the established formatting.
            if canonical == 'breast_augmentation' and re.search(r'breast|augmentation', title, re.I):
                continue
            return title
    if canonical == "breast_augmentation":
        return breast_augmentation_display_name(evidence, raw_price_text)
    if canonical == 'botox':
        listed = tariff_price_row_name(evidence, canonical, raw_price_text)
        if listed and fold(listed) not in {"botox", "anti wrinkle", "botulinum toxin"}:
            return listed
        title = re.sub(r'\s+', ' ', raw_procedure_text or '').strip(' |:;-–')
        if (title and len(title) <= 110 and has_procedure(title, canonical)
                and not re.search(r'\b(?:prices?|costs?|how|what|from|available|starting)\b', fold(title))
                and not list(iter_exact_price_matches(title))):
            return title
        return display_name(canonical)
    if canonical in {"chemical_peel", "hair_transplant"}:
        title = tariff_price_row_name(evidence, canonical, raw_price_text)
        if title:
            return title
        # Keep explicitly named menu rows, not descriptions from the article.
        title = re.sub(r"\s+", " ", raw_procedure_text or "").strip()
        if (title and len(title) <= 110 and has_procedure(title, canonical)
                and not re.search(r"\b(?:costs?|prices?|average|how|what|from|ranges?|between)\b", fold(title))
                and not list(iter_exact_price_matches(title))):
            return title
        return display_name(canonical)
    if canonical != "filler":
        return display_name(canonical)
    title = re.sub(r"\s+", " ", raw_procedure_text or "").strip(" |:;-–")
    # Keep the bounded menu title, including its product and dosage.
    # SEO headings and long article prose never become a treatment name.
    generic = bool(re.fullmatch(r"(?:dermal\s+)?fillers?(?:\s+lips\s+cheeks)?", title, re.I))
    prose = pricing_prose_title(title) or bool(re.search(r"\b(?:costs?|prices?|starts?|starting|from|average|what|how|contact)\b",
                           fold(title)))
    named_filler_row = has_procedure(title, "filler") or bool(re.search(
        r"\b(?:umplere|volumizare|augmentare|marire)\b.{0,30}"
        r"\b(?:buze|pometi|cearcane|menton|mandibul\w*|nazogenien\w*)\b", fold(title)))
    if (title and len(title) <= 110 and not generic and not prose
            and named_filler_row and not list(iter_exact_price_matches(title))):
        return title
    line = priced_line_text(evidence)
    detail = procedure_detail(line, "filler", raw_price_text)
    anatomy = detail.split(" · ")[0] if detail else ""
    labels = {"Lip": "Lip filler", "Cheek": "Cheek filler", "Chin": "Chin filler",
              "Jawline": "Jawline filler", "Nasolabial": "Nasolabial filler",
              "Tear trough": "Tear trough filler", "Rhinofiller / nose": "Nose filler",
              "Full face rejuvenation": "Full face rejuvenation"}
    return labels.get(anatomy, display_name(canonical))


def add_reject(
    diag: DiscoveryDiagnostics,
    url: str,
    reason: str,
    detail: str = "",
):
    if len(diag.reject_samples) < 20:
        diag.reject_samples.append(
            RejectSample(
                url=url,
                reason=reason,
                detail=detail[:220],
            )
        )


PRICE_PATH_HINTS = [
    "price", "prices", "pricing", "price-list", "pricelist", "cost", "costs",
    "costo", "kosto", "kostoja", "prezzo",
    "pret", "preturi", "preț", "prețuri", "precio", "precios", "prix",
    "preco", "precos", "preço", "preços", "fiyat", "fiyatlar", "ucret", "ücret",
    "cena", "cennik", "prijzen", "цена", "цени",
    "tariff", "tariffs", "tarif", "tarife",
    "prezzi", "listino", "preisliste", "preise", "gebuhren", "gebuehren",
    "cmim", "çmim", "cmime", "çmime",
    "treatment", "treatments", "service", "services",
    "sherbim", "shërbim", "sherbime", "shërbime",
    "aesthetic", "aesthetics", "injectable", "injectables",
    "promo", "promotion", "promotions", "offer", "offers",
    "oferta", "ofertat", "discount", "zbritje",
    "package", "packages", "paketa",
    "platform", "platforma", "membership", "loyalty",
]

LEGAL_IDENTITY_PATH_HINTS = [
    "contact", "contacts", "contatti", "contatto", "kontakt", "contacto",
    "contacte", "imprint", "impressum", "legal", "company", "societa",
    "società", "chi-siamo", "about-us", "rreth-nesh", "privacy", "terms",
    "termini", "mentions-legales", "aviso-legal",
]


def official_site_candidate_links(
    base_url: str,
    html: str,
    procedure: str,
    language: str,
    limit: int = 8,
    identity_mode: bool = False,
) -> list[str]:
    """
    Find likely price/treatment pages directly from a clinic's official site.
    This is especially useful for Google Places candidates whose price page is
    not well indexed by Google/Serper.
    """
    if not html:
        return []

    base_host = host_of(base_url)
    if not base_host:
        return []

    soup = BeautifulSoup(html, "lxml")
    canonical = canonicalize_procedure(procedure)

    proc_terms = aliases_for(procedure)[:4]
    proc_terms += local_terms_for(procedure, language)
    if canonical == "filler":
        proc_terms += ["lip filler", "dermal filler", "filler"]

    candidates = {}

    for a in soup.find_all("a", href=True):
        raw = str(a.get("href") or "").strip()
        if not raw or raw.startswith(("#", "mailto:", "tel:", "javascript:")):
            continue

        absolute = safe_http_urljoin(base_url, raw)
        if not absolute:
            continue
        if not related_clinic_hosts(host_of(absolute), base_host):
            continue

        if absolute.rstrip("/") == base_url.rstrip("/"):
            continue

        label = " ".join(a.stripped_strings)
        blob = fold(f"{label} {urlparse(absolute).path}")

        score = 0

        if identity_mode:
            for hint in LEGAL_IDENTITY_PATH_HINTS:
                if fold(hint) in blob:
                    score += 10 if hint in {
                        "contact", "contacts", "contatti", "kontakt",
                        "contacto", "imprint", "impressum", "legal",
                        "aviso-legal", "mentions-legales",
                    } else 4
            if score <= 0:
                continue
            prev = candidates.get(absolute)
            if prev is None or score > prev:
                candidates[absolute] = score
            continue

        for hint in PRICE_PATH_HINTS:
            if fold(hint) in blob:
                # A single generic clinic tariff can list the requested
                # surgery, while a treatment page may show no price at all.
                score += 8 if hint in {
                    "price", "prices", "pricing", "price-list", "pricelist",
                    "cost", "costs", "costo", "kosto", "kostoja",
                    "prezzo", "prezzi", "listino", "tariff", "tariffs",
                    "tarif", "tarife", "preisliste", "preise", "gebuhren",
                    "gebuehren", "cmim", "çmim", "cmime", "çmime",
                } else 2

        for term in proc_terms:
            if fold(term) and fold(term) in blob:
                score += 5

        # Some clinics put an entire surgical price list on a generic
        # "aesthetic surgery" index page instead of a /prices/ path. A
        # verified city-specific homepage can lead us there in one hop.
        if (re.search(r"\b(?:chirurg\w*|surgery)\b", blob)
                and re.search(r"\b(?:estetic\w*|aesthetic\w*|plastic\w*)\b", blob)):
            score += 4

        # Prefer shallow service/price pages over random blog pagination.
        path = urlparse(absolute).path or "/"
        depth = len([x for x in path.split("/") if x])
        if depth <= 3:
            score += 1

        if any(x in blob for x in ["blog", "news", "author", "tag", "category"]):
            score -= 2

        # A shallow generic page such as /about gets only the +1 depth bonus
        # and must not be crawled. Require at least one real price/procedure/
        # service signal.
        if score <= 1:
            continue

        prev = candidates.get(absolute)
        if prev is None or score > prev:
            candidates[absolute] = score

    return [
        url
        for url, _score in sorted(
            candidates.items(),
            key=lambda item: (-item[1], len(item[0])),
        )[:limit]
    ]



async def official_site_sitemap_candidate_links(
    base_url: str,
    procedure: str,
    language: str,
    limit: int = 6,
    identity_mode: bool = False,
) -> list[str]:
    """Find procedure/price URLs in a clinic sitemap without using Serper."""
    parsed = urlparse(base_url)
    if not parsed.scheme or not parsed.netloc:
        return []
    root = f"{parsed.scheme}://{parsed.netloc}"
    # Many multilingual WordPress installations expose a sitemap index (or a
    # robots.txt Sitemap entry) rather than /sitemap.xml. A three-child cap
    # also misses language-specific page maps farther into the index.
    robots = await fetch_text_document(urljoin(root + "/", "robots.txt")) or ""
    advertised = re.findall(r"(?im)^\s*Sitemap:\s*(https?://\S+)", robots)
    roots = list(dict.fromkeys([
        *[u for u in advertised if host_of(u) == host_of(root)],
        urljoin(root + "/", "sitemap.xml"),
        urljoin(root + "/", "sitemap_index.xml"),
        urljoin(root + "/", "wp-sitemap.xml"),
    ]))
    documents = await asyncio.gather(
        *(fetch_text_document(u) for u in roots), return_exceptions=True,
    )
    locs = []
    for document in documents:
        if isinstance(document, str):
            locs.extend(_sitemap_locs(document))
    if not locs:
        return []
    child_maps = [u for u in dict.fromkeys(locs)
                  if urlparse(u).path.lower().endswith(".xml")
                  and host_of(u) == host_of(root)]
    child_maps.sort(key=lambda u: (
        0 if re.search(r"(?:page|post|de|en|it)[-_]sitemap", u, re.I) else 1,
        u,
    ))
    child_maps = child_maps[:max(1, int(os.getenv("MAX_SITEMAP_CHILD_MAPS", "12")))]
    page_urls = [u for u in locs if not u.lower().endswith(".xml")]

    if child_maps:
        children = await asyncio.gather(
            *(fetch_text_document(u) for u in child_maps),
            return_exceptions=True,
        )
        for child in children:
            if isinstance(child, Exception) or not child:
                continue
            page_urls.extend(
                u for u in _sitemap_locs(child)
                if not u.lower().endswith(".xml")
            )

    canonical = canonicalize_procedure(procedure)
    proc_terms = aliases_for(procedure)[:6] + local_terms_for(procedure, language)[:4]
    if canonical == "filler":
        proc_terms += ["lip filler", "dermal filler", "filler", "rhinofiller"]

    price_terms = PRICE_PATH_HINTS + ["cost", "costs", "fee", "fees"]
    base_host = host_of(base_url)
    scored = {}

    for url in page_urls:
        if host_of(url) != base_host:
            continue
        blob = fold(urlparse(url).path)
        score = 0
        if identity_mode:
            for term in LEGAL_IDENTITY_PATH_HINTS:
                token = fold(term)
                if token and token in blob:
                    score += 10 if token in {
                        "contact", "contacts", "contatti", "kontakt",
                        "contacto", "imprint", "impressum", "legal",
                        "aviso-legal", "mentions-legales",
                    } else 4
            if any(x in blob for x in ["tag/", "author/", "category/", "blog/"]):
                score -= 5
            if score > 0:
                scored[url] = max(score, scored.get(url, 0))
            continue
        for term in proc_terms:
            t = fold(term)
            if t and t in blob:
                score += 8
        for term in price_terms:
            t = fold(term)
            if t and t in blob:
                score += 4

        # Promo/membership pages often have opaque names (for example a
        # platform/program page) but can contain the only public tariff.
        if any(
            token in blob
            for token in [
                "promo", "offer", "ofert", "discount", "zbrit",
                "platform", "platforma", "membership", "loyalty",
                "package", "paketa",
            ]
        ):
            score += 3

        if any(x in blob for x in ["tag/", "author/", "category/"]):
            score -= 3
        # Blog/article URLs are allowed if they are strongly procedure/price specific.
        if "blog" in blob or "news" in blob:
            score -= 1
        if score > 0:
            scored[url] = max(score, scored.get(url, 0))

    return [
        url for url, _ in sorted(
            scored.items(),
            key=lambda kv: (-kv[1], len(kv[0])),
        )[:limit]
    ]



def bad_host(url: str) -> bool:
    h = host_of(url)
    if not h:
        return True

    blocked = {
        "youtube.com", "youtu.be", "wikipedia.org", "pinterest.com",
        "reddit.com", "healthline.com", "webmd.com", "mayoclinic.org",
    }

    return any(h == x or h.endswith("." + x) for x in blocked)


PRICE_PAGE_TERMS = [
    "price", "prices", "pricing", "price-list", "pricelist",
    "cost", "costs", "costo", "kosto", "kostoja", "tariff", "tariffs", "tarife",
    "prezzo", "prezzi", "listino", "preisliste", "preise", "gebuhren", "gebuehren",
    "pret", "preturi", "preț", "prețuri", "precio", "precios", "prix",
    "preco", "precos", "preço", "preços", "fiyat", "fiyatlar", "ucret", "ücret",
    "cena", "cennik", "prijzen", "цена", "цени",
    "cmim", "çmim", "cmime", "çmime", "fees",
]


def price_page_signal(hit: SearchHit, procedure: str) -> int:
    """Score pages likely to carry a clinic-specific treatment price."""
    src = classify_source(hit.url)
    blob = fold(f"{hit.title} {hit.snippet} {hit.url}")
    path = fold(urlparse(hit.url).path)
    if re.search(r"/(?:blog|news|author)(?:/|$)", path):
        return 0
    if re.search(r"(?:how-much|cost-in|costs?-and-prices|/learn/)", path):
        return 0
    score = 0

    if src == "marketplace" and is_probable_single_business_page(hit.url):
        score += 10

    if any(fold(term) in path for term in PRICE_PAGE_TERMS):
        score += 8
    elif any(fold(term) in blob for term in PRICE_PAGE_TERMS):
        score += 3

    if has_procedure(blob, procedure):
        score += 5

    canonical = canonicalize_procedure(procedure)
    if canonical == "filler" and any(
        x in path for x in [
            "filler", "fillers", "lip-filler", "dermal-filler",
            "hyaluronic", "rhinofiller", "nasolabial",
        ]
    ):
        score += 4

    if hit.directory_verified:
        if canonical in (hit.directory_capabilities or []):
            score += 3
        if (urlparse(hit.url).path or "/") in {"", "/"}:
            score -= 2

    return score


def local_official_from_city_query(
    url: str, query: str, city: str, country_code: str,
) -> bool:
    """A city-scoped search may open a local official host.

    The snippet often omits the city. The opened page still has to name it
    before a price can become a card.
    """
    host = host_of(url or "")
    if not host or not city_in_text(query or "", city):
        return False
    suffix = {
        "AL": ".al",
        "IT": ".it",
        "GB": ".uk",
        "UK": ".uk",
    }.get((country_code or "").upper(), "")
    return bool(suffix and host.endswith(suffix))


def site_focus_result_relevant(
    hit: SearchHit, procedure: str, city: str = "",
) -> bool:
    """Keep treatment pages and local clinic roots that can link to tariffs."""
    root = (urlparse(hit.url).path or "/").strip("/") == ""
    blob = fold(f"{hit.title} {hit.snippet}")
    return (
        has_procedure(f"{hit.title} {hit.snippet} {hit.url}", procedure)
        or is_price_menu_path(hit.url)
        or (root and bool(city) and city_in_text(blob, city)
            and bool(re.search(
                r"\b(?:clinic|klinike|klinika|spital|hospital|"
                r"medical|chirurg\w*|surgery|estetic\w*|aesthetic\w*)\b",
                blob + " " + domain_brand(hit.url),
            )))
    )


def cached_price_navigation_hits(
    directory_hits: list[SearchHit], req: DiscoverRequest, limit: int = 8,
) -> list[SearchHit]:
    """Reuse price links from official homepages fetched in earlier rounds.

    This reads the per-loop HTTP cache; it neither pays for Serper nor fetches
    another root page. The normal page processing still checks every price.
    """
    if not req.previously_fetched_urls:
        return []
    state = _fetch_state()
    visited = set(req.previously_fetched_urls)
    now = time.monotonic()
    result = []
    seen_hosts = set()
    for hit in directory_hits:
        host = host_of(hit.url)
        if (not host or host in seen_hosts or not hit.directory_verified
                or classify_source(hit.url) != "official_clinic"
                or already_stored_clinic_hit(hit, req)):
            continue
        cached_roots = [
            (url, entry[1]) for (url, xml), entry in state["cache"].items()
            if not xml and entry[0] > now and entry[1] and url in visited
            and related_clinic_hosts(host_of(url), host)
            and (urlparse(url).path or "/") in {"", "/"}
        ]
        if not cached_roots:
            continue
        for root_url, html in cached_roots:
            if is_obvious_financial_site(html):
                continue
            links = official_site_candidate_links(
                root_url, html, req.procedure, "sq", limit=8,
            )
            price_links = [link for link in links
                           if link not in visited and is_price_menu_path(link)]
            if not price_links:
                continue
            result.append(hit.model_copy(update={
                "url": price_links[0], "query": "adaptive_site_search",
            }))
            seen_hosts.add(host)
            break
        if len(result) >= limit:
            break
    return result


def procedure_subdomain_candidates(
    provider: SearchHit,
    procedure: str,
    indexed_hits: list[SearchHit],
    language: str,
    limit: int = 2,
) -> list[SearchHit]:
    """Guess bounded procedure microsites under a verified clinic host.

    Search-result language paths supply the likely local spelling, but neither
    the clinic host nor any published procedure microsite is hardcoded.
    """
    host = host_of(provider.url)
    if not host or not provider.directory_verified:
        return []
    languages = []
    for indexed in indexed_hits:
        if not related_clinic_hosts(host_of(indexed.url), host):
            continue
        first = urlparse(indexed.url).path.strip("/").split("/")[0].lower()
        match = re.match(r"^(it|sq|en|de|fr|es|ro)(?:$|[-_])", first)
        if match and match.group(1) not in languages:
            languages.append(match.group(1))
    if language not in languages:
        languages.append(language)
    labels = []
    for term in [
        *(t for lang in languages for t in local_terms_for(procedure, lang)),
        *aliases_for(procedure),
    ]:
        label = fold(term).strip().lower()
        if (re.fullmatch(r"[a-z]{5,32}", label)
                and label not in labels and label not in {"clinic", "prices"}):
            labels.append(label)
    return [provider.model_copy(update={
        "url": f"https://{label}.{host}/",
        "query": "adaptive_site_search",
    }) for label in labels[:max(0, limit)]]


def indexed_price_discovery_queries(
    city: str, procedure: str, country_code: str, language: str,
) -> list[str]:
    """Find indexed clinic-owned price pages outside the city-directory top N."""
    terms = local_terms_for(procedure, language)
    local = terms[0] if terms else display_name(canonicalize_procedure(procedure))
    if country_code == "AL" and canonicalize_procedure(procedure) == "rhinoplasty":
        # Albanian definite genitive: rinoplastikë -> rinoplastikës.
        inflected = local[:-1] + "ës" if local.endswith("ë") else local
        return [
            f"{inflected} Shqipëri çmimi euro spital",
            f"{inflected} Shqipëri kostoja euro klinikë",
            # A clinic may serve Tirana from an Italian-language tariff that
            # Albanian-language indexing misses altogether.
            f"rinoplastica {city} listino prezzi clinica estetica",
        ]
    _lang, words = search_profile(country_code, city)
    return [
        f"{local} {city} {words[-1] if words else 'prices'}",
        f"{display_name(canonicalize_procedure(procedure))} {city} clinic price list",
    ]


def alternate_indexed_price_queries(
    city: str, procedure: str, country_code: str,
) -> list[str]:
    """Generic locale variations for a bounded search after cache-only rounds."""
    if country_code == "AL" and canonicalize_procedure(procedure) == "rhinoplasty":
        return [
            f"rinoplastica {city} prezzi clinica chirurgia",
            f"rhinoplasty {city} clinic surgery price EUR",
            f"rinoplastike {city} cmimi klinika euro",
            f"rinoplastica {city} prezzi operazione naso clinica",
        ]
    language, words = search_profile(country_code, city)
    local = (local_terms_for(procedure, language) or [display_name(procedure)])[0]
    english = display_name(canonicalize_procedure(procedure)) or local
    # A fully cached generic query cannot surface a clinic indexed under a
    # different price-page title. These stay procedure-and-city searches.
    return [
        f'"{local}" "{city}" "{words[-1] if words else "prices"}"',
        f'"{local}" "{city}" "{words[0] if words else "price"}" clinic',
        f'site:whatclinic.com "{city}" "{english}"',
        f'"{english}" "{city}" "price catalog"',
        f"{local} {city} clinic treatment prices",
        f"{local} {city} published clinic price",
    ]


def adaptive_site_search_hosts(
    directory_hits: list[SearchHit], req: DiscoverRequest, limit: int,
) -> list[str]:
    """Search unpriced clinics from the last crawl before unrelated domains."""
    visited = {host_of(url) for url in req.previously_fetched_urls}
    recent = set(req.previous_round_verified_hosts)
    canonical = canonicalize_procedure(req.procedure)
    surgical = canonical in {
        "rhinoplasty", "breast_augmentation", "facelift", "liposuction",
        "blepharoplasty", "tummy_tuck", "otoplasty",
    }
    rows = []
    seen = set()
    for hit in directory_hits:
        host = host_of(hit.url)
        if (not host or host in seen or not hit.directory_verified
                or classify_source(hit.url) != "official_clinic"
                or already_stored_clinic_hit(hit, req)):
            continue
        seen.add(host)
        capabilities = hit.directory_capabilities or []
        if capabilities and canonical not in capabilities:
            continue
        label = fold(f"{hit.place_name or hit.title} {domain_brand(hit.url)}")
        surgical_provider = bool(re.search(
            r"\b(?:hospital|spital|surgery|surgical|chirurg(?:ia|ie)?)\b",
            label,
        )) and not bool(re.search(r"\b(?:dental|dentist|dentale)\b", label))
        score = (
            0 if surgical and surgical_provider else 1,
            0 if host in recent else 1,
            0 if canonical in capabilities else 1,
            0 if host in visited else 1,
            -float(hit.directory_relevance_score or 0),
        )
        rows.append((score, host))
    rows.sort(key=lambda item: item[0])
    return [host for _, host in rows[:max(0, limit)]]


def select_internal_links_fairly(
    hits: list[SearchHit],
    procedure: str,
    limit: int,
) -> list[SearchHit]:
    """Prefer tariff pages, while giving each clinic a chance within the cap."""
    by_host: dict[str, list[SearchHit]] = {}
    for hit in hits:
        host = host_of(hit.url)
        if host:
            by_host.setdefault(host, []).append(hit)
    for group in by_host.values():
        group.sort(
            key=lambda h: (
                -price_page_signal(h, procedure),
                -_directory_url_relevance(h.url),
                len(h.url),
            )
        )
    chosen = []
    while by_host and len(chosen) < max(0, limit):
        for host in list(by_host):
            group = by_host[host]
            chosen.append(group.pop(0))
            if not group:
                del by_host[host]
            if len(chosen) >= limit:
                break
    return chosen


def select_discovery_work(unique: list[SearchHit], req: DiscoverRequest, rank_fn):
    """Use separate crawl lanes instead of one global top-45 list."""
    unique = [hit for hit in unique if not already_stored_clinic_hit(hit, req)]

    if req.hybrid_interactive:
        # One bounded round in the user-facing endpoint, even with full_growth.
        max_total = int(os.getenv(
            "MAX_ADAPTIVE_ROOT_PAGES" if req.adaptive_rescue else "MAX_INTERACTIVE_ROOT_PAGES",
            "18" if req.adaptive_rescue else "10",
        ))
        max_marketplace = 4 if req.app_fast_queries else 2
        max_price_like = 4 if req.app_fast_queries else (10 if req.adaptive_rescue else 6)
        max_directory = 2 if req.app_fast_queries else (14 if req.adaptive_rescue else 8)
    elif req.interactive_fast:
        if req.full_growth:
            max_total = int(
                os.getenv("MAX_FULL_GROWTH_PAGES_TO_FETCH", "105")
            )
            max_marketplace = int(
                os.getenv("MAX_FULL_GROWTH_MARKETPLACE_PROFILE_PAGES", "12")
            )
            max_price_like = int(
                os.getenv("MAX_FULL_GROWTH_PRICE_LIKE_OFFICIAL_PAGES", "18")
            )
            max_directory = int(
                os.getenv("MAX_FULL_GROWTH_DIRECTORY_ROOT_PAGES", "55")
            )
        else:
            max_total = int(os.getenv("MAX_HYBRID_PAGES_TO_FETCH", "36"))
            max_marketplace = int(
                os.getenv("MAX_HYBRID_MARKETPLACE_PROFILE_PAGES", "12")
            )
            max_price_like = int(
                os.getenv("MAX_HYBRID_PRICE_LIKE_OFFICIAL_PAGES", "14")
            )
            max_directory = int(
                os.getenv("MAX_HYBRID_DIRECTORY_ROOT_PAGES", "8")
            )
    else:
        max_total = int(os.getenv("MAX_PAGES_TO_FETCH", "60"))
        max_marketplace = int(os.getenv("MAX_MARKETPLACE_PROFILE_PAGES", "16"))
        max_price_like = int(os.getenv("MAX_PRICE_LIKE_OFFICIAL_PAGES", "22"))
        max_directory = int(os.getenv("MAX_DIRECTORY_ROOT_PAGES", "12"))

    selected = []
    seen = set()
    seen_provider_hosts = set()
    counts = {
        "marketplace": 0,
        "price_like": 0,
        "directory": 0,
        "general": 0,
    }

    def add(rows, lane, limit, repeat_provider=False):
        for hit in rows:
            if len(selected) >= max_total or counts[lane] >= limit:
                break
            if not hit.url or hit.url in seen:
                continue
            host = host_of(hit.url)
            if (not repeat_provider and classify_source(hit.url) == "official_clinic"
                    and any(related_clinic_hosts(host, old) for old in seen_provider_hosts)):
                continue
            seen.add(hit.url)
            if classify_source(hit.url) == "official_clinic":
                seen_provider_hosts.add(host)
            selected.append(hit)
            counts[lane] += 1


    if req.search_mode == "site_focus":
        # A real discovered URL precedes a guessed /prices/ or another root.
        discovered = sorted(
            [h for h in unique if h.url in req.priority_site_urls],
            key=lambda h: (-price_page_signal(h, req.procedure), rank_fn(h)),
        )
        add(discovered, "price_like", max_total)
        # One homepage per remaining clinic before guessed tariff paths.
        roots = sorted(
            [h for h in unique if urlparse(h.url).path in {"", "/"}],
            key=rank_fn,
        )
        add(roots, "directory", min(12, max_total))
        linked = [h for h in unique if h.url not in seen]
        linked = sorted(linked, key=lambda h: (-price_page_signal(h, req.procedure), rank_fn(h)))
        add(linked, "price_like", max_total)
        add(linked, "price_like", max_total, repeat_provider=True)
        return selected, counts

    marketplace_profiles = sorted(
        [
            h for h in unique
            if classify_source(h.url) == "marketplace"
            and is_probable_single_business_hit(h, req.city)
        ],
        key=lambda h: (-price_page_signal(h, req.procedure), rank_fn(h)),
    )
    add(marketplace_profiles, "marketplace", max_marketplace)

    price_like = sorted(
        [
            h for h in unique
            if classify_source(h.url) == "official_clinic"
            and not h.directory_verified
            and price_page_signal(h, req.procedure) >= 5
        ],
        key=lambda h: (-price_page_signal(h, req.procedure), rank_fn(h)),
    )
    add(price_like, "price_like", max_price_like)

    canonical = canonicalize_procedure(req.procedure)
    directory_roots = sorted(
        [
            h for h in unique
            if h.directory_verified
            and (
                req.full_growth
                or canonical in (h.directory_capabilities or [])
                or not h.directory_capabilities
            )
        ],
        key=lambda h: (
            0
            if canonical in (h.directory_capabilities or [])
            else (1 if not h.directory_capabilities else 2),
            -float(h.directory_relevance_score or 0.0),
            rank_fn(h),
        ),
    )
    add(directory_roots, "directory", max_directory)

    remaining = sorted(
        [h for h in unique if h.url not in seen],
        key=lambda h: (-price_page_signal(h, req.procedure), rank_fn(h)),
    )
    add(remaining, "general", max_total)
    # Only unused slots may revisit a provider after other domains got a turn.
    add(remaining, "general", max_total, repeat_provider=True)

    return selected, counts



# ============================================================
# Marketplace -> official-site verification
# ============================================================

OFFICIAL_NAME_STOPWORDS = {
    "clinic", "klinika", "poliklinika", "medical", "medicine", "aesthetic",
    "aesthetics", "esthetic", "esthetics", "beauty", "spa", "center", "centre",
    "hospital", "day", "dr", "doctor", "doctors", "the", "and",
}


def official_site_root(url: str) -> str:
    parsed = urlparse(url or "")
    if not parsed.scheme or not parsed.netloc:
        return ""
    return f"{parsed.scheme}://{parsed.netloc}/"


def clinic_identity_tokens(name: str) -> list[str]:
    words = re.findall(r"[a-z0-9]+", fold(name or ""))
    return [
        w for w in words
        if w not in OFFICIAL_NAME_STOPWORDS and len(w) >= 2
    ]


def clinic_identity_similarity(a: str, b: str) -> float:
    ka = _clinic_compare_key(a)
    kb = _clinic_compare_key(b)
    if not ka or not kb:
        return 0.0
    if ka == kb:
        return 1.0

    ta = set(clinic_identity_tokens(a))
    tb = set(clinic_identity_tokens(b))

    token_score = 0.0
    if ta and tb:
        token_score = len(ta & tb) / max(len(ta), len(tb))

    compact_score = SequenceMatcher(None, ka, kb).ratio()

    # One distinctive token can be enough when one source prefixes the clinic
    # name with "Poliklinika", "Dr", "Aesthetic Clinic", etc.
    contained = 0.0
    if ta and tb and (ta <= tb or tb <= ta):
        contained = 0.92

    return max(token_score, compact_score, contained)


def marketplace_variant_tags(row: ClinicPriceResult) -> tuple[set[str], str]:
    blob = fold(
        " ".join(
            [
                row.procedure_detail or "",
                row.raw_procedure_text or "",
                row.raw_evidence or "",
            ]
        )
    )

    anatomy = set()
    mapping = {
        "lip": ["lip", "lips", "buz", "buze"],
        "cheek": ["cheek", "malar"],
        "chin": ["chin", "menton"],
        "jaw": ["jaw", "jawline", "mandib"],
        "nose": ["rhinofiller", "nose filler", "nasal filler"],
        "nasolabial": ["nasolabial"],
        "tear_trough": ["tear trough", "under eye", "under-eye"],
        "temple": ["temple", "temporal"],
    }
    for tag, terms in mapping.items():
        if any(fold(term) in blob for term in terms):
            anatomy.add(tag)

    ml = ""
    m = re.search(r"(\d+(?:[.,]\d+)?)\s*ml\b", blob, re.I)
    if m:
        ml = m.group(1).replace(",", ".")

    return anatomy, ml


OFFICIAL_RESOLUTION_BLOCKED_HOSTS = {
    "facebook.com", "instagram.com", "tiktok.com", "linkedin.com",
    "x.com", "twitter.com", "threads.net", "threads.com",
    "fresha.com", "whatclinic.com", "booksy.com", "treatwell.com",
    "hirefrederick.com",
    "wupdoc.com", "realself.com", "worldclinics.net",
    "beautynailhairsalons.com",
    "albest.al",
    "gjithebiznesi.com",
    "gjejbiznese.com",
    "cybo.com",
    "wanderlog.com",
    "booking.com", "tripadvisor.com", "youtube.com", "youtu.be",
    "google.com", "maps.google.com", "maps.app.goo.gl", "goo.gl",
    "freshastatus.com",
}


def blocked_for_official_resolution(url: str) -> bool:
    h = host_of(url)
    if not h:
        return True
    if bad_host(url):
        return True

    # Platform-owned support/status/marketing domains are never a clinic's
    # official website even when linked from a marketplace footer.
    if any(token in h for token in [
        "fresha", "whatclinic", "booksy", "treatwell", "hirefrederick"
    ]):
        return True

    return any(
        h == x or h.endswith("." + x)
        for x in OFFICIAL_RESOLUTION_BLOCKED_HOSTS
    )


def marketplace_outbound_official_candidates(
    marketplace_url: str,
    html: str,
) -> list[str]:
    """Extract plausible clinic-owned external links from a marketplace profile."""
    if not marketplace_url or not html:
        return []

    src_host = host_of(marketplace_url)
    soup = BeautifulSoup(html, "lxml")
    out = []
    seen = set()

    for a in soup.find_all("a", href=True):
        href = (a.get("href") or "").strip()
        if not href:
            continue

        label = fold(" ".join(a.stripped_strings))
        if any(x in label for x in [
            "map", "maps", "directions", "location",
            "open in google", "google maps",
        ]):
            continue

        url = safe_http_urljoin(marketplace_url, href)
        h = host_of(url)
        if not h or h == src_host:
            continue
        if blocked_for_official_resolution(url):
            continue
        if classify_source(url) != "official_clinic":
            continue

        root = official_site_root(url) or url
        if root in seen:
            continue
        seen.add(root)
        out.append(root)

    return out[:8]


def official_candidate_has_sufficient_local_evidence(
    candidate: SearchHit,
    local_ok: bool,
    intrinsic_score: float,
) -> bool:
    """Decide whether a candidate can be accepted without an explicit city.

    Guessed domains and ordinary web-search hits may never rely on name/domain
    similarity alone. Direct marketplace outbound links can, because the link
    comes from the exact marketplace business profile. A cached directory row
    may do so only when backed by a Google Place ID.
    """
    if local_ok:
        return True

    if (
        candidate.query == "marketplace_outbound"
        and intrinsic_score >= 0.90
    ):
        return True

    if candidate.query == "brand_identity_probe":
        return False

    if (
        candidate.query == "clinic_directory"
        and bool(candidate.place_id)
        and intrinsic_score >= 0.75
    ):
        return True

    return False



async def verify_official_candidate(
    candidate: SearchHit,
    clinic_name: str,
    city: str,
) -> SearchHit | None:
    if not candidate.url or blocked_for_official_resolution(candidate.url):
        return None
    if classify_source(candidate.url) != "official_clinic":
        return None

    root = official_site_root(candidate.url) or candidate.url
    html = await fetch_html(root)
    if not html:
        return None

    text = page_text(html)
    resolved_name = (
        await resolve_clinic_name(
            html,
            root,
            candidate.title,
            city,
        )
    ) or domain_brand(root)

    resolved_score = clinic_identity_similarity(
        clinic_name,
        resolved_name,
    )
    domain_score = clinic_identity_similarity(
        clinic_name,
        domain_brand(root),
    )
    title_score = clinic_identity_similarity(
        clinic_name,
        candidate.title,
    )

    # A marketplace outbound candidate used to receive the clinic name as its
    # synthetic title, which made every external footer link score 1.0.
    if candidate.query == "marketplace_outbound":
        score = max(resolved_score, domain_score)
    else:
        score = max(resolved_score, domain_score, title_score)

    if score < 0.50:
        return None

    page_blob = f"{candidate.title} {candidate.snippet} {text[:12000]}"
    local_ok = (
        strong_local_page_evidence(html, text, city, root)
        or city_in_text(page_blob, city)
    )

    intrinsic_score = max(resolved_score, domain_score)
    if not official_candidate_has_sufficient_local_evidence(
        candidate,
        local_ok,
        intrinsic_score,
    ):
        return None

    quality_ok, relevance, reason = clinic_directory_site_quality(
        html,
        root,
        city,
        business_name=resolved_name or clinic_name,
    )
    if not quality_ok and reason in {"retail", "agency"}:
        return None

    return SearchHit(
        title=resolved_name or candidate.title or clinic_name,
        url=root,
        snippet=city,
        query="marketplace_official_verified",
        directory_verified=True,
        directory_verification_source=(
            candidate.query or "marketplace_official_verified"
        ),
        directory_relevance_score=max(
            float(relevance or 0.0),
            score,
            0.50,
        ),
        directory_capabilities=[],
    )



DOMAIN_PROBE_STOPWORDS = {
    "clinic", "klinika", "medical", "aesthetic", "aesthetics",
    "esthetic", "esthetics", "beauty", "spa", "center", "centre",
    "hospital", "day", "dr", "doctor",
    "fitness", "wellness", "club", "studio", "salon",
    "and", "the", "of",
}


def official_domain_probe_candidates(
    clinic_name: str,
    country_code: str,
) -> list[str]:
    """Generate a very small set of plausible clinic-owned domains.

    This is intentionally conservative and every candidate must still pass
    verify_official_candidate(), including clinic identity/location checks.
    """
    words = re.findall(r"[a-z0-9]+", fold(clinic_name or ""))
    words = [w for w in words if w]

    if not words:
        return []

    full_compact = "".join(words)
    full_hyphen = "-".join(words)

    core_words = [w for w in words if w not in DOMAIN_PROBE_STOPWORDS]
    core_compact = "".join(core_words)
    core_hyphen = "-".join(core_words)

    stems = []
    for stem in [
        full_compact,
        full_hyphen,
        core_compact,
        core_hyphen,
    ]:
        stem = stem.strip("-")
        if len(stem) < 4:
            continue
        if stem not in stems:
            stems.append(stem)

    cc = (country_code or "").strip().lower()
    tlds = []
    if cc and len(cc) == 2:
        tlds.append(cc)
    tlds.append("com")

    out = []
    seen = set()

    # Prefer .com after country TLD for brands that use international domains.
    ordered_tlds = []
    for tld in ["com"] + tlds:
        if tld and tld not in ordered_tlds:
            ordered_tlds.append(tld)

    for stem in stems[:3]:
        for tld in ordered_tlds[:2]:
            url = f"https://{stem}.{tld}/"
            if url not in seen:
                seen.add(url)
                out.append(url)

    return out[:6]


def marketplace_brand_identity_domain_candidates(
    clinic_name: str,
    country_code: str,
) -> list[str]:
    """Generate a conservative short-brand domain candidate.

    Only one distinctive token is allowed after generic business words are
    removed. This avoids reintroducing full-name guessed-domain false positives.
    """
    words = re.findall(r"[a-z0-9]+", fold(clinic_name or ""))
    core = [
        w for w in words
        if w not in DOMAIN_PROBE_STOPWORDS and len(w) >= 4
    ]

    if len(core) != 1:
        return []

    brand = core[0]
    cc = (country_code or "").strip().lower()

    tlds = []
    if cc and len(cc) == 2:
        tlds.append(cc)
    tlds.append("com")

    out = []
    for tld in tlds:
        url = f"https://{brand}.{tld}/"
        if url not in out:
            out.append(url)

    return out[:2]


async def probe_marketplace_brand_identity_domain(
    clinic_name: str,
    city: str,
    country_code: str,
) -> tuple[SearchHit | None, int]:
    """Confirm official identity from a short brand domain.

    This does not require the official website itself to list the treatment,
    because the exact marketplace service menu remains the price source.
    """
    urls = marketplace_brand_identity_domain_candidates(
        clinic_name,
        country_code,
    )
    if not urls:
        return None, 0

    attempts = len(urls)

    for url in urls:
        try:
            verified = await verify_official_candidate(
                SearchHit(
                    title=domain_brand(url),
                    url=url,
                    snippet="",
                    query="brand_identity_probe",
                ),
                clinic_name,
                city,
            )
        except Exception:
            verified = None

        if not verified:
            continue

        identity_score = clinic_identity_similarity(
            clinic_name,
            verified.title,
        )
        if identity_score < 0.68:
            continue

        verified.directory_verification_source = "brand_identity_probe"
        return verified, attempts

    return None, attempts



def clinic_name_search_variants(clinic_name: str) -> list[str]:
    """Small generic set of search variants for marketplace business names."""
    raw = re.sub(r"\s+", " ", (clinic_name or "").strip())
    if not raw:
        return []

    variants = [raw]

    # Marketplace naming often differs only by singular/plural or punctuation.
    low = fold(raw)
    if "aesthetic" in low and "aesthetics" not in low:
        variants.append(
            re.sub(
                r"\baesthetic\b",
                "Aesthetics",
                raw,
                flags=re.I,
            )
        )
    elif "aesthetics" in low:
        variants.append(
            re.sub(
                r"\baesthetics\b",
                "Aesthetic",
                raw,
                flags=re.I,
            )
        )

    # Also try a punctuation-light brand phrase.
    compact_words = re.findall(r"[A-Za-z0-9]+", raw)
    if compact_words:
        variants.append(" ".join(compact_words))

    out = []
    seen = set()
    for value in variants:
        key = fold(value)
        if key and key not in seen:
            seen.add(key)
            out.append(value)

    return out[:3]


async def domain_probe_confirms_requested_procedure(
    official_hit: SearchHit,
    procedure: str,
    language: str,
) -> bool:
    """A guessed domain must prove the requested treatment on its own site."""
    root = official_site_root(official_hit.url) or official_hit.url
    homepage = await fetch_html(root)
    if not homepage:
        return False

    canonical = canonicalize_procedure(procedure)
    if has_procedure(page_text(homepage), canonical):
        return True

    try:
        links = official_site_candidate_links(
            root,
            homepage,
            canonical,
            language,
            limit=int(
                os.getenv(
                    "MAX_DOMAIN_PROBE_PROCEDURE_PAGES",
                    "4",
                )
            ),
        )
    except Exception:
        links = []

    if not links:
        return False

    pages = await asyncio.gather(
        *(fetch_html(url) for url in links[:4]),
        return_exceptions=True,
    )

    for html in pages:
        if isinstance(html, Exception) or not html:
            continue
        if has_procedure(page_text(html), canonical):
            return True

    return False



async def probe_official_domain_candidates(
    clinic_name: str,
    city: str,
    country_code: str,
    procedure: str,
    language: str,
) -> tuple[SearchHit | None, int, int]:
    urls = official_domain_probe_candidates(
        clinic_name,
        country_code,
    )

    attempts = len(urls)
    if not urls:
        return None, 0, 0

    async def verify(url: str):
        try:
            return await verify_official_candidate(
                SearchHit(
                    title=domain_brand(url),
                    url=url,
                    snippet="",
                    query="domain_probe",
                ),
                clinic_name,
                city,
            )
        except Exception:
            return None

    results = await asyncio.gather(
        *(verify(url) for url in urls),
        return_exceptions=True,
    )

    verified = []
    for result in results:
        if isinstance(result, Exception) or result is None:
            continue
        verified.append(result)

    if not verified:
        return None, attempts, 0

    verified.sort(
        key=lambda hit: max(
            clinic_identity_similarity(clinic_name, hit.title),
            clinic_identity_similarity(
                clinic_name,
                domain_brand(hit.url),
            ),
        ),
        reverse=True,
    )

    rejected_no_procedure = 0
    for hit in verified:
        if await domain_probe_confirms_requested_procedure(
            hit,
            procedure,
            language,
        ):
            return hit, attempts, rejected_no_procedure
        rejected_no_procedure += 1

    return None, attempts, rejected_no_procedure


def _directory_match_for_marketplace(
    clinic_name: str,
    directory_hits: list[SearchHit],
) -> SearchHit | None:
    best = None
    best_score = 0.0

    for hit in directory_hits:
        if not hit.directory_verified:
            continue
        score = clinic_identity_similarity(clinic_name, hit.title)
        if score > best_score:
            best = hit
            best_score = score

    return best if best is not None and best_score >= 0.72 else None


STRONG_DIRECTORY_VERIFICATION_SOURCES = {
    "google_places",
    "places",
    "web_search_linked_official",
    "marketplace_profile_link",
    "manual_verified",
}


def marketplace_directory_match_is_strong(
    hit: SearchHit | None,
    clinic_name: str = "",
) -> bool:
    if hit is None:
        return False
    if hit.place_id:
        return True

    source = fold(hit.directory_verification_source or "")

    if source in STRONG_DIRECTORY_VERIFICATION_SOURCES:
        return True

    # A prior plain web-search match is only strong when the clinic brand is
    # also represented by the domain itself. This prevents an aggregator page
    # that merely mentions the clinic from becoming a permanent official site.
    if source == "web_search":
        return clinic_identity_similarity(
            clinic_name,
            domain_brand(hit.url),
        ) >= 0.35

    return False


def discovery_page_outbound_official_candidates(
    page_url: str,
    html: str,
    clinic_name: str,
) -> list[str]:
    """Find likely clinic-owned websites linked by a discovery/directory page.

    Generic business directories often rank for exact clinic-name searches.
    If such a page explicitly links to the business website, follow that link
    instead of calling the directory itself the clinic's official website.
    """
    if not page_url or not html:
        return []

    src_host = host_of(page_url)
    soup = BeautifulSoup(html, "lxml")
    scored = []
    seen = set()

    for a in soup.find_all("a", href=True):
        href = (a.get("href") or "").strip()
        if not href:
            continue

        url = safe_http_urljoin(page_url, href)
        h = host_of(url)
        if not h or h == src_host:
            continue
        if blocked_for_official_resolution(url):
            continue
        if classify_source(url) != "official_clinic":
            continue

        root = official_site_root(url) or url
        if root in seen:
            continue

        label = fold(" ".join(a.stripped_strings))
        parent_text = fold(
            " ".join(
                a.parent.stripped_strings
                if getattr(a, "parent", None) is not None
                else []
            )
        )[:500]

        domain_score = clinic_identity_similarity(
            clinic_name,
            domain_brand(root),
        )

        explicit_website_label = any(
            token in label or token in parent_text
            for token in [
                "website",
                "web site",
                "official site",
                "official website",
                "visit site",
                "visit website",
                "faqja",
                "webfaqe",
            ]
        )

        # A naked URL shown as anchor text is also a common "Website" field.
        naked_url_label = (
            "." in label
            and len(label.split()) <= 3
        )

        if not (
            explicit_website_label
            or naked_url_label
            or domain_score >= 0.30
        ):
            continue

        score = domain_score
        if explicit_website_label:
            score += 2.0
        if naked_url_label:
            score += 1.0

        seen.add(root)
        scored.append((score, root))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [url for _score, url in scored[:6]]


async def resolve_discovery_hit_to_official(
    hit: SearchHit,
    clinic_name: str,
    city: str,
) -> tuple[SearchHit | None, bool]:
    """Resolve a web-search result to the clinic-owned site.

    Returns `(verified_site, followed_external_website)`.
    """
    if not hit.url:
        return None, False

    try:
        html = await fetch_html(hit.url)
    except Exception:
        html = None

    linked = []
    if html:
        linked = discovery_page_outbound_official_candidates(
            hit.url,
            html,
            clinic_name,
        )

    # If a result page explicitly advertises a different business website,
    # prefer validating that destination first.
    for url in linked:
        verified = await verify_official_candidate(
            SearchHit(
                title=domain_brand(url),
                url=url,
                snippet="",
                query="discovery_outbound",
            ),
            clinic_name,
            city,
        )
        if verified:
            verified.directory_verification_source = (
                "web_search_linked_official"
            )
            return verified, True

    # An unrelated host that advertises an external business website is a
    # discovery/directory page, not the official clinic site.
    current_domain_score = clinic_identity_similarity(
        clinic_name,
        domain_brand(hit.url),
    )
    if linked and current_domain_score < 0.35:
        return None, True

    verified = await verify_official_candidate(
        hit,
        clinic_name,
        city,
    )
    if verified:
        verified.directory_verification_source = "web_search"
    return verified, False


async def deactivate_superseded_directory_matches(
    city: str,
    clinic_name: str,
    directory_hits: list[SearchHit],
    new_hit: SearchHit | None,
) -> int:
    """Deactivate all weak same-clinic directory domains superseded by new hit."""
    if new_hit is None:
        return 0

    new_host = host_of(new_hit.url)
    if not new_host:
        return 0

    rejected = {}

    for hit in directory_hits:
        old_host = host_of(hit.url)
        if not old_host or old_host == new_host:
            continue
        if hit.place_id:
            continue

        similarity = max(
            clinic_identity_similarity(clinic_name, hit.title),
            clinic_identity_similarity(
                clinic_name,
                domain_brand(hit.url),
            ),
        )
        if similarity < 0.72:
            continue

        if marketplace_directory_match_is_strong(
            hit,
            clinic_name,
        ):
            continue

        rejected[old_host] = (
            "superseded_by_stronger_marketplace_official_match:"
            + new_host
        )

    if not rejected:
        return 0

    return await firestore_deactivate_clinic_directory(
        city,
        rejected,
    )



async def resolve_marketplace_official_site(
    clinic_name: str,
    city: str,
    procedure: str,
    directory_hits: list[SearchHit],
    serper: SerperClient,
    marketplace_url: str = "",
    country_code: str = "",
    language: str = "en",
) -> tuple[SearchHit | None, str, int, bool, int, int, int]:
    """Resolve clinic-owned website; directory/search pages are discovery only."""
    weak_directory_skipped = False
    directory_superseded_count = 0
    probe_rejected_no_procedure = 0
    resolution_search_queries = 0

    # 1) Direct website link from exact marketplace profile.
    if marketplace_url:
        try:
            market_html = await fetch_html(marketplace_url)
        except Exception:
            market_html = None

        if market_html:
            for url in marketplace_outbound_official_candidates(
                marketplace_url,
                market_html,
            ):
                verified = await verify_official_candidate(
                    SearchHit(
                        title=domain_brand(url),
                        url=url,
                        snippet="",
                        query="marketplace_outbound",
                    ),
                    clinic_name,
                    city,
                )
                if verified:
                    verified.directory_verification_source = (
                        "marketplace_profile_link"
                    )
                    return (
                        verified,
                        "marketplace_link",
                        0,
                        weak_directory_skipped,
                        directory_superseded_count,
                        probe_rejected_no_procedure,
                        resolution_search_queries,
                    )

    # 2) Only strong directory entries may short-circuit.
    directory_match = _directory_match_for_marketplace(
        clinic_name,
        directory_hits,
    )

    if directory_match:
        if marketplace_directory_match_is_strong(
            directory_match,
            clinic_name,
        ):
            # Plain web_search entries still get audited for "Website" links:
            # old versions may have cached an aggregator as the official site.
            if fold(
                directory_match.directory_verification_source or ""
            ) == "web_search":
                verified, followed = (
                    await resolve_discovery_hit_to_official(
                        directory_match,
                        clinic_name,
                        city,
                    )
                )
                if verified:
                    directory_superseded_count = (
                        await deactivate_superseded_directory_matches(
                            city,
                            clinic_name,
                            directory_hits,
                            verified,
                        )
                    )
                    source = (
                        "linked_discovery_page"
                        if followed
                        else "directory"
                    )
                    return (
                        verified,
                        source,
                        0,
                        False,
                        directory_superseded_count,
                        probe_rejected_no_procedure,
                        resolution_search_queries,
                    )
            else:
                verified = await verify_official_candidate(
                    directory_match,
                    clinic_name,
                    city,
                )
                if verified:
                    verified.directory_verification_source = (
                        directory_match.directory_verification_source
                        or "clinic_directory"
                    )
                    return (
                        verified,
                        "directory",
                        0,
                        False,
                        directory_superseded_count,
                        probe_rejected_no_procedure,
                        resolution_search_queries,
                    )

        weak_directory_skipped = True

    name_variants = clinic_name_search_variants(clinic_name)
    display_proc = display_name(canonicalize_procedure(procedure))

    queries = []
    for name in name_variants:
        queries.append(f'"{name}" "{city}"')

    queries.extend(
        [
            f'"{clinic_name}" "{city}" official website',
            f'"{clinic_name}" "{city}" clinic',
            f'"{clinic_name}" "{city}" "{display_proc}"',
            f'"{clinic_name}" website',
        ]
    )

    deduped_queries = []
    qseen = set()
    for q in queries:
        key = fold(q)
        if key not in qseen:
            qseen.add(key)
            deduped_queries.append(q)
    queries = deduped_queries

    max_per_query = int(
        os.getenv("MAX_MARKETPLACE_OFFICIAL_SEARCH_RESULTS", "10")
    )
    max_queries = max(
        1,
        int(os.getenv("MAX_MARKETPLACE_OFFICIAL_QUERY_ATTEMPTS", "5")),
    )
    seen_urls = set()

    async def try_search_query(
        query: str,
    ) -> tuple[SearchHit | None, bool]:
        nonlocal resolution_search_queries
        resolution_search_queries += 1

        try:
            hits = await serper.search(
                query,
                max_per_query,
                page=1,
            )
        except Exception:
            return None, False

        candidates = []
        for hit in hits:
            if not hit.url or hit.url in seen_urls:
                continue
            seen_urls.add(hit.url)

            if blocked_for_official_resolution(hit.url):
                continue

            candidates.append(hit)

        candidates.sort(
            key=lambda h: max(
                clinic_identity_similarity(clinic_name, h.title),
                clinic_identity_similarity(
                    clinic_name,
                    domain_brand(h.url),
                ),
            ),
            reverse=True,
        )

        for hit in candidates[:6]:
            verified, followed = (
                await resolve_discovery_hit_to_official(
                    hit,
                    clinic_name,
                    city,
                )
            )
            if verified:
                return verified, followed

        return None, False

    # 3) Exhaust a small high-value web-search budget before domain guessing.
    if env_bool("ENABLE_MARKETPLACE_OFFICIAL_WEB_LOOKUP", True):
        for query in queries[:max_queries]:
            verified, followed = await try_search_query(query)
            if verified:
                directory_superseded_count = (
                    await deactivate_superseded_directory_matches(
                        city,
                        clinic_name,
                        directory_hits,
                        verified,
                    )
                )
                return (
                    verified,
                    (
                        "linked_discovery_page"
                        if followed
                        else "search"
                    ),
                    0,
                    weak_directory_skipped,
                    directory_superseded_count,
                    probe_rejected_no_procedure,
                    resolution_search_queries,
                )

    # 4) Exact marketplace price + independently verified short brand domain.
    brand_identity_hit, brand_identity_attempts = (
        await probe_marketplace_brand_identity_domain(
            clinic_name,
            city,
            country_code,
        )
    )

    if brand_identity_hit:
        directory_superseded_count = (
            await deactivate_superseded_directory_matches(
                city,
                clinic_name,
                directory_hits,
                brand_identity_hit,
            )
        )
        return (
            brand_identity_hit,
            "brand_identity_probe",
            brand_identity_attempts,
            weak_directory_skipped,
            directory_superseded_count,
            probe_rejected_no_procedure,
            resolution_search_queries,
        )

    # 5) Last resort: broader guessed domains must prove the requested
    # procedure on the clinic-owned site.
    (
        probed,
        probe_attempts,
        probe_rejected_no_procedure,
    ) = await probe_official_domain_candidates(
        clinic_name,
        city,
        country_code,
        procedure,
        language,
    )

    probe_attempts += brand_identity_attempts

    if probed:
        probed.directory_verification_source = "domain_probe"
        directory_superseded_count = (
            await deactivate_superseded_directory_matches(
                city,
                clinic_name,
                directory_hits,
                probed,
            )
        )
        return (
            probed,
            "domain_probe",
            probe_attempts,
            weak_directory_skipped,
            directory_superseded_count,
            probe_rejected_no_procedure,
            resolution_search_queries,
        )

    return (
        None,
        "",
        probe_attempts,
        weak_directory_skipped,
        directory_superseded_count,
        probe_rejected_no_procedure,
        resolution_search_queries,
    )


def apply_official_marketplace_verification(
    row: ClinicPriceResult,
    official_hit: SearchHit | None,
    procedure_confirmed: bool,
    official_prices: list[tuple[ExtractedEvidence, str, float]],
) -> ClinicPriceResult | None:
    """Official clinic price wins; otherwise keep a verified marketplace price.

    A search-snippet-only marketplace price is not returned unless an official
    clinic price can replace it.
    """
    payload = row.model_dump()

    if not official_hit:
        payload["price_verification_status"] = "official_site_unresolved"
        if row.marketplace_price_capture == "search_snippet":
            return None
        return ClinicPriceResult.model_validate(payload)

    official_root = official_site_root(official_hit.url) or official_hit.url
    payload["official_website"] = official_root
    payload["identity_verified"] = True
    payload["official_procedure_verified"] = bool(procedure_confirmed)

    if official_prices:
        evidence, evidence_type, _score = official_prices[0]

        # Preserve the marketplace record as secondary evidence.
        payload["marketplace_source_url"] = (
            row.marketplace_source_url or row.source_url
        )
        payload["marketplace_source_host"] = (
            row.marketplace_source_host or row.source_host
        )
        payload["marketplace_price_min"] = (
            row.marketplace_price_min
            if row.marketplace_price_min is not None
            else row.price_min
        )
        payload["marketplace_price_max"] = (
            row.marketplace_price_max
            if row.marketplace_price_max is not None
            else row.price_max
        )
        payload["marketplace_currency"] = (
            row.marketplace_currency or row.currency
        )
        payload["marketplace_raw_evidence"] = (
            row.marketplace_raw_evidence or row.raw_evidence
        )

        payload["price_min"] = evidence.price_min
        payload["price_max"] = evidence.price_max
        payload["currency"] = evidence.currency
        payload["qualifier"] = evidence.qualifier
        payload["unit"] = evidence.unit
        payload["original_price_min"] = evidence.original_price_min
        payload["original_price_max"] = evidence.original_price_max
        payload["source_url"] = evidence.source_url
        payload["source_host"] = host_of(evidence.source_url)
        payload["source_type"] = "official_clinic"
        payload["evidence_type"] = evidence_type
        payload["clinic_own_price"] = True
        payload["city_match"] = True
        payload["identity_verified"] = True
        payload["official_procedure_verified"] = True
        payload["official_price_found"] = True
        payload["official_price_override"] = True
        payload["price_verification_status"] = "official_price"
        payload["raw_procedure_text"] = evidence.raw_procedure_text
        payload["raw_evidence"] = evidence.raw_evidence
        payload["procedure_detail"] = procedure_detail(
            evidence.raw_evidence,
            row.procedure_canonical,
        )
        payload["product_brand"] = detect_product_brand(
            evidence.raw_evidence,
            row.procedure_canonical,
        )
        payload["product_line"] = detect_product_line(
            evidence.raw_evidence,
            row.procedure_canonical,
        )
        payload["confidence"] = max(float(row.confidence), 0.97)

        return ClinicPriceResult.model_validate(payload)

    if procedure_confirmed:
        payload["price_verification_status"] = (
            "official_procedure_confirmed_marketplace_price"
        )
        payload["confidence"] = min(0.99, max(float(row.confidence), 0.96))
    else:
        payload["price_verification_status"] = (
            "official_identity_confirmed_marketplace_price"
        )
        payload["confidence"] = min(0.99, max(float(row.confidence), 0.93))

    # Snippet-only price is still discovery-only if the official site did not
    # publish a compatible price.
    if row.marketplace_price_capture == "search_snippet":
        return None

    return ClinicPriceResult.model_validate(payload)


def requested_procedure_variant_tags(
    procedure: str,
) -> tuple[set[str], str]:
    blob = fold(procedure or "")
    anatomy = set()
    mapping = {
        "lip": ["lip", "lips", "buze", "buzesh", "buzësh"],
        "cheek": ["cheek", "malar"],
        "chin": ["chin", "menton"],
        "jaw": ["jaw", "jawline", "mandib"],
        "nose": ["rhinofiller", "nose filler", "nasal filler"],
        "nasolabial": ["nasolabial"],
        "tear_trough": ["tear trough", "under eye", "under-eye"],
        "temple": ["temple", "temporal"],
    }
    for tag, terms in mapping.items():
        if any(fold(term) in blob for term in terms):
            anatomy.add(tag)

    ml = ""
    m = re.search(r"(\d+(?:[.,]\d+)?)\s*ml\b", blob, re.I)
    if m:
        ml = m.group(1).replace(",", ".")

    return anatomy, ml


def official_evidence_matches_requested_procedure(
    evidence: ExtractedEvidence,
    requested_procedure: str,
) -> bool:
    requested_anatomy, requested_ml = requested_procedure_variant_tags(
        requested_procedure
    )
    if not requested_anatomy and not requested_ml:
        return True

    dummy = ClinicPriceResult(
        clinic_name="_",
        city="_",
        procedure_canonical=canonicalize_procedure(requested_procedure),
        procedure_display_name=display_name(
            canonicalize_procedure(requested_procedure)
        ),
        procedure_detail=procedure_detail(
            evidence.raw_evidence,
            requested_procedure,
        ),
        price_min=evidence.price_min,
        price_max=evidence.price_max,
        currency=evidence.currency,
        qualifier=evidence.qualifier,
        unit=evidence.unit,
        source_url=evidence.source_url,
        source_host=host_of(evidence.source_url),
        source_type="official_clinic",
        evidence_type="official_treatment_page",
        clinic_own_price=True,
        city_match=True,
        identity_verified=True,
        confidence=0.9,
        raw_procedure_text=evidence.raw_procedure_text,
        raw_evidence=evidence.raw_evidence,
    )
    evidence_anatomy, evidence_ml = marketplace_variant_tags(dummy)

    if requested_anatomy:
        if not evidence_anatomy:
            return False
        if not (requested_anatomy & evidence_anatomy):
            return False

    if requested_ml:
        if not evidence_ml or requested_ml != evidence_ml:
            return False

    return True


async def crawl_official_site_once_for_marketplace_clinic(
    official_hit: SearchHit,
    requested_procedure: str,
    city: str,
    language: str,
    country_code: str,
    serper: SerperClient,
    interactive_fast: bool = False,
) -> tuple[
    bool,
    list[tuple[ExtractedEvidence, str, float]],
]:
    """Crawl one official clinic site once for the requested procedure.

    All marketplace variants for that clinic reuse this same crawl result.
    """
    canonical = canonicalize_procedure(requested_procedure)
    root = official_site_root(official_hit.url) or official_hit.url
    homepage = await fetch_html(root)
    if not homepage:
        return False, []

    internal_limit = int(
        os.getenv(
            "MAX_HYBRID_MARKETPLACE_OFFICIAL_INTERNAL_LINKS"
            if interactive_fast
            else "MAX_MARKETPLACE_OFFICIAL_INTERNAL_LINKS",
            "5" if interactive_fast else "8",
        )
    )
    sitemap_limit = int(
        os.getenv(
            "MAX_HYBRID_MARKETPLACE_OFFICIAL_SITEMAP_LINKS"
            if interactive_fast
            else "MAX_MARKETPLACE_OFFICIAL_SITEMAP_LINKS",
            "4" if interactive_fast else "6",
        )
    )
    max_pages = int(
        os.getenv(
            "MAX_HYBRID_MARKETPLACE_OFFICIAL_PAGES_PER_CLINIC"
            if interactive_fast
            else "MAX_MARKETPLACE_OFFICIAL_PAGES_PER_CLINIC",
            "6" if interactive_fast else "10",
        )
    )

    candidate_urls = [root]
    candidate_urls.extend(
        official_site_candidate_links(
            root,
            homepage,
            canonical,
            language,
            limit=internal_limit,
        )
    )

    try:
        candidate_urls.extend(
            await official_site_sitemap_candidate_links(
                root,
                canonical,
                language,
                limit=sitemap_limit,
            )
        )
    except Exception:
        pass

    # Only one domain search per clinic, not one per marketplace variant.
    if env_bool("ENABLE_MARKETPLACE_OFFICIAL_SITE_SEARCH", True):
        _lang, price_words = search_profile(country_code, city)
        price_word = price_words[0] if price_words else "price"
        query_term = requested_procedure.strip() or display_name(canonical)

        try:
            site_hits = await serper.search(
                f'site:{host_of(root)} "{query_term}" {price_word}',
                5,
                page=1,
            )
            for hit in site_hits:
                if (
                    hit.url
                    and host_of(hit.url) == host_of(root)
                    and classify_source(hit.url) == "official_clinic"
                ):
                    candidate_urls.append(hit.url)
        except Exception:
            pass

    deduped = []
    seen = set()
    for url in candidate_urls:
        url = (url or "").split("#")[0]
        if not url or host_of(url) != host_of(root) or url in seen:
            continue
        seen.add(url)
        deduped.append(url)

    deduped = deduped[:max_pages]

    pages = await asyncio.gather(
        *(fetch_html(url) for url in deduped),
        return_exceptions=True,
    )

    procedure_confirmed = False
    price_candidates = []

    for url, html in zip(deduped, pages):
        if isinstance(html, Exception) or not html:
            continue

        text = page_text(html)
        if has_procedure(text, canonical):
            procedure_confirmed = True

        evidence_rows = extract_price_evidence(
            html,
            url,
            canonical,
        )

        for evidence in evidence_rows:
            if procedure_negated(evidence.raw_evidence, canonical):
                continue
            if ambiguous_multi_price_block(
                evidence.raw_evidence,
                canonical,
            ):
                continue

            accepted, own, confidence, _reason, evidence_type = (
                validate_evidence(
                    evidence,
                    text,
                    html,
                )
            )
            if not accepted or not own:
                continue

            if not official_evidence_matches_requested_procedure(
                evidence,
                requested_procedure,
            ):
                continue

            quality = {
                "official_price_menu": 6.0,
                "official_treatment_page": 5.0,
                "official_article": 2.0,
                "official_page": 1.0,
            }.get(evidence_type, 0.0)

            price_candidates.append(
                (
                    evidence,
                    evidence_type,
                    quality + confidence,
                )
            )

    price_candidates.sort(key=lambda x: x[2], reverse=True)
    return procedure_confirmed, price_candidates



def marketplace_verification_variant_key(
    row: ClinicPriceResult,
) -> tuple:
    anatomy, ml = marketplace_variant_tags(row)
    return (
        tuple(sorted(anatomy)),
        ml,
        fold(row.product_brand or ""),
        fold(row.product_line or ""),
        fold(row.unit or ""),
        round(float(row.price_min or 0), 2),
        round(float(row.price_max or 0), 2),
        row.currency,
        row.marketplace_price_capture,
    )



async def enrich_marketplace_rows_with_official_sites(
    rows: list[ClinicPriceResult],
    directory_hits: list[SearchHit],
    req: DiscoverRequest,
    language: str,
    country_code: str,
    serper: SerperClient,
) -> tuple[list[ClinicPriceResult], dict[str, int]]:
    stats = {
        "checks": 0,
        "variant_checks": 0,
        "site_crawls": 0,
        "sites_matched": 0,
        "sites_from_directory": 0,
        "weak_directory_skipped": 0,
        "directory_superseded": 0,
        "sites_from_search": 0,
        "sites_from_linked_discovery_page": 0,
        "sites_from_profile_link": 0,
        "sites_from_domain_probe": 0,
        "sites_from_brand_identity_probe": 0,
        "domain_probe_attempts": 0,
        "domain_probe_matches": 0,
        "domain_probe_rejected_no_procedure": 0,
        "resolution_search_queries": 0,
        "sites_cached": 0,
        "procedure_confirmed": 0,
        "prices_found": 0,
        "prices_overridden": 0,
        "official_no_price": 0,
        "official_unresolved": 0,
        "snippet_rejected": 0,
    }

    if not env_bool("ENABLE_MARKETPLACE_OFFICIAL_VERIFICATION", True):
        return rows, stats

    grouped: dict[str, list[tuple[int, ClinicPriceResult]]] = {}
    for idx, row in enumerate(rows):
        if row.source_type != "marketplace":
            continue
        key = _clinic_compare_key(row.clinic_name)
        if not key:
            continue
        grouped.setdefault(key, []).append((idx, row))

    max_checks = int(os.getenv("MAX_MARKETPLACE_OFFICIAL_CHECKS", "8"))
    groups = list(grouped.values())[:max_checks]

    replacements: dict[int, ClinicPriceResult | None] = {}
    semaphore = asyncio.Semaphore(
        max(
            1,
            int(
                os.getenv(
                    "MARKETPLACE_OFFICIAL_VERIFY_CONCURRENCY",
                    "3",
                )
            ),
        )
    )

    async def verify_group(items):
        # Prefer a real marketplace profile page over a snippet row.
        representative = next(
            (
                row for _idx, row in items
                if row.marketplace_price_capture == "profile_page"
            ),
            items[0][1],
        )

        async with semaphore:
            (
                official_hit,
                source,
                probe_attempts,
                weak_directory_skipped,
                directory_superseded_count,
                probe_rejected_no_procedure,
                resolution_search_queries,
            ) = await resolve_marketplace_official_site(
                representative.clinic_name,
                req.city,
                req.procedure,
                directory_hits,
                serper,
                marketplace_url=representative.source_url,
                country_code=country_code,
                language=language,
            )

            if not official_hit:
                return (
                    items,
                    None,
                    source,
                    False,
                    [],
                    probe_attempts,
                    weak_directory_skipped,
                    directory_superseded_count,
                    probe_rejected_no_procedure,
                    resolution_search_queries,
                )

            procedure_confirmed, official_prices = (
                await crawl_official_site_once_for_marketplace_clinic(
                    official_hit,
                    req.procedure,
                    req.city,
                    language,
                    country_code,
                    serper,
                    interactive_fast=req.interactive_fast,
                )
            )

            return (
                items,
                official_hit,
                source,
                procedure_confirmed,
                official_prices,
                probe_attempts,
                weak_directory_skipped,
                directory_superseded_count,
                probe_rejected_no_procedure,
                resolution_search_queries,
            )

    verified = await asyncio.gather(
        *(verify_group(items) for items in groups),
        return_exceptions=True,
    )

    official_hits_to_cache: dict[str, SearchHit] = {}

    for item in verified:
        if isinstance(item, Exception):
            continue

        (
            items,
            official_hit,
            source,
            procedure_confirmed,
            official_prices,
            probe_attempts,
            weak_directory_skipped,
            directory_superseded_count,
            probe_rejected_no_procedure,
            resolution_search_queries,
        ) = item

        stats["checks"] += 1
        stats["domain_probe_attempts"] += probe_attempts
        stats["domain_probe_rejected_no_procedure"] += int(
            probe_rejected_no_procedure or 0
        )
        stats["resolution_search_queries"] += int(
            resolution_search_queries or 0
        )
        if weak_directory_skipped:
            stats["weak_directory_skipped"] += 1
        stats["directory_superseded"] += int(
            directory_superseded_count or 0
        )

        # Count local variants for diagnostics only; they no longer trigger
        # separate network crawls.
        stats["variant_checks"] += len(
            {
                marketplace_verification_variant_key(row)
                for _idx, row in items
            }
        )

        if official_hit:
            stats["site_crawls"] += 1
            stats["sites_matched"] += 1

            h = host_of(official_hit.url)
            if h:
                official_hits_to_cache[h] = official_hit
            if source == "directory":
                stats["sites_from_directory"] += 1
            elif source == "search":
                stats["sites_from_search"] += 1
            elif source == "linked_discovery_page":
                stats["sites_from_linked_discovery_page"] += 1
            elif source == "marketplace_link":
                stats["sites_from_profile_link"] += 1
            elif source == "domain_probe":
                stats["sites_from_domain_probe"] += 1
                stats["domain_probe_matches"] += 1
            elif source == "brand_identity_probe":
                stats["sites_from_brand_identity_probe"] += 1
        else:
            stats["official_unresolved"] += 1

        if procedure_confirmed:
            stats["procedure_confirmed"] += 1
        if official_prices:
            stats["prices_found"] += 1
        elif official_hit:
            stats["official_no_price"] += 1

        for idx, row in items:
            upgraded = apply_official_marketplace_verification(
                row,
                official_hit,
                procedure_confirmed,
                official_prices,
            )

            if upgraded is None:
                stats["snippet_rejected"] += 1
                replacements[idx] = None
                continue

            if upgraded.official_price_override:
                stats["prices_overridden"] += 1

            replacements[idx] = upgraded

    if official_hits_to_cache:
        try:
            stats["sites_cached"] = await firestore_upsert_clinic_directory(
                req.city,
                country_code,
                list(official_hits_to_cache.values()),
            )
        except Exception:
            stats["sites_cached"] = 0

    out = []
    for idx, row in enumerate(rows):
        if idx in replacements:
            upgraded = replacements[idx]
            if upgraded is not None:
                out.append(upgraded)
            continue

        if (
            row.source_type == "marketplace"
            and row.marketplace_price_capture == "search_snippet"
        ):
            stats["snippet_rejected"] += 1
            continue

        out.append(row)

    return out, stats



def build_serp_directory_candidates(
    hits: list[SearchHit],
    city: str,
    procedure: str,
    existing_hosts: set[str],
    limit: int = 30,
) -> list[SearchHit]:
    """Promote clinic-like organic search hosts into the identity verifier.

    This is a discovery-only rescue lane. A SERP hit cannot become a trusted
    clinic just because it ranks in search. The host must still pass the same
    official-site / locality / clinic-quality verifier used by Places.
    """
    canonical = canonicalize_procedure(procedure)
    scored = []
    seen = set()

    for hit in hits:
        url = str(hit.url or "").strip()
        if not url or classify_source(url) != "official_clinic":
            continue
        if bad_host(url):
            continue

        root = official_site_root(url) or url
        host = host_of(root)
        if not host or host in existing_hosts or host in seen:
            continue

        blob = f"{hit.title} {hit.snippet} {hit.url}"
        proc_match = has_procedure(blob, canonical)
        city_match = city_in_text(blob, city)

        # At least one discovery signal is required. The website verifier will
        # independently establish local clinic identity from fetched pages.
        if not (proc_match or city_match):
            continue

        seen.add(host)
        scored.append(
            (
                0 if (proc_match and city_match) else 1,
                0 if proc_match else 1,
                0 if city_match else 1,
                SearchHit(
                    title=hit.title,
                    url=root,
                    snippet=hit.snippet,
                    query="serp_clinic_directory",
                    directory_verification_source="serp_clinic_directory",
                ),
            )
        )

    scored.sort(key=lambda x: x[:3])
    return [x[3] for x in scored[: max(1, int(limit))]]


async def seed_directory_from_serp(
    city: str,
    country_code: str,
    procedure: str,
    raw_hits: list[SearchHit],
    directory_hits: list[SearchHit],
    limit: int = 30,
) -> tuple[list[SearchHit], dict]:
    existing_hosts = {
        host_of(x.url)
        for x in directory_hits
        if host_of(x.url)
    }

    candidates = build_serp_directory_candidates(
        raw_hits,
        city,
        procedure,
        existing_hosts,
        limit=limit,
    )

    if not candidates:
        return directory_hits, {
            "candidates": 0,
            "candidate_hosts": [],
            "verified": 0,
            "added": 0,
            "linked_official_resolved": 0,
            "linked_official_hosts": [],
            "rejected": [],
        }

    # First resolve each organic result as a possible discovery/listing page.
    # Example: a local guide can rank for a clinic name while linking to the
    # real clinic-owned website. We follow that external Website link and then
    # verify the destination; the guide itself never becomes the official site.
    resolved_verified: list[SearchHit] = []
    fallback_candidates: list[SearchHit] = []
    linked_official_hosts: list[str] = []
    linked_unresolved: list[str] = []

    resolve_batches = await asyncio.gather(
        *(
            resolve_discovery_hit_to_official(
                candidate,
                normalize_directory_clinic_name(
                    candidate.title,
                    candidate.url,
                ),
                city,
            )
            for candidate in candidates
        ),
        return_exceptions=True,
    )

    for candidate, resolved in zip(candidates, resolve_batches):
        if isinstance(resolved, Exception):
            fallback_candidates.append(candidate)
            continue

        verified_site, followed_external = resolved

        if verified_site is not None:
            if followed_external:
                linked_host = host_of(verified_site.url)
                if linked_host and linked_host not in linked_official_hosts:
                    linked_official_hosts.append(linked_host)
                # Preserve the strong provenance assigned by
                # resolve_discovery_hit_to_official.
                verified_site.query = "serp_linked_official"
            else:
                verified_site.directory_verification_source = (
                    "serp_clinic_directory"
                )
                verified_site.query = "serp_clinic_directory"

            resolved_verified.append(verified_site)
            continue

        if followed_external:
            linked_unresolved.append(
                f"{candidate.title} -> external website not verified"
            )
        else:
            fallback_candidates.append(candidate)

    # Keep the old verifier as a fallback for organic hits that were not
    # discovery pages and could not be resolved by the stronger path above.
    fallback_verified: list[SearchHit] = []
    verify_stats = {"rejected_clinics": []}

    if fallback_candidates:
        fallback_verified, verify_stats = (
            await verify_places_clinic_websites(
                city,
                fallback_candidates,
            )
        )
        fallback_verified = [
            row.model_copy(
                update={
                    "directory_verification_source": (
                        "serp_clinic_directory"
                    ),
                    "query": "serp_clinic_directory",
                }
            )
            for row in fallback_verified
        ]

    by_verified_host: dict[str, SearchHit] = {}
    for row in resolved_verified + fallback_verified:
        h = host_of(row.url)
        if h:
            by_verified_host[h] = row
    verified = list(by_verified_host.values())

    new_rows = [
        row
        for row in verified
        if host_of(row.url) not in existing_hosts
    ]

    if verified:
        await firestore_upsert_clinic_directory(
            city,
            country_code,
            verified,
        )

    merged = {
        host_of(x.url): x
        for x in directory_hits
        if host_of(x.url)
    }
    for row in verified:
        merged[host_of(row.url)] = row

    final = list(merged.values())
    _directory_memory_put(city, final)

    rejected = [
        str(x)[:220]
        for x in verify_stats.get("rejected_clinics", [])[:40]
    ]
    rejected.extend(
        str(x)[:220]
        for x in linked_unresolved[:20]
    )

    return final, {
        "candidates": len(candidates),
        "candidate_hosts": [
            host_of(x.url)
            for x in candidates
            if host_of(x.url)
        ],
        "verified": len(verified),
        "added": len(new_rows),
        "linked_official_resolved": len(linked_official_hosts),
        "linked_official_hosts": linked_official_hosts[:40],
        "rejected": rejected,
    }



async def discover(req: DiscoverRequest) -> DiscoverResponse:
    diag = DiscoveryDiagnostics(search_mode=req.search_mode)
    diag.firestore_clinics_known_before_search = len(req.known_clinic_names)
    skipped_existing_urls: set[str] = set()

    def keep_new_provider(hit: SearchHit) -> bool:
        if req.progressive_stage and vertical_search.REJECTIONS.get((fold(req.city), req.procedure, hit.url)):
            diag.negative_cache_hits += 1
            return False
        if hit.url in req.previously_fetched_urls or bad_host(hit.url):
            return False
        if foreign_price_source_path(hit.url, req.city):
            return False
        source = classify_source(hit.url)
        blob = f"{hit.title} {hit.snippet} {hit.url}"
        # Off-city directory pages cannot provide a local clinic identity.
        # Reject them before any HTML or Places request consumes the budget.
        if source in {"directory", "marketplace", "social"} and not city_in_text(blob, req.city):
            return False
        if is_retail_product_page(hit.url, blob, req.procedure):
            return False
        if already_stored_clinic_hit(hit, req):
            skipped_existing_urls.add(hit.url)
            diag.existing_clinic_urls_skipped = len(skipped_existing_urls)
            return False
        return True

    economical_cap = (
        req.serper_request_cap
        or (
            int(
                os.getenv(
                    "MAX_ECONOMICAL_SERPER_NETWORK_REQUESTS",
                    "12",
                )
            )
            if req.economical_growth
            else 0
        )
    )
    serper = SerperClient(
        enabled=req.enable_serper,
        request_cap=economical_cap,
    )
    if req.progressive_stage:
        serper.brave_enabled = False
        serper.brightdata_enabled = False
    places = GooglePlacesClient()

    country_code = (req.country_code or country_hint_for_city(req.city) or "").upper()
    if not country_code and places.configured:
        country_code = await vertical_search.resolve_country(sys.modules[__name__], req.city)

    primary_language, _price_words = search_profile(country_code, req.city)
    serper.country_code = country_code
    serper.language = primary_language
    diag.search_country_code = country_code
    diag.search_language = primary_language
    queries = build_queries(
        req.city,
        req.procedure,
        country_code,
        req.search_mode,
        req.interactive_fast,
        req.full_growth,
        req.economical_growth,
        req.app_fast_queries,
    )
    if req.query_override is not None:
        queries = req.query_override
    if req.progressive_stage == "primary":
        serper.language = "en"
    if req.search_mode == "site_focus" and req.priority_site_hosts:
        # Round 0 fetches /preturi/{city}/ directly. Do not Serper
        # `site:host`, which ranked Cronosmed /preturi/bacau/ for Timișoara.
        queries = []
    if not req.progressive_stage and req.hybrid_interactive and req.known_clinic_hosts and req.search_mode in {"expanded", "rescue", "deep"}:
        # Exclude already-priced providers from broad discovery queries.
        # Keep marketplace and targeted site queries intact.
        excluded_hosts = [h for h in req.known_clinic_hosts if re.fullmatch(r"[a-z0-9.-]+", h)][:8]
        exclude = " ".join(f"-site:{h}" for h in excluded_hosts)
        if exclude:
            # Keep the first simple procedure/city/price search identical to
            # an ordinary Google query. Skip saved providers after retrieval.
            queries = [f"{q} {exclude}" if index > 0 and not q.startswith("site:") else q
                       for index, q in enumerate(queries)]
    if not req.enable_serper:
        queries = []
    diag.serp_queries = len(queries)

    errors = []
    hits = []
    explicit_hosts = set()
    for url in req.priority_site_urls:
        if (urlparse(url).scheme not in {"http", "https"} or bad_host(url)
                or url in req.previously_fetched_urls
                or classify_source(url) != "official_clinic"
                or foreign_price_source_path(url, req.city)):
            continue
        hits.append(SearchHit(title=domain_brand(url), url=url,
                              snippet="", query="adaptive_site_search"))
        explicit_hosts.add(host_of(url))
    for tariff_url in known_host_tariff_urls(
        req.priority_site_hosts, req.city, req.procedure, country_code,
    ):
        if (tariff_url in req.previously_fetched_urls or bad_host(tariff_url)
                or host_of(tariff_url) in explicit_hosts):
            continue
        if foreign_price_source_path(tariff_url, req.city):
            continue
        hits.append(SearchHit(
            title=domain_brand(tariff_url) or host_of(tariff_url),
            url=tariff_url,
            snippet="",
            query="known_host_tariff",
        ))

    if req.economical_growth:
        max_per_query = int(
            os.getenv(
                "MAX_ECONOMICAL_SERP_RESULTS_PER_QUERY",
                "20" if req.hybrid_interactive else "10",
            )
        )
    elif req.full_growth:
        max_per_query = int(
            os.getenv(
                "MAX_FULL_GROWTH_SERP_RESULTS_PER_QUERY",
                "20",
            )
        )
    else:
        max_per_query = int(
            os.getenv(
                "MAX_HYBRID_SERP_RESULTS_PER_QUERY"
                if req.interactive_fast
                else "MAX_SERP_RESULTS_PER_QUERY",
                "8" if req.interactive_fast else "10",
            )
        )

    max_per_query = max(1, min(max_per_query, 20))
    diag.serp_results_per_query = max_per_query

    serp_page = 2 if req.search_mode == "deep" else 1

    await _emit_hybrid_status(
        phase="searching", round=req.search_mode, queries=queries,
        search_country_code=country_code, search_language=primary_language,
        source_lanes=["official_web", "provider_platforms"],
    )

    search_batches = await asyncio.gather(
        *(
            serper.search(
                q,
                max_per_query,
                page=serp_page,
                refresh_cache=(not req.progressive_stage and req.hybrid_interactive and req.full_growth
                               and req.search_mode == "expanded" and index < 2),
            )
            for index, q in enumerate(queries)
        ),
        return_exceptions=True,
    )

    for q, rows in zip(queries, search_batches):
        if isinstance(rows, Exception):
            errors.append(f"{q}: {rows}"[:500])
            continue

        diag.serp_hits_total += len(rows)
        hits.extend(rows)

    # Explicit full-growth also inspects page 2 for a small set of broad
    # discovery queries. Search remains discovery-only: snippets never become
    # trusted prices.
    if (
        req.enable_serper and not req.progressive_stage
        and req.full_growth
        and req.search_mode in {"standard", "expanded"}
        and queries
    ):
        page2_default = "2" if req.economical_growth else "8"
        page2_env = (
            "MAX_ECONOMICAL_PAGE2_QUERIES"
            if req.economical_growth
            else "MAX_FULL_GROWTH_PAGE2_QUERIES"
        )
        page2_limit = max(
            1,
            min(
                int(os.getenv(page2_env, page2_default)),
                len(queries),
            ),
        )
        page2_queries = queries[:page2_limit]
        page2_batches = await asyncio.gather(
            *(
                serper.search(
                    q,
                    int(
                        os.getenv(
                            "MAX_FULL_GROWTH_PAGE2_RESULTS",
                            str(max_per_query),
                        )
                    ),
                    page=2,
                )
                for q in page2_queries
            ),
            return_exceptions=True,
        )
        diag.serp_page2_queries = len(page2_queries)
        page2_hosts = []
        for q, rows in zip(page2_queries, page2_batches):
            if isinstance(rows, Exception):
                errors.append(f"{q} [page2]: {rows}"[:500])
                continue
            diag.serp_page2_hits_total += len(rows)
            diag.serp_hits_total += len(rows)
            hits.extend(rows)
            for h in rows:
                host = host_of(h.url)
                if host and host not in page2_hosts:
                    page2_hosts.append(host)
        diag.serp_page2_candidate_hosts = page2_hosts[:60]

    # Firestore identities were passed in before these paid searches. Broad
    # Serper queries can still return an existing provider, but its page must
    # not consume a fetch slot or enter the clinic-directory seed.
    hits = [hit for hit in hits if keep_new_provider(hit)]

    # Reuse a city-level clinic directory across ALL procedures. Cached
    # clinic websites cost zero Places calls. Only the first expanded search
    # for a new city may bootstrap Places, with a small city-wide query budget.
    directory_hits = await firestore_load_clinic_directory(req.city)
    diag.clinic_directory_cached = len(directory_hits)

    bootstrap_stats = None
    if (
        req.search_mode == "expanded"
        and not req.skip_places_bootstrap
        and (
            req.refresh_places
            or not directory_hits
        )
        and places.configured
        and env_bool("ENABLE_PLACES_CITY_BOOTSTRAP", True)
    ):
        directory_hits, bootstrap_stats = await bootstrap_city_clinic_directory(
            req.city,
            country_code,
            primary_language,
            procedure=req.procedure if req.refresh_places else "",
            force=req.refresh_places,
            max_queries=int(
                os.getenv(
                    "GOOGLE_PLACES_FULL_GROWTH_QUERY_BUDGET"
                    if req.refresh_places
                    else "GOOGLE_PLACES_CITY_QUERY_BUDGET",
                    (
                        "4"
                        if req.economical_growth and req.refresh_places
                        else "8"
                        if req.refresh_places
                        else "2"
                    ),
                )
            ),
        )

    if bootstrap_stats:
        diag.places_discovery_queries = bootstrap_stats["requests_attempted"]
        diag.places_candidate_websites = bootstrap_stats["places_candidates"]
        diag.places_query_texts = list(
            bootstrap_stats.get("query_texts", [])
        )
        diag.places_candidate_names = list(
            bootstrap_stats.get("candidate_names", [])
        )
        diag.places_candidate_hosts = list(
            bootstrap_stats.get("candidate_hosts", [])
        )
        category_terms = [
            fold(x)
            for x in provider_categories_for_procedure(req.procedure)
        ]
        diag.places_provider_category_queries = sum(
            1
            for q in bootstrap_stats.get("query_texts", [])
            if any(term in fold(q) for term in category_terms)
        )
        diag.places_results_total = 0
        diag.places_results_with_website = bootstrap_stats["places_candidates"]
        diag.places_api_status = bootstrap_stats["status"]
        diag.places_api_error = bootstrap_stats["error"]
        diag.places_requests_attempted = bootstrap_stats["requests_attempted"]
        diag.places_requests_succeeded = bootstrap_stats["requests_succeeded"]
        diag.places_quota_blocked = bootstrap_stats["quota_blocked"]
        diag.clinic_directory_bootstrap_added = bootstrap_stats["added"]
        diag.clinic_directory_deactivated = bootstrap_stats.get("deactivated",0)
        diag.clinic_directory_rejected_irrelevant = bootstrap_stats.get("rejected_irrelevant",0)
        diag.clinic_directory_rejected_retail = bootstrap_stats.get("rejected_retail",0)
        diag.clinic_directory_rejected_agency = bootstrap_stats.get(
            "rejected_agency",
            0,
        )
        diag.places_rejected_clinics = [
            str(x)[:220]
            for x in bootstrap_stats.get("rejected_clinics", [])[:40]
        ]

    directory_hits = [hit for hit in directory_hits if keep_new_provider(hit)]

    # Organic-search identity rescue. We run this only in the explicit
    # expanded full-growth round, after Places, so it can discover clinic
    # domains that Google Places does not return for the procedure.
    if (
        req.full_growth
        and req.search_mode == "expanded"
        and not req.hybrid_interactive
        and env_bool("ENABLE_SERP_CLINIC_DIRECTORY_SEED", True)
    ):
        serp_seed_limit = int(
            os.getenv(
                "MAX_SERP_CLINIC_DIRECTORY_CANDIDATES",
                "20" if req.economical_growth else "70",
            )
        )
        if req.hybrid_interactive:
            serp_seed_limit = min(serp_seed_limit, 4)
        directory_hits, serp_seed_stats = await seed_directory_from_serp(
            req.city,
            country_code,
            req.procedure,
            hits,
            directory_hits,
            limit=serp_seed_limit,
        )
        diag.serp_directory_candidates = serp_seed_stats["candidates"]
        diag.serp_directory_candidate_hosts = list(
            serp_seed_stats["candidate_hosts"]
        )
        diag.serp_directory_verified = serp_seed_stats["verified"]
        diag.serp_directory_added = serp_seed_stats["added"]
        diag.serp_directory_linked_official_resolved = (
            serp_seed_stats.get(
                "linked_official_resolved",
                0,
            )
        )
        diag.serp_directory_linked_official_hosts = list(
            serp_seed_stats.get(
                "linked_official_hosts",
                [],
            )
        )
        diag.serp_directory_rejected = list(
            serp_seed_stats["rejected"]
        )

    directory_hits = [hit for hit in directory_hits if keep_new_provider(hit)]

    if req.search_mode == "site_focus":
        navigation_hits = cached_price_navigation_hits(directory_hits, req)
        hits.extend(navigation_hits)
        if req.debug:
            diag.price_navigation_candidate_urls = [h.url for h in navigation_hits]
    if req.search_mode == "site_focus" and req.enable_serper and not req.progressive_stage:
        broad_limit = (0 if len(navigation_hits) >= 2
                       else 2 if navigation_hits else 3)
        broad_queries = indexed_price_discovery_queries(
            req.city, req.procedure, country_code, primary_language,
        )[:min(broad_limit, req.serper_request_cap)]
        diag.indexed_price_discovery_queries = list(broad_queries)
        diag.serp_queries += len(broad_queries)
        verified_directory_hosts = {
            host_of(row.url) for row in directory_hits if row.directory_verified
        }
        indexed_hosts = {host_of(hit.url) for hit in navigation_hits}
        before_broad_cache_hits = serper.cache_hits
        broad_batches = await asyncio.gather(
            *(serper.search(q, max_per_query, page=1) for q in broad_queries),
            return_exceptions=True,
        )
        # Replaying the same 14-day Serper cache cannot reveal a new clinic.
        # Try at most two previously unseen generic formulations, once each
        # per cache TTL, only when all the regular searches were cache hits.
        # Keep at least two network slots for focused verified-site searches.
        if (req.hybrid_interactive and req.economical_growth and broad_queries
                and serper.cache_hits - before_broad_cache_hits == len(broad_queries)
                and serper.requests_attempted == 0
                and req.serper_request_cap >= 1):
            replay_queries = []
            fresh_queries = []
            # Leave a site: query slot when the cap can cover both. A cap of
            # one or two is still spent on a query that is not already cached.
            # Cached alternates are replayed for free: a later page check can
            # accept a local clinic the previous snippet filter skipped.
            extra_limit = 2 if req.serper_request_cap >= 3 else req.serper_request_cap
            for q in alternate_indexed_price_queries(
                req.city, req.procedure, country_code,
            ):
                if q in broad_queries:
                    continue
                if await serp_cache_get(serper.cache_query(q), max_per_query, 1) is not None:
                    replay_queries.append(q)
                else:
                    fresh_queries.append(q)
            extra_queries = replay_queries + fresh_queries[:extra_limit]
            if extra_queries:
                diag.indexed_price_uncached_queries = fresh_queries[:extra_limit]
                diag.indexed_price_discovery_queries.extend(extra_queries)
                diag.serp_queries += len(extra_queries)
                broad_batches.extend(await asyncio.gather(
                    *(serper.search(q, max_per_query, page=1)
                      for q in extra_queries),
                    return_exceptions=True,
                ))
                broad_queries.extend(extra_queries)
        def consider_index_hit(hit: SearchHit, index_name: str) -> None:
            host = host_of(hit.url)
            if host in indexed_hosts:
                reason = "same_host_already_selected"
            elif news_report_url(hit.url):
                reason = "news_report"
            elif classify_source(hit.url) != "official_clinic":
                reason = "not_official_host"
            elif not site_focus_result_relevant(hit, req.procedure, req.city):
                reason = "procedure_or_tariff_missing"
            elif not keep_new_provider(hit):
                reason = "already_in_firestore"
            elif not any(related_clinic_hosts(host, verified)
                         for verified in verified_directory_hosts) and not city_in_text(
                             f"{hit.title} {hit.snippet}", req.city,
                         ) and not local_official_from_city_query(
                             hit.url, hit.query, req.city, country_code,
                         ):
                reason = "city_unconfirmed_in_index"
            else:
                reason = "selected_for_page_fetch"
            if req.debug and len(diag.indexed_price_serp_samples) < 40:
                diag.indexed_price_serp_samples.append({
                    "url": hit.url[:240],
                    "decision": reason,
                    "index": index_name,
                })
            if reason != "selected_for_page_fetch":
                return
            indexed_hosts.add(host)
            hits.append(hit.model_copy(update={"query": "adaptive_site_search"}))
            diag.indexed_price_candidate_urls.append(hit.url)

        for query, batch in zip(broad_queries, broad_batches):
            if isinstance(batch, Exception):
                errors.append(f"{query}: {batch}"[:500])
                continue
            diag.serp_hits_total += len(batch)
            for hit in sorted(
                batch,
                key=lambda row: -price_page_signal(row, req.procedure),
            ):
                consider_index_hit(hit, "serper")

        # If every Google/Serper formulation came from the existing cache, a
        # replay cannot discover a new provider.  Use an independently indexed
        # Brave query when configured; otherwise spend at most two remaining
        # Serper credits on page 2.  This branch runs only in the final
        # site-focus round, which itself runs only while the 2+2 target is short.
        cache_only = bool(broad_queries and serper.requests_attempted == 0)
        novelty_limit = max(
            0,
            min(2, int(os.getenv("MAX_BRAVE_NOVELTY_REQUESTS", "2"))),
        )
        novelty_queries = alternate_indexed_price_queries(
            req.city, req.procedure, country_code,
        )[:novelty_limit]
        if cache_only and getattr(serper, "brave_enabled", False) and novelty_queries:
            brave_batches = await asyncio.gather(*(
                serper.brave_search(
                    q,
                    count=max_per_query,
                    country_code=country_code,
                    language=primary_language,
                )
                for q in novelty_queries
            ), return_exceptions=True)
            for query, batch in zip(novelty_queries, brave_batches):
                if isinstance(batch, Exception):
                    errors.append(f"{query} [brave]: {batch}"[:500])
                    continue
                for hit in sorted(
                    batch,
                    key=lambda row: -price_page_signal(row, req.procedure),
                ):
                    consider_index_hit(hit, "brave")
        elif cache_only and novelty_queries:
            page2_limit = min(
                len(novelty_queries),
                2,
                max(0, req.serper_request_cap - serper.requests_attempted),
            )
            page2_queries = novelty_queries[:page2_limit]
            page2_batches = await asyncio.gather(*(
                serper.search(q, max_per_query, page=2, refresh_cache=True)
                for q in page2_queries
            ), return_exceptions=True)
            diag.serp_page2_queries += len(page2_queries)
            for query, batch in zip(page2_queries, page2_batches):
                if isinstance(batch, Exception):
                    errors.append(f"{query} [page2]: {batch}"[:500])
                    continue
                diag.serp_page2_hits_total += len(batch)
                diag.serp_hits_total += len(batch)
                for hit in sorted(
                    batch,
                    key=lambda row: -price_page_signal(row, req.procedure),
                ):
                    consider_index_hit(hit, "serper_page2")
        diag.indexed_price_candidate_urls = list(dict.fromkeys(
            diag.indexed_price_candidate_urls
        ))[:40]

        # Broad indexed-price lookups consume a portion of the same per-round
        # request cap. Do not query a clinic's domain again in this round.
        remaining_site_queries = max(0, req.serper_request_cap - serper.requests_attempted)
        site_hosts = adaptive_site_search_hosts(
            [row for row in directory_hits if host_of(row.url) not in indexed_hosts], req,
            max(0, min(remaining_site_queries, int(os.getenv(
                "MAX_ADAPTIVE_SITE_SEARCH_DOMAINS", "3",
            )))),
        )
        site_hosts = [host for host in site_hosts if host not in indexed_hosts]
        language_terms = local_terms_for(req.procedure, primary_language)
        term = language_terms[0] if language_terms else display_name(
            canonicalize_procedure(req.procedure)
        )
        if country_code == "AL" and canonicalize_procedure(req.procedure) == "rhinoplasty":
            term = term[:-1] + "ës" if term.endswith("ë") else term
            # A site's published tariff can live on a procedure microsite
            # (e.g. procedure.brand.example). Google `site:brand.example`
            # does not reliably include those subdomains. A distinctive
            # verified brand can be searched by name, then the returned URL
            # still MUST be on that brand's parent or child domain.
            brand_by_host = {
                host_of(hit.url): (hit.place_name or hit.title or "").strip()
                for hit in directory_hits if hit.directory_verified
            }
            site_queries = []
            for host in site_hosts:
                brand = brand_by_host.get(host, "")
                if (brand and len(brand.split()) <= 2
                        and clinic_identity_similarity(
                            brand, domain_brand(f"https://{host}/")) >= 0.7):
                    site_queries.append(f"{brand} rinoplastica {req.city} prezzo")
                else:
                    site_queries.append(f"site:{host} rinoplastica OR rinoplastika")
        else:
            site_queries = [f"site:{host} {term}" for host in site_hosts]
        diag.adaptive_site_query_hosts = site_hosts
        diag.adaptive_site_query_texts = site_queries if req.debug else []
        diag.adaptive_site_queries = len(site_queries)
        diag.serp_queries += len(site_queries)
        site_batches = await asyncio.gather(
            *(serper.search(q, max_per_query, page=1) for q in site_queries),
            return_exceptions=True,
        )
        verified_site_hits: list[SearchHit] = []
        for host, query, batch in zip(site_hosts, site_queries, site_batches):
            if isinstance(batch, Exception):
                errors.append(f"{query}: {batch}"[:500])
                continue
            diag.serp_hits_total += len(batch)
            for hit in batch:
                if (classify_source(hit.url) != "official_clinic"
                        or not related_clinic_hosts(host_of(hit.url), host)
                        or not site_focus_result_relevant(hit, req.procedure, req.city)):
                    continue
                hits.append(hit.model_copy(update={"query": "adaptive_site_search"}))
                verified_site_hits.append(hit)
                diag.adaptive_site_candidate_urls.append(hit.url)
        diag.adaptive_site_candidate_urls = list(dict.fromkeys(
            diag.adaptive_site_candidate_urls
        ))[:50]
        diag.adaptive_site_urls = len(diag.adaptive_site_candidate_urls)

        # Search indexes may return the main domain while omitting a clinic's
        # procedure subdomain. Probe a few same-parent HTTPS roots only for
        # verified providers whose indexed results have no explicit tariff.
        # No Serper credit is used; probes still consume the bounded HTTP cap.
        max_probes = max(0, int(os.getenv("MAX_ADAPTIVE_SUBDOMAIN_PROBES", "6")))
        max_hosts = max(0, int(os.getenv("MAX_ADAPTIVE_SUBDOMAIN_HOSTS", "3")))
        max_per_host = max(0, int(os.getenv("MAX_ADAPTIVE_SUBDOMAIN_LABELS_PER_HOST", "2")))
        probe_hits: list[SearchHit] = []
        verified_by_host = {
            host_of(row.url): row for row in directory_hits if row.directory_verified
        }
        for host in site_hosts[:max_hosts]:
            if any(is_price_menu_path(row.url) and related_clinic_hosts(
                host_of(row.url), host,
            ) for row in verified_site_hits):
                continue
            provider = verified_by_host.get(host)
            if not provider:
                continue
            probe_hits.extend(procedure_subdomain_candidates(
                provider, req.procedure, verified_site_hits,
                primary_language, limit=max_per_host,
            ))
            if len(probe_hits) >= max_probes:
                break
        seen_probe_urls = {row.url for row in hits} | set(req.previously_fetched_urls)
        probe_hits = [row for row in probe_hits[:max_probes]
                      if row.url not in seen_probe_urls and not bad_host(row.url)]
        diag.procedure_subdomain_probed_urls = [row.url for row in probe_hits]
        probes = await asyncio.gather(
            *(fetch_html(row.url) for row in probe_hits), return_exceptions=True,
        )
        for row, html in zip(probe_hits, probes):
            if isinstance(html, Exception) or not html:
                reason = "unreachable_or_external_redirect"
            else:
                body = page_text(html)[:16000]
                brand_tokens = clinic_identity_tokens(row.place_name or row.title)
                if not city_in_text(body, req.city):
                    reason = "city_missing_on_page"
                elif not has_procedure(body, req.procedure):
                    reason = "procedure_missing_on_page"
                elif brand_tokens and not any(
                    token in fold(body) for token in brand_tokens
                ):
                    reason = "provider_identity_missing_on_page"
                else:
                    reason = "selected_for_price_verification"
                    hits.append(row)
                    diag.procedure_subdomain_candidate_urls.append(row.url)
            if req.debug and len(diag.procedure_subdomain_reject_samples) < 20:
                diag.procedure_subdomain_reject_samples.append({
                    "url": row.url, "decision": reason,
                })

    diag.clinic_directory_used = len(directory_hits)
    diag.clinic_directory_all_names = [
        (h.place_name or h.title or domain_brand(h.url))[:120]
        for h in directory_hits[:50]
    ]
    diag.clinic_directory_all_hosts = [
        host_of(h.url)
        for h in directory_hits[:50]
        if host_of(h.url)
    ]
    diag.clinic_directory_all_capabilities = [
        (
            (h.place_name or h.title or domain_brand(h.url))[:70]
            + ":"
            + ",".join(h.directory_capabilities or [])
        )[:180]
        for h in directory_hits[:50]
    ]
    hits.extend(directory_hits)
    hits = [hit for hit in hits if keep_new_provider(hit)]

    by_url = {}

    for h in hits:
        if not h.url or bad_host(h.url):
            continue
        venue = canonicalize_fresha_venue_url(h.url)
        if venue != h.url:
            h = h.model_copy(update={"url": venue})
        if h.url not in by_url or (h.directory_verified and not by_url[h.url].directory_verified):
            by_url[h.url] = h

    unique = list(by_url.values())
    diag.unique_urls = len(unique)

    # Search engines sometimes ignore the city constraint for marketplace
    # searches (e.g. Tirana returning Fresha Hamilton/Sydney pages).
    filtered_unique = []
    for hit in unique:
        if classify_source(hit.url) == "marketplace":
            if marketplace_url_geo_conflict(hit.url, req.city, country_code):
                diag.rejected_marketplace_url_geo += 1
                continue

            blob = f"{hit.title} {hit.snippet} {hit.url}"
            if not city_in_text(blob, req.city):
                diag.rejected_marketplace_serp_city += 1
                continue

        filtered_unique.append(hit)
    unique = filtered_unique
    if req.search_mode == "site_focus":
        unique = [
            hit for hit in unique
            if hit.query in {"adaptive_site_search", "known_host_tariff"}
            or hit.directory_verified
        ]
    if req.previously_fetched_urls:
        visited = set(req.previously_fetched_urls)
        unique = [hit for hit in unique if hit.url not in visited]

    # Marketplace category pages can still be valuable discovery sources.
    # Expand local Fresha / WhatClinic / Booksy / Treatwell category pages into
    # likely provider profiles, but never use the category page itself as a
    # clinic-price source.
    marketplace_children: list[SearchHit] = []
    marketplace_categories = [
        h for h in unique
        if classify_source(h.url) == "marketplace"
        and not is_probable_single_business_page(h.url)
    ]
    max_category_fetches = int(os.getenv("MAX_MARKETPLACE_CATEGORY_FETCHES", "6"))
    if req.hybrid_interactive:
        max_category_fetches = min(max_category_fetches, 2)
    max_profiles_per_category = int(os.getenv("MAX_MARKETPLACE_PROFILES_PER_CATEGORY", "10"))

    selected_categories = marketplace_categories[:max_category_fetches]
    category_pages = await asyncio.gather(
        *(asyncio.wait_for(fetch_html(hit.url), timeout=4 if req.hybrid_interactive else 18)
          for hit in selected_categories), return_exceptions=True,
    )
    for category_hit, category_html in zip(selected_categories, category_pages):
        if isinstance(category_html, Exception) or not category_html:
            continue
        diag.marketplace_category_pages_expanded += 1
        for profile_url in expand_marketplace_category_links(
            category_hit.url,
            category_html,
            req.city,
            limit=max_profiles_per_category,
        ):
            if marketplace_url_geo_conflict(profile_url, req.city, country_code):
                diag.rejected_marketplace_url_geo += 1
                continue

            marketplace_children.append(
                SearchHit(
                    title="",
                    url=profile_url,
                    snippet="",
                    query=category_hit.query,
                )
            )

    if marketplace_children:
        existing_urls = {h.url for h in unique}
        for child in marketplace_children:
            if child.url not in existing_urls and keep_new_provider(child):
                existing_urls.add(child.url)
                unique.append(child)
                diag.marketplace_profile_urls += 1

    def rank(hit: SearchHit):
        src = classify_source(hit.url)
        blob = f"{hit.title} {hit.snippet} {hit.url}"

        foreign = foreign_city_conflict(blob, req.city)
        foreign_penalty = 1 if foreign else 0

        direct = 0 if src in {"official_clinic", "marketplace"} else 1
        proc = 0 if has_procedure(blob, req.procedure) else 1
        retail = 1 if is_retail_product_page(hit.url, blob, req.procedure) else 0

        # Places reviews/rating affect crawl order only. They do NOT make a
        # price valid. A clinic still needs accepted page-level price evidence.
        directory_priority = 0 if hit.directory_verified else 1
        requested_canonical = canonicalize_procedure(req.procedure)
        if not hit.directory_verified:
            capability_priority = 1
        elif requested_canonical in (hit.directory_capabilities or []):
            capability_priority = 0
        elif hit.directory_capabilities:
            capability_priority = 2
        else:
            capability_priority = 1

        places_priority = 0 if hit.place_id else 1
        reviews = -(hit.place_user_rating_count or 0)
        rating = -(hit.place_rating or 0)

        return (
            retail,
            foreign_penalty,
            capability_priority,
            directory_priority,
            places_priority,
            direct,
            proc,
            reviews,
            rating,
        )

    work, lane_counts = select_discovery_work(unique, req, rank)
    diag.selected_official_candidate_urls = [
        h.url for h in select_internal_links_fairly(
            [h for h in unique if classify_source(h.url) == "official_clinic"],
            req.procedure, 40,
        )
    ]
    diag.selected_marketplace_profiles = lane_counts["marketplace"]
    diag.selected_marketplace_urls = [
        h.url for h in work if classify_source(h.url) == "marketplace"
    ][:20]
    diag.selected_price_like_official = lane_counts["price_like"]
    diag.selected_directory_roots = lane_counts["directory"]
    selected_directory_work = [
        h for h in work if h.directory_verified
    ]
    diag.selected_directory_names = [
        (h.place_name or h.title or domain_brand(h.url))[:120]
        for h in selected_directory_work[:30]
    ]
    diag.selected_directory_hosts = [
        host_of(h.url)
        for h in selected_directory_work[:30]
        if host_of(h.url)
    ]
    diag.selected_general_web = lane_counts["general"]
    diag.pages_attempted = len(work)

    rows: list[ClinicPriceResult] = []

    async def accept_processed(item):
        if isinstance(item, Exception):
            errors.append(f"page processing: {item}"[:500])
            return

        status, hit, html, text, payload, detail = item

        if status == "whatclinic_category":
            diag.whatclinic_category_results_rejected += 1
            diag.rejected_marketplace_category += 1
            add_reject(diag, hit.url, "whatclinic_category_page")
            return

        if status == "fetch_failed":
            diag.rejected_fetch_failed += 1
            if detail in {"http_401", "http_403", "http_429"}:
                diag.rejected_http_blocked += 1
            add_reject(diag, hit.url, str(detail or "fetch_failed"))
            return

        if status == "nonmedical_business":
            add_reject(diag, hit.url, "nonmedical_financial_business")
            return

        diag.pages_fetched += 1

        if text and has_procedure(text, req.procedure):
            diag.pages_with_procedure_text += 1

        if status == "retail_product":
            diag.rejected_retail_product += 1
            add_reject(diag, hit.url, "retail_product")
            return

        if status == "foreign_city":
            diag.rejected_foreign_city += 1
            add_reject(diag, hit.url, "foreign_city", str(detail))
            return

        if status == "marketplace_category":
            diag.rejected_marketplace_category += 1
            add_reject(diag, hit.url, "marketplace_category")
            return

        if status == "bad_identity":
            diag.rejected_bad_identity += 1
            add_reject(diag, hit.url, "bad_identity")
            return

        name, evidence = payload

        if not evidence:
            diag.rejected_no_price += 1
            add_reject(diag, hit.url, "no_price_evidence")
            return

        diag.pages_with_price_candidates += 1
        diag.price_candidates_total += len(evidence)

        src = classify_page_source(hit.url, text or "")

        if (
            (hit.directory_verified or hit.place_id)
            and city_in_text(hit.place_address or hit.snippet, req.city)
        ):
            place = PlaceIdentity(
                name=(hit.place_name or hit.title or name).strip(),
                formatted_address=hit.place_address or hit.snippet,
                website=(hit.url if src == "official_clinic" else ""),
                # Rating/review counts are only transient crawl-priority data.
                rating=hit.place_rating if not hit.directory_verified else None,
                user_rating_count=hit.place_user_rating_count if not hit.directory_verified else None,
                place_id=hit.place_id,
                city_match=True,
            )
        else:
            place = (
                await places.resolve_clinic(name, req.city, hit.url)
                if places.configured and env_bool("ENABLE_PLACES_IDENTITY_LOOKUP", False)
                else None
            )

        local_page = await asyncio.to_thread(strong_local_page_evidence,
            html or "",
            text or "",
            req.city,
            hit.url,
        )

        if place:
            city_match = True
            identity_verified = True
            clinic_name = place.name
        else:
            city_match = local_page
            identity_verified = False
            clinic_name = name

        # Places miss no longer kills a strong local official page.
        if (
            places.configured
            and src == "official_clinic"
            and not place
            and not local_page
        ):
            diag.rejected_city += 1
            add_reject(
                diag,
                hit.url,
                "places_miss_no_local_evidence",
                name,
            )
            return

        if (
            places.configured
            and src == "official_clinic"
            and not place
            and local_page
        ):
            diag.places_miss_but_local_page_accepted += 1

        # Marketplace must prove requested city.
        if src == "marketplace" and not (place or local_page):
            diag.rejected_city += 1
            add_reject(
                diag,
                hit.url,
                "marketplace_not_city_verified",
                clinic_name,
            )
            return

        canonical = canonicalize_procedure(req.procedure)

        for e in evidence:
            if "whatclinic.com" in host_of(e.source_url):
                if e.extraction_method == "whatclinic_service_pair":
                    diag.whatclinic_price_blocks_found += 1
                    if not html:
                        diag.whatclinic_snippet_price_candidates += 1

            if not marketplace_price_evidence_is_strong(e, req.procedure):
                diag.whatclinic_weak_marketplace_evidence_rejected += (
                    1 if "whatclinic.com" in host_of(e.source_url) else 0
                )
                add_reject(
                    diag,
                    hit.url,
                    "weak_marketplace_price_binding",
                    e.raw_evidence,
                )
                continue

            if procedure_negated(e.raw_evidence, req.procedure):
                diag.rejected_procedure_negation += 1
                add_reject(
                    diag,
                    hit.url,
                    "procedure_negation",
                    e.raw_evidence,
                )
                continue

            if (
                canonical == "botox"
                and botox_medical_indication(e.raw_evidence)
            ):
                add_reject(
                    diag,
                    hit.url,
                    "botox_medical_indication",
                    e.raw_evidence,
                )
                continue

            if ambiguous_multi_price_block(e.raw_evidence, req.procedure):
                diag.rejected_ambiguous_multi_price += 1
                add_reject(
                    diag,
                    hit.url,
                    "ambiguous_multi_price",
                    e.raw_evidence,
                )
                continue

            accepted, own, confidence, reason, evidence_type = await asyncio.to_thread(
                validate_evidence, e,
                text or "",
                html or "",
                city=req.city,
            )

            if not accepted:
                if reason in {
                    "market_context",
                    "foreign_market_context",
                    "agency_or_directory_context",
                    "third_party_provider_quote",
                }:
                    diag.rejected_market_context += 1

                add_reject(
                    diag,
                    hit.url,
                    reason,
                    e.raw_evidence,
                )
                continue

            if identity_verified:
                confidence += 0.06

            if city_match:
                confidence += 0.05

            if evidence_type == "official_article":
                diag.official_article_rows += 1

            if (
                src == "marketplace"
                and clinic_name
                and fold(clinic_name) not in MARKETPLACE_BRAND_NAMES
            ):
                diag.marketplace_names_cleaned += 1

            rows.append(
                ClinicPriceResult(
                    clinic_name=clinic_name,
                    city=req.city,
                    procedure_canonical=canonical,
                    procedure_display_name=published_procedure_display_name(
                        canonical, e.raw_procedure_text, e.raw_evidence, e.raw_price_text),
                    procedure_detail=procedure_detail(
                        e.raw_evidence,
                        canonical,
                        e.raw_price_text,
                    ),
                    product_brand=detect_product_brand(e.raw_evidence, req.procedure),
                    product_line=detect_product_line(e.raw_evidence, req.procedure),
                    price_min=e.price_min,
                    price_max=e.price_max,
                    currency=e.currency,
                    qualifier=e.qualifier,
                    unit=e.unit,
                    original_price_min=e.original_price_min,
                    original_price_max=e.original_price_max,
                    source_url=e.source_url,
                    source_host=host_of(e.source_url),
                    official_website=(
                        place.website
                        if place and place.website
                        else (
                            official_site_root(e.source_url)
                            if src == "official_clinic"
                            else ""
                        )
                    ),
                    source_type=src,
                    evidence_type=evidence_type,
                    clinic_own_price=own,
                    city_match=city_match,
                    identity_verified=identity_verified,
                    rating=place.rating if place else None,
                    user_rating_count=place.user_rating_count if place else None,
                    confidence=max(0, min(0.99, confidence)),
                    raw_procedure_text=e.raw_procedure_text,
                    raw_evidence=e.raw_evidence,
                    source_location_text=tariff_location_context(html or ""),
                    price_scope=(
                        "implant_excluded"
                        if canonical == "breast_augmentation" and implant_cost_excluded(e.raw_evidence)
                        else ""
                    ),
                    price_verification_status=(
                        "official_price"
                        if src == "official_clinic" and own
                        else "marketplace_pending_official_verification"
                        if src == "marketplace"
                        else ""
                    ),
                    official_procedure_verified=(
                        src == "official_clinic"
                        and has_procedure(
                            f"{e.raw_procedure_text} {e.raw_evidence}",
                            canonical,
                        )
                    ),
                    official_price_found=(
                        src == "official_clinic" and own
                    ),
                    official_price_override=False,
                    marketplace_price_capture=(
                        "search_snippet"
                        if (
                            src == "marketplace"
                            and detail == "whatclinic_serp_price"
                        )
                        else "profile_page"
                        if src == "marketplace"
                        else ""
                    ),
                    marketplace_source_url=(
                        e.source_url if src == "marketplace" else ""
                    ),
                    marketplace_source_host=(
                        host_of(e.source_url)
                        if src == "marketplace"
                        else ""
                    ),
                    marketplace_price_min=(
                        e.price_min if src == "marketplace" else None
                    ),
                    marketplace_price_max=(
                        e.price_max if src == "marketplace" else None
                    ),
                    marketplace_currency=(
                        e.currency if src == "marketplace" else ""
                    ),
                    marketplace_raw_evidence=(
                        e.raw_evidence if src == "marketplace" else ""
                    ),
                )
            )

    async def process(hit: SearchHit):
        src = classify_source(hit.url)

        if (
            src == "marketplace"
            and "whatclinic.com" in host_of(hit.url)
            and is_whatclinic_category_result(
                hit.url, hit.title, hit.snippet, req.city
            )
        ):
            return ("whatclinic_category", hit, None, None, None, None)

        html = await fetch_html(hit.url)

        if not html:
            snippet_evidence = extract_whatclinic_serp_price_evidence(
                hit, req.procedure, req.city
            )
            if snippet_evidence:
                name = marketplace_profile_name("", hit.url, hit.title, req.city)
                if name:
                    text = f"{hit.title} {hit.snippet}".strip()
                    return (
                        "ok",
                        hit,
                        "",
                        text,
                        (name, snippet_evidence),
                        "whatclinic_serp_price",
                    )
            failure = _fetch_state().get("failures", {}).get((hit.url, False), "fetch_failed")
            return ("fetch_failed", hit, None, None, None, failure)

        if hit.directory_verified and is_obvious_financial_site(html):
            return ("nonmedical_business", hit, html, "", None, None)

        memo = _hybrid_parse_memo.get()
        text_key = ("page_text", hit.url, memo.get("__city__", "") if memo is not None else "")
        text = memo.get(text_key) if memo is not None else None
        if text is None:
            # Parsing large price menus must not block /health, job status,
            # or the foreground scheduler on the ASGI event loop.
            text = await asyncio.to_thread(page_text, html)
            if memo is not None:
                memo[text_key] = text

        # Hostname-only classification is intentionally provisional.  Unknown
        # medical-tourism platforms and directories are identified after the
        # page has been fetched, before any price ownership decision.
        src = classify_page_source(hit.url, text)

        if is_hard_retail_url(hit.url, req.procedure):
            return ("retail_product", hit, html, text, None, None)

        foreign = foreign_city_conflict(
            f"{hit.title} {hit.snippet} {text[:5000]}",
            req.city,
        )

        if foreign and not city_in_text(
            f"{hit.title} {hit.snippet} {text[:5000]}",
            req.city,
        ):
            return ("foreign_city", hit, html, text, None, foreign)

        if src == "marketplace" and not is_probable_single_business_page(hit.url):
            return ("marketplace_category", hit, html, text, None, None)

        name = await resolve_clinic_name(html, hit.url, hit.title, req.city)

        if not name:
            return ("bad_identity", hit, html, text, None, None)

        evidence = await asyncio.to_thread(extract_price_evidence, html, hit.url, req.procedure)

        detail = None
        if (
            src == "marketplace"
            and "whatclinic.com" in host_of(hit.url)
            and not evidence
        ):
            evidence = extract_whatclinic_serp_price_evidence(
                hit, req.procedure, req.city
            )
            if evidence:
                detail = "whatclinic_serp_price"

        return ("ok", hit, html, text, (name, evidence), detail)

    published_prices = None
    navigation_seen_urls = {h.url for h in work} | set(req.previously_fetched_urls)
    immediate_processed = []

    async def process_and_publish(hit, follow_navigation=True):
        nonlocal published_prices
        if req.progressive_stage:
            eligible_now = dedupe_live_results([r for r in rows if _app_can_show_row(r)])
            if len(eligible_now) >= req.progressive_stop_count:
                return ("enough_results", hit, None, None, None, None)
        try:
            item = await process(hit)
            await accept_processed(item)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            errors.append(f"page processing failed: {hit.url}: {type(exc).__name__}")
            return exc
        if req.progressive_stage:
            status, rejected_hit, _html, _text, payload, detail = item
            reason = {"foreign_city": "wrong_city", "fetch_failed": "fetch_failed"}.get(status, "")
            if status == "fetch_failed" and detail in {"http_403", "http_429"}:
                reason = "blocked"
            if status == "ok" and payload and not payload[1]:
                reason = "no_price"
            if reason:
                vertical_search.REJECTIONS.put((fold(req.city), req.procedure, rejected_hit.url), reason)
            if len(dedupe_live_results([r for r in rows if _app_can_show_row(r)])) >= req.progressive_stop_count:
                budget = _interactive_fetch_budget.get()
                if budget:
                    async with budget["lock"]:
                        budget["left"] = 0
                follow_navigation = False
        if _hybrid_progress.get() is not None:
            # Official rows have passed the same city, ownership and evidence
            # gates as the final response. Marketplace rows wait for the
            # existing official-site verification below.
            eligible = dedupe_live_results([
                row for row in rows
                if row.source_type == "official_clinic" and _app_can_show_row(row)
            ])
            signature = tuple((row.source_url, row.price_min, row.price_max,
                               row.raw_evidence) for row in eligible)
            if signature and signature != published_prices:
                published_prices = signature
                await _emit_hybrid_partial([
                    _display_from_live(row, "live_search") for row in eligible
                ])
            base = _hybrid_round_progress_base.get() or {}
            await _emit_hybrid_status(
                phase="checking_pages", round=req.progressive_stage or req.search_mode,
                fetched_pages=int(base.get("fetched_pages") or 0) + diag.pages_fetched,
                serper_requests=int(base.get("serper_requests") or 0) + serper.requests_attempted,
                pages_attempted=diag.pages_attempted,
            )
        if req.hybrid_interactive and follow_navigation and not isinstance(item, Exception):
            status, lead, html, text, payload, detail = item
            if (status == "ok" and html and classify_source(lead.url) == "official_clinic"
                    and await asyncio.to_thread(strong_local_page_evidence,
                                                html, text or "", req.city, lead.url)):
                lead_has_eligible_price = any(
                    related_clinic_hosts(row.source_host, host_of(lead.url))
                    and _app_can_show_row(row) for row in rows
                )
                if not lead_has_eligible_price:
                    host = host_of(lead.url)
                    if host not in diag.unpriced_local_provider_hosts:
                        diag.unpriced_local_provider_hosts.append(host)
                links = await asyncio.to_thread(official_site_candidate_links,
                    lead.url, html, req.procedure, primary_language, limit=8)
                links = [url for url in links if url not in navigation_seen_urls
                         and not bad_host(url) and not foreign_price_source_path(url, req.city)]
                # Remember all real links for the continuation; follow one per
                # provider now, while unrelated root pages may still be slow.
                for url in links:
                    if url not in diag.pending_price_navigation_urls:
                        diag.pending_price_navigation_urls.append(url)
                if links and not lead_has_eligible_price:
                    url = links[0]
                    navigation_seen_urls.add(url)
                    diag.pages_attempted += 1
                    if req.debug:
                        diag.price_navigation_candidate_urls.append(url)
                    child = lead.model_copy(update={"url": url, "query": "google_places_sitecrawl"})
                    immediate_processed.append(await process_and_publish(child, follow_navigation=False))
        return item

    processed = await asyncio.gather(
        *(process_and_publish(h) for h in work),
        return_exceptions=True,
    )
    processed.extend(immediate_processed)

    # Phase 1.5: follow same-site price/service links from verified clinic
    # homepages and city-specific official pages discovered in site-focus.
    # The latter are often indexed articles that link to an unindexed tariff.
    places_internal_hits: list[SearchHit] = []
    already_seen_urls = set(navigation_seen_urls)

    for item in processed:
        if isinstance(item, Exception):
            continue

        status, hit, html, text, payload, detail = item

        if (
            status != "ok"
            or not html
            or not (
                hit.place_id or hit.directory_verified
                or await asyncio.to_thread(strong_local_page_evidence, html, text or "", req.city, hit.url)
                or (
                    req.search_mode == "site_focus"
                    and hit.query == "adaptive_site_search"
                    and city_in_text(
                        f"{hit.title} {hit.snippet} {text[:5000]}", req.city,
                    )
                    and has_procedure(
                        f"{hit.title} {hit.snippet} {text[:5000]}", req.procedure,
                    )
                )
            )
            or classify_source(hit.url) != "official_clinic"
        ):
            continue

        for link in await asyncio.to_thread(official_site_candidate_links,
            hit.url,
            html,
            req.procedure,
            primary_language,
            limit=int(
                os.getenv("MAX_PLACES_INTERNAL_LINKS_PER_SITE", "8")
            ),
        ):
            if link in already_seen_urls or bad_host(link):
                continue

            already_seen_urls.add(link)
            if req.debug and len(diag.price_navigation_candidate_urls) < 50:
                diag.price_navigation_candidate_urls.append(link)
            places_internal_hits.append(
                SearchHit(
                    title=hit.title,
                    url=link,
                    snippet=hit.snippet,
                    query="google_places_sitecrawl",
                    place_id=hit.place_id,
                    place_name=hit.place_name or hit.title,
                    place_address=hit.place_address or hit.snippet,
                    place_rating=hit.place_rating,
                    place_user_rating_count=hit.place_user_rating_count,
                    directory_verified=hit.directory_verified,
                    directory_relevance_score=hit.directory_relevance_score,
                    directory_capabilities=hit.directory_capabilities,
                    directory_evidence_pages=hit.directory_evidence_pages,
                )
            )

    # Sitemap fallback: when Serper is unavailable or a clinic hides service
    # pages from homepage navigation, inspect the sitemap for the requested
    # procedure. Limit this to likely providers to keep crawling bounded.
    sitemap_roots = []
    requested_canonical = canonicalize_procedure(req.procedure)
    for item in processed:
        if isinstance(item, Exception):
            continue
        status, hit, html, text, payload, detail = item
        if (
            status == "ok"
            and hit.directory_verified
            and classify_source(hit.url) == "official_clinic"
            and (
                requested_canonical in (hit.directory_capabilities or [])
                or not hit.directory_capabilities
            )
        ):
            sitemap_roots.append(hit)

    sitemap_root_limit = (
        int(os.getenv("MAX_FULL_GROWTH_SITEMAP_ROOTS", "55"))
        if req.full_growth
        else 12
    )
    if req.hybrid_interactive:
        sitemap_root_limit = min(sitemap_root_limit, 2)
        # XML probes previously consumed the last fetch slots before any
        # homepage navigation price links could be fetched. Inspect those
        # links first; use XML only if none were found on visited homepages.
        if places_internal_hits:
            sitemap_root_limit = 0
    if req.search_mode == "site_focus":
        # This round already starts from indexed treatment/price pages and
        # bounded procedure microsites. XML probing on each accepted probe
        # would waste the final HTTP slots and add network latency.
        sitemap_root_limit = 0
    sitemap_selected = sitemap_roots[:sitemap_root_limit]

    sitemap_batches = await asyncio.gather(
        *(
            official_site_sitemap_candidate_links(
                hit.url,
                req.procedure,
                primary_language,
                limit=int(
                    os.getenv(
                        "MAX_FULL_GROWTH_SITEMAP_PRICE_LINKS_PER_SITE"
                        if req.full_growth
                        else "MAX_SITEMAP_PRICE_LINKS_PER_SITE",
                        "2" if req.hybrid_interactive else "6" if req.full_growth else "5",
                    )
                ),
            )
            for hit in sitemap_selected
        ),
        return_exceptions=True,
    )

    for hit, links in zip(sitemap_selected, sitemap_batches):
        if isinstance(links, Exception):
            continue
        for link in links:
            if link in already_seen_urls or bad_host(link):
                continue
            already_seen_urls.add(link)
            places_internal_hits.append(
                SearchHit(
                    title=hit.title,
                    url=link,
                    snippet=hit.snippet,
                    query="official_site_sitemap",
                    place_id=hit.place_id,
                    place_name=hit.place_name or hit.title,
                    place_address=hit.place_address or hit.snippet,
                    place_rating=hit.place_rating,
                    place_user_rating_count=hit.place_user_rating_count,
                    directory_verified=True,
                    directory_capabilities=hit.directory_capabilities,
                )
            )

    internal_link_limit = int(
        os.getenv(
            "MAX_FULL_GROWTH_INTERNAL_LINKS_TOTAL"
            if req.full_growth
            else "MAX_PLACES_INTERNAL_LINKS_TOTAL",
            "120" if req.full_growth else "50",
        )
    )
    if req.hybrid_interactive:
        internal_link_limit = min(internal_link_limit, int(os.getenv(
            "MAX_ADAPTIVE_INTERNAL_PAGES" if req.adaptive_rescue else "MAX_INTERACTIVE_INTERNAL_PAGES",
            "16" if req.adaptive_rescue else "10",
        )))
    places_internal_hits = select_internal_links_fairly(
        places_internal_hits,
        req.procedure,
        internal_link_limit,
    )
    diag.places_internal_links_discovered = len(places_internal_hits)
    diag.clinic_directory_internal_links = sum(1 for h in places_internal_hits if h.directory_verified)
    if req.debug:
        diag.selected_internal_urls = [h.url for h in places_internal_hits[:50]]
        current_budget = _interactive_fetch_budget.get()
        diag.fetch_slots_before_internal = current_budget["left"] if current_budget else None

    if places_internal_hits:
        places_internal_processed = await asyncio.gather(
            *(process_and_publish(h) for h in places_internal_hits),
            return_exceptions=True,
        )
        processed.extend(places_internal_processed)

    # Phase 2: local official clinic pages that discuss the procedure but have
    # no price get a domain-specific follow-up search for the price page.
    followup_domains = []
    seen_followup_domains = set()
    verified_followup_domains = set()

    for item in processed:
        if isinstance(item, Exception):
            continue
        status, hit, html, text, payload, detail = item
        if status != "ok" or not payload:
            continue
        name, evidence = payload
        if evidence:
            continue
        if classify_source(hit.url) != "official_clinic":
            continue
        if not text:
            continue

        # A verified local clinic is allowed one domain-specific procedure
        # lookup even when the homepage itself does not mention the treatment.
        # This catches price pages with generic slugs or weak internal linking.
        local_page_ok = await asyncio.to_thread(strong_local_page_evidence,
            html or "",
            text or "",
            req.city,
            hit.url,
        )

        directory_local_ok = bool(hit.directory_verified)

        places_local_ok = (
            (
                str(hit.query or "").startswith("google_places_city:")
                or hit.place_id
            )
            and (
                city_in_text(hit.snippet or "", req.city)
                or city_in_text(hit.place_address or "", req.city)
                or local_page_ok
            )
        )

        if not (local_page_ok or directory_local_ok or places_local_ok):
            continue

        host = host_of(hit.url)
        if req.adaptive_rescue and any(
            related_clinic_hosts(host, known) for known in req.known_clinic_hosts
        ):
            continue
        if host and host not in seen_followup_domains:
            seen_followup_domains.add(host)
            followup_domains.append(host)
            if hit.directory_verified or hit.place_id:
                verified_followup_domains.add(host)

    fetch_budget = _interactive_fetch_budget.get()
    can_process_followup_pages = (
        not req.progressive_stage and req.search_mode != "site_focus"
        and not (req.search_mode == "rescue" and fetch_budget is not None
                 and fetch_budget["left"] <= 2)
    )
    if followup_domains and not can_process_followup_pages and req.search_mode == "rescue":
        diag.adaptive_followup_page_budget_blocked = True

    if followup_domains and can_process_followup_pages:
        canonical = canonicalize_procedure(req.procedure)
        local_terms = local_terms_for(req.procedure, primary_language)
        brand_terms = brands_for(req.procedure)
        _lang, local_price_words = search_profile(country_code, req.city)

        preferred_terms = []
        if canonical == "filler":
            preferred_terms.append("lip filler")
        else:
            preferred_terms.append(display_name(canonical))
        preferred_terms.extend(local_terms[:2])
        preferred_terms.extend(brand_terms[:2])

        followup_queries = []
        price_word = local_price_words[0] if local_price_words else "price"
        if req.economical_growth:
            max_followups = int(
                os.getenv(
                    "MAX_ADAPTIVE_SITE_FOLLOWUP_QUERIES" if req.adaptive_rescue
                    else "MAX_ECONOMICAL_SITE_FOLLOWUP_QUERIES",
                    "8" if req.adaptive_rescue else "4",
                )
            )
            followup_domain_limit = int(
                os.getenv(
                    "MAX_ADAPTIVE_SITE_FOLLOWUP_DOMAINS" if req.adaptive_rescue
                    else "MAX_ECONOMICAL_SITE_FOLLOWUP_DOMAINS",
                    "8" if req.adaptive_rescue else "4",
                )
            )
        elif req.full_growth:
            max_followups = int(
                os.getenv("MAX_FULL_GROWTH_SITE_FOLLOWUP_QUERIES", "36")
            )
            followup_domain_limit = int(
                os.getenv("MAX_FULL_GROWTH_SITE_FOLLOWUP_DOMAINS", "24")
            )
        else:
            max_followups = int(
                os.getenv(
                    "MAX_HYBRID_SITE_FOLLOWUP_QUERIES"
                    if req.interactive_fast
                    else "MAX_SITE_FOLLOWUP_QUERIES",
                    "8" if req.interactive_fast else "18",
                )
            )
            followup_domain_limit = 8

        for host in followup_domains[:followup_domain_limit]:
            if req.adaptive_rescue:
                # Give every previously verified clinic one inexpensive
                # domain search before allocating a second query to any one
                # provider. Search local-language treatment pages first.
                local_anchor = (local_terms[0] if local_terms else preferred_terms[0])
                followup_queries.append(f'site:{host} {local_anchor}')
                if len(followup_queries) >= max_followups:
                    break
                continue
            # First search the verified clinic domain for the treatment itself.
            # Do not require the word "price" because many valid tariff pages
            # are indexed under generic aesthetic-treatment titles.
            if host in verified_followup_domains and preferred_terms:
                followup_queries.append(
                    f'site:{host} "{preferred_terms[0]}"'
                )
                if len(followup_queries) >= max_followups:
                    break

            for term in preferred_terms:
                followup_queries.append(
                    f'site:{host} "{term}" {price_word}'
                )
                if len(followup_queries) >= max_followups:
                    break
            if len(followup_queries) >= max_followups:
                break

        diag.site_followup_queries = len(followup_queries)

        followup_batches = await asyncio.gather(
            *(
                serper.search(
                    q,
                    5,
                    page=(2 if req.search_mode == "deep" else 1),
                )
                for q in followup_queries
            ),
            return_exceptions=True,
        )

        followup_hits = []
        seen_followup_urls = {h.url for h in work}
        for q, batch in zip(followup_queries, followup_batches):
            if isinstance(batch, Exception):
                errors.append(f"{q}: {batch}"[:500])
                continue
            for hit in batch:
                if (hit.url in seen_followup_urls or bad_host(hit.url)
                        or not keep_new_provider(hit)):
                    continue
                if classify_source(hit.url) != "official_clinic":
                    continue
                seen_followup_urls.add(hit.url)
                followup_hits.append(hit)

        followup_hits = followup_hits[:12]
        diag.site_followup_urls = len(followup_hits)

        if followup_hits:
            followup_processed = await asyncio.gather(
                *(process_and_publish(h) for h in followup_hits),
                return_exceptions=True,
            )
            processed.extend(followup_processed)

    # A marketplace listing, or an official procedure page, that names the
    # clinic and shows no price is not a card. Search the configured web index
    # for that clinic's procedure price, then open the official or booking page.
    # The Google snippet itself is never stored as the price.
    unpriced_queries = []
    seen_unpriced = set()
    for item in processed:
        if isinstance(item, Exception):
            continue
        status, hit, html, text, payload, detail = item
        if status != "ok" or not payload:
            continue
        name, evidence = payload
        source = classify_source(hit.url)
        clinic = (hit.place_name or "").strip()
        if source == "official_clinic" and len(clinic) < 2:
            clinic = domain_brand(hit.url)
        elif len(clinic) < 2:
            clinic = (name or "").strip()
        priced = bool(evidence)
        procedure_on_page = bool(text and has_procedure(text, req.procedure))
        city_on_page = city_in_text(
            f"{text or ''} {hit.snippet or ''} {hit.place_address or ''}",
            req.city,
        )
        if not (
            unpriced_listing_should_search(source, clinic, priced)
            or unpriced_official_page_should_search(
                source, clinic, priced, procedure_on_page, city_on_page,
            )
        ):
            continue
        clinic_key = _clinic_compare_key(clinic)
        if clinic_key and clinic_key in {
            _clinic_compare_key(known) for known in req.known_clinic_names
        }:
            continue
        for query in unpriced_provider_price_queries(clinic, req.city, req.procedure):
            if query in seen_unpriced:
                continue
            seen_unpriced.add(query)
            unpriced_queries.append(query)
            if len(unpriced_queries) >= 2:
                break
        if len(unpriced_queries) >= 2:
            break
    if unpriced_queries and req.enable_serper and not req.progressive_stage:
        room = max(0, int(req.serper_request_cap) - int(serper.requests_attempted))
        unpriced_queries = unpriced_queries[: min(2, room)]
    else:
        unpriced_queries = []
    if unpriced_queries:
        diag.site_followup_queries += len(unpriced_queries)
        unpriced_batches = await asyncio.gather(
            *(serper.search(query, 5) for query in unpriced_queries),
            return_exceptions=True,
        )
        extra_hits = []
        seen_extra = set()
        for previous in processed:
            if isinstance(previous, Exception):
                continue
            try:
                seen_extra.add(previous[1].url)
            except Exception:
                continue
        for query, batch in zip(unpriced_queries, unpriced_batches):
            if isinstance(batch, Exception):
                errors.append(f"{query}: {batch}"[:500])
                continue
            for hit in batch:
                if hit.url in seen_extra or bad_host(hit.url):
                    continue
                if not price_search_hit_is_openable_page(hit.url):
                    continue
                seen_extra.add(hit.url)
                extra_hits.append(hit)
                if len(extra_hits) >= 4:
                    break
        if extra_hits:
            # The menu pages that had no price already spent the round budget.
            # These follow-up pages are the ones that can still become cards.
            allowance = _interactive_fetch_budget.get()
            if allowance is not None:
                async with allowance["lock"]:
                    short = min(4, len(extra_hits)) - int(allowance.get("left") or 0)
                    if short > 0:
                        allowance["left"] = int(allowance.get("left") or 0) + short
            extra_processed = await asyncio.gather(
                *(process_and_publish(hit) for hit in extra_hits),
                return_exceptions=True,
            )
            processed.extend(extra_processed)

    rows, official_stats = await enrich_marketplace_rows_with_official_sites(
        rows,
        directory_hits,
        req,
        primary_language,
        country_code,
        serper,
    )

    diag.marketplace_official_checks = official_stats["checks"]
    diag.marketplace_official_variant_checks = official_stats[
        "variant_checks"
    ]
    diag.marketplace_official_site_crawls = official_stats[
        "site_crawls"
    ]
    diag.marketplace_official_sites_matched = official_stats["sites_matched"]
    diag.marketplace_official_sites_from_directory = official_stats[
        "sites_from_directory"
    ]
    diag.marketplace_official_weak_directory_skipped = official_stats[
        "weak_directory_skipped"
    ]
    diag.marketplace_official_directory_superseded = official_stats[
        "directory_superseded"
    ]
    diag.marketplace_official_sites_from_search = official_stats[
        "sites_from_search"
    ]
    diag.marketplace_official_sites_from_linked_discovery_page = (
        official_stats["sites_from_linked_discovery_page"]
    )
    diag.marketplace_official_sites_from_profile_link = official_stats[
        "sites_from_profile_link"
    ]
    diag.marketplace_official_sites_from_domain_probe = official_stats[
        "sites_from_domain_probe"
    ]
    diag.marketplace_official_sites_from_brand_identity_probe = (
        official_stats["sites_from_brand_identity_probe"]
    )
    diag.marketplace_official_domain_probe_attempts = official_stats[
        "domain_probe_attempts"
    ]
    diag.marketplace_official_domain_probe_matches = official_stats[
        "domain_probe_matches"
    ]
    diag.marketplace_official_domain_probe_rejected_no_procedure = (
        official_stats["domain_probe_rejected_no_procedure"]
    )
    diag.marketplace_official_resolution_search_queries = official_stats[
        "resolution_search_queries"
    ]
    diag.marketplace_official_sites_cached = official_stats[
        "sites_cached"
    ]
    diag.marketplace_official_procedure_confirmed = official_stats[
        "procedure_confirmed"
    ]
    diag.marketplace_official_prices_found = official_stats["prices_found"]
    diag.marketplace_prices_overridden = official_stats["prices_overridden"]
    diag.marketplace_official_no_price = official_stats["official_no_price"]
    diag.marketplace_official_unresolved = official_stats[
        "official_unresolved"
    ]
    diag.marketplace_snippet_prices_rejected = official_stats[
        "snippet_rejected"
    ]

    diag.accepted_rows_before_dedupe = len(rows)
    diag.accepted_candidate_clinics = list(dict.fromkeys(
        r.clinic_name for r in rows if r.clinic_name
    ))[:20]

    # Best row per clinic+procedure+unit.
    # An article that quotes market prices may pass extraction but must never
    # suppress a trusted price-menu row for the same clinic during dedupe.
    best = {}

    for r in rows:
        if not trusted_price_result(r):
            diag.trust_rejected_rows += 1
            if len(diag.trust_reject_samples) < 10:
                reason = trusted_price_failure(r)
                evidence = " ".join((r.raw_evidence or "").split())[:80]
                diag.trust_reject_samples.append(
                    f"{r.clinic_name} {r.procedure_canonical} {reason} "
                    f"url={r.source_url[:140]} evidence={evidence}"
                )
            continue
        key = (
            r.clinic_name.lower().strip(),
            r.procedure_canonical,
            r.unit,
        )

        evidence_quality = {
            "official_price_menu": 6,
            "official_treatment_page": 5,
            "marketplace_service_menu": 4,
            "marketplace_profile": 3,
            "official_article": 2,
            "official_page": 1,
            "unknown": 0,
        }
        score = (
            1 if r.city_match else 0,
            evidence_quality.get(r.evidence_type, 0),
            1 if r.identity_verified else 0,
            1 if r.clinic_own_price else 0,
            r.confidence,
            -len(r.raw_evidence or ""),
        )

        prev = best.get(key)

        if not prev:
            best[key] = r
            continue

        prev_score = (
            1 if prev.city_match else 0,
            evidence_quality.get(prev.evidence_type, 0),
            1 if prev.identity_verified else 0,
            1 if prev.clinic_own_price else 0,
            prev.confidence,
            -len(prev.raw_evidence or ""),
        )

        if score > prev_score:
            best[key] = r

    evidence_rank = {
        "official_price_menu": 0,
        "official_treatment_page": 1,
        "marketplace_service_menu": 2,
        "marketplace_profile": 3,
        "official_article": 4,
        "official_page": 5,
        "unknown": 6,
    }

    ranked = sorted(
        best.values(),
        key=lambda r: (
            not r.city_match,
            evidence_rank.get(r.evidence_type, 9),
            not r.identity_verified,
            not r.clinic_own_price,
            -r.confidence,
        ),
    )

    final = []
    seen_clinics = set()

    for r in ranked:
        ck = r.clinic_name.lower().strip()

        if ck in seen_clinics:
            continue

        seen_clinics.add(ck)
        final.append(r)

        if len(final) >= req.limit:
            break

    diag.accepted_rows_after_dedupe = len(final)
    diag.trusted_candidate_clinics = [r.clinic_name for r in final[:20]]
    known_hosts = set(req.known_clinic_hosts)
    diag.trusted_novel_candidate_clinics = [
        r.clinic_name for r in final[:20]
        if not any(related_clinic_hosts(official_identity_host(r), known) for known in known_hosts)
    ] if req.hybrid_interactive else []

    if final and (
        req.persist
        or env_bool("AUTO_PERSIST_SEARCH_RESULTS", False)
    ):
        await firestore_upsert_results(
            req.city,
            req.procedure,
            country_code,
            final,
            discovered_by="discover_endpoint",
        )

        if req.persist:
            await firestore_register_target(
                req.city,
                req.procedure,
                country_code,
            )

    diag.serper_rate_limit_retries = serper.rate_limit_retries
    diag.serper_request_cap = serper.request_cap
    diag.serper_cache_hits = serper.cache_hits
    diag.serper_cache_writes = serper.cache_writes
    diag.serper_free_account_num_fallbacks = (
        serper.free_account_num_fallbacks
    )
    diag.serper_effective_num_cap = serper.effective_num_cap
    diag.serper_configured = bool(serper.api_key)
    diag.serper_requests_attempted = serper.requests_attempted
    diag.serper_requests_succeeded = serper.requests_succeeded
    diag.serper_requests_failed = serper.requests_failed
    diag.serper_requests_skipped = serper.requests_skipped
    diag.serper_disabled = serper.disabled
    diag.serper_disabled_reason = serper.disabled_reason
    diag.serper_last_error = serper.last_error
    diag.brightdata_serp_configured = serper.brightdata_enabled
    diag.brightdata_serp_requests_attempted = (
        serper.brightdata_requests_attempted
    )
    diag.brightdata_serp_requests_succeeded = (
        serper.brightdata_requests_succeeded
    )
    diag.brightdata_serp_requests_failed = (
        serper.brightdata_requests_failed
    )
    diag.brightdata_serp_hits_total = (
        serper.brightdata_hits_total
    )
    diag.brightdata_serp_fallback_used = (
        serper.brightdata_fallback_used
    )
    diag.brave_search_configured = bool(getattr(serper, "brave_enabled", False))
    diag.brave_search_requests_attempted = int(getattr(serper, "brave_requests_attempted", 0))
    diag.brave_search_requests_succeeded = int(getattr(serper, "brave_requests_succeeded", 0))
    diag.brave_search_requests_failed = int(getattr(serper, "brave_requests_failed", 0))
    diag.brave_search_hits_total = int(getattr(serper, "brave_hits_total", 0))
    diag.brave_search_cache_hits = int(getattr(serper, "brave_cache_hits", 0))
    diag.brave_search_used = bool(getattr(serper, "brave_used", False))
    # Include any optional identity lookup calls that happened after bootstrap.
    diag.places_requests_attempted += places.requests_attempted
    diag.places_requests_succeeded += places.requests_succeeded
    if not diag.places_api_status and places.last_status:
        diag.places_api_status = places.last_status
    if not diag.places_api_error and places.last_error:
        diag.places_api_error = places.last_error
    diag.places_quota_blocked = diag.places_quota_blocked or places.quota_blocked

    return DiscoverResponse(
        city=req.city,
        procedure=req.procedure,
        country_code=country_code,
        primary_language=primary_language,
        queries=queries,
        results=final,
        searched_urls=len(work) + diag.site_followup_urls,
        fetched_pages=diag.pages_fetched,
        search_errors=list(dict.fromkeys(errors))[:10],
        # Hybrid uses counters for growth_exhausted_reason even without debug.
        diagnostics=diag if (req.debug or req.hybrid_interactive) else None,
        crawled_urls=[
            item[1].url for item in processed
            if not isinstance(item, Exception) and item[1].url
        ],
    )


# ============================================================
# API
# ============================================================

@asynccontextmanager
async def app_lifespan(_app):
    await start_background_refresh()
    try:
        yield
    finally:
        await stop_background_refresh()


app = FastAPI(
    title="Aesthetic Procedure Price Discovery",
    version="0.11.88",
    lifespan=app_lifespan,
)


@app.get("/serper-health")
async def serper_health(city: str = "Tirana"):
    client = SerperClient()
    if not client.api_key:
        return {
            "configured": False,
            "ok": False,
            "error": "SERPER_API_KEY is not configured",
            "result_count": 0,
        }
    try:
        rows = await client.search(f'"aesthetic clinic" {city}', num=3, page=1)
        return {
            "configured": True,
            "ok": True,
            "result_count": len(rows),
            "sample_urls": [r.url for r in rows[:3]],
            "requests_attempted": client.requests_attempted,
            "requests_succeeded": client.requests_succeeded,
            "requests_failed": client.requests_failed,
            "error": client.last_error,
        }
    except Exception as exc:
        return {
            "configured": True,
            "ok": False,
            "result_count": 0,
            "requests_attempted": client.requests_attempted,
            "requests_succeeded": client.requests_succeeded,
            "requests_failed": client.requests_failed,
            "error": str(exc)[:500],
        }


@app.get("/health")
async def health():
    worker_version = getattr(getattr(app.state, "index_jobs", None), "version", "unknown")
    return {"ok": True, "version": app.version,
            "price_index": True, "discovery_jobs": True,
            "worker_version": worker_version, "progressive_jobs": worker_version == app.version}


_BACKGROUND_REFRESH_TASK = None


async def refresh_targets_once() -> RefreshTargetsResponse:
    available = await firestore_is_available()

    if not available:
        return RefreshTargetsResponse(
            firestore_available=False,
            errors=["Firestore is disabled, unavailable, or missing credentials."],
        )

    max_targets = int(os.getenv("BACKGROUND_MAX_TARGETS_PER_RUN", "20"))
    discovery_limit = int(os.getenv("BACKGROUND_DISCOVERY_LIMIT", "8"))

    targets = await firestore_load_targets(max_targets)

    refreshed = 0
    rows_persisted = 0
    errors = []

    for target in targets:
        city = str(target.get("city") or "").strip()
        procedure = str(target.get("procedure") or "").strip()
        country_code = str(target.get("country_code") or "").strip()
        doc_id = str(target.get("_doc_id") or "")

        if not city or not procedure:
            continue

        try:
            # Rotate query families across background runs so continuous refresh
            # does not spend every cycle asking Google the same questions.
            refresh_count = int(target.get("refresh_count", 0) or 0)
            search_mode = ["expanded", "deep", "standard"][refresh_count % 3]

            if env_bool("BACKGROUND_RUN_LEGACY_MAINTENANCE", False):
                await firestore_normalize_whatclinic_results(city, procedure)
                await firestore_normalize_cached_units(city, procedure)
                await firestore_deactivate_weak_results(city, procedure)

            stored_before = await firestore_load_results(
                city,
                procedure,
                max_results=100,
            )
            stored_keys = _stored_clinic_keys(stored_before)

            response = await discover(
                DiscoverRequest(
                    city=city,
                    procedure=procedure,
                    country_code=country_code or None,
                    limit=discovery_limit,
                    persist=False,
                    debug=False,
                    search_mode=search_mode,
                )
            )

            new_count = len(
                {
                    _clinic_compare_key(row.clinic_name)
                    for row in response.results
                    if _clinic_compare_key(row.clinic_name)
                    and _clinic_compare_key(row.clinic_name) not in stored_keys
                }
            )

            written = await firestore_upsert_results(
                city,
                procedure,
                response.country_code,
                response.results,
                discovered_by=f"background_refresh_{search_mode}",
            )

            rows_persisted += written
            refreshed += 1

            await firestore_update_target_refresh(
                doc_id,
                len(response.results),
                "",
                search_mode=search_mode,
                newly_discovered_count=new_count,
            )

        except Exception as exc:
            msg = f"{city}/{procedure}: {exc}"
            errors.append(msg[:500])

            await firestore_update_target_refresh(
                doc_id,
                0,
                msg,
                search_mode="error",
                newly_discovered_count=0,
            )

    return RefreshTargetsResponse(
        firestore_available=True,
        targets_seen=len(targets),
        targets_refreshed=refreshed,
        rows_persisted=rows_persisted,
        errors=errors[:20],
    )


async def background_refresh_loop():
    interval_minutes = max(
        5,
        int(os.getenv("REFRESH_INTERVAL_MINUTES", "30")),
    )

    # Do not hammer APIs immediately at startup unless explicitly requested.
    startup_delay = max(
        0,
        int(os.getenv("BACKGROUND_START_DELAY_SECONDS", "20")),
    )

    if startup_delay:
        await asyncio.sleep(startup_delay)

    while True:
        try:
            await refresh_targets_once()
        except asyncio.CancelledError:
            raise
        except Exception:
            pass

        await asyncio.sleep(interval_minutes * 60)


async def start_background_refresh():
    global _BACKGROUND_REFRESH_TASK

    if (
        env_bool("ENABLE_BACKGROUND_REFRESH", False)
        and firestore_enabled()
    ):
        _BACKGROUND_REFRESH_TASK = asyncio.create_task(
            background_refresh_loop()
        )


async def stop_background_refresh():
    global _BACKGROUND_REFRESH_TASK

    if _BACKGROUND_REFRESH_TASK is not None:
        _BACKGROUND_REFRESH_TASK.cancel()

        try:
            await _BACKGROUND_REFRESH_TASK
        except asyncio.CancelledError:
            pass

        _BACKGROUND_REFRESH_TASK = None

    state = _FETCH_LOOP_STATE.pop(asyncio.get_running_loop(), None)
    if state is not None:
        await state["client"].aclose()


@app.get("/places-health")
async def places_health(city: str = "Tirana"):
    """One-request live probe. It deliberately does NOT run ten searches."""
    places = GooglePlacesClient()
    cached = await firestore_load_clinic_directory(city)

    if not places.configured:
        return {
            "configured": False,
            "usable": bool(cached),
            "cached_directory": len(cached),
            "status": 0,
            "error": "GOOGLE_PLACES_API_KEY is missing",
            "requests_attempted": 0,
            "candidates": [],
        }

    country_code = country_hint_for_city(city) or ""
    language, _ = search_profile(country_code, city)
    candidates = await places.discover_city_clinic_websites(
        city,
        language,
        procedure="",
        max_websites=10,
        max_queries=1,
    )

    return {
        "configured": True,
        "usable": bool(candidates or cached),
        "partial_success": bool(candidates and places.last_status >= 400),
        "cached_directory": len(cached),
        "status": places.last_status,
        "error": places.last_error,
        "quota_blocked": places.quota_blocked,
        "requests_attempted": places.requests_attempted,
        "requests_succeeded": places.requests_succeeded,
        "results_total": places.results_total,
        "results_with_website": places.results_with_website,
        "candidate_count": len(candidates),
        "candidates": [
            {
                "name": c.place_name or c.title,
                "rating": c.place_rating,
                "user_rating_count": c.place_user_rating_count,
                "website": c.url,
                "place_id": c.place_id,
            }
            for c in candidates
        ],
    }


@app.post("/bootstrap-city", response_model=CityBootstrapResponse)
async def bootstrap_city(city: str = "Tirana", country_code: str = "", force: bool = False):
    cc = (country_code or country_hint_for_city(city) or "").upper()
    language, _ = search_profile(cc, city)
    rows, stats = await bootstrap_city_clinic_directory(
        city,
        cc,
        language,
        procedure="",
        force=force,
        max_queries=int(os.getenv("GOOGLE_PLACES_CITY_QUERY_BUDGET", "2")),
    )
    return CityBootstrapResponse(
        city=city,
        country_code=cc,
        firestore_available=await firestore_is_available(),
        cached_before=int(stats.get("cached_before", 0)),
        places_configured=bool(os.getenv("GOOGLE_PLACES_API_KEY", "").strip()),
        places_requests_attempted=stats["requests_attempted"],
        places_requests_succeeded=stats["requests_succeeded"],
        places_status=stats["status"],
        places_error=stats["error"],
        places_quota_blocked=stats["quota_blocked"],
        places_candidates=stats["places_candidates"],
        websites_verified=stats["verified"],
        directory_added=stats["added"],
        directory_deactivated=stats.get("deactivated",0),
        directory_reactivated=stats.get("reactivated",0),
        directory_rescued_by_price_evidence=stats.get("rescued_by_price_evidence",0),
        directory_rejected_irrelevant=stats.get("rejected_irrelevant",0),
        directory_rejected_retail=stats.get("rejected_retail",0),
        directory_rejected_agency=stats.get("rejected_agency",0),
        directory_total=len(rows),
        rejected_clinics=stats.get("rejected_clinics",[]),
        clinics=[
            {
                "clinic_name": r.title,
                "official_website": r.url,
                "google_place_id": r.place_id,
                "site_relevance_score": round(float(r.directory_relevance_score or 0.0),3),
                "site_capabilities": sorted(set(r.directory_capabilities or [])),
                "site_evidence_pages": int(r.directory_evidence_pages or 0),
                "rating": r.place_rating,
                "user_rating_count": r.place_user_rating_count,
            }
            for r in rows[:50]
        ],
    )


async def search_official_tariff_links(
    host: str, procedure: str, stats: dict | None = None,
    request_cap: int = 3,
) -> list[str]:
    """Find indexed clinic menus omitted from that clinic's XML sitemap."""
    if request_cap <= 0:
        return []
    client = SerperClient(request_cap=min(3, request_cap))
    if not client.api_key and not client.brightdata_enabled:
        return []
    canonical = canonicalize_procedure(procedure)
    de_term = (local_terms_for(canonical, "de") or [display_name(canonical)])[0]
    it_term = (local_terms_for(canonical, "it") or [display_name(canonical)])[0]
    # Clinic tariff URLs are frequently absent from XML and may be in a
    # different language from the cached treatment article. Search across
    # language variants while keeping every hit on the clinic's own host.
    queries = [
        f'site:{host} (gebuhren OR preise OR prezzi OR listino OR tarife OR cmime OR prices)',
        f'site:{host} "{de_term}" (gebuhren OR preise)',
        f'site:{host} "{it_term}" (prezzi OR listino OR tarife OR prices)',
    ]
    pages = []
    for query in queries:
        try:
            matches = await client.search(query, num=10)
        except Exception:
            continue
        pages.extend(hit.url for hit in matches
                     if host_of(hit.url) == host and is_price_menu_path(hit.url))
    if stats is not None:
        stats["serper_requests_attempted"] = (
            stats.get("serper_requests_attempted", 0)
            + getattr(client, "requests_attempted", 0)
        )
        stats["serper_cache_hits"] = (
            stats.get("serper_cache_hits", 0)
            + getattr(client, "cache_hits", 0)
        )
    return list(dict.fromkeys(pages))[:8]


async def refresh_cached_official_tariffs(
    stored_pool: list[DisplayClinicPrice], city: str, procedure: str,
    country_code: str, persist: bool = True, diagnostics: dict | None = None,
    query_stats: dict | None = None,
    network_request_budget: int | None = None,
) -> tuple[list[DisplayClinicPrice], int]:
    """Search each cached clinic's sitemap for a stronger own tariff page."""
    canonical = canonicalize_procedure(procedure)
    rows = list(stored_pool)
    changed = 0
    seen_hosts = set()
    for index, stored in enumerate(rows):
        host = host_of(stored.official_website or stored.source_url)
        legacy_article = (
            stored.evidence_type == "official_treatment_page"
            and not is_price_menu_path(stored.source_url)
            and bool(re.search(r"\b(?:quanto costa|how much does|kostoja e)\b",
                               fold(stored.raw_evidence[:170])))
        )
        if (stored.evidence_type != "official_article" and not legacy_article
                or not stored.clinic_own_price
                or stored.source_type != "official_clinic"
                or not host or host in seen_hosts):
            continue
        seen_hosts.add(host)
        if diagnostics is not None:
            diagnostics[host] = "no_eligible_tariff_found"
        base = stored.official_website or stored.source_url
        links = await official_site_sitemap_candidate_links(
            base, canonical, search_profile(country_code, city)[0], limit=80,
        )
        # A short sitemap scan is worthwhile only for clearly marked tariff
        # paths; service/article pages must not replace another article.
        tariff_links = [u for u in links
                        if host_of(u) == host and is_price_menu_path(u)
                        and u.rstrip("/") != stored.source_url.rstrip("/")][:4]
        if diagnostics is not None and tariff_links:
            diagnostics[host] = "sitemap_tariff_candidates"
        async def validated_tariff(menu_url: str) -> DisplayClinicPrice | None:
            if host_of(menu_url) != host or not is_price_menu_path(menu_url):
                return None
            html = await fetch_html(menu_url)
            if not html:
                return None
            full_text = page_text(html)
            full_folded = fold(full_text[:2500])
            price_scope = (
                "package_including_travel"
                if (any(t in full_folded for t in ("flug", "flight", "volo"))
                    and any(t in full_folded for t in ("unterkunft", "hotel", "accommodation", "alloggio")))
                else "all_inclusive_package"
                if any(t in full_folded for t in ("all-inclusive", "all inclusive", "tutto incluso"))
                else ""
            )
            for evidence in sorted(
                extract_price_evidence(html, menu_url, canonical),
                key=lambda e: (len(e.raw_evidence), e.price_min),
            ):
                if (len(evidence.raw_evidence) > 160
                        or canonical == "rhinoplasty"
                        and nonprimary_rhinoplasty_variant(evidence.raw_evidence)):
                    continue
                accepted, own, confidence, _, evidence_type = validate_evidence(
                    evidence, full_text, html, city,
                )
                if not accepted or not own or evidence_type != "official_price_menu":
                    continue
                payload = stored.model_dump()
                payload.update(
                    price_min=evidence.price_min, price_max=evidence.price_max,
                    currency=evidence.currency, qualifier=evidence.qualifier,
                    unit=evidence.unit, raw_procedure_text=evidence.raw_procedure_text,
                    raw_evidence=evidence.raw_evidence, source_url=menu_url,
                    source_host=host, evidence_type=evidence_type,
                    price_scope=price_scope,
                    clinic_own_price=True, official_price_found=True,
                    price_verification_status="official_price",
                    confidence=max(confidence, 0.97),
                    last_verified_at=datetime.now(timezone.utc).isoformat(),
                    cache_age_days=0,
                )
                replacement = DisplayClinicPrice.model_validate(payload)
                if (not trusted_price_result(replacement)
                        or not official_tariff_takes_priority(replacement, stored)):
                    continue
                if persist:
                    saved = await firestore_upsert_results(
                        city, procedure, country_code,
                        [ClinicPriceResult.model_validate(payload)],
                        discovered_by="official_tariff_refresh",
                    )
                    if not saved:
                        continue
                return replacement
            return None

        # Even when an unrelated tariff is in the sitemap, a more relevant
        # procedure tariff may be indexed by search but omitted from XML.
        for menu_url in tariff_links:
            replacement = await validated_tariff(menu_url)
            if replacement is not None:
                rows[index] = replacement
                changed += 1
                break
        if rows[index].evidence_type != "official_price_menu":
            remaining = (None if network_request_budget is None else max(
                0, network_request_budget - (query_stats or {}).get("serper_requests_attempted", 0)
            ))
            if remaining == 0:
                if diagnostics is not None:
                    diagnostics[host] = "indexed_search_budget_exhausted"
                continue
            if diagnostics is not None:
                diagnostics[host] = "indexed_search_attempted"
            if remaining is None:
                indexed_links = await search_official_tariff_links(
                    host, canonical, stats=query_stats,
                )
            else:
                indexed_links = await search_official_tariff_links(
                    host, canonical, stats=query_stats, request_cap=min(3, remaining),
                )
            if diagnostics is not None and not indexed_links:
                diagnostics[host] = "no_indexed_tariff_url_found"
            for menu_url in indexed_links:
                if menu_url in tariff_links:
                    continue
                replacement = await validated_tariff(menu_url)
                if replacement is not None:
                    rows[index] = replacement
                    changed += 1
                    break
        if diagnostics is not None and rows[index].evidence_type == "official_price_menu":
            diagnostics[host] = "official_tariff_saved"
        elif diagnostics is not None and indexed_links:
            diagnostics[host] = "indexed_tariff_has_no_eligible_procedure_price"

    return rows, changed


def tighten_price_evidence(text: str, price_text: str) -> str:
    """Keep the sentence around the selected amount, not the neighbouring rows."""
    raw = " ".join((text or "").split())
    needle = " ".join((price_text or "").split())
    pos = raw.lower().find(needle.lower()) if needle else -1
    if pos < 0:
        return raw[:180]
    start = max(0, pos - 90)
    end = min(len(raw), pos + len(needle) + 12)
    return raw[start:end].strip()


async def recheck_untrusted_official_botox_menus(
    city: str,
    procedure: str,
    country_code: str,
) -> int:
    """Re-read a saved clinic tariff when its stored Botox line is not cosmetic.

    A Hungarian menu can list anti-wrinkle Botox in forint and a medical
    fissure treatment in another currency. The saved card must follow the
    cosmetic line on that same page.
    """
    if canonicalize_procedure(procedure) != "botox" or not firestore_enabled():
        return 0

    def _candidates():
        client = _firestore_client()
        if client is None:
            return []
        try:
            docs = list(
                client.collection(_results_collection_name()).where(
                    "search_key", "==", _search_key(city, procedure),
                ).limit(40).stream()
            )
        except Exception:
            return []
        found = []
        seen = set()
        for doc in docs:
            data = doc.to_dict() or {}
            if data.get("active") is False:
                continue
            raw = data.get("result")
            if not isinstance(raw, dict):
                continue
            try:
                row = ClinicPriceResult.model_validate(raw)
            except Exception:
                continue
            if (
                row.source_type != "official_clinic"
                or row.evidence_type != "official_price_menu"
                or trusted_price_result(row)
            ):
                continue
            url = (row.source_url or "").strip()
            if not url or url in seen:
                continue
            seen.add(url)
            found.append(row)
            if len(found) >= 3:
                break
        return found

    try:
        stored_rows = await asyncio.to_thread(_candidates)
    except Exception:
        return 0
    if not stored_rows:
        return 0

    refreshed: list[ClinicPriceResult] = []
    for stored in stored_rows:
        html = await fetch_html(stored.source_url)
        if not html:
            continue
        text = page_text(html)
        best = None
        best_rank = None
        for evidence in extract_price_evidence(html, stored.source_url, "botox"):
            window = tighten_price_evidence(
                evidence.raw_evidence, evidence.raw_price_text,
            )
            if botox_medical_indication(window):
                continue
            detail = procedure_detail(window, "botox", evidence.raw_price_text)
            if botox_nonprimary_variant(detail, window, evidence.unit):
                continue
            accepted, own, confidence, _reason, evidence_type = validate_evidence(
                evidence, text, html, city,
            )
            if not accepted:
                continue
            primary = (
                "upper face" in fold(detail) or "full botox" in fold(detail)
            )
            if (
                not primary
                and (not own or evidence_type != "official_price_menu")
            ):
                continue
            rank = (1 if primary else 0, -evidence.price_min)
            if best_rank is not None and rank <= best_rank:
                continue
            payload = stored.model_dump()
            payload.update(
                procedure_detail=detail,
                price_min=evidence.price_min,
                price_max=evidence.price_max,
                currency=evidence.currency,
                qualifier=evidence.qualifier,
                unit=evidence.unit or "procedure",
                raw_procedure_text=evidence.raw_procedure_text or "Botox",
                raw_evidence=window,
                evidence_type="official_price_menu",
                clinic_own_price=True,
                official_price_found=True,
                official_procedure_verified=True,
                price_verification_status="official_price",
                confidence=max(confidence, 0.9),
            )
            try:
                candidate = ClinicPriceResult.model_validate(payload)
            except Exception:
                continue
            if not trusted_price_result(candidate):
                continue
            best = candidate
            best_rank = rank
        if best is not None:
            refreshed.append(best)

    if not refreshed:
        return 0
    return await firestore_upsert_results(
        city,
        procedure,
        country_code,
        refreshed,
        discovered_by="official_menu_recheck",
    )


_LEGACY_MAINTENANCE_NEXT: dict[tuple[str, str], float] = {}
_LEGACY_MAINTENANCE_LOCKS = weakref.WeakKeyDictionary()


async def run_legacy_maintenance_if_due(city: str, procedure: str) -> tuple[int, int, int]:
    """Run repairs at most once per city/procedure per process and TTL."""
    key = (canonical_city(city), canonicalize_procedure(procedure))
    loop = asyncio.get_running_loop()
    locks = _LEGACY_MAINTENANCE_LOCKS.setdefault(loop, {})
    lock = locks.setdefault(key, asyncio.Lock())
    async with lock:
        if time.monotonic() < _LEGACY_MAINTENANCE_NEXT.get(key, 0):
            return 0, 0, 0
        normalized = await firestore_normalize_whatclinic_results(city, procedure)
        units = await firestore_normalize_cached_units(city, procedure)
        deactivated = await firestore_deactivate_weak_results(city, procedure)
        _LEGACY_MAINTENANCE_NEXT[key] = time.monotonic() + max(
            60, int(os.getenv("LEGACY_MAINTENANCE_TTL_SECONDS", "86400"))
        )
        return normalized, units, deactivated


def _app_can_show_row(row) -> bool:
    """Rows the app can paint as a price card.

    Same cards the terminal hybrid display keeps: an owned clinic price, or a
    bookable service menu. Country-comparison articles stay out.
    """
    if not trusted_price_result(row):
        return False
    if news_report_url(row.source_url):
        return False
    if comparative_market_article_context(row.source_url, row.raw_evidence or ""):
        return False
    if row.clinic_own_price and row.source_type == "official_clinic":
        return True
    return (
        row.source_type == "marketplace"
        and row.evidence_type == "marketplace_service_menu"
    )


async def _emit_hybrid_partial(rows: list) -> None:
    """Send already-stored cards before tariff refresh and live search."""
    queue = _hybrid_progress.get()
    if queue is None or not rows:
        return
    payload = []
    for row in rows:
        if hasattr(row, "model_dump"):
            payload.append(row.model_dump(mode="json"))
    if payload:
        await queue.put({"event": "partial", "display_results": payload})


async def _emit_hybrid_status(**progress) -> None:
    queue = _hybrid_progress.get()
    if queue is not None:
        await queue.put({"event": "progress", "progress": progress})


async def _discover_hybrid_ndjson(req: HybridDiscoverRequest):
    queue: asyncio.Queue = asyncio.Queue()

    async def run() -> None:
        token = _hybrid_progress.set(queue)
        try:
            result = await _discover_hybrid_impl(req)
            await queue.put({
                "event": "done",
                "body": result.model_dump(mode="json"),
            })
        except Exception as exc:
            await queue.put({"event": "error", "detail": str(exc)})
        finally:
            _hybrid_progress.reset(token)
            await queue.put(None)

    task = asyncio.create_task(run())
    try:
        while True:
            item = await queue.get()
            if item is None:
                break
            yield json.dumps(item, default=str) + "\n"
    finally:
        if not task.done():
            task.cancel()


@app.post("/discover-hybrid")
async def discover_hybrid(req: HybridDiscoverRequest):
    if req.stream_progress:
        return StreamingResponse(
            _discover_hybrid_ndjson(req),
            media_type="application/x-ndjson",
        )
    return await _discover_hybrid_impl(req)


async def _discover_hybrid_impl(req: HybridDiscoverRequest):
    country_code = (
        req.country_code
        or country_hint_for_city(req.city)
        or ""
    ).upper()

    available = await firestore_is_available()

    whatclinic_firestore_normalized = 0
    cached_units_normalized = 0
    weak_firestore_deactivated = 0

    # Interactive searches paint the first new card before sitemap rechecks,
    # legacy maintenance, or tariff refreshes spend the Serper cap.
    if available and not req.stream_progress:
        await recheck_untrusted_official_botox_menus(
            req.city, req.procedure, country_code,
        )
        (whatclinic_firestore_normalized,
         cached_units_normalized,
         weak_firestore_deactivated) = await run_legacy_maintenance_if_due(
            req.city, req.procedure,
        )

    stored_pool = (
        await firestore_load_results(
            req.city,
            req.procedure,
            max_results=max(60, req.display_limit * 12),
        )
        if available
        else []
    )
    excluded_urls = set(req.excluded_source_urls)
    stored_pool = [row for row in stored_pool if row.source_url not in excluded_urls]
    if req.stream_progress:
        stored_pool = [row for row in stored_pool if _app_can_show_row(row)]
    preview = compose_hybrid_display(
        stored_pool, [], req.stored_count, req.fresh_count, req.display_limit,
        allow_cached_fill=not req.strict_new_clinics,
    )[3]
    await _emit_hybrid_partial(preview)
    historical_pool = (
        await firestore_load_historical_results(
            req.city,
            req.procedure,
            max_results=max(300, req.display_limit * 30),
        )
        if available
        else []
    )

    tariff_refresh_diagnostics = {}
    tariff_search_stats = {}
    tariff_rows_updated = 0
    if not req.stream_progress:
        stored_pool, tariff_rows_updated = await refresh_cached_official_tariffs(
            stored_pool, req.city, req.procedure, country_code,
            persist=available,
            diagnostics=tariff_refresh_diagnostics,
            query_stats=tariff_search_stats,
            network_request_budget=min(
                max(0, int(os.getenv("MAX_ADAPTIVE_TARIFF_SERPER_REQUESTS", "6"))),
                6,
                max(0, int(os.getenv("MAX_ADAPTIVE_TOTAL_SERPER_REQUESTS", "16"))),
            ) if req.economical_growth else None,
        )
    # Earlier releases could already have saved an owned microsite under a
    # second brand name. Firestore read order ranks stronger tariff evidence
    # first; collapse aliases before selecting any cards or counting clinics.
    stored_pool = _unique_display_rows(stored_pool)
    stored_pool = [row for row in stored_pool if row.source_url not in excluded_urls
                   and (not req.stream_progress or _app_can_show_row(row))]

    if available:
        await firestore_register_target(
            req.city,
            req.procedure,
            country_code,
        )

    live_limit = max(
        10,
        req.display_limit * 4,
        req.fresh_count * 6,
    )

    # Always reserve stored_count saved cards and search for fresh_count
    # new clinics. A full saved list must not cancel the live search.
    desired_new_for_display = hybrid_desired_new_count(
        stored_available=max(len(stored_pool), req.client_stored_count),
        stored_count=req.stored_count,
        fresh_count=req.fresh_count,
        display_limit=req.display_limit,
    )
    if req.collection_target:
        # Only the verified server pool reduces the database goal. Client
        # counts are hints and must never claim that a price is verified.
        desired_new_for_display = max(
            desired_new_for_display, req.collection_target - len(stored_pool),
        )
    if (req.stream_progress and req.serper_first and not req.background_collection
            and env_bool("ENABLE_PROGRESSIVE_DISCOVERY", True)):
        desired_new_for_display = min(desired_new_for_display,
            max(0, vertical_search.GOOD_ENOUGH - len(stored_pool)))

    memo_token = _hybrid_parse_memo.set({"__city__": canonical_city(req.city)})
    try:
        (
            responses,
            merged_live,
            growth_stopped_for_cache_sufficiency,
        ) = await run_growth_search(
            city=req.city,
            procedure=req.procedure,
            country_code=country_code,
            stored_pool=stored_pool,
            desired_new=desired_new_for_display,
            limit=live_limit,
            debug=req.debug,
            enabled=req.enable_growth_search,
            max_rounds=req.max_growth_rounds,
            interactive_fast=req.fast_interactive_search,
            cache_sufficient=False,
            force_full_growth_search=req.force_full_growth_search,
            app_fast=req.stream_progress,
            economical_growth=req.economical_growth,
            initial_serper_requests=tariff_search_stats.get("serper_requests_attempted", 0),
            stored_count=req.stored_count,
            fresh_count=req.fresh_count,
            display_limit=req.display_limit,
            allow_cached_fill=not req.strict_new_clinics,
            excluded_source_urls=req.excluded_source_urls,
            client_known_clinic_hosts=req.client_known_clinic_hosts,
            client_known_clinic_names=req.client_known_clinic_names,
            serper_request_budget=req.serper_request_budget,
            serper_first=req.serper_first,
            background_collection=req.background_collection,
        )
    finally:
        _hybrid_parse_memo.reset(memo_token)

    merged_live = [row for row in merged_live if row.source_url not in excluded_urls
                   and (not req.stream_progress or _app_can_show_row(row))]
    merged_live, stabilized_clinic_names = stabilize_live_clinic_names(
        merged_live, stored_pool,
    )

    fresh_pool_raw = [
        _display_from_live(row, "live_search")
        for row in merged_live
    ]

    # In v0.11.1, a fresh slot means genuinely NEW to Firestore.
    # Existing clinics found again live are refreshes only and cannot occupy
    # one of the requested fresh slots.
    novel_rows = _novel_live_rows(
        fresh_pool_raw,
        stored_pool,
    )
    fresh_pool = novel_rows
    novel_live_available = len(novel_rows)
    genuinely_new_rows, corrected_reverification_rows = split_novel_history(
        novel_rows, historical_pool,
    )
    existing_operator_aliases = []
    for row in merged_live:
        match = cached_identity_match(row, stored_pool)
        shared_ids = shared_legal_identifiers(row, match) if match is not None else set()
        shared_names = shared_legal_entity_names(row, match) if match is not None else set()
        shared_contacts = shared_operator_contacts(row, match) if match is not None else set()
        if match is not None and (shared_ids or shared_names or shared_contacts):
            if shared_ids:
                reason = "shared_official_legal_identifier"
                evidence = sorted(shared_ids)[0]
            elif shared_names:
                reason = "shared_official_legal_entity"
                evidence = sorted(shared_names)[0]
            else:
                reason = "shared_official_operator_contact"
                evidence = sorted(shared_contacts)[0]
            alias = {
                "found_name": row.clinic_name,
                "stored_name": match.clinic_name,
                "found_host": official_identity_host(row),
                "stored_host": official_identity_host(match),
                "reason": reason,
            }
            if shared_ids:
                alias["legal_identifier"] = evidence
            else:
                alias["identity_evidence"] = evidence
            existing_operator_aliases.append(alias)

    persisted_count = tariff_rows_updated

    # A treatment microsite under an existing clinic's domain is the same
    # provider even when its page title looks like a different clinic name.
    # Do not persist that alias as an extra Firestore clinic.
    persistable_live = []
    for row in merged_live:
        match = cached_identity_match(row, stored_pool)
        if match is None:
            persistable_live.append(row)
            continue
        row_host = official_identity_host(row)
        stored_host = official_identity_host(match)
        # Revalidation on the exact same owned host may update the existing
        # Firestore document. A microsite/subdomain or another domain sharing
        # the same public legal ID is an alias and must not create a document.
        if row_host and row_host == stored_host:
            persistable_live.append(row)
        elif (not row_host and not stored_host
              and _clinic_compare_key(row.clinic_name)
              == _clinic_compare_key(match.clinic_name)):
            persistable_live.append(row)

    if available and persistable_live:
        persisted_count += await firestore_upsert_results(
            req.city,
            req.procedure,
            responses[-1].country_code if responses else country_code,
            persistable_live,
            discovered_by=(
                "hybrid_growth_search"
                if len(responses) > 1
                else "hybrid_live_search"
            ),
        )

        stored_pool = refresh_cached_display_rows_with_live(
            stored_pool,
            merged_live,
        )

    (
        stored_selected,
        fresh_selected,
        fallback_rows,
        display_rows,
        fallback_used,
        fallback_reason,
    ), rotation_persisted = await compose_persistent_rotating_hybrid_display(
        city=req.city,
        procedure=req.procedure,
        stored_pool=stored_pool,
        fresh_pool=fresh_pool,
        stored_count=req.stored_count,
        fresh_count=req.fresh_count,
        display_limit=req.display_limit,
        allow_cached_fill=not req.strict_new_clinics,
    )

    app_bridge_enabled = bool(
        req.sync_app_bridge
        or env_bool("ENABLE_APP_BRIDGE", False)
    )
    app_candidates_synced = 0
    app_site_urls_synced = 0
    app_evidence_staged = 0

    if available and app_bridge_enabled:
        directory_rows = await firestore_load_clinic_directory(
            req.city,
            max_results=120,
        )

        # Feed all still-trusted Python cache/live identities to the app
        # candidate queue, not only the four currently visible cards.
        bridge_rows = []
        seen_bridge = set()
        for row in [*stored_pool, *fresh_pool_raw]:
            try:
                safe = trusted_price_result(row)
            except Exception:
                safe = False
            if not safe:
                continue
            key = (
                fold(row.clinic_name),
                host_of(_candidate_website_from_price_row(row)),
                row.source_type,
            )
            if key in seen_bridge:
                continue
            seen_bridge.add(key)
            bridge_rows.append(row)

        app_candidates_synced = await firestore_sync_app_candidate_store(
            req.city,
            req.procedure,
            country_code,
            bridge_rows,
            directory_rows,
        )

        app_site_urls_synced = await firestore_sync_app_site_urls(
            req.city,
            req.procedure,
            bridge_rows,
        )

        if req.sync_app_staging:
            app_evidence_staged = await firestore_stage_python_price_evidence(
                req.city,
                req.procedure,
                country_code,
                bridge_rows,
            )

    if req.stream_progress and not req.force_full_growth_search and req.enable_growth_search:
        normalized_rounds = ["expanded", "site_focus", "rescue"][:len(responses)]
    else:
        normalized_rounds = (["standard", "expanded", "rescue", "site_focus"]
                             if req.economical_growth else ["standard", "expanded", "deep"])[:len(responses)]

    newly_discovered_count = novel_live_available
    refreshed_existing_count = max(
        0,
        len(merged_live) - newly_discovered_count,
    )

    growth_diagnostics = {}
    if req.debug:
        for i, response in enumerate(responses):
            if response.diagnostics is not None:
                growth_diagnostics[
                    normalized_rounds[i]
                ] = response.diagnostics

    serper_network_requests_total = sum(
        (
            response.diagnostics.serper_requests_attempted
            if response.diagnostics is not None
            else 0
        )
        for response in responses
    )
    serper_cache_hits_total = sum(
        (
            response.diagnostics.serper_cache_hits
            if response.diagnostics is not None
            else 0
        )
        for response in responses
    )
    brave_search_requests_total = sum(
        (
            response.diagnostics.brave_search_requests_attempted
            if response.diagnostics is not None
            else 0
        )
        for response in responses
    )
    total_serper_spent = (serper_network_requests_total
                          + tariff_search_stats.get("serper_requests_attempted", 0))
    env_serper_cap = max(0, int(os.getenv("MAX_ADAPTIVE_TOTAL_SERPER_REQUESTS", "16")))
    request_serper_cap = (
        req.serper_request_budget if req.serper_request_budget > 0 else env_serper_cap
    )
    if req.force_full_growth_search or req.serper_request_budget > 0:
        request_serper_cap = max(request_serper_cap, min(32, max(env_serper_cap, 28)))
    request_serper_cap = min(40, max(0, request_serper_cap))
    if req.stream_progress and req.serper_first and env_bool("ENABLE_PROGRESSIVE_DISCOVERY", True):
        request_serper_cap = min(req.serper_request_budget or 4, 4)
    remaining_serper_budget = max(
        0, request_serper_cap - total_serper_spent,
    ) if req.economical_growth else 0
    shortfall = max(0, desired_new_for_display - novel_live_available)
    blocked_by_total_budget = bool(
        req.economical_growth and req.enable_growth_search
        and shortfall and remaining_serper_budget == 0 and len(responses) < min(4, req.max_growth_rounds)
    )
    quality_rejected_count = 0
    quality_reject_samples: list[str] = []
    quality_reasons = {
        "comparative_market_article", "directory_unverified",
        "market_context", "foreign_market_context",
        "agency_or_directory_context", "multi_provider_agency_price",
        "third_party_provider_quote", "nonprimary_rhinoplasty_variant",
        "foreign_comparison_column", "unresolved_comparison_column",
        "places_miss_no_local_evidence", "marketplace_not_city_verified",
        "news_report", "generic_multi_clinic_price",
    }
    for response in responses:
        diagnostics = response.diagnostics
        if diagnostics is None:
            continue
        quality_rejected_count += (
            diagnostics.rejected_market_context
            + diagnostics.rejected_city
            + diagnostics.rejected_foreign_city
            + diagnostics.rejected_bad_identity
            + diagnostics.rejected_ambiguous_multi_price
            + diagnostics.trust_rejected_rows
        )
        for sample in diagnostics.reject_samples:
            if sample.reason not in quality_reasons:
                continue
            rendered = f"{sample.reason}: {sample.url}"
            if rendered not in quality_reject_samples:
                quality_reject_samples.append(rendered[:300])
        for sample in diagnostics.trust_reject_samples:
            rendered = f"final_trust_gate: {sample}"
            if rendered not in quality_reject_samples:
                quality_reject_samples.append(rendered[:300])

    return HybridDiscoverResponse(
        city=req.city,
        procedure=req.procedure,
        country_code=(
            responses[-1].country_code
            if responses
            else country_code
        ),
        strategy=f"{req.stored_count}_firestore_{req.fresh_count}_new_live",
        firestore_enabled=firestore_enabled(),
        firestore_available=available,
        stored_available=len(stored_pool),
        client_stored_available=req.client_stored_count,
        known_firestore_clinics=(
            [{"name": row.clinic_name, "official_host": stored_provider_identity_host(row)}
             for row in stored_pool] if req.debug else []
        ),
        live_available=len(fresh_pool),
        desired_new_for_display=desired_new_for_display,
        novel_live_available=novel_live_available,
        existing_operator_aliases=existing_operator_aliases[:20],
        rotation_persisted=rotation_persisted,
        official_tariff_refresh_diagnostics=tariff_refresh_diagnostics,
        tariff_serper_network_requests=tariff_search_stats.get("serper_requests_attempted", 0),
        persisted_count=persisted_count,
        app_bridge_enabled=app_bridge_enabled,
        app_candidates_synced=app_candidates_synced,
        app_site_urls_synced=app_site_urls_synced,
        app_evidence_staged=app_evidence_staged,
        newly_discovered_count=newly_discovered_count,
        genuinely_new_count=len(genuinely_new_rows),
        corrected_reverification_count=len(corrected_reverification_rows),
        quality_rejected_count=quality_rejected_count,
        quality_reject_samples=quality_reject_samples[:20],
        genuinely_new_clinics=[row.clinic_name for row in genuinely_new_rows],
        corrected_reverification_clinics=[
            row.clinic_name for row in corrected_reverification_rows
        ],
        stabilized_clinic_names=stabilized_clinic_names[:20],
        refreshed_existing_count=refreshed_existing_count,
        weak_firestore_deactivated=weak_firestore_deactivated,
        whatclinic_firestore_normalized=whatclinic_firestore_normalized,
        cached_units_normalized=cached_units_normalized,
        economical_growth_used=req.economical_growth,
        serper_network_requests_total=(
            serper_network_requests_total + tariff_search_stats.get("serper_requests_attempted", 0)
        ),
        serper_cache_hits_total=serper_cache_hits_total,
        brave_search_requests_total=brave_search_requests_total,
        brave_search_used=brave_search_requests_total > 0,
        growth_search_used=len(responses) > 1,
        growth_rounds=normalized_rounds,
        adaptive_rescue_used="rescue" in normalized_rounds,
        adaptive_site_focus_used="site_focus" in normalized_rounds,
        adaptive_new_clinics_missing=shortfall,
        adaptive_serper_budget_remaining=remaining_serper_budget,
        growth_exhausted_reason=growth_shortfall_reason(
            desired_new_for_display, novel_live_available, responses,
            req.enable_growth_search, req.max_growth_rounds, req.economical_growth,
            total_budget_exhausted=blocked_by_total_budget,
        ),
        growth_exhausted=(
            req.enable_growth_search
            and not growth_stopped_for_cache_sufficiency
            and (len(responses) >= min(req.max_growth_rounds, 4) or blocked_by_total_budget)
            and novel_live_available < desired_new_for_display
        ),
        growth_stopped_for_cache_sufficiency=(
            growth_stopped_for_cache_sufficiency
        ),
        fallback_used=fallback_used,
        fallback_reason=fallback_reason,
        card_diagnostics=[
            *(
                [
                    "places_discovery_queries="
                    f"{responses[0].diagnostics.places_discovery_queries} "
                    "hosts="
                    + ",".join(responses[0].diagnostics.places_candidate_hosts[:12])
                ]
                if responses and responses[0].diagnostics is not None
                else []
            ),
            *(
                f"{row.origin} | {row.clinic_name} | {row.price_min:g} {row.currency}"
                f" | {row.source_type}/{row.evidence_type} | {row.source_url}"
                for row in display_rows
            ),
        ],
        stored_results=stored_selected,
        fresh_results=fresh_selected,
        fallback_results=fallback_rows,
        display_results=display_rows,
        candidate_results=_unique_display_rows([
            *display_rows,
            *[_copy_display_origin(row, "live_fallback") for row in fresh_pool],
            *[_copy_display_origin(row, "firestore_fallback") for row in stored_pool],
        ])[:20],
        live_search_diagnostics=(
            responses[0].diagnostics
            if req.debug and responses
            else None
        ),
        growth_diagnostics=growth_diagnostics,
        search_errors=(responses[0].search_errors if responses else []),
        growth_search_errors={
            normalized_rounds[i]: response.search_errors
            for i, response in enumerate(responses)
            if response.search_errors
        },
    )


@app.post("/refresh-targets", response_model=RefreshTargetsResponse)
async def refresh_targets():
    """
    Refresh every active city/procedure target saved in Firestore.

    For production Cloud Run, call this endpoint from Cloud Scheduler instead
    of relying only on the in-process background loop, because Cloud Run
    instances may sleep when idle.
    """
    return await refresh_targets_once()



@app.post("/discover", response_model=DiscoverResponse)
async def discover_prices(req: DiscoverRequest):
    try:
        return await discover(req)
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e))


# Keep the existing engine entry point and add the index/worker contract used
# by Flutter. Ship this companion module beside this file.
from explore_index_jobs import install as _install_index_jobs
_install_index_jobs(sys.modules[__name__])
