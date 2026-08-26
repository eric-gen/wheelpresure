import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'link.dart';

/// Bluetooth LE transport - used on every platform.
///
/// Identity model:
/// * Boards advertise as "TireESP32-" followed by a unique suffix. That
///   suffix (the device key) is just a hardware label - it is NOT the tire.
/// * The first time a board connects, the app asks which tire it is
///   ([assignTire]). That choice is stored twice: on the phone
///   (SharedPreferences) and on the board itself (NVS, via ASSIGN command),
///   so both sides remember across restarts.
/// * [state].tires and [measured] are keyed by TIRE NAME (FL..RR); every
///   internal map here is keyed by device key.
class BleManager implements LinkManager {
  BleManager._();
  static final instance = BleManager._();

  /// All boards advertise this same service UUID.
  static final serviceUuid = Guid('5f1d16a0-046d-47fd-b49a-d6f1ae118f52');

  /// Command characteristic: app writes CSV targets or "ASSIGN:TIRE";
  /// the board stores "ACK:ID:bar" / "ACK:ID:0" as its readable value.
  static final charUuid = Guid('5f1d16a1-046d-47fd-b49a-d6f1ae118f52');

  /// Live-measurement characteristic (new ESP-IDF firmware): "%.2f".
  static final pressureCharUuid = Guid('5f1d16a2-046d-47fd-b49a-d6f1ae118f52');

  @override
  final state = ValueNotifier<LinkState>(const LinkState());
  @override
  final message = ValueNotifier<String?>(null);
  @override
  final unackedBoards = ValueNotifier<Set<String>>(const <String>{});
  @override
  final measured = ValueNotifier<Map<String, double>>(const {});

  /// Boards that are connected but have no tire assigned yet.
  final pendingAssign = ValueNotifier<Set<String>>(const <String>{});

  /// Device keys currently in the auto-reconnect loop (top banner shows this).
  final reconnecting = ValueNotifier<Set<String>>(const <String>{});

  void _setReconnecting(String key, bool active) {
    final s = {...reconnecting.value};
    if (active) {
      s.add(key);
    } else {
      s.remove(key);
    }
    reconnecting.value = s;
  }

  static const retryDelay = Duration(seconds: 5);

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, BluetoothCharacteristic> _chars = {};
  final Map<String, BluetoothCharacteristic> _pressureChars = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>> _subs = {};
  final Map<String, StreamSubscription<List<int>>> _notifySubs = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, String> _keyToTire = {};
  final Set<String> _suppressRetry = {};
  bool _userDisconnected = false;
  SharedPreferences? _prefs;

  /// Devices seen by scans, for the devices screen (device key -> device).
  final Map<String, BluetoothDevice> _discovered = {};
  Map<String, BluetoothDevice> get discovered => Map.of(_discovered);

  /// Tire name currently assigned to a device key (or null).
  String? tireOf(String deviceKey) => _keyToTire[deviceKey];

  /// Device key that controls the given tire (or null).
  String? keyForTire(String tire) {
    for (final e in _keyToTire.entries) {
      if (e.value == tire) return e.key;
    }
    return null;
  }

  Future<SharedPreferences> get _settings async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  bool get isConnected => _chars.isNotEmpty;

  /// Device key = MAC address (never changes, even when a board renames
  /// itself after tire assignment). _names keeps the advertised label.
  final Map<String, String> _names = {};

  String labelOf(String key) {
    final n = _names[key];
    return (n == null || n.isEmpty) ? 'ESP32 $key' : n;
  }

  void _registerTire(String key, String tire) {
    // One board per tire: drop any previous claim on this tire.
    _keyToTire.removeWhere((k, t) {
      if (t == tire && k != key) return true;
      return false;
    });
    _keyToTire[key] = tire;
    final tires = {...state.value.tires, tire};
    state.value = LinkState(
      phase: LinkPhase.connected,
      tires: tires,
    );
  }

  /* ---------------------------------------------------------------- */
  /* connect / scan                                                    */
  /* ---------------------------------------------------------------- */

  @override
  Future<void> connect() async {
    if (state.value.phase != LinkPhase.disconnected &&
        state.value.phase != LinkPhase.connected) {
      return;
    }
    try {
      _userDisconnected = false;
      final found = await scanBoards(seconds: 8);
      debugPrint('BLE scan done: boards: ${found.keys.toList()}');

      if (found.isEmpty) {
        _setPhase(LinkPhase.disconnected);
        message.value =
            'No TireESP32 boards found - power them on and rescan';
        return;
      }

      if (state.value.phase == LinkPhase.disconnected) {
        _setPhase(LinkPhase.connecting);
      }
      for (final entry in found.entries) {
        await _link(entry.key, entry.value);
      }
      if (_chars.isEmpty && state.value.phase == LinkPhase.connecting) {
        _setPhase(LinkPhase.disconnected);
        message.value = 'Boards seen, but none accepted a connection';
        return;
      }
      if (_chars.isNotEmpty) {
        _setPhase(LinkPhase.connected);
      }
    } catch (e) {
      debugPrint('BLE connect failed: $e');
      _setPhase(LinkPhase.disconnected);
      message.value = 'Connection failed: $e';
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
    if (adapter != BluetoothAdapterState.on) {
      throw Exception('Bluetooth is turned off');
    }

    final found = <String, BluetoothDevice>{};
    final seenNames = <String>{};
    late final StreamSubscription<List<ScanResult>> scanSub;
    scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        // Debug aid: log every advertiser once per scan.
        final label = name.isEmpty ? '(no name)' : name;
        if (seenNames.add(label)) {
          debugPrint('BLE heard: "$label" ${r.device.remoteId.str}');
        }
        if (!name.startsWith('WHC-') && !name.startsWith('TireESP32-')) {
          continue;
        }
        final key = r.device.remoteId.str; // MAC: stable identity
        if (name.isNotEmpty) _names[key] = name;
        if (!found.containsKey(key)) {
          debugPrint('BLE board found: "$name" ($key)');
          found[key] = r.device;
        }
      }
    });

    // --- SAMSUNG WARM-UP CYCLE ---
    await FlutterBluePlus.startScan();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await FlutterBluePlus.stopScan();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Main scan: manual lifecycle because some Samsung stacks abort FBP's
    // own timeout parameter instantly.
    await FlutterBluePlus.startScan();
    await FlutterBluePlus.isScanning.where((s) => s).first;
    Timer(Duration(seconds: seconds), () => FlutterBluePlus.stopScan());
    await FlutterBluePlus.isScanning.where((s) => !s).first;

    await scanSub.cancel();
    await FlutterBluePlus.stopScan();

    _discovered.addAll(found);
    return found;
  }

  /* ---------------------------------------------------------------- */
  /* linking                                                           */
  /* ---------------------------------------------------------------- */

  Future<void> _link(String key, BluetoothDevice device) async {
    try {
      debugPrint('BLE: Attempting connection to $key (${device.remoteId})...');

      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
        autoConnect: false,
        mtu: null, // no forced MTU: crashes some ESP32 stacks
      );

      // Give Samsung's GATT client a moment to settle, then verify.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final cs = await device.connectionState.first;
      if (cs != BluetoothConnectionState.connected) {
        throw Exception('connection dropped during setup ($cs)');
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

      _discovered[key] = device;
      _devices[key] = device;
      _chars[key] = target;
      _retryTimers.remove(key)?.cancel();
      _setReconnecting(key, false);
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
            final v =
                double.tryParse(utf8.decode(raw, allowMalformed: true).trim());
            if (v == null) return;
            final tire = _keyToTire[key];
            if (tire != null) {
              measured.value = {...measured.value, tire: v};
            }
          });
        } catch (e) {
          debugPrint('BLE: pressure notify unavailable for $key: $e');
        }
      }

      // Tire assignment: known -> register; unknown -> ask the user.
      final saved = (await _settings).getString('assign_$key');
      if (saved != null && saved.isNotEmpty) {
        _registerTire(key, saved);
        debugPrint('BLE: $key is tire $saved');
      } else {
        pendingAssign.value = {...pendingAssign.value, key};
        message.value =
            'New board $key connected - choose its tire on the devices screen';
        debugPrint('BLE: $key needs tire assignment');
      }

      if (unackedBoards.value.contains(key)) {
        unackedBoards.value = {...unackedBoards.value}..remove(key);
      }
      debugPrint('BLE: Successfully ready and linked $key');
    } catch (e) {
      debugPrint('BLE: failed to connect $key: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }

    if (!_chars.containsKey(key)) {
      _scheduleReconnect(key, device);
    }
  }

  /* ---------------------------------------------------------------- */
  /* assignment                                                        */
  /* ---------------------------------------------------------------- */

  /// Persists which tire a board controls: sent to the board (NVS) and
  /// stored locally. Returns false when the board did not confirm.
  Future<bool> assignTire(String deviceKey, String tire) async {
    final c = _chars[deviceKey];
    if (c == null) {
      message.value = '$deviceKey is not connected';
      return false;
    }
    try {
      await c.write(utf8.encode('ASSIGN:$tire'));
    } catch (e) {
      message.value = 'Assignment write failed: $e';
      return false;
    }
    // Board confirms with ACK:<tire>:0 as its readable value.
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        final s = utf8.decode(await c.read(), allowMalformed: true).trim();
        if (s == 'ACK:$tire:0') {
          await (await _settings).setString('assign_$deviceKey', tire);
          pendingAssign.value = {...pendingAssign.value}..remove(deviceKey);
          _registerTire(deviceKey, tire);
          message.value = '$deviceKey is now tire $tire';
          debugPrint('BLE: assigned $deviceKey -> $tire');
          return true;
        }
      } catch (_) {}
    }
    message.value = 'Board did not confirm the assignment - try again';
    return false;
  }

  /* ---------------------------------------------------------------- */
  /* manual controls (devices screen)                                  */
  /* ---------------------------------------------------------------- */

  /// Manually connect one specific board (device key).
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
    _setReconnecting(key, false);
    _suppressRetry.add(key);
    try {
      await b.disconnect();
    } catch (_) {}
    _remove(key);
    _suppressRetry.remove(key);
  }

  /* ---------------------------------------------------------------- */
  /* auto-reconnect                                                    */
  /* ---------------------------------------------------------------- */

  void _scheduleReconnect(String key, BluetoothDevice device) {
    if (_userDisconnected) return;
    _retryTimers[key]?.cancel();
    _setReconnecting(key, true);
    _retryTimers[key] = Timer(retryDelay, () async {
      if (_userDisconnected || _chars.containsKey(key)) return;
      debugPrint('BLE: reconnecting $key...');
      // Freshly scanned object sidesteps Android's stale-handle error 133.
      final fresh = await _findBoard(key);
      final target = fresh ?? device;
      if (fresh != null) _devices[key] = fresh;
      await _link(key, target);
    });
  }

  /// Short unfiltered scan that returns one board (or null).
  Future<BluetoothDevice?> _findBoard(String key) async {
    BluetoothDevice? hit;
    late final StreamSubscription<List<ScanResult>> sub;
    sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.remoteId.str == key) hit ??= r.device;
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
  Future<void> reconnectOne(String tire) async {
    final key = _keyToTire.entries
        .where((e) => e.value == tire)
        .map((e) => e.key)
        .firstOrNull;
    if (key == null) {
      message.value =
          '$tire has never been linked - use the devices screen first';
      return;
    }
    if (_chars.containsKey(key)) return;
    var device = _devices[key] ?? _discovered[key];
    device ??= await _findBoard(key);
    if (device == null) {
      message.value = '$tire not found - is the board powered?';
      final d = _devices[key];
      if (d != null) _scheduleReconnect(key, d);
      return;
    }
    debugPrint('BLE: manual reconnect attempt for $tire');
    _devices[key] = device;
    await _link(key, device);
    if (!_chars.containsKey(key)) {
      _scheduleReconnect(key, device);
    }
  }

  /* ---------------------------------------------------------------- */
  /* teardown                                                          */
  /* ---------------------------------------------------------------- */

  void _setPhase(LinkPhase phase) =>
      state.value = state.value.copyWith(phase: phase);

  void _remove(String key) {
    _subs.remove(key)?.cancel();
    _notifySubs.remove(key)?.cancel();
    _chars.remove(key);
    _pressureChars.remove(key);
    final tire = _keyToTire[key];
    if (tire != null && measured.value.containsKey(tire)) {
      final m = {...measured.value}..remove(tire);
      measured.value = m;
    }
    final tires = {...state.value.tires}..remove(tire);
    state.value = LinkState(
      phase: tires.isEmpty ? LinkPhase.disconnected : LinkPhase.connected,
      tires: tires,
    );
    final device = _devices[key];
    if (device != null && !_userDisconnected && !_suppressRetry.contains(key)) {
      final label = tire ?? key;
      message.value = '$label lost - auto-reconnecting...';
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
  Future<void> disconnect() async {
    _userDisconnected = true;
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    reconnecting.value = const {};
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
    pendingAssign.value = const <String>{};
    _keyToTire.clear();
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

  /* ---------------------------------------------------------------- */
  /* sending                                                           */
  /* ---------------------------------------------------------------- */

  @override
  Future<void> sendPressures(List<double> pressures) async {
    if (!isConnected || pressures.isEmpty) return;
    // One CSV message for everyone, fixed order FL,FR,RL,RR. Each board
    // applies the slot of its assigned tire and confirms with an ACK.
    final payload =
        pressures.map((p) => p.toStringAsFixed(1)).join(',').codeUnits;
    const order = ['FL', 'FR', 'RL', 'RR'];
    final failed = <String>{};
    final jobs = <Future<void>>[];
    for (final entry in _chars.entries) {
      final key = entry.key;
      final tire = _keyToTire[key];
      if (tire == null || !order.contains(tire)) continue; // unassigned
      final idx = order.indexOf(tire);
      if (idx >= pressures.length) continue;
      final c = entry.value;
      final want = pressures[idx];
      jobs.add(() async {
        try {
          await c.write(payload);
        } catch (e) {
          debugPrint('BLE write to $tire failed: $e');
          failed.add(tire);
          return;
        }
        if (!await _awaitAck(key, tire, c, want)) failed.add(tire);
      }());
    }
    await Future.wait(jobs);
    unackedBoards.value = failed;
    if (failed.isEmpty) {
      debugPrint('BLE: all boards acknowledged');
    }
  }

  /// Poll-reads the characteristic until it carries this board's ack for
  /// exactly the value we just sent (~1.5 s total).
  Future<bool> _awaitAck(
    String key,
    String tire,
    BluetoothCharacteristic c,
    double want,
  ) async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        final s = utf8.decode(await c.read(), allowMalformed: true).trim();
        final parts = s.split(':');
        if (parts.length >= 3 &&
            parts[0] == 'ACK' &&
            parts[1].toUpperCase() == tire.toUpperCase()) {
          final v = double.tryParse(parts[2]);
          if (v != null && (v - want).abs() < 0.05) return true;
        }
      } catch (_) {
        // transient read error - keep polling
      }
    }
    return false;
  }
}
