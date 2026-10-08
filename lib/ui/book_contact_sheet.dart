import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/google_places_service.dart';

/// Looks up phone on profile first; if empty, repeats Google Places lookup
/// (same source used to enrich clinic profiles).
Future<String?> resolveBookingPhone({
  required GooglePlacesService places,
  required String clinicName,
  required String city,
  required String existingPhone,
}) async {
  var p = existingPhone.trim();
  if (p.isNotEmpty) return p;
  if (!places.isConfigured) return null;
  final g = await places.lookupClinic(clinicName: clinicName, city: city);
  p = (g?.phone ?? '').trim();
  return p.isNotEmpty ? p : null;
}

/// If [mergedPhoneFromProfile] is empty, shows a short overlay and resolves
/// the public line via Google Places (Places Details API).
Future<String?> ensureBookingPhoneWithGooglePlaces({
  required BuildContext context,
  required GooglePlacesService places,
  required String clinicName,
  required String city,
  required String mergedPhoneFromProfile,
}) async {
  var phone = mergedPhoneFromProfile.trim();
  if (phone.isNotEmpty) return phone;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) {
      return PopScope(
        canPop: false,
        child: Material(
          color: Colors.black26,
          child: Center(
            child: Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 26,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Finding number on Google…',
                      style: GoogleFonts.urbanist(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF1A1A1A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  try {
    return await resolveBookingPhone(
      places: places,
      clinicName: clinicName,
      city: city,
      existingPhone: '',
    );
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

String _telLaunchString(String raw) {
  final hasPlus = raw.trim().startsWith('+');
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return '';
  return hasPlus ? '+$digits' : digits;
}

/// Digits suitable for `wa.me` only when the number plausibly targets a mobile
/// line (WhatsApp). Landlines and empty values return null.
String? _whatsappWaMeDigits(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;
  final d = t.replaceAll(RegExp(r'\D'), '');
  if (d.length < 10 || d.length > 15) return null;
  if (!_digitsLookLikeMobileForWhatsApp(d)) return null;
  return d;
}

bool _digitsLookLikeMobileForWhatsApp(String d) {
  if (d.length < 10 || d.length > 15) return false;

  if (d.startsWith('44')) {
    return d.length >= 11 && d[2] == '7';
  }
  if (d.startsWith('40')) {
    return d.length >= 11 && d[2] == '7';
  }
  if (d.startsWith('33')) {
    return d.length >= 11 && (d[2] == '6' || d[2] == '7');
  }
  if (d.startsWith('39')) {
    return d.length >= 11 && d[2] == '3';
  }
  if (d.startsWith('34')) {
    return d.length >= 11 && (d[2] == '6' || d[2] == '7');
  }
  if (d.startsWith('49')) {
    if (d.length < 12) return false;
    final p = d.substring(2, 4);
    return p == '15' || p == '16' || p == '17';
  }
  if (d.startsWith('971')) {
    return d.length >= 11 && d.length > 3 && d[3] == '5';
  }
  if (d.startsWith('1') && d.length == 11) {
    return true;
  }
  return d.length >= 11;
}

String _clinicAvatarInitials(String clinicName) {
  final parts = clinicName
      .trim()
      .split(RegExp(r'\s+'))
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '★';
  if (parts.length == 1) {
    final s = parts.first;
    final up = s.toUpperCase();
    return up.length >= 2 ? up.substring(0, 2) : '$up★';
  }
  return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
}

String _starsAscii(double r) {
  final full = r.floor().clamp(0, 5);
  final half = (r - full) >= 0.5;
  final filled = full + (half ? 1 : 0);
  return '${'★' * filled}${'☆' * (5 - filled)}';
}

Uri? _websiteUri(String? normalizedOrRaw) {
  if (normalizedOrRaw == null) return null;
  final t = normalizedOrRaw.trim();
  if (t.isEmpty) return null;
  final u = t.startsWith('http') ? t : 'https://$t';
  return Uri.tryParse(u);
}

Uri? _instagramUri(String? raw) {
  if (raw == null) return null;
  final t = raw.trim();
  if (t.isEmpty) return null;
  if (t.contains('instagram.com')) {
    final u = t.startsWith('http') ? t : 'https://$t';
    return Uri.tryParse(u);
  }
  final h = t.replaceFirst('@', '').trim();
  if (h.isEmpty) return null;
  return Uri.tryParse('https://www.instagram.com/$h/');
}

Future<void> _tryLaunch(
  BuildContext context,
  Uri? uri, {
  required String errorLabel,
}) async {
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $errorLabel')),
      );
    }
  }
}

String? _websiteHostForSubtitle(String? websiteUrl) {
  final u = _websiteUri(websiteUrl);
  if (u == null) return null;
  var host = u.host;
  if (host.startsWith('www.')) {
    host = host.substring(4);
  }
  return host.isEmpty ? null : host;
}

/// Handle for Instagram subtitle (not a full URL).
String _instagramHandleDisplay(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  final t = raw.trim();
  if (t.contains('instagram.com')) {
    final parsed = Uri.tryParse(t.startsWith('http') ? t : 'https://$t');
    if (parsed != null && parsed.pathSegments.isNotEmpty) {
      final first = parsed.pathSegments.firstWhere(
        (s) => s.isNotEmpty,
        orElse: () => '',
      );
      if (first.isNotEmpty) return first;
    }
  }
  return t.replaceFirst('@', '');
}

/// Google Places [weekday_text] uses the API language hint (`ro` for Bucharest,
/// etc.), so strings look like `"luni: 10:00–21:00"`. Next to English status
/// copy we show only the hours slice.
String _hoursWithoutLocalizedWeekdayPrefix(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';

  final firstChunk = t.split(RegExp(r'\s+·\s+')).first.trim();

  final afterColon =
      RegExp(r'^[^:]+:\s*(.+)$').firstMatch(firstChunk)?.group(1)?.trim();

  if (afterColon != null && afterColon.isNotEmpty) {
    return afterColon;
  }

  return firstChunk;
}

Widget _v2PulseDot() {
  return SizedBox(
    width: 10,
    height: 10,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x401D9E75),
          ),
        ),
        Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF1D9E75),
          ),
        ),
      ],
    ),
  );
}

Widget _v2BookingRow({
  required TextStyle sf,
  required bool enabled,
  required bool isDarkCall,
  required Color iconSquareBg,
  required Widget icon,
  required String title,
  required String subtitle,
  required VoidCallback? onTap,
}) {
  const radius = BorderRadius.all(Radius.circular(16));
  final opacity = enabled ? 1.0 : 0.42;
  return Opacity(
    opacity: opacity,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: isDarkCall ? const Color(0xFF1A1A2E) : Colors.white,
            borderRadius: radius,
            border: Border.all(
              color:
                  isDarkCall ? const Color(0xFF1A1A2E) : const Color(0xFFF0F0F0),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconSquareBg,
                  borderRadius: BorderRadius.circular(13),
                ),
                alignment: Alignment.center,
                child: icon,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: sf.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color:
                            isDarkCall ? Colors.white : const Color(0xFF1A1A1A),
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: sf.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isDarkCall
                            ? Colors.white.withValues(alpha: 0.38)
                            : const Color(0xFFAAAAAA),
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 24,
                color: isDarkCall
                    ? Colors.white.withValues(alpha: 0.2)
                    : const Color(0xFFDDDDDD),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Matches `book_sheet_v2.html`: clinic row, status bar + pulse, copy row,
/// full-width stacked booking options + cancel.
Future<void> showBookAppointmentSheet(
  BuildContext context, {
  required String clinicName,
  required String phone,
  double? rating,
  int? procedureCount,
  bool? isOpenNow,
  String? openingHoursOneLine,
  String? websiteUrl,
  String? instagramHandle,
}) async {
  final sf = GoogleFonts.urbanist();
  final serif = GoogleFonts.dmSerifDisplay();

  final telStr = _telLaunchString(phone);
  final waDigits = _whatsappWaMeDigits(phone);
  final telUri =
      telStr.isNotEmpty ? Uri.parse('tel:$telStr') : null;
  final waUri = waDigits != null
      ? Uri.parse('https://wa.me/$waDigits')
      : null;

  final siteUri = _websiteUri(websiteUrl);
  final igUri = _instagramUri(instagramHandle);
  final siteHost = _websiteHostForSubtitle(websiteUrl);
  final igDisplay = _instagramHandleDisplay(instagramHandle);

  final rVal = rating ?? 0;
  final showStars = rVal > 0;
  final procLabel =
      procedureCount != null && procedureCount > 0
          ? '$procedureCount procedures'
          : null;
  final openLabel = isOpenNow == null
      ? null
      : isOpenNow
          ? 'Open now'
          : 'Closed';
  final statusText = isOpenNow == true
      ? 'Available for appointments today'
      : 'Check availability first';

  final availTime = _hoursWithoutLocalizedWeekdayPrefix(
    openingHoursOneLine ?? '',
  );

  final webSub = siteHost != null && siteHost.isNotEmpty
      ? '$siteHost · Online booking'
      : 'Book on the clinic website';

  final igSub =
      igDisplay.isNotEmpty ? '@$igDisplay · Message to book' : 'DM to book';

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x80000000),
    builder: (sheetCtx) {
      final bottomInset = MediaQuery.paddingOf(sheetCtx).bottom;
      Future<void> go(Uri? uri, String label) async {
        Navigator.of(sheetCtx).pop();
        await _tryLaunch(context, uri, errorLabel: label);
      }

      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: Colors.white),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E5E5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A2E),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          _clinicAvatarInitials(clinicName),
                          style: serif.copyWith(
                            fontSize: 17,
                            color: Colors.white,
                            height: 1,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              clinicName,
                              style: serif.copyWith(
                                fontSize: 19,
                                color: const Color(0xFF1A1A1A),
                                height: 1.15,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Wrap(
                              spacing: 5,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (showStars) ...[
                                  Text(
                                    _starsAscii(rVal),
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFFF5C842),
                                      height: 1,
                                    ),
                                  ),
                                  Text(
                                    rVal.toStringAsFixed(1),
                                    style: sf.copyWith(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFF1A1A1A),
                                      height: 1,
                                    ),
                                  ),
                                  Container(
                                    width: 3,
                                    height: 3,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFDDDDDD),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ],
                                if (procLabel != null)
                                  Text(
                                    procLabel,
                                    style: sf.copyWith(
                                      fontSize: 12,
                                      height: 1,
                                      color: const Color(0xFFAAAAAA),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                if (procLabel != null && openLabel != null)
                                  Container(
                                    width: 3,
                                    height: 3,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFDDDDDD),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                if (openLabel != null)
                                  Text(
                                    openLabel,
                                    style: sf.copyWith(
                                      fontSize: 12,
                                      height: 1,
                                      color: isOpenNow == true
                                          ? const Color(0xFF1D9E75)
                                          : const Color(0xFFAAAAAA),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F7F7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        _v2PulseDot(),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            statusText,
                            style: sf.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF1A1A1A),
                              height: 1.25,
                            ),
                          ),
                        ),
                        Text(
                          availTime.isEmpty ? '—' : availTime,
                          style: sf.copyWith(
                            fontSize: 11,
                            color: const Color(0xFFAAAAAA),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Material(
                    color: Colors.white,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Clipboard.setData(
                            ClipboardData(text: phone.trim()));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Number copied')),
                          );
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          border:
                              Border.all(color: const Color(0xFFF0F0F0)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F4FF),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.phone_in_talk_rounded,
                                size: 15,
                                color: const Color(0xFF185FA5),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                phone.trim(),
                                style: sf.copyWith(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF1A1A2E),
                                ),
                              ),
                            ),
                            Text(
                              'Copy',
                              style: sf.copyWith(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFFAAAAAA),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Divider(height: 1, color: Color(0xFFF5F5F5)),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'BOOK VIA',
                    style: sf.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      height: 1,
                      color: const Color(0xFFAAAAAA),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _v2BookingRow(
                        sf: sf,
                        enabled: telUri != null,
                        isDarkCall: true,
                        iconSquareBg: const Color(0xFF1A1A2E),
                        icon: const Icon(
                          Icons.phone_in_talk_rounded,
                          color: Colors.white,
                          size: 21,
                        ),
                        title: 'Call clinic',
                        subtitle: 'Speak directly with the team',
                        onTap: () => go(telUri, 'Phone'),
                      ),
                      const SizedBox(height: 8),
                      _v2BookingRow(
                        sf: sf,
                        enabled: waUri != null,
                        isDarkCall: false,
                        iconSquareBg: const Color(0xFF25D366),
                        icon: const Icon(
                          Icons.chat_rounded,
                          color: Colors.white,
                          size: 21,
                        ),
                        title: 'WhatsApp',
                        subtitle: 'Chat and schedule easily',
                        onTap: () => go(waUri, 'WhatsApp'),
                      ),
                      const SizedBox(height: 8),
                      _v2BookingRow(
                        sf: sf,
                        enabled: siteUri != null,
                        isDarkCall: false,
                        iconSquareBg: const Color(0xFFEFF4FF),
                        icon: const Icon(
                          Icons.public_rounded,
                          color: Color(0xFF185FA5),
                          size: 20,
                        ),
                        title: 'Book on website',
                        subtitle: webSub,
                        onTap: () => go(siteUri, 'Website'),
                      ),
                      const SizedBox(height: 8),
                      _v2BookingRow(
                        sf: sf,
                        enabled: igUri != null,
                        isDarkCall: false,
                        iconSquareBg: const Color(0xFFFFF0F7),
                        icon: const Icon(
                          Icons.camera_alt_outlined,
                          color: Color(0xFFC4607A),
                          size: 20,
                        ),
                        title: 'Instagram DM',
                        subtitle: igSub,
                        onTap: () => go(igUri, 'Instagram'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding:
                      EdgeInsets.fromLTRB(20, 0, 20, bottomInset + 28),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(sheetCtx).pop(),
                    child: Container(
                      width: double.infinity,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F8F8),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'Cancel',
                        style: sf.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFAAAAAA),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
