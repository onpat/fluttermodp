import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/amp_entry.dart';

/// Client that searches AMP (amp.dascene.net) for composers and downloads
/// modules. Modules arrive as gzip-compressed files and are decompressed
/// into an author-named sub-directory.
class AmpService {
  AmpService._();
  static const _baseUrl = 'amp.dascene.net';

  // ---------------------------------------------------------------------------
  // Handle search
  // ---------------------------------------------------------------------------

  /// Search for composers by handle name.
  static Future<List<AmpComposer>> searchHandles(String query) async {
    final uri = Uri.https(_baseUrl, '/newresult.php');

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded');
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      request.write(_encodeForm(<String, String>{
        'search': query,
        'request': 'handle',
      }));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'AMP search failed: HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return _parseHandleResults(body);
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Module list
  // ---------------------------------------------------------------------------

  /// Fetch the list of modules for a composer by [viewId].
  static Future<List<AmpModule>> fetchModules(int viewId) async {
    final uri = Uri.https(_baseUrl, '/detail.php', <String, String>{
      'detail': 'modules',
      'view': viewId.toString(),
    });

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'text/html');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'AMP module list failed: HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final body = await response.transform(utf8.decoder).join();
      return _parseModuleList(body);
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  /// Download a module; modules arrive as .gz files and are decompressed.
  /// Saved as [saveDir]/[composerHandle]/[moduleName].[format].
  static Future<String> download({
    required int index,
    required String composerHandle,
    required String moduleName,
    required String format,
    required Directory saveDir,
  }) async {
    final authorDir = Directory('${saveDir.path}/$composerHandle');
    if (!authorDir.existsSync()) {
      authorDir.createSync(recursive: true);
    }

    final ext = format.toLowerCase();
    final filename = '$moduleName.$ext';
    final file = File('${authorDir.path}/$filename');

    final downloadUri =
        Uri.https(_baseUrl, '/downmod.php', <String, String>{
      'index': index.toString(),
    });

    final client = HttpClient();
    try {
      final request = await client.getUrl(downloadUri);
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'AMP download failed: HTTP ${response.statusCode}',
          uri: downloadUri,
        );
      }

      final compressed = <int>[];
      await for (final chunk in response) {
        compressed.addAll(chunk);
      }

      final decompressed = gzip.decode(compressed);
      await file.writeAsBytes(decompressed, flush: true);
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

  static List<AmpComposer> _parseHandleResults(String html) {
    final results = <AmpComposer>[];

    final handleRegExp = RegExp(
      r'<td\s+class="descript">\s*Handle:\s*</td>\s*<td>\s*<a\s+href='
      r'"detail\.php\?view=(\d+)"[^>]*>\s*([^<]+)\s*</a>',
      dotAll: true,
    );

    final realNameRegExp = RegExp(
      r'<td\s+class="descript">\s*Real\s*Name:\s*</td>\s*<td>\s*([^<]+)\s*</td>',
      dotAll: true,
    );

    final countryRegExp = RegExp(
      r'<td\s+class="descript">\s*(?:Lived\s*in|Country):\s*'
      r'</td>\s*<td>(.*?)</td>',
      dotAll: true,
    );

    final groupsRegExp = RegExp(
      r'<td\s+class="descript">\s*(?:Groups|Was\s+a\s+member\s+of):\s*'
      r'</td>\s*<td>\s*(.*?)\s*</td>',
      dotAll: true,
    );

    final handleMatches = handleRegExp.allMatches(html).toList();
    final realNameMatches = realNameRegExp.allMatches(html).toList();
    final countryMatches = countryRegExp.allMatches(html).toList();
    final groupsMatches = groupsRegExp.allMatches(html).toList();

    for (var i = 0; i < handleMatches.length; i++) {
      final hm = handleMatches[i];
      final viewId = int.tryParse(hm.group(1)!) ?? -1;
      final handle = _decodeHtmlEntities((hm.group(2) ?? '').trim());
      if (viewId < 0 || handle.isEmpty) continue;

      final realName = i < realNameMatches.length
          ? _stripTags(_decodeHtmlEntities(
              (realNameMatches[i].group(1) ?? '').trim()))
          : null;

      final country = i < countryMatches.length
          ? _stripTags(_decodeHtmlEntities(
              (countryMatches[i].group(1) ?? '').trim()))
          : null;

      final groups = i < groupsMatches.length
          ? _stripTags(_decodeHtmlEntities(
              (groupsMatches[i].group(1) ?? '').trim()))
          : null;

      results.add(AmpComposer(
        viewId: viewId,
        handle: handle,
        realName: (realName != null && realName.isNotEmpty) ? realName : null,
        country: (country != null && country.isNotEmpty) ? country : null,
        groups: (groups != null && groups.isNotEmpty) ? groups : null,
      ));
    }

    return results;
  }

  static List<AmpModule> _parseModuleList(String html) {
    final results = <AmpModule>[];

    final rowRegExp = RegExp(
      r'<a\s+href="downmod\.php\?index=(\d+)"[^>]*>\s*([^<]*)\s*</a>\s*'
      r'</td>\s*<td>\s*<a\s+href="detail\.php\?view=\d+"[^>]*>\s*'
      r'([^<]*)\s*</a>\s*</td>\s*<td>\s*(\w+)\s*</td>\s*'
      r'<td>\s*([^<]*)\s*</td>',
      dotAll: true,
    );

    for (final match in rowRegExp.allMatches(html)) {
      final index = int.tryParse(match.group(1)!) ?? -1;
      if (index < 0) continue;

      final rawName = (match.group(2) ?? '').trim();
      final name = _decodeHtmlEntities(rawName)
          .replaceAll(RegExp(r'^[\s.&nbsp;]+'), '')
          .trim();
      if (name.isEmpty) continue;

      final composerHandle =
          _decodeHtmlEntities((match.group(3) ?? '').trim());
      final format = (match.group(4) ?? '').trim().toUpperCase();
      final size = (match.group(5) ?? '').trim();

      results.add(AmpModule(
        index: index,
        name: name,
        composerHandle: composerHandle,
        format: format,
        size: size,
      ));
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  static String _encodeForm(Map<String, String> data) {
    return data.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  static String _decodeHtmlEntities(String input) {
    var decoded = input;
    decoded = decoded.replaceAll('&amp;', '&');
    decoded = decoded.replaceAll('&lt;', '<');
    decoded = decoded.replaceAll('&gt;', '>');
    decoded = decoded.replaceAll('&quot;', '"');
    decoded = decoded.replaceAll('&#39;', "'");
    decoded = decoded.replaceAll('&apos;', "'");
    decoded = decoded.replaceAll('&nbsp;', ' ');
    try {
      decoded = Uri.decodeComponent(decoded);
    } catch (_) {}
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

  static String _stripTags(String input) {
    return input
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
