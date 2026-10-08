import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../glow_up_face_analysis_service.dart';

/// Deterministic clinic prompt for OpenAI / Replicate stage 3.
class ClinicPromptBuilder {
  ClinicPromptBuilder._();

  static const String clinicBasePrompt = '''
Professional beauty-portrait retouch — same style as
a high-end ring-light studio photo (neutral, not warm).

IDENTITY — non negotiable:
Same person. Same ethnicity. Same hair.
Same background #000000. Same pose. Same framing.
Same eye color and iris. No zoom. No crop.
Preserve the EXACT skin undertone from the input —
neutral beige / pink, NOT orange, NOT golden, NOT tan.

SKIN:
- Lighten under-eye area — reduce darkness only; natural skin tone (no green or yellow)
- Even, clear complexion — soft dewy finish
- Soften forehead and smile lines — keep texture
- Soften nasolabial folds — shallower, not deeper
- Remove redness and spots only
- Neutral luminosity — healthy and fresh, not bronzed
- Match input skin hue exactly — no color shift
- Keep visible pores — real skin, not plastic

EYES:
- Keep the same catchlights and iris highlights as the input — do NOT add new white spots in pupils
- Sclera may look slightly fresher — never glowing or neon
- Same eye size and shape — no makeup

BROWS:
- Groomed, slightly lifted arch — natural hairs visible

LIPS:
- +10–15% natural volume, same lip color
- Soft hydrated sheen — no lipstick, no liner

CHEEKS:
- Very subtle midface volume if hollow
- Soft neutral highlight on cheekbones — not bronze

JAWLINE:
- If sagging/jowls are present: subtly tighten and refine the jawline (firmness only, no new face shape)

LIGHTING:
- Soft even ring-light beauty lighting on face
- Neutral white balance — no warm or orange cast
- Black background #000000 unchanged

STYLE:
- Clean clinic before/after — realistic photograph
- Same person, clearly fresher — subtle not dramatic
- Like a skilled retoucher, not a beauty filter

FORBIDDEN:
Orange, peach, bronze, golden, or tan skin.
Green, yellow, teal, or neon tint on skin or under eyes.
New artificial catchlights, glowing pupil spots, or over-bright sclera.
Blotchy brown spots, mottled patches, or visible retouch seams on cheeks or forehead.
Lines, arcs, or marks drawn under the eyes.
Warm color grade. Sun-kissed look. Contouring.
Heavy makeup. Eyeliner. Eyeshadow. Mascara.
Plastic airbrush. Cartoon or illustration look.
Changing skin undertone or ethnicity.
Darkening skin. Gray background. Hair halos.
''';

  /// Shorter prompt — closer to ChatGPT web image edit (less under-eye hallucination).
  static const String chatGptStyleBasePrompt = '''
Editorial beauty portrait, polished but realistic — high-end studio retouch.
Same person, same ethnicity, same pose, same framing, same hair, same eye color and iris pattern as the input. Pure black #000000 background unchanged. No zoom, no crop.

HAIR & HAIRLINE — keep pixel-identical (highest priority, do not violate):
Keep the hair EXACTLY as in the input — same hairstyle, same hairline position and shape, same length, same parting, same color and the same darkness. Do NOT regenerate, redraw, recolor, grey, lighten, thin, blur, or move the hair or hairline. Do NOT add flyaways, frizz, halos, stray strands, grain, dusting, or speckle along the hairline, temples, or forehead. The forehead skin next to the hairline must stay the same clean, smooth, even tone as the input — no texture noise, no grey peppering, no specks, no blotchy patch. If in doubt, leave the hair, hairline, and upper forehead visually identical to the input.

ABSOLUTE RULE — NO ARTIFACTS ANYWHERE ON SKIN (highest priority, do not violate):
Do NOT paint, draw, or insert any new shape, patch, oval, half-moon, crescent, arc, curve, dark spot, light spot, shadow, highlight, line, contour, blotch, or discolored zone ANYWHERE on the face: not under the eyes, not on the cheeks, not on the forehead, not on the temples, not on the nose, not on the jawline, not on the chin, not on the neck. Every region of skin must be ONE continuous, uniform, smooth gradient that blends seamlessly with the surrounding skin. If ANY localized mark, oval shape, half-moon, patch, visible boundary, color blob, or hue inconsistency appears in your output, the output is INVALID and you must redo it. The safest default is to leave any area visually identical to the input rather than introduce a mark. When in doubt, do NOTHING to that region.

SKIN COLOR — MANDATORY, NOT OPTIONAL:
The skin in the output MUST match the input skin undertone exactly — same hue, same saturation, same warmth. Actively check every region (forehead, cheeks, nose, chin, neck, under-eyes) and remove ANY warm shift toward orange, peach, golden, tan, bronze, sallow yellow, ruddy red — and ANY shift toward green, grey, or cool blue. There must be no patches of different color, no warm blotches, no cool blotches, no uneven discoloration. The face must read as one consistent neutral skin tone identical to the input. This is required on every output. Do not skip this step.

SKIN QUALITY:
Clear, even, healthy dewy finish. Visible pores and natural texture — never airbrushed plastic. Reduce only redness and small blemishes. Soft natural luminosity, like high-end editorial retouch. The cheeks must be one uniform skin texture from cheekbone down — no dark spots, no light spots, no curved shapes anywhere on the cheek or near the nasolabial area.

FACE:
Soften nasolabial folds and forehead lines — shallower, not erased, no smearing.
Eyes: keep the same iris and catchlights as input — never add new white dots, sparkles, or glow in the pupils. Subtle natural lash definition. No eyeshadow, eyeliner, or mascara.
Brows: groomed, slightly fuller, gently lifted arch — natural hairs visible.
Lips: +10% natural fullness, hydrated soft sheen, the same natural lip color as input (no lipstick, no liner).
Cheeks: very soft healthy flush — neutral pink, not bronze, not orange. Gentle highlight on cheekbones only if natural.

STYLE:
Editorial clinic preview — looks like the same person on their best skincare day. Realistic photograph. Not a filter, not an airbrush, not a beauty app.

FORBIDDEN:
Orange, peach, bronze, golden, tan, sallow, grey, or cool-blue skin shift.
Painted oval / half-moon / patch under the eyes. Drawn arcs or lines on cheeks.
New catchlights, glowing pupils, neon sclera.
Makeup, contouring stripes, heavy shadow.
Plastic airbrush, cartoon, illustration.
Regenerating, greying, thinning, recoloring, or moving the hair or hairline. Grain, dusting, or speckle on the forehead or near the hairline.
Changing skin undertone or ethnicity. Changing face width, jaw, or skull shape — EXCEPT a subtle nose refinement when one is explicitly listed in the treatment goals below.

FINAL STEP — mandatory self-review before producing the output (every step is required, none are optional):

1. FULL-FACE ARTIFACT SCAN (mandatory):
   Scan the ENTIRE face — under each eye, tear-troughs, upper cheeks, lower cheeks, forehead, temples, nose, nasolabial area, jawline, chin, and neck. For EVERY region: is there any oval, half-moon, crescent, curved line, arc, dark spot, light spot, patch, blotch, color blob, or visible boundary that is not in the input? If YES, erase it completely and blend the area into the surrounding uniform skin — same color, same brightness, same texture, no seam. If you cannot remove the artifact cleanly, restore that region to look identical to the input. The output is invalid if any such mark remains anywhere on the skin.

2. DISCOLORATION / COLOR-CAST REMOVAL (mandatory — always perform this step):
   Always check and always neutralize. Inspect every skin region (forehead, cheeks, nose, chin, jaw, neck, under-eyes) and remove ANY warm shift (orange, peach, golden, tan, bronze, sallow yellow, ruddy red), ANY cool shift (green, grey, cool blue), and ANY uneven discoloration patches between regions. The final face must be one consistent neutral skin tone exactly matching the input. Do not skip this. Do not leave any warm/cool/blotchy areas.

3. PLASTIC / CARTOON CHECK (mandatory):
   Does the skin look smoothed-out, waxy, plastic, airbrushed, or AI-rendered? Restore visible pore texture and natural micro-variation everywhere on the face.

Apply all three fixes WITHOUT re-editing identity, pose, framing, hair, hairline, eye color, brow shape, lip shape, jewelry, or background. Keep every refinement explicitly requested in the treatment goals below (for example the nose reshape or lips) fully intact — do NOT revert them during this review; the reshaped nose is intended and is not an artifact. Output only the cleaned final image.
''';

  static bool chatGptStyleFromEnv() {
    final v = (dotenv.env['GLOW_UP_CHATGPT_STYLE'] ?? 'false').trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'on';
  }

  /// Compact stage-3 prompt (ChatGPT-web style).
  static String buildChatGptStyle(
    FaceAnalysisReport report, {
    bool softCapture = false,
  }) {
    final focus = report.findings
        .where((f) => f.recommendEdit)
        .take(3)
        .map((f) => f.areaLabel.toLowerCase())
        .join(', ');
    final note = softCapture ? ' Soft-focus input — keep pores visible.' : '';
    final musts = report.chatGptTreatmentMusts();
    final lipSym =
        '\nLIPS (required): mirror left–right lip symmetry — level mouth corners, even '
        'cupid\'s bow peaks, balanced vermillion on both sides; same natural lip color, no duck lip.';
    final buf = StringBuffer(chatGptStyleBasePrompt);
    if (lipSym.isNotEmpty) buf.write(lipSym);
    if (musts.isNotEmpty) buf.write('\n$musts');
    if (focus.isNotEmpty) buf.write('\nGentle focus: $focus.');
    if (note.isNotEmpty) buf.write(note);
    return buf.toString().trim();
  }

  /// Builds the stage-3 edit prompt from [report].
  static String build(
    FaceAnalysisReport report, {
    double intensity = 0.45,
    bool softCapture = false,
    bool? chatGptStyle,
  }) {
    final useChatGpt = chatGptStyle ?? chatGptStyleFromEnv();
    if (useChatGpt) {
      final prompt = buildChatGptStyle(report, softCapture: softCapture);
      debugPrint('[PROMPT] chatgpt-style (${prompt.length} chars)');
      return prompt;
    }
    // Soft captures need slightly less aggressive edits
    // to avoid hallucination — but still show clear results
    final captureNote = softCapture
        ? '\nCapture note: soft-focus input — '
            'keep natural pores; still make clinic '
            'improvements clearly visible; '
            'soften smile lines (shallower folds, '
            'not deeper shadows).\n'
        : '';

    final prompt = '''
$clinicBasePrompt

Patient findings:
${report.findingsSummary()}$captureNote
'''.trim();

    debugPrint('[FINDINGS]');
    debugPrint(report.findingsSummary());
    debugPrint('[PROMPT]');
    debugPrint(prompt);

    return prompt;
  }

  static double intensityFromEnv() {
    if (chatGptStyleFromEnv()) return 0.42;
    final raw = (dotenv.env['GLOW_UP_CLINIC_INTENSITY'] ?? '0.55').trim();
    return (double.tryParse(raw) ?? 0.55).clamp(0.0, 0.75);
  }
}

/// Structured findings block for [ClinicPromptBuilder].
extension ClinicFindingsSummary on FaceAnalysisReport {
  String findingsSummary() {
    final lines = <String>[];
    for (final f in findings.where((f) => f.recommendEdit)) {
      final label = _clinicFindingLabel(f);
      final level = _clinicSeverityLabel(f);
      lines.add('$label: $level');
    }
    if (plansSmileLineTreatment &&
        !lines.any((l) => l.startsWith('smile lines'))) {
      lines.add('smile lines: soften gently — reduce depth only');
    }
    if (lines.isEmpty) {
      lines.add('skin quality: mild visible aging');
    }
    return lines.join('\n');
  }

  static String _clinicFindingLabel(FaceFinding f) {
    switch (f.area.toLowerCase()) {
      case 'eyes':
        return 'under-eye: brighten and fill tear trough';
      case 'wrinkles':
        return 'wrinkles: soften forehead and smile lines';
      case 'lips':
        return 'lips: add subtle natural volume +15%';
      case 'cheeks':
        return 'cheeks: restore volume and lift midface';
      case 'jaw':
        return 'jaw: refine and define subtly';
      case 'nose':
        return 'nose: minor harmony refinement only';
      case 'filler':
        return 'volume: balance and harmonize';
      case 'skin':
        return 'skin: clear even tone, neutral dewy finish';
      case 'brows':
        return 'brows: lift arch subtly, keep natural';
      default:
        return f.areaLabel.toLowerCase();
    }
  }

  static String _clinicSeverityLabel(FaceFinding f) {
    final s = f.severity.toLowerCase().trim();
    if (s.isNotEmpty && s != 'none') {
      if ({'mild', 'moderate', 'severe', 'visible', 'low', 'high'}.contains(s)) {
        return s;
      }
    }
    final status = f.status.toLowerCase();
    if (status.contains('severe')) return 'severe';
    if (status.contains('moderate')) return 'moderate';
    if (status.contains('mild')) return 'mild';
    if (status.contains('visible')) return 'visible';
    if (status.contains('thin') ||
        status.contains('hollow') ||
        status.contains('volume_loss')) {
      return 'low';
    }
    if (status.contains('asym')) return 'mild';
    if (status.contains('needs')) return 'moderate';
    if ({'ok', 'good', 'balanced', 'natural'}.contains(status)) {
      return 'minimal';
    }
    return f.statusLabel.toLowerCase();
  }
}
