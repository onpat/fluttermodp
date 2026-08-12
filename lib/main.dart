import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _openMptChannel = MethodChannel('net.klovnin.fluttermodp/libopenmpt');

class _InitializationResult {
  const _InitializationResult({required this.success, required this.message});

  final bool success;
  final String message;
}

Future<_InitializationResult> _initializeOpenMpt() async {
  if (!Platform.isAndroid) {
    return const _InitializationResult(
      success: false,
      message: 'libopenmpt initialization is skipped outside Android.',
    );
  }

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
