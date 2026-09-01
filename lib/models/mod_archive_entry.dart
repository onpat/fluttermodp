/// A single result row parsed from the Mod Archive search-results HTML.
class ModArchiveEntry {
  const ModArchiveEntry({
    required this.moduleId,
    required this.filename,
    required this.title,
    required this.format,
    required this.downloadUrl,
    this.rating,
    required this.isPlayable,
  });

  /// Numeric module identifier used by the download endpoint.
  final int moduleId;

  /// The file name displayed on Mod Archive (e.g. "85206-tester.mod").
  final String filename;

  /// The song / module title (e.g. "tester1-cw").
  final String title;

  /// Short format tag (e.g. "MOD", "XM", "IT", "AHX", …).
  final String format;

  /// Full download URL on the API subdomain.
  final String downloadUrl;

  /// Rating out of 10, when available.
  final double? rating;

  /// `true` when the online player can play this module.
  final bool isPlayable;

  @override
  String toString() =>
      'ModArchiveEntry(id=$moduleId, "$filename", $format${rating != null ? ", rating=$rating/10" : ""})';
}