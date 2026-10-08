import 'package:flutter/foundation.dart';

import 'explore_price_evidence.dart';
import 'explore_price_sanity.dart';
import 'explore_procedure_relation.dart';

/// Result of the strict evidence lock before a price may be shown or saved.
class ExplorePriceEvidenceLock {
  const ExplorePriceEvidenceLock.accept({
    required this.evidence,
    required this.relation,
  })  : rejected = false,
        rejectReason = '';

  const ExplorePriceEvidenceLock.reject({
    required this.rejectReason,
    this.relation,
    this.evidence,
  }) : rejected = true;

  final bool rejected;
  final String rejectReason;
  final ExtractedPriceEvidence? evidence;
  final ProcedureRelationResult? relation;

  bool get accepted => !rejected && evidence != null && relation != null;
}

/// True when [amount] appears as a literal number in [source] (HTML/PDF text).
///
/// Accepts common thousand separators (`30,000`, `30.000`, `30 000`) and the
/// compact digits form. Never invents a number that is not on the page.
bool exploreAmountLiterallyInSource(String source, double amount) {
  if (source.trim().isEmpty || amount <= 0) return false;
  final whole = amount == amount.roundToDouble()
      ? amount.round().toString()
      : amount.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  if (whole.isEmpty) return false;

  // Compact: strip spaces/commas/thin spaces so "30,000" and "30000" match.
  final compactSrc = source.replaceAll(RegExp(r'[\s,\u00a0\u202f]'), '');
  final compactAmt = whole.replaceAll(RegExp(r'[\s,]'), '');
  if (compactAmt.length >= 2 && compactSrc.contains(compactAmt)) {
    return true;
  }

  // European thousands with dot: 30.000
  if (whole.length > 3) {
    final withDots = _groupThousands(whole, '.');
    if (source.contains(withDots)) return true;
  }
  // US thousands with comma: 30,000
  if (whole.length > 3) {
    final withCommas = _groupThousands(whole, ',');
    if (source.contains(withCommas)) return true;
  }
  // Raw digits with word boundary-ish (avoid matching phone fragments loosely
  // when the amount is short — still require currency/price context nearby
  // for tiny amounts via caller sanity).
  if (RegExp(
    '(?<![0-9])${RegExp.escape(whole)}(?![0-9])',
  ).hasMatch(source)) {
    return true;
  }
  return false;
}

String _groupThousands(String digits, String sep) {
  final buf = StringBuffer();
  final chars = digits.replaceAll(RegExp(r'[^0-9]'), '').split('').reversed.toList();
  for (var i = 0; i < chars.length; i++) {
    if (i > 0 && i % 3 == 0) buf.write(sep);
    buf.write(chars[i]);
  }
  return buf.toString().split('').reversed.join();
}

/// Price and procedure must share the same smallest evidence block.
bool explorePriceAndProcedureShareEvidenceBlock(
  ExtractedPriceEvidence row, {
  String requestedProcedure = '',
}) {
  final block = row.rawEvidence.trim().isNotEmpty
      ? row.rawEvidence
      : '${row.rawProcedureText}\n${row.rawPriceText}';
  if (block.trim().isEmpty) return false;
  if (!exploreAmountLiterallyInSource(block, row.priceMin)) return false;
  final label = row.rawProcedureText.trim();
  if (label.isEmpty) return false;
  // Never treat raw HTML scraps as a procedure label.
  if (label.contains('<') || label.contains('stylesheet') || label.length > 180) {
    return false;
  }

  final foldedBlock = block.toLowerCase();
  final foldedLabel = label.toLowerCase();
  if (foldedBlock.contains(foldedLabel)) return true;

  final tokens = foldedLabel
      .split(RegExp(r'[^a-z0-9\u0600-\u06ff]+'))
      .where((t) => t.length >= 4)
      .toList();
  var hits = 0;
  for (final t in tokens) {
    if (foldedBlock.contains(t)) hits++;
  }
  if (hits >= 1) return true;

  // Localized menus: English URL slug ("rhinoplasty") + Arabic evidence in the
  // same extractor row. Accept when the amount is in the price text and the
  // block carries the requested treatment family.
  final amountInPrice =
      exploreAmountLiterallyInSource(row.rawPriceText, row.priceMin);
  if (!amountInPrice) return tokens.isEmpty;

  final want = exploreRelationRequestedFamily(
    requestedProcedure.trim().isNotEmpty ? requestedProcedure : label,
  );
  if (want != 'other') {
    final signals = detectProcedureTreatmentSignals(block);
    if (signals.matchesRequested(want)) return true;
  }
  // Short Latin slug label already paired with an amount by the extractor.
  if (label.length <= 48 &&
      RegExp(r'^[A-Za-z][A-Za-z0-9\s\-/]*$').hasMatch(label) &&
      exploreAmountLiterallyInSource(row.rawEvidence, row.priceMin)) {
    return true;
  }
  return tokens.isEmpty;
}

void logPriceSource(String source, {String url = ''}) {
  final suffix = url.trim().isEmpty ? '' : ' · $url';
  debugPrint('[PRICE SOURCE] $source$suffix');
}

void logPriceLiteralFound({
  required double amount,
  required String currency,
  required String rawPriceText,
}) {
  final raw = rawPriceText.trim();
  final clipped = raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
  debugPrint(
    '[PRICE LITERAL FOUND] ${amount.round()} $currency · "$clipped"',
  );
}

void logProcedureRelationLock(ProcedureRelationResult relation, {String label = ''}) {
  // Skip noisy rejects; ACCEPT path logs via [PRICE ACCEPT].
  if (!relation.eligibleForFromPrice) return;
  final short = label.trim();
  final suffix = short.isEmpty
      ? ''
      : ' · "${short.length > 72 ? '${short.substring(0, 72)}…' : short}"';
  debugPrint(
    '[PROCEDURE RELATION] ${relation.logToken} · ${relation.reason}$suffix',
  );
}

void logPriceReject(String reason, {String detail = ''}) {
  // Cap reject log volume — full reject storms freeze Flutter debug console.
  if (!_shouldEmitPriceRejectLog(reason)) return;
  final suffix = detail.trim().isEmpty ? '' : ' · $detail';
  debugPrint('[PRICE REJECT] $reason$suffix');
}

int _priceRejectLogBudget = 12;
DateTime _priceRejectLogWindow = DateTime.fromMillisecondsSinceEpoch(0);

bool _shouldEmitPriceRejectLog(String reason) {
  final now = DateTime.now();
  if (now.difference(_priceRejectLogWindow) > const Duration(seconds: 2)) {
    _priceRejectLogWindow = now;
    _priceRejectLogBudget = 12;
  }
  if (_priceRejectLogBudget <= 0) return false;
  // Always keep room for lock / accept-adjacent rejects.
  if (reason.startsWith('relation_') && _priceRejectLogBudget < 4) {
    return false;
  }
  _priceRejectLogBudget--;
  return true;
}

void logPriceAcceptLock({
  required String clinic,
  required String procedure,
  required ExtractedPriceEvidence evidence,
  required ProcedureRelationResult relation,
}) {
  debugPrint(
    '[PRICE ACCEPT] clinic="$clinic" procedure="$procedure" '
    'relation=${relation.logToken} '
    'raw="${evidence.rawPriceText.length > 64 ? '${evidence.rawPriceText.substring(0, 64)}…' : evidence.rawPriceText}" '
    'parsed=${evidence.priceMin.round()} ${evidence.currency} '
    'method=${evidence.extractionMethod.wire} '
    'url=${evidence.sourceUrl}',
  );
}

/// Strict gate: literal amount in page + same block + exact/variant relation.
ExplorePriceEvidenceLock lockExplorePriceEvidence({
  required ExtractedPriceEvidence candidate,
  required String procedure,
  required String sourceHtmlOrText,
  bool clinicOwnQuoted = false,
  bool pageHasFamilyWitness = false,
}) {
  final src = sourceHtmlOrText.trim().isNotEmpty
      ? sourceHtmlOrText
      : '${candidate.rawEvidence}\n${candidate.rawPriceText}';

  if (!exploreAmountLiterallyInSource(src, candidate.priceMin) &&
      !exploreAmountLiterallyInSource(candidate.rawPriceText, candidate.priceMin) &&
      !exploreAmountLiterallyInSource(candidate.rawEvidence, candidate.priceMin)) {
    logPriceReject(
      'amount_not_literal_in_source',
      detail: '${candidate.priceMin.round()} missing from HTML/PDF',
    );
    return ExplorePriceEvidenceLock.reject(
      rejectReason: 'amount_not_literal_in_source',
    );
  }
  logPriceLiteralFound(
    amount: candidate.priceMin,
    currency: candidate.currency,
    rawPriceText: candidate.rawPriceText,
  );

  if (!explorePriceAndProcedureShareEvidenceBlock(
    candidate,
    requestedProcedure: procedure,
  )) {
    logPriceReject(
      'procedure_price_block_mismatch',
      detail: candidate.rawProcedureText,
    );
    return ExplorePriceEvidenceLock.reject(
      rejectReason: 'procedure_price_block_mismatch',
    );
  }

  // Prefer a page-level family witness when the HTML already showed the
  // requested treatment (same signal the picker used). Also treat official
  // /preturi menus as a witness so bare "1100 Lei/1 ml" cells lock.
  final menuWitness = exploreSourceUrlLooksLikePriceMenu(candidate.sourceUrl);
  final relation = classifyProcedureRelation(
    requestedProcedure: procedure,
    label: candidate.rawProcedureText,
    evidence: '${candidate.rawPriceText}\n${candidate.rawEvidence}',
    sourceUrl: candidate.sourceUrl,
    clinicOwnQuoted: clinicOwnQuoted,
    pageHasFamilyWitness: pageHasFamilyWitness || menuWitness,
  );
  logProcedureRelationLock(relation, label: candidate.rawProcedureText);

  if (!relation.eligibleForFromPrice) {
    logPriceReject(
      'relation_${relation.logToken}',
      detail: relation.reason,
    );
    return ExplorePriceEvidenceLock.reject(
      rejectReason: 'relation_${relation.logToken}',
      relation: relation,
      evidence: candidate,
    );
  }

  if (!isValidExtractedPriceCandidate(
    rawPriceText: candidate.rawPriceText,
    priceMin: candidate.priceMin,
    currency: candidate.currency,
    extractionMethod: candidate.extractionMethod.wire,
    rawEvidence: candidate.rawEvidence,
    procedure: procedure,
    sourceUrl: candidate.sourceUrl,
    priceMax: candidate.priceMax,
    logRejects: false,
  )) {
    final why = evaluateExtractedPriceCandidate(
      rawPriceText: candidate.rawPriceText,
      priceMin: candidate.priceMin,
      currency: candidate.currency,
      extractionMethod: candidate.extractionMethod.wire,
      rawEvidence: candidate.rawEvidence,
      procedure: procedure,
      sourceUrl: candidate.sourceUrl,
      priceMax: candidate.priceMax,
    ).reason;
    logPriceReject(why.isEmpty ? 'sanity_reject' : why);
    return ExplorePriceEvidenceLock.reject(
      rejectReason: why.isEmpty ? 'sanity_reject' : why,
      relation: relation,
      evidence: candidate,
    );
  }

  return ExplorePriceEvidenceLock.accept(
    evidence: candidate,
    relation: relation,
  );
}
