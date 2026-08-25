import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'link.dart';

/// Bluetooth Classic (SPP) transport - requires ESP32 boards with the
/// original chip (e.g. WROVER-E); the S3 cannot do Bluetooth Classic.
class ClassicManager implements LinkManager {
  ClassicManager._();
  static final instance = ClassicManager._();

  /// Boards advertise this name; app tells them apart by the suffix.
  static const prefix = 'TireESP32';

@override
  final state = ValueNotifier<LinkState>(const LinkState());
@override
  final message = ValueNotifier<String?>(null);

  /// Boards that got a write but never acknowledged it - drives the red
  /// warning banner in the UI.
@override
  final unackedBoards = ValueNotifier<Set<String>>(const <String>{});

  static const ackTimeout = Duration(milliseconds: 1500);

  final Map<String, BluetoothConnection> _conns = {};
  final Map<String, String> _knownAddresses = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, String> _rxBuffers = {};
  Set<String> _pendingAcks = const <String>{};
  bool _userDisconnected = false;

  @override
  bool get isConnected => _conns.isNotEmpty;

  @override
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

  void _onData(String key, Uint8List data) {
    var buffer =
        (_rxBuffers[key] ?? '') + utf8.decode(data, allowMalformed: true);
    int index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      final line = buffer.substring(0, index).trim();
      buffer = buffer.substring(index + 1);
      debugPrint('Classic [$key] received: "$line"');
      if (line == 'ACK:$key') {
        _pendingAcks = {..._pendingAcks}..remove(key);
      }
      // (future: handle other board replies here)
    }
    _rxBuffers[key] = buffer;
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
      (data) => _onData(key, data),
      onDone: () => _remove(key),
      onError: (_) => _remove(key),
    );
    state.value = state.value.copyWith(tires: {...state.value.tires, key});
    if (state.value.phase == LinkPhase.disconnected) {
      _setPhase(LinkPhase.connected);
    }
    if (unackedBoards.value.contains(key)) {
      unackedBoards.value = {...unackedBoards.value}..remove(key);
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
    _rxBuffers.remove(key);
    if (_pendingAcks.contains(key)) {
      _pendingAcks = {..._pendingAcks}..remove(key);
      // Lost mid-send: not "unacked", it's simply gone (UI already dims it).
    }
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

@override
  Future<void> disconnect() async {
    _userDisconnected = true;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    final conns = Map.of(_conns);
    _conns.clear();
    _rxBuffers.clear();
    unackedBoards.value = const <String>{};
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
  /// picks its own slot by its TIRE_ID and replies "ACK:`<TIRE_ID>`".
  /// Boards that stay silent land in [unackedBoards] (red warning).
@override
  Future<void> sendPressures(List<double> pressures) async {
    if (!isConnected || pressures.isEmpty) return;
    final payload =
        '${pressures.map((p) => p.toStringAsFixed(1)).join(',')}\n';
    final targets = _conns.keys.toList();
    _pendingAcks = {...targets};
    final writeFailed = <String>{};
    for (final k in targets) {
      try {
        _conns[k]!.output.add(utf8.encode(payload));
        await _conns[k]!.output.allSent;
      } catch (e) {
        debugPrint('Classic write to $k failed: $e');
        writeFailed.add(k);
      }
    }
    await Future<void>.delayed(ackTimeout);
    final failed = {...writeFailed, ..._pendingAcks};
    unackedBoards.value = failed;
    if (failed.isEmpty) {
      debugPrint('Classic: all boards acknowledged: $targets');
    }
  }

  @override
  Future<void> reconnectOne(String key) async {
    // Classic transport is retired; BLE handles every platform now.
  }
}
