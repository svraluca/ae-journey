import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/openai_service.dart';
import '../services/explore_price_sanity.dart';
import '../services/filter_currency.dart';
import 'clinic_compare_price_display.dart';

/// Fill tone for clinic price pins (matches badges on compare / expanded map).
enum MapPricePinTone { defaultNavy, best, premium }

/// [standard] = expanded map; [compact] = small preview card map.
enum MapPricePinLayout { standard, compact }

const _kInk = Color(0xFF1A1A2E);
const _kGreen = Color(0xFF1D9E75);
const _kPremium = Color(0xFFC4607A);

MapPricePinTone mapPricePinToneFor(OpenAIClinic c) {
  final v = c.badgeVariant.toLowerCase();
  if (v == 'best') return MapPricePinTone.best;
  if (v == 'hi') return MapPricePinTone.premium;
  return MapPricePinTone.defaultNavy;
}

Color mapPricePinFillColor(MapPricePinTone tone) {
  switch (tone) {
    case MapPricePinTone.best:
      return _kGreen;
    case MapPricePinTone.premium:
      return _kPremium;
    case MapPricePinTone.defaultNavy:
      return _kInk;
  }
}

/// Short price string for pin label and list rows.
/// When [displayCurrency] is set, converts from the clinic currency.
String mapPricePinShortLabel(
  OpenAIClinic c, {
  FilterCurrency? displayCurrency,
}) {
  if (!c.hasProcedure) return 'Not listed';
  if (c.pricePending) return '…';
  if (exploreClinicIsNoPublicPrice(c)) return '—';
  if (c.priceMin > 0 &&
      !isValidExtractedPriceCandidate(
        rawPriceText:
            c.rawPriceText.trim().isNotEmpty ? c.rawPriceText : c.priceLabel,
        priceMin: c.priceMin,
        priceMax: c.priceMax,
        currency: c.currency,
        extractionMethod: c.extractionMethod,
        rawEvidence: c.priceEvidenceText,
        procedure: c.brand,
        sourceUrl: c.priceSourceUrl,
      )) {
    return '—';
  }

  if (displayCurrency != null) {
    final converted = convertClinicPriceLabel(c, displayCurrency);
    if (converted != null) {
      if (converted.length > 22) return '${converted.substring(0, 20)}…';
      return converted;
    }
  }

  // Use the same verified formatter as the card: ranges are not phone
  // numbers, and a published 40 AED/unit rate must retain its unit on a pin.
  final listed = clinicCompareProcedurePriceDisplay(c);
  if (listed.isNotEmpty) {
    final compact = priceLabelCurrencyAfter(listed);
    return compact.length > 22 ? '${compact.substring(0, 20)}…' : compact;
  }

  // Prefer the clinic's published/curated label (Worldwide guide prices often
  // fail the AI "justified" thresholds, e.g. AED 42 or $12–$16 per unit).
  final raw = c.priceLabel.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (raw.isNotEmpty && RegExp(r'\d').hasMatch(raw)) {
    if (looksLikePhoneNumber(raw) || looksLikeAddressNumber(raw)) {
      return '—';
    }
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 8) return '—';
    final ordered = priceLabelCurrencyAfter(raw);
    if (ordered.length > 22) return '${ordered.substring(0, 20)}…';
    return ordered;
  }

  final line = clinicCompareProcedurePriceDisplay(c);
  if (line.isEmpty) return '—';
  final compact =
      priceLabelCurrencyAfter(line.replaceAll(RegExp(r'\s+'), ' ').trim());
  if (compact.length > 22) return '${compact.substring(0, 20)}…';
  return compact;
}

/// Converts a clinic price into [to] using approximate FX rates.
/// Returns null when [to] is null (keep website currency) or amount unknown.
String? convertClinicPriceLabel(OpenAIClinic c, FilterCurrency? to) {
  if (to == null) return null;
  // Never FX-convert a city-default guess — that turned Dubai 1000 AED
  // (mislabeled £) into ~4,649 AED.
  if (!c.currencyConfirmed) return null;
  final label = c.priceLabel.trim();
  final fromCode = FilterFx.detectCodeFromLabel(
    label,
    fallback: c.currency.trim().isNotEmpty ? c.currency.trim() : r'$',
  );

  double? amount;
  if (c.priceMin > 0) {
    amount = c.priceMin;
  } else {
    amount = FilterFx.parseAmount(label);
  }
  if (amount == null || amount <= 0) return null;

  final converted = FilterFx.convert(
    amount: amount,
    fromCode: fromCode,
    to: to,
  );
  final hasFrom = label.toLowerCase().startsWith('from ') || c.priceMin > 0;
  return FilterFx.formatAmount(converted, to, fromPrefix: hasFrom);
}

/// Resolves marker position; fans out clinics with missing coords around [mapCenter].
LatLng clinicMapLatLng(OpenAIClinic clinic, LatLng mapCenter, int index) {
  if (clinic.coord.lat.abs() > 1e-5 || clinic.coord.lng.abs() > 1e-5) {
    return LatLng(clinic.coord.lat, clinic.coord.lng);
  }
  final row = index % 3;
  final col = index ~/ 3;
  return LatLng(
    mapCenter.latitude + row * 0.012 - 0.012,
    mapCenter.longitude + col * 0.012 - 0.012,
  );
}

Future<BitmapDescriptor> buildMapPricePinDescriptor({
  required OpenAIClinic clinic,
  required bool isSelected,
  required double pixelRatio,
  MapPricePinLayout layout = MapPricePinLayout.standard,
  FilterCurrency? displayCurrency,
}) async {
  final price = mapPricePinShortLabel(
    clinic,
    displayCurrency: displayCurrency,
  );

  final double logicalW;
  final double logicalBodyH;
  final double logicalTailDrop;
  final double radius;
  final double fontSize;
  final double textPadH;
  final double tailHalf;
  final double tailExtend;
  final double outPad;
  final double unSelStrokeInner;
  final double unSelStrokeScale;
  final double letterSpacing;

  switch (layout) {
    case MapPricePinLayout.standard:
      logicalW = 108;
      logicalBodyH = 34;
      logicalTailDrop = 6;
      radius = 16;
      fontSize = 12;
      textPadH = 12;
      tailHalf = 6.5;
      tailExtend = 1.25;
      outPad = 4;
      unSelStrokeInner = 1;
      unSelStrokeScale = 1.25;
      letterSpacing = 0.35;
      break;
    case MapPricePinLayout.compact:
      logicalW = 76;
      logicalBodyH = 26;
      logicalTailDrop = 4.5;
      radius = 12;
      fontSize = 9.5;
      textPadH = 8;
      tailHalf = 5;
      tailExtend = 0.85;
      outPad = 3;
      unSelStrokeInner = 0.85;
      unSelStrokeScale = 1.05;
      letterSpacing = 0.22;
      break;
  }

  final logicalH = logicalBodyH + logicalTailDrop;
  final pr = pixelRatio;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(pr);

  final bodyRect = Rect.fromLTWH(0, 0, logicalW, logicalBodyH);
  final bodyR = RRect.fromRectAndRadius(bodyRect, Radius.circular(radius));

  if (isSelected) {
    // Soft light edge only — no ink/black frame or drop-shadow halo.
    canvas.drawRRect(bodyR, Paint()..color = Colors.white);
    canvas.drawRRect(
      bodyR,
      Paint()
        ..color = const Color(0xFFD8DCE4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, 1.25 / pr),
    );
  } else {
    // Default pins are always ink/black; selected flips to white.
    canvas.drawRRect(bodyR, Paint()..color = _kInk);
    canvas.drawRRect(
      bodyR,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(unSelStrokeInner, unSelStrokeScale / pr),
    );
  }

  final textColor = isSelected ? _kInk : Colors.white;
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    text: TextSpan(
      text: price,
      style: GoogleFonts.urbanist(
        color: textColor,
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        height: 1.0,
        letterSpacing: letterSpacing,
      ),
    ),
  )..layout(maxWidth: logicalW - textPadH);

  final textY = ((logicalBodyH - tp.height) / 2).clamp(0.0, logicalBodyH);
  tp.paint(canvas, Offset(((logicalW - tp.width) / 2).clamp(0.0, logicalW), textY));

  final cx = logicalW / 2;
  final tailTop = logicalBodyH;
  final tailPath = ui.Path()
    ..moveTo(cx - tailHalf, tailTop - 0.75)
    ..lineTo(cx + tailHalf, tailTop - 0.75)
    ..lineTo(cx, logicalH + tailExtend)
    ..close();

  if (isSelected) {
    canvas.drawPath(tailPath, Paint()..color = Colors.white);
    canvas.drawPath(
      tailPath,
      Paint()
        ..color = const Color(0xFFD8DCE4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, 1.25 / pr),
    );
  } else {
    canvas.drawPath(tailPath, Paint()..color = _kInk);
    canvas.drawPath(
      tailPath,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(unSelStrokeInner, unSelStrokeScale / pr),
    );
  }

  final picture = recorder.endRecording();
  final outW = (logicalW * pr).ceil();
  final outH = ((logicalH + outPad) * pr).ceil();
  final ui.Image image = await picture.toImage(outW, outH);
  final bd = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final bytes = bd!.buffer.asUint8List();
  return BitmapDescriptor.bytes(bytes, imagePixelRatio: pr);
}
