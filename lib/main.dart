import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Imported to keep the background HTTP server entrypoint reachable by the
// Dart compiler (tree-shaking). It is started from the Kotlin service via
// FlutterEngine.executeDartEntrypoint("httpServerEntrypoint").
import 'remote/http_server.dart' as remote;

import 'pages/mod_archive_search_page.dart';
import 'pages/amp_search_page.dart';
import 'services/download_dir_store.dart';
import 'widgets/directory_picker_dialog.dart';

const _openMptChannel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');

const _interpolationLabels = <int, String>{
  0: '内部デフォルト',
  1: '補間なし',
  2: '線形補間',
  4: '3次補間 (cubic)',
  8: '8-tap windowed sinc',
};

const _sampleRates = <int>[44100, 48000, 88200, 96000, 192000];

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
    this.positionMs = 0,
    this.durationMs = 0,
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
  final int positionMs;
  final int durationMs;

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
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class RenderSettings {
  const RenderSettings({
    this.interpolationFilterLength = 0,
    this.sampleRate = 48000,
    this.floatOutput = true,
    this.volumeRampingStrength = -1,
    this.tempoFactor = 1.0,
    this.pitchFactor = 1.0,
    this.playAtEnd = 'fadeout',
    this.oplVolumeFactor = 1.0,
    this.emulateAmiga = false,
    this.emulateAmigaType = 'auto',
    this.dither = 1,
  });

  final int interpolationFilterLength;
  final int sampleRate;
  final bool floatOutput;
  final int volumeRampingStrength;
  final double tempoFactor;
  final double pitchFactor;
  final String playAtEnd;
  final double oplVolumeFactor;
  final bool emulateAmiga;
  final String emulateAmigaType;
  final int dither;

  factory RenderSettings.fromMap(Map<Object?, Object?> map) => RenderSettings(
    interpolationFilterLength: (map['interpolationFilterLength'] as num?)?.toInt() ?? 0,
    sampleRate: (map['sampleRate'] as num?)?.toInt() ?? 48000,
    floatOutput: map['floatOutput'] as bool? ?? true,
    volumeRampingStrength: (map['volumeRampingStrength'] as num?)?.toInt() ?? -1,
    tempoFactor: (map['tempoFactor'] as num?)?.toDouble() ?? 1.0,
    pitchFactor: (map['pitchFactor'] as num?)?.toDouble() ?? 1.0,
    playAtEnd: map['playAtEnd'] as String? ?? 'fadeout',
    oplVolumeFactor: (map['oplVolumeFactor'] as num?)?.toDouble() ?? 1.0,
    emulateAmiga: map['emulateAmiga'] as bool? ?? false,
    emulateAmigaType: map['emulateAmigaType'] as String? ?? 'auto',
    dither: (map['dither'] as num?)?.toInt() ?? 1,
  );

  RenderSettings copyWith({
    int? interpolationFilterLength,
    int? sampleRate,
    bool? floatOutput,
    int? volumeRampingStrength,
    double? tempoFactor,
    double? pitchFactor,
    String? playAtEnd,
    double? oplVolumeFactor,
    bool? emulateAmiga,
    String? emulateAmigaType,
    int? dither,
  }) => RenderSettings(
    interpolationFilterLength: interpolationFilterLength ?? this.interpolationFilterLength,
    sampleRate: sampleRate ?? this.sampleRate,
    floatOutput: floatOutput ?? this.floatOutput,
    volumeRampingStrength: volumeRampingStrength ?? this.volumeRampingStrength,
    tempoFactor: tempoFactor ?? this.tempoFactor,
    pitchFactor: pitchFactor ?? this.pitchFactor,
    playAtEnd: playAtEnd ?? this.playAtEnd,
    oplVolumeFactor: oplVolumeFactor ?? this.oplVolumeFactor,
    emulateAmiga: emulateAmiga ?? this.emulateAmiga,
    emulateAmigaType: emulateAmigaType ?? this.emulateAmigaType,
    dither: dither ?? this.dither,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'interpolationFilterLength': interpolationFilterLength,
    'sampleRate': sampleRate,
    'floatOutput': floatOutput,
    'volumeRampingStrength': volumeRampingStrength,
    'tempoFactor': tempoFactor,
    'pitchFactor': pitchFactor,
    'playAtEnd': playAtEnd,
    'oplVolumeFactor': oplVolumeFactor,
    'emulateAmiga': emulateAmiga,
    'emulateAmigaType': emulateAmigaType,
    'dither': dither,
  };
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
  RenderSettings _renderSettings = const RenderSettings();
  Timer? _stateTimer;
  bool _busy = false;
  bool _refreshing = false;
  String? _operationMessage;

  /// シークバーをドラッグ中の値（秒）。ドラッグ中はポーリング更新に
  /// 干渉されないように、この値を優先して表示する。
  double? _seekDragValue;

  @override
  void initState() {
    super.initState();
    _refreshState();
    _loadRenderSettings();
    _stateTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => _refreshState(quiet: true),
    );
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    super.dispose();
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

  Future<void> _loadRenderSettings() async {
    try {
      final result = await _openMptChannel.invokeMapMethod<Object?, Object?>(
        'getRenderSettings',
      );
      if (mounted && result != null) {
        setState(() => _renderSettings = RenderSettings.fromMap(result));
      }
    } on MissingPluginException {
      // Non-Android platforms keep the defaults.
    } on PlatformException {
      // Keep the defaults if the native side is unavailable.
    }
  }

  Future<void> _updateRenderSettings(RenderSettings settings) async {
    setState(() => _renderSettings = settings);
    try {
      final result = await _openMptChannel.invokeMapMethod<Object?, Object?>(
        'setRenderSettings',
        settings.toMap(),
      );
      if (mounted && result != null) {
        setState(() => _renderSettings = RenderSettings.fromMap(result));
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _operationMessage = error.message ?? error.code);
      }
    }
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _RenderSettingsSheet(
        settings: _renderSettings,
        onChanged: _updateRenderSettings,
      ),
    );
  }

  /// ミリ秒を「m:ss」形式の文字列へ変換する。
  String _formatDuration(int milliseconds) {
    final totalSeconds =
        milliseconds <= 0 ? 0 : milliseconds ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// 「再生中」表示の下に置くシークバー。
  ///
  /// 再生中または一時停止中で曲の長さが判明しているときのみ操作可能。
  /// ドラッグ中は [_seekDragValue] を表示し、指を離した時点でネイティブ側へ
  /// シーク要求を送る。
  Widget _buildSeekBar() {
    final playlist = _playlist;
    final seekable = (playlist.isPlaying || playlist.isPaused) &&
        playlist.durationMs > 0;
    // Slider は max が 0 だと描画できないため、無効時は仮の幅を使う。
    final durationSeconds = seekable ? playlist.durationMs / 1000.0 : 1.0;
    final positionSeconds = playlist.positionMs / 1000.0;
    final value = (_seekDragValue ?? positionSeconds).clamp(0.0, durationSeconds);

    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            _formatDuration((value * 1000).round()),
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('seekBar'),
            value: value,
            max: durationSeconds,
            onChanged: seekable
                ? (newValue) => setState(() => _seekDragValue = newValue)
                : null,
            onChangeEnd: seekable
                ? (newValue) {
                    setState(() => _seekDragValue = null);
                    _invoke(
                      'seek',
                      arguments: {'positionMs': (newValue * 1000).round()},
                    );
                  }
                : null,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            _formatDuration(seekable ? playlist.durationMs : 0),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasTracks = _playlist.entries.isNotEmpty;
    final currentIsActive = _playlist.isPlaying || _playlist.isPaused;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '再生設定',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
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
                  const SizedBox(height: 4),
                  _buildSeekBar(),
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
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const ModArchiveSearchPage()),
                            );
                            await _refreshState();
                          },
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Mod Archive'),
                  ),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) =>
                                      const AmpSearchPage()),
                            );
                            await _refreshState();
                          },
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('AMP'),
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
class _RenderSettingsSheet extends StatefulWidget {
  const _RenderSettingsSheet({required this.settings, required this.onChanged});

  final RenderSettings settings;
  final ValueChanged<RenderSettings> onChanged;

  @override
  State<_RenderSettingsSheet> createState() => _RenderSettingsSheetState();
}

class _RenderSettingsSheetState extends State<_RenderSettingsSheet> {
  late RenderSettings _settings = widget.settings;

  /// 値が 1.00 の近傍にあるとき、正確に 1.00 へ吸着させる許容幅。
  static const double _snapTolerance = 0.04;

  /// テンポ倍率とピッチ倍率を連動して変更するかどうか。
  bool _linkTempoPitch = true;

  /// AMP / Mod Archive 共通のダウンロード先ディレクトリ。
  Directory? _downloadDir;
  bool _downloadDirLoading = true;

  /// リピート再生と HTTPリモコンの現在状態。
  PlaylistState _playlist = const PlaylistState();
  Timer? _stateTimer;
  bool _refreshing = false;
  String? _operationMessage;
  late final TextEditingController _httpPortController;

  @override
  void initState() {
    super.initState();
    _httpPortController = TextEditingController(text: '8080');
    _loadDownloadDir();
    _refreshState();
    _stateTimer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => _refreshState(),
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

  /// メイン画面と同様に、再生状態を取得して表示を最新化する。
  Future<void> _refreshState() async {
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
      // 非 Android 環境では既定値のまま表示する。
    } on PlatformException {
      // 取得に失敗したときは現在の表示を維持する。
    } finally {
      _refreshing = false;
    }
  }

  /// リピート再生と HTTPリモコンの操作をネイティブ側へ渡し、状態を更新する。
  Future<void> _invokePlayer(
    String method, {
    Map<String, Object?>? arguments,
  }) async {
    if (mounted) setState(() => _operationMessage = null);
    try {
      await _openMptChannel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      if (mounted) {
        setState(() => _operationMessage = 'Android端末で実行してください。');
      }
      return;
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _operationMessage = error.message ?? error.code);
      }
      return;
    }
    await _refreshState();
  }

  Future<void> _loadDownloadDir() async {
    try {
      final dir = await DownloadDirStore.instance.load();
      if (!mounted) return;
      setState(() {
        _downloadDir = dir;
        _downloadDirLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _downloadDirLoading = false);
    }
  }

  Future<void> _pickDownloadDir() async {
    final store = DownloadDirStore.instance;
    final hasAccess = await store.hasAccess();
    if (!hasAccess) {
      if (!mounted) return;
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ストレージへのアクセス許可'),
          content: const Text(
            '共有ストレージ（Documents など）へ保存するには、'
            '「すべてのファイルへのアクセス」を許可する必要があります。\n'
            'システム設定画面を開きますか？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('設定を開く'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await store.requestAccess();
      }
      return;
    }
    if (!mounted) return;
    final initial = _downloadDir;
    if (initial == null) return;
    final root = await store.pickerRoot();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => DirectoryPickerDialog(
        initialDir: initial,
        rootDir: root,
      ),
    );
    if (picked == null || picked.isEmpty) return;
    await store.set(Directory(picked));
    if (!mounted) return;
    setState(() => _downloadDir = Directory(picked));
  }

  Future<void> _resetDownloadDir() async {
    try {
      final dir = await DownloadDirStore.instance.resetToDefault();
      if (!mounted) return;
      setState(() => _downloadDir = dir);
    } catch (_) {}
  }

  /// [value] が 1.00 に十分近い場合は 1.00 に吸着させ、それ以外はそのまま返す。
  double _snapToUnit(double value) {
    const unit = 1.0;
    return (value - unit).abs() <= _snapTolerance ? unit : value;
  }

  void _apply(RenderSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.85,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('再生設定', style: theme.textTheme.titleLarge),
                    ),
                    IconButton(
                      tooltip: '閉じる',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (_operationMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    _operationMessage!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _sectionTitle('リピート再生'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('1曲リピート'),
                      value: _playlist.repeatOne,
                      onChanged: (enabled) => _invokePlayer(
                        'setRepeatOne',
                        arguments: {'enabled': enabled},
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('全曲リピート'),
                      value: _playlist.repeatPlaylist,
                      onChanged: (enabled) => _invokePlayer(
                        'setRepeatPlaylist',
                        arguments: {'enabled': enabled},
                      ),
                    ),
                    _sectionTitle('リモコン'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('HTTPリモコン'),
                      subtitle: Text(
                        _playlist.httpServerRunning
                            ? '${_playlist.httpServerAddress ?? '0.0.0.0'}:${_playlist.httpServerPort}'
                            : '再生・プレイリストを遠隔操作できます',
                      ),
                      value: _playlist.httpServerRunning,
                      onChanged: (enabled) => _invokePlayer(
                        enabled ? 'startHttpServer' : 'stopHttpServer',
                        arguments: enabled ? {'port': _httpPort} : null,
                      ),
                    ),
                    TextField(
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
                    const SizedBox(height: 8),
                    _sectionTitle('ダウンロード'),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('保存先フォルダ'),
                      subtitle: Text(
                        _downloadDirLoading
                            ? '読み込み中…'
                            : _downloadDir?.path ?? '-',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'フォルダを選択',
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickDownloadDir,
                      ),
                    ),
                    Text(
                      'AMP / Mod Archive からダウンロードしたモジュールの保存先です。'
                      '初期値は Documents/mods です。',
                      style: theme.textTheme.labelSmall,
                    ),
                    TextButton.icon(
                      onPressed:
                          _downloadDirLoading ? null : _resetDownloadDir,
                      icon: const Icon(Icons.restore),
                      label: const Text('初期値 (Documents/mods) に戻す'),
                    ),
                    _sectionTitle('サンプリング'),
                    _dropdown<int>(
                      label: '補間方法',
                      value: _settings.interpolationFilterLength,
                      items: _interpolationLabels,
                      onChanged: (v) => _apply(
                        _settings.copyWith(interpolationFilterLength: v!),
                      ),
                    ),
                    _dropdown<int>(
                      label: 'サンプリングレート',
                      value: _settings.sampleRate,
                      items: {for (final r in _sampleRates) r: '$r Hz'},
                      onChanged: (v) => _apply(
                        _settings.copyWith(sampleRate: v!),
                      ),
                    ),
                    _dropdown<bool>(
                      label: '出力ビット数',
                      value: _settings.floatOutput,
                      items: const {true: '32bit Float', false: '16bit PCM'},
                      onChanged: (v) => _apply(
                        _settings.copyWith(floatOutput: v!),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'サンプリングレートとビット数の変更は、次の再生開始時に反映されます。',
                      style: theme.textTheme.labelSmall,
                    ),
                    _sectionTitle('レンダラー'),
                    _slider(
                      label: 'ボリュームランプ',
                      display: _settings.volumeRampingStrength < 0
                          ? 'デフォルト'
                          : '${_settings.volumeRampingStrength}',
                      value: _settings.volumeRampingStrength.toDouble(),
                      min: -1,
                      max: 10,
                      divisions: 11,
                      onChanged: (v) => _apply(
                        _settings.copyWith(volumeRampingStrength: v.round()),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('テンポとピッチを連動'),
                      value: _linkTempoPitch,
                      onChanged: (v) => setState(() => _linkTempoPitch = v),
                    ),
                    _slider(
                      label: 'テンポ倍率',
                      display: _settings.tempoFactor.toStringAsFixed(2),
                      value: _settings.tempoFactor,
                      min: 0.25,
                      max: 2.0,
                      onChanged: (v) {
                        final snapped = _snapToUnit(v);
                        _apply(
                          _linkTempoPitch
                              ? _settings.copyWith(
                                  tempoFactor: snapped,
                                  pitchFactor: snapped,
                                )
                              : _settings.copyWith(tempoFactor: snapped),
                        );
                      },
                    ),
                    _slider(
                      label: 'ピッチ倍率',
                      display: _settings.pitchFactor.toStringAsFixed(2),
                      value: _settings.pitchFactor,
                      min: 0.25,
                      max: 2.0,
                      onChanged: (v) {
                        final snapped = _snapToUnit(v);
                        _apply(
                          _linkTempoPitch
                              ? _settings.copyWith(
                                  tempoFactor: snapped,
                                  pitchFactor: snapped,
                                )
                              : _settings.copyWith(pitchFactor: snapped),
                        );
                      },
                    ),
                    _slider(
                      label: 'OPL音源の音量',
                      display: _settings.oplVolumeFactor.toStringAsFixed(2),
                      value: _settings.oplVolumeFactor,
                      min: 0.0,
                      max: 2.0,
                      onChanged: (v) => _apply(
                        _settings.copyWith(oplVolumeFactor: _snapToUnit(v)),
                      ),
                    ),
                    _dropdown<String>(
                      label: '曲終端時の動作',
                      value: _settings.playAtEnd,
                      items: const {
                        'fadeout': 'フェードアウト',
                        'continue': 'ループ継続',
                        'stop': '停止',
                      },
                      onChanged: (v) => _apply(
                        _settings.copyWith(playAtEnd: v!),
                      ),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Amiga リサンプラをエミュレート'),
                      value: _settings.emulateAmiga,
                      onChanged: (v) => _apply(_settings.copyWith(emulateAmiga: v)),
                    ),
                    _dropdown<String>(
                      label: 'Amiga フィルタ種別',
                      value: _settings.emulateAmigaType,
                      items: const {
                        'auto': '自動',
                        'a500': 'A500',
                        'a1200': 'A1200',
                        'unfiltered': 'フィルタなし',
                      },
                      onChanged: _settings.emulateAmiga
                          ? (v) => _apply(
                              _settings.copyWith(emulateAmigaType: v!),
                            )
                          : null,
                    ),
                    _dropdown<int>(
                      label: 'ディザ (16bit出力時のみ)',
                      value: _settings.dither,
                      items: const {
                        0: 'なし',
                        1: 'デフォルト',
                        2: 'Rectangular',
                        3: 'ノイズシェーピング',
                      },
                      onChanged: _settings.floatOutput
                          ? null
                          : (v) => _apply(_settings.copyWith(dither: v!)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?>? onChanged,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: DropdownButton<T>(
        value: value,
        items: items.entries
            .map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _slider({
    required String label,
    required String display,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(display, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
