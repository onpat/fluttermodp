import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/mod_archive_entry.dart';
import '../services/mod_archive_service.dart';

/// Full-screen page that searches Mod Archive and downloads modules
/// directly into the local playlist.
class ModArchiveSearchPage extends StatefulWidget {
  const ModArchiveSearchPage({super.key});

  @override
  State<ModArchiveSearchPage> createState() => _ModArchiveSearchPageState();
}

class _ModArchiveSearchPageState extends State<ModArchiveSearchPage> {
  final _keywordController = TextEditingController();
  String _searchType = 'filename_or_songtitle';

  bool _searching = false;
  String? _searchError;
  List<ModArchiveEntry> _results = const [];

  final Set<int> _downloadingIds = {};
  Directory? _saveDir;

  @override
  void initState() {
    super.initState();
    _initSaveDir();
  }

  Future<void> _initSaveDir() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        // Fallback to app documents directory
        final fallback = await getApplicationDocumentsDirectory();
        _saveDir = Directory('${fallback.path}/modarchive');
        return;
      }
      _saveDir = Directory('${dir.path}/modarchive');
    } catch (_) {
      try {
        final fallback = await getApplicationDocumentsDirectory();
        _saveDir = Directory('${fallback.path}/modarchive');
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }
// ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _performSearch() async {
    final query = _keywordController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _searching = true;
      _searchError = null;
      _results = const [];
    });

    try {
      final results = await ModArchiveService.search(
        query,
        searchType: _searchType,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _searchError = results.isEmpty ? '検索結果がありません。' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _searchError = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _downloadAndAdd(ModArchiveEntry entry) async {
    if (_downloadingIds.contains(entry.moduleId)) return;

    setState(() => _downloadingIds.add(entry.moduleId));

    try {
      Directory saveDir = _saveDir ?? Directory(
        '${(await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory()).path}/modarchive',
      );
      _saveDir = saveDir;

      final filePath = await ModArchiveService.download(
        moduleId: entry.moduleId,
        filename: entry.filename,
        saveDir: saveDir,
      );

      if (!mounted) return;
      await _addTrackToPlaylist(filePath, entry.filename);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('プレイリストに追加: ${entry.filename}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ダウンロード失敗: ${entry.filename}'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _downloadingIds.remove(entry.moduleId));
      }
    }
  }

  Future<void> _addTrackToPlaylist(String uri, String name) async {
    const channel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');
    try {
      await channel.invokeMethod('addTrackToPlaylist', <String, Object?>{
        'uri': uri,
        'name': name,
      });
    } catch (error) {
      debugPrint('[ModArchive] addTrackToPlaylist failed: $error');
      rethrow;
    }
  }
// ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mod Archive 検索'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildSearchBar(theme),
            if (_searchError != null && _results.isEmpty)
              _buildMessage(_searchError!, theme, isError: true)
            else if (!_searching && _results.isEmpty)
              _buildMessage(
                'キーワードを入力して検索してください。',
                theme,
                isHint: true,
              ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            if (_results.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  '${_results.length}件 ヒット',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const Divider(),
              Expanded(child: _buildResultsList(theme)),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-widgets
  // ---------------------------------------------------------------------------

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keywordController,
                  decoration: const InputDecoration(
                    labelText: '検索キーワード',
                    hintText: 'ファイル名、曲名など…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _performSearch(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _searching ? null : _performSearch,
                icon: const Icon(Icons.search),
                label: const Text('検索'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <MapEntry<String, String>>[
                const MapEntry('filename_or_songtitle', 'ファイル名 or 曲名'),
                const MapEntry('filename_and_songtitle', 'ファイル名 and 曲名'),
                const MapEntry('filename', 'ファイル名のみ'),
                const MapEntry('songtitle', '曲名のみ'),
                const MapEntry('module_instruments', 'インストゥルメント'),
                const MapEntry('module_comments', 'コメント'),
              ].map((e) {
                final selected = _searchType == e.key;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(e.value,
                        style: TextStyle(
                            fontSize: 12,
                            color: selected
                                ? null
                                : theme.textTheme.bodySmall?.color)),
                    selected: selected,
                    onSelected: (_) => setState(() => _searchType = e.key),
                    visualDensity: VisualDensity.compact,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
Widget _buildMessage(String text, ThemeData theme,
      {bool isError = false, bool isHint = false}) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: isError
              ? theme.colorScheme.error
              : isHint
                  ? theme.textTheme.bodySmall?.color
                  : null,
        ),
      ),
    );
  }

  Widget _buildResultsList(ThemeData theme) {
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final entry = _results[index];
        final downloading = _downloadingIds.contains(entry.moduleId);

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: _formatBadge(entry.format, theme),
            title: Text(entry.filename,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              entry.title != entry.filename ? entry.title : '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.rating != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star,
                            size: 14, color: Colors.amber.shade700),
                        const SizedBox(width: 2),
                        Text(entry.rating!.toStringAsFixed(1),
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                downloading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        tooltip: 'ダウンロード',
                        icon: const Icon(Icons.download),
                        onPressed: () => _downloadAndAdd(entry),
                      ),
              ],
            ),
            onTap: () => _downloadAndAdd(entry),
          ),
        );
      },
    );
  }

  Widget _formatBadge(String format, ThemeData theme) {
    final color = switch (format.toUpperCase()) {
      'MOD' => Colors.blue,
      'XM' => Colors.teal,
      'IT' => Colors.deepPurple,
      'S3M' => Colors.orange,
      'AHX' => Colors.grey,
      _ => theme.colorScheme.primary,
    };
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withAlpha(120)),
      ),
      alignment: Alignment.center,
      child: Text(
        format.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}