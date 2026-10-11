# Filler prices and marketplace Maps ratings

The four screenshot fees were checked against actual source pages on
11 October 2026. All four pages returned HTTP 200. Capture hashes, extracted
rows and validation results are in [filler_price_sources_e33.json](filler_price_sources_e33.json).

| Screenshot clinic | Published filler amount | Scope and source |
| --- | --- | --- |
| Euro Istanbul Clinic | €350 | [Official menu](https://www.euroistanbul.com/fillers-injection/): one area; each added area costs €250 |
| CE International Hospital | $200–$350 | [Bookimed profile](https://us-uk.bookimed.com/clinic/clinic-expert/), whose provider schema names CE International Hospital; its URL retains Clinic Expert |
| Quartz Hospital | $350 | [Bookimed provider menu](https://us-uk.bookimed.com/clinic/quartz-clinique/procedure=fillers-injection/) |
| Elixirmed Clinic | $840.27–$1,680.54 | [Bookimed provider menu](https://us-uk.bookimed.com/clinic/elixirmed/procedure=fillers-injection/); screenshot rounds to $840–$1,681 |

The Bookimed numbers are literal published marketplace menu entries, not
independent confirmation of a doctor's direct fee. The generic rows do not
establish syringe volume, filler brand or a personalised quote. Elixirmed's
matched fee record is dated 8 February 2025; the user's no-age-cutoff policy
preserves that original date and allows the still-published fee. CE and Quartz
have procedure records dated 26 and 25 September 2026 respectively. Google AI
summaries were not used as price evidence.

## Why marketplace cards could remain unrated

The live enrichment pipeline already queried Places by provider name and city.
Its first identity gate could accept a marketplace provider by name. A second
website check then discarded that same accepted rating because Bookimed's host
differs from the actual clinic website. Cached enrichment already allowed the
name match, so live and cached paths behaved differently.

The fix makes both live gates use the same provider identity rules. Marketplace
lookup removes an appended location title such as `Clinic in Turkey` and
recognizes generic clinic words such as `Hospital` and `Clinique`. A different
provider or a conflicting city still fails. No clinic-specific aliases or
ratings were introduced. A differently named Maps listing still needs identity
proof; this does not guarantee that every provider will acquire a Google score.

The real official host is saved with the successful rating for reuse. The
marketplace provider identity remains a comparison key when Maps supplies a
different display name, so the rating can patch the original card. The rating
backfill preserves its original price, currency, source URL, evidence and
extraction revision.

The new regression tests exercise live Text Search, both identity gates,
rating overlay and reuse without a second HTTP call. They also reject another
clinic and the correct name in another city. The Google replies are mocks;
the cloud environment has no configured Places API key, so current real
Google ratings have not been measured here.

Validation passed: 65 tests across nine Flutter suites, including the four new
Maps rating regressions. Targeted analysis reported zero errors with existing
warning/info findings; this is not a clean lint pass. Two older regression
fixtures were updated to the current e33 health and Places quota-error contracts.

## Apply on the Mac

This rating fix changes Flutter, not the Python/Functions price revision.
Use the existing e33 update instructions for any components still on older
versions. For the new fix, paste this into local Codex:

```text
Update /Users/elenaraluca/Desktop/GlowPass from origin/main, preserving local
work, Hunter guards and .env. Read verification/filler_prices_and_maps_ratings_e33.md.
Run test/explore_marketplace_maps_rating_test.dart and relevant regression tests.
Stop and relaunch Flutter rather than relying only on hot reload.
Keep the configured Places API key; never print or commit it. Check Fillers
and capture Places match/city/identity/error logs if any card still says No rating.
Do not replace a missing Google score with a Bookimed review score, assign a
similarly named clinic's rating, change the fee, or bulk-delete Firestore.
```

The cloud task did not deploy a mobile release or change production Firestore.
