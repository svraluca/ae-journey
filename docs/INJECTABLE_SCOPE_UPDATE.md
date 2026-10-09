# Injectable treatment evidence update

Hair-conditioning Botox, topical products called dermal fillers, and needle-free lip services must not appear as medical injection prices. The same rules now run on discovery and saved-price reads in Python, Functions and Flutter. Provider context is generic: a hair/nail venue needs treatment-local clinical evidence for an ambiguous service; its name is never a blacklist.

Fresha extraction previously discarded `itemOffered.description` and category. It now retains the service technique, package information and booking identity. Rejected authoritative offers cannot be resurrected by Python's loose DOM fallback. Functions also validates the original fragment before shrinking it, and structured offers retain their description/category. Cream descriptions take precedence over marketing names such as “Dermal filler”; numbing cream accompanying an injection remains valid.

The live Cleopatra Nails page checked on 9 October 2026 contains both €150 and €199 lip-augmentation services. The €199 category is **HYALURON PEN**. The €150 promotion at this nail venue lacks injectable technique evidence. Neither is a verified injectable filler, so the update removes these cards rather than changing €150 to €199. The source snapshot and fetch hash are in `verification/injectable_source_audit.json`; the literal offers are test fixtures, never runtime price overrides.

Booksy and clinicaalos.com returned proxy CONNECT 403. La Coqueta's reported hair/nail identity and ambiguous €80 Botox title are covered by regression tests. The reported Alós cream/no-filler page could not be independently checked, and the original €350 card evidence was not supplied. Cached prices from the previous parser revision require revalidation; creams and unqualified treatments are rejected even if old verification flags are present.

## Apply

Pull the update while preserving local edits, then restart the Python backend and fully restart Flutter. The backend and worker must both report **0.11.86** at `/health`; Flutter and Functions use extraction revision **e24**. The Python entrypoint remains `python/aesthetic_price_discovery_v11_67.py`, and the new `python/injectable_scope.py` module must be present beside it. Deploy the changed Functions when using that production extraction path. The delivered ZIP contains changed files, not the entire app.

Old e23 app price stamps become unverified and refresh from source evidence. This can temporarily reduce visible cards. Python's serving gate excludes invalid legacy results and its existing weak-result cleanup marks invalid treatment evidence inactive during normal discovery. No production Firestore writes or deployments were performed in this cloud run.

51 shared cases cover hair Botox, creams, needle-free techniques and genuine injection controls across 13 language contexts. Additional tests exercise original JSON-LD, live-source fixtures, native worker cache handoff, cached JSON and cleanup. Run details are in `verification/injectable_scope_validation.json`. These regressions cover these error classes; they do not guarantee every future website layout is parseable.

Booksy and Alós domains were added to the cloud environment draft, preserving existing domains. Review and save the changes in environment settings, then publish the environment to activate the reusable configuration. The current run still cannot access those sites. Physical-iPhone performance and production Firestore timing remain unmeasured.
