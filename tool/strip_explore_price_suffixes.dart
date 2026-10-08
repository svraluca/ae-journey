/// One-off migration: strip baked-in prices from clinic titles in
/// `explore_google_prices`.
///
/// Dry-run (default — no writes):
///   dart run tool/strip_explore_price_suffixes.dart
///
/// Apply writes:
///   dart run tool/strip_explore_price_suffixes.dart --apply
///
/// Auth: Application Default Credentials.
///   gcloud auth application-default login
///   gcloud config set project aestheticpass-818c6
///
/// Does not bump ExploreGooglePriceStore.revision.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _projectId = 'aestheticpass-818c6';
const _collection = 'explore_google_prices';
const _titleKeys = [
  'brand',
  'procedure_name',
  'procedure',
  'treatment_name',
  'treatment',
];

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final token = await _accessToken();
  if (token.isEmpty) {
    stderr.writeln(
      'No access token. Run: gcloud auth application-default login',
    );
    exitCode = 1;
    return;
  }

  var docsScanned = 0;
  var docsModified = 0;
  var clinicsModified = 0;
  String? pageToken;

  stdout.writeln(
    apply
        ? 'APPLY: writing changed docs in $_collection'
        : 'DRY-RUN: no writes. Pass --apply to update Firestore.',
  );

  do {
    final page = await _listDocuments(token, pageToken);
    pageToken = page.nextPageToken;
    for (final doc in page.documents) {
      docsScanned++;
      final fields = doc['fields'];
      if (fields is! Map) continue;
      final clinicsField = fields['clinics'];
      final values = _arrayValues(clinicsField);
      if (values == null) continue;

      var clinicChanges = 0;
      final nextValues = <Map<String, Object?>>[];
      for (final value in values) {
        final map = _asMapValue(value);
        if (map == null) {
          nextValues.add(Map<String, Object?>.from(value as Map));
          continue;
        }
        final fieldsMap = Map<String, Object?>.from(
          (map['fields'] as Map?)?.cast<String, Object?>() ?? const {},
        );
        var changed = false;
        for (final key in _titleKeys) {
          final current = _stringValue(fieldsMap[key]);
          if (current == null) continue;
          final stripped = stripPriceSuffix(current);
          if (stripped == current) continue;
          fieldsMap[key] = {'stringValue': stripped};
          changed = true;
          stdout.writeln(
            '  ${doc['name']}: $key\n'
            '    - $current\n'
            '    + $stripped',
          );
        }
        if (changed) clinicChanges++;
        nextValues.add({
          'mapValue': {'fields': fieldsMap},
        });
      }

      if (clinicChanges == 0) continue;
      docsModified++;
      clinicsModified += clinicChanges;
      if (!apply) continue;

      final name = '${doc['name']}';
      await _patchClinics(token, name, nextValues);
    }
  } while (pageToken != null && pageToken.isNotEmpty);

  stdout.writeln(
    'Done. docs scanned=$docsScanned, docs modified=$docsModified, '
    'clinic entries modified=$clinicsModified'
    '${apply ? '' : ' (dry-run)'}',
  );
}

/// Same logic as `_stripPriceSuffix` in lib/services/openai_service.dart.
String stripPriceSuffix(String raw) {
  var s = raw.trim();
  final pipeOrDashPrice = RegExp(
    r'\s*[\|\-–—]\s*[£€$]?\s*\d[\d.,]*\s*'
    r'(RON|LEI|EUR|GBP|USD|TRY|PLN|KRW|JPY|BRL|INR|AED|RUB|AUD|€|£|\$)?'
    r'\s*$',
    caseSensitive: false,
  );
  while (true) {
    final next = s.replaceFirst(pipeOrDashPrice, '').trim();
    if (next == s) break;
    s = next;
  }
  final trailingPrice = RegExp(
    r'\s+[£€$]?\s*\d{2,6}[\d.,]*\s*'
    r'(RON|LEI|EUR|GBP|USD|TRY|PLN|KRW|JPY|BRL|INR|AED|RUB|AUD|€|£|\$)\s*$',
    caseSensitive: false,
  );
  return s.replaceFirst(trailingPrice, '').trim();
}

Future<String> _accessToken() async {
  final env = Platform.environment['GOOGLE_ACCESS_TOKEN']?.trim() ?? '';
  if (env.isNotEmpty) return env;
  final result = await Process.run(
    'gcloud',
    ['auth', 'application-default', 'print-access-token'],
  );
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    return '';
  }
  return '${result.stdout}'.trim();
}

class _Page {
  const _Page({required this.documents, this.nextPageToken});
  final List<Map<String, Object?>> documents;
  final String? nextPageToken;
}

Future<_Page> _listDocuments(String token, String? pageToken) async {
  final uri = Uri.https(
    'firestore.googleapis.com',
    '/v1/projects/$_projectId/databases/(default)/documents/$_collection',
    {
      'pageSize': '100',
      if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
    },
  );
  final res = await http.get(
    uri,
    headers: {'Authorization': 'Bearer $token'},
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw StateError('List failed ${res.statusCode}: ${res.body}');
  }
  final json = jsonDecode(res.body) as Map<String, Object?>;
  final raw = json['documents'];
  final docs = <Map<String, Object?>>[
    if (raw is List)
      for (final row in raw)
        if (row is Map) row.cast<String, Object?>(),
  ];
  return _Page(
    documents: docs,
    nextPageToken: json['nextPageToken'] as String?,
  );
}

Future<void> _patchClinics(
  String token,
  String documentName,
  List<Map<String, Object?>> clinicValues,
) async {
  final uri = Uri.parse(
    'https://firestore.googleapis.com/v1/$documentName?updateMask.fieldPaths=clinics',
  );
  final res = await http.patch(
    uri,
    headers: {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'fields': {
        'clinics': {
          'arrayValue': {'values': clinicValues},
        },
      },
    }),
  );
  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw StateError('Patch failed ${res.statusCode}: ${res.body}');
  }
}

List<Object?>? _arrayValues(Object? field) {
  if (field is! Map) return null;
  final array = field['arrayValue'];
  if (array is! Map) return null;
  final values = array['values'];
  if (values is! List) return const [];
  return values;
}

Map<String, Object?>? _asMapValue(Object? value) {
  if (value is! Map) return null;
  final map = value['mapValue'];
  if (map is! Map) return null;
  return map.cast<String, Object?>();
}

String? _stringValue(Object? field) {
  if (field is! Map) return null;
  final v = field['stringValue'];
  if (v is! String) return null;
  return v;
}
