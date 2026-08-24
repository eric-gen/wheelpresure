import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ble.dart';
import 'classic_manager.dart';

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

  bool get isConnected;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> sendPressures(List<double> pressures);

  static final LinkManager instance = _pick();

  static LinkManager _pick() {
    if (Platform.isIOS) return BleManager.instance;
    return ClassicManager.instance;
  }
}
