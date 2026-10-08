'use strict';

/**
 * Confirmed from `firebase firestore:databases:list` on aestheticpass-818c6:
 *   locationId: nam5  (Firestore native, US multi-region)
 *
 * Cloud Functions, Cloud Tasks, and Cloud Scheduler cannot deploy to `nam5`.
 * `us-central1` is the regional compute location that colocates with nam5.
 * Do not change this to nam5 — deploys will fail.
 */
const firestoreLocationId = 'nam5';
const computeRegion = 'us-central1';

/** Bound onto runExploreRefresh in part 2. Not a function body. */
const runExploreRefreshOptions = {
  region: computeRegion,
  timeoutSeconds: 540,
  memory: '512MiB',
};

module.exports = {
  firestoreLocationId,
  computeRegion,
  runExploreRefreshOptions,
};
