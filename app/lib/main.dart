import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'devices_screen.dart';
import 'link.dart';
import 'toast.dart';

void main() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FLUTTER ERROR: ${details.exception}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('UNCAUGHT ERROR: $error\n$stack');
    return true;
  };
  runApp(const TireApp());
}

class Tire {
  const Tire(this.name, this.pressure);

  final String name;
  final double pressure;

  Tire copyWith({double? pressure}) => Tire(name, pressure ?? this.pressure);
}

class TireApp extends StatelessWidget {
  const TireApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tire Pressure Control',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const OverviewScreen(),
    );
  }
}

class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  final List<Tire> _tires = [
    const Tire('FL', 2.3),
    const Tire('FR', 2.3),
    const Tire('RL', 2.5),
    const Tire('RR', 2.5),
  ];

  @override
  void initState() {
    super.initState();
    LinkManager.instance.message.addListener(_showBleMessage);
    if (kDebugMode) {
      Future.delayed(const Duration(seconds: 3), () {
        if (LinkManager.instance.state.value.phase == LinkPhase.disconnected) {
          LinkManager.instance.connect();
        }
      });
    }
  }

  void _showBleMessage() {
    final msg = LinkManager.instance.message.value;
    if (msg == null || !mounted) return;
    LinkManager.instance.message.value = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    LinkManager.instance.message.removeListener(_showBleMessage);
    super.dispose();
  }

  double get _average =>
      _tires.map((t) => t.pressure).reduce((a, b) => a + b) / _tires.length;

  Future<void> _editPressure({int? index}) async {
    final isAll = index == null;
    final linked = LinkManager.instance.state.value.tires;
    if (isAll) {
      final missing = [
        for (final t in _tires)
          if (!linked.contains(t.name)) t.name,
      ];
      if (missing.isNotEmpty) {
        _notify('Not linked: ${missing.join(", ")} - connect first');
        return;
      }
    } else {
      final name = _tires[index].name;
      if (!linked.contains(name)) {
        _notify('$name is not linked - trying to reconnect...');
        LinkManager.instance.reconnectOne(name);
        return;
      }
    }
    final result = await Navigator.push<double>(
      context,
      MaterialPageRoute(
        builder: (_) => PressureEditScreen(
          title: isAll ? 'All Tires' : 'Tire ${_tires[index].name}',
          initialPressure: isAll ? _average : _tires[index].pressure,
        ),
      ),
    );
    if (result == null) return;
    final old = [for (final t in _tires) t.pressure];
    setState(() {
      if (isAll) {
        for (var i = 0; i < _tires.length; i++) {
          _tires[i] = _tires[i].copyWith(pressure: result);
        }
      } else {
        _tires[index] = _tires[index].copyWith(pressure: result);
      }
    });
    // One message with every pressure, fixed order FL,FR,RL,RR:
    // "2.4,3.4,1.2,2.5". Boards pick their own slot by TIRE_ID.
    await LinkManager.instance.sendPressures([
      for (final t in _tires) t.pressure,
    ]);
    // A board that never confirmed never applied the value - roll its
    // tile back so the screen shows what the hardware is actually doing.
    final unacked = LinkManager.instance.unackedBoards.value;
    if (unacked.isNotEmpty) {
      setState(() {
        for (var i = 0; i < _tires.length; i++) {
          if (unacked.contains(_tires[i].name)) {
            _tires[i] = _tires[i].copyWith(pressure: old[i]);
          }
        }
      });
      _notify('No confirmation from: ${unacked.toList()..sort()} - '
          'value reverted');
    }
  }

  void _notify(String msg) {
    showAppToast(msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Tire Pressure'),
        actions: [
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DevicesScreen()),
            ),
            icon: const Icon(Icons.sensors),
            tooltip: 'ESP32 devices',
          ),
          const _LinkButton(),
        ],
      ),
      body: Stack(
        children: [
          Column(
        children: [
          ValueListenableBuilder<Set<String>>(
            valueListenable: LinkManager.instance.unackedBoards,
            builder: (context, unacked, _) {
              if (unacked.isEmpty) return const SizedBox.shrink();
              return _warningBanner(unacked.toList()..sort());
            },
          ),
          Expanded(
            child: Center(
              child: ListenableBuilder(
                listenable: LinkManager.instance.state,
                builder: (context, _) => AspectRatio(
                  aspectRatio: 379 / 212,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final s = constraints.maxWidth / 379;
                      return Stack(
                        children: [
                          _buildVehicle(s),
                          _buildSetAllButton(s),
                          _tireAt(s, 'FL', 68, 42),
                          _tireAt(s, 'FR', 281, 42),
                          _tireAt(s, 'RL', 68, 138),
                          _tireAt(s, 'RR', 281, 138),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
        // Single-slot toast: newest message replaces the old one, floats
        // above the content without blocking interaction.
        Positioned(
          left: 24,
          right: 24,
          bottom: 24,
          child: const AppToast(),
        ),
        ],
      ),
    );
  }

  Widget _warningBanner(List<String> boards) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.error,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.warning_amber_rounded, color: scheme.onError),
        title: Text(
          'No confirmation from: ${boards.join(", ")}',
          style: TextStyle(color: scheme.onError),
        ),
        subtitle: Text(
          'Check the board(s), then send again',
          style: TextStyle(color: scheme.onError.withValues(alpha: 0.8)),
        ),
        trailing: IconButton(
          icon: Icon(Icons.close, color: scheme.onError),
          onPressed:
              () => LinkManager.instance.unackedBoards.value = const {},
        ),
      ),
    );
  }

  Widget _buildVehicle(double s) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 114 * s,
      top: 6 * s,
      width: 150 * s,
      height: 200 * s,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12 * s),
              border: Border.all(color: scheme.primary, width: 1.5 * s),
            ),
          ),
          Positioned(left: 5 * s, top: 5 * s, child: _mount(s)),
          Positioned(right: 5 * s, top: 5 * s, child: _mount(s)),
          Positioned(left: 5 * s, bottom: 5 * s, child: _mount(s)),
          Positioned(right: 5 * s, bottom: 5 * s, child: _mount(s)),
        ],
      ),
    );
  }

  Widget _mount(double s) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 9 * s,
      height: 18 * s,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(3 * s),
      ),
    );
  }

  Widget _buildSetAllButton(double s) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 128 * s,
      top: 74 * s,
      width: 122 * s,
      height: 64 * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _editPressure(),
          borderRadius: BorderRadius.circular(10 * s),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10 * s),
              border: Border.all(color: scheme.primary, width: 1.5 * s),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FittedBox(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8 * s),
                    child: Text(
                      'SET ALL',
                      style: TextStyle(
                        fontSize: (14 * s).clamp(14, 24),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 3,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                ),
                FittedBox(
                  child: Text(
                    'avg ${_average.toStringAsFixed(1)} bar',
                    style: TextStyle(
                      fontSize: (10 * s).clamp(10, 14),
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tireAt(double s, String name, double x, double y) {
    final scheme = Theme.of(context).colorScheme;
    final tire = _tires.firstWhere((t) => t.name == name);
    final linked = LinkManager.instance.state.value.tires.contains(name);
    return Positioned(
      left: x * s,
      top: y * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _editPressure(index: _tires.indexOf(tire)),
          borderRadius: BorderRadius.circular(6 * s),
          child: Opacity(
            opacity: linked ? 1.0 : 0.35,
            child: Column(
            children: [
              Container(
                width: 30 * s,
                height: 30 * s,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6 * s),
                  border: Border.all(color: scheme.primary, width: 1.5 * s),
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontSize: (13 * s).clamp(12, 22),
                          fontWeight: FontWeight.bold,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 3 * s,
                      right: 3 * s,
                      width: 5 * s,
                      height: 5 * s,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              linked
                                  ? Colors.greenAccent
                                  : scheme.outlineVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 4 * s),
              // Live measurement when the board reports one (new firmware),
              // otherwise the last commanded value.
              ValueListenableBuilder<Map<String, double>>(
                valueListenable: LinkManager.instance.measured,
                builder: (context, measured, _) {
                  final live = measured[name];
                  final shown =
                      live != null ? '${live.toStringAsFixed(2)} bar' : '${tire.pressure.toStringAsFixed(1)} bar';
                  return Text(
                    shown,
                    style: TextStyle(
                      fontSize: (11 * s).clamp(11, 15),
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                },
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

class PressureEditScreen extends StatefulWidget {
  const PressureEditScreen({
    super.key,
    required this.title,
    required this.initialPressure,
  });

  final String title;
  final double initialPressure;

  @override
  State<PressureEditScreen> createState() => _PressureEditScreenState();
}

class _PressureEditScreenState extends State<PressureEditScreen> {
  late double _pressure = widget.initialPressure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const Spacer(),
              Text(
                _pressure.toStringAsFixed(1),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w300,
                  color: scheme.primary,
                  height: 1.0,
                ),
              ),
              Text(
                'bar',
                style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              Slider(
                value: _pressure,
                min: 1.0,
                max: 4.0,
                divisions: 30,
                label: '${_pressure.toStringAsFixed(1)} bar',
                onChanged: (value) => setState(() => _pressure = value),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('1.0', style: TextStyle(color: scheme.onSurfaceVariant)),
                    Text('4.0', style: TextStyle(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, _pressure),
                        child: const Text('OK'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LinkManager.instance.state,
      builder: (context, _) {
        final state = LinkManager.instance.state.value;
        final (icon, tooltip) = switch (state.phase) {
          LinkPhase.connected => (
            Icons.bluetooth_connected,
            'Connected: ${state.tires.toList()..sort()} - tap to disconnect',
          ),
          LinkPhase.scanning || LinkPhase.connecting => (
            Icons.bluetooth_searching,
            'Connecting...',
          ),
          LinkPhase.disconnected => (
            Icons.bluetooth_disabled,
            'Connect ESP32 boards',
          ),
        };
        return IconButton(
          onPressed: () {
            if (LinkManager.instance.isConnected) {
              LinkManager.instance.disconnect();
            } else if (state.phase == LinkPhase.disconnected) {
              LinkManager.instance.connect();
            }
          },
          icon: Icon(icon),
          tooltip: tooltip,
        );
      },
    );
  }
}
