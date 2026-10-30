import 'package:flutter/services.dart';

class AccessibilityBridge {
  static const MethodChannel _channel = MethodChannel(
    'hello_boss/accessibility',
  );

  Future<bool> isEnabled() async {
    final result = await _channel.invokeMethod<bool>('isEnabled');
    return result ?? false;
  }

  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  Future<void> openAppInfo() => _channel.invokeMethod('openAppInfo');
}
