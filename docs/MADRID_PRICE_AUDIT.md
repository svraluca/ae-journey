# Madrid card audit — 8 October 2026

The five screenshots contain twenty cards. The amounts below were checked against live public clinic or booking pages using TLS-verified requests. Published fees still depend on their stated treatment, dose, promotion and individual assessment. The uploaded simulator log contains no stored price evidence for these particular cards, so a matching website amount does not establish exactly how the old card was produced.

| Card | Finding |
|---|---|
| Botox / Clínica MBA — €350 | Published for Toxina Botulínica per session. The fee does not state the number of areas beside it. |
| Botox / Sandra Hermida — €510 | NeuroSkin combines Skinbooster and neuromodulators. Exclude it from standalone Botox. The menu separately lists upper-third neuromodulators at €350 and one zone at €250. |
| Botox / Clínica Ibiza — €190 | Published **from €190 for one area**; three areas cost €350. Keep the starting-price and area basis. |
| Botox / Elena Berezo — €299 | Current anti-wrinkle starting promotion, with purchase/treatment conditions. It is not an unconditional fixed fee. |
| Filler / Venusmed — €250 | The price page has a conditional friends pack; hydration also has its own prices. The lip-augmentation treatment page publishes €349–€380. Do not bind either other fee to generic lip augmentation. |
| Filler / IME — €400 | This is the **ANTES** column. **AHORA**, one vial of lip augmentation is €330; other areas have separate current fees. Select the current column and preserve its dose/area. |
| Chin filler / Jorge García — €2,500 | The chin treatment page asks for a personalized quote and publishes no numerical fee. The homepage's “Hasta 2.500€” concerns financing. Exclude credit limits from treatment prices. The original card's exact provenance remains unavailable. |
| Filler / Cleopatra Nails — €150 | Published Fresha promotional offer for one vial. A separate same-name service appears under HYALURON PEN at €199. Preserve the selected offer's terms; do not infer its mechanism from the generic title. |
| Peel / Elena Berezo — €120 | The checked peel page gives no fixed numerical fee. This amount is unsupported by that current page. |
| Peel / Sandra Hermida — €150 | Published for one PhenTCA chemical-peel session. |
| Peel / IME — €120 | Published standard chemical-peel price per session; phenol has a separate fee. |
| Peel / De Felipe — €50 | Published for one salicylic-acid 10–25% peel session. |
| Rhinoplasty / Marco Romeo — €10,000–€20,000 | The guide explicitly describes national averages and says they are **not his practice's prices**. This row also concerns post-traumatic surgery. Exclude the guide's amounts from clinic-owned fees. |
| Rhinoplasty / Sculpture — from €7,000 | Matches the treatment page's starting-price wording. |
| Rhinoplasty / Icifacial — from €10,000 | The provider-specific primary section publishes **from €8,000**. Generic country ranges on the page must not replace it. The section heading says 2025; no explicit expiry was found. |
| Rhinoplasty / Diego Casas — €7,000–€10,000 | Matches an explicit provider paragraph on the price page. Generic estimates elsewhere remain separate. |
| Breast augmentation / Gustavo Sordo — from €6,400 | Published for the specified implant technique; retain its actual method when available. |
| Breast augmentation / Marco Romeo — €6,000–€8,000 | Same national-average guide and explicit nonownership disclaimer. A matching table amount does not make it a practice fee. |
| Breast augmentation / Doctor Aso — from €6,400 | Matches the conventional implant procedure's starting price. |
| Breast augmentation / Bonomédico — €3,490 | Published offer for round implants, with Dr. Carlos Corrales Benítez as provider. Bonomédico says it is not a medical office; it must not become the treating clinic's identity. |

The earlier Dra. Olmo source is now accessible. Its actual FAQ says: “Depende del número de viales a infiltrar al paciente pero suele rondar los 300€.” Preserve **approximately €300, depending on vials**, rather than reporting an exact fee or claiming the page has no price.

The machine-readable evidence includes exact URLs, excerpts, access timestamps and fetched-page SHA-256 hashes:

- [Botox, fillers and peels](../verification/user_followup_source_audit.json)
- [Rhinoplasty and breast augmentation](../verification/madrid_surgery_source_audit.json)

The corrections implement general rules for amount ownership, current columns, financing, conditional packs, procedure variants and explicit nonownership. No clinic price is hardcoded into production discovery. The API and Flutter/Functions changes need to reach the running backend and app before the screenshots' behavior can change. Actual iOS frame rate and live Google ratings were not measured in this cloud run.
