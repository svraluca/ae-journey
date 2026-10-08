'use strict';

/**
 * Review queue for ambiguous / uncertain Explore verifications.
 * Uncertain records must not be shown as verified cards.
 */
const COLLECTION = 'explore_price_review_queue';

function reviewDocId({
  cityId = '',
  branchId = '',
  procedureCanonicalId = '',
  reason = '',
} = {}) {
  const raw = [
    String(cityId).trim(),
    String(branchId).trim(),
    String(procedureCanonicalId).trim().toLowerCase(),
    String(reason).trim().toLowerCase(),
  ].join('|');
  return encodeURIComponent(raw).replace(/%/g, '_').slice(0, 400);
}

/**
 * Enqueue an ambiguous verification outcome for human / secondary review.
 * Idempotent on cityId+branch+procedure+reason.
 */
async function enqueuePriceReview(admin, {
  cityId = '',
  branchId = '',
  clinicId = '',
  procedureCanonicalId = '',
  reason = 'ambiguous',
  details = {},
  sourceUrl = '',
} = {}) {
  if (!admin) throw new Error('admin required');
  const id = reviewDocId({
    cityId,
    branchId,
    procedureCanonicalId,
    reason,
  });
  const ref = admin.firestore().collection(COLLECTION).doc(id);
  await ref.set({
    cityId,
    branchId,
    clinicId,
    procedureCanonicalId,
    reason,
    details,
    sourceUrl,
    status: 'open',
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }, {merge: true});
  return id;
}

module.exports = {
  COLLECTION,
  reviewDocId,
  enqueuePriceReview,
};
