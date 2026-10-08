'use strict';

const {EXTRACT_REVISION} = require('../extractRevision');

/** Max Google clinics to resolve Fresha URLs for per city import. */
const FRESHA_MAX_RESULTS = 40;

/** Max Fresha venue URLs sent to Malikgen per Apify run. */
const FRESHA_VENUE_BATCH_SIZE = 12;

/** Do not re-run a successful city import within this window. */
const FRESHA_IMPORT_TTL_DAYS = 7;

/** Empty / zero-price imports may retry after this cooldown. */
const FRESHA_EMPTY_COOLDOWN_MS = 30 * 60 * 1000;

/** Apify actor — venue mode only (never city/search discovery). */
const FRESHA_ACTOR_ID = 'malikgen~fresha-scraper';

const IMPORT_COLLECTION = 'explore_marketplace_imports';
const STAGING_COLLECTION = 'explore_marketplace_staging';
const RAW_SERVICES_COLLECTION = 'explore_marketplace_raw_services';
const PROVIDER_FRESHA = 'fresha';

/** Google Places discovery queries for medical-aesthetic clinics. */
const AESTHETIC_PLACE_QUERIES = [
  'aesthetic clinic',
  'medical aesthetics',
  'Botox clinic',
  'filler clinic',
  'dermatology clinic',
  'cosmetic clinic',
];

module.exports = {
  FRESHA_MAX_RESULTS,
  FRESHA_VENUE_BATCH_SIZE,
  FRESHA_IMPORT_TTL_DAYS,
  FRESHA_EMPTY_COOLDOWN_MS,
  FRESHA_ACTOR_ID,
  IMPORT_COLLECTION,
  STAGING_COLLECTION,
  RAW_SERVICES_COLLECTION,
  PROVIDER_FRESHA,
  EXTRACT_REVISION,
  AESTHETIC_PLACE_QUERIES,
};
