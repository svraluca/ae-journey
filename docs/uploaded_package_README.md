# Explore v11.83 — price accuracy and bounded discovery

Prepared from the supplied sources plus the delivered v11.82 patch. **This is a reviewed source package, not an installed update to your Mac.** The backend import filename stays `aesthetic_price_discovery_v11_67.py`; API and worker report version **0.11.83**.

Read `PRICE_AUDIT.md` for every visible screenshot card and the source links. Read `CURSOR_PROMPT.md` for integration. No credentials, clinic seeds, scraped HTML, or destructive database migration are included.

## What changes

- Correct procedure/price binding in Booksy service rows; recognize trailing `+` as a starting price. Compact presentation attributes before the Flutter HTML cap so service rows survive.
- Reject consultation fees, market averages, implant-only costs, partial-rhinoplasty ranges, month-only campaigns without confirmed validity, and clinic directories. Apply the exclusions to cached rows too.
- Recognize Spanish mamoplasty and lip-filler terminology; preserve fat-transfer labels; keep Spanish attached price ranges; reject a different branch's tariff heading.
- Normalize pricing prose out of card procedure titles. Preserve original evidence text separately.
- Increase the Flutter display capacity from four to eight. Six valid cards satisfy foreground discovery. This is capacity, not a promise of eight published prices in every market.
- Load the supplied 249-country and 151-procedure catalogs once. Keep existing six procedure pills and API family keys. Preserve translated aliases already supported by the verifier.
- Add a bounded progressive policy around the existing discovery engine, behind `ENABLE_PROGRESSIVE_DISCOVERY` (default true). Existing endpoints, ownership gates, index, ratings and scheduler remain.

## Request flow and budgets

`/price-index` remains read-only and serves usable stored prices without running a crawler. `/discover-jobs` accepts a durable job independently. Partial prices are published before the whole job completes; rating enrichment remains independent in Flutter.

| Stage | Trigger | Maximum work per pass |
|---|---|---|
| Existing index | Every selection | Return usable cards; six ends foreground discovery |
| Known domains | Fewer than six | Up to six known hosts; eight HTML GETs |
| Primary Serper | Still short | Two English queries; 16 HTML GETs |
| Local Serper | Still short and multilingual/deep enabled | One configured non-English language, two queries; 12 HTML GETs |
| Exa | Still short and explicitly enabled | One semantic URL search, eight results; ten HTML GETs |
| Places | Still short after preceding stages and key configured | Two clinic-domain searches, six websites; ten HTML GETs |

Each Serper query consults the existing locale-scoped query cache before making a network request. The foreground policy does not force-refresh that cache or run hidden page-two and near-duplicate rescue queries. Total Serper allowance is four network requests per pass, or the caller's lower positive allowance. Independent primary queries run concurrently.

Fast stages allow at most 24 HTML GETs; deep stages allow at most 32 more. The existing shared HTTP pool defaults to 12 concurrent requests and a seven-second interactive request timeout. Sitemap/robots probes are excluded from these HTML limits. Already-started requests may finish after the six-card threshold; new fetch reservations stop. Static page verification and price evidence still decide whether a card is usable.

Once a Firestore-backed fast pass has six prices, the durable job may continue as a **background pass** toward the requested collection target (normally 12; policy maximum 20). The first pass has already persisted and published its prices. A thin pass below six is not immediately repeated. Background jobs retain focus/preemption behavior; logs about another pill can therefore appear while the selected pill remains visible.

## Flags and caches

| Setting | Default | Behavior |
|---|---|---|
| `ENABLE_PROGRESSIVE_DISCOVERY` | true | New policy for the app's streaming Serper-first jobs; false restores the previous cascade |
| `ENABLE_DEEP_DISCOVERY` | true | Allow local, Exa and Places rescue after the fast stages |
| `ENABLE_MULTILINGUAL_SEARCH` | true | Enable the bounded local-language stage |
| `ENABLE_EXA_RESCUE` | false | Opt into semantic rescue; requires `EXA_API_KEY` |
| `SERP_CACHE_TTL_DAYS` | 14 | Existing Firestore/in-memory URL-result cache, provider and locale scoped |

Exa only discovers URLs. Its results pass the same city, clinic identity, procedure and price verifier as Serper results. Its failures produce a provider status and allow the next stage. No Exa contents/crawl request is made. Brave/Bright Data search fallbacks are disabled within the new policy; the legacy rollback retains them.

Country resolution accepts Flutter's supplied ISO code first, then existing hints, then a cached Places resolution using structured country components or the full country catalog. It is not restricted to capital cities. Country lookups are cached for one day; unresolved lookups retry after five minutes. Ambiguous city names still need Flutter's selected country/place identity.

Rejection cache keys include city, procedure and URL. In-process TTLs: blocked five minutes; transient fetch failure one minute; no price six hours; wrong-city/market/consultation one day; directory seven days. This rejection cache is not persisted across backend restarts. Static fetch caching separately retains successful HTML for 15 minutes and blocked responses for five minutes.

## Evidence, currencies and ratings

The existing schema retains `price_min`, `price_max`, `currency`, `unit`, `qualifier`, original price fields, procedure detail, original-language evidence, evidence type, confidence, source URL and verification time. Ranges are not flattened; `from` is distinct from fixed amounts; per-unit/area/ml/session/graft basis remains separate from the total. Existing structured-offer and DOM/table/card extractors remain; the new policy does not add an LLM to page processing.

Country currency metadata supplies recognition/context. It does not reject a Turkish clinic's EUR/USD/GBP fee or convert source prices. Existing explicit-currency rules remain; ambiguous symbols are not newly inferred from the selected city. Currency matchers are compiled once.

Google Places remains the source of business ratings/review counts. This package preserves v11.82's rating lookup and later enrichment. A Google rating never validates a procedure price. Your supplied Valencia logs show successful ratings for My Medica, Ipanema, Aurora Reig and Dr. Puig. No live Places call was made with your account in this environment.

## Telemetry and checks

`[GP SEARCH]` reports city, procedure, country, stage list, background status, saved/verified counts, Serper/Exa/Places calls, fetched HTML pages and elapsed time. Job progress adds `ttfr_ms` and `time_to_6_verified_ms`; existing rejection diagnostics remain. These durations measure the backend job, not the app's entire network/rendering path.

**189 Python tests passed, zero failed/skipped.** The final suite result and command output are in `verification/python_tests.json` and `.log`. The offline suite covers the actual verifier, queue/index behavior, progressive partial results, multiple markets, supplied catalog loading, query limits, currencies, country caching, negative TTLs, provider ordering, Exa adapter caching/failure, and foreground/background separation. Public HTML replays are separate from blind search performance.

Flutter regression tests are included, but **Flutter tests and `flutter analyze` were not run here**: no Flutter SDK/full build project is available. Changed Dart files were syntax-parsed only. Functions are unchanged from v11.82. No live Serper/Exa discovery, paid Places lookup, simulator run or deployment is claimed.

## Remaining limits

- The uploaded procedure catalog's synonyms are mostly English. Existing local translations cover the current six families; 151 entries do not mean 151 procedures have been validated worldwide.
- No new Python Firecrawl/Playwright/Zyte renderer or AI verifier was added. Expensive rendering was not present in this supplied Python pipeline; blocked pages remain unverified. Existing Flutter integrations are preserved.
- Some clinic sites publish contradictory or conditional prices. The audit labels those explicitly. The fourth breast card's clinic identity is covered by navigation in the screenshot and cannot be verified without its URL/full card.
- The source audit proves specific public prices and reproduced extraction errors. It does not prove every city will produce six eligible clinics or promise a fixed search latency.

`SOURCE_MANIFEST.json` lists exact changed/new files and hashes. Patch application was checked against a reconstructed v11.82 baseline; local edits must still be merged carefully.
