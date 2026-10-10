# Marketplace discovery fixes — 0.11.95 / e31

Verified on 10 October 2026. These changes use platform markup and procedure
taxonomy for any city. Audit URLs and amounts are test evidence only; production
does not import these receipts or contain Istanbul/provider/price overrides.

## What was wrong

- WhatClinic returned HTTP 403 (`Client-OldBrowserSpam`) for the obsolete
  Chrome 126 User-Agent. The same public pages returned HTTP 200 with the
  truthful Python HTTP client identity. The client now identifies itself
  correctly. Genuine access refusals remain failures, with no identity rotation.
- Category expansion took arbitrary anchors. Navigation to other treatments
  consumed the profile shortlist before the actual clinic cards were reached.
  Expansion now reads bounded provider cards, prioritizes those listing a
  matching tariff, and follows at most two additional published Next links.
- Marketplace search favored a few indexed individual profiles. It now searches
  the platform's actual procedure category; the returned URL supplies the local
  country/province/city hierarchy. Saved category URLs and Exa category leads
  can also enter discovery. The four paid-query allowance is unchanged.
- Generic whole-page parsing admitted patient reviews (`Paid: €25`) and could
  attach a neighboring service's fee to an unpriced treatment. WhatClinic now
  uses each provider's own named menu row or structured Offer and its own price
  container. Reviews, directory averages and unfetched search snippets cannot
  certify fees. An upper-bound-only quote is excluded rather than shown as exact.
- Districts in `addressLocality` were rejected even when the provider's own
  PostalAddress and actual geographic profile hierarchy proved the city.
  These fields now work together. A foreign locality or city-named street
  cannot override the provider's address. No district list was added.
- Travel intermediaries could appear as treating clinics. Explicit agency
  descriptions are excluded; a clinic offering transfers remains eligible.
- Python counted two implausible surgical totals as usable while Flutter
  rejected them. Generic procedure/currency rejection bands now agree, including
  explicit per-graft and Botox per-unit scope. No published amount is converted,
  clamped or replaced. Invalid cached rows cannot count toward display readiness.

## Elixirmed receipt

The fetched Bookimed profile literally publishes **Fillers injection
$840.06–$1,680.11**. The screenshot's $840–$1,680 label truncates the decimals.
The source says **Last price update — 29.03.2025**; this is a dated marketplace
fee, not an official clinic-site fee or a personalized quote. Expand Aesthetic
Medicine and Cosmetology in the profile's treatment-price section.

The source action now points to the existing `#prices` anchor in the same
document that supplied the fee. It does not switch to an unfetched treatment
tab: that separately fetched tab published slightly different USD amounts.
The exact quotes and current engine recheck are retained in
`elixirmed_published_price_receipt_v11_95.json`.

## Real live checks

`whatclinic_fillers_http_v11_95.json` records an actual HTTP NDJSON request to
the restarted Python service, using `serper_first=true` as the app's discovery
worker does. The only supplied lead was the user's WhatClinic directory URL.
It discovered a pool of **five** Istanbul providers and displayed **four**:
first card **1,102 ms**, fourth **2,490 ms**, completion **3,203 ms**.
Partials accumulate and stay capped at four. No supplied provider URLs or
fees, mocked search/fetch, or external database access were used.

`whatclinic_fillers_hybrid_v11_95.json` independently records the same real
hybrid function for both cities: Istanbul five providers/four display cards;
Ankara two providers/two display cards. Every fee was re-fetched from the
individual provider menu. Its earlier measured times remain in that receipt.

The final bounded category-only audit in `whatclinic_six_tabs_v11_95.json`
tests all twelve city/procedure combinations through real `discover()` and
the production display composer. It found **49 accepted offers** on **36
distinct provider profiles**. All exact evidence/amount/currency tuples were
independently matched to freshly fetched menus and replayed through the full
Flutter comparison worker. The pool counts are:

| Procedure | Istanbul pool | Ankara pool |
|---|---:|---:|
| Botox | 1 | 0 |
| Fillers | 5 | 2 |
| Chemical peel | 3 | 0 |
| Rhinoplasty | 7 | 6 |
| Breast augmentation | 7 | 6 |
| Hair transplant | 6 | 6 |

Displays cap at four distinct providers. This audit starts at one actual
WhatClinic category per case and checks a bounded profile shortlist. It is
neither exhaustive city coverage nor the combined official-site/Bookimed
search. Generic Treatment for Wrinkles fees require injectable evidence in
their own offer; that category label alone is insufficient for Botox. Sparse
counts do not authorize guessing another fee.

Two previously observed Ankara quotes remain in the revalidation history:
€290–€544 rhinoplasty and €18–€45 FUE without a per-graft unit. Final discovery
excludes them under the app's existing full-procedure amount rules.

## Validation and runtime

- Python: **209/209** tests passed, including cold-category orchestration,
  directory/profile ownership, review leakage, locality, access and amount gates.
- Functions: **330/330** tests passed.
- Focused Flutter: **129/129** tests passed, including all 49 live rows,
  twelve city/tab replay cases, old-revision rejection, loading, English titles,
  source locality, exact ranges and the four-card cap.
- Flutter analysis: **zero errors**, 82 warnings and 193 informational findings
  across the repository. This is not a claim that the repository is lint-clean.
- Local `/health`: `ok=true`, `version=0.11.95`,
  `worker_version=0.11.95`, `price_extract_revision=e31`.

The cloud process has no bound `SERPER_API_KEY`. Actual HTML access, directory
expansion, profile fees and live streaming were tested; unseeded paid Google
search was covered by an offline orchestration test, not a live cold benchmark.
The environment draft preserves the secure credential requirement. It must be
bound in environment settings and published before that cloud benchmark can run.
No production Firebase deployment or user Mac/phone restart was performed here.

Reproduce the directory-to-profile hybrid check using the configured Python:

```sh
python scripts/audit_explore_prices.py \
  --city Istanbul --country TR --procedures filler \
  --directory-url https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/dermal-fillers \
  --output verification/local_istanbul_fillers_directory.json
```

For live unseeded six-procedure discovery, use existing secure local credentials
and omit both `--directory-url` and `--source-audit`; repeat with `--city Ankara`:

```sh
python scripts/audit_explore_prices.py \
  --city Istanbul --country TR --env-file .env \
  --output verification/local_istanbul_cold.json
```

The CLI disables external database access and prints credential presence only.

## Cursor prompt

```text
Sync latest GitHub main containing 0.11.95/e31. Preserve my .env, local hunter
edits and uncommitted work. Read verification/whatclinic_v11_95_handoff.md.

Sync the complete Python package into the actual hunter/LaunchAgent runtime,
including amount_policy.py, vertical_search.py and explore_index_jobs.py.
Restart that configured service. Confirm /health version and worker_version
are both 0.11.95 and price_extract_revision is e31. Restart Flutter with the
updated client. Check the deployed Functions revision and report/apply any
required e31 synchronization through the existing deployment workflow.

Using existing secure credentials, run scripts/audit_explore_prices.py for all
six Istanbul procedures without directory/source-audit inputs, then Ankara.
Separately run the documented directory-URL test to distinguish Google search
failures from HTML access and extraction. Do not import audit fees as seeds,
add provider/city/price overrides, weaken verification, or stamp old amounts e31.
Old cached prices need a real source recheck; retain their URLs as leads.

Check actual app tabs: cached verified cards paint promptly; verified partials
accumulate; displays stay at four distinct providers; English titles preserve
subtype, original evidence, currency and range; source buttons open the exact
verified document. Label WhatClinic/Bookimed fees as marketplace prices.
Record first/fourth-card times, usable provider counts, exact rejection reasons
and API/worker/Functions revisions. Distinguish a verified-price shortfall from
request failures. Give me a copyable Cursor prompt after each finished task.
```
