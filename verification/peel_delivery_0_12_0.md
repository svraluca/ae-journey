# Peel cards and reusable partial results

The supplied 0.11.99 log showed zero usable saved rows followed by two verified
Bookimed peel fees. Its foreground search was still processing broad English
and Turkish pages. The earlier source audit found four additional doctor menus
on WhatClinic, but their viewer-converted currency failed the original-currency
policy. They were discovery leads, not seven eligible original-currency quotes.

The user now explicitly permits published WhatClinic conversions with a note
in card details. Release 0.12.0 implements that preference and reduces waiting:

- WhatClinic HTML containing its real currency selector receives the distinct
  `platform_converted` provenance marker. The HTTP reader uses the site's
  documented country cookie `cc=fr` for a consistent EUR viewer presentation.
  These amounts are not relabeled as the clinic's original currency.
- Converted fees require WhatClinic provider URLs and EUR. An uncontrolled RON
  response or a conversion marker on another platform remains ineligible.
  Old `viewer_localized` rows still need a source recheck.
- Tapping a converted card's amount opens Price details with the conversion
  explanation and source link. No price-source subtitle is added below it.
- Sparse peel searches reach marketplace provider menus immediately after
  saved-source checks. Ordinary English, local-language and named-peel searches
  remain available within the same request ceilings. Location is request data.
- The serving index reuses accepted partial results from running or paused
  durable jobs. All rows still pass evidence, locality, scope and quarantine
  checks. Firestore results are merged with those local partials.
- Flutter saves accepted partials before the full crawl completes. Subsequent
  loads can use that saved evidence. A visible card list does not show a
  “Checking more” spinner or rebuild its map for hidden page counters.
  New accepted cards continue to arrive through the comparison callback.

Existing ownership, product, package, locality, literal-amount and source-date
checks remain active. Price publication dates have no maximum-age rule.
Extraction remains e34: existing e34 native-currency fees retain eligibility,
including the user-retained $2,735 menu, without rewriting historical stamps.
The new conversion marker retains the reason these additional fees differ.

## Actual source delivery

The known-directory `/discover` request returned HTTP 200 in 9.7 seconds with
five WhatClinic provider menus. Four are doctor menus; one is Pervin Dinçer
Beauty Consultancy. The four doctor listings were:

| Provider | Published EUR viewer amount |
| --- | --- |
| Dr. Ebru Söylemez | €100–€200 |
| Dr. Faruk Akçadırlı | €109–€145 |
| Dr. İ. Öykü Maraşoğlu Çelen | €250–€350 |
| Dr. Siyamek Saleki | €800–€900 |

[whatclinic_peel_delivery_0_12_0.json](whatclinic_peel_delivery_0_12_0.json)
contains the exact provider links, fee evidence and conversion provenance.
All five actual response rows passed the full Flutter worker validator and
retained the conversion explanation. This demonstrates directory-to-card
delivery; it is not an unseeded paid Google search benchmark, an iPhone timing
measurement, or a confirmation of personal clinic quotes.

## Mac rollout

Validation: 131 selected Python regressions, all 42 Functions test files
(362 tests), and 52 Flutter tests passed. The live source receipt passed the
full client worker validator. Targeted Flutter analysis found no errors;
existing nonfatal warnings remain in the comparison screen.

Use local Codex to merge origin/main into `/Users/elenaraluca/Desktop/GlowPass`,
preserving local commits, changes, secrets and Hunter guards. Fast-forward-only
pulls cannot update a diverged branch. Update the actual Python runtime named in
the existing LaunchAgent and restart it; restart/rebuild Flutter too. Health
must report API and worker **0.12.0**, extraction **e34**. The new Flutter client
requires backend 0.12.0. Deploy the changed Functions verifier separately if
that path is used. No production Firestore cleanup or database deletion is
required for this update, and no production deployment was performed here.
