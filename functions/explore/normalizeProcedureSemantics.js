'use strict';

/**
 * Safe LLM semantic normalizer for procedure labels.
 * NEVER asks for or applies price / amount / currency fields.
 *
 * Flow:
 * 1. Deterministic match + relation
 * 2. Cheap LLM only when family=other / low confidence / unclear units
 * 3. Strong deterministic rejections cannot be overridden by AI
 */

const admin = require('firebase-admin');
const {matchRawProcedureLabel} = require('./procedureMatch');
const {
  classifyProcedureRelation,
  logProcedureRelation,
} = require('./procedureRelation');

const NORMALIZER_VERSION = 'n1';
const CACHE_COLLECTION = 'procedure_semantic_cache';
const LLM_MODEL = 'gpt-4o-mini';
const CONFIDENCE_THRESHOLD = 0.85;

const STANDARD_UNITS = new Set([
  'unit', 'area', 'zone', 'ml', 'syringe', 'session', 'graft', 'implant',
  'vial', 'treatment', 'package',
]);

const STRONG_REJECT = new Set([
  'bundle',
  'add_on',
  'market_information',
  'different_procedure',
  'wrong_family',
  'consultation',
  'deposit',
  'financing',
  'phone_number',
  'address_number',
]);

const PRICE_KEYS = new Set([
  'price', 'pricemin', 'pricemax', 'price_min', 'price_max', 'amount',
  'currency', 'estimatedprice', 'averageprice', 'estimated_price',
  'average_price', 'priceMin', 'priceMax',
]);

function cacheKey(rawLabel) {
  return String(rawLabel || '')
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/[^a-z0-9\u0600-\u06ff]+/g, ' ')
      .trim()
      .replace(/\s+/g, '_')
      .slice(0, 180);
}

function stripPriceFields(obj) {
  if (!obj || typeof obj !== 'object') return {};
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (PRICE_KEYS.has(k) || PRICE_KEYS.has(String(k).toLowerCase())) continue;
    if (/price|amount|currency|estimate|average/i.test(k)) continue;
    out[k] = v;
  }
  return out;
}

function standardizeUnit(raw) {
  const u = String(raw || '').trim().toLowerCase();
  if (!u) return null;
  if (['areas', 'area', 'zonas', 'zona', 'zones', 'zone', 'مناطق', 'منطقة']
      .includes(u)) {
    return u.startsWith('zon') || u.includes('منطق') ? 'zone' : 'area';
  }
  if (['units', 'unit', 'iu', 'وحدات', 'وحدة'].includes(u)) return 'unit';
  if (['ml', 'cc', 'مل'].includes(u)) return 'ml';
  if (['syringe', 'syringes', 'jeringa', 'jeringas'].includes(u)) return 'syringe';
  if (['session', 'sessions', 'sesion', 'sesión', 'sedinta', 'ședință']
      .includes(u)) {
    return 'session';
  }
  if (['graft', 'grafts', 'grefa', 'greffe'].includes(u)) return 'graft';
  if (['implant', 'implants'].includes(u)) return 'implant';
  if (['vial', 'vials', 'flacon'].includes(u)) return 'vial';
  if (['treatment', 'treatments', 'tratamiento'].includes(u)) return 'treatment';
  if (['package', 'packages', 'pack', 'paquete'].includes(u)) return 'package';
  return STANDARD_UNITS.has(u) ? u : null;
}

/**
 * Infer unit semantics from the label alone (no LLM).
 * Does NOT divide or transform prices.
 */
function inferUnitsFromLabel(rawLabel) {
  const t = String(rawLabel || '');
  const area = t.match(/\b(\d+)\s*(?:areas?|zones?|zonas?|zone|مناطق)\b/i) ||
      t.match(/\b(?:areas?|zones?|zonas?)\s*[:=-]?\s*(\d+)\b/i) ||
      t.match(/\b(?:one|two|three|1|2|3)\s+areas?\b/i);
  if (area) {
    const word = String(area[0]).toLowerCase();
    let q = Number(area[1]);
    if (!Number.isFinite(q)) {
      if (/\bone\b/.test(word)) q = 1;
      else if (/\btwo\b/.test(word)) q = 2;
      else if (/\bthree\b/.test(word)) q = 3;
    }
    return {unitType: 'area', unitQuantity: Number.isFinite(q) ? q : null};
  }
  const ml = t.match(/\b(\d+(?:[.,]\d+)?)\s*ml\b/i) ||
      t.match(/\b(\d+(?:[.,]\d+)?)\s*cc\b/i);
  if (ml) {
    const q = Number(String(ml[1]).replace(',', '.'));
    return {unitType: 'ml', unitQuantity: Number.isFinite(q) ? q : null};
  }
  const unit = t.match(/\b(\d+)\s*(?:units?|iu)\b/i);
  if (unit) {
    return {unitType: 'unit', unitQuantity: Number(unit[1]) || null};
  }
  const syringe = t.match(/\b(\d+)\s*syringes?\b/i);
  if (syringe) {
    return {unitType: 'syringe', unitQuantity: Number(syringe[1]) || null};
  }
  return {unitType: null, unitQuantity: null};
}

function standardizePriceType(raw, unitType) {
  const t = String(raw || '').trim();
  const lower = t.toLowerCase();
  if (lower === 'approximate') return 'approximate';
  if (lower === 'from') return 'from';
  if (lower === 'range') return 'range';
  if (lower === 'sale') return 'sale';
  if (lower === 'perunit' || lower === 'per_unit') return 'per_unit';
  if (lower === 'perarea' || lower === 'per_area') return 'per_area';
  if (lower === 'persession' || lower === 'per_session') return 'per_session';
  if (lower === 'fixed') {
    if (unitType === 'unit') return 'per_unit';
    if (unitType === 'area' || unitType === 'zone') return 'fixed';
    if (unitType === 'session') return 'per_session';
    return 'fixed';
  }
  if (!t) return 'unknown';
  return 'unknown';
}

function isStrongReject(match, relation) {
  const reason = String(match && match.rejectReason || '').toLowerCase();
  if (reason) {
    if (STRONG_REJECT.has(reason)) return true;
    if (reason.startsWith('wrong_family')) return true;
    if (reason.includes('consultation') || reason.includes('deposit') ||
        reason.includes('financ') || reason.includes('phone') ||
        reason.includes('address') || reason.includes('bundle') ||
        reason.includes('market')) {
      return true;
    }
  }
  const rel = String(relation && (relation.relation || relation.logToken) || '')
      .toLowerCase();
  if (STRONG_REJECT.has(rel)) return true;
  if (relation && relation.eligible === false &&
      ['bundle', 'add_on', 'market_information', 'different_procedure']
          .includes(rel)) {
    return true;
  }
  return false;
}

async function readCache(key) {
  if (!key) return null;
  try {
    const snap = await admin.firestore().collection(CACHE_COLLECTION).doc(key).get();
    if (!snap.exists) return null;
    const data = snap.data() || {};
    if (String(data.normalizerVersion || '') !== NORMALIZER_VERSION) return null;
    return data;
  } catch (_) {
    return null;
  }
}

async function writeCache(key, value) {
  if (!key || !value) return;
  try {
    await admin.firestore().collection(CACHE_COLLECTION).doc(key).set({
      ...value,
      normalizerVersion: NORMALIZER_VERSION,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});
  } catch (_) {
    // non-fatal
  }
}

async function callSemanticLlm({rawLabel, serviceLabel, requestedProcedure, city}) {
  const key = String(process.env.OPENAI_API_KEY || '').trim();
  if (!key) return null;
  console.log('[SEMANTICS] AI normalizer used');
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      temperature: 0,
      response_format: {type: 'json_object'},
      messages: [
        {
          role: 'system',
          content:
            'Normalize aesthetic procedure label semantics. Return JSON only with keys: ' +
            'family, canonical, variant, relation, unitType, unitQuantity, confidence. ' +
            'relation must be one of: exact, variant, bundle, add_on, different_procedure, ' +
            'market_information, ambiguous. ' +
            'unitType one of: unit, area, zone, ml, syringe, session, graft, implant, vial, ' +
            'treatment, package, or null. ' +
            'NEVER return price, amount, currency, priceMin, priceMax, or estimates. ' +
            'Do not invent clinic prices.',
        },
        {
          role: 'user',
          content: JSON.stringify({
            rawProcedureLabel: rawLabel,
            surroundingServiceLabel: serviceLabel || '',
            requestedProcedure: requestedProcedure || '',
            city: city || '',
          }),
        },
      ],
    }),
  });
  if (!res.ok) return null;
  const json = await res.json();
  const content = json.choices && json.choices[0] && json.choices[0].message
    ? json.choices[0].message.content : '';
  const parsed = stripPriceFields(JSON.parse(content));
  return {
    family: String(parsed.family || 'other').toLowerCase(),
    canonical: String(parsed.canonical || '').toLowerCase(),
    variant: String(parsed.variant || ''),
    relation: String(parsed.relation || 'ambiguous').toLowerCase(),
    unitType: standardizeUnit(parsed.unitType),
    unitQuantity: parsed.unitQuantity == null ? null : Number(parsed.unitQuantity),
    confidence: Number(parsed.confidence) || 0,
    fromLlm: true,
  };
}

/**
 * Normalize procedure semantics. Safe to call after numeric evidence is locked.
 *
 * @return {Promise<{
 *   family:string, canonical:string, variant:string, relation:string,
 *   unitType:string|null, unitQuantity:number|null, confidence:number,
 *   eligible:boolean, fromLlm:boolean, cached:boolean, rejectReason:string,
 *   normalizerVersion:string
 * }>}
 */
async function normalizeProcedureSemantics({
  rawLabel,
  serviceLabel = '',
  requestedProcedure = '',
  city = '',
  sourceUrl = '',
  clinicOwnQuoted = true,
  existingUnit = '',
  existingQuantity = null,
  skipCache = false,
} = {}) {
  const label = String(rawLabel || '').trim();
  const detMatch = matchRawProcedureLabel(label, requestedProcedure);
  const relation = classifyProcedureRelation({
    requestedProcedure,
    label,
    evidence: serviceLabel,
    sourceUrl,
    clinicOwnQuoted,
  });
  logProcedureRelation(relation, label);

  const unitsFromLabel = inferUnitsFromLabel(label);
  const baseUnits = {
    unitType: standardizeUnit(existingUnit) || unitsFromLabel.unitType,
    unitQuantity: existingQuantity != null
      ? Number(existingQuantity)
      : unitsFromLabel.unitQuantity,
  };

  if (isStrongReject(detMatch, relation)) {
    return {
      family: detMatch.family || 'other',
      canonical: detMatch.canonical || '',
      variant: '',
      relation: relation.relation || 'ambiguous',
      unitType: baseUnits.unitType,
      unitQuantity: baseUnits.unitQuantity,
      confidence: detMatch.confidence || 0,
      eligible: false,
      fromLlm: false,
      cached: false,
      rejectReason: detMatch.rejectReason || relation.logToken || relation.reason,
      normalizerVersion: NORMALIZER_VERSION,
    };
  }

  const needsLlm = detMatch.family === 'other' ||
      (detMatch.confidence > 0 && detMatch.confidence < CONFIDENCE_THRESHOLD) ||
      (relation.relation === 'ambiguous') ||
      (baseUnits.unitType == null &&
        /\b(?:area|zone|ml|unit|syringe|session)\b/i.test(label));

  let semantics = {
    family: detMatch.family || 'other',
    canonical: detMatch.canonical || '',
    variant: '',
    relation: relation.eligible
      ? (relation.relation || 'exact')
      : (relation.relation || 'ambiguous'),
    unitType: baseUnits.unitType,
    unitQuantity: baseUnits.unitQuantity,
    confidence: detMatch.confidence || 0,
    fromLlm: false,
    cached: false,
    eligible: !!relation.eligible && !detMatch.rejectReason,
    rejectReason: detMatch.rejectReason || (relation.eligible ? '' : relation.logToken),
    normalizerVersion: NORMALIZER_VERSION,
  };

  if (!needsLlm) {
    if (looksLikeVariantLabel(label) && semantics.relation === 'exact') {
      semantics.relation = 'variant';
      semantics.variant = summarizeVariant(label, baseUnits);
    }
    return semantics;
  }

  const key = cacheKey(label);
  if (!skipCache) {
    const cached = await readCache(key);
    if (cached) {
      // Still cannot override strong reject (already returned above).
      const rel = String(cached.relation || '').toLowerCase();
      if (STRONG_REJECT.has(rel)) {
        return {
          ...semantics,
          ...cached,
          unitType: standardizeUnit(cached.unitType) || semantics.unitType,
          eligible: false,
          fromLlm: false,
          cached: true,
          rejectReason: rel,
          normalizerVersion: NORMALIZER_VERSION,
        };
      }
      return {
        family: cached.family || semantics.family,
        canonical: cached.canonical || semantics.canonical,
        variant: cached.variant || '',
        relation: cached.relation || semantics.relation,
        unitType: standardizeUnit(cached.unitType) || semantics.unitType,
        unitQuantity: cached.unitQuantity != null
          ? Number(cached.unitQuantity)
          : semantics.unitQuantity,
        confidence: Number(cached.confidence) || semantics.confidence,
        eligible: ['exact', 'variant'].includes(
            String(cached.relation || '').toLowerCase()),
        fromLlm: false,
        cached: true,
        rejectReason: '',
        normalizerVersion: NORMALIZER_VERSION,
      };
    }
  }

  try {
    const llm = await callSemanticLlm({
      rawLabel: label,
      serviceLabel,
      requestedProcedure,
      city,
    });
    if (llm) {
      const rel = String(llm.relation || '').toLowerCase();
      // AI cannot turn a deterministic soft-pass into a forbidden accept if
      // it invents a strong-reject relation — honour that. But if AI says
      // exact/variant while deterministic already passed relation gate, OK.
      if (STRONG_REJECT.has(rel)) {
        semantics = {
          ...semantics,
          family: llm.family || semantics.family,
          canonical: llm.canonical || semantics.canonical,
          variant: llm.variant || '',
          relation: rel,
          unitType: llm.unitType || semantics.unitType,
          unitQuantity: llm.unitQuantity != null
            ? llm.unitQuantity
            : semantics.unitQuantity,
          confidence: llm.confidence,
          eligible: false,
          fromLlm: true,
          rejectReason: rel,
        };
      } else if (semantics.eligible || ['exact', 'variant'].includes(rel)) {
        // Only clarify ambiguous semantics — never revive a strong reject
        // (already returned). Soft ambiguous may become exact/variant.
        if (!isStrongReject(detMatch, {relation: rel, eligible: false, logToken: rel})) {
          semantics = {
            ...semantics,
            family: llm.family !== 'other' ? llm.family : semantics.family,
            canonical: llm.canonical || semantics.canonical,
            variant: llm.variant || summarizeVariant(label, {
              unitType: llm.unitType || semantics.unitType,
              unitQuantity: llm.unitQuantity != null
                ? llm.unitQuantity
                : semantics.unitQuantity,
            }),
            relation: ['exact', 'variant'].includes(rel)
              ? rel
              : (semantics.relation || rel),
            unitType: llm.unitType || semantics.unitType,
            unitQuantity: llm.unitQuantity != null
              ? llm.unitQuantity
              : semantics.unitQuantity,
            confidence: Math.max(semantics.confidence, llm.confidence),
            eligible: ['exact', 'variant'].includes(
                String(llm.relation || semantics.relation).toLowerCase()),
            fromLlm: true,
            rejectReason: '',
          };
        }
      }
      await writeCache(key, {
        family: semantics.family,
        canonical: semantics.canonical,
        variant: semantics.variant,
        relation: semantics.relation,
        unitType: semantics.unitType,
        unitQuantity: semantics.unitQuantity,
        confidence: semantics.confidence,
        rawLabel: label,
      });
    }
  } catch (e) {
    console.log(`[SEMANTICS] failed: ${e.message || e}`);
  }

  return semantics;
}

function looksLikeVariantLabel(label) {
  return /\b(?:\d+\s*(?:areas?|zones?|ml|units?|syringes?|sessions?)|russian\s+lips|1\s*area|2\s*areas|3\s*areas)\b/i
      .test(String(label || ''));
}

function summarizeVariant(label, units) {
  if (units && units.unitType && units.unitQuantity != null) {
    return `${units.unitQuantity} ${units.unitType}${units.unitQuantity === 1 ? '' : 's'}`;
  }
  const t = String(label || '').trim();
  if (/russian\s+lips/i.test(t)) return 'Russian lips';
  return '';
}

/**
 * Merge locked numeric evidence with semantics. Semantics never overwrite price.
 */
function mergeVerifiedNumericWithSemantics(verifiedNumericEvidence, semantics) {
  const locked = {
    priceMin: verifiedNumericEvidence.priceMin,
    priceMax: verifiedNumericEvidence.priceMax,
    currency: verifiedNumericEvidence.currency,
    rawPriceText: verifiedNumericEvidence.rawPriceText,
    rawEvidence: verifiedNumericEvidence.rawEvidence,
    sourceUrl: verifiedNumericEvidence.sourceUrl,
  };
  return {
    ...verifiedNumericEvidence,
    ...locked,
    canonicalProcedure: semantics.canonical ||
        verifiedNumericEvidence.canonicalProcedure || '',
    procedureFamily: semantics.family ||
        verifiedNumericEvidence.procedureFamily || '',
    procedureCanonical: semantics.canonical ||
        verifiedNumericEvidence.procedureCanonical || '',
    procedureRelation: semantics.relation ||
        verifiedNumericEvidence.procedureRelation || '',
    unitType: semantics.unitType != null
      ? semantics.unitType
      : (verifiedNumericEvidence.unitType || null),
    unitQuantity: semantics.unitQuantity != null
      ? semantics.unitQuantity
      : (verifiedNumericEvidence.unitQuantity ?? null),
    variant: semantics.variant || '',
    semanticConfidence: semantics.confidence || 0,
    normalizerVersion: NORMALIZER_VERSION,
    amountLiteralVerified: true,
    procedureEvidenceVerified: true,
  };
}

module.exports = {
  normalizeProcedureSemantics,
  mergeVerifiedNumericWithSemantics,
  inferUnitsFromLabel,
  standardizeUnit,
  standardizePriceType,
  stripPriceFields,
  isStrongReject,
  cacheKey,
  NORMALIZER_VERSION,
  LLM_MODEL,
  CACHE_COLLECTION,
  CONFIDENCE_THRESHOLD,
  STRONG_REJECT,
};
