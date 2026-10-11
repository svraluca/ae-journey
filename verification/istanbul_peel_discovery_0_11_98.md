# Istanbul chemical-peel coverage — 0.11.98 / e33

The source audit on 11 October 2026 found seven medical providers with a
published chemical-peel price listing. This does **not** establish seven fees
eligible under the user's original-currency preference: two provider menus
qualify, four WhatClinic menus expose viewer-localized currency, and one
Bookimed menu has ambiguous treatment scope. No prices, provider list, or city
list was added to application code.

## Sources checked

| Provider and exact source | Published listing | Eligibility |
| --- | --- | --- |
| [Lokman Hekim Istanbul](https://us-uk.bookimed.com/clinic/lokman-hekim-istanbul/procedure=chemical-peel/) | $2,735 | Accepted provider menu; preserved fee date 15 January 2025 |
| [Memorial Bahçelievler](https://us-uk.bookimed.com/clinic/memorial-bahcelievler-hospital/procedure=chemical-peel/) | $150–$300 | Accepted provider menu; preserved fee date 22 May 2025 |
| [Dr Siyamek Saleki](https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/sariyer/dr-siyamek-saleki-esthetics) | €800–€900 as rendered | Original clinic currency unverified; description mentions enzymatic pigmentation treatment |
| [Dr Faruk Akçadırlı](https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/besiktas/dr-faruk-akcadirli-clinic) | €109–€145 on profile | Original clinic currency unverified; directory rendered €108–€144, illustrating conversion/rounding drift |
| [Dr Ebru Söylemez](https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/kadikoy/dr-ebru-soylemez) | €100–€200 as rendered | Original clinic currency unverified; menu also specifies 30 minutes |
| [Dr İ. Öykü Maraşoğlu Çelen](https://www.whatclinic.com/hair-loss/turkey/istanbul-province/istanbul/dri-oyku-marasoglu-celen) | €250–€350 as rendered | Original clinic currency unverified; menu specifies 45 minutes. Separate Cleopatra peeling €250–€400 is not the same generic fee. |
| [Quartz Hospital](https://us-uk.bookimed.com/clinic/quartz-clinique/procedure=chemical-peel/) | $2,200 | Rejected for ambiguous service scope; descriptive text separately says approximately $2,400. Do not silently replace it with that estimate. |

Each linked page returned HTTP 200. These amounts match published third-party
listings; the audit does not confirm a personalised or direct clinic quote.
Pervin Dinçer Beauty Consultancy Bakırköy also renders €12–€45, but is a beauty
consultancy and is not counted as a seventh medical clinic.

[istanbul_peel_coverage_0_11_98.json](istanbul_peel_coverage_0_11_98.json)
records source hashes, price evidence, original-currency eligibility and source
dates. Overall, 76 provider profiles were requested: 70 returned HTTP 200 and
six additional WhatClinic profiles returned HTTP 429. Among the 49 readable
additional WhatClinic profiles, no further chemical-peel fee was extracted.
No repeated requests were used to evade the rate limit.

## Why the app shows two

The supplied Flutter log shows two usable e33 saved rows, a foreground job,
the broad English and Turkish queries, and then marketplace search. It ends
while that search is still running; it is not a completed-search receipt.
`serper=0` alone cannot establish missing credentials: cached searches can
avoid new paid requests.

The previous directory crawl stopped after the first page plus two next
pages. Ebru and Çelen appear on pages indexed 3 and 4, so it missed their
priced listings. The previous progressive search spent up to four requests
on broad English, broad local and two marketplace searches. Its existing
BioRePeel/PRX/TCA recognition did not produce variant queries.

Even when fetched successfully, WhatClinic pages contain a country selector
and viewer-converted prices. The exact live endpoint diagnosis is
`marketplace_original_currency_unverified`; this explains why the four doctor
menus do not become original-currency comparison cards. The linked profile
pages in this audit do not expose an independently verified original fee.
Forcing Turkey's viewer setting or converting EUR back to TRY would not prove
what the provider originally entered.

## Implemented retrieval changes

- Follow actual same-category next links through at most five pages. Sort
  explicitly priced provider leads first; fetch each provider profile to verify
  its treatment row. Directory starting prices never become provider fees.
- When chemical-peel discovery falls short, add two grouped queries after the
  existing lanes: TCA/glycolic acid/salicylic acid and BioRePeel/PRX-T33/Cosmelan.
  The requested city comes from the request. Broad search remains first.
- Chemical peels have a default maximum of six paid requests instead of four.
  An explicit caller budget, including requests already spent, remains a hard
  ceiling. Other families retain their four-request policy. Stop once the goal
  is met; named variants are not searched unnecessarily.
- Exclude Trustpilot, including its subdomains, from clinic website resolution.
  Its footer link was consuming an original-source lookup slot.

Named queries are discovery leads, not automatic fee approvals. Retail
Cosmelan kits, body treatments, unrelated lasers, market estimates and
unverified original currencies retain their existing scope/evidence checks.
The generic Peels tab does not imply that all peel depths, products and
packages are directly comparable.

The strongest retrieval method is directory-to-provider-menu navigation,
followed by a real linked clinic website and its own tariff when available.
Named-treatment searches broaden official-source discovery where those links
are absent. This implementation does not promise seven original-currency
cards before that independent evidence exists.

## Validation and rollout

- Python: 105 focused discovery/extraction regressions passed.
- Flutter: 20 focused tool, peel extraction and price-date/currency tests passed.
- Actual `/health`: API and worker 0.11.98, extraction e33.
- Actual directory-only `/discover`: HTTP 200 in 9.13 seconds; five category
  pages expanded and ten provider leads reached, including the page-four
  priced doctor. Zero eligible prices returned because of the original-currency
  policy. This measures a known-directory request, not paid cold Google search.
- An offline integration test proves seven independent provider profile menus
  can be reached across five linked pages without copying directory amounts.
  Its seven fees are fixtures, not seven live original-currency results.

See [peel_directory_http_0_11_98.json](peel_directory_http_0_11_98.json) for
the actual HTTP result and structured trust rejection samples. Paid unseeded
Google/Exa search was unavailable in this cloud runtime. No production
Firestore write or Functions deployment was performed. Extraction remains
e33 because the price-verification policy is unchanged.

For the Mac, use local Codex in Cursor to update the existing repository from
origin/main while preserving local commits, guards, secrets and any unresolved
merge. Read this document and sync the Python package to the actual runtime
named in `~/Library/LaunchAgents/com.glowpass.aesthetic-price-discovery.plist`.
Restart that existing LaunchAgent and restart Flutter. Verify the running
`http://127.0.0.1:8080/health` reports **both versions 0.11.98 and revision e33**.
The app now requires backend 0.11.98. Merely pulling code without updating the
LaunchAgent's runtime will leave the old crawler running. Re-run Peels and
inspect the `subtypes` stage and trust rejection details. Do not bulk-delete
Firestore or restamp old rows to increase the card count.
