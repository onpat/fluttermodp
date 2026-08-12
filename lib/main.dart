import 'package:flutter/material.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import 'openmpt_ffi.dart';

const _sampleRate = 48000;
const _channelCount = 2;
const _feedThresholdFrames = 4096;
const _renderChunkFrames = 8192;

bool _isPlaybackActive = false;
bool _isFeeding = false;
bool _feedRequested = false;
bool _hasQueuedFirstBuffer = false;
OpenMptDecoder? _decoder;

class _InitializationResult {
  const _InitializationResult({required this.success, required this.message});

  final bool success;
  final String message;
}

Future<_InitializationResult> _initializeOpenMpt() async {
  try {
    final decoder = await OpenMptDecoder.fromAsset('assets/cavern.mod');
    _decoder = decoder;
    debugPrint('[libopenmpt] SUCCESS: ${decoder.description}');
    return _InitializationResult(success: true, message: decoder.description);
  } catch (error, stackTrace) {
    final message = 'Unexpected initialization failure: $error';
    debugPrint('[libopenmpt] ERROR: $message');
    debugPrintStack(stackTrace: stackTrace);
    return _InitializationResult(success: false, message: message);
  }
}

Future<void> _feedOpenMpt(int remainingFrames) async {
  if (!_isPlaybackActive) {
    return;
  }
  if (_isFeeding) {
    // A feed event can arrive while the previous PCM buffer is being queued.
    // Remember it so flutter_pcm_sound's one-shot event is not lost.
    _feedRequested = true;
    return;
  }

  _isFeeding = true;
  try {
    final pcmBytes = _decoder?.renderStereo(
      frameCount: _renderChunkFrames,
      sampleRate: _sampleRate,
    );

    if (pcmBytes == null || pcmBytes.isEmpty) {
      _isPlaybackActive = false;
      FlutterPcmSound.setFeedCallback(null);
      _decoder?.dispose();
      _decoder = null;
      debugPrint('[libopenmpt] PLAYBACK: cavern.mod finished.');
      return;
    }

    // flutter_pcm_sound expects signed 16-bit interleaved PCM in host endian.
    final pcm = pcmBytes;
    await FlutterPcmSound.feed(PcmArrayInt16(bytes: pcm.buffer.asByteData()));
    if (!_hasQueuedFirstBuffer) {
      _hasQueuedFirstBuffer = true;
      final frames = pcm.lengthInBytes ~/ (_channelCount * 2);
      debugPrint(
        '[libopenmpt] PLAYBACK: First PCM buffer queued ($frames frames).',
      );
    }
  } catch (error, stackTrace) {
    _isPlaybackActive = false;
    FlutterPcmSound.setFeedCallback(null);
    _decoder?.dispose();
    _decoder = null;
    debugPrint('[libopenmpt] PLAYBACK ERROR: $error');
    debugPrintStack(stackTrace: stackTrace);
  } finally {
    _isFeeding = false;
    if (_isPlaybackActive && _feedRequested) {
      _feedRequested = false;
      Future.microtask(() => _feedOpenMpt(0));
    }
  }
}

Future<String> _startPlayback() async {
  try {
    await FlutterPcmSound.setLogLevel(LogLevel.error);
    await FlutterPcmSound.setup(
      sampleRate: _sampleRate,
      channelCount: _channelCount,
    );
    await FlutterPcmSound.setFeedThreshold(_feedThresholdFrames);
    FlutterPcmSound.setFeedCallback(_feedOpenMpt);
    _isPlaybackActive = true;
    _feedRequested = false;
    _hasQueuedFirstBuffer = false;
    final started = FlutterPcmSound.start();
    final message = started
        ? 'Automatic playback started at $_sampleRate Hz, stereo.'
        : 'PCM output was ready, but playback did not start.';
    debugPrint('[libopenmpt] PLAYBACK: $message');
    return message;
  } catch (error, stackTrace) {
    _isPlaybackActive = false;
    _decoder?.dispose();
    _decoder = null;
    final message = 'PCM output initialization failed: $error';
    debugPrint('[libopenmpt] PLAYBACK ERROR: $message');
    debugPrintStack(stackTrace: stackTrace);
    return message;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialization = await _initializeOpenMpt();
  var startupMessage = initialization.message;
  if (initialization.success) {
    startupMessage = '$startupMessage\n${await _startPlayback()}';
  }
  runApp(FlutterModp(initializationMessage: startupMessage));
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
  int _counter = 0;

  void _incrementCounter() {
    setState(() => _counter++);
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
              const Text('You have pushed the button this many times:'),
              Text(
                '$_counter',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
