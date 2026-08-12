import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _openMptChannel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');

class _InitializationResult {
  const _InitializationResult({required this.success, required this.message});

  final bool success;
  final String message;
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
    final message = 'Platform initialization failed: ${error.message}';
    debugPrint('[libopenmpt] ERROR: $message');
    return _InitializationResult(success: false, message: message);
  } catch (error, stackTrace) {
    final message = 'Unexpected initialization failure: $error';
    debugPrint('[libopenmpt] ERROR: $message');
    debugPrintStack(stackTrace: stackTrace);
    return _InitializationResult(success: false, message: message);
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
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
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
  bool _isPicking = false;
  String? _selectedFileName;
  String _status = '再生するモジュールファイルを選択してください。';

  Future<void> _pickAndPlay() async {
    if (_isPicking) return;
    setState(() {
      _isPicking = true;
      _status = 'ファイル選択画面を開いています…';
    });

    try {
      final selected = await _openMptChannel.invokeMapMethod<String, Object?>(
        'pickFile',
      );
      if (!mounted) return;
      if (selected == null) {
        setState(() => _status = 'ファイル選択をキャンセルしました。');
        return;
      }

      final uri = selected['uri'] as String?;
      final name = selected['name'] as String? ?? 'selected module';
      if (uri == null || uri.isEmpty) {
        throw PlatformException(
          code: 'invalid_file',
          message: '選択されたファイルの URI を取得できませんでした。',
        );
      }

      setState(() {
        _selectedFileName = name;
        _status = '$name を読み込んでいます…';
      });
      final result = await _openMptChannel.invokeMapMethod<String, Object?>(
        'playFile',
        {'uri': uri, 'name': name},
      );
      if (!mounted) return;
      final success = result?['success'] == true;
      setState(() {
        _status =
            result?['message'] as String? ??
            (success ? '再生を開始しました。' : '再生を開始できませんでした。');
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() => _status = error.message ?? error.code);
    } catch (error) {
      if (mounted) setState(() => _status = 'ファイルの再生に失敗しました: $error');
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: .center,
            children: [
              const Text('libopenmpt initialization result:'),
              const SizedBox(height: 8),
              Text(widget.initializationMessage, textAlign: TextAlign.center),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _isPicking ? null : _pickAndPlay,
                icon: const Icon(Icons.audio_file),
                label: Text(_isPicking ? '処理中…' : 'モジュールファイルを選択'),
              ),
              const SizedBox(height: 16),
              if (_selectedFileName != null)
                Text(
                  '選択中: $_selectedFileName',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              const SizedBox(height: 8),
              Text(_status, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
