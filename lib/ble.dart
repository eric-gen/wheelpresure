import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'link.dart';

/// Bluetooth LE transport - used on every platform.
/// Matches the current firmware: the characteristic is READ and WRITE only
/// (no notify) and a board confirms by rewriting its value to
/// "ACK:TIRE_ID:bar", which we pick up by polling reads.
class BleManager implements LinkManager {
  BleManager._();
  static final instance = BleManager._();

  /// All boards advertise this same service UUID.
  static final serviceUuid = Guid('5f1d16a0-046d-47fd-b49a-d6f1ae118f52');

  /// Every board exposes this same characteristic; boards are told apart by
  /// their advertised name: TireESP32-FL, TireESP32-FR, TireESP32-RL, ...
  static final charUuid = Guid('5f1d16a1-046d-47fd-b49a-d6f1ae118f52');

  /// Optional live-measurement characteristic (new ESP-IDF firmware).
  /// Boards without it simply don't report measured values.
  static final pressureCharUuid = Guid('5f1d16a2-046d-47fd-b49a-d6f1ae118f52');

  @override
  final state = ValueNotifier<LinkState>(const LinkState());
  @override
  final message = ValueNotifier<String?>(null);
  @override
  final unackedBoards = ValueNotifier<Set<String>>(const <String>{});
  @override
  final measured = ValueNotifier<Map<String, double>>(const {});

  static const retryDelay = Duration(seconds: 5);

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BluetoothCharacteristic> _chars = {};
  final Map<String, BluetoothCharacteristic> _pressureChars = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>> _subs = {};
  final Map<String, StreamSubscription<List<int>>> _notifySubs = {};
  final Map<String, Timer> _retryTimers = {};
  bool _userDisconnected = false;

  @override
  bool get isConnected => _chars.isNotEmpty;

  @override
  Future<void> connect() async {
    if (state.value.phase != LinkPhase.disconnected) return;
    try {
      _userDisconnected = false;
      
      // FIX: Added Permission.location. Samsung silently returns 0 scan 
      // results without a granted location permission when neverForLocation is omitted.
      final perms = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();
      
      debugPrint('BLE permissions: $perms');
      final denied =
          perms.entries.where((e) => !e.value.isGranted).map((e) => e.key);
      if (denied.isNotEmpty) {
        message.value =
            'Permission denied (${denied.join(", ")}) - allow "Nearby '
            'devices" and "Location" for this app in Settings';
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
      final found = await scanBoards(seconds: 8);
      debugPrint('BLE scan done: boards: ${found.keys.toList()}');

      if (found.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value =
            'No TireESP32-xx found - check the boards are powered and '
            'flashed, and that Bluetooth & Location are on';
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

  /// Scans for TireESP32 boards. Public so the devices screen can use it.
  /// Throws on permission/adapter problems (caller shows the message).
  Future<Map<String, BluetoothDevice>> scanBoards({int seconds = 8}) async {
    final perms = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    debugPrint('BLE permissions: $perms');
    final denied =
        perms.entries.where((e) => !e.value.isGranted).map((e) => e.key);
    if (denied.isNotEmpty) {
      throw Exception(
          'Permission denied (${denied.join(", ")}) - allow "Nearby devices" '
          'and "Location" in Settings');
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
      throw Exception('Bluetooth is turned off');
    }

    final found = <String, BluetoothDevice>{};
    late final StreamSubscription<List<ScanResult>> scanSub;
    scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final key = _keyFromName(name);
        if (key != null && !found.containsKey(key)) {
          debugPrint('BLE board found: "$name"');
          found[key] = r.device;
        }
      }
    });

    // --- SAMSUNG WARM-UP CYCLE ---
    await FlutterBluePlus.startScan(); // no timeout param!
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await FlutterBluePlus.stopScan();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Main scan: unfiltered, name-matched here. Manual lifecycle because
    // some Samsung stacks abort FBP's own timeout parameter instantly.
    await FlutterBluePlus.startScan();
    await FlutterBluePlus.isScanning.where((s) => s).first;
    Timer(Duration(seconds: seconds), () => FlutterBluePlus.stopScan());
    await FlutterBluePlus.isScanning.where((s) => !s).first;

    await scanSub.cancel();
    await FlutterBluePlus.stopScan();

    for (final e in found.entries) {
      _discovered[e.key] = e.value; // remember for manual reconnects
    }
    return found;
  }

  final Map<String, BluetoothDevice> _discovered = {};

  /// Devices seen by the most recent scans, for the devices screen.
  Map<String, BluetoothDevice> get discovered => Map.of(_discovered);

  /// Manually connect one specific board (devices screen).
  Future<void> connectDevice(String key) async {
    if (_chars.containsKey(key)) return;
    var device = _devices[key] ?? _discovered[key];
    device ??= await _findBoard(key);
    if (device == null) {
      message.value = '$key not found - is the board powered?';
      return;
    }
    _devices[key] = device;
    _discovered[key] = device;
    await _link(key, device);
  }

  /// Manually disconnect one specific board without auto-reconnecting it.
  Future<void> disconnectDevice(String key) async {
    final b = _devices[key];
    if (b == null) return;
    _retryTimers.remove(key)?.cancel();
    _suppressRetry.add(key);
    try {
      await b.disconnect();
    } catch (_) {}
    _remove(key);
    _suppressRetry.remove(key);
  }

  final Set<String> _suppressRetry = {};

  Future<void> _link(String key, BluetoothDevice device) async {
    try {
      debugPrint('BLE: Attempting connection to $key (${device.remoteId})...');
      
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
        autoConnect: false, // Forces an immediate active connection attempt
        mtu: null,          // FIX 1: Stops FBP from forcing a 512 MTU that crashes ESP32 stacks
      );

      // FIX 2: Give Samsung's GATT client 500ms to negotiate the connection baseline
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // FIX 3: Ensure the device is actually marked as connected before pulling services
      final currentConnectionState = await device.connectionState.first;
      if (currentConnectionState != BluetoothConnectionState.connected) {
        throw Exception("Device reported connected, but state stream is $currentConnectionState");
      }

      debugPrint('BLE: Connected to $key. Discovering services...');
      final services = await device.discoverServices();

      BluetoothCharacteristic? target;
      BluetoothCharacteristic? pressureChar;
      for (final svc in services) {
        for (final c in svc.characteristics) {
          if (c.uuid == charUuid) target = c;
          if (c.uuid == pressureCharUuid) pressureChar = c;
        }
      }

      if (target == null) {
        debugPrint('BLE: $key missing expected characteristic');
        await device.disconnect();
        return;
      }

      _devices[key] = device;
      _chars[key] = target;
      _retryTimers.remove(key)?.cancel();
      _subs[key]?.cancel();
      _subs[key] = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _remove(key);
      });

      // Live measurements (new firmware only; silently skipped otherwise).
      _notifySubs.remove(key)?.cancel();
      _pressureChars.remove(key);
      if (pressureChar != null) {
        try {
          await pressureChar.setNotifyValue(true);
          _pressureChars[key] = pressureChar;
          _notifySubs[key] = pressureChar.onValueReceived.listen((raw) {
            final v = double.tryParse(
                utf8.decode(raw, allowMalformed: true).trim());
            if (v != null) {
              measured.value = {...measured.value, key: v};
            }
          });
          debugPrint('BLE: live pressure enabled for $key');
        } catch (e) {
          debugPrint('BLE: pressure notify unavailable for $key: $e');
        }
      }

      state.value = state.value.copyWith(tires: {...state.value.tires, key});
      if (state.value.phase == LinkPhase.disconnected) {
        _setPhase(LinkPhase.connected);
      }
      if (unackedBoards.value.contains(key)) {
        unackedBoards.value = {...unackedBoards.value}..remove(key);
      }
      debugPrint('BLE: Successfully ready and linked $key');
    } catch (e) {
      debugPrint('BLE: failed to connect $key: $e');
      // If a connection attempt breaks mid-way, explicitly clean it up
      try { await device.disconnect(); } catch (_) {}
    }

    if (!_chars.containsKey(key)) {
      // Board seen but not linked yet - keep trying in the background.
      _scheduleReconnect(key, device);
    }
  }


  void _scheduleReconnect(String key, BluetoothDevice device) {
    if (_userDisconnected) return;
    // One retry loop per board: replace any pending timer instead of
    // bailing out (the old _devices.containsKey guard silently killed
    // every post-loss reconnect).
    _retryTimers[key]?.cancel();
    _retryTimers[key] = Timer(retryDelay, () async {
      if (_userDisconnected || _chars.containsKey(key)) return;
      debugPrint('BLE: reconnecting $key...');
      // A freshly scanned device object sidesteps the stale-handle
      // status-133 problem; the cached object often never connects again.
      final fresh = await _findBoard(key);
      final target = fresh ?? device;
      if (fresh != null) _devices[key] = fresh;
      await _link(key, target);
    });
  }

  /// Poll-reads the characteristic until it carries this board's ack for
  /// exactly the value we just sent (~1.5 s total, like the webapp).
  Future<bool> _awaitAck(
    String key,
    BluetoothCharacteristic c,
    double want,
  ) async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        final s = utf8.decode(await c.read(), allowMalformed: true).trim();
        debugPrint('BLE [$key] read: "$s"');
        final parts = s.split(':');
        
        // FIX: access the array elements using indices [0], [1], and [2]
        if (parts.length >= 3 &&
            parts[0] == 'ACK' &&
            parts[1].toUpperCase() == key) {
          final v = double.tryParse(parts[2]);
          if (v != null && (v - want).abs() < 0.05) return true;
        }
      } catch (_) {
        // transient read error - keep polling
      }
    }
    return false;
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
    _notifySubs.remove(key)?.cancel();
    _chars.remove(key);
    _pressureChars.remove(key);
    if (measured.value.containsKey(key)) {
      final m = {...measured.value}..remove(key);
      measured.value = m;
    }
    final tires = {...state.value.tires}..remove(key);
    state.value = LinkState(
      phase: tires.isEmpty ? LinkPhase.disconnected : LinkPhase.connected,
      tires: tires,
    );
    final device = _devices[key];
    if (device != null && !_userDisconnected && !_suppressRetry.contains(key)) {
      message.value = '$key lost - auto-reconnecting...';
      // Clear Android's half-dead connection state first; without this the
      // next connect() often fails with status 133 (stale GATT handle).
      () async {
        try {
          await device.disconnect();
        } catch (_) {}
      }();
      _scheduleReconnect(key, device);
    }
    debugPrint('BLE: lost $key');
  }

  @override
  Future<void> reconnectOne(String key) async {
    if (_chars.containsKey(key)) return;
    var device = _devices[key];
    // Never seen this session? Quick 3 s targeted scan to find it.
    device ??= await _findBoard(key);
    if (device == null) {
      message.value = '$key not found - is the board powered?';
      _scheduleReconnectIfKnown(key);
      return;
    }
    debugPrint('BLE: manual reconnect attempt for $key');
    await _link(key, device);
    if (!_chars.containsKey(key)) {
      // keep trying in the background like any other lost board
      _devices[key] = device;
      _scheduleReconnect(key, device);
    }
  }

  void _scheduleReconnectIfKnown(String key) {
    final d = _devices[key];
    if (d != null && !_userDisconnected) _scheduleReconnect(key, d);
  }

  /// Short unfiltered scan that returns just this tire's board (or null).
  Future<BluetoothDevice?> _findBoard(String key) async {
    BluetoothDevice? hit;
    late final StreamSubscription<List<ScanResult>> sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (_keyFromName(name) == key) hit ??= r.device;
      }
    });
    try {
      await FlutterBluePlus.startScan();
      await FlutterBluePlus.isScanning.where((s) => s).first;
      Timer(const Duration(seconds: 3), () => FlutterBluePlus.stopScan());
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (_) {}
    await sub.cancel();
    return hit;
  }

  @override
  Future<void> disconnect() async {
    _userDisconnected = true;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    for (final sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    _chars.clear();
    for (final s in _notifySubs.values) {
      await s.cancel();
    }
    _notifySubs.clear();
    _pressureChars.clear();
    measured.value = const {};
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
    const keys = ['FL', 'FR', 'RL', 'RR'];
    final failed = <String>{};
    final jobs = <Future<void>>[];
    for (final entry in _chars.entries) {
      final k = entry.key;
      final idx = keys.indexOf(k);
      if (idx < 0 || idx >= pressures.length) continue;
      final c = entry.value;
      final want = pressures[idx];
      jobs.add(() async {
        try {
          await c.write(payload);
        } catch (e) {
          debugPrint('BLE write to $k failed: $e');
          failed.add(k);
          return;
        }
        if (!await _awaitAck(k, c, want)) failed.add(k);
      }());
    }
    await Future.wait(jobs);
    unackedBoards.value = failed;
    if (failed.isEmpty) {
      debugPrint('BLE: all boards acknowledged: ${_chars.keys.toList()..sort()}');
    }
  }
}