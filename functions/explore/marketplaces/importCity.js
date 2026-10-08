'use strict';

const admin = require('firebase-admin');
const {FreshaProvider, venueHasMedicalAestheticServices, venueIsBeautyOnly} =
    require('./freshaProvider');
const {discoverAestheticClinics} = require('./googleClinicDiscovery');
const {findFreshaVenueUrlForClinic} = require('./freshaUrlFinder');
const {
  namesLookLikeSameProvider,
  packedCanonicalClinicName,
} = require('../identity');
const {classifyFreshaService} = require('./procedureMap');
const {
  shouldStartImport,
  markImportRunning,
  markImportFinished,
  markImportFailed,
} = require('./importState');
const {
  FRESHA_MAX_RESULTS,
  STAGING_COLLECTION,
  RAW_SERVICES_COLLECTION,
  EXTRACT_REVISION,
  PROVIDER_FRESHA,
} = require('./constants');
const {cityDisplayName, importCityKey} = require('./locationFormat');
const {phonesMatch, addressOverlap} = require('./identityMatch');
const {upsertVerified} = require('../firestoreStore');
const {isValidExtractedPriceCandidate} = require('../priceSanity');
const {clinicIdentityRejectReason: identityReject} = require('../identity');

function nowIso() {
  return new Date().toISOString();
}

function freshaMatchesGoogleClinic(venue, place, city) {
  if (!venue || !place) return {strong: false, reason: 'missing'};
  const nameOk = namesLookLikeSameProvider(venue.name, place.name) ||
      packedCanonicalClinicName(venue.name) ===
          packedCanonicalClinicName(place.name);
  if (!nameOk) return {strong: false, reason: 'name_mismatch'};
  const addrOk = addressOverlap(
      venue.address || venue.street,
      place.address || '');
  const phoneOk = phonesMatch(venue.phone, place.phone || '');
  const cityFold = String(cityDisplayName(city) || '').toLowerCase();
  const blob = `${venue.address} ${venue.city} ${place.address}`.toLowerCase();
  const cityOk = !cityFold || blob.includes(cityFold) ||
      String(place.address || '').toLowerCase().includes(cityFold);
  const strong = nameOk && (addrOk || phoneOk || cityOk);
  return {strong, reason: strong ? 'strong' : 'weak_identity'};
}

async function stageVenue(city, venue, googleClinic, meta) {
  const id = `${importCityKey(city)}_${venue.freshaVenueId || 'x'}`.slice(0, 400);
  await admin.firestore().collection(STAGING_COLLECTION).doc(id).set({
    city: cityDisplayName(city),
    provider: PROVIDER_FRESHA,
    venue,
    googlePlaceId: String((googleClinic && googleClinic.placeId) || ''),
    googleName: String((googleClinic && googleClinic.name) || ''),
    matchReason: String((meta && meta.reason) || ''),
    marketplace_identity_verified: meta && meta.strong === true,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
}

async function saveRawServices(city, venue, googleClinic, services) {
  if (!services.length) return;
  const id = `${importCityKey(city)}_${venue.freshaVenueId || 'x'}`.slice(0, 400);
  await admin.firestore().collection(RAW_SERVICES_COLLECTION).doc(id).set({
    city: cityDisplayName(city),
    provider: PROVIDER_FRESHA,
    freshaVenueId: venue.freshaVenueId,
    venueUrl: venue.venueUrl,
    venueName: venue.name,
    googlePlaceId: String((googleClinic && googleClinic.placeId) || ''),
    services: services.map((s) => ({
      name: s.name,
      raw_procedure_text: s.name,
      raw_price_text: s.rawPriceText,
      price_min: s.price,
      priceValue: s.priceValue || s.price,
      currency: s.currency,
      duration: s.duration || '',
      category: s.category || '',
      source_url: s.venueUrl || venue.venueUrl,
    })),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
}

function buildFreshaPoolRow({
  venue,
  place,
  service,
  exploreProcedure,
  relation,
}) {
  const priceMin = Number(service.price || 0);
  const currency = String(service.currency || venue.currency || '').toUpperCase();
  const rawPriceText = String(service.rawPriceText || '').trim();
  const sourceUrl = String(venue.venueUrl || service.venueUrl || '').trim();
  const rawProcedure = String(service.name || '').trim();
  if (!(priceMin > 0) || !rawPriceText || !sourceUrl) return null;
  const clinicName = String((place && place.name) || venue.name || '').trim();
  if (identityReject(clinicName)) return null;

  const row = {
    name: clinicName,
    clinicName,
    place_id: String((place && place.placeId) || ''),
    placeId: String((place && place.placeId) || ''),
    rating: Number((place && place.rating) || venue.rating || 0) || 0,
    reviews: Number((place && place.reviews) || venue.reviewsCount || 0) || 0,
    lat: Number((place && place.lat) || venue.latitude || 0) || 0,
    lng: Number((place && place.lng) || venue.longitude || 0) || 0,
    address: String((place && place.address) || venue.address || ''),
    area: String((place && place.address) || venue.address || ''),
    website: String((place && place.website) || venue.website || ''),
    price_min: priceMin,
    price_max: priceMin,
    priceMin,
    currency,
    raw_price_text: rawPriceText,
    rawPriceText,
    price_label: rawPriceText,
    raw_procedure_text: rawProcedure,
    brand: rawProcedure,
    price_source_url: sourceUrl,
    sourceUrl,
    source_url: sourceUrl,
    source_type: 'marketplace',
    source_platform: PROVIDER_FRESHA,
    source_type_detail: 'fresha',
    marketplace_venue_id: venue.freshaVenueId,
    marketplace_identity_verified: true,
    provider_clinic: clinicName,
    extraction_method: 'fresha_menu',
    extractionMethod: 'fresha_menu',
    price_evidence_text: rawPriceText,
    rawEvidence: rawPriceText,
    verified: true,
    price_verified: true,
    price_verification_status: 'fresha_marketplace',
    procedure_relation: (relation && relation.logToken) || 'exact',
    verified_at: nowIso(),
    lastCheckedAt: nowIso(),
    price_extract_revision: EXTRACT_REVISION,
    scrapedAt: venue.scrapedAt || nowIso(),
  };

  if (!isValidExtractedPriceCandidate({
    rawPriceText,
    priceMin,
    currency,
    extractionMethod: 'fresha_menu',
    rawEvidence: rawPriceText,
    procedure: exploreProcedure || rawProcedure,
    logRejects: false,
  })) {
    return null;
  }
  return row;
}

function pickFromPricesByProcedure(acceptedRows) {
  const best = new Map();
  for (const row of acceptedRows) {
    const key = String(row.exploreProcedure || '').trim().toLowerCase();
    if (!key) continue;
    const prev = best.get(key);
    if (!prev || Number(row.service.price) < Number(prev.service.price)) {
      best.set(key, row);
    }
  }
  return [...best.values()];
}

async function processMatchedClinic({
  city,
  googleClinic,
  freshaRaw,
  freshaUrl,
  provider,
  poolByProcedure,
  stats,
}) {
  const venue = provider.normalizeVenue(freshaRaw, {
    fallbackUrl: freshaUrl,
    googleClinic,
  });
  if (!venue) return;

  const services = provider.normalizeServices(freshaRaw, {venueUrl: freshaUrl});
  stats.servicesSeen += services.length;

  // Service-first: inspect catalogue before pool contribution.
  if (!venueHasMedicalAestheticServices(services) || venueIsBeautyOnly(services)) {
    console.log(
        `[FRESHA IMPORT] skip beauty-only · ${venue.name}`);
    await stageVenue(city, venue, googleClinic, {reason: 'beauty_only', strong: false});
    stats.beautySkipped += 1;
    return;
  }

  // Always retain raw aesthetic catalogue for future procedures.
  await saveRawServices(city, venue, googleClinic, services);

  const identity = freshaMatchesGoogleClinic(venue, googleClinic, city);
  if (!identity.strong) {
    await stageVenue(city, venue, googleClinic, identity);
    stats.staged += 1;
    console.log(
        `[FRESHA MATCH] weak · ${venue.name} · ${identity.reason} — staged only`);
    // Still inspected; do not enter verified pool.
    return;
  }

  console.log(
      `[FRESHA MATCH] venue → Google place · "${venue.name}" → ${googleClinic.placeId}`);

  const accepted = [];
  for (const service of services) {
    const classified = classifyFreshaService(service.name, {
      venueUrl: venue.venueUrl,
    });
    if (!classified.accepted) {
      // Unknown aesthetic names already in raw catalogue.
      continue;
    }
    accepted.push({
      service,
      exploreProcedure: classified.exploreProcedure,
      relation: classified.relation,
    });
  }

  const fromRows = pickFromPricesByProcedure(accepted);
  for (const item of fromRows) {
    const poolRow = buildFreshaPoolRow({
      venue,
      place: googleClinic,
      service: item.service,
      exploreProcedure: item.exploreProcedure,
      relation: item.relation,
    });
    if (!poolRow) continue;
    console.log(
        `[FRESHA PRICE] accepted · ${poolRow.name} · ` +
        `${item.exploreProcedure} · ${poolRow.raw_price_text}`);
    const proc = item.exploreProcedure;
    if (!poolByProcedure.has(proc)) poolByProcedure.set(proc, []);
    poolByProcedure.get(proc).push(poolRow);
    stats.pricesAccepted += 1;
  }
  if (fromRows.length) stats.clinicsMatched += 1;
}

async function importFreshaCity({
  city,
  maxResults = FRESHA_MAX_RESULTS,
  force = false,
} = {}) {
  const display = cityDisplayName(city);
  if (!display || display.toLowerCase() === 'worldwide') {
    return {ok: false, reason: 'invalid_city', status: 'failed'};
  }

  if (!force) {
    const gate = await shouldStartImport(city);
    if (!gate.start) {
      console.log(`[FRESHA IMPORT] skip · ${display} · ${gate.reason}`);
      return {
        ok: true,
        skipped: true,
        reason: gate.reason,
        status: gate.state && gate.state.status,
        venues: 0,
        services: 0,
        clinics: Number((gate.state && gate.state.clinicsImported) || 0),
        prices: Number((gate.state && gate.state.pricesImported) || 0),
      };
    }
  }

  try {
    await markImportRunning(city);
  } catch (e) {
    if (e && e.code === 'already_running') {
      return {
        ok: true,
        skipped: true,
        reason: 'already_running',
        status: 'running',
        venues: 0,
        services: 0,
        clinics: 0,
        prices: 0,
      };
    }
    throw e;
  }

  console.log(`[FRESHA IMPORT] start · ${display}`);
  const provider = new FreshaProvider();
  const apiKey = String(process.env.GOOGLE_PLACES_API_KEY || '').trim();
  const serperApiKey = String(process.env.SERPER_API_KEY || '').trim();
  const dataForSeoLogin = String(process.env.DATAFORSEO_LOGIN || '').trim();
  const dataForSeoPassword = String(process.env.DATAFORSEO_PASSWORD || '').trim();
  const serpApiKey = String(process.env.SERPAPI_API_KEY || '').trim();

  const stats = {
    venues: 0,
    servicesSeen: 0,
    pricesAccepted: 0,
    clinicsMatched: 0,
    staged: 0,
    beautySkipped: 0,
    freshaUrls: 0,
  };
  const poolByProcedure = new Map();

  try {
    const clinics = await discoverAestheticClinics({
      city,
      apiKey,
      maxResults,
    });
    console.log(`[FRESHA IMPORT] google_clinics=${clinics.length}`);

    const urlByPlaceId = new Map();
    for (const clinic of clinics) {
      const found = await findFreshaVenueUrlForClinic(clinic, {
        city,
        serperApiKey,
        dataForSeoLogin,
        dataForSeoPassword,
        serpApiKey,
      });
      if (!found.url) continue;
      urlByPlaceId.set(clinic.placeId, {clinic, url: found.url});
      stats.freshaUrls += 1;
    }
    console.log(`[FRESHA IMPORT] fresha_urls=${stats.freshaUrls}`);

    const urls = [...urlByPlaceId.values()].map((x) => x.url);
    const scraped = urls.length ? await provider.scrapeVenues(urls) : [];
    stats.venues = scraped.length;

    // Index scraped venues by normalized URL.
    const byUrl = new Map();
    for (const raw of scraped) {
      const u = String((raw && (raw.url || raw.venueUrl)) || '').trim()
          .split('?')[0].replace(/\/$/, '');
      if (u) byUrl.set(u.toLowerCase(), raw);
    }

    for (const {clinic, url} of urlByPlaceId.values()) {
      const key = url.toLowerCase().split('?')[0].replace(/\/$/, '');
      let raw = byUrl.get(key);
      if (!raw) {
        // Fuzzy: slug suffix match
        for (const [k, v] of byUrl.entries()) {
          if (k.includes(key.slice(-24)) || key.includes(k.slice(-24))) {
            raw = v;
            break;
          }
        }
      }
      if (!raw) {
        stats.staged += 1;
        continue;
      }
      await processMatchedClinic({
        city,
        googleClinic: clinic,
        freshaRaw: raw,
        freshaUrl: url,
        provider,
        poolByProcedure,
        stats,
      });
    }

    let firestoreAdds = 0;
    for (const [procedure, rows] of poolByProcedure.entries()) {
      if (!rows.length) continue;
      await upsertVerified(display, procedure, rows);
      firestoreAdds += rows.length;
      console.log(
          `[FRESHA FIRESTORE] added ${rows.length} · ${display} · ${procedure}`);
    }

    const status = await markImportFinished(city, {
      venuesImported: stats.venues,
      servicesImported: stats.servicesSeen,
      pricesImported: stats.pricesAccepted,
      clinicsImported: stats.clinicsMatched,
    });

    console.log(
        `[FRESHA IMPORT] ${status} · ${stats.clinicsMatched} clinics · ` +
        `${stats.pricesAccepted} prices · staged=${stats.staged} · ` +
        `beautySkipped=${stats.beautySkipped} · firestoreRows=${firestoreAdds}`);

    return {
      ok: true,
      skipped: false,
      status,
      venues: stats.venues,
      services: stats.servicesSeen,
      clinics: stats.clinicsMatched,
      prices: stats.pricesAccepted,
      staged: stats.staged,
      freshaUrls: stats.freshaUrls,
    };
  } catch (err) {
    console.error(`[FRESHA IMPORT] failed · ${display} · ${err && err.message}`);
    await markImportFailed(city, err);
    return {
      ok: false,
      reason: String((err && err.message) || err),
      status: 'failed',
      venues: stats.venues,
      services: stats.servicesSeen,
      clinics: stats.clinicsMatched,
      prices: stats.pricesAccepted,
    };
  }
}

module.exports = {
  importFreshaCity,
  buildFreshaPoolRow,
  pickFromPricesByProcedure,
  freshaMatchesGoogleClinic,
};
