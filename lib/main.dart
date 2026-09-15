import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
      ),
      home: const HandDashboard(),
    );
  }
}

// ─────────────────────────────────────────────
// SESSION LOGGER MODEL
// ─────────────────────────────────────────────
class SessionLog {
  final DateTime timestamp;
  final Map<String, double> peakValues; 
  final int durationSeconds;

  SessionLog({
    required this.timestamp,
    required this.peakValues,
    required this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'peakValues': peakValues,
        'durationSeconds': durationSeconds,
      };

  factory SessionLog.fromJson(Map<String, dynamic> j) => SessionLog(
        timestamp: DateTime.parse(j['timestamp']),
        peakValues: Map<String, double>.from(
            (j['peakValues'] as Map).map((k, v) => MapEntry(k, (v as num).toDouble()))),
        durationSeconds: j['durationSeconds'] ?? 0,
      );

  static double toDegrees(double flexPercent) => flexPercent * 0.9;
}

class SessionLogger {
  static const _key = 'kino_session_logs';

  static Future<List<SessionLog>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    return raw.map((s) => SessionLog.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> save(SessionLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_key) ?? [];
    existing.add(jsonEncode(log.toJson()));
    if (existing.length > 50) existing.removeAt(0);
    await prefs.setStringList(_key, existing);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

// ─────────────────────────────────────────────
// MAIN DASHBOARD
// ─────────────────────────────────────────────
class HandDashboard extends StatefulWidget {
  const HandDashboard({super.key});
  @override
  State<HandDashboard> createState() => _HandDashboardState();
}

class _HandDashboardState extends State<HandDashboard>
    with TickerProviderStateMixin {

  bool isScanning = false;
  bool isConnected = false;
  BluetoothDevice? esp32Device;
  StreamSubscription? _connectionSub;
  StreamSubscription? _dataSub;
  StreamSubscription? _scanSub;

  late AnimationController _pulseController;
  late AnimationController _glowController;
  late AnimationController _heartbeatController; 

  String _displayedAnimation = "Index_Flex";
  String _candidateAnimation = "Index_Flex";
  Timer? _animDebounce;
  static const int _holdMs = 250; 
  Key _modelKey = UniqueKey(); 

  String statusMessage = "Tap CONNECT to start";
  bool _bleReady = false;

  final Map<String, double> sensorValues = {
    "Thumb": 0, "Index": 0, "Middle": 0, "Ring": 0, "Little": 0,
  };

  DateTime? _sessionStart;
  bool isRecording = false;
  final Map<String, double> _sessionPeak = {
    "Thumb": 0, "Index": 0, "Middle": 0, "Ring": 0, "Little": 0,
  };
  List<SessionLog> _allLogs = [];

  int currentBPM = 0;
  bool showBPM = false; 

  static const Map<String, String> _animationNames = {
    "Thumb":  "Thumb_Flex",
    "Index":  "Index_Flex",
    "Middle": "Middle_Flex.001",
    // TRYING .001 FOR THE RING FINGER BASED ON BLENDER IMAGE
    "Ring":   "Ring_Flex", 
    "Little": "Little_Flex",
  };

  static const Map<String, Color> _fingerColors = {
    "Thumb":  Color(0xFF00FFCC),
    "Index":  Color(0xFF7B2FFF),
    "Middle": Color(0xFFFF6B35),
    "Ring":   Color(0xFFFFD700),
    "Little": Color(0xFFFF2D78),
  };

  static const Map<String, IconData> _fingerIcons = {
    "Thumb":  Icons.thumb_up_alt_rounded,
    "Index":  Icons.touch_app_rounded,
    "Middle": Icons.pan_tool_alt_rounded,
    "Ring":   Icons.circle_rounded,
    "Little": Icons.warning_rounded,
  };

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _glowController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))..repeat(reverse: true);
    _heartbeatController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400))..repeat(reverse: true);
    
    _waitForBluetooth();
    _loadLogs(); 
  }

  void _loadLogs() async {
    final logs = await SessionLogger.load();
    if (mounted) setState(() => _allLogs = logs);
  }

  void _toggleRecording() {
    setState(() {
      if (isRecording) {
        _endSession();
        isRecording = false;
      } else {
        _startSession();
        isRecording = true;
      }
    });
  }

  void _startSession() {
    _sessionStart = DateTime.now();
    _sessionPeak.updateAll((_, __) => 0);
    _showSnack("Recording Attempt...", const Color(0xFF00FFCC));
  }

  void _updatePeak(Map<String, double> current) {
    if (!isRecording) return;
    current.forEach((k, v) {
      
      if (v > (_sessionPeak[k] ?? 0)) _sessionPeak[k] = v;
    });
  }

  void _endSession() async {
    if (_sessionStart == null) return;
    final dur = DateTime.now().difference(_sessionStart!).inSeconds;
    
    if (dur >= 2) {
      final log = SessionLog(
        timestamp: _sessionStart!,
        peakValues: Map.from(_sessionPeak),
        durationSeconds: dur,
      );
      await SessionLogger.save(log);
      _allLogs = await SessionLogger.load();
      _openLogSheet(); 
    }
    
    _sessionStart = null;
    if (mounted) setState(() {});
  }

  void _openLogSheet() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SessionLogSheet(logs: _allLogs),
    );
  }

  void _waitForBluetooth() async {
    await Future.delayed(const Duration(seconds: 1));
    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (mounted) {
        setState(() {
          _bleReady = state == BluetoothAdapterState.on;
          if (!_bleReady) statusMessage = "Enable Bluetooth first";
        });
      }
      FlutterBluePlus.adapterState.listen((s) {
        if (mounted) {
          setState(() {
            _bleReady = s == BluetoothAdapterState.on;
            if (!_bleReady && !isConnected) {
              statusMessage = "Bluetooth turned off";
              isScanning = false;
            }
          });
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _animDebounce?.cancel();
    _pulseController.dispose();
    _glowController.dispose();
    _heartbeatController.dispose();
    _connectionSub?.cancel();
    _dataSub?.cancel();
    _scanSub?.cancel();
    esp32Device?.disconnect();
    super.dispose();
  }

  void _updateAnimation(String newAnim) {
    if (newAnim == _displayedAnimation) return;
    if (newAnim == _candidateAnimation) return;

    _candidateAnimation = newAnim;
    _animDebounce?.cancel();
    _animDebounce = Timer(const Duration(milliseconds: _holdMs), () {
      if (mounted && _candidateAnimation != _displayedAnimation) {
        setState(() {
          _displayedAnimation = _candidateAnimation;
          _modelKey = UniqueKey(); 
        });
      }
    });
  }

  String _getDominantFinger() {
    String currentDomFinger = "Index";
    _animationNames.forEach((key, val) {
      if (val == _displayedAnimation) currentDomFinger = key;
    });

    String bestFinger = currentDomFinger;
    double scoreToBeat = (sensorValues[currentDomFinger] ?? 0.0) + 12.0; 

    sensorValues.forEach((key, val) {
      
      if (key == currentDomFinger) return;

      if (val > scoreToBeat) {
        scoreToBeat = val; 
        bestFinger = key;
      }
    });

    if ((sensorValues[bestFinger] ?? 0) < 15.0) return "HOLD"; 
    return bestFinger;
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited
    );

    if (!allGranted) {
      _showSnack("Grant all permissions in Settings", const Color(0xFFFF2D78));
      await Future.delayed(const Duration(seconds: 1));
      await openAppSettings();
      return false;
    }
    return true;
  }

  void startBLEScan() async {
    if (isScanning || isConnected) return;
    if (!await _requestPermissions()) return;

    final btState = await FlutterBluePlus.adapterState.first;
    if (btState != BluetoothAdapterState.on) {
      _showSnack("Turn ON Bluetooth first!", const Color(0xFFFF6B35));
      return;
    }

    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));

    if (mounted) {
      setState(() {
        isScanning = true;
        statusMessage = "Scanning for ESP32...";
      });
    }

    bool found = false;
    _scanSub?.cancel();

    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (found) return;
      for (final r in results) {
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : r.advertisementData.advName;

        if (name == "SDV_Glove_ESP32") {
          found = true;
          _scanSub?.cancel();
          FlutterBluePlus.stopScan().then((_) {
            Future.delayed(const Duration(milliseconds: 400), () {
              connectToGlove(r.device);
            });
          });
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: false,
      );
    } catch (e) {
      if (mounted) setState(() { isScanning = false; statusMessage = "Scan failed: $e"; });
      return;
    }

    await Future.delayed(const Duration(seconds: 16));
    if (mounted && !found && !isConnected) {
      setState(() {
        isScanning = false;
        statusMessage = "Not found. Is glove powered ON?";
      });
      _showSnack("SDV_Glove_ESP32 not found", const Color(0xFFFF6B35));
    }
  }

  void connectToGlove(BluetoothDevice device) async {
    if (!mounted) return;
    setState(() => statusMessage = "Connecting...");

    try {
      if (device.isConnected) {
        await device.disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);
      await Future.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      setState(() {
        esp32Device = device;
        isConnected = true;
        isScanning = false;
        statusMessage = "Connected — discovering...";
      });

      _connectionSub?.cancel();
      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          if (isRecording) _endSession(); 
          setState(() {
            isConnected = false;
            esp32Device = null;
            statusMessage = "Disconnected. Tap to reconnect.";
            isRecording = false;
            currentBPM = 0;
            showBPM = false; 
          });
          _dataSub?.cancel();
          _showSnack("Glove disconnected", const Color(0xFFFF2D78));
        }
      });

      try { await device.requestMtu(185); } catch (e) {}
      await Future.delayed(const Duration(milliseconds: 300));

      final services = await device.discoverServices();
      bool charFound = false;

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() == "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
          for (final char in svc.characteristics) {
            if (char.uuid.toString().toLowerCase() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
              charFound = true;
              await char.setNotifyValue(true);
              await Future.delayed(const Duration(milliseconds: 200));

              if (mounted) setState(() => statusMessage = "Live ✓");

              _dataSub?.cancel();
              _dataSub = char.lastValueStream.listen(
                (value) {
                  if (value.isEmpty) return;
                  
                  // 🔥 ULTRA-FORGIVING PARSER
                  final raw = String.fromCharCodes(value).trim();
                  // Splits by comma, removes any spaces/garbage, drops empty items
                  final parts = raw.split(RegExp(r'[,|]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                  
                  // Must have AT LEAST 5 values (Fingers). 6th is optional BPM.
                  if (parts.length >= 5) {
                    const keys = ["Thumb","Index","Middle","Ring","Little"];
                    if (mounted) {
                      setState(() {
                        for (int i = 0; i < 5; i++) {
                          sensorValues[keys[i]] = (double.tryParse(parts[i]) ?? 0).clamp(0.0, 100.0);
                        }
                        
                        // Safely grab BPM if it exists
                        if (parts.length >= 6) {
                          currentBPM = int.tryParse(parts[5]) ?? 0;
                        }
                        
                        statusMessage = "Live ✓";
                        if (isRecording) _updatePeak(sensorValues);
                      });
                      
                      String dominantFinger = _getDominantFinger();
                      if (dominantFinger != "HOLD") {
                        _updateAnimation(_animationNames[dominantFinger] ?? "Index_Flex");
                      }
                    }
                  }
                },
              );
            }
          }
        }
      }

      if (!charFound) {
        _showSnack("UUID not found — reflash ESP32", const Color(0xFFFFD700));
        if (mounted) setState(() => statusMessage = "UUID mismatch!");
      }

    } catch (e) {
      if (mounted) {
        setState(() {
          isScanning = false;
          isConnected = false;
          statusMessage = "Failed — try again";
        });
        _showSnack("Connection failed: $e", const Color(0xFFFF2D78));
      }
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0A0A0F), Color(0xFF0D1117), Color(0xFF0A0A0F)],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            _buildTopBar(),
            
            // Flex 5 for Model
            Expanded(
              flex: 5,
              child: _buildModelViewer(),
            ),
            
            // Flex 3 for Sensors (Fixes the overflow hazard tape entirely!)
            Expanded(
              flex: 3,
              child: _buildSensorPanel(),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(children: [
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
                colors: [Color(0xFF00FFCC), Color(0xFF7B2FFF)]),
          ),
          child: const Icon(Icons.back_hand_rounded, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("KinoSync", style: TextStyle(color: Colors.white,
              fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 1)),
          Text("SDV Telemetry", style: TextStyle(color: Color(0xFF00FFCC),
              fontSize: 10, letterSpacing: 2)),
        ]),
        const Spacer(),

        GestureDetector(
          onTap: _openLogSheet,
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.6)),
              color: const Color(0xFFFFD700).withOpacity(0.06),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.history_rounded, color: Color(0xFFFFD700), size: 14),
              const SizedBox(width: 5),
              Text("LOG${_allLogs.isNotEmpty ? ' (${_allLogs.length})' : ''}",
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      letterSpacing: 1, color: Color(0xFFFFD700))),
            ]),
          ),
        ),

        if (isConnected) _buildBpmPill(),
        if (isConnected) const SizedBox(width: 8),

        _buildStatusPill(),
      ]),
    );
  }

  Widget _buildBpmPill() {
    return GestureDetector(
      onTap: () {
        setState(() {
          showBPM = !showBPM;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: EdgeInsets.symmetric(horizontal: showBPM ? 12 : 8, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFF2D78).withOpacity(0.15),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFFFF2D78).withOpacity(0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _heartbeatController,
              builder: (context, child) {
                double scale = currentBPM > 40 ? 1.0 + (_heartbeatController.value * 0.3) : 1.0;
                return Transform.scale(
                  scale: scale,
                  child: Icon(Icons.favorite, color: const Color(0xFFFF2D78), size: 16),
                );
              }
            ),
            if (showBPM) ...[
              const SizedBox(width: 6),
              Text(
                currentBPM > 0 ? "$currentBPM BPM" : "READING...",
                style: const TextStyle(
                  color: Color(0xFFFF2D78),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill() {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (_, __) {
        final c = isConnected
            ? const Color(0xFF00FFCC)
            : isScanning
                ? Color.lerp(const Color(0xFF00FFCC),
                    const Color(0xFF7B2FFF), _pulseController.value)!
                : const Color(0xFFFF2D78);

        return GestureDetector(
          onTap: (isConnected || isScanning) ? null : startBLEScan,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: c, width: 1.5),
              color: c.withOpacity(0.08),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle, color: c,
                  boxShadow: [BoxShadow(color: c.withOpacity(0.7), blurRadius: 6)],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? "CONNECTED"
                    : isScanning ? "SCANNING..."
                    : "CONNECT",
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    letterSpacing: 1.2, color: c),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildModelViewer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(children: [
        AnimatedBuilder(
          animation: _glowController,
          builder: (_, __) {
            String dom = _displayedAnimation.replaceAll('_Flex', '').replaceAll('.001', '').replaceAll('.002', '');
            Color glowColor = _fingerColors[dom] ?? const Color(0xFF7B2FFF);
            
            return Center(child: Container(
              width: 200, height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(
                  color: glowColor.withOpacity(0.15 + _glowController.value * 0.1),
                  blurRadius: 80 + _glowController.value * 30,
                  spreadRadius: 20,
                )],
              ),
            ));
          }
        ),

        ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: ModelViewer(
            key: _modelKey,
            src: 'assets/Hand_Animation_Final.glb',
            alt: "3D Hand Model",
            autoRotate: false,
            cameraControls: true,
            animationName: _displayedAnimation,
            autoPlay: true,
            backgroundColor: Colors.transparent,
          ),
        ),

        Positioned(top: 12, left: 0, right: 0,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Text(statusMessage,
                style: const TextStyle(color: Colors.white60,
                    fontSize: 10, letterSpacing: 1)),
          )),
        ),

        Positioned(bottom: 12, left: 0, right: 0,
          child: Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black45,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Text(
              _displayedAnimation.replaceAll('_', ' ').replaceAll('.001', '').replaceAll('.002', '').toUpperCase(),
              style: const TextStyle(
                  color: Color(0xFF00FFCC), fontSize: 11,
                  letterSpacing: 2, fontWeight: FontWeight.w600),
            ),
          )),
        ),
      ]),
    );
  }

  Widget _buildSensorPanel() {
    return Container(
      // Removed hardcoded height here! Flutter handles layout naturally.
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text("TELEMETRY",
              style: TextStyle(color: Colors.white54, fontSize: 11,
                  letterSpacing: 2, fontWeight: FontWeight.w600)),
          const Spacer(),
          
          GestureDetector(
            onTap: _toggleRecording,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isRecording ? const Color(0xFFFF2D78).withOpacity(0.2) : Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isRecording ? const Color(0xFFFF2D78) : Colors.transparent),
              ),
              child: Row(
                children: [
                  Icon(isRecording ? Icons.stop_rounded : Icons.fiber_manual_record, 
                    color: isRecording ? const Color(0xFFFF2D78) : Colors.white70, size: 14),
                  const SizedBox(width: 4),
                  Text(isRecording ? "STOP LOG" : "NEW ATTEMPT", 
                    style: TextStyle(color: isRecording ? const Color(0xFFFF2D78) : Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: sensorValues.keys.map(_buildFingerBar).toList(),
          ),
        ),
      ]),
    );
  }

  Widget _buildFingerBar(String finger) {
    // 1. Removed the isBroken hack entirely
    final value = sensorValues[finger] ?? 0.0;
    final percent = (value / 100.0).clamp(0.0, 1.0);
    final degrees = SessionLog.toDegrees(value);
    
    final color = _fingerColors[finger] ?? const Color(0xFF00FFCC);
    final isActive = _displayedAnimation == _animationNames[finger];

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (_, __) => Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // 2. Removed "ERR" text fallback
          Text("${value.toInt()}%",
              style: TextStyle(color: isActive ? color : Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
          // 3. Removed "N/A" text fallback
          Text("${degrees.toInt()}°",
              style: TextStyle(color: isActive ? color.withOpacity(0.7) : Colors.white24, fontSize: 9)),
          
          const SizedBox(height: 4),
          Expanded( 
            child: Container(
              width: 40,
              decoration: BoxDecoration(
                // 4. Cleaned up border and background logic
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isActive
                          ? color.withOpacity(0.5 + _pulseController.value * 0.3)
                          : Colors.white.withOpacity(0.08),
                  width: isActive ? 1.5 : 1,
                ),
              ),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox( 
                  heightFactor: percent,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [color, color.withOpacity(0.4)],
                      ),
                      boxShadow: isActive ? [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8)] : [],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 5. Cleaned up icon and label colors
          Icon(_fingerIcons[finger] ?? Icons.circle,
              color: isActive ? color : Colors.white30, size: 14),
          const SizedBox(height: 2),
          Text(finger.substring(0, 3).toUpperCase(),
              style: TextStyle(color: isActive ? color : Colors.white38, fontSize: 9, letterSpacing: 1, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// SESSION LOG BOTTOM SHEET 
// ─────────────────────────────────────────────
class _SessionLogSheet extends StatelessWidget {
  final List<SessionLog> logs;
  const _SessionLogSheet({required this.logs});

  static const Map<String, Color> _fingerColors = {
    "Thumb":  Color(0xFF00FFCC),
    "Index":  Color(0xFF7B2FFF),
    "Middle": Color(0xFFFF6B35),
    "Ring":   Color(0xFFFFD700),
    "Little": Color(0xFFFF2D78),
  };

  String _fmt(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2,'0')}';
  }

  String _fmtDur(int s) {
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${s % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    final reversed = logs.reversed.toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F0F18),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(
            top: BorderSide(color: Color(0xFF7B2FFF), width: 1),
          ),
        ),
        child: Column(children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Row(children: [
              const Icon(Icons.history_rounded, color: Color(0xFFFFD700), size: 18),
              const SizedBox(width: 8),
              Text("SESSION LOGS (${logs.length})",
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w700, letterSpacing: 1.5)),
              const Spacer(),
              if (logs.isNotEmpty)
                GestureDetector(
                  onTap: () async {
                    await SessionLogger.clear();
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text("CLEAR ALL",
                      style: TextStyle(color: Color(0xFFFF2D78),
                          fontSize: 10, letterSpacing: 1)),
                ),
            ]),
          ),
          if (logs.isEmpty)
            const Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.data_usage_rounded, color: Colors.white24, size: 48),
                  SizedBox(height: 12),
                  Text("No sessions yet.\nConnect the glove to start logging.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ]),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                itemCount: reversed.length,
                itemBuilder: (_, i) {
                  final log = reversed[i];
                  final prev = i + 1 < reversed.length ? reversed[i + 1] : null;
                  return _SessionCard(
                    log: log,
                    prev: prev,
                    index: reversed.length - i,
                    fingerColors: _fingerColors,
                    fmtTime: _fmt,
                    fmtDur: _fmtDur,
                  );
                },
              ),
            ),
        ]),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final SessionLog log;
  final SessionLog? prev;
  final int index;
  final Map<String, Color> fingerColors;
  final String Function(DateTime) fmtTime;
  final String Function(int) fmtDur;

  const _SessionCard({
    required this.log,
    required this.prev,
    required this.index,
    required this.fingerColors,
    required this.fmtTime,
    required this.fmtDur,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF7B2FFF).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text("#$index",
                style: const TextStyle(
                    color: Color(0xFF7B2FFF), fontSize: 10,
                    fontWeight: FontWeight.w700, letterSpacing: 1)),
          ),
          const SizedBox(width: 8),
          Text(fmtTime(log.timestamp),
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          const Spacer(),
          const Icon(Icons.timer_outlined, color: Colors.white38, size: 12),
          const SizedBox(width: 4),
          Text(fmtDur(log.durationSeconds),
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ]),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: log.peakValues.entries.map((e) {
            final color = fingerColors[e.key] ?? Colors.white;
            final deg = SessionLog.toDegrees(e.value);
            final prevVal = prev?.peakValues[e.key];
            final delta = prevVal != null ? e.value - prevVal : null;

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withOpacity(0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withOpacity(0.2)),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(e.key.substring(0, 3).toUpperCase(),
                    style: TextStyle(
                        color: color, fontSize: 9,
                        fontWeight: FontWeight.w700, letterSpacing: 1)),
                const SizedBox(height: 2),
                Text("${e.value.toInt()}% · ${deg.toInt()}°",
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 10,
                        fontWeight: FontWeight.w600)),
                if (delta != null) ...[
                  const SizedBox(height: 2),
                  _DeltaBadge(delta: delta),
                ],
              ]),
            );
          }).toList(),
        ),
        if (prev != null) ...[
          const SizedBox(height: 10),
          _ImprovementSummary(log: log, prev: prev!),
        ],
      ]),
    );
  }
}

class _DeltaBadge extends StatelessWidget {
  final double delta;
  const _DeltaBadge({required this.delta});

  @override
  Widget build(BuildContext context) {
    if (delta.abs() < 1) {
      return const Text("─", style: TextStyle(color: Colors.white38, fontSize: 9));
    }
    final isUp = delta > 0;
    final color = isUp ? const Color(0xFF00FFCC) : const Color(0xFFFF2D78);
    final icon = isUp ? "▲" : "▼";
    return Text("$icon${delta.abs().toInt()}%",
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700));
  }
}

class _ImprovementSummary extends StatelessWidget {
  final SessionLog log;
  final SessionLog prev;
  const _ImprovementSummary({required this.log, required this.prev});

  @override
  Widget build(BuildContext context) {
    int improved = 0, declined = 0;
    double totalDelta = 0;

    log.peakValues.forEach((k, v) {
      
      final p = prev.peakValues[k] ?? 0;
      final d = v - p;
      totalDelta += d;
      if (d > 1) improved++;
      if (d < -1) declined++;
    });

    final avgDelta = totalDelta / log.peakValues.length ; 
    final isOverallBetter = avgDelta > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (isOverallBetter
            ? const Color(0xFF00FFCC)
            : const Color(0xFFFF2D78)).withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (isOverallBetter
              ? const Color(0xFF00FFCC)
              : const Color(0xFFFF2D78)).withOpacity(0.2),
        ),
      ),
      child: Row(children: [
        Icon(
          isOverallBetter ? Icons.trending_up_rounded : Icons.trending_down_rounded,
          color: isOverallBetter ? const Color(0xFF00FFCC) : const Color(0xFFFF2D78),
          size: 14,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            isOverallBetter
                ? "$improved finger${improved != 1 ? 's' : ''} improved · avg +${avgDelta.abs().toStringAsFixed(1)}%"
                : declined > 0
                    ? "$declined finger${declined != 1 ? 's' : ''} declined · avg ${avgDelta.toStringAsFixed(1)}%"
                    : "No significant change vs last session",
            style: TextStyle(
              color: isOverallBetter ? const Color(0xFF00FFCC) : const Color(0xFFFF2D78),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ]),
    );
  }
}