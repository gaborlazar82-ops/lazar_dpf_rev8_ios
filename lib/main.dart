import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LazarDpfApp());
}

class LazarDpfApp extends StatelessWidget {
  const LazarDpfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lazar DPF Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        cardColor: const Color(0xFF161B22),
      ),
      home: const DpfDashboardScreen(),
    );
  }
}

class DpfDashboardScreen extends StatefulWidget {
  const DpfDashboardScreen({super.key});

  @override
  State<DpfDashboardScreen> createState() => _DpfDashboardScreenState();
}

class _DpfDashboardScreenState extends State<DpfDashboardScreen> {
  // Telemetriai mért értékek
  String soot = "-";
  String regen = "-";
  String stateVal = "-";
  String dp = "-";
  String egt = "-";
  String eot = "-";
  String statusMessage = "Bluetooth keresése...";
  bool isConnected = false;

  // BLE vezérlők
  BluetoothDevice? connectedDevice;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;
  StreamSubscription<List<int>>? characteristicSubscription;
  final StringBuffer _rxBuffer = StringBuffer();
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    startBleScan();
  }

  void startBleScan() async {
    setState(() => statusMessage = "Eszköz keresése (LAZAR_DPF)...");

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

      scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          String devName = r.device.platformName;
          if (devName == "LAZAR_DPF" || devName.contains("XM-15") || devName.contains("DPF")) {
            await FlutterBluePlus.stopScan();
            connectToDevice(r.device);
            break;
          }
        }
      });
    } catch (e) {
      setState(() => statusMessage = "Hiba a kereséskor: $e");
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    setState(() => statusMessage = "Csatlakozás: ${device.platformName}...");
    connectedDevice = device;

    try {
      await device.connect(autoConnect: true);
      setState(() {
        isConnected = true;
        statusMessage = "Csatlakozva";
      });

      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            isConnected = false;
            statusMessage = "Kapcsolat megszakadt, újracsatlakozás...";
            resetMetrics();
          });
          startBleScan();
        }
      });

      // Karakterisztikák felderítése és feliratkozás az adatokra
      List<BluetoothService> services = await device.discoverServices();
      for (BluetoothService service in services) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          if (characteristic.properties.notify || characteristic.properties.indicate) {
            await characteristic.setNotifyValue(true);
            characteristicSubscription = characteristic.lastValueStream.listen((data) {
              onDataReceived(data);
            });
          }
        }
      }
    } catch (e) {
      setState(() => statusMessage = "Csatlakozási hiba: $e");
    }
  }

  void onDataReceived(List<int> bytes) {
    if (bytes.isEmpty) return;
    String chunk = utf8.decode(bytes, allowMalformed: true);
    _rxBuffer.write(chunk);

    String content = _rxBuffer.toString();
    if (content.contains('\n')) {
      List<String> lines = content.split('\n');
      for (int i = 0; i < lines.length - 1; i++) {
        String line = lines[i].trim();
        if (line.isNotEmpty) {
          parseIncomingMessage(line);
        }
      }
      _rxBuffer.clear();
      _rxBuffer.write(lines.last);
    }
  }

  void parseIncomingMessage(String rawLine) {
    if (!rawLine.contains(";")) return;

    try {
      List<String> parts = rawLine.split(";");
      int alertCode = 0;

      for (String part in parts) {
        List<String> kv = part.split(":");
        if (kv.length >= 2) {
          String key = kv[0].trim();
          String val = kv.sublist(1).join(":").trim();

          if (key.toUpperCase() == "SOOT") {
            soot = (val == "-1") ? "-" : val;
          } else if (key.toUpperCase() == "REGEN") {
            regen = (val == "-1") ? "-" : (val == "1" ? "BE" : "KI");
          } else if (key.toUpperCase() == "STATE") {
            stateVal = (val == "-1") ? "-" : val;
          } else if (key.toUpperCase() == "ALERT") {
            alertCode = int.tryParse(val) ?? 0;
          } else if (key.toUpperCase() == "L2") {
            extractL2Metrics(val);
          }
        }
      }

      if (alertCode > 0 && isConnected) {
        triggerSoundAlert(alertCode);
      }

      setState(() {});
    } catch (_) {}
  }

  void extractL2Metrics(String l2Str) {
    List<String> segments = l2Str.split(",");
    for (String seg in segments) {
      String s = seg.trim();
      if (s.startsWith("Dp") && s.contains("Kpa")) {
        dp = s.replaceAll("Dp", "").replaceAll("Kpa", "").trim();
      } else if (s.startsWith("EGT") && s.contains("°C")) {
        egt = s.replaceAll("EGT", "").replaceAll("°C", "").trim();
      } else if (s.startsWith("EOT") && s.contains("°C")) {
        eot = s.replaceAll("EOT", "").replaceAll("°C", "").trim();
      }
    }
  }

  void triggerSoundAlert(int alertCode) async {
    int beeps = (alertCode == 1) ? 3 : 2;
    for (int i = 0; i < beeps; i++) {
      try {
        await _audioPlayer.play(AssetSource('beep.mp3'));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  void resetMetrics() {
    soot = "-";
    regen = "-";
    stateVal = "-";
    dp = "-";
    egt = "-";
    eot = "-";
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    connectionSubscription?.cancel();
    characteristicSubscription?.cancel();
    connectedDevice?.disconnect();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isRegenOn = regen == "BE";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Lazar DPF Monitor"),
        centerTitle: true,
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                statusMessage,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isConnected ? const Color(0xFF3FB950) : const Color(0xFFD29922),
                ),
              ),
            ),
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.3,
                children: [
                  _buildCard("Korom (Soot)", soot != "-" ? "$soot %" : "-", const Color(0xFF58A6FF)),
                  _buildCard(
                    "Regeneráció",
                    regen,
                    isRegenOn ? const Color(0xFFFF3D00) : const Color(0xFF3FB950),
                    isEmphasized: isRegenOn,
                  ),
                  _buildCard("Folyamat", stateVal != "-" ? "$stateVal %" : "-", const Color(0xFF3FB950)),
                  _buildCard("Diff. nyomás (Dp)", dp != "-" ? "$dp kPa" : "-", const Color(0xFF3FB950)),
                  _buildCard("Kipufogó (EGT2)", egt != "-" ? "$egt °C" : "-", const Color(0xFFD29922)),
                  _buildCard("Motorolaj (EOT)", eot != "-" ? "$eot °C" : "-", const Color(0xFF58A6FF)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String title, String value, Color valueColor, {bool isEmphasized = false}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isEmphasized ? const Color(0xFFFF3D00) : const Color(0xFF232B36),
          width: isEmphasized ? 2 : 1,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF8B949E))),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: valueColor),
          ),
        ],
      ),
    );
  }
}