import 'dart:io';

import 'package:flutter/material.dart';

/// 簡易ディレクトリ選択ダイアログ。
///
/// [rootDir] から下の階層のみを辿れる。サブフォルダへの移動・新規フォルダの
/// 作成が可能で、「このフォルダを選択」で現在のフォルダのパスを返す。
/// `Navigator.pop(context, String)` で結果を返し、キャンセル時は `null`。
class DirectoryPickerDialog extends StatefulWidget {
  const DirectoryPickerDialog({
    super.key,
    required this.initialDir,
    required this.rootDir,
  });

  final Directory initialDir;
  final Directory rootDir;

  @override
  State<DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<DirectoryPickerDialog> {
  late Directory _current;
  String? _error;
  bool _creating = false;
  final TextEditingController _newFolderController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _current = widget.initialDir;
  }

  @override
  void dispose() {
    _newFolderController.dispose();
    super.dispose();
  }

  /// 末尾のセパレーターを除いた正規化済みパス。
  String _norm(String path) {
    var result = path;
    while (result.endsWith('/') && result.length > 1) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  bool get _atRoot => _norm(_current.path) == _norm(widget.rootDir.path);

  List<Directory> _subdirectories(Directory dir) {
    if (!dir.existsSync()) return const [];
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException catch (error) {
      _error = 'フォルダを読み込めません: ${error.message}';
      return const [];
    }
    final dirs = <Directory>[];
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final name = _norm(entry.path).split(Platform.pathSeparator).last;
      if (name.isEmpty || name.startsWith('.')) continue;
      dirs.add(entry);
    }
    dirs.sort(
      (a, b) =>
          _norm(a.path).toLowerCase().compareTo(_norm(b.path).toLowerCase()),
    );
    return dirs;
  }

  void _navigate(Directory dir) {
    setState(() {
      _error = null;
      _current = dir;
    });
  }

  void _up() {
    if (_atRoot) return;
    final parent = Directory(_norm(_current.path)).parent;
    if (_norm(parent.path).length < _norm(widget.rootDir.path).length) return;
    _navigate(parent);
  }

  Future<void> _createFolder() async {
    _newFolderController.clear();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新規フォルダ'),
        content: TextField(
          controller: _newFolderController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'フォルダ名',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _newFolderController.text.trim()),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (!mounted) return;

    setState(() => _creating = true);
    try {
      final created = Directory('${_norm(_current.path)}/$name');
      // 既存のダウンロード処理と同様に同期APIを使う（フォルダ作成は軽量な操作）。
      created.createSync(recursive: false);
      if (mounted) {
        _navigate(created);
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        setState(() => _error = 'フォルダを作成できません: ${error.message}');
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subDirs = _subdirectories(_current);
    final exists = _current.existsSync();

    return AlertDialog(
      title: const Text('保存先フォルダの選択'),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _current.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (!exists)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'このフォルダは存在しません。選択すると作成されます。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.tertiary),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            const Divider(height: 12),
            Expanded(
              child: subDirs.isEmpty
                  ? Center(
                      child: Text(
                        _error == null ? 'サブフォルダはありません' : '読み込めませんでした',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      itemCount: subDirs.length,
                      itemBuilder: (context, index) {
                        final dir = subDirs[index];
                        final name =
                            _norm(dir.path).split(Platform.pathSeparator).last;
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _navigate(dir),
                        );
                      },
                    ),
            ),
            if (_creating)
              const Padding(
                padding: EdgeInsets.all(8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _atRoot ? null : _up,
          icon: const Icon(Icons.arrow_upward),
          label: const Text('上へ'),
        ),
        TextButton.icon(
          onPressed: _creating ? null : _createFolder,
          icon: const Icon(Icons.create_new_folder),
          label: const Text('新規フォルダ'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _norm(_current.path)),
          child: const Text('このフォルダを選択'),
        ),
      ],
    );
  }
}
