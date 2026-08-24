import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum LinkPhase { disconnected, connecting, connected }

class WifiState {
  const WifiState({this.phase = LinkPhase.disconnected, this.tireId});

  final LinkPhase phase;
  final String? tireId;
}

class WifiManager {
  WifiManager._();
  static final instance = WifiManager._();

  /// Default gateway of the ESP32 SoftAP.
  static const host = '192.168.4.1';
  static const port = 3333;

  final state = ValueNotifier<WifiState>(const WifiState());
  final message = ValueNotifier<String?>(null);

  Socket? _socket;
  String _buffer = '';
  bool _connecting = false;

  bool get isConnected => state.value.phase == LinkPhase.connected;

  Future<void> connect() async {
    if (isConnected || _connecting) return;
    _connecting = true;
    state.value = const WifiState(phase: LinkPhase.connecting);
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      _socket = socket;
      _buffer = '';
      socket.listen(_onData, onDone: _onDisconnected, cancelOnError: true);
      socket.writeln('?');
      state.value = const WifiState(phase: LinkPhase.connected);
      message.value = 'Connected - asking board for its tire ID...';
    } catch (_) {
      state.value = const WifiState();
      message.value =
          'No reply from $host - join the TireESP32-xx WiFi network '
          'first (Settings > WiFi, password: tirepressure)';
    } finally {
      _connecting = false;
    }
  }

  void _onData(Uint8List data) {
    _buffer += utf8.decode(data, allowMalformed: true);
    int index;
    while ((index = _buffer.indexOf('\n')) >= 0) {
      final line = _buffer.substring(0, index).trim();
      _buffer = _buffer.substring(index + 1);
      if (line.startsWith('ID:')) {
        final id = line.substring(3).trim();
        state.value = WifiState(phase: LinkPhase.connected, tireId: id);
        message.value = 'Linked to tire $id';
      }
    }
  }

  void _onDisconnected() {
    _socket?.destroy();
    _socket = null;
    state.value = const WifiState();
    message.value = 'Connection lost';
  }

  Future<void> disconnect() async {
    _socket?.destroy();
    _socket = null;
    _buffer = '';
    state.value = const WifiState();
    message.value = 'Disconnected';
  }

  Future<void> send(String key, double pressure) async {
    final socket = _socket;
    if (socket == null || !isConnected) return;
    try {
      socket.writeln(pressure.toStringAsFixed(1));
    } catch (e) {
      debugPrint('WiFi send failed: $e');
    }
  }
}
