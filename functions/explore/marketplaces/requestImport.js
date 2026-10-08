'use strict';

const {importFreshaCity} = require('./importCity');
const {shouldStartImport} = require('./importState');
const {cityDisplayName} = require('./locationFormat');
const {FRESHA_MAX_RESULTS} = require('./constants');

/**
 * Callable entry: claim + run Fresha city seed in the Cloud Function.
 * Flutter must fire-and-forget — never await this for UI paint.
 */
async function handleRequestExploreMarketplaceImport(request) {
  const data = (request && request.data) || {};
  const city = cityDisplayName(data.city || data.location || '');
  if (!city || city.toLowerCase() === 'worldwide') {
    return {ok: false, reason: 'invalid_city'};
  }
  const force = data.force === true;
  const maxResults = Number(data.maxResults) > 0
      ? Math.min(Number(data.maxResults), FRESHA_MAX_RESULTS)
      : FRESHA_MAX_RESULTS;
  const provider = String(data.provider || 'fresha').toLowerCase();
  if (provider !== 'fresha') {
    return {ok: false, reason: 'provider_unsupported'};
  }

  if (!force) {
    const gate = await shouldStartImport(city);
    if (!gate.start) {
      return {
        ok: true,
        skipped: true,
        reason: gate.reason,
        skippedReason: gate.reason,
        status: gate.state && gate.state.status,
        venues: Number((gate.state && gate.state.venuesImported) || 0),
        services: Number((gate.state && gate.state.servicesImported) || 0),
        clinics: Number((gate.state && gate.state.clinicsImported) || 0),
        prices: Number((gate.state && gate.state.pricesImported) || 0),
      };
    }
  }

  // Full import runs inside this invocation (timeout 540s). Client disconnects early.
  const result = await importFreshaCity({city, maxResults, force: true});
  return {
    ...result,
    skippedReason: result.reason || '',
  };
}

module.exports = {
  handleRequestExploreMarketplaceImport,
};
