# Price refresh and cache corrections — 9 October 2026

The previous display stabilized both a clinic's slot and its amount. A newer verified quote could reach the pool while the old displayed amount survived. The display now retains the provider's position and replaces its tariff only when the incoming verified quote has a newer verification timestamp. Older late cache responses cannot overwrite it.

Saved prices paint as each validated source completes. Native Firestore cache is read before the server, using the requested procedure and its canonical alias, city place ID and name, and supported prior document revisions. Empty or invalid current documents no longer hide usable older aliases. Empty results are not kept in the Google-price memory cache for the whole session. Every saved row still passes current city, procedure, evidence and ownership checks.

City selection starts card reads before waiting for map readiness. Queued/running jobs and the final index read retain the loading state. An already completed discovery ticket's returned rows paint before further index and known-page refresh requests. Positive source invalidation can remove an old card; a 403 or timeout does not establish that a published price disappeared.

The Python parser selects explicit current offer columns, including `EN OFERTA`, rather than the ordinary price beside them. It retains the same row's vial basis, former amount and offer qualifier. Crossed-out old amounts remain excluded. A background fetch of the known evidence page updates its verified fee and timestamp when it can bind a current published tariff. This checks the website when refresh runs; it does not continuously monitor every clinic website or guarantee that a blocked page can be read.

Publishers such as ELLE are rejected before display and indexing. Editorial procedure-cost guides are rechecked instead of trusting incomplete cached excerpts; explicit nonownership disclaimers invalidate their amounts. A clinic's ordinary `/price-guide/` menu remains eligible for evidence validation. Maps locality matching ignores the street part of a formatted address: `C. de Murcia, 4, Arganzuela, 28045 Madrid, España` is a Madrid address.

## Latest screenshot audit

| Card | Current source finding |
|---|---|
| MBA Botox €350 | Published per session; areas unspecified beside the fee. |
| Lorea Bagazgoitia Botox €350 | Site returned 403; unverified in this cloud run. |
| Ibiza Botox €190 | Exact one-zone table fee; hero says from €190 for one zone. Two zones €290, three €350. |
| Berezo Botox €299 | Published starting promotion with conditions. Current Python replay did not bind a Botox tariff; the website amount alone does not prove the card's extraction. |
| De Felipe filler €305 | Published generic hyaluronic filler; aesthetic and scar sections both contain it. It does not establish a lip/chin-specific fee. |
| IME lip filler €400 | Old `ANTES` column. Current `AHORA` fee is €330 for one vial. |
| Venusmed lip filler €349–€380 | Matches the published augmentation range; hydration has separate pricing. |
| Berezo lip filler €330 | Current one-vial offer; ordinary fee €400. |
| Jesús Lago breast from €4,800 | Site proxy-blocked; unverified here. |
| Marco Romeo breast €6,000–€8,000 | Guide explicitly disclaims these as practice fees. Exclude. |
| ELLE breast from €8,000 | Publisher, not a treating clinic. Exclude. |
| Gustavo Sordo breast from €6,400 | Published for the specified implant technique. |
| Gustavo Sordo rhinoplasty from €10,040 | Matches the primary procedure's starting fee. |
| Marco Romeo rhinoplasty €7,500–€9,000 | Same disclaimed national-average guide; exclude. |
| Jesús Lago rhinoplasty €4,950 | Site proxy-blocked; unverified here. |
| CEME rhinoplasty from €4,599 | Official pages proxy-blocked. Google's AI summary suggests €4,100 for complete surgery without hospitalization, but that is not verified official-page evidence. No replacement amount is hardcoded. |

Exact fetched URLs, timestamps, excerpts and SHA-256 hashes are in [the source audit](../verification/latest_madrid_source_audit.json). The user logs report zero eligible app Firestore seeds and already completed job tickets carrying rows. They do not prove there was no data anywhere in Firestore. Exa discovery rounds appear in the user's runtime logs; Exa cannot replace source-page verification.

## Apply the update

Pull the latest `main`, restart the Python backend, and fully restart the Flutter app. Backend `/health` must report API and worker version **0.11.85**. The filename remains `python/aesthetic_price_discovery_v11_67.py`; its runtime version is authoritative. Deploy updated Functions when using their production extraction path. No production deployment or Firestore migration was performed in this cloud run.

The cloud startup helper disables Firestore for local testing. It is intended for this environment, not as a replacement for the user's authenticated production backend configuration. Actual iOS latency and fresh Google rating values need verification in the running app.
