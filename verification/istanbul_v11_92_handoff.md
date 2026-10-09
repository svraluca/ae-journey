Istanbul's empty tabs had several causes: plural “Fillers injection” menu labels were missed; Bookimed's default provider profile often omitted the requested service; its treatment tabs referenced the root provider's structured address; and accepted platform menus waited for optional official-site crawling before delivery. The dedicated marketplace round also opened too few provider profiles. This update recognizes the menu wording, follows one same-provider treatment tab, preserves the provider's locality proof, opens up to eight profiles in that bounded round, and publishes valid menus while other pages are still being checked.

Two endpoints in one Botox service range now remain a range. Nested low-only price elements cannot replace the complete offer. Category pages remain discovery leads and cannot become provider-price cards. Inline bold text inside a paragraph no longer loses preceding “national average” qualifiers. In particular, Akın Şahin's retrieved ₺5,000–₺15,000 paragraph describes a Turkey average and is rejected as a provider fee. This uses general extraction and ownership rules, with no provider or price overrides.

API and worker are 0.11.92; extraction revision is e28 in Python, Flutter and Functions. A row receives e28 only when its actual source is extracted. Reading an old cache cannot stamp it as newly verified. Older rows remain refresh leads where supported, and need re-extraction before display. Flutter requires the updated backend and preserves its actual revision.

Eight Istanbul Botox providers were verified by directly fetching their public Bookimed provider menus with HTTP 200. These are published marketplace offers, not claims that the clinic's own website publishes the same tariff. Currency and service scope remain as published.

| Provider | Published Botox offer, USD | Source |
|---|---:|---|
| Dr. Hasan Duygulu – Face Aesthetics Clinic Turkey | $150–$250 | https://us-uk.bookimed.com/clinic/dr-hasan-duygulu-private-practice/ |
| Estherian Clinic | $330–$450 | https://us-uk.bookimed.com/clinic/estherian-clinic/ |
| Trustmed Clinic | $200–$500, Botox for men | https://us-uk.bookimed.com/clinic/trustmed-clinic/ |
| Medipunto Clinic | $150–$350 | https://us-uk.bookimed.com/clinic/oezel-okmeydani-hastanesi/ |
| Dr. Kadri Akinci Plastic Surgery Clinic | $250 | https://us-uk.bookimed.com/clinic/dr-kadri-akinci-plastic-surgery-clinic-ai/ |
| Happy Esthetic Clinic | $160–$280 | https://us-uk.bookimed.com/clinic/happy-esthetic/ |
| Blanc Clinic&Beauty | $150–$300 | https://us-uk.bookimed.com/clinic/blanc-clinic/ |
| Grand Clinic | $470 | https://us-uk.bookimed.com/clinic/grand-clinic/ |

The captured source pages passed the Python discovery engine and complete Flutter validator for the actual six tab queries: Botox 8, Fillers 3, Peels 2, Rhinoplasty 1, Breast Augmentation 2 and Hair Transplant 1. The hair offer is FUT and retains that scope. Detailed URLs, literal evidence, actual capture times and HTML hashes are in `istanbul_published_menus_v11_92.json`. This audit is test evidence, not a production seed list. The tests change their replay clock explicitly; the original capture time is retained in the audit.

An isolated development SQLite cache populated with those captured rows served all six `/price-index` requests in approximately 7–78 ms. Botox retained eight rotation candidates while showing four. Other tabs showed their smaller verified pools. A display limit of eight returned HTTP 422. External Firestore was not changed. These numbers measure cached HTTP delivery in cloud, not fresh city discovery or physical iPhone rendering.

Validation: Python 159/159 and Functions 326/326 passed; focused Flutter 74/74 passed. Full Flutter: 787 passed, the same 14 baseline failures, no new failures. Changed Dart analysis: zero errors, existing unused/style diagnostics remain. Full details and the cache smoke report are in `istanbul_published_menus_v11_92_validation.json`. Production Functions, the Mac LaunchAgent and the iPhone were not updated in cloud.

Copy this task to Cursor on the Mac:

```text
Integrate GitHub main's Istanbul published-menu fixes: API/worker 0.11.92, extraction e28. Preserve .env and all local hunter, city-table and cosmetic-scope edits; merge overlapping changes without resetting the working tree. Read verification/istanbul_v11_92_handoff.md and the accompanying source audit and validation JSON files.

Inspect the LaunchAgent's actual runtime path and sync the complete reviewed Python package, including its existing dependencies and vertical-search modules. Preserve that runtime's .env. Restart only that LaunchAgent and fully restart Flutter. Confirm the exact endpoint used by the phone reports /health version=0.11.92, worker_version=0.11.92 and price_extract_revision=e28. Hot reload alone does not update Python.

Use the existing source-refresh flow to re-extract stale saved rows, and then run normal live discovery for all six Istanbul tabs. Do not relabel old rows e28, import audit prices into production, delete whole collections or relax ownership/location rules to fill four cards. Display valid published provider offers as soon as they arrive, even if there are fewer than four. Preserve their source links, currency, ranges, dosage/area and hair technique. Confirm cached tab restoration works immediately while enrichment runs in the background.

Verify that discovered Bookimed provider profiles expose treatment-specific menus, including Fillers injection, and that their own structured locality survives the root-profile/treatment-tab handoff. Confirm marketplace prices are labeled with their platform; category averages, unrelated clinic menus, foreign providers and Turkey-wide estimates must remain excluded. Akın Şahin's 5000–15000 TRY average must not return as his verified fee. Retain correct public provider names and English procedure display from the prior update.

Run Python and Functions regressions and the focused Flutter tests, including explore_published_menu_replay_test.dart, explore_istanbul_delivery_test.dart, explore_price_index_test.dart, explore_compare_hybrid_contract_test.dart and explore_tab_restore_and_qualifier_test.dart. Separate the 14 documented baseline Flutter failures from new failures. Check cold discovery time, time to first card, database cache reads, scrolling and loaded-tab restoration on the phone; use USB profile mode for frame timings when available. Report remaining timeouts with their actual exception and rejected-row reasons.

Check production Functions extraction revision separately. If the app uses an older deployed extraction path, prepare and validate only the affected getExploreProcedurePrices, verifyExploreCandidates and scheduledExploreCandidateVerify deployment. Deploy within existing session authorization; otherwise present the concrete reviewed deployment for approval as the final step. Do not claim the production path has been updated based on local /health alone.

Finish with the integrated commit, actual API/worker/extraction versions, live per-tab counts and source URLs, cache/phone timings, test results, deployment status and remaining limitations. Include a copyable Cursor prompt after the task.
```
