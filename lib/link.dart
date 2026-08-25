import 'package:flutter/foundation.dart';

import 'ble.dart';

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

/// Common interface for both transports so the UI never cares which is in
/// use. Android uses Bluetooth Classic SPP; iOS only allows BLE.
abstract class LinkManager {
  ValueNotifier<LinkState> get state;
  ValueNotifier<String?> get message;
  ValueNotifier<Set<String>> get unackedBoards;

  /// Live measured pressure per linked tire (tire id -> bar). Boards with
  /// the a2 characteristic push this every ~2 s; empty when unavailable.
  ValueNotifier<Map<String, double>> get measured;

  bool get isConnected;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> sendPressures(List<double> pressures);

  /// Try to reconnect one specific tire immediately (tap on a dim tile).
  Future<void> reconnectOne(String key);

  static final LinkManager instance = _pick();

  static LinkManager _pick() {
    // BLE everywhere now: one firmware (READ|WRITE characteristic with
    // read-back ACKs) serves Android and iOS alike. ClassicManager stays
    // available for the old SPP firmware if ever needed.
    return BleManager.instance;
  }
}
