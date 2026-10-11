# Peel products versus procedure fees

Release: Python API/worker 0.11.99, extraction revision e34 in Python,
Firebase Functions and Flutter.

The previous verifier accepted a clinic-owned paragraph containing
`Our PRX-T33 bottle 4 ml | 85 EUR` and
`Our TCA peel solution 30 ml | 25 EUR`. A clinic identity and a literal amount
do not establish that the amount buys a treatment. The cached Python serving
gate also lacked the product checks applied during extraction.

The correction checks the priced label for bottles, vials, ampoules, kits,
solutions and ambiguous ml quantities. Those quantities require explicit
session/application context; generic “facial treatment” marketing does not
establish a procedure fee. Shopping, wholesale and take-home wording rejects.
Explicit product/shop URL structures reject. Compact single-price rows are
checked in both column orders; mixed multi-price pages are filtered row by row.
Sparse peel queries now include `treatment price` alongside the requested city.

Seventeen shared fixtures exercise the three actual verifiers. They include
English and Turkish product labels, a price-first table row, unqualified kits,
take-home peels and legitimate BioRePeel, PRX-T33, glycolic and salicylic peel
sessions. Python additionally tests mixed menus and cached rows with legacy
verification flags. These are fictional regression fixtures, not published
clinic quotes or a guarantee about every possible website layout.

Validation completed:

- 102 Python tests passed across product scope, peel coverage, public menus,
  injectable scope, treatment scope, marketplace provenance, fee ownership,
  WhatClinic expansion and discovery coverage.
- All 41 Functions test files passed when executed individually: 360 tests.
- 37 Flutter tests passed covering the new fixtures, backend compatibility,
  peel extraction and marketplace provenance.
- Local `/health` returned API and worker 0.11.99 and revision e34.

Deployment: update and restart the actual Mac Hunter process and rebuild/restart
Flutter together. Deploy the changed Firebase Functions if the application uses
that verifier. Older extraction revisions require rechecking their source;
never change their revision stamp to make them eligible. This release adds no
365-day price-age rule and does not change the original-currency requirement.
The historical e33 source audit remains intact. The dated $2,735 peel policy
regression still passes for a newly verified row; this is not a production
cache rewrite or a fresh online verification of that listing.

No production Firestore data or deployed Functions were changed by these checks.
