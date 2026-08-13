import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Imported to keep the background HTTP server entrypoint reachable by the
// Dart compiler (tree-shaking). It is started from the Kotlin service via
// FlutterEngine.executeDartEntrypoint("httpServerEntrypoint").
import 'remote/http_server.dart' as remote;

const _openMptChannel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');

/// Root-library entrypoint started by [PlaybackService] via
/// `FlutterEngine.executeDartEntrypoint("httpServerEntrypoint")`.
///
/// The Flutter engine resolves non-`main` entrypoints only in the root
/// library (the file containing `main()`), so this wrapper must live here
/// rather than in `lib/remote/http_server.dart`.
@pragma('vm:entry-point')
void httpServerEntrypoint() {
  remote.httpServerEntrypoint();
}

class _InitializationResult {
  const _InitializationResult({required this.success, required this.message});

  final bool success;
  final String message;
}

class PlaylistEntry {
  const PlaylistEntry({required this.uri, required this.name});

  final String uri;
  final String name;

  factory PlaylistEntry.fromMap(Map<Object?, Object?> map) => PlaylistEntry(
    uri: map['uri'] as String? ?? '',
    name: map['name'] as String? ?? '名称不明',
  );
}

class PlaylistState {
  const PlaylistState({
    this.entries = const [],
    this.currentIndex = -1,
    this.repeatOne = false,
    this.repeatPlaylist = false,
    this.isPlaying = false,
    this.isPaused = false,
    this.status = 'プレイリストを読み込んでいます…',
    this.httpServerRunning = false,
    this.httpServerPort = 0,
    this.httpServerAddress,
  });

  final List<PlaylistEntry> entries;
  final int currentIndex;
  final bool repeatOne;
  final bool repeatPlaylist;
  final bool isPlaying;
  final bool isPaused;
  final String status;
  final bool httpServerRunning;
  final int httpServerPort;
  final String? httpServerAddress;

  factory PlaylistState.fromMap(Map<Object?, Object?> map) {
    final rawEntries = map['entries'] as List<Object?>? ?? const [];
    return PlaylistState(
      entries: rawEntries
          .whereType<Map<Object?, Object?>>()
          .map(PlaylistEntry.fromMap)
          .toList(growable: false),
      currentIndex: (map['currentIndex'] as num?)?.toInt() ?? -1,
      repeatOne: map['repeatOne'] == true,
      repeatPlaylist: map['repeatPlaylist'] == true,
      isPlaying: map['isPlaying'] == true,
      isPaused: map['isPaused'] == true,
      status: map['status'] as String? ?? '状態を取得できません。',
      httpServerRunning: map['httpServerRunning'] == true,
      httpServerPort: (map['httpServerPort'] as num?)?.toInt() ?? 0,
      httpServerAddress: map['httpServerAddress'] as String?,
    );
  }
}

Future<_InitializationResult> _initializeOpenMpt() async {
  try {
    final result = await _openMptChannel.invokeMapMethod<String, Object?>(
      'initialize',
    );
    final success = result?['success'] == true;
    final message =
        result?['message'] as String? ?? 'No native result returned.';
    debugPrint('[libopenmpt] ${success ? 'SUCCESS' : 'ERROR'}: $message');
    return _InitializationResult(success: success, message: message);
  } on PlatformException catch (error) {
    return _InitializationResult(
      success: false,
      message: 'Platform initialization failed: ${error.message}',
    );
  } catch (error, stackTrace) {
    debugPrintStack(stackTrace: stackTrace);
    return _InitializationResult(
      success: false,
      message: 'Unexpected initialization failure: $error',
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialization = await _initializeOpenMpt();
  runApp(FlutterModp(initializationMessage: initialization.message));
}

class FlutterModp extends StatelessWidget {
  const FlutterModp({
    super.key,
    this.initializationMessage = 'libopenmpt has not been initialized.',
  });

  final String initializationMessage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter MOD Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: MyHomePage(
        title: 'Flutter MOD Player',
        initializationMessage: initializationMessage,
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    required this.initializationMessage,
  });

  final String title;
  final String initializationMessage;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  PlaylistState _playlist = const PlaylistState();
  Timer? _stateTimer;
  bool _busy = false;
  bool _refreshing = false;
  String? _operationMessage;
  late final TextEditingController _httpPortController;

  @override
  void initState() {
    super.initState();
    _httpPortController = TextEditingController(text: '8080');
    _refreshState();
    _stateTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => _refreshState(quiet: true),
    );
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _httpPortController.dispose();
    super.dispose();
  }

  int get _httpPort {
    final value = int.tryParse(_httpPortController.text.trim());
    return (value != null && value > 0 && value < 65536) ? value : 8080;
  }

  Future<void> _refreshState({bool quiet = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final result = await _openMptChannel.invokeMapMethod<Object?, Object?>(
        'getPlaylist',
      );
      if (mounted && result != null) {
        setState(() => _playlist = PlaylistState.fromMap(result));
      }
    } on MissingPluginException {
      if (mounted && !quiet) {
        setState(() => _operationMessage = 'Android端末で実行してください。');
      }
    } on PlatformException catch (error) {
      if (mounted && !quiet) {
        setState(() => _operationMessage = error.message ?? error.code);
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _invoke(
    String method, {
    Map<String, Object?>? arguments,
    bool showBusy = false,
  }) async {
    if (_busy) return;
    setState(() {
      if (showBusy) _busy = true;
      _operationMessage = null;
    });
    try {
      final result = await _openMptChannel.invokeMethod<Object?>(
        method,
        arguments,
      );
      if (!mounted) return;
      if (result is Map && result['message'] is String) {
        setState(() => _operationMessage = result['message'] as String);
      }
      await _refreshState();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _operationMessage = error.message ?? error.code);
      }
    } finally {
      if (mounted && showBusy) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClear() async {
    if (_playlist.entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('プレイリストを空にしますか？'),
        content: const Text('再生中の場合は停止します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('空にする'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _invoke('clearPlaylist');
  }

  @override
  Widget build(BuildContext context) {
    final hasTracks = _playlist.entries.isNotEmpty;
    final currentIsActive = _playlist.isPlaying || _playlist.isPaused;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                children: [
                  Text(
                    _playlist.status,
                    key: const ValueKey('playbackStatus'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (_operationMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _operationMessage!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: '前の曲',
                  onPressed: hasTracks ? () => _invoke('previous') : null,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton.filled(
                  tooltip: _playlist.isPlaying ? '一時停止' : '再生',
                  onPressed: hasTracks
                      ? () => _invoke(_playlist.isPlaying ? 'pause' : 'play')
                      : null,
                  icon: Icon(
                    _playlist.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
                IconButton(
                  tooltip: '停止',
                  onPressed: currentIsActive ? () => _invoke('stop') : null,
                  icon: const Icon(Icons.stop),
                ),
                IconButton(
                  tooltip: '次の曲',
                  onPressed: hasTracks ? () => _invoke('next') : null,
                  icon: const Icon(Icons.skip_next),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    dense: true,
                    title: const Text('1曲リピート'),
                    value: _playlist.repeatOne,
                    onChanged: (enabled) => _invoke(
                      'setRepeatOne',
                      arguments: {'enabled': enabled},
                    ),
                  ),
                ),
                Expanded(
                  child: SwitchListTile(
                    dense: true,
                    title: const Text('全曲リピート'),
                    value: _playlist.repeatPlaylist,
                    onChanged: (enabled) => _invoke(
                      'setRepeatPlaylist',
                      arguments: {'enabled': enabled},
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('HTTPリモコン'),
                        subtitle: Text(
                          _playlist.httpServerRunning
                              ? '${_playlist.httpServerAddress ?? '0.0.0.0'}:${_playlist.httpServerPort}'
                              : '再生・プレイリストを遠隔操作できます',
                        ),
                        value: _playlist.httpServerRunning,
                        onChanged: (enabled) async {
                          if (enabled) {
                            await _invoke(
                              'startHttpServer',
                              arguments: {'port': _httpPort},
                            );
                          } else {
                            await _invoke('stopHttpServer');
                          }
                        },
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _httpPortController,
                              keyboardType: TextInputType.number,
                              enabled: !_playlist.httpServerRunning,
                              decoration: const InputDecoration(
                                labelText: 'ポート',
                                hintText: '8080',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke('pickFiles', showBusy: true),
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('曲を追加'),
                  ),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke('loadPlaylist', showBusy: true),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('m3u読込'),
                  ),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _invoke('savePlaylist', showBusy: true),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('m3u保存'),
                  ),
                  TextButton.icon(
                    onPressed: hasTracks && !_busy ? _confirmClear : null,
                    icon: const Icon(Icons.clear_all),
                    label: const Text('クリア'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: hasTracks
                  ? ListView.builder(
                      itemCount: _playlist.entries.length,
                      itemBuilder: (context, index) {
                        final entry = _playlist.entries[index];
                        final isCurrent = index == _playlist.currentIndex;
                        return ListTile(
                          selected: isCurrent,
                          leading: SizedBox(
                            width: 32,
                            child: isCurrent && currentIsActive
                                ? Icon(
                                    _playlist.isPlaying
                                        ? Icons.graphic_eq
                                        : Icons.pause,
                                  )
                                : Text('${index + 1}'),
                          ),
                          title: Text(
                            entry.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            entry.uri,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '削除',
                            onPressed: () => _invoke(
                              'removeTrack',
                              arguments: {'index': index},
                            ),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                          onTap: () =>
                              _invoke('playIndex', arguments: {'index': index}),
                        );
                      },
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'プレイリストは空です。\n「曲を追加」または「m3u読込」から追加してください。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                widget.initializationMessage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
