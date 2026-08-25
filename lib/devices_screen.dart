import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble.dart';
import 'link.dart';

/// ESP32 connection screen: scan, see every board with its state,
/// connect/disconnect individual boards, and watch live link status.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}
class _DevicesScreenState extends State<DevicesScreen> {
  bool _scanning = false;
  String? _error;
  Map<String, BluetoothDevice> _results = {};
  String? _busyKey; // row currently mid-connect/disconnect

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
      if (!mounted) return;
      setState(() => _results = found);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _toggle(String key) async {
    final linked = _ble.state.value.tires.contains(key);
    setState(() => _busyKey = key);
    try {
      if (linked) {
        await _ble.disconnectDevice(key);
      } else {
        await _ble.connectDevice(key);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$key: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
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
          return ValueListenableBuilder<Map<String, double>>(
            valueListenable: _ble.measured,
            builder: (context, measured, _) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Connected (${linkState.tires.length})',
                      style: TextStyle(
                          color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  for (final key in linkState.tires.toList()..sort())
                    ListTile(
                      leading:
                          const Icon(Icons.check_circle, color: Colors.green),
                      title: Text('TireESP32-$key'),
                      subtitle: Text(measured.containsKey(key)
                          ? '${measured[key]!.toStringAsFixed(2)} bar - connected'
                          : 'connected'),
                      trailing: _busyKey == key
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton(
                              onPressed: () => _toggle(key),
                              child: const Text('Disconnect'),
                            ),
                    ),
                  if (linkState.tires.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('None yet - pick a board below.'),
                    ),
                  const Divider(height: 32),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Row(
                      children: [
                        Text('Available boards',
                            style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600)),
                        if (_scanning) ...[
                          const SizedBox(width: 12),
                          const SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!,
                          style: TextStyle(color: scheme.error)),
                    ),
                  for (final entry in _results.entries.where((e) =>
                      !linkState.tires.contains(e.key)))
                    ListTile(
                      leading: Icon(Icons.bluetooth_searching,
                          color: scheme.onSurfaceVariant),
                      title: Text('TireESP32-${entry.key}'),
                      subtitle: Text(entry.value.remoteId.str),
                      trailing: _busyKey == entry.key
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : FilledButton(
                              onPressed: () => _toggle(entry.key),
                              child: const Text('Connect'),
                            ),
                    ),
                  if (_results.isEmpty && !_scanning && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child:
                          Text('No boards seen. Power them on and rescan.'),
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
}

