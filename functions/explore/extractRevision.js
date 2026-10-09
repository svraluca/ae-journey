'use strict';

/// Price-extraction revision, shared by every Explore backend write path.
///
/// Must stay in lockstep with `kExplorePriceExtractRevision` in
/// lib/services/explore_price_sanity.dart. The client strips any positive
/// price whose stamp is not the current revision, so a backend that lags
/// behind ships rows that Flutter silently zeroes out — which is exactly how
/// the "only 1 card" bug happened (backend e12 vs client e13).
///
/// Bump only when extraction semantics change, and bump both sides together.
/// Rows carrying an older stamp stay stale on purpose: they are re-verified
/// rather than trusted.
/// e17: Stylage M/L/XL filler brands; Neuronox/botulotoxina; strip
/// dermatocosmetolog / Prețuri section titles from compare cards.
/// e18: exact prices stay exact (no auto /ml from "1 ml"); cross-city cache purge.
/// e19: page-level clinicOwnPrice / country cost guides; display-title normalization.
/// e20: Fresha JSON-LD Offer.itemOffered names; cost-savings URL reject; Fresha/Booksy discovery.
/// e21: synchronize with the supplied Flutter verifier and preserve menu labels.
/// e22: preserve owned tariffs beside dosage averages and multilingual offers.
/// e23: bind current tariffs to their scope; exclude finance, combinations and market disclaimers.
/// e24: retain marketplace technique; reject hair Botox, topical and needleless fillers.
/// e25: revalidate informational average tables and literal range endpoints.
const EXTRACT_REVISION = 'e25';

module.exports = {EXTRACT_REVISION};
