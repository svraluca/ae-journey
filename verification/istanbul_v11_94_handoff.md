# Global published-price discovery fixes — 0.11.94 / e30

Verified on 10 October 2026. These changes apply to every city; the Istanbul
sources below are diagnostic fixtures, never production seeds or price overrides.

## Why ordinary Google searches succeeded while the program missed pages

- In sparse markets, two marketplace queries and two local-language queries
  exhausted the four-request allowance before the basic English
  `procedure + location + price` query ran. The new order reserves English,
  local-language and provider-menu searches within the same allowance.
- Custom product headings, sale-price classes and single-surgery all-inclusive
  packages were missed or rejected together with combined surgical packages.
  Bounded DOM adapters now preserve the current fee, original fee, full title
  and qualifications. Combined surgeries and non-surgical substitutes remain
  excluded.
- A provider's own named fee could be lost inside a paragraph that also gave
  general market estimates. The extractor now binds the named own-price clause
  separately; market comparisons remain excluded.
- Large HTML pages were repeatedly parsed concurrently. Marketplace name and
  address parsing also ran on the event loop. Request-local visible-text reuse,
  bounded document processing and off-loop identity/location parsing allow
  verified partials to arrive before the full collection finishes.
- The saved-page timeout discarded unfinished URLs. They now continue into
  the next bounded stage. Saved URLs retain their caller-supplied order instead
  of being displaced by keyword-rich marketplace profile URLs.
- Each stage's first partial replaced earlier verified cards. Partials now
  combine the accumulated verified pool and enforce the four-card display cap.
- Debug response construction indexed a four-label list with five or six
  stages, raising `IndexError` after successful extraction. Stage labels now
  come from actual stage diagnostics and support additional rounds.
- Flutter had a second USD rhinoplasty floor of $2,500, higher than extraction's
  existing $1,500 floor. The checks now agree while preserving source, scope
  and locality verification.

## Live evidence

All checked screenshot domains returned HTTP 200. Search snippets alone were
not used as published-price evidence. Captured URL, timestamp and SHA-256
receipts are in `istanbul_official_sources_v11_94.json` and
`istanbul_published_menus_v11_94.json`.

Four official breast-augmentation offers passed the actual Python verifier:

| Provider | Published fee | Page |
|---|---|---|
| Clineca | €3,100 | https://www.clineca.com/pricing |
| Carely Clinic | €3,450 promotional all-inclusive package | https://carelyclinic.com/all-inclusive-breast-augmentation-turkey-package/ |
| Euro Istanbul Clinic | €4,200 all-inclusive package | https://www.euroistanbul.com/breast-augmentation-package/ |
| HayatMed Clinic | from €4,250 | https://www.hayatmed.com/blog/breast-augmentation/breast-augmentation-surgery-cost/ |

Official rhinoplasty offers: Clineca €2,500–€3,800; Carely €2,850 promotional
all-inclusive package; Euro Istanbul €3,250 promotional all-inclusive package.
Each audit row preserves its exact source URL and qualifications.

Independent source-page audit counts:

| Procedure | Distinct providers | Official own-price fees | Provider-specific marketplace menus |
|---|---:|---:|---:|
| Botox | 14 | 0 | 14 |
| Fillers | 5 | 0 | 5 |
| Chemical peel | 2 | 0 | 2 |
| Rhinoplasty | 7 | 3 | 4 |
| Breast augmentation | 11 | 4 | 7 |
| Hair transplant | 7 | 0 | 7 |

Marketplace menus are labelled as third-party published menus, not official
clinic website fees. Currency is preserved as published. Two peel menus were
verified; the audit does not justify inventing two more. General averages,
Google AI summaries and unrelated prices cannot fill a missing slot.

Vanity's screenshot €3,000 was not found in the checked live page. The checked
Emre Ozenalp pages contained market comparisons; the checked Ali Mezdeği page
said fees were not public. These are findings about the specific checked URLs,
not claims that every page on those sites lacks fees. The exact screenshot
Mehmet Emre Dinc English claim has not been verified.

## Reproduction and validation

`istanbul_published_menus_v11_94_validation.json` records tests, live hybrid
partial timings, final counts and remaining limitations. The source-only
recheck calls the actual `_discover_hybrid_impl` used by the app, with no mocked
search/fetch and no external database writes:

```sh
python scripts/audit_explore_prices.py \
  --city Istanbul --country TR \
  --source-audit verification/istanbul_published_menus_v11_94.json \
  --output verification/local_istanbul_known_urls.json
```

For actual cold discovery, omit `--source-audit` and use the configured local
Python environment. `--env-file .env` can load an existing secret file without
printing credentials. The script disables Firestore and scheduled refreshes:

```sh
python scripts/audit_explore_prices.py \
  --city Istanbul --country TR --env-file .env \
  --output verification/local_istanbul_cold.json
```

The cloud process has no `SERPER_API_KEY`; its source rechecks are not cold SERP
benchmarks. A required secret requirement was saved in the cloud environment
draft. Supply the credential securely in environment settings and publish the
draft to enable cold-search measurements. Do not put secret values in chat,
tracked files, logs or prompts.

## Cursor prompt

```text
Sync the latest GitHub main containing the global 0.11.94/e30 discovery fixes.
Preserve my .env, local hunter edits and any uncommitted work. Read
verification/istanbul_v11_94_handoff.md and the validation JSON first.

Sync the complete Python package to the actual hunter/LaunchAgent runtime,
including vertical_search.py and explore_index_jobs.py. Restart that configured
service and confirm /health reports version=0.11.94, worker_version=0.11.94 and
price_extract_revision=e30. Restart Flutter with the updated client. Identify
the Functions extraction revision and report any production deployment gap.

Using existing secure local credentials, run scripts/audit_explore_prices.py
without --source-audit for all six Istanbul procedures, then repeat for another
city. Separately run the source-URL audit above to distinguish discovery from
extraction. Never import the audit prices as production seeds or add provider,
city or price overrides. Do not weaken ownership, locality or procedure gates
to force four cards. Preserve exact currencies, ranges and package conditions.

Check the actual app: verified cached rows paint immediately; verified partials
accumulate across stages and never disappear when another stage starts; the
display remains capped at four distinct providers. Record time to first card,
time to fourth card, final usable count, precise rejection/failure reasons and
API/worker/Functions revisions. If fewer than four survive, report the evidence
shortfall separately from request failures. Run relevant regressions after any
further changes and provide a copyable Cursor prompt after each finished task.
```
