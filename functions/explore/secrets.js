'use strict';

const {defineSecret, defineString} = require('firebase-functions/params');

/**
 * Secret Manager names. Bound on getExploreProcedurePrices via `secrets: [...]`.
 * Values are read server-side as process.env.<NAME>.
 *
 * Create/update with:
 *   firebase functions:secrets:set OPENAI_API_KEY
 */
const openaiApiKey = defineSecret('OPENAI_API_KEY');
const googlePlacesApiKey = defineSecret('GOOGLE_PLACES_API_KEY');
const serpApiKey = defineSecret('SERPAPI_API_KEY');
/** Serper discovery key — first choice for URL discovery, never for prices. */
const serperApiKey = defineSecret('SERPER_API_KEY');
/** DataForSEO discovery credentials (Basic auth). Prices never come from it. */
const dataForSeoLogin = defineSecret('DATAFORSEO_LOGIN');
const dataForSeoPassword = defineSecret('DATAFORSEO_PASSWORD');
const googleTranslateApiKey = defineSecret('GOOGLE_TRANSLATE_API_KEY');
/** Firecrawl — site map / PDF fetch fallback only; never supplies a trusted price. */
const firecrawlApiKey = defineSecret('FIRECRAWL_API_KEY');
/** Zyte — browserHtml fallback only; never AI extract / prices. */
const zyteApiKey = defineSecret('ZYTE_API_KEY');
/** Apify — Fresha bulk seeders (disabled by default via USE_APIFY_FRESHA). */
const apifyApiToken = defineSecret('APIFY_API_TOKEN');
/** Bright Data — primary SERP / Unlocker / Maps discovery. Never expose to clients. */
const brightDataApiKey = defineSecret('BRIGHTDATA_API_KEY');
const brightDataSerpZone = defineSecret('BRIGHTDATA_SERP_ZONE');
const brightDataUnlockerZone = defineSecret('BRIGHTDATA_UNLOCKER_ZONE');
const brightDataGoogleMapsDatasetId = defineSecret('BRIGHTDATA_GOOGLE_MAPS_DATASET_ID');

/** Public Cloud Run URL — not a secret. Do not set via `gcloud run services update`. */
const rendererUrl = defineString('RENDERER_URL', {
  default: 'https://glowpass-renderer-688009382588.us-central1.run.app',
  description: 'Cloud Run Playwright renderer for JS-only clinic pages',
});

const rendererToken = defineSecret('RENDERER_TOKEN');

module.exports = {
  openaiApiKey,
  googlePlacesApiKey,
  serpApiKey,
  serperApiKey,
  dataForSeoLogin,
  dataForSeoPassword,
  googleTranslateApiKey,
  firecrawlApiKey,
  zyteApiKey,
  apifyApiToken,
  brightDataApiKey,
  brightDataSerpZone,
  brightDataUnlockerZone,
  brightDataGoogleMapsDatasetId,
  rendererUrl,
  rendererToken,
};
