# GlowPass Explore corrections

This checkout preserves the complete Flutter app already uploaded to GitHub and adds the corrected Python price-discovery program from the supplied update ZIP. The uploaded Functions sources are integrated into the existing project.

## Corrected behavior

- Compare shows at most **four** eligible providers, including after background results arrive. The Flutter limit and Python API contract agree.
- Cards preserve the clinic's published treatment name, dosage and price range. A generic Botox label no longer overrides a more precise tariff name.
- Pending searches show progress. Completed jobs stop loading immediately and publish any returned rows.
- Menu parsing runs off the mobile app's frame thread. Heading lookup indexes siblings once; repeated literal regexes and unchanged display rows reuse cached work.
- Page context travels with each price fragment. Market estimates, foreign comparisons, consultation fees, and incomparable packages cannot masquerade as local treatment tariffs.
- Owned price menus remain usable beside average dosage descriptions. Monetary averages remain excluded. Explicit offer expiry replaces guesses based on the amount alone.
- Functions and Flutter share extraction revision **e23**, which invalidates older price evidence. A regression test compares the actual files.
- General extraction rules exclude financing caps, conditional companion offers, old price columns, and explicitly disclaimed market estimates. They preserve current treatment names, areas, doses, and approximate pricing; clinic prices are not hardcoded.
- Returning to a verified tab reuses its four cards immediately, with bounded background refresh. Repeated missing-rating lookups and duplicate collection submissions are coalesced. SQLite waits run outside the API event loop.
- Saved prices paint as each source completes, before map readiness. Native Firestore aliases are tried before server reads; invalid or empty current documents cannot mask usable prior saves. Completed job rows paint before further index requests, and pending jobs retain loading.
- Newer verified tariffs update an existing clinic's card in place. Explicit offer columns preserve their current amount and vial basis. Publishers are excluded, and city-named streets do not count as foreign cities during rating matching.
- City matching uses complete words, and explicit foreign branch tariff headings override local SEO titles and shared footers.
- Index reads preserve rejected-source quarantine and country scope. Fresh verification can restore a rejected source.
- Discovery counts eligible unique saved providers and respects already-spent search budgets. Malformed Exa responses fail safely.

Google ratings require a matching business in the selected city. The Harrogate/Málaga listings from the supplied Valencia logs correctly remain excluded. Cards show `No rating` when a verified rating is unavailable.

## Development environment

```sh
bash scripts/setup-cloud.sh
bash scripts/start-local-backend.sh
```

Setup installs locked Python dependencies, Node **20.20.2**, and Flutter **3.41.4** / Dart **3.11.1**. It verifies the Node archive's official SHA-256 and Flutter framework commit `ff37bef603469fb030f2b72995ab929ccfc227f0`, then runs `npm ci` and `flutter pub get --enforce-lockfile`. Both existing app lockfiles remain unchanged.

The backend helper starts the local service with Firestore and scheduled refresh disabled. It prevents a local dotenv file from overriding those development settings. See [cloud startup instructions](docs/CLOUD_START.md) for shell activation, readiness checks, and test commands.

## Validation

**103 Python tests**, **260 Functions tests**, and **196 tests in 14 selected Flutter suites** passed with no failures or skips. Final commands are recorded in [current validation](verification/current_validation.json). The local API and worker both report **0.11.85** and passed health, price-index, and four-card request-limit checks. Flutter analysis reports no errors; warnings and style notices remain. Earlier setup and performance checks are preserved in [prior validation](verification/prior_validation_7e70ecc.json).

Tests cover the display limit, treatment names, exact fee ranges, active search messages, cancellation, cache ownership, event-loop responsiveness, city scope, tariff ownership, provider budgets, and rejected-source persistence.

## Limits of this run

The twenty Madrid screenshot cards were checked against live public source pages. The [Madrid price audit](docs/MADRID_PRICE_AUDIT.md) distinguishes matching amounts from wrong treatments, old prices, promotions, financing and market estimates. The Dra. Olmo FAQ publishes approximately €300 depending on vials. Source URLs, excerpts and fetched-page hashes are recorded in the audit JSON files. The old cards' exact stored extraction evidence was not present in the supplied log, and live Google ratings were not rechecked.

Device scrolling and mobile release builds were not run. No Firebase, app-store, or backend deployment was performed. Deploy the client, Python API and Functions changes together; the corrected API rejects older eight-card requests.

The [latest cache and price-refresh report](docs/PRICE_REFRESH_AND_CACHE.md) covers the subsequent sixteen Madrid cards, missing loading, ELLE, the CEME Maps-address rejection and updated prices. CEME's Google-summary €4,100 is not independently confirmed because its official pages remained proxy-blocked; clinic prices are never hardcoded from screenshots.

`PRICE_AUDIT.md`, original patches, the uploaded README and older verification files are historical upload evidence. This run's results are recorded separately. Local credentials, dependency caches and build output stay excluded from Git.
