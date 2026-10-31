import 'package:flutter/services.dart';

class ControlFeature {
  final String id;
  final String name;
  final String example;

  const ControlFeature(this.id, this.name, this.example);
}

class DeviceControlBridge {
  static const MethodChannel _channel = MethodChannel(
    'hello_boss/device_control',
  );

  /// Only the controls this phone supports.
  Future<List<ControlFeature>> getFeatures() async {
    final raw =
        await _channel.invokeListMethod<Map<dynamic, dynamic>>('getFeatures') ??
        <Map<dynamic, dynamic>>[];

    return raw
        .map(
          (m) => ControlFeature(
            m['id'] as String,
            m['name'] as String,
            m['example'] as String,
          ),
        )
        .toList();
  }

  Future<Set<String>> getAllowedFeatures() async {
    final list = await _channel.invokeListMethod<String>('getAllowedFeatures');
    return (list ?? <String>[]).toSet();
  }

  Future<void> setAllowedFeatures(Set<String> ids) =>
      _channel.invokeMethod('setAllowedFeatures', {'ids': ids.toList()});

  /// Runs a typed command like "turn on flashlight" (handy for testing).
  Future<String> execute(String command) async {
    final result = await _channel.invokeMethod<String>('execute', {
      'command': command,
    });
    return result ?? '';
  }

  Future<bool> hasWriteSettings() async =>
      (await _channel.invokeMethod<bool>('hasWriteSettings')) ?? false;

  Future<void> openWriteSettings() =>
      _channel.invokeMethod('openWriteSettings');

  Future<bool> hasDndAccess() async =>
      (await _channel.invokeMethod<bool>('hasDndAccess')) ?? false;

  Future<void> openDndAccess() => _channel.invokeMethod('openDndAccess');
}
