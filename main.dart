import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'crypto/encryption_service.dart';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart';
import 'crypto/key_manager.dart';

//

import 'payload/health_payload.dart';
import 'services/ipfs_client.dart';

//
void main() {
  runApp(const HealthBlockchainApp());
}

class HealthBlockchainApp extends StatelessWidget {
  const HealthBlockchainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health Blockchain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'SF Pro Display',
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF007AFF),
          brightness: Brightness.light,
        ),
      ),
      home: const HealthHomePage(),
    );
  }
}

class UploadedRecord {
  final String recordId;
  final String cid;
  final DateTime createdAt;

  UploadedRecord(
      {required this.recordId, required this.cid, required this.createdAt});

  Map<String, dynamic> toJson() => {
        'recordId': recordId,
        'cid': cid,
        'createdAt': createdAt.toIso8601String(),
      };

  static UploadedRecord fromJson(Map<String, dynamic> m) => UploadedRecord(
        recordId: m['recordId'] as String,
        cid: m['cid'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
      );
}

class HealthHomePage extends StatefulWidget {
  const HealthHomePage({super.key});

  @override
  State<HealthHomePage> createState() => _HealthHomePageState();
}

class _HealthHomePageState extends State<HealthHomePage>
    with TickerProviderStateMixin {
  bool _isLoading = false;
  bool _dataLoaded = false;
  String _statusMessage = "Pronto per il caricamento";
  Map<String, dynamic> _healthData = {};
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  Map<String, dynamic>? _manifestBase; // ← manifest per i wrap chiave (owner)

  static const String kBackendBaseUrl = 'http://193.70.113.55:8787';
  // Map<String, dynamic>? _manifestBase;
  List<UploadedRecord> _uploadedRecords = [];

  bool _uploadingIpfs = false;
  bool _uploadedOk = false;

  Uint8List? _encryptedBytes; // risultato cifratura da inviare a IPFS
  String? _ipfsCid;

  DateTime? _lastSync;

  // 🔹 Nuovi campi per payload pronto alla cifratura
  Map<String, dynamic>? _payload;
  Uint8List? _payloadBytes;

  static const List<HealthDataType> types = [
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE,
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
    HealthDataType.WEIGHT,
    HealthDataType.HEIGHT,
    HealthDataType.BODY_MASS_INDEX,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.DISTANCE_WALKING_RUNNING,
  ];

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.elasticOut),
    );
    _animationController.forward();
    _initializeHealthData();
    _loadLastSync();
    _loadUploadedRecords();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime dt) =>
      "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} "
      "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";

  Future<void> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final iso = prefs.getString('last_sync_iso');
    if (iso != null) {
      setState(() => _lastSync = DateTime.parse(iso));
    }
  }

  Future<void> _initializeHealthData() async {
    await _checkHealthPermissions();
  }

  Future<bool> _checkHealthPermissions() async {
    try {
      final requested = await Health().requestAuthorization(
        types,
        permissions: types.map((e) => HealthDataAccess.READ).toList(),
      );

      setState(() {
        _statusMessage = requested
            ? "Permessi concessi - Pronto per il caricamento"
            : "Permessi necessari per continuare";
      });

      return requested;
    } catch (e) {
      setState(() {
        _statusMessage = "Errore nei permessi: ${e.toString()}";
      });
      return false;
    }
  }

  // funzione hash
  String _sha256Hex(List<int> data) => crypto.sha256.convert(data).toString();

  // funzione cifratura payload
  Future<void> _encryptCurrentPayload() async {
    if (_payloadBytes == null) return;

    try {
      final recordId = _sha256Hex(_payloadBytes!);

      // ATTENZIONE: adatta in base al tuo EncryptionService
      // Supponiamo ritorni un oggetto con 'cipherBytes' (Uint8List)
      final enc = await EncryptionService.encryptPayload(
        payloadBytes: _payloadBytes!,
        recordId: recordId,
      );

      final manifestBase = enc.buildManifestBase();

      setState(() {
        _statusMessage =
            "Payload cifrato! RecordId: $recordId (pronto per IPFS)";
        _encryptedBytes = enc.encryptedBytes;
        _manifestBase =
            manifestBase; // ⬅️ salva manifest base per l’upload successivo
        _uploadedOk = false; // ⬅️ reset
      });

      if (!mounted) return;

      // Mostra un messaggio visibile anche quando la card di caricamento è nascosta
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✅ Payload cifrato!',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          backgroundColor: Colors.white,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          duration: const Duration(seconds: 3),
          elevation: 4,
        ),
      );

      print("Payload cifrato! RecordId: $recordId (pronto per IPFS)");
      setState(() {
        _statusMessage =
            "Payload cifrato! RecordId: $recordId (pronto per IPFS)";
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Errore cifratura: $e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _uploadToIpfs() async {
    if (_encryptedBytes == null || _payloadBytes == null) return;

    setState(() {
      _uploadingIpfs = true;
      _uploadedOk = false; // ⬅️ reset
    });

    final recordId = _sha256Hex(_payloadBytes!);
    final client = IpfsClient(baseUrl: kBackendBaseUrl);
    try {
      final res = await client.uploadEncryptedBytes(
        encryptedBytes: _encryptedBytes!,
        recordId: recordId,
        filename: 'health_payload.enc',
      );

      if (!mounted) return;
      if (res.ok && res.cid != null) {
        setState(() {
          _ipfsCid = res.cid;
          _uploadedOk = true; // ⬅️ segnala successo
        });

        // ⬇️ INVIA anche il MANIFEST al backend (se presente)
        if (_manifestBase != null) {
          final saved = await client.uploadManifest(
            recordId: recordId,
            cid: res.cid!,
            manifestBase: _manifestBase!,
          );
          if (saved && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('🔐 Metadati di chiave salvati')),
            );
          }
          if (!saved) {
            // opzionale: log o snackbar soft warning
            debugPrint('⚠️ Salvataggio manifest fallito');
          } else {
            debugPrint('✅ Manifest salvato');
          }
        }

        await _rememberUploadedRecord(recordId, res.cid!);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Caricato su IPFS\nCID: ${res.cid}',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: Colors.black87),
            ),
            backgroundColor: Colors.white,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            duration: const Duration(seconds: 4),
            elevation: 4,
          ),
        );
        print('IPFS CID: ${res.cid}, URL: ${res.url}');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text('Upload fallito: ${res.error ?? 'errore sconosciuto'}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Errore upload: $e'),
            behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _uploadingIpfs = false); // ⬅️ STOP loading
    }
  }

  Future<void> _loadHealthData() async {
    setState(() {
      _isLoading = true;
      _dataLoaded = false;
      _encryptedBytes = null;
      _ipfsCid = null;
      _manifestBase = null; // ← reset
    });

    // Mostra lo spinner per almeno 1.5s
    await Future.delayed(const Duration(milliseconds: 1500));

    try {
      final hasPermissions = await _checkHealthPermissions();
      if (!hasPermissions) {
        throw Exception(
          "Permessi HealthKit non concessi. Vai in Impostazioni > Privacy e sicurezza > Salute per abilitarli.",
        );
      }

      final now = DateTime.now();

      // ⏱️ Applica overlap per catturare eventuali backfill
      final lastSyncOriginal = _lastSync; // salva per il filtro anti-duplicati
      const overlap = Duration(hours: 48);
      final start = (lastSyncOriginal != null)
          ? lastSyncOriginal.subtract(overlap)
          : now.subtract(const Duration(days: 7));

      print("=== INIZIO CARICAMENTO DATI SANITARI ===");
      print("Query Health: $start -> $now (overlap ${overlap.inHours}h)");

      // Fetch
      List<HealthDataPoint> healthDataPoints =
          await Health().getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: now,
      );

      // 🔎 Filtra fuori i duplicati: prendi solo ciò che è *successivo* all'ultima sync reale
      if (lastSyncOriginal != null) {
        healthDataPoints = healthDataPoints
            .where((dp) => dp.dateTo.isAfter(lastSyncOriginal))
            .toList();
      }

      print("Dati (post-filtro): ${healthDataPoints.length} punti");

      // Fallback solo al primo avvio (se non abbiamo _lastSync e non è uscito nulla)
      if (healthDataPoints.isEmpty && lastSyncOriginal == null) {
        final thirtyDaysAgo = now.subtract(const Duration(days: 30));
        print("Fallback 30 giorni: $thirtyDaysAgo -> $now");
        healthDataPoints = await Health().getHealthDataFromTypes(
          types: types,
          startTime: thirtyDaysAgo,
          endTime: now,
        );
        print("Dati fallback 30 giorni: ${healthDataPoints.length}");
      }

      // Organizza i dati
      final Map<String, dynamic> organizedData = {};
      final Map<String, int> dataCount = {};

      for (final dp in healthDataPoints) {
        final typeKey = dp.type.name;
        organizedData.putIfAbsent(typeKey, () => []);
        dataCount[typeKey] = (dataCount[typeKey] ?? 0) + 1;

        organizedData[typeKey].add({
          'value': dp.value,
          'unit': dp.unit.name,
          'dateFrom': dp.dateFrom.toIso8601String(),
          'dateTo': dp.dateTo.toIso8601String(),
        });
      }

      // 📦 Costruisci payload compatto/deterministico per cifratura
      // fromEff: l'intervallo "logico" dei dati nuovi (dopo l'ultima sync reale)
      final fromEff = lastSyncOriginal ?? start;
      final payload = HealthPayload.build(
        from: fromEff,
        to: now,
        countByType: dataCount,
      );
      final payloadBytes = HealthPayload.encode(payload);

      // 💾 Persisti ultima sincronizzazione (ora corrente)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_sync_iso', now.toIso8601String());

      setState(() {
        _lastSync = now;
        _healthData = {
          'totalDataPoints': healthDataPoints.length,
          'dataByType': organizedData,
          'countByType': dataCount,
          'fetchDate': now.toIso8601String(),
        };

        // salva payload per gli step successivi (cifratura/upload)
        _payload = payload;
        _payloadBytes = payloadBytes;

        _isLoading = false;
        _dataLoaded = true;
        _statusMessage = healthDataPoints.isEmpty
            ? "Nessun dato sanitario nuovo trovato."
            : "Dati caricati con successo! ${healthDataPoints.length} punti dati trovati";
      });

      if (healthDataPoints.isNotEmpty) {
        HapticFeedback.mediumImpact();
      }

      // Debug opzionale
      print("Payload JSON: ${jsonEncode(payload)}");
      print("Payload bytes: ${payloadBytes.length} byte");
      print("=== DATI SANITARI CARICATI ===");
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "Errore nel caricamento: ${e.toString()}";
      });
      print("Errore nel caricamento dati sanitari: $e");
    }
  }

  Widget _buildHealthDataSummary() {
    if (!_dataLoaded) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green[600], size: 24),
              const SizedBox(width: 8),
              Text(
                "Dati caricati",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.green[700],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_lastSync != null)
            Text(
              "Ultima sincronizzazione: ${_formatDate(_lastSync!)}",
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
          const SizedBox(height: 12),
          Text(
            "Totale: ${_healthData['totalDataPoints']} punti dati",
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 0),
          ...(_healthData['countByType'] as Map<String, int>).entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_getTypeDisplayName(entry.key),
                          style: const TextStyle(fontSize: 14)),
                      Text(
                        "${entry.value}",
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700], size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    "I dati sono pronti per la crittografia e il caricamento su blockchain",
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getTypeDisplayName(String type) {
    const Map<String, String> displayNames = {
      'STEPS': 'Passi',
      'HEART_RATE': 'Frequenza cardiaca',
      'BLOOD_PRESSURE_SYSTOLIC': 'Pressione sistolica',
      'BLOOD_PRESSURE_DIASTOLIC': 'Pressione diastolica',
      'WEIGHT': 'Peso',
      'HEIGHT': 'Altezza',
      'BODY_MASS_INDEX': 'BMI',
      'ACTIVE_ENERGY_BURNED': 'Calorie bruciate',
      'DISTANCE_WALKING_RUNNING': 'Distanza percorsa',
    };
    return displayNames[type] ?? type;
  }

  Future<void> _loadUploadedRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('uploaded_records');
    if (s == null) return;
    final List list = jsonDecode(s) as List;
    setState(() {
      _uploadedRecords = list
          .map((e) => UploadedRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  Future<void> _rememberUploadedRecord(String recordId, String cid) async {
    final rec =
        UploadedRecord(recordId: recordId, cid: cid, createdAt: DateTime.now());
    setState(() {
      // evita duplicati per lo stesso recordId
      _uploadedRecords.removeWhere((r) => r.recordId == recordId);
      _uploadedRecords.insert(0, rec);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'uploaded_records',
      jsonEncode(_uploadedRecords.map((r) => r.toJson()).toList()),
    );
  }

  void _openRecordsPage() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordsPage(
          backendBaseUrl: kBackendBaseUrl,
          records: _uploadedRecords,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    ScaleTransition(
                      scale: _scaleAnimation,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.blue[600]!, Colors.blue[400]!],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.blue.withOpacity(0.3),
                              blurRadius: 15,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.health_and_safety,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      "Health Blockchain",
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1D1D1F),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Dati sanitari sicuri su blockchain",
                      style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                    ),
                    if (_lastSync != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          "Ultima sincronizzazione: ${_formatDate(_lastSync!)}",
                          style:
                              TextStyle(fontSize: 13, color: Colors.grey[600]),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 16),

                    // 🔹 Pulsante per vedere i record caricati (nuova sezione)
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed:
                            _uploadedRecords.isEmpty ? null : _openRecordsPage,
                        icon: const Icon(Icons.lock_outline),
                        label: Text(
                          _uploadedRecords.isEmpty
                              ? "Nessun record caricato"
                              : "I miei record su IPFS (${_uploadedRecords.length})",
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.blue[400]!),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          foregroundColor: Colors.blue[700],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Card principale (sparisce quando _dataLoaded = true)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => SizeTransition(
                  sizeFactor: anim,
                  axisAlignment: -1,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _dataLoaded
                    ? const SizedBox.shrink(key: ValueKey('hidden-card'))
                    : Container(
                        key: const ValueKey('loader-card'),
                        margin: const EdgeInsets.symmetric(horizontal: 20),
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 15,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                color: _isLoading
                                    ? Colors.orange[50]
                                    : Colors.blue[50],
                                borderRadius: BorderRadius.circular(50),
                              ),
                              child: _isLoading
                                  ? SpinKitRipple(
                                      color: Colors.orange[600]!, size: 60)
                                  : Icon(Icons.health_and_safety_outlined,
                                      size: 50, color: Colors.blue[600]),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              _statusMessage,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 16,
                                  color: Colors.grey[700],
                                  height: 1.4),
                            ),
                            const SizedBox(height: 30),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : () async {
                                        setState(() {
                                          _statusMessage =
                                              "Caricamento dati sanitari...";
                                          // Hard reset stato upload
                                          _encryptedBytes = null;
                                          _ipfsCid = null;
                                          _manifestBase = null;
                                        });
                                        await _loadHealthData();
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue[600],
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16)),
                                  disabledBackgroundColor: Colors.grey[300],
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          color: Colors.white,
                                          strokeWidth: 2.5,
                                        ),
                                      )
                                    : const Text(
                                        "Carica Dati Sanitari",
                                        style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),

              // Riepilogo dati (appare con animazione quando _dataLoaded = true)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                switchInCurve: Curves.easeOutBack,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.08), end: Offset.zero)
                      .animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: _dataLoaded
                    ? KeyedSubtree(
                        key: const ValueKey('summary'),
                        child: _buildHealthDataSummary(),
                      )
                    : const SizedBox.shrink(key: ValueKey('summary-empty')),
              ),

              // Bottone "Cifra payload" (visibile solo dopo il caricamento)
              if (_dataLoaded &&
                  (_encryptedBytes == null || _manifestBase == null))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: (_payloadBytes != null)
                          ? _encryptCurrentPayload
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[700],
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        disabledBackgroundColor: Colors.grey[300],
                      ),
                      child: const Text(
                        "Cifra payload",
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),

              // Bottone upload IPFS
              (_encryptedBytes != null && _manifestBase != null)
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton.icon(
                          onPressed: (_encryptedBytes != null &&
                                  _manifestBase != null &&
                                  !_uploadingIpfs &&
                                  !_uploadedOk)
                              ? _uploadToIpfs
                              : null,
                          icon: _uploadingIpfs
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.2,
                                  ),
                                )
                              : const Icon(Icons.cloud_upload_outlined),
                          label: Text(
                            _uploadingIpfs
                                ? "Caricamento..."
                                : (_uploadedOk
                                    ? "Caricato correttamente"
                                    : "Carica su IPFS"),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green[600],
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            disabledBackgroundColor: Colors.grey[300],
                          ),
                        ),
                      ),
                    )
                  : Container(),

              // Richiamo “I miei record” anche in basso (comodo)
              // Padding(
              //   padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              //   child: SizedBox(
              //     width: double.infinity,
              //     height: 48,
              //     child: OutlinedButton.icon(
              //       onPressed:
              //           _uploadedRecords.isEmpty ? null : _openRecordsPage,
              //       icon: const Icon(Icons.folder_open),
              //       label: Text(
              //         _uploadedRecords.isEmpty
              //             ? "I miei record (vuoto)"
              //             : "I miei record (${_uploadedRecords.length})",
              //       ),
              //       style: OutlinedButton.styleFrom(
              //         side: BorderSide(color: Colors.blue[200]!),
              //         shape: RoundedRectangleBorder(
              //             borderRadius: BorderRadius.circular(14)),
              //         foregroundColor: Colors.blue[700],
              //       ),
              //     ),
              //   ),
              // ),
            ],
          ),
        ),
      ),
    );
  }
}

class RecordsPage extends StatefulWidget {
  final String backendBaseUrl;
  final List<UploadedRecord> records;

  const RecordsPage({
    super.key,
    required this.backendBaseUrl,
    required this.records,
  });

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  bool _busy = false;

  // Aggiungi in RecordsPage:
  Future<void> _showPlainJson(BuildContext context, String jsonStr) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(2))),
                const Text('Payload in chiaro',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 400),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      const JsonEncoder.withIndent('  ')
                          .convert(json.decode(jsonStr)),
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13.5),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copia'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: jsonStr));
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copiato')));
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Condividi'),
                        onPressed: () {
                          // opzionale: integrazione con share_plus
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _viewClear(UploadedRecord rec) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final recordId = rec.recordId;

      // 1) Manifest dal backend
      final manifestRes = await http
          .get(Uri.parse('${widget.backendBaseUrl}/keywraps/$recordId'));
      if (manifestRes.statusCode != 200) {
        throw Exception('Manifest non trovato (${manifestRes.statusCode})');
      }
      final manifest = jsonDecode(manifestRes.body) as Map<String, dynamic>;
      final m = manifest['manifest'] as Map<String, dynamic>? ?? {};
      final owner =
          (m['wraps'] as Map<String, dynamic>)['owner'] as Map<String, dynamic>;
      final cid = (manifest['cid'] ?? m['cid'] ?? rec.cid) as String;

      // 2) Deriva KEK_device
      final kek = await KeyManager.deriveKekDevice();

      // 3) Unwrap DEK (AES-GCM, aad=recordId)
      final aead = AesGcm.with256bits();
      final wrapNonce = base64Decode(owner['nonce'] as String);
      final wrapMac = base64Decode(owner['mac'] as String);
      final wrapCipher = base64Decode(owner['dek'] as String);
      final dekBytes = await aead.decrypt(
        SecretBox(wrapCipher, nonce: wrapNonce, mac: Mac(wrapMac)),
        secretKey: kek,
        aad: utf8.encode(recordId),
      );
      final dek = SecretKey(dekBytes);

// 4) Scarica blob IPFS (nonce|cipher|mac)
// Usa URL *senza* path; opzionale: fallback su altri gateway
      final candidates = <String>[
        'https://w3s.link/ipfs/$cid', // preferito per Web3.Storage
        'https://$cid.ipfs.w3s.link', // subdomain gateway
        'https://ipfs.io/ipfs/$cid', // fallback
        'https://cloudflare-ipfs.com/ipfs/$cid',
        'https://dweb.link/ipfs/$cid',
      ];

      http.Response? blobRes;
      for (final u in candidates) {
        try {
          final r =
              await http.get(Uri.parse(u)).timeout(const Duration(seconds: 12));
          if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
            blobRes = r;
            break;
          }
        } catch (_) {
          // ignora timeout/errore e prova il prossimo gateway
        }
      }

      if (blobRes == null) {
        throw Exception('Download IPFS fallito (tutti i gateway)');
      }

      final bytes = blobRes.bodyBytes;
      if (bytes.length < 12 + 16) {
        throw Exception('Blob troppo corto');
      }

      final dataNonce = bytes.sublist(0, 12);
      final dataMac = bytes.sublist(bytes.length - 16);
      final dataCipher = bytes.sublist(12, bytes.length - 16);

      // 5) Decrypt dati (AAD = recordId)
      final plain = await aead.decrypt(
        SecretBox(dataCipher, nonce: dataNonce, mac: Mac(dataMac)),
        secretKey: dek,
        aad: utf8.encode(recordId),
      );

      final jsonStr = utf8.decode(plain);
      if (!mounted) return;
      await _showPlainJson(context, jsonStr);

      // Ripulisci subito i segreti dalla RAM
      plain.fillRange(0, plain.length, 0);
      dataCipher.fillRange(0, dataCipher.length, 0);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore decrypt: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _short(String s, {int head = 8, int tail = 6}) {
    if (s.length <= head + tail) return s;
    return '${s.substring(0, head)}…${s.substring(s.length - tail)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('I miei record su IPFS'),
      ),
      body: widget.records.isEmpty
          ? const Center(child: Text('Nessun record caricato finora'))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: widget.records.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final r = widget.records[i];
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 3))
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('RecordId: ${_short(r.recordId)}',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text('CID: ${_short(r.cid)}',
                          style: TextStyle(color: Colors.grey[700])),
                      const SizedBox(height: 6),
                      Text('Creato: ${r.createdAt.toLocal()}',
                          style:
                              TextStyle(color: Colors.grey[600], fontSize: 12)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: _busy ? null : () => _viewClear(r),
                            icon: const Icon(Icons.remove_red_eye_outlined),
                            label: const Text('Vedi in chiaro'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue[700],
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: r.cid));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('CID copiato')));
                            },
                            icon: const Icon(Icons.copy),
                            label: const Text('Copia CID'),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
