'use strict';

/**
 * Server-side Explore feature flags (env / Firebase params).
 * Never expose to Flutter.
 */
function envFlag(name, defaultValue = false) {
  const raw = String(process.env[name] || '').trim().toLowerCase();
  if (!raw) return defaultValue;
  if (['1', 'true', 'yes', 'on'].includes(raw)) return true;
  if (['0', 'false', 'no', 'off'].includes(raw)) return false;
  return defaultValue;
}

function useBrightData() {
  return envFlag('USE_BRIGHTDATA', true) &&
      String(process.env.BRIGHTDATA_API_KEY || '').trim() !== '';
}

function useApifyFresha() {
  return envFlag('USE_APIFY_FRESHA', false);
}

function useZyteFallback() {
  return envFlag('USE_ZYTE_FALLBACK', false);
}

function usePlaywrightFallback() {
  return envFlag('USE_PLAYWRIGHT_FALLBACK', false);
}

module.exports = {
  envFlag,
  useBrightData,
  useApifyFresha,
  useZyteFallback,
  usePlaywrightFallback,
};
