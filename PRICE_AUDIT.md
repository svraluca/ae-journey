# Valencia screenshot audit

Primary pages checked October 7–8, 2026. Prices below describe published evidence, not an individualized treatment quote. The important distinction is whether the amount belongs to this clinic, procedure, branch and pricing basis.

## Rhinoplasty

| Card | Finding |
|---|---|
| Dr. Moltó — €1,800–€3,500 | The clinic exists. This is an indicative **partial rhinoplasty** range in a price guide. It must not be shown as a verified full-rhinoplasty tariff. [Source](https://www.drmolto.com/rinoplastia-ultrasonica-precio/) |
| Dr. Eduardo Simón — €4,000 | The older article describes a Spanish market range, not a current fixed clinic price. His current homepage describes primary ultrasonic rhinoplasty starting at **€8,400**, subject to individual assessment. The current parser conservatively leaves this homepage quote unverified; it does not replace the card with an invented amount. [Current page](https://dreduardosimon.com/) · [Older article](https://dreduardosimon.com/rinoplastia-precio) |
| Dr. Zingone — €4,500–€6,500 | This is a 2025 guide's indicative range for primary surgery across private clinics. It is not established as his own Valencia fee. [Source](https://drzingone.com/precio-rinoplastia/) |
| Médics Integral Salut — €3,500–€6,000 | A Spain-wide guide from a Girona provider. It lacks evidence for a Valencia clinic-owned price. [Source](https://www.medicsintegralsalut.com/cuanto-cuesta-rinoplastia-espana/) |

## Breast augmentation

| Card | Finding |
|---|---|
| Sensabell — from €3,000 | The paragraph describes **other low-cost clinics**. Sensabell's own procedure page asks for an individual quote. Remove this amount as its tariff. [Guide](https://sensabell.com/precio-aumento-pecho-2026-valencia/) · [Procedure](https://sensabell.com/servicio/cirugia-plastica-estetica/corporal/aumento-de-pecho-valencia/) |
| Dr. Julio Puig — €2,000 | The guide's €600–€2,000 concerns a pair of implants, not the complete operation. The prominent procedure price is **from €5,300**. A lower FAQ still mentions €4,000, so the site is internally inconsistent and the final quote needs confirmation. The corrected replay selects the explicit main starting-price heading, not the component cost. [Procedure](https://drpuig.com/cirugia-estetica/mamas/aumento-pecho/) · [Guide](https://drpuig.com/precio-aumento-de-pecho-valencia-cuanto-cuesta/) |
| ClinicHunter — from €2,253 | This is a directory, not the treating clinic. The repeated listing amount is not a verified provider-owned tariff. [Source](https://clinichunter.com/breast-enlargement/clinics/spain/valencia/) |
| Fourth card — €3,900 | The screenshot covers its name/domain. Cannot identify or validate this card reliably; its source URL or full card is needed. |

## Hair transplant

| Card | Published evidence |
|---|---|
| MCapilar — €3,090 | Its Valencia section gives **€3,090–€3,690**. A standalone minimum must be marked “from,” not fixed. The original replay chose an Oviedo paragraph; the corrected city/range rules reject that branch quote and preserve the published range. [Source](https://clinicamcapilar.com/injerto-capilar-precio/) |
| Salud Capilar — from €2,900 | Matches the Valencia page's advertised starting offer. It is not the same as its monthly financing amount; confirm current promotional conditions. [Source](https://clinicasaludcapilar.com/clinica-trasplante-capilar-valencia/) |
| Magnasalud — from €2,500 | Matches the FUE treatment page's starting price. [Source](https://clinicamagnasalud.es/servicios/medicina-capilar/trasplante-capilar-fue/) |
| Benaes — from €1,500 | Matches the clinic menu's advertised starting fees for FUE, DHI and FUSS. Do not present it as a fixed price for every graft count/technique. [Clinic menu](https://www.benaes.com/clinica-capilar/) |

The hair cards are therefore not all wrong. Their starting/range and technique labels matter. Salud Capilar's page returned HTTP 502 to the direct replay, and Benaes/Dr. Zingone returned 403; their published text was checked through web retrieval, not a successful production-fetch replay. The fix does not bypass access restrictions.

## Earlier Botox and filler screenshots

| Procedure / clinic | Correction |
|---|---|
| Botox / My Medica — €350 | Matches its fee page. [Source](https://es.mymedicavalencia.com/fees/) |
| Botox / Ipanema — €260 | Wrong neighboring service. The menu lists **from €230 for three Botox zones**; **from €260** belongs to lip augmentation. [Booksy service menu](https://booksy.com/es-es/110260_ipanema-beauty-studio_salon-de-unas_58087_valencia) |
| Botox / Aurora Reig — €200 | Conditional campaign/couples price. The regular page lists **€250 for three zones**, including a touch-up. The old campaign should not become a general current fee. [Regular page](https://aurorareig.com/neuromodulador/) · [Campaign](https://aurorareig.com/oferta-especial-de-toxina-botulinica-botox-en-valencia-y-denia/) |
| Botox / Dr. Puig — from US$400 | A generic average from a FAQ. The own procedure heading states **from €300**. [Source](https://drpuig.com/medicina-estetica/facial/botox/) |
| Filler / Miim — €200 | Its €200–€400 is a market average, not a clinic-owned lip filler tariff. The Spanish sentence fragment should not become a procedure title. [Source](https://www.miimclinic.com/cual-es-el-precio-de-un-aumento-de-labios/) |
| Filler / My Medica — €70 | Consultation/appointment fee redeemable against treatment. The published lip enhancement fee is **€300 per vial**. [Source](https://mymedicavalencia.com/aesthetic-medicine/) |
| Filler / Aurora Reig — €250 | Matches its lip augmentation page, one vial. [Source](https://aurorareig.com/aumento-de-labios/) |
| Filler / Holaglow — from €329 | Matches the Valencia lip augmentation page. Keep the “from” qualification. [Source](https://www.holaglow.com/tratamientos/aumento-labios/valencia) |

## Why counts and speed looked wrong

The server counted rows the Flutter gates later dropped: directories, implausible bundles, wrong procedure-price associations and duplicated providers. Twelve server rows therefore did not mean twelve usable cards. The old Flutter display cap was also four. The update gates price provenance earlier and permits eight displayed providers.

Separate job IDs for Botox, filler and peeling show concurrent/queued jobs, not proof that the selected pill was querying Botox. Existing focus IDs prevent stale jobs from repainting the active result list. Background collection can legitimately keep logging a previous pill.

The new stage policy is country-aware and shared across arbitrary cities: selected procedure plus city and price intent, then local language and genuinely different rescue providers only if short. No Valencia/Madrid/Barcelona clinic prices are inserted into production configuration.

Serper is already the backend's Google-results API integration. Google Places supplies clinic identity/ratings rather than procedure tariffs. Google's Custom Search JSON API is closed to new customers and existing customers must migrate by January 1, 2027, so it is not the recommended replacement here. [Serper](https://serper.dev/) · [Google documentation](https://developers.google.com/custom-search/v1/overview)

## Verification limits

`verification/` separates offline regressions, downloaded-page replay results and access failures. Replay used the actual extraction, ownership, location, trust and deduplication gates with known URLs. It does not establish that blind Serper discovery found every source. No paid provider keys or running Mac backend were available here. The earlier v11.82 package contains six-clinic source controls for Barcelona/Madrid/Valencia; those remain diagnostic controls, not guaranteed live card counts.
