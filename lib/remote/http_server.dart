import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Channel used by the native side to start/stop this HTTP server.
const _controlChannel = MethodChannel('net.klovnin.fluttermodp/http_server');

/// Channel used by this isolate to drive the audio player in Kotlin.
const _playerChannel = MethodChannel('net.klovnin.fluttermodp/player');

HttpServer? _server;

/// Background entrypoint started by the root-library wrapper in `main.dart`.
void httpServerEntrypoint() {
  WidgetsFlutterBinding.ensureInitialized();
  _controlChannel.setMethodCallHandler(_handleControl);
}

Future<Object?> _handleControl(MethodCall call) async {
  switch (call.method) {
    case 'startServer':
      final args = call.arguments;
      final port = args is Map ? args['port'] as int? ?? 8080 : 8080;
      return _startServer(port);
    case 'stopServer':
      return _stopServer();
    default:
      throw MissingPluginException('Unknown control method: ${call.method}');
  }
}

Future<Map<String, Object?>> _startServer(int port) async {
  if (_server != null) {
    return {'success': false, 'message': 'HTTP server already running'};
  }
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    server.listen(_handleRequest);
    return {'success': true, 'port': server.port};
  } on SocketException catch (error) {
    return {'success': false, 'message': error.message};
  } catch (error) {
    return {'success': false, 'message': error.toString()};
  }
}

Future<Map<String, Object?>> _stopServer() async {
  final server = _server;
  if (server == null) {
    return {'success': true, 'message': 'HTTP server is not running'};
  }
  _server = null;
  await server.close(force: true);
  return {'success': true};
}

Future<void> _handleRequest(HttpRequest request) async {
  final response = request.response;
  response.headers.contentType = ContentType.json;
  try {
    final result = await _route(request);
    response.statusCode = (result['statusCode'] as int?) ?? HttpStatus.ok;
    response.write(jsonEncode(result['body']));
  } catch (error) {
    response.statusCode = HttpStatus.internalServerError;
    response.write(jsonEncode({'success': false, 'message': error.toString()}));
  } finally {
    await response.close();
  }
}

Future<Map<String, Object?>> _route(HttpRequest request) async {
  final method = request.method.toUpperCase();
  final segments = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final query = request.uri.queryParameters;

  if (method == 'GET' && segments.isEmpty) {
    final state = await _playerChannel.invokeMethod<Object?>('getState');
    return _ok({'success': true, 'state': state});
  }

  if (method == 'GET' && segments.length == 1 && segments.first == 'state') {
    final state = await _playerChannel.invokeMethod<Object?>('getState');
    return _ok({'success': true, 'state': state});
  }

  if (method == 'POST') {
    final command = segments.isEmpty ? query['cmd'] ?? '' : segments.first;
    final index = _parseIndex(segments.length > 1 ? segments[1] : query['index']);
    final positionMs = int.tryParse(query['positionMs'] ?? query['position'] ?? '');
    final enabled = query['enabled']?.toLowerCase() == 'true' || query['enabled'] == '1';

    switch (command) {
      case 'play':
        await _playerChannel.invokeMethod('play');
        return _ok({'success': true});
      case 'pause':
        await _playerChannel.invokeMethod('pause');
        return _ok({'success': true});
      case 'stop':
        await _playerChannel.invokeMethod('stop');
        return _ok({'success': true});
      case 'next':
        await _playerChannel.invokeMethod('next');
        return _ok({'success': true});
      case 'previous':
        await _playerChannel.invokeMethod('previous');
        return _ok({'success': true});
      case 'seek':
        if (positionMs == null || positionMs < 0) {
          return _error('positionMs must be a non-negative integer');
        }
        await _playerChannel.invokeMethod('seek', {'positionMs': positionMs});
        return _ok({'success': true});
      case 'playIndex':
        if (index == null) return _error('index is required');
        await _playerChannel.invokeMethod('playIndex', {'index': index});
        return _ok({'success': true});
      case 'remove':
      case 'removeTrack':
        if (index == null) return _error('index is required');
        await _playerChannel.invokeMethod('removeTrack', {'index': index});
        return _ok({'success': true});
      case 'clear':
      case 'clearPlaylist':
        await _playerChannel.invokeMethod('clearPlaylist');
        return _ok({'success': true});
      case 'repeatOne':
        await _playerChannel.invokeMethod('setRepeatOne', {'enabled': enabled});
        return _ok({'success': true});
      case 'repeatPlaylist':
        await _playerChannel.invokeMethod('setRepeatPlaylist', {'enabled': enabled});
        return _ok({'success': true});
    }
  }

  return _error('unknown route: $method /${segments.join('/')}', HttpStatus.notFound);
}

int? _parseIndex(String? raw) {
  if (raw == null) return null;
  return int.tryParse(raw);
}

Map<String, Object?> _ok(Map<String, Object?> body) =>
    {'statusCode': HttpStatus.ok, 'body': body};

Map<String, Object?> _error(String message, [int status = HttpStatus.badRequest]) =>
    {'statusCode': status, 'body': {'success': false, 'message': message}};