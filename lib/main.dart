import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// === UUIDs de tu firmware ===
const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String char1Uuid   = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // sintonización (READ/WRITE)
const String char2Uuid   = "ceb5483e-36e1-4688-b7f5-ea07361b26a8"; // offset/estado (WRITE) y lecturas sensor (READ)

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SOLLOW BLE Tuner',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontWeight: FontWeight.w700),
          bodyMedium: TextStyle(fontSize: 14),
        ),
        cardTheme: const CardTheme(
          margin: EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          elevation: 1,
        ),
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothDevice? device;
  BluetoothCharacteristic? ch1;
  BluetoothCharacteristic? ch2;

  // Campos de entrada
  final _kp = TextEditingController(text: '2.0');
  final _ti = TextEditingController(text: '0.0');
  final _td = TextEditingController(text: '0.02');
  final _vmax = TextEditingController(text: '1023');
  final _valturb = TextEditingController(text: '150');
  final _offset = TextEditingController(text: '1.0');

  String lastParams = '—'; // READ de CH1
  String lastSensor = '—'; // READ de CH2
  bool _connecting = false;

  bool get _connected => device != null && ch1 != null && ch2 != null;

  @override
  void dispose() {
    _kp.dispose();
    _ti.dispose();
    _td.dispose();
    _vmax.dispose();
    _valturb.dispose();
    _offset.dispose();
    super.dispose();
  }

  Future<void> _ensurePerms() async {
    if (!Platform.isAndroid) return;

    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      try { await FlutterBluePlus.turnOn(); } catch (_) {}
    }

    final scan = await Permission.bluetoothScan.request();
    final conn = await Permission.bluetoothConnect.request();
    final loc = await Permission.locationWhenInUse.request();

    if (scan.isPermanentlyDenied || conn.isPermanentlyDenied || loc.isPermanentlyDenied) {
      await openAppSettings();
      throw Exception('Debes habilitar permisos en Ajustes para continuar');
    }

    final service = await Permission.location.serviceStatus;
    if (!service.isEnabled) {
      throw Exception('Activa la Ubicación del sistema (requerido por algunos OEMs para escanear BLE).');
    }

    if (!scan.isGranted || !conn.isGranted || !loc.isGranted) {
      throw Exception('Permisos BLE/Ubicación no concedidos');
    }
  }

  Future<void> _scanAndConnect() async {
    try {
      setState(() => _connecting = true);
      await _ensurePerms();

      BluetoothDevice? found;
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

      final subScan = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName;
          final uuids = r.advertisementData.serviceUuids;
          final containsSvc = uuids.map((g) => g.toString().toLowerCase()).contains(serviceUuid);
          if (name == 'SOLLOW' || containsSvc) {
            found = r.device;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 6));
      await FlutterBluePlus.stopScan();
      await subScan.cancel();

      if (found == null) {
        throw Exception('No se encontró SOLLOW. Verifica que esté anunciando, cerca y con Ubicación del sistema activa.');
      }

      device = found;
      await device!.connect(timeout: const Duration(seconds: 10));

      // MTU alto antes de discoverServices
      try { await device!.requestMtu(185); } catch (_) {}

      final services = await device!.discoverServices();
      final srv = services.firstWhere(
            (s) => s.uuid.toString().toLowerCase() == serviceUuid,
        orElse: () => throw Exception('Servicio no hallado en el dispositivo'),
      );

      ch1 = srv.characteristics.firstWhere((c) => c.uuid.toString().toLowerCase() == char1Uuid);
      ch2 = srv.characteristics.firstWhere((c) => c.uuid.toString().toLowerCase() == char2Uuid);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conectado a SOLLOW')),
        );
      }

      // Lee snapshots iniciales
      await _readParams();
      await _readSensor();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      if (device != null) await device!.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      device = null;
      ch1 = null;
      ch2 = null;
      lastParams = '—';
      lastSensor = '—';
    });
  }

  // ---------- Writes ----------
  Future<void> _sendTuning() async {
    if (ch1 == null) return;
    final msg = '*${_kp.text},${_ti.text},${_td.text},${_vmax.text},${_valturb.text}\n';
    try {
      await ch1!.write(utf8.encode(msg), withoutResponse: false)
          .timeout(const Duration(seconds: 2));
      await _readParams(); // confirma en snapshot
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH1: $e')));
    }
  }

  Future<void> _sendOffset() async {
    if (ch2 == null) return;
    try {
      await ch2!.write(utf8.encode('OFFSET=${_offset.text}\n'), withoutResponse: false)
          .timeout(const Duration(seconds: 2));
      await _readParams(); // refleja offset
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH2 (offset): $e')));
    }
  }

  Future<void> _sendEstado(int v) async {
    if (ch2 == null) return;
    try {
      await ch2!.write(utf8.encode('ESTADO=$v\n'), withoutResponse: false)
          .timeout(const Duration(seconds: 2));
      // leer sensor para ver movimiento/feedback
      await _readSensor();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH2 (estado): $e')));
    }
  }

  // ---------- Reads ----------
  Future<void> _readParams() async {
    if (ch1 == null) return;
    try {
      final data = await ch1!.read();
      final s = utf8.decode(data, allowMalformed: true);
      setState(() => lastParams = s.isEmpty ? '—' : s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Read CH1: $e')));
    }
  }

  Future<void> _readSensor() async {
    if (ch2 == null) return;
    try {
      final data = await ch2!.read();
      final s = utf8.decode(data, allowMalformed: true);
      setState(() => lastSensor = s.isEmpty ? '—' : s);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Read CH2: $e')));
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SOLLOW BLE Tuner'),
        actions: [
          if (_connected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.bluetooth_connected, size: 16),
                      SizedBox(width: 6),
                      Text('Conectado'),
                    ],
                  ),
                ),
              ),
            ),
          if (_connected)
            IconButton(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              tooltip: 'Desconectar',
            ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!_connected)
                ElevatedButton.icon(
                  onPressed: _connecting ? null : _scanAndConnect,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: Text(_connecting ? 'Conectando...' : 'Buscar y Conectar'),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Parámetros PID / Vmax / ValTurb', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _numField('Kp', _kp),
                          _numField('Ti', _ti),
                          _numField('Td', _td),
                          _numField('Vmax', _vmax),
                          _numField('ValTurb', _valturb),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _connected ? _sendTuning : null,
                            icon: const Icon(Icons.send),
                            label: const Text('Enviar'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: _connected ? _readParams : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Leer parámetros'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _monoBox(context, 'Snapshot', lastParams),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Offset y Estado', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _numField('Offset', _offset),
                          FilledButton.icon(
                            onPressed: _connected ? _sendOffset : null,
                            icon: const Icon(Icons.tune),
                            label: const Text('Enviar Offset'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: _connected ? () => _sendEstado(1) : null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Iniciar (ESTADO=1)'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _connected ? () => _sendEstado(0) : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('Detener (ESTADO=0)'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Lecturas del Sensor', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: _connected ? _readSensor : null,
                            icon: const Icon(Icons.sensors),
                            label: const Text('Leer sensor'),
                          ),
                          const SizedBox(width: 12),
                          if (_connected)
                            TextButton.icon(
                              onPressed: () async {
                                // sondeo rápido 5 lecturas
                                for (int i = 0; i < 5; i++) {
                                  await _readSensor();
                                  await Future.delayed(const Duration(milliseconds: 150));
                                }
                              },
                              icon: const Icon(Icons.timelapse),
                              label: const Text('Sondeo x5'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _monoBox(context, 'Última lectura', lastSensor),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return ConstrainedBox(
      constraints: const BoxConstraints.tightFor(width: 150),
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        maxLines: 1,
      ),
    );
  }

  Widget _monoBox(BuildContext context, String title, String body) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          // Evita overflow con SelectableText + soft wrap + maxLines razonable
          SelectableText(
            body,
            style: const TextStyle(fontFamily: 'monospace'),
            maxLines: 5,
          ),
        ],
      ),
    );
  }
}
