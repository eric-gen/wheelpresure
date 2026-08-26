import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble.dart';
import 'toast.dart';
import 'link.dart';

/// ESP32 connection screen.
///
/// Shows every discovered board with its state, lets you connect /
/// disconnect individual boards, and - for brand new boards - choose which
/// tire they control. The assignment is stored on the phone AND on the
/// board itself, so it only ever happens once per board.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _scanning = false;
  String? _error;
  String? _busyKey;
  final Set<String> _assigning = {};
  Map<String, BluetoothDevice> _results = {};

  /// Every board ever seen in this session - boards that disappear
  /// (powered off, out of range) stay listed as offline with Connect.
  final Map<String, BluetoothDevice> _seen = {};

  BleManager get _ble => BleManager.instance;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final found = await _ble.scanBoards(seconds: 6);
      if (mounted) {
        setState(() {
          _results = found;
          _seen.addAll(found);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _toggle(String key) async {
    final linked = _ble.state.value.tires.contains(_ble.tireOf(key)) &&
        _ble.tireOf(key) != null;
    setState(() => _busyKey = key);
    try {
      if (linked) {
        await _ble.disconnectDevice(key);
      } else {
        await _ble.connectDevice(key);
      }
    } catch (e) {
      if (mounted) showAppToast('$key: $e');
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _assign(String key, String tire) async {
    setState(() => _assigning.add(key));
    final ok = await _ble.assignTire(key, tire);
    if (!ok && mounted) showAppToast('Assigning $key to $tire failed');
    if (mounted) setState(() => _assigning.remove(key));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32 Devices'),
        actions: [
          IconButton(
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.refresh),
            tooltip: 'Scan again',
          ),
        ],
      ),
      body: ValueListenableBuilder<LinkState>(
        valueListenable: _ble.state,
        builder: (context, linkState, _) {
          return ValueListenableBuilder<Set<String>>(
            valueListenable: _ble.pendingAssign,
            builder: (context, pending, _) {
              // Merge scan results + boards we know from earlier sessions.
              final known = <String>{
                ..._seen.keys,
                ..._results.keys,
                ..._ble.discovered.keys,
              }
                  .where((k) => !linkState.tires.contains(_ble.tireOf(k)))
                  .toList()
                ..sort();

              return ListView(
                children: [
                  const SectionHeader('Connected'),
                  if (linkState.tires.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('None yet - connect a board below.'),
                    ),
                  for (final tire in linkState.tires.toList()..sort())
                    ValueListenableBuilder<Map<String, double>>(
                      valueListenable: _ble.measured,
                      builder: (context, measured, _) => ListTile(
                        leading:
                            const Icon(Icons.check_circle, color: Colors.green),
                        title: Text('Tire $tire'),
                        subtitle: Text(measured.containsKey(tire)
                            ? '${measured[tire]!.toStringAsFixed(2)} bar - connected'
                            : 'connected'),
                        trailing: _busyRow(tire),
                      ),
                    ),

                  const Divider(height: 32),
                  const SectionHeader('New board? Choose its tire'),
                  for (final key in pending)
                    Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Board $key',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final tire in const ['FL', 'FR', 'RL', 'RR'])
                                  OutlinedButton(
                                    onPressed: _assigning.contains(key)
                                        ? null
                                        : () => _assign(key, tire),
                                    child: Text(tire),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                  const Divider(height: 32),
                  SectionHeader(
                    _scanning ? 'Scanning...' : 'All boards',
                    trailing: _scanning
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, style: TextStyle(color: scheme.error)),
                    ),
                  for (final key in known)
                    Builder(builder: (context) {
                      final dev = _results[key] ??
                          _seen[key] ??
                          _ble.discovered[key];
                      final online = _results.containsKey(key);
                      return ListTile(
                        leading: Icon(
                          online
                              ? Icons.bluetooth_searching
                              : Icons.bluetooth_disabled,
                          color: online
                              ? scheme.onSurfaceVariant
                              : scheme.outlineVariant,
                        ),
                        title: Text('TireESP32-$key'),
                        subtitle: Text(
                          '${dev?.remoteId.str ?? ''}'
                          '${online ? '' : ' - offline'}',
                        ),
                        trailing: _busyRow(key) ??
                            (pending.contains(key)
                                ? null
                                : OutlinedButton(
                                    onPressed: () => _toggle(key),
                                    child: const Text('Connect'),
                                  )),
                      );
                    }),
                  if (known.isEmpty && pending.isEmpty && !_scanning)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No boards seen. Power them on and rescan.'),
                    ),
                  const SizedBox(height: 24),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget? _busyRow(String id) {
    if (_busyKey != id && !_assigning.contains(id)) {
      return null;
    }
    return const SizedBox(
        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text(title,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600)),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
  }
}
