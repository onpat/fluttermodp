import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/mod_archive_entry.dart';

/// Lightweight client that searches Mod Archive and downloads modules.
///
/// Only uses [dart:io] – no third-party HTTP or HTML-parser dependencies.
class ModArchiveService {
  ModArchiveService._();

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Fetch the first page of search results for [query].
  static Future<List<ModArchiveEntry>> search(
    String query, {
    String searchType = 'filename_or_songtitle',
  }) async {
    final uri = Uri.https('modarchive.org', '/index.php', <String, String>{
      'request': 'search',
      'query': query,
      'search_type': searchType,
      'submit': 'Find',
    });

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Search failed: HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return _parseSearchResults(body);
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Download a module and save it as [saveDir]/[filename].
  /// Returns the absolute path of the saved file.
  static Future<String> download({
    required int moduleId,
    required String filename,
    required Directory saveDir,
  }) async {
    if (!saveDir.existsSync()) {
      saveDir.createSync(recursive: true);
    }

    final downloadUri =
        Uri.https('api.modarchive.org', '/downloads.php', <String, String>{
      'moduleid': moduleId.toString(),
    });

    final file = File('${saveDir.path}/$filename');
    final client = HttpClient();

    try {
      final request = await client.getUrl(downloadUri);
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Download failed: HTTP ${response.statusCode}',
          uri: downloadUri,
        );
      }

      final sink = file.openWrite();
      try {
        await response.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }

    if (!file.existsSync() || file.lengthSync() == 0) {
      throw FileSystemException(
        'Downloaded file is empty or missing',
        file.path,
      );
    }

    return file.absolute.path;
  }

  // ---------------------------------------------------------------------------
  // HTML parsing (internal)
  // ---------------------------------------------------------------------------

  static List<ModArchiveEntry> _parseSearchResults(String html) {
    final results = <ModArchiveEntry>[];

    final rowRegExp = RegExp(r'<tr>\s*(.*?)\s*</tr>', dotAll: true);
    final downloadRegExp = RegExp(r'downloads\.php\?moduleid=(\d+)');
    final filenameRegExp =
        RegExp(r'<a\s[^>]*class="standard-link"[^>]*>(.*?)</a>', dotAll: true);
    final titleRegExp =
        RegExp(r'<span\s+class="module-listing">\s*\n(.*?)\n', dotAll: true);
    final formatRegExp = RegExp(r'<span\s+class="format-icon">(\w+)</span>');
    final ratingRegExp = RegExp(r'Rated\s*</a>\s*(\d+(?:\.\d+)?)\s*/\s*10');
    final disabledRegExp = RegExp(r'control_play_disabled');

    for (final match in rowRegExp.allMatches(html)) {
      final row = match.group(1) ?? '';
      final d = downloadRegExp.firstMatch(row);
      if (d == null) continue;
      final moduleId = int.tryParse(d.group(1)!) ?? -1;
      if (moduleId < 0) continue;

      final fn = filenameRegExp.firstMatch(row);
      final rawFilename = fn?.group(1)?.trim() ?? '';
      final filename = _decodeHtmlEntities(rawFilename);

      final t = titleRegExp.firstMatch(row);
      final rawTitle = t?.group(1)?.trim() ?? filename;
      final title = _decodeHtmlEntities(rawTitle);

      final fm = formatRegExp.firstMatch(row);
      final format = fm?.group(1) ?? '';

      final r = ratingRegExp.firstMatch(row);
      final double? rating =
          r != null ? double.tryParse(r.group(1)!) : null;

      final isPlayable = !disabledRegExp.hasMatch(row);
      final fragment = filename.isNotEmpty ? '#$filename' : '';
      final downloadUrl =
          'https://api.modarchive.org/downloads.php?moduleid=$moduleId$fragment';

      results.add(ModArchiveEntry(
        moduleId: moduleId,
        filename: filename,
        title: title,
        format: format,
        downloadUrl: downloadUrl,
        rating: rating,
        isPlayable: isPlayable,
      ));
    }

    return results;
  }

  /// Decode URL-encoded and HTML-entity-encoded strings found in search results.
  static String _decodeHtmlEntities(String input) {
    var decoded = input;
    // Decode common HTML entities
    decoded = decoded.replaceAll('&amp;', '&');
    decoded = decoded.replaceAll('&lt;', '<');
    decoded = decoded.replaceAll('&gt;', '>');
    decoded = decoded.replaceAll('&quot;', '"');
    decoded = decoded.replaceAll('&#39;', "'");
    decoded = decoded.replaceAll('&apos;', "'");
    // Decode URL percent-encoding (e.g. %20 -> space, %E3%81%82 -> あ)
    try {
      decoded = Uri.decodeComponent(decoded);
    } catch (_) {
      // Keep the original if decoding fails
    }
    // Also decode numeric HTML entities like &#x3042; or &#12354;
    decoded = decoded.replaceAllMapped(
      RegExp(r'&#x([0-9A-Fa-f]+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
    decoded = decoded.replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!)),
    );
    return decoded;
  }
}