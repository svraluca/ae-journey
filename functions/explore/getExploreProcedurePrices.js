'use strict';

const {HttpsError} = require('firebase-functions/v2/https');
const {HttpClinicPageFetcher} = require('./pageFetcher');
const {renderIfNeeded} = require('./rendererClient');
const {extractPriceEvidence} = require('./priceExtractor');
const {selectEvidenceForProcedure, matchRawProcedureLabel} = require('./procedureMatch');
const {classifyLabelIfNeeded} = require('./classifyLabel');
const {searchPlaces, searchSerpUrls, findPlaceByName, discoverBroadSerpClinicCandidates} = require('./discovery');
const {pricePathsForHost} = require('./searchLocale');
const {
  loadCached,
  loadReverifyCandidates,
  upsertVerified,
  isTrustedPrice,
} = require('./firestoreStore');
const {loadHostCatalog, saveHostCatalog, EXTRACT_REVISION} = require('./clinicCatalog');
const {
  normalizeProcedureSemantics,
  mergeVerifiedNumericWithSemantics,
  standardizePriceType,
} = require('./normalizeProcedureSemantics');
const {
  discoverFirecrawlUrls,
  evidenceFromFirecrawlUrls,
} = require('./firecrawlDiscovery');
const {
  clinicIdentityRejectReason,
  extractMarketplaceProviderName,
  marketplacePlatformLabel,
  isMarketplaceOrDirectoryHost,
  marketplaceLocationStronglyMatches,
  logDiscoveryReject,
  logDiscoverySkip,
  ingestExcludeClinicKeys,
} = require('./identity');
const {hostOf, buildEvidenceHash, applyLabelClassification, isNonLiteralClinicPriceUrl} = require('./parsePrice');
const {
  loadDiscoveryState,
  isKnownPermanentReject,
  isTemporarilyBlocked,
  discoverySkipPlaceIds,
  markAccepted,
  markPermanentReject,
  markTemporaryReject,
  isPermanentRejectReason,
  isTemporaryFailureReason,
} = require('./discoveryState');
const {
  evaluateExtractedPriceCandidate,
  logPriceAccept,
} = require('./priceSanity');
const {
  loadCandidatesForProcedure,
  candidateToPlace,
  upsertCandidates,
  getCityCoverage,
  prioritizePlaces,
  markCandidateAttempt,
} = require('./clinicCandidateStore');
const {discoveryQueriesForProcedure} = require('./brightdata/discoveryQueries');
const {pageHasRequestedFamilyWitness} = require('./procedureRelation');

const INTERACTIVE_DEADLINE_MS = 8000;
const DEEP_DEADLINE_MS = 110000;
const INTERACTIVE_CANDIDATE_RESERVE_MS = 700;
const SERP_MIN_REMAINING_MS = 1800;
const FIRECRAWL_MIN_REMAINING_MS = 4000;

function uniqueUrls(urls) {
  const seen = new Set();
  const out = [];
  for (const url of urls || []) {
    const u = String(url || '').trim();
    if (!u || seen.has(u)) continue;
    seen.add(u);
    out.push(u);
  }
  return out;
}

/** Cache → catalog → family paths → official page → SERP. Never SERP-first. */
function stagedVerifyUrls({
  base,
  host,
  procedure,
  cachedSuccess = [],
  serpUrls = [],
} = {}) {
  return {
    siteUrlCache: uniqueUrls(cachedSuccess),
    familyPaths: uniqueUrls(
        (familyPaths(procedure) || []).map((p) => `${base}${p}`)),
    officialPage: uniqueUrls([
      base,
      ...(pricePathsForHost(host) || []).map((p) => `${base}${p}`),
    ]),
    serp: uniqueUrls(
        (serpUrls || []).filter((u) => !isNonLiteralClinicPriceUrl(u))),
  };
}

function familyPaths(procedure) {
  const t = String(procedure || '').toLowerCase();
  if (t.includes('botox') || t.includes('toxin')) {
    return [
      '/botox', '/pages/botox', '/toxina-botulinica', '/estompare-riduri',
      '/eliminare-riduri-neuromodulator', '/injectari', '/neuromodulator',
    ];
  }
  if (t.includes('filler') || t.includes('labio') || t.includes('hialuron')) {
    return [
      '/aumento-labios', '/aumento-de-labios', '/fillers', '/rellenos',
      '/marire-buze', '/acid-hialuronic', '/pages/preturi-injectari',
    ];
  }
  if (t.includes('laser')) return ['/laser', '/depilacion-laser', '/epilare-laser'];
  if (t.includes('peel')) return ['/peeling', '/peeling-quimico', '/peeling-chimic'];
  if (t.includes('rhino') || t.includes('rinoplast')) {
    return [
      '/rinoplastia', '/rhinoplasty', '/rinoplastie',
      '/rhinoplastie', '/nasenkorrektur', '/rinoplasti',
    ];
  }
  if (t.includes('breast') || t.includes('boob') || t.includes('mamar') ||
      t.includes('pecho')) {
    return [
      '/aumento-de-pecho', '/mamoplastia', '/marire-sani',
      '/breast-augmentation',
    ];
  }
  if (t.includes('hair') || t.includes('fue') || t.includes('injerto') ||
      t.includes('transplant de par')) {
    return [
      '/injerto-capilar', '/fue', '/transplant-de-par', '/hair-transplant',
    ];
  }
  return [];
}

function formatListedAmount(min) {
  const n = Number(min);
  if (!Number.isFinite(n) || n <= 0) return '';
  if (Math.abs(n - Math.trunc(n)) < 0.05) return String(Math.trunc(n));
  return String(Math.trunc(n));
}

function formatLabel(min, currency) {
  const n = formatListedAmount(min);
  if (currency === 'EUR' || currency === '€') return `from ${n} €`;
  if (currency === 'GBP' || currency === '£') return `from £${n}`;
  if (currency === 'RON') return `from ${n} RON`;
  return `from ${n} ${currency}`.trim();
}

function clinicJson({place, evidence, city}) {
  const sourceUrl = evidence.sourceUrl;
  const host = hostOf(sourceUrl);
  // Bright Data (or other) may have fetched the page — never store as sourceType.
  const discoveryProvider = evidence.discoveryProvider ||
      place.discovery_provider || 'google_places';
  let sourceType = evidence.sourceType || 'official_clinic';
  if (String(sourceType).toLowerCase() === 'brightdata') {
    sourceType = 'official_clinic';
  }
  const unitType = evidence.unitType || evidence.unit || evidence.priceUnit || null;
  const unitQuantity = evidence.unitQuantity ?? evidence.quantity ??
      evidence.priceQuantity ?? null;
  const priceType = standardizePriceType(evidence.priceType, unitType);
  const nowIso = new Date().toISOString();
  return {
    name: place.name,
    clinicName: place.name,
    city,
    address: place.address || place.formattedAddress || '',
    website: place.website || '',
    area: host ? `${host} · src:${sourceUrl}` : `src:${sourceUrl}`,
    rating: place.rating || 0,
    reviews: place.reviews || 0,
    lat: place.lat || 0,
    lng: place.lng || 0,
    // Canonical verified numeric fields (snake_case for Flutter/Firestore).
    price_min: evidence.priceMin,
    price_max: evidence.priceMax,
    priceMin: evidence.priceMin,
    priceMax: evidence.priceMax,
    price_gbp: Math.round(evidence.priceMin),
    price_label: priceType === 'approximate'
      ? formatLabel(evidence.priceMin, evidence.currency).replace(/^from /, 'approximately ')
      : formatLabel(evidence.priceMin, evidence.currency),
    currency: evidence.currency || '',
    currency_confirmed: Boolean(String(evidence.currency || '').trim()),
    brand: evidence.rawProcedureText,
    has_procedure: true,
    price_pending: false,
    price_source_url: sourceUrl,
    sourceUrl,
    sourceHost: host,
    sourceType,
    source_type: sourceType,
    source_platform: evidence.sourcePlatform || '',
    provider_clinic: evidence.providerClinic || place.providerClinic || '',
    raw_procedure_text: evidence.rawProcedureText,
    rawProcedureText: evidence.rawProcedureText,
    raw_price_text: evidence.rawPriceText,
    rawPriceText: evidence.rawPriceText,
    rawEvidence: String(evidence.rawEvidence || '').slice(0, 180),
    extraction_method: evidence.extractionMethod,
    extractionMethod: evidence.extractionMethod,
    evidence_hash: evidence.evidenceHash ||
      buildEvidenceHash(sourceUrl, evidence.rawProcedureText, evidence.rawPriceText),
    price_type: priceType,
    priceType,
    price_unit: unitType || '',
    unitType: unitType || null,
    price_quantity: unitQuantity,
    unitQuantity,
    procedure_family: evidence.procedureFamily,
    procedureFamily: evidence.procedureFamily,
    procedure_canonical: evidence.procedureCanonical || evidence.canonicalProcedure,
    canonicalProcedure: evidence.canonicalProcedure || evidence.procedureCanonical,
    procedure_relation: evidence.procedureRelation || '',
    procedureRelation: evidence.procedureRelation || '',
    amount_literal_verified: evidence.amountLiteralVerified !== false,
    procedure_evidence_verified: evidence.procedureEvidenceVerified !== false,
    amountLiteralVerified: evidence.amountLiteralVerified !== false,
    procedureEvidenceVerified: evidence.procedureEvidenceVerified !== false,
    price_verification_status: 'official_website',
    price_verified: true,
    priceVerified: true,
    verified: true,
    needs_reverification: false,
    verifiedAt: nowIso,
    price_verified_at: nowIso,
    lastCheckedAt: nowIso,
    price_evidence_text: String(evidence.rawEvidence || '').slice(0, 180),
    place_id: place.placeId || '',
    placeId: place.placeId || '',
    discovery_provider: discoveryProvider,
    discoveryProvider,
    price_extract_revision: EXTRACT_REVISION,
    extractRevision: EXTRACT_REVISION,
    normalizer_version: evidence.normalizerVersion || '',
    normalizerVersion: evidence.normalizerVersion || '',
  };
}

function pastDeadline(deadlineAt, reserveMs = 400) {
  if (!deadlineAt) return false;
  return Date.now() + reserveMs >= Number(deadlineAt);
}

async function htmlForUrl(fetcher, url, {deep = false, deadlineAt = 0} = {}) {
  const {useBrightData, useZyteFallback, usePlaywrightFallback} =
      require('./featureFlags');
  const page = await fetcher.fetch(url);
  console.log(`[DIRECT HTTP] ${url} · status=${page.statusCode || 0}` +
      `${page.jsShell ? ' · jsShell' : ''}${page.blocked ? ' · blocked' : ''}`);

  const blockedByStatus = page.blocked && Number(page.statusCode || 0) >= 400;
  const needsUnlock = !page.html || page.jsShell || blockedByStatus ||
      page.needsRendering;

  // Interactive: HTTP first; Unlocker only when blocked/JS.
  if (!needsUnlock && page.html) {
    return page;
  }
  if (pastDeadline(deadlineAt, 1200)) {
    return page;
  }

  if (useBrightData()) {
    const {fetchUnlockedHtml} = require('./brightdata/brightDataUnlocker');
    const unlocked = await fetchUnlockedHtml(url);
    if (unlocked) {
      console.log(`[PRICE SOURCE] brightdata_unlocker · ${url}`);
      return {url, html: unlocked, rendered: true, fromBrightData: true};
    }
  }

  // Playwright only when explicitly enabled (dev/debug).
  if (deep && !pastDeadline(deadlineAt, 4000) && usePlaywrightFallback() &&
      (page.needsRendering || page.jsShell || blockedByStatus)) {
    const rendered = await renderIfNeeded(url);
    if (rendered.html) {
      console.log(`[EXTRACT] ${extractPriceEvidence({html: rendered.html, sourceUrl: url}).length} price rows`);
      return rendered;
    }
    console.log('[VERIFY] no literal price evidence (renderer unavailable or failed)');
  }

  // Zyte behind feature flag only.
  if (!pastDeadline(deadlineAt, 2500) &&
      useZyteFallback() && (!page.html || page.jsShell || blockedByStatus)) {
    const {fetchZyteBrowserHtml} = require('./zyteClient');
    const zyteHtml = await fetchZyteBrowserHtml(url);
    if (zyteHtml) {
      console.log(`[PRICE SOURCE] zyte_browserHtml · ${url}`);
      return {html: zyteHtml, url, fromZyte: true};
    }
  }
  return page;
}

async function evidenceFromUrls(fetcher, urls, procedure, {
  clinicName, city, deep = false, deadlineAt = 0,
} = {}) {
  const all = [];
  const seen = new Set();
  for (const url of urls) {
    if (pastDeadline(deadlineAt, 600)) break;
    if (!url || seen.has(url)) continue;
    if (isNonLiteralClinicPriceUrl(url)) {
      console.log(`[VERIFY] skip blog/guide ${url}`);
      continue;
    }
    seen.add(url);
    const cachedCat = await loadHostCatalog(url);
    if (cachedCat.length) {
      all.push(...cachedCat);
      continue;
    }
    const page = await htmlForUrl(fetcher, url, {deep, deadlineAt});
    if (!page.html) continue;
    const rows = extractPriceEvidence({html: page.html, sourceUrl: page.url || url});
    if (rows.length) {
      console.log(`[EXTRACT] ${rows.length} price rows`);
      await saveHostCatalog({url: page.url || url, clinicName, city, evidence: rows});
    }
    all.push(...rows);
  }
  return all;
}

async function verifyPlace(fetcher, place, {
  city, procedure, deep = false, deadlineAt = 0, countryCode = '',
} = {}) {
  if (!place.website) return null;
  const base = place.website.replace(/\/+$/, '');
  let host;
  try {
    host = new URL(base.includes('://') ? base : `https://${base}`).host;
  } catch (_) {
    return null;
  }

  let cachedEntries = [];
  try {
    const {loadCachedSiteUrlEntries} = require('./siteUrlCache');
    cachedEntries = await loadCachedSiteUrlEntries(host);
  } catch (_) {
    cachedEntries = [];
  }
  const cachedSuccess = cachedEntries
      .filter((e) => Number(e.successCount || 0) > 0 || e.lastSuccessAt)
      .map((e) => e.url);
  const stages = stagedVerifyUrls({
    base,
    host,
    procedure,
    cachedSuccess,
  });
  console.log(
      `[BRIGHTDATA URL] cache-first cached=${stages.siteUrlCache.length} ` +
      `family=${stages.familyPaths.length} official=${stages.officialPage.length} ` +
      `· ${place.name}`);

  let rows = [];
  let picked = null;
  const collect = async (urls, label) => {
    if (picked || !urls.length) return;
    if (pastDeadline(deadlineAt, 600)) return;
    const found = await evidenceFromUrls(fetcher, urls, procedure, {
      clinicName: place.name,
      city,
      deep,
      deadlineAt,
    });
    if (found.length) {
      rows = [...rows, ...found];
      picked = selectEvidenceForProcedure(rows, procedure);
      if (picked) {
        console.log(`[VERIFY] evidence via ${label} · ${place.name}`);
      }
    }
  };

  // 1. Previously successful cached procedure URLs — never pay SERP first.
  await collect(stages.siteUrlCache, 'siteUrlCache');
  // 2. Host catalog evidence.
  if (!picked && !pastDeadline(deadlineAt, 400)) {
    const catalog = await loadHostCatalog(base);
    if (catalog.length) {
      rows = [...rows, ...catalog];
      picked = selectEvidenceForProcedure(rows, procedure);
      if (picked) {
        console.log(`[VERIFY] evidence via hostCatalog · ${place.name}`);
      }
    }
  }
  // 3. Strongly procedure-specific known paths.
  await collect(stages.familyPaths, 'familyPaths');
  // 4. Direct official page + generic price paths.
  await collect(stages.officialPage, 'officialPage');
  // 5. SERP only if cheaper evidence failed and budget remains.
  if (!picked && !pastDeadline(deadlineAt, SERP_MIN_REMAINING_MS)) {
    const serp = await searchSerpUrls({
      city,
      procedure,
      websiteHost: host,
      countryCode,
      apiKey: process.env.SERPAPI_API_KEY,
      serperApiKey: process.env.SERPER_API_KEY,
      dataForSeoLogin: process.env.DATAFORSEO_LOGIN,
      dataForSeoPassword: process.env.DATAFORSEO_PASSWORD,
      maxResults: 4,
    });
    await collect(
        stagedVerifyUrls({base, host, procedure, serpUrls: serp.map((s) => s.url)}).serp,
        'serp');
  } else if (!picked && pastDeadline(deadlineAt, SERP_MIN_REMAINING_MS)) {
    console.log(`[VERIFY] skip SERP · budget · ${place.name}`);
  }
  // 6. Firecrawl / renderer only in deep background mode.
  if (!picked && deep && !pastDeadline(deadlineAt, FIRECRAWL_MIN_REMAINING_MS)) {
    console.log(`[DISCOVERY] sitemap/firecrawl fallback · ${place.name} · ${host}`);
    const fcUrls = await discoverFirecrawlUrls({
      websiteUrl: base,
      procedure,
      city,
      clinicName: place.name,
      maxUrls: 5,
    });
    if (fcUrls.length) {
      const fcRows = await evidenceFromFirecrawlUrls({
        urls: fcUrls,
        procedure,
        city,
        clinicName: place.name,
        htmlForUrl: (u) => htmlForUrl(fetcher, u, {deep, deadlineAt}),
      });
      if (fcRows.length) {
        rows = [...rows, ...fcRows];
        await saveHostCatalog({
          url: fcRows[0].sourceUrl || base,
          clinicName: place.name,
          city,
          evidence: fcRows,
        });
        picked = selectEvidenceForProcedure(rows, procedure);
      }
    }
  }
  if (!picked) {
    for (const row of rows) {
      const match = matchRawProcedureLabel(row.rawProcedureText, procedure);
      if (match.rejectReason) continue;
      if (match.family === 'other') {
        const classified = await classifyLabelIfNeeded(row.rawProcedureText, procedure);
        const merged = applyLabelClassification(row, classified);
        if (merged.procedureFamily && merged.procedureFamily !== 'other') {
          picked = {...row, ...merged, priceMin: row.priceMin};
          break;
        }
      }
    }
  }
  if (!picked) {
    const offered = pageHasRequestedFamilyWitness(rows, procedure);
    console.log(
        `[VERIFY] clinic=${place.name} offers=${offered} price=false`);
    return {
      ratingOnly: {
        name: place.name,
        rating: place.rating,
        reviews: place.reviews,
        lat: place.lat,
        lng: place.lng,
        area: hostOf(place.website),
        price_min: 0,
        price_verified: false,
        verified: false,
      },
      procedureOffered: offered,
    };
  }
  if (picked.sourceType === 'search_snippet') {
    console.log(`[VERIFY] skipped untrusted source=${picked.sourceType}`);
    return null;
  }
  let providerName = String(picked.providerClinic || '').trim();
  let identityPlace = place;
  if (picked.sourceType === 'marketplace' ||
      picked.sourceType === 'aggregator' ||
      isMarketplaceOrDirectoryHost(picked.sourceUrl || place.website)) {
    if (!providerName) {
      const html = (await htmlForUrl(fetcher, picked.sourceUrl, {deep, deadlineAt})).html || '';
      providerName = extractMarketplaceProviderName(html, {
        sourceUrl: picked.sourceUrl,
        marketplaceName: place.name,
      });
    }
    if (!providerName) {
      logDiscoveryReject('marketplace_without_provider', {
        placeId: place.placeId,
        name: place.name,
      });
      return {permanentReject: 'marketplace_without_provider'};
    }
    const pageBlob = `${picked.rawEvidence || ''} ${picked.rawProcedureText || ''} ${picked.rawPriceText || ''}`;
    if (!marketplaceLocationStronglyMatches({
      city,
      placeAddress: place.address || place.formattedAddress || '',
      sourceUrl: picked.sourceUrl,
      pageText: pageBlob,
    })) {
      logDiscoveryReject('marketplace_location_mismatch', {
        placeId: place.placeId,
        name: place.name,
      });
      return {permanentReject: 'marketplace_location_mismatch'};
    }
    const resolved = await findPlaceByName({
      name: providerName,
      city,
      apiKey: process.env.GOOGLE_PLACES_API_KEY,
    });
    identityPlace = resolved
      ? {...resolved, providerClinic: providerName}
      : {...place, name: providerName, providerClinic: providerName, website: resolved && resolved.website || ''};
    picked = {
      ...picked,
      providerClinic: providerName,
      sourcePlatform: picked.sourcePlatform || marketplacePlatformLabel(picked.sourceUrl),
      sourceType: 'marketplace',
    };
  }
  const identityReason = clinicIdentityRejectReason(identityPlace.name, {
    websiteHost: hostOf(identityPlace.website || picked.sourceUrl || ''),
    providerClinic: providerName,
    sourceType: picked.sourceType,
  });
  if (identityReason) {
    logDiscoveryReject(identityReason, {
      placeId: identityPlace.placeId || place.placeId,
      name: identityPlace.name,
    });
    return {permanentReject: identityReason};
  }
  const sanity = evaluateExtractedPriceCandidate({
    rawPriceText: picked.rawPriceText,
    priceMin: picked.priceMin,
    currency: picked.currency,
    extractionMethod: picked.extractionMethod,
    rawEvidence: picked.rawEvidence,
    procedure,
    sourceUrl: picked.sourceUrl,
    priceMax: picked.priceMax,
    structuredOffer: picked.extractionMethod === 'json_ld' ||
        picked.extractionMethod === 'schema_offer',
  });
  if (!sanity.accepted) {
    console.log(`[VERIFY] rejected ${place.name} · ${sanity.reason}`);
    return null;
  }

  // Lock numeric evidence BEFORE any semantic LLM call.
  const verifiedNumericEvidence = {
    priceMin: picked.priceMin,
    priceMax: picked.priceMax,
    currency: picked.currency,
    rawPriceText: picked.rawPriceText,
    rawEvidence: picked.rawEvidence,
    sourceUrl: picked.sourceUrl,
    sourceType: picked.sourceType || 'official_clinic',
    sourcePlatform: picked.sourcePlatform || '',
    providerClinic: picked.providerClinic || '',
    extractionMethod: picked.extractionMethod,
    evidenceHash: picked.evidenceHash,
    priceType: picked.priceType,
    unit: picked.unit || picked.priceUnit || '',
    quantity: picked.quantity ?? picked.priceQuantity ?? null,
    rawProcedureText: picked.rawProcedureText,
    procedureFamily: picked.procedureFamily,
    procedureCanonical: picked.procedureCanonical,
    procedureRelation: picked.procedureRelation || '',
    discoveryProvider: place.discovery_provider ||
        (picked.fromBrightData ? 'brightdata' : 'google_places'),
  };

  const semantics = await normalizeProcedureSemantics({
    rawLabel: picked.rawProcedureText,
    serviceLabel: picked.rawEvidence || '',
    requestedProcedure: procedure,
    city,
    sourceUrl: picked.sourceUrl,
    clinicOwnQuoted: true,
    existingUnit: verifiedNumericEvidence.unit,
    existingQuantity: verifiedNumericEvidence.quantity,
  });
  if (!semantics.eligible) {
    console.log(
        `[VERIFY] rejected ${place.name} · semantic_${semantics.rejectReason || semantics.relation}`);
    return null;
  }

  const merged = mergeVerifiedNumericWithSemantics(
      verifiedNumericEvidence, semantics);
  // Hard guard: semantics must never alter locked amounts.
  if (merged.priceMin !== verifiedNumericEvidence.priceMin ||
      merged.priceMax !== verifiedNumericEvidence.priceMax ||
      merged.currency !== verifiedNumericEvidence.currency ||
      merged.rawPriceText !== verifiedNumericEvidence.rawPriceText) {
    console.log(`[VERIFY] rejected ${place.name} · semantic_price_overwrite_blocked`);
    return null;
  }

  logPriceAccept({
    clinic: identityPlace.name,
    procedure,
    rawPriceText: merged.rawPriceText,
    parsedAmount: merged.priceMin,
    currency: merged.currency,
    extractionMethod: merged.extractionMethod,
    sourceUrl: merged.sourceUrl,
  });
  console.log(
      `[VERIFY] clinic=${identityPlace.name} accepted ` +
      `${merged.priceMin} ${merged.currency}`);
  return {
    clinic: clinicJson({place: identityPlace, evidence: merged, city}),
    stages: {
      pageFound: true,
      pageFetched: true,
      evidenceExtracted: true,
      procedureMatched: true,
      cityMatched: true,
    },
  };
}

/**
 * Callable handler. Flutter paints Firestore immediately; this returns fresh verified rows.
 */
async function handleGetExploreProcedurePrices(request) {
  const data = request.data || {};
  const city = String(data.city || '').trim();
  const procedure = String(data.procedure || '').trim();
  try {
    return await _handleGetExploreProcedurePricesBody(request);
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    const msg = err && err.message ? String(err.message) : String(err);
    const type = err && err.name ? String(err.name) : typeof err;
    console.error(
        '[BACKEND ERROR] stage=getExploreProcedurePrices ' +
        `type=${type} city=${city} procedure=${procedure} message=${msg}`);
    if (err && err.stack) {
      console.error('[BACKEND ERROR] stack=', err.stack);
    }
    throw new HttpsError(
        'internal',
        `Explore backend failed (${type}): ${msg.slice(0, 180)}`,
    );
  }
}

/**
 * Callable handler body. Flutter paints Firestore immediately; this returns fresh verified rows.
 */
async function _handleGetExploreProcedurePricesBody(request) {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Sign in required');
  }
  const data = request.data || {};
  const {normalizeExploreLocality} = require('./cityIdentity');
  const locality = normalizeExploreLocality(data);
  const city = locality.city || String(data.city || '').trim();
  const cityId = locality.cityId;
  const countryCode = locality.countryCode;
  const procedure = String(data.procedure || '').trim();
  const excludeClinicKeys = data.excludeClinicKeys || [];
  const freshLimit = Math.min(4, Math.max(1, Number(data.freshLimit) || 2));
  const deep = String(data.mode || 'interactive').trim().toLowerCase() === 'deep';
  const logTag = deep ? '[BACKEND DEEP]' : '[BACKEND QUICK]';
  const startedAt = Date.now();
  const deadlineAt = startedAt + (deep ? DEEP_DEADLINE_MS : INTERACTIVE_DEADLINE_MS);
  if (!city || !procedure) {
    throw new HttpsError('invalid-argument', 'city and procedure required');
  }

  console.log(
      `[EXPLORE CITY] display=${city} cityId=${cityId || '-'} cc=${countryCode || '-'}`);
  console.log(
      `${logTag} ${city} · ${procedure} · revision=${EXTRACT_REVISION} · ` +
      `limit=${freshLimit}`);
  const cachedRaw = await loadCached(city, procedure, {cityId});
  const cached = cachedRaw.filter(isTrustedPrice);
  const discoveryState = await loadDiscoveryState(city, procedure, {cityId});
  // Permanent + active-temporary rejects only. Accepted IDs stay discoverable
  // so a clinic stamped with an older revision can be re-verified; duplicates
  // of currently trusted clinics are filtered by `seen` / excludeClinicKeys.
  const skipPlaceIds = discoverySkipPlaceIds(discoveryState);

  const fetcher = new HttpClinicPageFetcher();
  const coverage = await getCityCoverage(city, procedure, {cityId});
  const storedRows = await loadCandidatesForProcedure(city, procedure, {
    limit: deep ? 24 : 12,
    cityId,
  });
  const storedPlaces = storedRows
      .map(candidateToPlace)
      .filter((p) => p.website);
  const reverifyPlaces = await loadReverifyCandidates(city, procedure, {cityId});
  const needPlaces = storedPlaces.length < (deep ? 8 : 4);
  let discoveredPlaces = [];
  if (needPlaces && !pastDeadline(deadlineAt, 2500)) {
    discoveredPlaces = await searchPlaces({
      city,
      procedure,
      countryCode,
      apiKey: process.env.GOOGLE_PLACES_API_KEY,
      maxResults: deep ? 10 : 5,
      skipPlaceIds,
      queries: discoveryQueriesForProcedure(procedure, city, {
        countryCode,
        countryName: locality.countryName,
        asciiCity: locality.canonicalName || city,
      }),
      paginate: false,
      verifiedVisibleCount: Number(coverage?.verifiedVisibleCount) ||
          cached.length ||
          0,
      deep,
    });
    if (discoveredPlaces.length) {
      await upsertCandidates({
        city,
        procedure,
        clinics: discoveredPlaces,
        provider: 'google_places',
        cityId,
        countryCode,
      });
    }
  } else {
    console.log(
        `${logTag} using stored candidates=${storedPlaces.length} · skip extra Places`);
  }

  // Broad web discovery (no site:) when still under the visible target.
  // Serper finds domains; verifyPlace still owns official-page prices.
  let serpBroadPlaces = [];
  const verifiedSoFar = Number(coverage?.verifiedVisibleCount) || cached.length || 0;
  if (verifiedSoFar < 4 && !pastDeadline(deadlineAt, 2000)) {
    try {
      const leads = await discoverBroadSerpClinicCandidates({
        city,
        procedure,
        countryCode,
        serperApiKey: process.env.SERPER_API_KEY || '',
        dataForSeoLogin: process.env.DATAFORSEO_LOGIN || '',
        dataForSeoPassword: process.env.DATAFORSEO_PASSWORD || '',
        apiKey: process.env.SERPAPI_API_KEY || '',
        maxResults: deep ? 10 : 6,
        maxQueries: deep ? 5 : 4,
      });
      console.log(`${logTag} broad SERP leads=${leads.length}`);
      for (const lead of leads) {
        const website = String(lead.officialWebsite || '').trim();
        if (!website) continue;
        serpBroadPlaces.push({
          placeId: '',
          name: lead.name,
          website,
          address: '',
          rating: 0,
          userRatingsTotal: 0,
          lat: null,
          lng: null,
          discoveryProvider: 'serp_broad',
        });
      }
      if (serpBroadPlaces.length) {
        await upsertCandidates({
          city,
          procedure,
          clinics: serpBroadPlaces,
          provider: 'serp_broad',
          cityId,
          countryCode,
        });
      }
    } catch (e) {
      console.log(`${logTag} broad SERP discovery failed · ${e && e.message}`);
    }
  }

  const places = prioritizePlaces({
    reverify: reverifyPlaces,
    stored: storedPlaces,
    places: discoveredPlaces,
    serp: serpBroadPlaces,
  });
  // One line per request: the four inputs that decide whether fill-to-N can
  // reach its target. `cached` counts only currently-trusted rows, so a drop
  // here after a revision bump is expected and shows up as extra reverify work.
  console.log(
      `${logTag} inputs · cached=${cached.length} ` +
      `reverify=${reverifyPlaces.length} stored=${storedPlaces.length} ` +
      `discovered=${discoveredPlaces.length} ` +
      `serpBroad=${serpBroadPlaces.length} · queue=${places.length}`);

  const seen = new Set();
  const markSeen = (place, clinic) => {
    const id = String(place.placeId || clinic && clinic.place_id || '').trim();
    if (id) seen.add(`id:${id}`);
    const host = hostOf(place.website || (clinic && (clinic.sourceUrl || clinic.price_source_url)) || '');
    if (host) seen.add(`host:${host}`);
    const name = String(place.name || (clinic && clinic.name) || '').toLowerCase().trim();
    if (name) seen.add(`name:${name}`);
  };
  const alreadySeen = (place) => {
    const id = String(place.placeId || '').trim();
    if (id && (seen.has(`id:${id}`) || seen.has(`id:${id.toLowerCase()}`))) {
      return true;
    }
    const host = hostOf(place.website || '');
    if (host && (seen.has(`host:${host}`) || seen.has(`host:${host.toLowerCase()}`))) {
      return true;
    }
    const name = String(place.name || '').toLowerCase().trim();
    return name && seen.has(`name:${name}`);
  };
  for (const c of cached) {
    markSeen({
      placeId: c.place_id,
      website: c.price_source_url || c.sourceUrl,
      name: c.name,
    }, c);
  }
  ingestExcludeClinicKeys(excludeClinicKeys, seen);

  const fresh = [];
  let cursor = 0;
  const workerCount = deep ? 6 : 4;
  const stages = {
    discovered: places.length,
    officialDomainResolved: 0,
    pageFound: 0,
    pageFetched: 0,
    evidenceExtracted: 0,
    procedureMatched: 0,
    cityMatched: 0,
    accepted: 0,
    rejectedByReason: {},
  };
  const bumpReject = (reason) => {
    const key = String(reason || 'unknown');
    stages.rejectedByReason[key] = (stages.rejectedByReason[key] || 0) + 1;
  };

  async function verifyOne(place) {
    const placeId = String(place.placeId || '').trim();
    if (placeId && isKnownPermanentReject(discoveryState, placeId)) {
      logDiscoveryReject('duplicate_known', {placeId, name: place.name});
      bumpReject('duplicate_known');
      return;
    }
    if (placeId && isTemporarilyBlocked(discoveryState, placeId)) {
      logDiscoveryReject('temporary_fetch_failure', {placeId, name: place.name});
      bumpReject('temporary_fetch_failure');
      return;
    }
    if (alreadySeen(place)) {
      logDiscoverySkip('current_procedure_already_seen', {
        placeId,
        name: place.name,
        procedure,
      });
      bumpReject('already_seen');
      return;
    }
    const identityReason = clinicIdentityRejectReason(place.name, {
      websiteHost: hostOf(place.website || ''),
    });
    if (identityReason) {
      logDiscoveryReject(identityReason, {placeId, name: place.name});
      bumpReject(identityReason);
      if (placeId) await markPermanentReject(city, procedure, placeId, identityReason, {cityId});
      return;
    }
    if (place.website) stages.officialDomainResolved++;
    const remaining = Number(deadlineAt) - Date.now();
    if (remaining < INTERACTIVE_CANDIDATE_RESERVE_MS) {
      console.log(`${logTag} no time for ${place.name}`);
      bumpReject('deadline');
      return;
    }
    let verified;
    try {
      verified = await Promise.race([
        verifyPlace(fetcher, place, {
          city, procedure, deep, deadlineAt, countryCode,
        }),
        new Promise((resolve) => {
          setTimeout(
              () => resolve({budgetExhausted: true}),
              Math.max(INTERACTIVE_CANDIDATE_RESERVE_MS, remaining));
        }),
      ]);
    } catch (err) {
      const msg = String(err && err.message || err || '');
      const temp = isTemporaryFailureReason(msg) || /timeout|ECONNRESET|unavailable|5\d\d/i.test(msg);
      logDiscoveryReject(temp ? 'temporary_fetch_failure' : 'invalid_price', {
        placeId,
        name: place.name,
      });
      bumpReject(temp ? 'temporary_fetch_failure' : 'invalid_price');
      if (placeId && temp) {
        await markTemporaryReject(
            city, procedure, placeId, 'temporary_fetch_failure', undefined, {cityId});
      }
      markSeen(place, null);
      return;
    }
    if (verified && verified.budgetExhausted) {
      console.log(`${logTag} candidate budget exhausted · ${place.name}`);
      bumpReject('budget_exhausted');
      markSeen(place, null);
      return;
    }
    if (verified && verified.permanentReject) {
      bumpReject(verified.permanentReject);
      if (placeId) {
        await markPermanentReject(
            city, procedure, placeId, verified.permanentReject, {cityId});
      }
      markSeen(place, null);
      return;
    }
    if (verified && verified.stages) {
      if (verified.stages.pageFound) stages.pageFound++;
      if (verified.stages.pageFetched) stages.pageFetched++;
      if (verified.stages.evidenceExtracted) stages.evidenceExtracted++;
      if (verified.stages.procedureMatched) stages.procedureMatched++;
      if (verified.stages.cityMatched) stages.cityMatched++;
    }
    if (verified && verified.clinic) {
      if (!(verified.stages && verified.stages.cityMatched)) {
        stages.cityMatched++;
      }
      stages.accepted++;
      markSeen(place, verified.clinic);
      fresh.push(verified.clinic);
      // Progressive store — do not wait for all candidates.
      if (placeId) await markAccepted(city, procedure, placeId, {cityId});
      await upsertVerified(city, procedure, [verified.clinic], {cityId});
      if (place.fromCandidateStore) {
        await markCandidateAttempt(place, {
          procedure,
          verified: true,
          offered: true,
        });
      }
      try {
        const {saveCachedSiteUrls} = require('./siteUrlCache');
        const src = verified.clinic.price_source_url || verified.clinic.sourceUrl;
        if (src) {
          await saveCachedSiteUrls({
            hostOrUrl: src,
            urls: [src],
            procedure,
            city,
            clinicName: verified.clinic.name,
            source: 'official_website',
            extractionMethod: verified.clinic.extraction_method || '',
            procedureFamily: verified.clinic.procedure_family || '',
            canonicalProcedure: procedure,
            success: true,
          });
        }
      } catch (_) {
        // non-fatal
      }
      console.log(
          `${logTag} progressive accept · ${verified.clinic.name} · ` +
          `accepted=${stages.accepted}/${freshLimit}`);
    } else {
      bumpReject((verified && verified.rejectReason) || 'no_verified_price');
      markSeen(place, null);
      if (place.fromCandidateStore && verified && verified.procedureOffered) {
        await markCandidateAttempt(place, {
          procedure,
          offered: true,
          priceStatus: 'no_public_price',
        });
      }
    }
  }

  async function worker() {
    while (true) {
      if (fresh.length >= freshLimit) return;
      if (pastDeadline(deadlineAt, INTERACTIVE_CANDIDATE_RESERVE_MS)) {
        console.log(
          `${logTag} deadline — stop new candidates · fresh=${fresh.length}`,
        );
        return;
      }
      const place = places[cursor++];
      if (!place) return;
      await verifyOne(place);
    }
  }

  await Promise.all(
    Array.from({length: Math.min(workerCount, places.length || 1)}, () => worker()),
  );

  const status = fresh.length >= freshLimit ? 'complete' : 'exhausted';
  console.log(
      `${logTag} ${city} · ${procedure} · revision=${EXTRACT_REVISION} · ` +
      `cached=${cached.length} · fresh=${fresh.length}/${freshLimit} · ` +
      `status=${status}`);
  console.log(
      `${logTag} stages · discovered=${stages.discovered} ` +
      `domain=${stages.officialDomainResolved} ` +
      `pageFound=${stages.pageFound} pageFetched=${stages.pageFetched} ` +
      `evidence=${stages.evidenceExtracted} procedure=${stages.procedureMatched} ` +
      `city=${stages.cityMatched} accepted=${stages.accepted} ` +
      `rejected=${JSON.stringify(stages.rejectedByReason)}`);

  // Legacy verified rows → upsert cityId coverage so unknown_coverage ends.
  try {
    const {upsertCoverageDoc} = require('./brightdata/cityDiscoveryState');
    const {buildCityId, isResolvedCityId} = require('./cityIdentity');
    let resolvedId = String(cityId || '').trim();
    if (!isResolvedCityId(resolvedId)) {
      resolvedId = buildCityId({
        placeId: locality.placeId,
        countryCode: countryCode || String((coverage && coverage.countryCode) || ''),
        adminArea: locality.adminArea,
        canonicalName: locality.canonicalName || city,
        latitude: locality.latitude != null
          ? locality.latitude
          : (coverage && coverage.latitude),
        longitude: locality.longitude != null
          ? locality.longitude
          : (coverage && coverage.longitude),
      });
    }
    if (isResolvedCityId(resolvedId) &&
        (cached.length > 0 || fresh.length > 0 ||
         Number(coverage.verifiedVisibleCount || 0) > 0)) {
      const verifiedN = Math.max(
          cached.length + fresh.length,
          Number(coverage.verifiedVisibleCount || 0));
      await upsertCoverageDoc(city, procedure, {
        cityId: resolvedId,
        status: verifiedN >= 4 ? 'complete' : 'partial',
        candidateCount: places.length || coverage.candidateCount || 0,
        verifiedCount: verifiedN,
      });
    }
  } catch (err) {
    console.log(`${logTag} coverage upsert skipped · ${err && err.message}`);
  }

  return {
    cached: cached.slice(0, 8),
    fresh,
    status,
    coverage,
    stages,
  };
}

module.exports = {
  handleGetExploreProcedurePrices,
  clinicJson,
  verifyPlace,
  pastDeadline,
  stagedVerifyUrls,
  familyPaths,
  INTERACTIVE_DEADLINE_MS,
  DEEP_DEADLINE_MS,
};
