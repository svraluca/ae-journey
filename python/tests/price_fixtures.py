"""Shared fictional tariff fixtures for the delivered offline regressions.

The source archive omitted the test modules these fixtures originally came
from. Keep fixture construction here, separate from test collection, and use
the real discovery engine for extraction and verification.
"""
from datetime import datetime, timedelta, timezone
from html import escape
from pathlib import Path
import sys
from unittest.mock import patch

import dotenv

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
with patch.object(dotenv, "load_dotenv", return_value=False):
    import aesthetic_price_discovery_v11_67 as e


def page(name, label, amount, *, city="Abu Dhabi", currency="AED"):
    """A clinic-owned price menu with explicit treatment and local address."""
    name, label = escape(name), escape(label)
    return (
        f"<html><title>{name}</title><h1>{name}</h1>"
        f"<h2>{label}</h2><p>Our {label} treatment: {amount} {escape(currency)}</p>"
        f"<footer>Our clinic: Test Street, {escape(city)}. Book an appointment.</footer></html>"
    )


def quote(name="Aster Medical Clinic", host="aster.example", *, amount=900,
          city="Abu Dhabi", age=0, origin="firestore"):
    """Build a display row from a tariff accepted by the actual verifier."""
    html = page(name, "Botox 3 areas", amount, city=city)
    url = f"https://{host}/prices/"
    text = e.page_text(html)
    candidates = e.extract_price_evidence(html, url, "botox")
    for evidence in candidates:
        accepted, owned, confidence, _, kind = e.validate_evidence(
            evidence, text, html, city,
        )
        if accepted and evidence.price_min == amount:
            break
    else:
        raise AssertionError("Fictional tariff was rejected by the price verifier")
    verified = datetime.now(timezone.utc) - timedelta(days=age)
    return e.DisplayClinicPrice(
        clinic_name=name, city=city, procedure_canonical="botox",
        procedure_display_name="Botox", price_min=evidence.price_min,
        price_max=evidence.price_max, currency=evidence.currency,
        qualifier=evidence.qualifier, unit=evidence.unit,
        source_url=url, source_host=e.host_of(url),
        official_website=f"https://{host}/", source_type="official_clinic",
        evidence_type=kind, clinic_own_price=owned,
        city_match=e.strong_local_page_evidence(html, text, city, url),
        identity_verified=True, confidence=confidence,
        raw_procedure_text=evidence.raw_procedure_text,
        raw_evidence=evidence.raw_evidence,
        procedure_detail=e.procedure_detail(
            evidence.raw_evidence, "botox", evidence.raw_price_text,
        ),
        official_price_found=True, official_procedure_verified=True,
        origin=origin, cache_age_days=age, last_verified_at=verified.isoformat(),
    )
