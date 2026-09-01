/// A composer/handle result parsed from AMP handle search results.
class AmpComposer {
  const AmpComposer({
    required this.viewId,
    required this.handle,
    this.realName,
    this.country,
    this.groups,
  });

  /// Numeric composer identifier used for the detail endpoint.
  final int viewId;

  /// Handle name (e.g. "Maf").
  final String handle;

  /// Real name if known (e.g. "Benoît Charcosset").
  final String? realName;

  /// Country name if known (e.g. "France").
  final String? country;

  /// Comma-separated group names if known.
  final String? groups;

  @override
  String toString() =>
      'AmpComposer(id=$viewId, "$handle"${realName != null ? ", $realName" : ""})';
}

/// A single module row parsed from the AMP composer's module list.
class AmpModule {
  const AmpModule({
    required this.index,
    required this.name,
    required this.composerHandle,
    required this.format,
    required this.size,
  });

  /// Numeric module index used by the download endpoint (downmod.php?index=...).
  final int index;

  /// Module name (e.g. "smirk").
  final String name;

  /// Handle of the composer (e.g. "Maf").
  final String composerHandle;

  /// Short format tag (e.g. "MOD", "XM", "FST").
  final String format;

  /// Display size string (e.g. "21Kb").
  final String size;

  @override
  String toString() =>
      'AmpModule(index=$index, "$name", $format, $size)';
}