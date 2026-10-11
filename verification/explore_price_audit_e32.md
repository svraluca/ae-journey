# Price review and tab stability — 0.11.96 / e32

Actual public pages checked on 11 October 2026. No production Firestore writes,
Firebase deployment or physical-phone test was performed. Audit URLs and amounts
are receipts only: production does not import them or contain Istanbul-specific
price overrides.

## Prices in the screenshots

“Matches” means the named source publishes the matching treatment fee, not that
the clinic confirmed a personal quote. Duplicate extraction adapters are not
counted as additional clinics.

| Provider / treatment | Live source finding | Decision |
|---|---|---|
| Euro Istanbul / fillers | [Own treatment page](https://www.euroistanbul.com/fillers-injection/): €350 for one area; additional-area charge is separate | Matches the €350 card |
| Quartz / fillers | [Bookimed menu](https://us-uk.bookimed.com/clinic/quartz-clinique/procedure=fillers-injection/#prices): $350; own operation record updated 25 September 2026 | Matches the $350 marketplace card |
| Veysel Özcan / fillers | [Bookimed menu](https://us-uk.bookimed.com/clinic/veysel-ozcan-muayenehanesi/procedure=fillers-injection/#prices): $360–$440; own record updated 12 March 2025 | Published, but excluded by the dated-fee policy |
| Elixirmed / fillers | [Bookimed menu](https://us-uk.bookimed.com/clinic/elixirmed/procedure=fillers-injection/#prices): $840.99–$1,681.99; own record updated 8 February 2025 | The platform publishes it; it is not an invented extraction. Exclude the dated record from new verified results |
| EstePera / lip filler | Screenshot shows ₺10,000–₺15,000; its source URL is truncated and not supplied | Not verified here; source link requested |
| Clineca / rhinoplasty | [Official pricing](https://www.clineca.com/pricing): €2,500–€3,800 on the current page | Preserve both range endpoints; discard neighboring “4,800” from the title |
| Istanbul European Clinic / rhinoplasty | [Own treatment menu](https://istanbuleuropeanclinic.com/treatment-prices-turkey/): €2,300 | Matches the €2,300 card |
| Quartz Clinique / rhinoplasty | [Price article](https://www.quartzclinique.com/burun-estetigi/): ₺75,000–₺150,000 is a citywide example; says exact fees are not published online | Reject as an unowned market estimate |
| Nişantaşı Hastanesi / rhinoplasty | [Article](https://nisantasihastanesi.com.tr/burun-estetigi/): ₺40,000–₺380,000 is an expected range | Reject as an indicative estimate |
| Gökhan Beyhan / Botox | [Official price page](https://www.gokhanbeyhan.com/en/botox-prices-istanbul): from €100; area-specific menu prices | The €100 starting card matches. This does not establish the separate ₺7,500 card |
| Dr. Akın Şahin / Botox | [Actual redirected article](https://drakinsahin.com/botoks-fiyatlari/): ₺5,000–₺15,000 is a nationwide average | Reject as a provider fee; “Dra Kinsahin” was a domain-derived name |
| Euro Istanbul / Botox | [Own treatment page](https://www.euroistanbul.com/botox-injection/): €250 for one area | Matches, with the one-area scope preserved |
| Dr. Attila Aydin / fillers | WhatClinic returned EUR here, while the user's server returned RON; the page has a viewer country selector | Do not infer an original clinic currency or reverse an exchange rate. Follow an actual official-site link to seek an original fee |
| Lokman Hekim / chemical peel | [Bookimed price section](https://us-uk.bookimed.com/clinic/lokman-hekim-istanbul/procedure=chemical-peel/#prices): $2,735; own record updated 15 January 2025 | **Keep, per the user's explicit instruction**, without rewriting its source date |

Seçkin Ulusoy, Kemal Caner Delioğlu and A. Kadir Kilimcioğlu pages were denied by
this environment's network proxy. Their fees are **not live-confirmed here**.
The user's supplied country/city estimates are covered by generic ownership
regressions, but those tests are not a claim to have fetched these pages.

Full captured amounts, dates, reasons, URLs and response hashes are in
[card_price_sources_e32.json](card_price_sources_e32.json). Older e31 receipts
remain historical; their prices were not re-stamped as current evidence.

## What changed

- Ordinary procedure/city returns restore the same eligible cards in the same
  order. New providers do not replace valid displayed providers during a
  background update. Explicit refresh can request a new selection; invalid
  evidence can still remove a card.
- Python, the worker, Functions and Flutter use e32 together; minimum Python
  runtime is 0.11.96. Reading an e17/e31 price cannot promote its stamp to e32.
  A catalog with a missing extraction stamp also requires a source check.
- An explicit marketplace fee update date survives extraction, DTOs and caches.
  Checking a page today does not renew a price dated in 2025. The dated-fee policy
  rejects explicit dates older than 365 days; an undated fee remains undated.
- `source_price_date_basis: user_retained_published_fee` provides a generic,
  per-row retention policy for the user-approved peel. It does not bypass
  procedure, source, locality, literal amount or extraction-revision checks,
  and does not allow invalid/future dates. The extractor never invents this flag.
- Market tables, city starting prices and indicative article ranges cannot
  acquire provider ownership merely because the page belongs to a doctor.
  Clineca's full range cannot become a truncated €2,500 exact price.
- WhatClinic's actual country-selector markup identifies viewer-localized
  prices. Those numbers are leads to an independently published original fee,
  using actual outbound website/navigation links rather than guessed domains.
- Searching can continue after four visible cards to build a reusable pool.
  Partial candidates accumulate beyond the display limit; displays remain capped
  at four. Explicit Find more resumes collection; warm-up work cannot downgrade
  its priority or discard preserved partial results.
- The source subtitle under amounts is removed; the location/domain row still
  opens the source. Mixed currencies do not produce a misleading single-currency
  “Typical range.” English titles strip unrelated leading amounts while retaining
  meaningful dose, area and product details.

## Uploaded archives

Both uploaded archives still use e31 / minimum runtime 0.11.95. Meaningful upload
changes include sale/former-price binding, Turkish city-table markers, Q&A portal
exclusion, cosmetic Botox scope and approximate-section handling; much of the
OpenAI service diff is formatting. They are not evidence of a deployed backend.

The uploaded Flutter currency rejection guessed country ownership from a list of
currencies and destinations, and its city-price rejection names Istanbul/Ankara.
This patch instead uses actual marketplace selector evidence and generic fee
ownership wording. The archives were compared, not blindly copied over newer
repository work. Do not overwrite this patch with those older e31 files.

## Firestore: what to change

**Installing e32 on all tiers is the primary fix.** Old price rows become
ineligible without deleting the clinic directory. Deleting caches alone cannot
fix an extractor that accepts general estimates again.

I cannot inspect actual document IDs in your production database. The manifest
[istanbul_price_cache_review_e32.json](istanbul_price_cache_review_e32.json)
contains **possible IDs generated from your code's exact key formulas**, including
the Istanbul Place ID, both city spellings, procedure aliases and older revisions.
It is not a database scan or a deletion command.

1. Preserve the approved peel first. In existing matching
   `explore_google_prices` peel documents, merge the price/evidence/provenance
   fields from `app_row` in
   [user_retained_peel_e32.json](user_retained_peel_e32.json) into the **Lokman
   Hekim chemical-peel row only**. Keep existing ratings, reviews, Place ID and
   coordinates. Keep its actual 2025 source date and explicit retention basis.
   This is a fresh source recheck, not permission to restamp other old prices.
   If retained in `aesthetic_price_results`, merge the matching `python_row`
   price evidence into that offer's `result` and preserve its other identity
   metadata. Do not delete the whole peel cache document.
2. In `explore_google_prices`, inspect the matching document's **`clinics`
   array**. Remove/zero disputed price fields from old rejected rows, preserving
   identities and URLs for re-verification. This includes dated Elixirmed/Veysel
   offers and the unowned rhinoplasty examples above. Never globally delete a
   provider that has a valid tariff for a different treatment.
3. In `ai_cache`, comparison cards are under **`result.clinics`**. Remove the
   corresponding invalid rows in the matching comparison documents. Preserve
   the retained peel row or replace its price fields with the fresh receipt.
4. In `aesthetic_price_results`, filter **`city_key == "istanbul"`** and the
   appropriate `procedure_canonical` / `search_key`. For rejected offers set
   **`active: false`**. Preserve legitimate and explicitly retained offers.
   Actual offer document IDs are hashes, so do not guess them.
5. `clinic_price_catalog` is keyed by source host and stores an **`evidence`
   array. Remove only disputed tariff evidence if needed; leave provider URLs.
   A Bookimed/WhatClinic host catalog can span many cities and providers.
   e32 refuses catalogs with an old/missing revision until a fresh scrape.
6. Check `explore_curated_prices` only if the disputed source/amount was manually
   seeded there; remove that price row. `explore_python_price_staging` is audit
   evidence, not a Flutter display store; clearing it alone will not change cards.

Leave `explore_clinic_candidates`, `clinic_site_urls`, clinic identity/directory
collections and users/favorites alone. Restart the app completely after updating
code; a hot reload can preserve already-painted in-memory cards.

## Verification and limits

- Python: **241 tests passed**.
- Functions: **345 tests passed**.
- Flutter: **78 focused tests passed**, covering tab stability, retention/DTO
  provenance, titles, mixed currencies, old receipt rejection, saved-price
  loading and hybrid display. This is not the full Flutter test suite.
- Flutter analysis reported no errors; it exits nonzero on warning/info findings
  in the inspected files. It is not a clean lint pass.
- Real restarted API `/health`: runtime and worker **0.11.96**, extract **e32**.
- Actual HTTP `/discover` re-fetched the supplied Euro Istanbul filler page and
  returned its €350 fee as e32. This cold request took **14,019 ms**; it is not
  evidence that discovery latency is solved or that all tabs have four clinics.
  See [e32_http_source_smoke.json](e32_http_source_smoke.json).

No Serper/Exa/Places credentials were available for an unseeded eight-clinic
search. The live audit checks page reading and price attribution; it does not
establish cold search coverage, eight verified Botox providers, four original-
currency prices for every tab, or a production deployment.
