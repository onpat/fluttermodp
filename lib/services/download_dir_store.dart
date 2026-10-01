import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _channel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');

/// ダウンロード先フォルダを作成できなかったときに投げられる例外。
///
/// Android で「すべてのファイルへのアクセス」が許可されていない場合など。
class DownloadDirException implements Exception {
  const DownloadDirException(this.message, [this.path]);

  final String message;
  final String? path;

  @override
  String toString() => message;
}

/// AMP / Mod Archive モジュールのダウンロード先ディレクトリの
/// 解決・永続化・作成を行うストア。
///
/// 既定ではユーザーが参照できる場所（Android では共有ストレージの
/// `Documents/mods`、それ以外では OS のドキュメントフォルダ直下の `mods`）
/// を使用し、設定画面のディレクトリピッカーで変更できる。
/// 選択結果はアプリ内の小さな JSON ファイルに永続化する
/// （サードパーティの設定保存パッケージは使わない）。
class DownloadDirStore {
  DownloadDirStore._();

  static final DownloadDirStore instance = DownloadDirStore._();

  /// 既定のダウンロード先フォルダ名。
  static const String defaultFolderName = 'mods';

  Directory? _downloadDir;
  bool _initialized = false;

  /// 永続化されたダウンロード先（無ければ既定値）を返す。
  ///
  /// フォルダの作成は行わない。実際に使う前には [ensureDir] を呼ぶこと。
  Future<Directory> load() async {
    if (_initialized) {
      return _downloadDir ?? await defaultDir();
    }
    _initialized = true;
    try {
      final file = await _prefsFile();
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map && decoded['downloadDir'] is String) {
          final path = decoded['downloadDir'] as String;
          if (path.isNotEmpty) {
            _downloadDir = Directory(path);
          }
        }
      }
    } catch (_) {
      // 設定ファイルが壊れている場合は既定値に戻す。
    }
    return _downloadDir ?? await defaultDir();
  }

  /// 既定のダウンロード先（Android: 共有ストレージの `Documents/mods`、
  /// それ以外: OS のドキュメントフォルダ直下の `mods`）。
  Future<Directory> defaultDir() async {
    if (Platform.isAndroid) {
      try {
        final documents =
            await _channel.invokeMethod<String>('getPublicDocumentsDir');
        if (documents != null && documents.isNotEmpty) {
          return Directory('$documents/$defaultFolderName');
        }
      } catch (_) {
        // ネイティブ側が古い場合はドキュメントディレクトリへフォールバック。
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$defaultFolderName');
  }

  /// [load] したダウンロード先を返し、存在しなければ作成する。
  ///
  /// 作成に失敗した場合（Android で「すべてのファイルへのアクセス」が
  /// 許可されていない場合など）は [DownloadDirException] を投げる。
  Future<Directory> ensureDir() async {
    final dir = await load();
    try {
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    } on FileSystemException {
      throw DownloadDirException(
        '保存先フォルダを作成できません: ${dir.path}\n'
        'Android の場合は「再生設定」→「保存先フォルダ」から'
        '「すべてのファイルへのアクセス」を許可してください。',
        dir.path,
      );
    }
  }

  /// ダウンロード先を [dir] に変更し、永続化する。
  Future<void> set(Directory dir) async {
    _downloadDir = dir;
    _initialized = true;
    try {
      final file = await _prefsFile();
      file.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        'downloadDir': dir.path,
      }));
    } catch (_) {
      // 永続化に失敗しても今回のセッションでは選択されたディレクトリを使う。
    }
  }

  /// ダウンロード先を既定値（`Documents/mods`）に戻す。
  Future<Directory> resetToDefault() async {
    final dir = await defaultDir();
    _downloadDir = dir;
    try {
      final file = await _prefsFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
    return dir;
  }

  /// 共有ストレージへの書き込み権限があるかどうか。
  ///
  /// Android 以外では常に `true`。Android では API 30+ で
  /// 「すべてのファイルへのアクセス」(MANAGE_EXTERNAL_STORAGE)、
  /// API 29 以下で WRITE_EXTERNAL_STORAGE の許可状態を返す。
  Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? true;
    } catch (_) {
      // ネイティブ側が未実装の環境では制限がないものとして扱う。
      return true;
    }
  }

  /// 共有ストレージへの書き込み権限を要求する。
  ///
  /// Android 11+ ではシステム設定の「すべてのファイルへのアクセス」画面を開く。
  /// 結果は非同期なので、戻ってきたら [hasAccess] で再確認すること。
  Future<void> requestAccess() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (_) {}
  }

  /// ディレクトリピッカーの起点となるディレクトリ。
  ///
  /// Android では共有ストレージのルート（`/storage/emulated/0`）、
  /// それ以外ではユーザーのホームディレクトリ。
  Future<Directory> pickerRoot() async {
    if (Platform.isAndroid) {
      try {
        final documents =
            await _channel.invokeMethod<String>('getPublicDocumentsDir');
        if (documents != null && documents.isNotEmpty) {
          return Directory(documents).parent;
        }
      } catch (_) {}
    }
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      return Directory(home);
    }
    final docs = await getApplicationDocumentsDirectory();
    return docs.parent;
  }

  Future<File> _prefsFile() async {
    final base = await getApplicationSupportDirectory();
    return File('${base.path}/download_dir.json');
  }
}
