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

  Future<void> setLanguage(String language) async {
    final locale = switch (language) {
      'Nepali' => 'ne-NP',
      'Hindi' => 'hi-IN',
      _ => 'en-US',
    };

    await _methods.invokeMethod<void>('setLanguage', {'language': locale});
  }
}
