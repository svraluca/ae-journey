import '../data/procedure.dart';

/// Preset procedure icons — keep in sync with [_kPresets] in procedure_form_screen.dart.
const presetIconByName = <String, String>{
  'Filler': 'assets/injection.png',
  'Botox': 'assets/botoxicon.png',
  'Polynucleotides': 'assets/polynucleotidesicon.png',
  'Biostimulator': 'assets/biostimulatorsicon.png',
  'Microneedling': 'assets/microneedelingicon.png',
  'RF Microneedling': 'assets/microneedeling.png',
  'Morpheus8 (body)': 'assets/morpheus8.png',
  'CO₂ Laser (body)': 'assets/co2laser.png',
  'HIFU (body)': 'assets/hifu.png',
  'ONDA Coolwaves': 'assets/onda.png',
  'Laser hair removal': 'assets/hifu.png',
  'Lymphatic drainage massage': 'assets/lymphatic.png',
  'Post-op massage': 'assets/post-op.png',
  'Rhinoplasty': 'assets/noseicon.png',
  'Blepharoplasty': 'assets/blapheroicon.png',
  'Otoplasty': 'assets/otaplasty.png',
  'Breast augmentation': 'assets/breasticon.png',
  'BBL (booty job)': 'assets/bbl.png',
  'Facelift': 'assets/facelifticon.png',
  'Mini facelift': 'assets/facelifticon.png',
  'Hair transplant': 'assets/hairtransplant.png',
  'Abdominoplasty (tummy tuck)': 'assets/abdominoplasty.png',
  'Liposuction': 'assets/liposuction.png',
  'Breast lift': 'assets/breasticon.png',
};

const _presetIconByName = presetIconByName;

const _presetEmojiByName = <String, String>{
  'Filler': '💉',
  'Botox': '✨',
  'Polynucleotides': '🧬',
  'Biostimulator': '🌙',
  'Microneedling': '📍',
  'RF Microneedling': '⚡',
  'Morpheus8 (body)': '⚡',
  'CO₂ Laser (body)': '🔥',
  'HIFU (body)': '📡',
  'ONDA Coolwaves': '〰️',
  'Laser hair removal': '✨',
  'Lymphatic drainage massage': '💆',
  'Post-op massage': '🫧',
  'Rhinoplasty': '👃',
  'Blepharoplasty': '👁️',
  'Otoplasty': '👂',
  'Breast augmentation': '🎀',
  'BBL (booty job)': '🍑',
  'Facelift': '✨',
  'Mini facelift': '✨',
  'Hair transplant': '💇',
  'Abdominoplasty (tummy tuck)': '🩹',
  'Liposuction': '🌀',
  'Breast lift': '🎀',
  'Labiaplasty': '◇',
  'Penile enlargement': '◇',
};

/// Longest names first so "RF Microneedling" wins over "Microneedling".
final _presetNamesByLength = _presetIconByName.keys.toList()
  ..sort((a, b) => b.length.compareTo(a.length));

class ProcedureIconInfo {
  const ProcedureIconInfo({this.asset, this.emoji});

  final String? asset;
  final String? emoji;
}

/// Resolves the same preset asset icons used in [procedure_form_screen]
/// from a free-form procedure title (clinic lists, search results, etc.).
ProcedureIconInfo procedureIconForTitle(String title, {String? category}) {
  return procedureIconFor(
    Procedure(title: title, date: DateTime(2000), category: category),
  );
}

ProcedureIconInfo procedureIconFor(Procedure procedure) {
  final title = procedure.title.trim();
  final lower = title.toLowerCase();
  final cat = (procedure.category ?? '').trim().toLowerCase();

  for (final name in _presetNamesByLength) {
    final key = name.toLowerCase();
    if (lower == key || lower.contains(key)) {
      return ProcedureIconInfo(
        asset: _presetIconByName[name],
        emoji: _presetEmojiByName[name],
      );
    }
  }

  // Keyword fallbacks for custom / localized titles.
  if (lower.contains('botox') || lower.contains('toxin')) {
    return const ProcedureIconInfo(asset: 'assets/botoxicon.png', emoji: '✨');
  }
  if (lower.contains('polynucleotide') || lower.contains('profhilo') || lower.contains('rejuran')) {
    return const ProcedureIconInfo(asset: 'assets/polynucleotidesicon.png', emoji: '🧬');
  }
  if (lower.contains('biostim') || lower.contains('sculptra')) {
    return const ProcedureIconInfo(asset: 'assets/biostimulatorsicon.png', emoji: '🌙');
  }
  if (lower.contains('filler') ||
      lower.contains('inject') ||
      lower.contains('hialuron') ||
      lower.contains('hyaluron') ||
      lower.contains('acid hialuronic')) {
    return const ProcedureIconInfo(asset: 'assets/injection.png', emoji: '💉');
  }
  if (lower.contains('morpheus')) {
    return const ProcedureIconInfo(asset: 'assets/morpheus8.png', emoji: '⚡');
  }
  if (lower.contains('microneed') || lower.contains('microned')) {
    return const ProcedureIconInfo(asset: 'assets/microneedelingicon.png', emoji: '📍');
  }
  if (lower.contains('hair removal') || lower.contains('epilare') || lower.contains('epilat') || lower.contains('depil')) {
    return const ProcedureIconInfo(asset: 'assets/hifu.png', emoji: '📡');
  }
  if (lower.contains('laser') || lower.contains('co2') || lower.contains('co₂')) {
    return const ProcedureIconInfo(asset: 'assets/co2laser.png', emoji: '🔥');
  }
  if (lower.contains('hifu') || lower.contains('ultherapy')) {
    return const ProcedureIconInfo(asset: 'assets/hifu.png', emoji: '📡');
  }
  if (lower.contains('onda')) {
    return const ProcedureIconInfo(asset: 'assets/onda.png', emoji: '〰️');
  }
  if (lower.contains('rhino') || lower.contains('rinoplast')) {
    return const ProcedureIconInfo(asset: 'assets/noseicon.png', emoji: '👃');
  }
  if (lower.contains('blephar') || lower.contains('eyelid') || lower.contains('blefaro')) {
    return const ProcedureIconInfo(asset: 'assets/blapheroicon.png', emoji: '👁️');
  }
  if (lower.contains('otoplast')) {
    return const ProcedureIconInfo(asset: 'assets/otaplasty.png', emoji: '👂');
  }
  if (lower.contains('bbl') || lower.contains('brazilian') || lower.contains('butt lift')) {
    return const ProcedureIconInfo(asset: 'assets/bbl.png', emoji: '🍑');
  }
  if (lower.contains('facelift') || lower.contains('face lift') || lower.contains('lifting facial')) {
    return const ProcedureIconInfo(asset: 'assets/facelifticon.png', emoji: '✨');
  }
  if (lower.contains('hair transplant') || lower.contains('transplant de par') || lower.contains('transplant păr')) {
    return const ProcedureIconInfo(asset: 'assets/hairtransplant.png', emoji: '💇');
  }
  if (lower.contains('abdomin') || lower.contains('tummy tuck') || lower.contains('abdominoplast')) {
    return const ProcedureIconInfo(asset: 'assets/abdominoplasty.png', emoji: '🩹');
  }
  if (lower.contains('lipo') || lower.contains('liposuc')) {
    return const ProcedureIconInfo(asset: 'assets/liposuction.png', emoji: '🌀');
  }
  if (lower.contains('breast') ||
      lower.contains('augmentare mamar') ||
      lower.contains('marire san') ||
      lower.contains('mărire sân') ||
      lower.contains('mastopex')) {
    return const ProcedureIconInfo(asset: 'assets/breasticon.png', emoji: '🎀');
  }
  if (lower.contains('lymphatic') || lower.contains('limfatic')) {
    return const ProcedureIconInfo(asset: 'assets/lymphatic.png', emoji: '💆');
  }
  if (lower.contains('post-op') || lower.contains('post op') || lower.contains('postop')) {
    return const ProcedureIconInfo(asset: 'assets/post-op.png', emoji: '🫧');
  }
  if (lower.contains('scar') || lower.contains('cicatric')) {
    return const ProcedureIconInfo(asset: 'assets/staricon.png', emoji: '✨');
  }

  if (cat.contains('hair removal')) {
    return const ProcedureIconInfo(asset: 'assets/hifu.png', emoji: '📡');
  }
  if (cat.contains('surgery') || cat.contains('chirurg')) {
    return const ProcedureIconInfo(asset: 'assets/knifeicon.png', emoji: '🔪');
  }
  if (cat.contains('inject') || cat.contains('botox')) {
    return const ProcedureIconInfo(asset: 'assets/injection.png', emoji: '💉');
  }
  if (cat.contains('laser') || cat.contains('energy')) {
    return const ProcedureIconInfo(asset: 'assets/co2laser.png', emoji: '🔥');
  }
  if (cat.contains('skin') || cat.contains('piele')) {
    return const ProcedureIconInfo(asset: 'assets/microneedelingicon.png', emoji: '📍');
  }

  return const ProcedureIconInfo(asset: 'assets/staricon.png', emoji: '✨');
}
