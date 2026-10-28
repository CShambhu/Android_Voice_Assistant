import 'dart:async';
import 'package:flutter/services.dart';

class WakeWordBridge {
  static const MethodChannel _methods = MethodChannel('hello_boss/wake_word');

  static const EventChannel _events = EventChannel(
    'hello_boss/wake_word_events',
  );

  Stream<Map<String, dynamic>>? _eventStream;

  Stream<Map<String, dynamic>> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => Map<String, dynamic>.from(event as Map));
  }

  Future<void> start() async {
    await _methods.invokeMethod<void>('start');
  }

  Future<void> stop() async {
    await _methods.invokeMethod<void>('stop');
  }

  /// Package names of the apps Hello Boss is allowed to control.
  Future<List<String>> getAllowedApps() async {
    final result = await _methods.invokeListMethod<String>('getAllowedApps');
    return result ?? <String>[];
  }

  /// The app's launcher icon as PNG bytes, or null if unavailable.
  Future<Uint8List?> getAppIcon(String packageName) async {
    return _methods.invokeMethod<Uint8List>('getAppIcon', {
      'package': packageName,
    });
  }

  Future<void> setAllowedApps(Iterable<String> packages) async {
    await _methods.invokeMethod<void>('setAllowedApps', {
      'packages': packages.toList(),
    });
  }

  Future<void> setLanguage(String language) async {
    final locale = switch (language) {
      'Nepali' => 'ne-NP',
      'Hindi' => 'hi-IN',
      _ => 'en-US',
    };

    await _methods.invokeMethod<void>('setLanguage', {'language': locale});
  }
}
