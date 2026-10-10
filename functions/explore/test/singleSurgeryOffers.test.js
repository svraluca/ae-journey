'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {classifyProcedureRelation} = require('../procedureRelation');

test('single surgery all-inclusive prices keep their scope', () => {
  for (const [requestedProcedure, label, amount, eligible] of [
    ['rhinoplasty', 'Closed Rhinoplasty All-Inclusive Package', 3200, true],
    ['breast augmentation', 'Breast Augmentation All-Inclusive Package', 4300, true],
    ['rhinoplasty', 'Hair Transplant + Rhinoplasty', 5100, false],
    ['hair transplant', 'Hair Transplant + Rhinoplasty', 5100, false],
    ['breast augmentation', '360 Lipo + Breast Augmentation', 6100, false],
    ['breast augmentation', 'Non-Surgical Breast Augmentation', 8200, false],
    ['rhinoplasty', 'Best Friends Rhinoplasty Package (2 People)', 5900, false],
  ]) {
    const relation = classifyProcedureRelation({requestedProcedure, label,
      evidence: `${label} | €${amount}`, sourceUrl: 'https://aster.example/packages/',
      clinicOwnQuoted: true});
    assert.equal(relation.eligible, eligible, `${label}: ${relation.reason}`);
  }
});
