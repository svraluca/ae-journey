'use strict';

/**
 * Curated public-site price repository.
 *
 * A hand-audited dataset of clinic prices read straight off public clinic
 * websites. It exists so Explore can paint real cards from Firestore before any
 * Places / Serper / OpenAI / scrape work starts, and it is deliberately kept in
 * its own collections rather than mixed into `explore_google_prices`: those
 * rows carry DOM evidence produced by the live evidence-lock pipeline, and
 * these do not. Trust is granted by an explicit curated branch on the client,
 * never by faking `rawEvidence` / `raw_price_text` / evidence hashes.
 *
 * Two collections, both written by scripts/importMiamiCuratedClinics.js:
 *   explore_curated_clinics/{clinicId}  one document per clinic
 *   explore_curated_prices/{rowId}      one document per priced procedure
 *
 * Explore searches by city + procedure, not by clinic, so the flattened price
 * collection is the one the client queries. The clinic documents exist so a
 * single clinic's details can be refreshed without rewriting 800 price rows.
 */

const crypto = require('crypto');

const {matchRawProcedureLabel} = require('./procedureMatch');
const {hostOf} = require('./parsePrice');
const {EXTRACT_REVISION} = require('./extractRevision');

const CLINIC_COLLECTION = 'explore_curated_clinics';
const PRICE_COLLECTION = 'explore_curated_prices';

/** Bumped when normalization semantics change, so a re-import rewrites rows. */
const CURATED_REVISION = 'c1';

/** Public clinic prices go stale after 30 days — stale-while-revalidate. */
const CURATED_STALE_AFTER_MS = 30 * 24 * 60 * 60 * 1000;

/** Wire value stored on curated rows; the client trusts only this source. */
const CURATED_SOURCE = 'curated_public_site';

/**
 * Dataset categories that mean the same thing as an Explore family but spell it
 * differently. Without this a "peels" row is invisible to the Peels pill, which
 * matches on the singular `peel` the rest of the pipeline uses.
 */
const CATEGORY_FAMILY_ALIASES = {
  peels: 'peel',
  fillers: 'filler',
  injectable: 'injectables',
  skincare: 'skin',
  hair_restoration: 'hair',
};

/**
 * Brand names the live label matcher does not carry, restricted to cases where
 * the flagship family is unambiguous. Kept here rather than added to
 * procedureMatch so the live extraction pipeline keeps its current behaviour.
 */
const CURATED_NAME_ALIASES = [
  {re: /\bdaxxify\b|\bnuceiva\b|\bletybo\b|\bbocouture\b|\bneuronox\b|\bbotulotoxin/i, family: 'botox', canonical: 'botox'},
  {re: /\bvollure\b|\bvolbella\b|\bvoluma\b|\brestylane\b|\bjuvederm\b|\bstylage\s+[smlx]+\b/i, family: 'filler', canonical: 'filler'},
  {re: /\bfacial balancing\b|\bcheek enhancement\b|\baugmentarea buzelor\b|\bmari[rt]e buze\b/i, family: 'filler', canonical: 'filler'},
  {re: /\bprx\b|\bperfexion\b|\bjet\s*peel\b|\bpeeling chimic\b|\bpeeling\s+aha\b|\bpeeling\s+tca\b/i, family: 'peel', canonical: 'chemical_peel'},
  {re: /\bmari[rt]ea?\s+s[aâ]nil|\baugmentare\s+mamar/i, family: 'breast_augmentation', canonical: 'breast_augmentation'},
];

/** Units that price one item, not one visit. */
const PER_UNIT_TOKENS = new Set([
  'unit', 'units', 'syringe', 'syringes', 'half syringe', 'ml', 'cc',
  'vial', 'vials', 'graft', 'grafts', 'thread', 'threads', 'bottle',
]);

/** Units that price one treated zone. */
const PER_AREA_TOKENS = new Set(['area', 'areas', 'zone', 'zones']);

/** Dataset price_type values that mark a promotion rather than a rate card. */
const PROMOTIONAL_PRICE_TYPES = new Set(['introductory', 'special']);

function cityKey(city) {
  return String(city || '').trim().toLowerCase();
}

function normalizeName(name) {
  return String(name || '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .trim();
}

function num(value) {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function docSafeId(raw) {
  return encodeURIComponent(String(raw)).replace(/%/g, '_').slice(0, 400);
}

/**
 * Split "per half syringe" / "1.5 ml" / "package" into a quantity and a token.
 * Matching is on the whole token, not a substring, so "per month" cannot be
 * mistaken for a per-unit rate the way a `contains('unit')` test would.
 */
function parseUnitLabel(rawUnit) {
  const t = String(rawUnit || '').trim().toLowerCase();
  if (!t) return {unit: '', quantity: 0, token: ''};
  const withoutPer = t.replace(/^per\s+/, '').trim();
  const qtyMatch = withoutPer.match(/^(\d+(?:[.,]\d+)?)[\s-]*(.*)$/);
  if (qtyMatch) {
    const quantity = num(String(qtyMatch[1]).replace(',', '.'));
    const token = (qtyMatch[2] || '').trim();
    return {unit: token || withoutPer, quantity, token};
  }
  return {unit: withoutPer, quantity: 0, token: withoutPer};
}

/**
 * Resolve the family/canonical pair used for querying.
 *
 * Order matters: the live Explore matcher wins so curated rows land in exactly
 * the same buckets as scraped rows, then a narrow brand alias table, then the
 * dataset's own category. The category fallback is the point of this function —
 * an IV drip or a Brazilian wax must keep its own family rather than be forced
 * into one of the six flagship pills.
 */
function curatedProcedureFamily({name, category}) {
  const label = String(name || '').trim();
  const match = label ? matchRawProcedureLabel(label, '') : null;
  if (match && match.family && match.family !== 'other') {
    return {
      family: match.family,
      canonical: match.canonical || match.family,
      familySource: 'explore_matcher',
    };
  }
  for (const alias of CURATED_NAME_ALIASES) {
    if (alias.re.test(label)) {
      return {
        family: alias.family,
        canonical: alias.canonical,
        familySource: 'curated_alias',
      };
    }
  }
  const cat = normalizeName(category).replace(/\s+/g, '_');
  const family = CATEGORY_FAMILY_ALIASES[cat] || cat;
  return {
    family: family || 'other',
    canonical: '',
    familySource: family ? 'dataset_category' : 'none',
  };
}

/**
 * ISO country from the dataset location, then from the market currency.
 * Miami rows have no country field, so USD still maps to US.
 */
const COUNTRY_CODE_ALIASES = {
  us: 'US',
  usa: 'US',
  'united states': 'US',
  gb: 'GB',
  uk: 'GB',
  'united kingdom': 'GB',
  'great britain': 'GB',
  england: 'GB',
  ca: 'CA',
  canada: 'CA',
  md: 'MD',
  moldova: 'MD',
  'republic of moldova': 'MD',
  ro: 'RO',
  romania: 'RO',
};

function countryCodeOf({location, currencyDefault}) {
  const loc = location || {};
  const raw = String(loc.country_code || loc.country || '').trim();
  if (raw) {
    const mapped = COUNTRY_CODE_ALIASES[raw.toLowerCase()];
    if (mapped) return mapped;
    if (/^[A-Za-z]{2}$/.test(raw)) return raw.toUpperCase();
  }
  const currency = String(currencyDefault || '').toUpperCase();
  if (currency === 'GBP') return 'GB';
  if (currency === 'EUR') return 'EU';
  if (currency === 'CAD') return 'CA';
  if (currency === 'MDL') return 'MD';
  if (currency === 'RON') return 'RO';
  return 'US';
}

/**
 * Map the dataset's price shape onto the wire values `PriceType.fromWire`
 * understands, keeping the semantics the source published.
 *
 * The unit wins over a promotional price_type: "$10 per unit, introductory"
 * must still read as a per-unit rate, so the promotion is carried separately in
 * `is_promotional` and the original value in `source_price_type`. That keeps
 * ordering able to demote a new-client teaser without losing the /unit label.
 */
function resolveCuratedPrice(procedure, currencyDefault) {
  const p = procedure || {};
  const price = num(p.price);
  const min = num(p.price_min);
  const max = num(p.price_max);
  const regular = num(p.regular_price);
  const member = num(p.member_price);

  // The default card shows the public, non-member price. Member pricing is
  // preserved alongside it so a UI that shows both can, but it must never
  // silently become the headline number.
  const display = price || regular || min || member;
  if (!display) return null;

  const priceMin = min || display;
  const priceMax = max > priceMin ? max : priceMin;

  const {unit, quantity} = parseUnitLabel(p.unit);
  const sourceType = String(p.price_type || '').trim().toLowerCase();
  const promotional = PROMOTIONAL_PRICE_TYPES.has(sourceType);
  const packageSessions = num(p.package_sessions);

  let priceType;
  if (PER_UNIT_TOKENS.has(unit)) {
    priceType = 'per_unit';
  } else if (PER_AREA_TOKENS.has(unit)) {
    priceType = 'per_area';
  } else if (max > priceMin) {
    priceType = 'range';
  } else if (sourceType === 'from' || sourceType === 'approximate') {
    priceType = 'from';
  } else if (promotional) {
    priceType = 'sale';
  } else {
    priceType = 'fixed';
  }

  return {
    priceMin,
    priceMax,
    currency: String(p.currency || currencyDefault || '').trim().toUpperCase() ||
        'USD',
    priceType,
    sourcePriceType: sourceType,
    unit,
    unitQuantity: quantity,
    memberPrice: member,
    regularPrice: regular,
    packageSessions,
    isPromotional: promotional,
    isPackage: packageSessions > 1 || unit === 'package',
  };
}

/**
 * Stable clinic identity. The dataset has no Google Place IDs, so host plus
 * normalized name is the strongest evidence available; a later live match can
 * attach a placeId without moving the document.
 */
function curatedClinicId({city, website, name}) {
  const ck = cityKey(city);
  const host = hostOf(website || '');
  const nn = normalizeName(name);
  const raw = host ? `${ck}|host:${host}|${nn}` : `${ck}|${nn || 'clinic'}`;
  return docSafeId(raw);
}

/**
 * Deterministic price-row identity so re-running the import updates rows in
 * place instead of duplicating them. Procedure name, unit and price type are
 * all part of the key because one clinic legitimately lists the same treatment
 * at different units ("Full Syringe" vs "Half Syringe").
 */
function curatedPriceRowId({cityKey: ck, clinicId, procedureName, unit, priceType}) {
  const composite = [
    ck || '',
    clinicId || '',
    normalizeName(procedureName),
    String(unit || '').toLowerCase(),
    String(priceType || ''),
  ].join('|');
  const hash = crypto.createHash('sha1').update(composite).digest('hex');
  const slug = normalizeName(procedureName).replace(/\s+/g, '-').slice(0, 40);
  return docSafeId(`${slug || 'row'}_${hash.slice(0, 16)}`);
}

/**
 * Normalize a dataset clinic. `cityKeyOverride` exists because the audit covers
 * the whole Miami-Dade metro: a Coral Gables address still has to answer a
 * "Miami" search, so the searchable key is the metro while the printed address
 * keeps the real municipality.
 */
function buildCuratedClinic({clinic, cityKeyOverride, checkedAt, currencyDefault}) {
  const c = clinic || {};
  const location = c.location || {};
  const rating = c.rating || {};
  const website = String(c.website || '').trim();
  const ck = cityKey(cityKeyOverride || location.city);
  const clinicId = curatedClinicId({city: ck, website, name: c.name});
  const postal = String(
      location.zip || location.postal_code || location.postcode || '').trim();
  const region = String(location.state || location.province || '').trim();
  const addressParts = [
    location.address, location.city, region, postal,
  ]
      .map((s) => String(s || '').trim())
      .filter(Boolean);
  return {
    clinicId,
    doc: {
      name: String(c.name || '').trim(),
      name_normalized: normalizeName(c.name),
      city: String(location.city || '').trim(),
      city_key: ck,
      state: region,
      postal_code: postal,
      country_code: countryCodeOf({location, currencyDefault}),
      address: addressParts.join(', '),
      phone: String(c.phone || '').trim(),
      website,
      website_host: hostOf(website),
      rating: num(rating.value),
      rating_count: Math.round(num(rating.review_count)),
      rating_platform: String(rating.platform || '').trim(),
      source: CURATED_SOURCE,
      curated_revision: CURATED_REVISION,
      checked_at: checkedAt,
      procedure_count: Array.isArray(c.procedures) ? c.procedures.length : 0,
    },
  };
}

/**
 * Flatten one procedure into a queryable price row, or return a skip reason.
 * A row is only valid with a positive number in one of the four price fields —
 * the dataset omits unpriced procedures rather than estimating them, and this
 * keeps that guarantee if a future revision slips.
 */
function buildCuratedPriceRow({
  clinic, clinicDoc, clinicId, procedure, checkedAt, currencyDefault,
}) {
  const p = procedure || {};
  const name = String(p.name || '').trim();
  if (!name) return {skip: 'missing_name'};
  const sourceUrl = String(p.source_url || '').trim();
  if (!sourceUrl) return {skip: 'missing_source_url'};

  const price = resolveCuratedPrice(p, currencyDefault);
  if (!price) return {skip: 'no_numeric_price'};

  const {family, canonical, familySource} = curatedProcedureFamily({
    name,
    category: p.category,
  });

  const rowId = curatedPriceRowId({
    cityKey: clinicDoc.city_key,
    clinicId,
    procedureName: name,
    unit: price.unit,
    priceType: price.priceType,
  });

  return {
    rowId,
    doc: {
      clinic_id: clinicId,
      clinic_name: clinicDoc.name,
      city_key: clinicDoc.city_key,
      city: clinicDoc.city,
      country_code: clinicDoc.country_code,

      // Display name stays exactly as published: "HydraFacial Platinum" must
      // never collapse to "Facial". Family/canonical are for querying only.
      procedure_name: name,
      procedure_name_normalized: normalizeName(name),
      procedure_canonical: canonical,
      procedure_family: family,
      procedure_family_source: familySource,
      source_category: String(p.category || '').trim(),

      price_min: price.priceMin,
      price_max: price.priceMax,
      currency: price.currency,
      price_type: price.priceType,
      source_price_type: price.sourcePriceType,
      unit: price.unit,
      unit_quantity: price.unitQuantity,
      member_price: price.memberPrice,
      regular_price: price.regularPrice,
      package_sessions: price.packageSessions,
      is_promotional: price.isPromotional,
      is_package: price.isPackage,

      source: CURATED_SOURCE,
      source_url: sourceUrl,
      source_type: String(p.source_type || '').trim() || 'official_clinic',
      note: String(p.note || '').trim(),

      rating: clinicDoc.rating,
      rating_count: clinicDoc.rating_count,
      address: clinicDoc.address,
      phone: clinicDoc.phone,
      website: clinicDoc.website,
      website_host: clinicDoc.website_host,

      curated_revision: CURATED_REVISION,
      price_extract_revision: EXTRACT_REVISION,
      checked_at: checkedAt,
    },
  };
}

/**
 * Normalize a whole dataset without touching Firestore, so the import can be
 * dry-run and unit-tested on the real file.
 */
function normalizeCuratedDataset({dataset, cityKeyOverride}) {
  const d = dataset || {};
  const checkedAt = String(d.checked_at || '').trim();
  const clinics = Array.isArray(d.clinics) ? d.clinics : [];
  const out = {
    checkedAt,
    currencyDefault: String(d.currency_default || 'USD').toUpperCase(),
    clinics: [],
    rows: [],
    skipped: [],
    invalidClinics: [],
    conflicts: [],
  };
  const seenRowIds = new Map();

  for (const clinic of clinics) {
    const name = String((clinic || {}).name || '').trim();
    const website = String((clinic || {}).website || '').trim();
    const phone = String((clinic || {}).phone || '').trim();
    const procedures = Array.isArray((clinic || {}).procedures)
      ? clinic.procedures
      : [];
    if (!name || (!website && !phone)) {
      out.invalidClinics.push({name, reason: 'missing_name_or_contact'});
      continue;
    }

    const {clinicId, doc: clinicDoc} = buildCuratedClinic({
      clinic,
      cityKeyOverride,
      checkedAt,
      currencyDefault: out.currencyDefault,
    });

    const rows = [];
    for (const procedure of procedures) {
      const built = buildCuratedPriceRow({
        clinic,
        clinicDoc,
        clinicId,
        procedure,
        checkedAt,
        currencyDefault: out.currencyDefault,
      });
      if (built.skip) {
        out.skipped.push({
          clinic: name,
          procedure: String((procedure || {}).name || ''),
          reason: built.skip,
        });
        continue;
      }
      // Same treatment listed twice at one unit collapses to one row rather
      // than fighting for the same document id on write. Identical prices are
      // just the same rate published on two pages; different prices need
      // resolving, and are reported so the source can be re-checked.
      const prior = seenRowIds.get(built.rowId);
      if (prior) {
        const candidate = {rowId: built.rowId, doc: built.doc, duplicates: 0};
        const samePrice = prior.doc.price_min === built.doc.price_min &&
            prior.doc.price_max === built.doc.price_max;
        if (samePrice) {
          prior.duplicates += 1;
          continue;
        }
        const winner = preferConflictingRow(prior, candidate);
        out.conflicts.push({
          clinic: name,
          procedure: built.doc.procedure_name,
          kept: `${winner.doc.price_min}-${winner.doc.price_max} ` +
              `(${winner.doc.source_url})`,
          dropped: winner === prior ?
            `${built.doc.price_min}-${built.doc.price_max} ` +
              `(${built.doc.source_url})` :
            `${prior.doc.price_min}-${prior.doc.price_max} ` +
              `(${prior.doc.source_url})`,
        });
        prior.doc = winner.doc;
        continue;
      }
      const entry = {rowId: built.rowId, doc: built.doc, duplicates: 0};
      seenRowIds.set(built.rowId, entry);
      rows.push(entry);
    }

    if (!rows.length) {
      out.invalidClinics.push({name, reason: 'no_priced_procedure'});
      continue;
    }
    out.clinics.push({clinicId, doc: clinicDoc, rowCount: rows.length});
    out.rows.push(...rows);
  }

  out.duplicatesMerged = [...seenRowIds.values()]
      .reduce((sum, e) => sum + e.duplicates, 0);
  return out;
}

/** Path segments in a source URL; a deeper page is the more specific one. */
function sourceUrlDepth(url) {
  const match = String(url || '').match(/^https?:\/\/[^/]+\/?(.*)$/i);
  if (!match) return 0;
  return String(match[1] || '')
      .split('/')
      .filter(Boolean)
      .length;
}

/**
 * Pick between two rows that share an identity key but publish different
 * prices. Clinics do this by listing a treatment on both a landing page and a
 * dedicated page, so prefer the deeper URL, then the narrower range. Keeping
 * whichever happened to parse first would make the import order-dependent.
 */
function preferConflictingRow(current, incoming) {
  const a = current.doc;
  const b = incoming.doc;
  const depthA = sourceUrlDepth(a.source_url);
  const depthB = sourceUrlDepth(b.source_url);
  if (depthB !== depthA) return depthB > depthA ? incoming : current;
  const spanA = a.price_max - a.price_min;
  const spanB = b.price_max - b.price_min;
  if (spanB !== spanA) return spanB < spanA ? incoming : current;
  return current;
}

/** Family -> row count, for dry-run reporting. */
function tallyFamilies(rows) {
  const counts = {};
  for (const r of rows || []) {
    const fam = (r.doc && r.doc.procedure_family) || 'other';
    counts[fam] = (counts[fam] || 0) + 1;
  }
  return counts;
}

module.exports = {
  CLINIC_COLLECTION,
  PRICE_COLLECTION,
  CURATED_REVISION,
  CURATED_SOURCE,
  CURATED_STALE_AFTER_MS,
  CATEGORY_FAMILY_ALIASES,
  cityKey,
  countryCodeOf,
  normalizeName,
  parseUnitLabel,
  sourceUrlDepth,
  curatedProcedureFamily,
  resolveCuratedPrice,
  curatedClinicId,
  curatedPriceRowId,
  buildCuratedClinic,
  buildCuratedPriceRow,
  normalizeCuratedDataset,
  tallyFamilies,
};
