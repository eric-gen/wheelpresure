import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';
import 'package:permission_handler/permission_handler.dart';

enum LinkPhase { disconnected, scanning, connecting, connected }

class LinkState {
  const LinkState({
    this.phase = LinkPhase.disconnected,
    this.tires = const <String>{},
  });

  final LinkPhase phase;
  final Set<String> tires;

  LinkState copyWith({LinkPhase? phase, Set<String>? tires}) =>
      LinkState(phase: phase ?? this.phase, tires: tires ?? this.tires);
}

/// Bluetooth Classic (SPP) transport - requires ESP32 boards with the
/// original chip (e.g. WROVER-E); the S3 cannot do Bluetooth Classic.
class ClassicManager {
  ClassicManager._();
  static final instance = ClassicManager._();

  /// Boards advertise this name; app tells them apart by the suffix.
  static const prefix = 'TireESP32';

  final state = ValueNotifier<LinkState>(const LinkState());
  final message = ValueNotifier<String?>(null);

  final Map<String, BluetoothConnection> _conns = {};
  final Map<String, String> _knownAddresses = {};
  final Map<String, Timer> _retryTimers = {};
  bool _userDisconnected = false;
  String _rxBuffer = '';

  bool get isConnected => _conns.isNotEmpty;

  Future<void> connect() async {
    if (state.value.phase != LinkPhase.disconnected) return;
    try {
      _userDisconnected = false;
      final perms = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      debugPrint('Classic permissions: $perms');
      final denied =
          perms.entries.where((e) => !e.value.isGranted).map((e) => e.key);
      if (denied.any(
        (p) => p == Permission.bluetoothScan || p == Permission.bluetoothConnect,
      )) {
        message.value =
            'Permission denied (${denied.join(", ")}) - allow "Nearby '
            'devices" for this app in Settings > Apps';
        return;
      }

      final bt = FlutterBluetoothSerial.instance;
      if ((await bt.state) != BluetoothState.STATE_ON) {
        message.value = 'Bluetooth is turned off';
        return;
      }

      _setPhase(LinkPhase.scanning);
      debugPrint('Classic: listing paired devices...');
      final paired = await bt.getBondedDevices();
      debugPrint(
        'Classic: ${paired.length} paired device(s): '
        '${paired.map((d) => d.name).toList()}',
      );

      final targets = <String, String>{};
      for (final d in paired) {
        final key = _keyFromName(d.name);
        if (key != null) targets[key] = d.address;
      }
      if (targets.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value =
            'No paired $prefix-xx board found - pair it once in '
            'Settings > Bluetooth first';
        return;
      }
      debugPrint('Classic: boards to connect: ${targets.keys.toList()}');

      _setPhase(LinkPhase.connecting);
      for (final entry in targets.entries) {
        _knownAddresses[entry.key] = entry.value;
        try {
          final conn = await BluetoothConnection.toAddress(entry.value)
              .timeout(const Duration(seconds: 8));
          _register(entry.key, conn);
          debugPrint('Classic: connected ${entry.key} (${entry.value})');
        } catch (e) {
          debugPrint('Classic: failed to connect ${entry.key}: $e');
        }
        if (!_conns.containsKey(entry.key)) {
          // Board seen but not linked yet - keep trying in the background.
          _scheduleReconnect(entry.key, entry.value);
        }
      }

      if (_conns.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value = 'Boards seen, but none accepted a connection';
        return;
      }
      _setPhase(LinkPhase.connected);
      message.value = 'Connected: ${_conns.keys.toList()..sort()}';
    } catch (e) {
      debugPrint('Classic connect failed: $e');
      _setPhase(LinkPhase.disconnected);
      message.value = 'Connection failed';
    }
  }

  void _onData(Uint8List data) {
    // Boards are write-only today; buffer anyway in case they reply later.
    _rxBuffer += utf8.decode(data, allowMalformed: true);
    int index;
    while ((index = _rxBuffer.indexOf('\n')) >= 0) {
      final line = _rxBuffer.substring(0, index).trim();
      _rxBuffer = _rxBuffer.substring(index + 1);
      debugPrint('Classic received: "$line"');
    }
  }

  String? _keyFromName(String? name) {
    if (name == null || !name.startsWith(prefix)) return null;
    for (final k in const ['FL', 'FR', 'RL', 'RR']) {
      if (name.endsWith('-$k')) return k;
    }
    return null;
  }

  void _setPhase(LinkPhase phase) =>
      state.value = state.value.copyWith(phase: phase);

  void _register(String key, BluetoothConnection conn) {
    _retryTimers.remove(key)?.cancel();
    _conns[key] = conn;
    conn.input.listen(
      _onData,
      onDone: () => _remove(key),
      onError: (_) => _remove(key),
    );
    state.value = state.value.copyWith(tires: {...state.value.tires, key});
    if (state.value.phase == LinkPhase.disconnected) {
      _setPhase(LinkPhase.connected);
    }
  }

  void _scheduleReconnect(String key, String address) {
    _retryTimers[key]?.cancel();
    if (_userDisconnected) return;
    _retryTimers[key] = Timer(const Duration(seconds: 5), () async {
      if (_userDisconnected || _conns.containsKey(key)) return;
      debugPrint('Classic: reconnecting $key...');
      try {
        final conn = await BluetoothConnection.toAddress(address)
            .timeout(const Duration(seconds: 6));
        if (_userDisconnected) {
          try {
            await conn.close();
          } catch (_) {}
          return;
        }
        debugPrint('Classic: reconnected $key');
        message.value = 'Reconnected to $key';
        _register(key, conn);
      } catch (e) {
        debugPrint('Classic: reconnect $key failed ($e) - retry in 5s');
        _scheduleReconnect(key, address);
      }
    });
  }

  void _remove(String key) {
    final conn = _conns.remove(key);
    try {
      conn?.close();
    } catch (_) {}
    final tires = {...state.value.tires}..remove(key);
    state.value = LinkState(
      phase: tires.isEmpty ? LinkPhase.disconnected : LinkPhase.connected,
      tires: tires,
    );
    final address = _knownAddresses[key];
    if (address != null && !_userDisconnected) {
      message.value = '$key lost - auto-reconnecting...';
      _scheduleReconnect(key, address);
    }
    debugPrint('Classic: lost $key');
  }

  Future<void> disconnect() async {
    _userDisconnected = true;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    final conns = Map.of(_conns);
    _conns.clear();
    state.value = const LinkState();
    for (final c in conns.values) {
      try {
        await c.close();
      } catch (_) {}
    }
    message.value = 'Disconnected';
  }

  /// Sends all four pressures in one message, fixed order FL,FR,RL,RR:
  /// "2.4,3.4,1.2,2.5\n". Written to every connected board; each board
  /// picks its own slot by its TIRE_ID.
  Future<void> sendPressures(List<double> pressures) async {
    if (!isConnected || pressures.isEmpty) return;
    final payload =
        '${pressures.map((p) => p.toStringAsFixed(1)).join(',')}\n';
    for (final k in _conns.keys.toList()) {
      try {
        _conns[k]!.output.add(utf8.encode(payload));
        await _conns[k]!.output.allSent;
      } catch (e) {
        debugPrint('Classic write to $k failed: $e');
      }
    }
  }
}
