'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  candidateDocId,
  legacyToCanonical,
  mergeCandidateRecord,
  prioritizePlaces,
  coverageLevel,
  shouldExpandDiscovery,
  shouldContinueVerification,
  verificationPriority,
  isVerifiedPoolHealthy,
  discoveryUpsertFields,
  applyFamilyVerificationState,
  tallyProcedureFamilyCoverage,
  isRetryBlocked,
  noPublicPriceRetryAfter,
  NO_PUBLIC_PRICE_RECHECK_MS,
} = require('../clinicCandidateStore');
const {mergeVerifiedPool} = require('../firestoreStore');
const {EXTRACT_REVISION} = require('../extractRevision');
const {discoveryQueriesForProcedure} = require('../brightdata/discoveryQueries');
const {classifyProcedureRelation} = require('../procedureRelation');

test('same clinic Botox then Fillers retains both families', () => {
  const botox = legacyToCanonical({
    city: 'London',
    cityKey: 'london',
    placeId: 'ChIJabc',
    name: 'Harley Clinic',
    procedure: 'Botox anti-wrinkle injection',
    discovery_provider: 'brightdata_maps',
  });
  const fillers = legacyToCanonical({
    city: 'London',
    cityKey: 'london',
    placeId: 'ChIJabc',
    name: 'Harley Clinic',
    procedure: 'dermal filler lips cheeks',
    discovery_provider: 'google_places',
  });
  const merged = mergeCandidateRecord(botox, fillers);
  assert.ok(merged.discoveredProcedures.includes('Botox anti-wrinkle injection'));
  assert.ok(merged.discoveredProcedures.includes('dermal filler lips cheeks'));
  assert.ok(merged.procedureFamilies.includes('botox'));
  assert.ok(merged.procedureFamilies.includes('filler'));
  assert.ok(merged.discoveryProviders.includes('brightdata_maps'));
  assert.ok(merged.discoveryProviders.includes('google_places'));
});

test('same placeId from Bright Data and Places is one candidate id', () => {
  const a = candidateDocId({
    city: 'Paris',
    placeId: 'ChIJ123',
    name: 'Clinique A',
    website: 'https://a.fr',
  });
  const b = candidateDocId({
    city: 'Paris',
    placeId: 'ChIJ123',
    name: 'Clinique A Maps',
    website: 'https://other.fr',
  });
  assert.equal(a, b);
});

test('legacy candidate docs still load safely', () => {
  const legacy = legacyToCanonical({
    city: 'Miami',
    procedure: 'Botox',
    name: 'Avana Wellness Plus',
    placeId: 'ChIJlegacy',
    website: 'https://avana.example',
    discovery_provider: 'brightdata',
  });
  assert.equal(legacy.cityKey, 'miami');
  assert.deepEqual(legacy.discoveredProcedures, ['Botox']);
  assert.ok(legacy.procedureFamilies.includes('botox'));
  assert.equal(legacy.websiteHost, 'avana.example');
});

test('coverage: thin triggers discovery; verified visible gates healthy', () => {
  assert.equal(coverageLevel(8), 'thin');
  assert.equal(coverageLevel(22), 'partial');
  assert.equal(coverageLevel(45), 'healthy');
  assert.equal(coverageLevel(65), 'broad');
  assert.equal(shouldExpandDiscovery({candidateCount: 8}), true);
  // 65 candidates with 0 verified visible → still expand.
  assert.equal(shouldExpandDiscovery({candidateCount: 65}), true);
  assert.equal(shouldExpandDiscovery({
    candidateCount: 65,
    verifiedVisibleCount: 4,
  }), false);
  assert.equal(verificationPriority(2), 'high');
  assert.equal(
      shouldContinueVerification({
        verifiedPriceCount: 2,
        unverifiedCandidateCount: 60,
      }),
      true,
  );
  assert.equal(
      shouldContinueVerification({
        verifiedPriceCount: 22,
        unverifiedCandidateCount: 5,
      }),
      false,
  );
});

test('candidate healthy/broad with 0 verified does not imply pool healthy', () => {
  // Mirrors getCityCoverage: coverageLevel can be healthy/broad while
  // verifiedVisibleCount is 0 — discovery must still expand.
  assert.equal(shouldExpandDiscovery({
    candidateCount: 65,
    verifiedVisibleCount: 0,
  }), true);
  assert.equal(isVerifiedPoolHealthy({verifiedVisibleCount: 0}), false);
});

test('stored Bright Data candidates rank before new Places', () => {
  const queue = prioritizePlaces({
    reverify: [{name: 'Old Trust', placeId: 'r1', website: 'https://r.example'}],
    stored: [{name: 'Bright Maps', placeId: 's1', website: 'https://s.example'}],
    places: [{name: 'New Places', placeId: 'p1', website: 'https://p.example'}],
  });
  assert.deepEqual(queue.map((p) => p.queueSource), [
    'reverify', 'stored', 'places',
  ]);
});

test('verified pool accumulates A B C + D', () => {
  const trusted = (name, id, price) => ({
    name,
    clinicName: name,
    place_id: id,
    placeId: id,
    price_min: price,
    priceMin: price,
    price_max: price,
    currency: 'USD',
    raw_price_text: `Botox $${price}`,
    rawPriceText: `Botox $${price}`,
    raw_procedure_text: 'Botox',
    rawProcedureText: 'Botox',
    price_source_url: `https://${id}.example/botox`,
    sourceUrl: `https://${id}.example/botox`,
    extraction_method: 'html_table',
    extractionMethod: 'html_table',
    price_verification_status: 'official_website',
    price_verified: true,
    verified: true,
    procedure_relation: 'exact',
    procedure_family: 'botox',
    price_extract_revision: EXTRACT_REVISION,
    extractRevision: EXTRACT_REVISION,
    website: `https://${id}.example`,
  });
  const existing = [
    trusted('Clinic A', 'a', 200),
    trusted('Clinic B', 'b', 220),
    trusted('Clinic C', 'c', 240),
  ];
  const {trusted: out, afterCount} = mergeVerifiedPool(existing, [
    trusted('Clinic D', 'd', 260),
  ], 'Botox anti-wrinkle injection');
  const names = out.map((c) => c.name).sort();
  assert.deepEqual(names, ['Clinic A', 'Clinic B', 'Clinic C', 'Clinic D']);
  assert.equal(afterCount, 4);
});

test('unknown city still gets English family queries', () => {
  const qs = discoveryQueriesForProcedure('Botox', 'Nairobi');
  assert.ok(qs.length >= 3);
  assert.ok(qs.every((q) => /nairobi/i.test(q)));
  assert.ok(qs.some((q) => /botox/i.test(q)));
});

test('bare anatomy and injectables stay ambiguous for Botox', () => {
  for (const label of ['Focus Frown', 'Injectables', 'Jawline', 'Chin']) {
    const r = classifyProcedureRelation({
      requestedProcedure: 'Botox',
      label,
      evidence: `${label} $199`,
    });
    assert.equal(r.eligible, false, label);
    assert.ok(
        r.relation === 'ambiguous' || r.relation === 'different_procedure',
        label,
    );
  }
});

test('Endolift JawLine is never Botox', () => {
  const r = classifyProcedureRelation({
    requestedProcedure: 'Botox anti-wrinkle injection',
    label: 'Endolift JawLine (Under Chin)',
    evidence: 'Endolift JawLine (Under Chin) $499',
    sourceUrl: 'https://clinic.example/endolift-jawline',
  });
  assert.equal(r.eligible, false);
  assert.equal(r.relation, 'different_procedure');
});

test('parent Botox Pricing inherits; Injectables does not', () => {
  const ok = classifyProcedureRelation({
    requestedProcedure: 'Botox',
    label: 'Frown Lines',
    evidence: 'Frown Lines $199',
    parentHeading: 'Botox Pricing',
  });
  assert.equal(ok.eligible, true);
  const no = classifyProcedureRelation({
    requestedProcedure: 'Botox',
    label: 'Frown Lines',
    evidence: 'Frown Lines $199',
    parentHeading: 'Injectables',
  });
  assert.equal(no.eligible, false);
});

test('rediscovery upsert payload never resets workflow status', () => {
  const FieldValue = {
    serverTimestamp: () => 'ts',
    arrayUnion: (v) => ({union: v}),
  };
  const payload = discoveryUpsertFields({
    name: 'Harley Clinic',
    placeId: 'ChIJ1',
    website: 'https://harley.example',
  }, {
    cityKey: 'london',
    cityDisplay: 'London',
    countryCode: 'GB',
    procedure: 'Botox anti-wrinkle injection',
    fam: 'botox',
    provider: 'brightdata_maps',
    FieldValue,
  });
  assert.equal(Object.prototype.hasOwnProperty.call(payload, 'status'), false);
  assert.equal(payload.website, 'https://harley.example');
});

test('empty rediscovery website does not wipe a stored site', () => {
  const FieldValue = {
    serverTimestamp: () => 'ts',
    arrayUnion: (v) => ({union: v}),
  };
  const payload = discoveryUpsertFields({
    name: 'Harley Clinic',
    placeId: 'ChIJ1',
    website: '',
  }, {
    cityKey: 'london',
    cityDisplay: 'London',
    countryCode: 'GB',
    procedure: 'Botox anti-wrinkle injection',
    fam: 'botox',
    provider: 'google_places',
    FieldValue,
  });
  assert.equal(Object.prototype.hasOwnProperty.call(payload, 'website'), false);
  assert.equal(Object.prototype.hasOwnProperty.call(payload, 'status'), false);
});

test('family maps keep Botox then Fillers independently', () => {
  let state = {priceStatus: {}, procedureOffered: {}};
  state = applyFamilyVerificationState(state, {
    fam: 'botox',
    offered: true,
    priceStatus: 'no_public_price',
  });
  state = applyFamilyVerificationState(state, {
    fam: 'filler',
    verified: true,
  });
  assert.equal(state.priceStatus.botox, 'no_public_price');
  assert.equal(state.priceStatus.filler, 'verified');
  assert.equal(state.procedureOffered.botox, true);
  assert.equal(state.procedureOffered.filler, true);
});

test('global verified status does not count as Botox verified', () => {
  const row = {
    status: 'verified',
    priceStatus: {filler: 'verified', botox: 'no_public_price'},
    procedureOffered: {filler: true, botox: true},
    procedureFamilies: ['filler', 'botox'],
    temporaryRetryAfter: Date.now() + 1000,
  };
  const botox = tallyProcedureFamilyCoverage([row], 'botox');
  const filler = tallyProcedureFamilyCoverage([row], 'filler');
  assert.equal(botox.familyVerified, 0);
  assert.equal(filler.familyVerified, 1);
});

test('no_public_price gets a multi-day recheck TTL, not permanent', () => {
  const now = Date.now();
  const until = noPublicPriceRetryAfter(now);
  assert.ok(until - now >= 7 * 24 * 60 * 60 * 1000);
  assert.ok(until - now <= 14 * 24 * 60 * 60 * 1000);
  assert.equal(NO_PUBLIC_PRICE_RECHECK_MS, 10 * 24 * 60 * 60 * 1000);
  const blocked = isRetryBlocked({
    temporaryRetryAfter: until,
    priceStatus: {botox: 'no_public_price'},
    procedureOffered: {botox: true},
  }, now);
  assert.equal(blocked, true);
  assert.equal(isRetryBlocked({
    temporaryRetryAfter: until,
    priceStatus: {botox: 'no_public_price'},
    procedureOffered: {botox: true},
  }, until + 1), false);
});

test('Botox $12/unit keeps perUnit type via parse', () => {
  const {parsePriceText} = require('../parsePrice');
  const parsed = parsePriceText('Botox $12/unit');
  assert.ok(parsed);
  assert.equal(parsed.priceMin, 12);
  assert.equal(parsed.priceType, 'perUnit');
});

test('price safety rejects reviews, financing, and market averages', () => {
  const {evaluateExtractedPriceCandidate} = require('../priceSanity');
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '4.9 stars · 1200 reviews',
    priceMin: 1200,
    currency: 'USD',
    extractionMethod: 'text_proximity',
  }).accepted, false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: '\$199/month',
    priceMin: 199,
    currency: 'USD',
    extractionMethod: 'dom_block',
    rawEvidence: 'financing from $199/month',
  }).accepted, false);
  assert.equal(evaluateExtractedPriceCandidate({
    rawPriceText: 'Average Botox cost in Miami is $350',
    priceMin: 350,
    currency: 'USD',
    extractionMethod: 'text_proximity',
    procedure: 'Botox',
    rawEvidence: 'Average Botox cost in Miami is $350',
  }).accepted, false);
});

test('poolHealthy uses post-validation visible count not raw cache', () => {
  const {isVerifiedPoolHealthy, shouldExpandDiscovery, exploreVisibleTarget} =
      require('../clinicCandidateStore');
  assert.equal(exploreVisibleTarget(), 4);
  // raw pool=4, one cross-city rejected → valid=3
  const rawPool = 4;
  const validVisible = 3;
  assert.equal(rawPool >= 4, true);
  assert.equal(isVerifiedPoolHealthy({
    verifiedVisibleCount: validVisible,
    verifiedPriceCount: rawPool,
  }), false);
  assert.equal(shouldExpandDiscovery({
    candidateCount: 32,
    verifiedVisibleCount: validVisible,
    verifiedPriceCount: rawPool,
  }), true);
  assert.equal(isVerifiedPoolHealthy({verifiedVisibleCount: 4}), true);
  assert.equal(shouldExpandDiscovery({
    candidateCount: 32,
    verifiedVisibleCount: 4,
  }), false);
});
