import 'dart:async';
import 'package:http/http.dart' as http;

/// Retrying queue acceptance is safe: the server coalesces active market jobs.
/// Keep the exact payload/focus sequence; a late retry must not steal focus.
Future<http.Response?> postExploreDiscoveryJobWithRetry({
  required http.Client client,
  required Uri uri,
  required String body,
  required bool Function() isCurrent,
  Duration timeout = const Duration(seconds: 8),
  Duration retryDelay = const Duration(milliseconds: 400),
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    if (!isCurrent()) return null;
    try {
      final response = await client.post(uri,
        headers: const {'Content-Type': 'application/json'}, body: body,
      ).timeout(timeout);
      if (!isCurrent()) return null;
      if (response.statusCode != 502 && response.statusCode != 503 &&
          response.statusCode != 504) return response;
      if (attempt == 1) return response;
    } on TimeoutException {
      if (attempt == 1) rethrow;
    } on http.ClientException {
      if (attempt == 1) rethrow;
    }
    await Future<void>.delayed(retryDelay);
  }
  return null;
}
