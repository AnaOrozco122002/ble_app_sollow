import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// === UUIDs del firmware ===
const String serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
const String char1Uuid   = "beb5483e-36e1-4688-b7f5-ea07361b26a8"; // sintonización (READ/WRITE)
const String char2Uuid   = "ceb5483e-36e1-4688-b7f5-ea07361b26a8"; // offset/estado/umbrales (WRITE) + lecturas (READ)

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.deepPurple);
    return MaterialApp(
      title: 'SOLLOW BLE Tuner',
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        cardTheme: const CardTheme(
          margin: EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(18))),
          elevation: 1.2,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: const OutlineInputBorder(),
          isDense: true,
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.2),
          bodyMedium: TextStyle(fontSize: 14),
          labelLarge: TextStyle(fontWeight: FontWeight.w600),
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

  // NUEVO: suscripción al estado de conexión
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // Entradas (escritura)
  final _kp = TextEditingController(text: '2.0');
  final _ti = TextEditingController(text: '0.0');
  final _td = TextEditingController(text: '0.02');
  final _vmax = TextEditingController(text: '1023');
  final _valturb = TextEditingController(text: '150');
  final _ktur = TextEditingController(text: '0.6'); // NUEVO KTurb
  final _offset = TextEditingController(text: '1.0');

  // NUEVO: umbrales QTR
  final _thOn  = TextEditingController(text: '250');
  final _thOff = TextEditingController(text: '180');

  // Lecturas (crudo)
  String lastParamsRaw = '—'; // snapshot crudo CH1
  String lastSensorRaw = '—'; // snapshot crudo CH2

  // Valores parseados para UI
  String pKp = '—', pTi = '—', pTd = '—', pVmax = '—', pValTurb = '—', pOffset = '—', pKTurb = '—';
  String sSalida = '—', sRaw = '—', sThOn = '—', sThOff = '—';

  bool _connecting = false;
  bool get _connected => device != null && ch1 != null && ch2 != null;

  // === Handler para desconexión automática ===
  void _handlePeripheralDisconnected() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('SOLLOW se desconectó')),
    );
    setState(() {
      device = null;
      ch1 = null;
      ch2 = null;
      lastParamsRaw = '—';
      lastSensorRaw = '—';
      pKp = pTi = pTd = pVmax = pValTurb = pOffset = pKTurb = '—';
      sSalida = sRaw = sThOn = sThOff = '—';
    });
    try { _connSub?.cancel(); } catch (_) {}
    _connSub = null;
  }

  @override
  void dispose() {
    try { _connSub?.cancel(); } catch (_) {}
    _connSub = null;

    _kp.dispose(); _ti.dispose(); _td.dispose(); _vmax.dispose();
    _valturb.dispose(); _ktur.dispose(); _offset.dispose();
    _thOn.dispose(); _thOff.dispose();
    super.dispose();
  }

  // ================== Permisos / Conexión ==================
  Future<void> _ensurePerms() async {
    if (!Platform.isAndroid) return;

    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      try { await FlutterBluePlus.turnOn(); } catch (_) {}
    }

    final scan = await Permission.bluetoothScan.request();
    final conn = await Permission.bluetoothConnect.request();
    final loc  = await Permission.locationWhenInUse.request();

    if (scan.isPermanentlyDenied || conn.isPermanentlyDenied || loc.isPermanentlyDenied) {
      await openAppSettings();
      throw Exception('Debes habilitar permisos en Ajustes para continuar');
    }

    final service = await Permission.location.serviceStatus;
    if (!service.isEnabled) {
      throw Exception('Activa “Ubicación” del sistema (algunos equipos la requieren para escanear BLE).');
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
          if (name == 'SOLLOW' || containsSvc) found = r.device;
        }
      });

      await Future.delayed(const Duration(seconds: 6));
      await FlutterBluePlus.stopScan();
      await subScan.cancel();

      if (found == null) {
        throw Exception('No se encontró SOLLOW. Verifica que anuncie cerca y que “Ubicación” esté activa.');
      }

      device = found;
      await device!.connect(timeout: const Duration(seconds: 10));

      try { await device!.requestMtu(185); } catch (_) {}

      // === SUSCRIPCIÓN AL ESTADO DE CONEXIÓN ===
      try {
        await _connSub?.cancel();
      } catch (_) {}
      _connSub = device!.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _handlePeripheralDisconnected();
        }
      });

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

      await _readSensor();
      await _readParams();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    // Cancela listener antes de desconectar manualmente
    try { await _connSub?.cancel(); } catch (_) {}
    _connSub = null;

    try { if (device != null) await device!.disconnect(); } catch (_) {}
    if (!mounted) return;
    setState(() {
      device = null; ch1 = null; ch2 = null;
      lastParamsRaw = '—'; lastSensorRaw = '—';
      pKp = pTi = pTd = pVmax = pValTurb = pOffset = pKTurb = '—';
      sSalida = sRaw = sThOn = sThOff = '—';
    });
  }

  // ================== Writes ==================
  Future<void> _sendTuning() async {
    if (ch1 == null) return;
    final msg = '*${_kp.text},${_ti.text},${_td.text},${_vmax.text},${_valturb.text},${_ktur.text}\n';
    try {
      await ch1!.write(utf8.encode(msg), withoutResponse: false).timeout(const Duration(seconds: 2));
      await _readParams(); // confirmar
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH1: $e')));
    }
  }

  Future<void> _sendOffset() async {
    if (ch2 == null) return;
    try {
      await ch2!.write(utf8.encode('OFFSET=${_offset.text}\n'), withoutResponse: false).timeout(const Duration(seconds: 2));
      await _readParams(); // refleja offset
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH2 (offset): $e')));
    }
  }

  Future<void> _sendEstado(int v) async {
    if (ch2 == null) return;
    try {
      await ch2!.write(utf8.encode('ESTADO=$v\n'), withoutResponse: false).timeout(const Duration(seconds: 2));
      await _readSensor(); // feedback
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH2 (estado): $e')));
    }
  }

  // NUEVO: enviar umbrales QTR
  Future<void> _sendThresholds() async {
    if (ch2 == null) return;
    final thOn  = _thOn.text.trim();
    final thOff = _thOff.text.trim();
    try {
      await ch2!.write(utf8.encode('TH_ON=$thOn\n'),  withoutResponse: false)
          .timeout(const Duration(seconds: 2));
      await ch2!.write(utf8.encode('TH_OFF=$thOff\n'), withoutResponse: false)
          .timeout(const Duration(seconds: 2));
      await _readSensor(); // refrescar snapshot con th_on/th_off
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Write CH2 (umbrales): $e')));
    }
  }

  // ================== Reads ==================
  Future<void> _readParams() async {
    if (ch1 == null) return;
    try {
      final data = await ch1!.read();
      final s = utf8.decode(data, allowMalformed: true);
      setState(() { lastParamsRaw = s.isEmpty ? '—' : s; _parseParams(s); });
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
      setState(() { lastSensorRaw = s.isEmpty ? '—' : s; _parseSensor(s); });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Read CH2: $e')));
    }
  }

  // ================== Parsers ==================
  Map<String, String> _kvToMap(String s) {
    final out = <String, String>{};
    if (s.trim().isEmpty || s == '—') return out;
    for (final part in s.split(',')) {
      final kv = part.split('=');
      if (kv.length == 2) out[kv[0].trim()] = kv[1].trim();
    }
    return out;
  }

  void _parseParams(String s) {
    final m = _kvToMap(s);
    pKp      = m['kp']     ?? '—';
    pTi      = m['ti']     ?? '—';
    pTd      = m['td']     ?? '—';
    pVmax    = m['vmax']   ?? '—';
    pValTurb = m['valturb']?? '—';
    pOffset  = m['offset'] ?? '—';
    pKTurb   = m['ktur']   ?? '—';
  }

  void _parseSensor(String s) {
    final m = _kvToMap(s);
    sSalida = m['salida'] ?? '—';
    sRaw    = m['raw']    ?? '—';
    sThOn   = m['th_on']  ?? '—';
    sThOff  = m['th_off'] ?? '—';
  }

  // ======= Helpers de UI =======
  Widget _sectionTitle(String title, {IconData? icon}) {
    return Row(
      children: [
        if (icon != null) Icon(icon, size: 22),
        if (icon != null) const SizedBox(width: 8),
        Flexible(child: Text(title, style: Theme.of(context).textTheme.titleLarge, overflow: TextOverflow.ellipsis)),
      ],
    );
  }

  Widget _kvTile(String k, String v, {double? width}) {
    final cs = Theme.of(context).colorScheme;
    final tile = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(k, style: TextStyle(fontWeight: FontWeight.w700, color: cs.onPrimaryContainer))),
          const SizedBox(width: 12),
          Text(v,
              style: TextStyle(fontFeatures: const [FontFeature.tabularFigures()], fontWeight: FontWeight.w600, color: cs.onPrimaryContainer),
              overflow: TextOverflow.ellipsis, maxLines: 1, softWrap: false),
        ],
      ),
    );
    if (width != null) return SizedBox(width: width, child: tile);
    return tile;
  }

  Widget _monoBox(String title, String body) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cs.primaryContainer.withOpacity(0.25), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        SelectableText(body, style: const TextStyle(fontFamily: 'monospace'), maxLines: 4),
      ]),
    );
  }

  Widget _numField(String label, TextEditingController c) {
    return ConstrainedBox(
      constraints: const BoxConstraints.tightFor(width: 160),
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: label),
        maxLines: 1,
      ),
    );
  }

  // ================== UI ==================
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SOLLOW BLE Tuner'),
        backgroundColor: cs.primary, foregroundColor: cs.onPrimary,
        actions: [
          if (_connected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: cs.onPrimary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: cs.onPrimary.withOpacity(0.25)),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.bluetooth_connected, size: 16),
                    SizedBox(width: 6),
                    Text('Conectado'),
                  ]),
                ),
              ),
            ),
          if (_connected)
            IconButton(onPressed: _disconnect, icon: const Icon(Icons.link_off), tooltip: 'Desconectar'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_connected)
            FilledButton.icon(
              onPressed: _connecting ? null : _scanAndConnect,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(_connecting ? 'Conectando…' : 'Buscar y Conectar'),
            ),

          // ===== 1) Lectura del sensor (PRIMERO) =====
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Lecturas del sensor', icon: Icons.sensors),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _kvTile('salida (norm.)', sSalida, width: 220),
                  _kvTile('raw (ponderado)', sRaw, width: 220),
                  _kvTile('TH_ON', sThOn, width: 140),
                  _kvTile('TH_OFF', sThOff, width: 140),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 12, children: [
                  FilledButton.icon(onPressed: _connected ? _readSensor : null, icon: const Icon(Icons.download), label: const Text('Leer sensor')),
                  if (_connected)
                    TextButton.icon(
                        onPressed: () async { for (int i=0;i<5;i++){ await _readSensor(); await Future.delayed(const Duration(milliseconds: 150)); } },
                        icon: const Icon(Icons.timelapse), label: const Text('Sondeo x5')),
                ]),
                const SizedBox(height: 8),
                _monoBox('Snapshot crudo', lastSensorRaw),
              ]),
            ),
          ),

          // ===== 2) Parámetros (Lectura) =====
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Parámetros (lectura)', icon: Icons.visibility),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  _kvTile('Kp', pKp, width: 140),
                  _kvTile('Ti', pTi, width: 140),
                  _kvTile('Td', pTd, width: 140),
                  _kvTile('Vmax', pVmax, width: 140),
                  _kvTile('ValTurb', pValTurb, width: 160),
                  _kvTile('KTurb', pKTurb, width: 140),
                  _kvTile('Offset', pOffset, width: 160),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 12, children: [
                  OutlinedButton.icon(onPressed: _connected ? _readParams : null, icon: const Icon(Icons.refresh), label: const Text('Actualizar snapshot')),
                  if (_connected)
                    TextButton.icon(
                        onPressed: () async { await _readParams(); await Future.delayed(const Duration(milliseconds: 200)); await _readParams(); },
                        icon: const Icon(Icons.bolt), label: const Text('Refresco rápido')),
                ]),
                const SizedBox(height: 8),
                _monoBox('Snapshot crudo', lastParamsRaw),
              ]),
            ),
          ),

          // ===== 3) Parámetros (Escritura, incluye KTurb) =====
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Parámetros (escritura PID / Vmax / ValTurb / KTurb)', icon: Icons.tune),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _numField('Kp', _kp),
                  _numField('Ti', _ti),
                  _numField('Td', _td),
                  _numField('Vmax', _vmax),
                  _numField('ValTurb', _valturb),
                  _numField('KTurb', _ktur),
                ]),
                const SizedBox(height: 14),
                FilledButton.icon(onPressed: _connected ? _sendTuning : null, icon: const Icon(Icons.send), label: const Text('Enviar')),
              ]),
            ),
          ),

          // ===== 4) Estado =====
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Estado', icon: Icons.power_settings_new),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  OutlinedButton.icon(onPressed: _connected ? () => _sendEstado(1) : null, icon: const Icon(Icons.play_arrow), label: const Text('Iniciar (BLE=1)')),
                  OutlinedButton.icon(onPressed: _connected ? () => _sendEstado(0) : null, icon: const Icon(Icons.stop), label: const Text('Detener (BLE=0)')),
                ]),
                const SizedBox(height: 6),
                Text('Nota: si controlas ESTADO por BLE, puedes comentar la lectura del botón físico en el firmware.',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ),

          // ===== 5) Offset =====
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Offset', icon: Icons.horizontal_rule),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _numField('Offset', _offset)),
                  const SizedBox(width: 12),
                  FilledButton.icon(onPressed: _connected ? _sendOffset : null, icon: const Icon(Icons.save), label: const Text('Enviar Offset')),
                ]),
              ]),
            ),
          ),

          // ===== 6) Umbrales QTR (TH_ON / TH_OFF) =====
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sectionTitle('Umbrales QTR (histéresis)', icon: Icons.tune),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  _numField('TH_ON (0..1000)', _thOn),
                  _numField('TH_OFF (0..1000)', _thOff),
                ]),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _connected ? _sendThresholds : null,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Enviar umbrales'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Consejo: mantén TH_OFF < TH_ON para evitar parpadeos al perder/recuperar línea.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
