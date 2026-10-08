# GlowPass Explore corrections

This checkout preserves the complete Flutter app already uploaded to GitHub and adds the corrected Python price-discovery program from the supplied update ZIP. The uploaded Functions sources are integrated into the existing project.

## Corrected behavior

- Compare shows at most **four** eligible providers, including after background results arrive. The Flutter limit and Python API contract agree.
- Cards preserve the clinic's published treatment name, dosage and price range. A generic Botox label no longer overrides a more precise tariff name.
- Pending searches show progress. Completed jobs stop loading immediately and publish any returned rows.
- Menu parsing runs off the mobile app's frame thread. Heading lookup indexes siblings once; repeated literal regexes and unchanged display rows reuse cached work.
- Page context travels with each price fragment. Market estimates, foreign comparisons, consultation fees, and incomparable packages cannot masquerade as local treatment tariffs.
- Owned price menus remain usable beside average dosage descriptions. Monetary averages remain excluded. Explicit offer expiry replaces guesses based on the amount alone.
- Functions and Flutter share extraction revision **e22**, which invalidates older price evidence. A regression test compares the actual files.
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

**80 Python tests**, **243 Functions tests**, and **214 tests in 16 selected Flutter suites** passed with no failures or skips. Final commands are recorded in [current validation](verification/current_validation.json). The complete setup script and backend restart instructions were exercised in this workspace. The service passed health, price-index, and four-card request-limit checks. Flutter analysis reports no errors; existing warnings and style notices remain.

Tests cover the display limit, treatment names, exact fee ranges, active search messages, cancellation, cache ownership, event-loop responsiveness, city scope, tariff ownership, provider budgets, and rejected-source persistence.

## Limits of this run

Current live clinic-price verification remains blocked: the network proxy rejects the Dr. Puig clinic source with HTTP 403. Access for the three clinic domains in the supplied logs, Clínica Dra. Olmo, their `www` hosts, and Flutter storage is saved in the environment draft. Review/save the settings and publish the environment to activate that configuration; draft saving alone does not apply it. No current clinic prices or ratings are certified by these offline tests.

Device scrolling and mobile release builds were not run. No Firebase, app-store, or backend deployment was performed. Deploy the client, Python API and Functions changes together; the corrected API rejects older eight-card requests.

`PRICE_AUDIT.md`, original patches, the uploaded README and older verification files are historical upload evidence. This run's results are recorded separately. Local credentials, dependency caches and build output stay excluded from Git.
