'use strict';

const {matchRawProcedureLabel, laserRowSubtype} = require('../procedureMatch');
const {
  classifyProcedureRelation,
  requestedFamily,
} = require('../procedureRelation');

/**
 * Map matched Fresha service families onto Explore pool procedure keys
 * (same strings as explorePillAiSearchQuery).
 */
const FAMILY_TO_EXPLORE_PROCEDURE = {
  botox: 'Botox anti-wrinkle injection',
  filler: 'dermal filler lips cheeks',
  laser: 'laser skin rejuvenation IPL',
  peel: 'chemical peel facial',
  chemical_peel: 'chemical peel facial',
  skin: 'skin booster Profhilo',
  profhilo: 'skin booster Profhilo',
  sculptra: 'Sculptra',
  skin_booster: 'skin booster Profhilo',
  prp: 'PRP facial hair',
  prp_hair: 'PRP facial hair',
  prp_face: 'PRP facial hair',
  hydrafacial: 'Hydrafacial',
  microneedling: 'microneedling',
  hifu: 'HIFU facial',
  pico_laser: 'laser skin rejuvenation IPL',
  lip_filler: 'dermal filler lips cheeks',
  cheek_filler: 'dermal filler lips cheeks',
  rhinoplasty: 'rhinoplasty nose job',
  breast_augmentation: 'breast augmentation',
  hair: 'hair transplant FUE',
  hair_transplant: 'hair transplant FUE',
};

function exploreProcedureForMatch(match, label = '') {
  const canonical = String((match && match.canonical) || '').toLowerCase();
  const family = String((match && match.family) || '').toLowerCase();
  if (family === 'laser' || canonical === 'laser' || canonical === 'pico_laser') {
    return laserRowSubtype(label || canonical) === 'hair'
      ? 'laser hair removal'
      : 'laser skin rejuvenation IPL';
  }
  if (canonical && FAMILY_TO_EXPLORE_PROCEDURE[canonical]) {
    return FAMILY_TO_EXPLORE_PROCEDURE[canonical];
  }
  if (family && FAMILY_TO_EXPLORE_PROCEDURE[family]) {
    return FAMILY_TO_EXPLORE_PROCEDURE[family];
  }
  return '';
}

/**
 * Classify a Fresha service into an Explore procedure pool key.
 * Unknown / ambiguous / bundle → null (may stage raw catalog only).
 */
function classifyFreshaService(serviceName, {venueUrl = ''} = {}) {
  const label = String(serviceName || '').trim();
  if (!label) {
    return {accepted: false, reason: 'empty', exploreProcedure: '', match: null};
  }

  const match = matchRawProcedureLabel(label, '');
  if (match.rejectReason) {
    console.log(`[FRESHA PROCEDURE] raw → rejected · ${match.rejectReason}`);
    return {
      accepted: false,
      reason: match.rejectReason,
      exploreProcedure: '',
      match,
    };
  }
  if (!match.family || match.family === 'other' || match.confidence < 0.75) {
    console.log(`[FRESHA PROCEDURE] raw → unknown · "${label.slice(0, 72)}"`);
    return {
      accepted: false,
      reason: 'unknown_procedure',
      exploreProcedure: '',
      match,
    };
  }

  const exploreProcedure = exploreProcedureForMatch(match, label);
  if ((match.family === 'laser' || match.canonical === 'pico_laser') &&
      laserRowSubtype(label) === 'generic') {
    return {
      accepted: false,
      reason: 'generic_laser',
      exploreProcedure: '',
      match,
    };
  }
  if (!exploreProcedure) {
    return {
      accepted: false,
      reason: 'no_pool_key',
      exploreProcedure: '',
      match,
    };
  }

  console.log(
      `[FRESHA PROCEDURE] raw → canonical · "${label.slice(0, 64)}" → ` +
      `${match.family}/${match.canonical || ''} → ${exploreProcedure}`);

  const relation = classifyProcedureRelation({
    requestedProcedure: exploreProcedure,
    label,
    evidence: label,
    sourceUrl: venueUrl,
    clinicOwnQuoted: true,
  });

  if (!relation.eligible) {
    const tag = relation.logToken === 'bundle' ? 'bundle'
      : (relation.logToken === 'ambiguous' ? 'ambiguous' : relation.logToken);
    console.log(`[FRESHA PRICE] rejected · ${tag} · "${label.slice(0, 64)}"`);
    return {
      accepted: false,
      reason: `relation_${relation.logToken}`,
      exploreProcedure,
      match,
      relation,
    };
  }

  return {
    accepted: true,
    reason: '',
    exploreProcedure,
    match,
    relation,
  };
}

module.exports = {
  FAMILY_TO_EXPLORE_PROCEDURE,
  exploreProcedureForMatch,
  classifyFreshaService,
  requestedFamily,
};
