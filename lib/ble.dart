import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'link.dart';

/// Bluetooth LE transport - used on iOS (and anywhere without classic BT).
/// Requires the S3 firmware with a notify-capable characteristic so boards
/// can send "ACK:TIRE_ID" replies.
class BleManager implements LinkManager {
  BleManager._();
  static final instance = BleManager._();

  /// All boards advertise this same service UUID.
  static final serviceUuid = Guid('5f1d16a0-046d-47fd-b49a-d6f1ae118f52');

  /// Every board exposes this same characteristic; boards are told apart by
  /// their advertised name: TireESP32-FL, TireESP32-FR, TireESP32-RL, ...
  static final charUuid = Guid('5f1d16a1-046d-47fd-b49a-d6f1ae118f52');

  @override
  final state = ValueNotifier<LinkState>(const LinkState());
  @override
  final message = ValueNotifier<String?>(null);
  @override
  final unackedBoards = ValueNotifier<Set<String>>(const <String>{});

  static const ackTimeout = Duration(milliseconds: 1500);

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BluetoothCharacteristic> _chars = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>> _subs = {};
  final Map<String, String> _rxBuffers = {};
  Set<String> _pendingAcks = const <String>{};
  bool _userDisconnected = false;

  @override
  bool get isConnected => _chars.isNotEmpty;

  @override
  Future<void> connect() async {
    if (state.value.phase != LinkPhase.disconnected) return;
    try {
      _userDisconnected = false;
      final perms = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      debugPrint('BLE permissions: $perms');
      final denied =
          perms.entries.where((e) => !e.value.isGranted).map((e) => e.key);
      if (denied.isNotEmpty) {
        message.value =
            'Permission denied (${denied.join(", ")}) - allow "Nearby '
            'devices" / "Bluetooth" for this app in Settings';
        return;
      }

      // Never hang here waiting for adapter events.
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => FlutterBluePlus.adapterStateNow,
          );
      debugPrint('BLE adapter state: $adapter');
      if (adapter != BluetoothAdapterState.on) {
        message.value = 'Bluetooth is turned off';
        return;
      }

      _setPhase(LinkPhase.scanning);
      debugPrint('BLE scanning for TireESP32 boards (8s)...');
      final found = <String, BluetoothDevice>{};
      var devicesSeen = 0;
      late final StreamSubscription<List<ScanResult>> scanSub;
      scanSub = FlutterBluePlus.scanResults.listen((results) {
        // Unfiltered scan: count everything so failures can be told apart.
        devicesSeen =
            devicesSeen > results.length ? devicesSeen : results.length;
        for (final r in results) {
          final name =
              r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : r.device.platformName;
          final key = _keyFromName(name);
          if (key != null && !found.containsKey(key)) {
            debugPrint('BLE board found: "$name"');
            found[key] = r.device;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await scanSub.cancel();
      await FlutterBluePlus.stopScan();
      debugPrint(
        'BLE scan done: saw $devicesSeen device(s), boards: '
        '${found.keys.toList()}',
      );

      if (found.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value =
            devicesSeen == 0
                ? 'Scan saw no devices at all - check Bluetooth permission'
                : 'Scan saw $devicesSeen device(s), but no TireESP32-xx - '
                    'check the boards are powered and flashed';
        return;
      }

      _setPhase(LinkPhase.connecting);
      for (final entry in found.entries) {
        await _link(entry.key, entry.value);
      }

      if (_chars.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value = 'Boards seen, but none accepted a connection';
        return;
      }
      _setPhase(LinkPhase.connected);
      message.value = 'Connected: ${_chars.keys.toList()..sort()}';
    } catch (e) {
      debugPrint('BLE connect failed: $e');
      _setPhase(LinkPhase.disconnected);
      message.value = 'Connection failed';
    }
  }

  Future<void> _link(String key, BluetoothDevice device) async {
    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 8),
        autoConnect: false,
      );
      final services = await device.discoverServices();
      BluetoothCharacteristic? target;
      for (final svc in services) {
        for (final c in svc.characteristics) {
          if (c.uuid == charUuid) target = c;
        }
      }
      if (target == null) {
        debugPrint('BLE: $key missing expected characteristic');
        await device.disconnect();
        return;
      }
      await target.setNotifyValue(true);
      target.onValueReceived.listen((value) => _onData(key, value));
      _devices[key] = device;
      _chars[key] = target;
      _subs[key]?.cancel();
      _subs[key] = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _remove(key);
      });
      state.value = state.value.copyWith(tires: {...state.value.tires, key});
      if (state.value.phase == LinkPhase.disconnected) {
        _setPhase(LinkPhase.connected);
      }
      if (unackedBoards.value.contains(key)) {
        unackedBoards.value = {...unackedBoards.value}..remove(key);
      }
      debugPrint('BLE: connected $key');
    } catch (e) {
      debugPrint('BLE: failed to connect $key: $e');
    }
    if (!_chars.containsKey(key)) {
      // Board seen but not linked yet - keep trying in the background.
      _scheduleReconnect(key, device);
    }
  }

  void _scheduleReconnect(String key, BluetoothDevice device) {
    if (_userDisconnected || _devices.containsKey(key)) return;
    Timer(const Duration(seconds: 5), () async {
      if (_userDisconnected || _chars.containsKey(key)) return;
      debugPrint('BLE: reconnecting $key...');
      await _link(key, device);
    });
  }

  void _onData(String key, List<int> raw) {
    var buffer =
        (_rxBuffers[key] ?? '') + utf8.decode(raw, allowMalformed: true);
    int index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      final line = buffer.substring(0, index).trim();
      buffer = buffer.substring(index + 1);
      debugPrint('BLE [$key] received: "$line"');
      if (line == 'ACK:$key') {
        _pendingAcks = {..._pendingAcks}..remove(key);
      }
    }
    _rxBuffers[key] = buffer;
  }

  String? _keyFromName(String? name) {
    if (name == null) return null;
    for (final k in const ['FL', 'FR', 'RL', 'RR']) {
      if (name.endsWith('-$k')) return k;
    }
    return null;
  }

  void _setPhase(LinkPhase phase) =>
      state.value = state.value.copyWith(phase: phase);

  void _remove(String key) {
    _subs.remove(key)?.cancel();
    _chars.remove(key);
    _rxBuffers.remove(key);
    final tires = {...state.value.tires}..remove(key);
    state.value = LinkState(
      phase: tires.isEmpty ? LinkPhase.disconnected : LinkPhase.connected,
      tires: tires,
    );
    final device = _devices[key];
    if (device != null && !_userDisconnected) {
      message.value = '$key lost - auto-reconnecting...';
      _scheduleReconnect(key, device);
    }
    debugPrint('BLE: lost $key');
  }

  @override
  Future<void> disconnect() async {
    _userDisconnected = true;
    for (final sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    _chars.clear();
    _rxBuffers.clear();
    unackedBoards.value = const <String>{};
    final devices = List.of(_devices.values);
    _devices.clear();
    state.value = const LinkState();
    for (final d in devices) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    message.value = 'Disconnected';
  }

  @override
  Future<void> sendPressures(List<double> pressures) async {
    if (!isConnected || pressures.isEmpty) return;
    // One message with every pressure, fixed order FL,FR,RL,RR. No newline
    // needed: a BLE write is one complete message.
    final payload =
        pressures.map((p) => p.toStringAsFixed(1)).join(',').codeUnits;
    final targets = _chars.keys.toList();
    _pendingAcks = {...targets};
    final writeFailed = <String>{};
    for (final k in targets) {
      try {
        await _chars[k]!.write(payload);
      } catch (e) {
        debugPrint('BLE write to $k failed: $e');
        writeFailed.add(k);
      }
    }
    await Future<void>.delayed(ackTimeout);
    final failed = {...writeFailed, ..._pendingAcks};
    unackedBoards.value = failed;
    if (failed.isEmpty) {
      debugPrint('BLE: all boards acknowledged: $targets');
    }
  }
}
