# Explore responsiveness and clinic variety — 9 October 2026

Location selection now reuses the saved resolved city before contacting Places, shows progress while a new locality resolves, and returns after the navigation animation finishes. Preference writes run in order after the selected city paints. The return transition no longer launches every procedure's Firestore cache reads at once.

Saved and discovery price batches validate on worker isolates on native Flutter. Ownership, procedure, currency, locality and price sanity rules still apply. The validators reuse a bounded cache of compiled regular expressions and briefly memoize checks on immutable clinic records. Display-only metadata changes preserve those checks. Hidden job progress no longer rebuilds a complete map/list; clinic cards have repaint boundaries. Background warm loops stop when the active selection changes.

The Python-first path now retains its entire eligible clinic pool instead of discarding providers after the first four. Entering a procedure, revisiting a city or pressing **Find more clinics** selects up to four verified providers, prioritizing those shown less often and preferring alternatives to providers visible in sibling procedures. Equally exposed choices are shuffled. Background results keep the active providers in their slots and can replace a provider's fee with newer verified evidence. A limited source pool necessarily repeats providers; rotation does not invent clinics or relax verification. New discovery continues independently of these display choices.

One loading panel replaces the duplicated search captions. It has a small search animation and three quiet placeholders. Only its small canvas repaints each frame; reduced-motion settings stop the animation. Partial results use a compact version of the panel.

## Hair transplant audit

| Madrid card | Finding |
|---|---|
| De Felipe €2,900 | The official tariff publishes **FUE Zafiro, fewer than 1,000 follicular units**. Other brackets are €3,400, €3,900 and €4,400. |
| Svenson €2,495 | Official site access blocked; amount and package scope remain unverified here. |
| Clínica Capilar Velázquez €9,000 | Official site access blocked; an exact fee versus range/package remains unverified here. |
| Hospital Capilar €5,000 | Official site access blocked; amount, package and Madrid branch scope remain unverified here. |

The Python replay already extracted all four De Felipe rows with their correct printed UF brackets. Flutter omitted the bracket when formatting the price. Cards and map price labels now retain the row's explicit follicular-unit count or range. This uses the treatment evidence; no production clinic prices are hardcoded. [Source records](../verification/madrid_hair_source_audit.json) contain timestamps and the fetched page hash. Fresh Google ratings were not verified in this run.

## Apply and validate

Pull the updated `main` into Cursor while preserving local edits, then fully restart Flutter. This update changes Flutter code; it does not require a replacement Python program or a production Firestore migration. The existing backend remains **0.11.85** with extraction revision **e23**.

Run `flutter run --profile` on a physical iPhone and test choosing Madrid, scrolling, switching procedures quickly, returning to a loaded procedure, and **Find more clinics**. Check Flutter DevTools frame timings during these interactions. Unit/widget tests verify the asynchronous cache handoff, no-network memory rotation, loading animation isolation, reduced motion, retained tariff qualifications and price validation. They do not establish actual device frame rates or production Firestore latency.

The broader check ran 54 Flutter suites: 672 tests passed and 14 failed. The untouched base commit reproduces all 14 failures with the same test names; this update introduces no additional failures. All nine new tests pass and analysis reports zero errors. The cache benchmark accepted 40 rows on a worker in approximately 2.7 seconds while the main event loop remained responsive; 100 cached validation passes took 11 milliseconds. These are test-run timings. [Validation details](../verification/responsive_explore_validation.json) list the inherited failures and matching-rule parity checks.

The cloud network draft adds the three blocked hair-clinic domains for future source checks. The draft must be saved/published in environment settings before those changes take effect; it was not applied during this audit.
