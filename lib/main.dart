import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// === UUIDs de tu firmware ===
const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String char1Uuid   = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // sintonización
const String char2Uuid   = "ceb5483e-36e1-4688-b7f5-ea07361b26a8"; // offset

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
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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
  StreamSubscription<List<int>>? _subCh1;
  StreamSubscription<List<int>>? _subCh2;

  // Campos de entrada
  final _kp = TextEditingController(text: '2.0');
  final _ti = TextEditingController(text: '0.0');
  final _td = TextEditingController(text: '0.02');
  final _vmax = TextEditingController(text: '1023');
  final _valturb = TextEditingController(text: '150');
  final _offset = TextEditingController(text: '1.0');

  String logCh1 = '';
  String logCh2 = '';
  bool _connecting = false;

  @override
  void dispose() {
    _subCh1?.cancel();
    _subCh2?.cancel();
    _kp.dispose();
    _ti.dispose();
    _td.dispose();
    _vmax.dispose();
    _valturb.dispose();
    _offset.dispose();
    super.dispose();
  }

  /// Pide permisos y verifica condiciones de sistema necesarias para escanear BLE.
  /// En Android 12+ pide SCAN/CONNECT. Además, por compatibilidad con Xiaomi,
  /// pedimos Location y verificamos que el *toggle* de ubicación del sistema esté encendido.
  Future<void> _ensurePerms() async {
    if (!Platform.isAndroid) return;

    // 1) Asegurar Bluetooth encendido
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      try { await FlutterBluePlus.turnOn(); } catch (_) {}
    }

    // 2) Pedir permisos BLE modernos (Android 12+)
    final scan = await Permission.bluetoothScan.request();
    final conn = await Permission.bluetoothConnect.request();

    // 3) (Compat/OEMs como Xiaomi) pide también ubicación en uso
    //    Aunque en 12+ no sería estrictamente necesario, muchos Xiaomi no escanean si
    //    no tienes la ubicación del sistema activada. Pedimos permiso y luego verificamos el toggle.
    final loc = await Permission.locationWhenInUse.request();

    // Si el usuario bloqueó definitivamente alguno, abre Ajustes para que lo habilite
    if (scan.isPermanentlyDenied || conn.isPermanentlyDenied || loc.isPermanentlyDenied) {
      await openAppSettings();
      throw Exception('Debes habilitar permisos en Ajustes para continuar');
    }

    // 4) Verifica que *Ubicación del sistema* esté encendida (requisito de varios OEMs para BLE scan)
    //    Nota: permission_handler permite consultar el servicio de ubicación.
    final service = await Permission.location.serviceStatus;
    if (!service.isEnabled) {
      // No podemos encenderlo desde la app; hay que pedir al usuario que active el toggle del SO.
      throw Exception(
          'Activa la Ubicación del sistema (Xiaomi suele exigirla para escanear BLE). '
              'Abre la barra rápida y enciende "Ubicación", luego reintenta.'
      );
    }

    // 5) Comprobación final
    if (!scan.isGranted || !conn.isGranted) {
      throw Exception('Permisos BLE no concedidos (SCAN/CONNECT)');
    }
    if (!loc.isGranted) {
      // En Android 12+ podría no ser necesario, pero para Xiaomi lo tratamos como requerido para evitar fallos de escaneo.
      throw Exception('Permiso de ubicación no concedido (requerido por tu dispositivo)');
    }
  }

  Future<void> _scanAndConnect() async {
    try {
      setState(() => _connecting = true);
      await _ensurePerms();

      BluetoothDevice? found;
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));

      // Escucha resultados de escaneo
      final subScan = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName; // puede venir vacío a veces
          final uuids = r.advertisementData.serviceUuids; // List<Guid>
          final containsSvc = uuids
              .map((g) => g.toString().toLowerCase())
              .contains(serviceUuid);

          if (name == 'SOLLOW' || containsSvc) {
            found = r.device;
          }
        }
      });

      await Future.delayed(const Duration(seconds: 6));
      await FlutterBluePlus.stopScan();
      await subScan.cancel();

      if (found == null) {
        // Si no encontró, probablemente es el toggle de Ubicación del sistema
        // (muy típico en Xiaomi) o el ESP32 no está anunciando el service UUID.
        throw Exception(
            'No se encontró SOLLOW. Verifica:\n'
                '• Que el ESP32 esté anunciando y cerca\n'
                '• En Xiaomi: que el toggle de Ubicación del sistema esté ENCENDIDO\n'
                '• Reinicia BT si es necesario'
        );
      }

      device = found;
      await device!.connect(timeout: const Duration(seconds: 10));

      final services = await device!.discoverServices();
      final srv = services.firstWhere(
            (s) => s.uuid.toString().toLowerCase() == serviceUuid,
        orElse: () => throw Exception('Servicio no hallado en el dispositivo'),
      );

      ch1 = srv.characteristics.firstWhere(
            (c) => c.uuid.toString().toLowerCase() == char1Uuid,
      );
      ch2 = srv.characteristics.firstWhere(
            (c) => c.uuid.toString().toLowerCase() == char2Uuid,
      );

      if (ch1!.properties.notify) {
        await ch1!.setNotifyValue(true);
        _subCh1 = ch1!.lastValueStream.listen((data) {
          setState(() => logCh1 = utf8.decode(data, allowMalformed: true));
        });
      }
      if (ch2!.properties.notify) {
        await ch2!.setNotifyValue(true);
        _subCh2 = ch2!.lastValueStream.listen((data) {
          setState(() => logCh2 = utf8.decode(data, allowMalformed: true));
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Conectado a SOLLOW')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _sendTuning() async {
    if (ch1 == null) return;
    final msg = '*${_kp.text},${_ti.text},${_td.text},${_vmax.text},${_valturb.text}';
    await ch1!.write(utf8.encode(msg), withoutResponse: false);
  }

  Future<void> _sendOffset() async {
    if (ch2 == null) return;
    await ch2!.write(utf8.encode(_offset.text), withoutResponse: false);
  }

  Future<void> _disconnect() async {
    try {
      await _subCh1?.cancel();
      await _subCh2?.cancel();
      if (device != null) await device!.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      device = null;
      ch1 = null;
      ch2 = null;
      logCh1 = '';
      logCh2 = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final connected = device != null && ch1 != null && ch2 != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SOLLOW BLE Tuner'),
        actions: [
          if (connected)
            IconButton(
              onPressed: _disconnect,
              icon: const Icon(Icons.link_off),
              tooltip: 'Desconectar',
            )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ElevatedButton.icon(
            onPressed: _connecting ? null : _scanAndConnect,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(_connecting ? 'Conectando...' : 'Buscar y Conectar'),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Parámetros PID / Vmax / ValTurb',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
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
                  FilledButton(
                    onPressed: connected ? _sendTuning : null,
                    child: const Text('Enviar PID + Vmax + ValTurb'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Offset', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _numField('Offset', _offset),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: connected ? _sendOffset : null,
                    child: const Text('Enviar Offset'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Notificaciones CH1', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(logCh1.isEmpty ? '—' : logCh1, style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Notificaciones CH2', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(logCh2.isEmpty ? '—' : logCh2, style: const TextStyle(fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return SizedBox(
      width: 140,
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}
