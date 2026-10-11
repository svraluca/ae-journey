# Published prices without an age cutoff — 0.11.97 / e33

The user's preference is to keep a genuinely published fee regardless of its
publication age. Python, Firebase Functions and Flutter now apply that policy.
There is no maximum publication age. The original price date is preserved;
fetching a page does not replace it with today's date. Missing dates remain
unknown. Invalid, ambiguous or future dates are still rejected.

Source ownership, procedure binding, provider locality, treatment scope,
original currency and extraction revision checks remain in force. No city,
provider or fee was added to production code. Revalidation is required for old
cache revisions; changing an extraction stamp by hand does not verify a price.

## Actual source checks on 11 October 2026

| Source | Published chemical-peel fee | Current result |
| --- | --- | --- |
| [Lokman Hekim Istanbul](https://us-uk.bookimed.com/clinic/lokman-hekim-istanbul/procedure=chemical-peel/) | $2,735; fee record dated 15 January 2025 | Accepted without a retention exception |
| [Memorial Bahcelievler](https://us-uk.bookimed.com/clinic/memorial-bahcelievler-hospital/procedure=chemical-peel/) | $150–$300; fee record dated 22 May 2025 | Accepted without an age exception |
| [Quartz](https://us-uk.bookimed.com/clinic/quartz-clinique/procedure=chemical-peel/) | $2,200 | Rejected for ambiguous treatment scope, independently of age |
| [Dr Siyamek Saleki](https://www.whatclinic.com/beauty-clinics/turkey/istanbul-province/istanbul/sariyer/dr-siyamek-saleki-esthetics) | Viewer-localized €800–€900 | Original clinic currency remains unverified |

These are literal published menu checks, not personalised quotes or a claim
that four eligible providers were discovered. All four pages returned HTTP 200.
The public capture details are in [peel_price_sources_e33.json](peel_price_sources_e33.json).
The accepted Lokman source and app row are in [published_peel_e33.json](published_peel_e33.json).

The running API's actual `/discover` request returned Lokman's $2,735 USD row
with revision e33 and its unchanged 2025 source date in 2.4 seconds. This was a
single known-source smoke check, not a cold search latency guarantee; see
[e33_http_source_smoke.json](e33_http_source_smoke.json). The local health response
reported both API and worker version 0.11.97, with extraction revision e33.
Validation passed: Python 242/242, Functions 346/346 and the focused nine Flutter
suites 79/79.

## Local Codex handoff

Paste this into Codex in Cursor on the Mac:

```text
Update /Users/elenaraluca/Desktop/GlowPass from origin/main to the 0.11.97/e33
patch. Preserve local Hunter guards, .env, uncommitted files and local commits.
If a merge is in progress, resolve it deliberately using the e33 policy rather
than blindly choosing ours/theirs. Remove any local 365-day fee-age rejection;
keep ownership, procedure, locality, original-currency and evidence checks.

Read verification/explore_e33_no_price_age_cutoff.md. Run the Python freshness
tests, Functions tests and relevant Flutter tests. Inspect the existing
com.glowpass.aesthetic-price-discovery.plist to locate the real Python runtime.
Sync the changed package there, including marketplace_price_freshness.py;
preserve runtime secrets and local guards, then restart the existing LaunchAgent.
Confirm /health reports version and worker_version 0.11.97 and
price_extract_revision e33. Stop and launch Flutter again.

Use the existing Firebase project/configuration to deploy the affected Explore
Functions as previously authorized; verify Functions extraction revision e33.
Do not reset Git or bulk-delete Firestore. Existing wrong/old price evidence
must be rechecked against its source, not merely restamped. The Lokman $2,735
published peel no longer needs user_retained_published_fee to pass an age gate.
Refresh its actual source and allow normally verified e33 rows to populate caches.

Check Peels and Fillers -> Botox -> Fillers. Verify original currencies and
stable tab returns. Do not force four cards with unverified prices. Report
actual discovery failures, including URLs and causes, if valid sources still
cannot be fetched.
```

No production deployment or Firestore write was performed in the cloud task.
Paid unseeded discovery and the Mac's actual LaunchAgent still need validation
there; known-source checks do not establish their readiness.
