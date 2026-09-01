import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/amp_entry.dart';
import '../services/amp_service.dart';

/// Full-screen page that searches AMP (amp.dascene.net) for composers,
/// lists their modules, and downloads them into composer-named folders.
class AmpSearchPage extends StatefulWidget {
  const AmpSearchPage({super.key});

  @override
  State<AmpSearchPage> createState() => _AmpSearchPageState();
}

class _AmpSearchPageState extends State<AmpSearchPage> {
  final _keywordController = TextEditingController();

  // null = search form, 0 = handle results, 1 = module list
  int? _step;

  // Search state
  bool _searching = false;
  String? _searchError;
  List<AmpComposer> _handles = const [];

  // Module list state
  bool _loadingModules = false;
  String? _moduleError;
  List<AmpModule> _modules = const [];
  AmpComposer? _selectedComposer;

  // Download state
  final Set<int> _downloadingIndices = {};
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
        final fallback = await getApplicationDocumentsDirectory();
        _saveDir = Directory('${fallback.path}/amp');
        return;
      }
      _saveDir = Directory('${dir.path}/amp');
    } catch (_) {
      try {
        final fallback = await getApplicationDocumentsDirectory();
        _saveDir = Directory('${fallback.path}/amp');
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
      _handles = const [];
      _step = null;
    });

    try {
      final results = await AmpService.searchHandles(query);
      if (!mounted) return;
      setState(() {
        _handles = results;
        _step = 0;
        _searchError = results.isEmpty ? 'No composers found.' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _searchError = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openModules(AmpComposer composer) async {
    setState(() {
      _loadingModules = true;
      _moduleError = null;
      _modules = const [];
      _selectedComposer = composer;
    });

    try {
      final modules = await AmpService.fetchModules(composer.viewId);
      if (!mounted) return;
      setState(() {
        _modules = modules;
        _step = 1;
        if (modules.isEmpty) {
          _moduleError = 'No modules found for ${composer.handle}.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _moduleError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingModules = false);
    }
  }

  Future<void> _downloadAndAdd(AmpModule module) async {
    if (_downloadingIndices.contains(module.index)) return;

    setState(() => _downloadingIndices.add(module.index));

    try {
      Directory saveDir = _saveDir ?? Directory(
        '${(await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory()).path}/amp',
      );
      _saveDir = saveDir;

      final filePath = await AmpService.download(
        index: module.index,
        composerHandle: module.composerHandle,
        moduleName: module.name,
        format: module.format,
        saveDir: saveDir,
      );

      if (!mounted) return;
      final name = '${module.name}.${module.format.toLowerCase()}';
      await _addTrackToPlaylist(filePath, name);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added to playlist: ${module.name}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $error'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _downloadingIndices.remove(module.index));
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add track: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _goBack() {
    if (_step == 1) {
      setState(() {
        _step = 0;
        _modules = const [];
        _selectedComposer = null;
        _moduleError = null;
      });
    } else if (_step == 0) {
      setState(() {
        _step = null;
        _handles = const [];
        _searchError = null;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showBack = _step != null;

    return Scaffold(
      appBar: AppBar(
        leading: showBack
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _goBack,
              )
            : null,
        title: Text(_step == 1
            ? _selectedComposer?.handle ?? 'Modules'
            : _step == 0
                ? 'AMP Search Results'
                : 'AMP Search'),
      ),
      body: Column(
        children: [
          _buildSearchBar(theme),
          const Divider(height: 1),
          Expanded(child: _buildContent(theme)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keywordController,
              decoration: InputDecoration(
                hintText: 'Composer handle…',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _keywordController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _keywordController.clear();
                          setState(() {});
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _performSearch(),
            ),
          ),
          const SizedBox(width: 8),
          _searching
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _performSearch,
                ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (_searching || _loadingModules) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_searchError != null && _handles.isEmpty && _modules.isEmpty) {
      return _buildMessage(_searchError!, theme, isError: true);
    }

    if (_moduleError != null && _modules.isEmpty) {
      return _buildMessage(_moduleError!, theme, isError: true);
    }

    if (_step == 1) {
      return _buildModuleList(theme);
    }

    if (_step == 0) {
      return _buildHandleList(theme);
    }

    return _buildMessage('Enter a composer handle to search AMP.', theme,
        isHint: true);
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

  Widget _buildHandleList(ThemeData theme) {
    return ListView.builder(
      itemCount: _handles.length,
      itemBuilder: (context, index) {
        final composer = _handles[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            title: Text(composer.handle,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
              [
                if (composer.realName != null) composer.realName!,
                if (composer.country != null) composer.country!,
              ].join(' \u00b7 '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openModules(composer),
          ),
        );
      },
    );
  }

  Widget _buildModuleList(ThemeData theme) {
    if (_modules.isEmpty) {
      return _buildMessage('No modules found.', theme, isHint: true);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            '${_modules.length} modules',
            style: theme.textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _modules.length,
            itemBuilder: (context, index) {
              final module = _modules[index];
              final downloading =
                  _downloadingIndices.contains(module.index);

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: ListTile(
                  leading: _formatBadge(module.format, theme),
                  title: Text(module.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    module.size,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: downloading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : IconButton(
                          tooltip: 'Download',
                          icon: const Icon(Icons.download),
                          onPressed: () => _downloadAndAdd(module),
                        ),
                  onTap: () => _downloadAndAdd(module),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _formatBadge(String format, ThemeData theme) {
    final color = switch (format.toUpperCase()) {
      'MOD' => Colors.blue,
      'XM' => Colors.teal,
      'IT' => Colors.deepPurple,
      'S3M' => Colors.orange,
      'FST' => Colors.grey,
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