# Cursor handoff — Explore 0.11.96 / e32

Copy this instruction into Cursor after pulling the completed patch:

```text
Use the current 0.11.96/e32 patch as the source of truth. Do not overwrite it
with the uploaded e31 Archive.zip or functions.zip. Preserve the local .env.

Deploy the changed Explore Functions in this project's configured Firebase
project, using its existing deployment configuration. Copy/sync the Python
package, including the NEW marketplace_price_freshness.py alongside
aesthetic_price_discovery_v11_67.py, explore_index_jobs.py and vertical_search.py.
Restart the Python API and worker/LaunchAgent. Confirm /health reports BOTH
version and worker_version 0.11.96 and price_extract_revision e32.

Keep the user-requested Lokman Hekim $2,735 chemical-peel card. Use the freshly
checked row in verification/user_retained_peel_e32.json to update only its
price/evidence/provenance fields in matching price-cache rows. Preserve existing
Maps identity, ratings and coordinates. Keep its actual 2025-01-15 source date
and source_price_date_basis=user_retained_published_fee. Do not simply relabel
other old extraction stamps as e32.

Follow verification/explore_price_audit_e32.md for selective Firestore review.
verification/istanbul_price_cache_review_e32.json contains possible document
paths generated from the app's key formulas; it is not a production DB scan.
Do not delete entire clinic directories, platform host catalogs, favorites or
the whole peel cache document. Invalid old price rows should require source
verification; correct clinic identities and source URLs should remain reusable.

Stop and launch Flutter afresh. Ordinary tab returns must restore the same
eligible clinics and order. Explicit Find more may change selection; a verified
new tariff may update a price, and invalid evidence may remove a card. Prices
must retain their original currency with no source subtitle under the amount.

Check Fillers -> Botox -> Fillers and Rhinoplasty -> Peels -> Rhinoplasty.
Verify source/procedure ownership rather than comparing solely with Google
AI summaries. Do not force four cards when four justified prices are unavailable.
No Istanbul-specific clinic/price list belongs in runtime code.

This patch was not deployed to production by Codex. Cold search coverage with
your configured Serper/Exa/Places credentials still needs validation. The real
known-source HTTP smoke test took 14 seconds, so do not claim cold discovery is
instant or that every tab has four verified providers.
```

Verified here: Python 242/242, Functions 346/346, focused Flutter 79/79, and
actual public-page source audits. The local API and worker run 0.11.96/e32.
Analysis had zero errors but warning/info findings; it is not a clean lint pass.
See [the source audit](explore_price_audit_e32.md) for confirmed, dated, rejected
and inaccessible prices. EstePera's exact source link remains requested.
