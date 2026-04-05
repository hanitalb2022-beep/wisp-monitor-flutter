// ============================================================================
// WISP Monitor - تطبيق مراقبة شبكة الإنترنت اللاسلكي
// مراقبة أبراج وسكاتر UBNT و MikroTik عبر SNMP
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dart_snmp/dart_snmp.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:intl/intl.dart' as intl;

// ============================================================================
// ثوابت التطبيق
// ============================================================================

class AppConstants {
  // ألوان التصميم
  static const Color bgPrimary = Color(0xFF05080F);
  static const Color bgSecondary = Color(0xFF0A1020);
  static const Color bgCard = Color(0xFF0F1A2E);
  static const Color bgCardLight = Color(0xFF142240);
  static const Color accentCyan = Color(0xFF00E5FF);
  static const Color accentCyanDark = Color(0xFF008BA0);
  static const Color textPrimary = Color(0xFFE8EAF0);
  static const Color textSecondary = Color(0xFF8A94A8);
  static const Color statusOnline = Color(0xFF00E676);
  static const Color statusOffline = Color(0xFFFF1744);
  static const Color statusWarning = Color(0xFFFFAB00);
  static const Color statusRecovered = Color(0xFF2979FF);

  // OIDs
  static const String oidSysName = '1.3.6.1.2.1.1.5.0';
  static const String oidSysUptime = '1.3.6.1.2.1.1.3.0';
  static const String oidUbntClients = '1.3.6.1.4.1.41112.1.4.7.1.1';
  static const String oidMikrotikClients = '1.3.6.1.4.1.14988.1.1.1.2.1.1';

  // إعدادات افتراضية
  static const int defaultCheckInterval = 5; // دقائق
  static const int defaultMaxClients = 8;
  static const String defaultCommunity = 'public';
  static const int snmpPort = 161;
  static const int snmpTimeout = 5; // ثواني

  // مفاتيح التخزين
  static const String keyTowers = 'towers_data';
  static const String keyAlerts = 'alerts_data';
  static const String keySettings = 'settings_data';

  // WorkManager
  static const String bgTaskName = 'wisp_monitor_check';
  static const String bgTaskTag = 'snmp_check';
}

// ============================================================================
// نماذج البيانات
// ============================================================================

enum DeviceType { ubnt, mikrotik }

enum SectorStatus { online, offline, warning, unknown }

enum AlertType { sectorDown, sectorUp, clientOverload }

class Sector {
  String id;
  String name;
  String ipAddress;
  DeviceType deviceType;
  String model;
  String community;
  int maxClients;
  SectorStatus status;
  int connectedClients;
  int latencyMs;
  String sysName;
  DateTime? lastCheck;
  DateTime? lastStatusChange;

  Sector({
    String? id,
    required this.name,
    required this.ipAddress,
    this.deviceType = DeviceType.ubnt,
    this.model = '',
    this.community = AppConstants.defaultCommunity,
    this.maxClients = AppConstants.defaultMaxClients,
    this.status = SectorStatus.unknown,
    this.connectedClients = 0,
    this.latencyMs = 0,
    this.sysName = '',
    this.lastCheck,
    this.lastStatusChange,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString() +
            '_${Random().nextInt(9999)}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ipAddress': ipAddress,
        'deviceType': deviceType.index,
        'model': model,
        'community': community,
        'maxClients': maxClients,
        'status': status.index,
        'connectedClients': connectedClients,
        'latencyMs': latencyMs,
        'sysName': sysName,
        'lastCheck': lastCheck?.toIso8601String(),
        'lastStatusChange': lastStatusChange?.toIso8601String(),
      };

  factory Sector.fromJson(Map<String, dynamic> json) => Sector(
        id: json['id'],
        name: json['name'] ?? '',
        ipAddress: json['ipAddress'] ?? '',
        deviceType: DeviceType.values[json['deviceType'] ?? 0],
        model: json['model'] ?? '',
        community: json['community'] ?? AppConstants.defaultCommunity,
        maxClients: json['maxClients'] ?? AppConstants.defaultMaxClients,
        status: SectorStatus.values[json['status'] ?? 3],
        connectedClients: json['connectedClients'] ?? 0,
        latencyMs: json['latencyMs'] ?? 0,
        sysName: json['sysName'] ?? '',
        lastCheck: json['lastCheck'] != null
            ? DateTime.tryParse(json['lastCheck'])
            : null,
        lastStatusChange: json['lastStatusChange'] != null
            ? DateTime.tryParse(json['lastStatusChange'])
            : null,
      );
}

class Tower {
  String id;
  String name;
  String location;
  List<Sector> sectors;

  Tower({
    String? id,
    required this.name,
    this.location = '',
    List<Sector>? sectors,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString() +
            '_${Random().nextInt(9999)}',
        sectors = sectors ?? [];

  int get onlineCount =>
      sectors.where((s) => s.status == SectorStatus.online).length;
  int get offlineCount =>
      sectors.where((s) => s.status == SectorStatus.offline).length;
  int get warningCount =>
      sectors.where((s) => s.status == SectorStatus.warning).length;
  int get totalClients =>
      sectors.fold(0, (sum, s) => sum + s.connectedClients);

  SectorStatus get overallStatus {
    if (sectors.isEmpty) return SectorStatus.unknown;
    if (sectors.every((s) => s.status == SectorStatus.offline)) {
      return SectorStatus.offline;
    }
    if (sectors.any((s) => s.status == SectorStatus.offline) ||
        sectors.any((s) => s.status == SectorStatus.warning)) {
      return SectorStatus.warning;
    }
    if (sectors.every((s) => s.status == SectorStatus.online)) {
      return SectorStatus.online;
    }
    return SectorStatus.unknown;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'location': location,
        'sectors': sectors.map((s) => s.toJson()).toList(),
      };

  factory Tower.fromJson(Map<String, dynamic> json) => Tower(
        id: json['id'],
        name: json['name'] ?? '',
        location: json['location'] ?? '',
        sectors: (json['sectors'] as List?)
                ?.map((s) => Sector.fromJson(s))
                .toList() ??
            [],
      );
}

class AlertItem {
  String id;
  AlertType type;
  String towerName;
  String sectorName;
  String sectorIp;
  String message;
  DateTime timestamp;
  bool isRead;

  AlertItem({
    String? id,
    required this.type,
    required this.towerName,
    required this.sectorName,
    this.sectorIp = '',
    required this.message,
    DateTime? timestamp,
    this.isRead = false,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString() +
            '_${Random().nextInt(9999)}',
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.index,
        'towerName': towerName,
        'sectorName': sectorName,
        'sectorIp': sectorIp,
        'message': message,
        'timestamp': timestamp.toIso8601String(),
        'isRead': isRead,
      };

  factory AlertItem.fromJson(Map<String, dynamic> json) => AlertItem(
        id: json['id'],
        type: AlertType.values[json['type'] ?? 0],
        towerName: json['towerName'] ?? '',
        sectorName: json['sectorName'] ?? '',
        sectorIp: json['sectorIp'] ?? '',
        message: json['message'] ?? '',
        timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
        isRead: json['isRead'] ?? false,
      );

  IconData get icon {
    switch (type) {
      case AlertType.sectorDown:
        return Icons.error;
      case AlertType.sectorUp:
        return Icons.check_circle;
      case AlertType.clientOverload:
        return Icons.warning;
    }
  }

  Color get color {
    switch (type) {
      case AlertType.sectorDown:
        return AppConstants.statusOffline;
      case AlertType.sectorUp:
        return AppConstants.statusOnline;
      case AlertType.clientOverload:
        return AppConstants.statusWarning;
    }
  }

  String get emoji {
    switch (type) {
      case AlertType.sectorDown:
        return '⛔';
      case AlertType.sectorUp:
        return '✅';
      case AlertType.clientOverload:
        return '⚠️';
    }
  }
}

class AppSettings {
  int checkIntervalMinutes;
  String defaultCommunity;
  int defaultMaxClients;
  int snmpTimeoutSeconds;
  bool notificationsEnabled;
  bool soundEnabled;
  bool vibrationEnabled;

  AppSettings({
    this.checkIntervalMinutes = AppConstants.defaultCheckInterval,
    this.defaultCommunity = AppConstants.defaultCommunity,
    this.defaultMaxClients = AppConstants.defaultMaxClients,
    this.snmpTimeoutSeconds = AppConstants.snmpTimeout,
    this.notificationsEnabled = true,
    this.soundEnabled = true,
    this.vibrationEnabled = true,
  });

  Map<String, dynamic> toJson() => {
        'checkIntervalMinutes': checkIntervalMinutes,
        'defaultCommunity': defaultCommunity,
        'defaultMaxClients': defaultMaxClients,
        'snmpTimeoutSeconds': snmpTimeoutSeconds,
        'notificationsEnabled': notificationsEnabled,
        'soundEnabled': soundEnabled,
        'vibrationEnabled': vibrationEnabled,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        checkIntervalMinutes:
            json['checkIntervalMinutes'] ?? AppConstants.defaultCheckInterval,
        defaultCommunity:
            json['defaultCommunity'] ?? AppConstants.defaultCommunity,
        defaultMaxClients:
            json['defaultMaxClients'] ?? AppConstants.defaultMaxClients,
        snmpTimeoutSeconds:
            json['snmpTimeoutSeconds'] ?? AppConstants.snmpTimeout,
        notificationsEnabled: json['notificationsEnabled'] ?? true,
        soundEnabled: json['soundEnabled'] ?? true,
        vibrationEnabled: json['vibrationEnabled'] ?? true,
      );
}

// ============================================================================
// خدمة SNMP
// ============================================================================

class SnmpService {
  /// فحص سكتر واحد عبر SNMP
  static Future<Map<String, dynamic>> checkSector(Sector sector) async {
    final result = <String, dynamic>{
      'online': false,
      'sysName': '',
      'clients': 0,
      'latencyMs': 0,
    };

    Snmp? session;
    try {
      final target = InternetAddress(sector.ipAddress);
      final stopwatch = Stopwatch()..start();

      session = await Snmp.createSession(
        target,
        community: sector.community,
        port: AppConstants.snmpPort,
        timeout: const Duration(seconds: 5),
        retries: 1,
        version: SnmpVersion.v2c,
      );

      // فحص الاتصال عبر sysName
      final sysNameOid = Oid.fromString(AppConstants.oidSysName);
      final sysNameMsg = await session.get(sysNameOid);
      stopwatch.stop();

      result['online'] = true;
      result['latencyMs'] = stopwatch.elapsedMilliseconds;
      result['sysName'] =
          sysNameMsg.pdu.varbinds.isNotEmpty
              ? sysNameMsg.pdu.varbinds[0].value.toString()
              : '';

      // عدّ المشتركين المتصلين
      try {
        final clientOidStr = sector.deviceType == DeviceType.ubnt
            ? AppConstants.oidUbntClients
            : AppConstants.oidMikrotikClients;

        int clientCount = 0;
        final walkOid = Oid.fromString(clientOidStr);

        await for (final msg in session.walk(oid: walkOid)) {
          if (msg.pdu.varbinds.isNotEmpty) {
            final varbindOid = msg.pdu.varbinds[0].oid.toString();
            if (varbindOid.startsWith(clientOidStr)) {
              clientCount++;
            } else {
              break;
            }
          }
        }
        result['clients'] = clientCount;
      } catch (_) {
        // إذا فشل عدّ المشتركين، نبقي الجهاز أونلاين
        result['clients'] = 0;
      }
    } on SocketException catch (_) {
      result['online'] = false;
    } on TimeoutException catch (_) {
      result['online'] = false;
    } catch (_) {
      result['online'] = false;
    } finally {
      try {
        session?.close();
      } catch (_) {}
    }

    return result;
  }
}

// ============================================================================
// خدمة الإشعارات
// ============================================================================

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static int _notifId = 0;

  static Future<void> initialize() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(initSettings);

    // طلب إذن الإشعارات (Android 13+)
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'wisp_monitor_channel',
      'WISP Monitor',
      channelDescription: 'تنبيهات مراقبة الشبكة',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(_notifId++, title, body, details, payload: payload);
  }
}

// ============================================================================
// خدمة التخزين المحلي
// ============================================================================

class StorageService {
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static Future<void> saveTowers(List<Tower> towers) async {
    final jsonList = towers.map((t) => t.toJson()).toList();
    await _prefs?.setString(AppConstants.keyTowers, jsonEncode(jsonList));
  }

  static List<Tower> loadTowers() {
    final str = _prefs?.getString(AppConstants.keyTowers);
    if (str == null || str.isEmpty) return [];
    try {
      final list = jsonDecode(str) as List;
      return list.map((j) => Tower.fromJson(j)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAlerts(List<AlertItem> alerts) async {
    // نحتفظ بآخر 200 تنبيه فقط
    final trimmed = alerts.length > 200 ? alerts.sublist(0, 200) : alerts;
    final jsonList = trimmed.map((a) => a.toJson()).toList();
    await _prefs?.setString(AppConstants.keyAlerts, jsonEncode(jsonList));
  }

  static List<AlertItem> loadAlerts() {
    final str = _prefs?.getString(AppConstants.keyAlerts);
    if (str == null || str.isEmpty) return [];
    try {
      final list = jsonDecode(str) as List;
      return list.map((j) => AlertItem.fromJson(j)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveSettings(AppSettings settings) async {
    await _prefs?.setString(
        AppConstants.keySettings, jsonEncode(settings.toJson()));
  }

  static AppSettings loadSettings() {
    final str = _prefs?.getString(AppConstants.keySettings);
    if (str == null || str.isEmpty) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(str));
    } catch (_) {
      return AppSettings();
    }
  }
}

// ============================================================================
// مزود الحالة الرئيسي (Provider)
// ============================================================================

class AppState extends ChangeNotifier {
  List<Tower> _towers = [];
  List<AlertItem> _alerts = [];
  AppSettings _settings = AppSettings();
  bool _isChecking = false;
  Timer? _checkTimer;
  DateTime? _lastFullCheck;

  List<Tower> get towers => _towers;
  List<AlertItem> get alerts => _alerts;
  AppSettings get settings => _settings;
  bool get isChecking => _isChecking;
  DateTime? get lastFullCheck => _lastFullCheck;

  // إحصائيات
  int get totalTowers => _towers.length;
  int get totalSectors => _towers.fold(0, (s, t) => s + t.sectors.length);
  int get onlineSectors => _towers.fold(0, (s, t) => s + t.onlineCount);
  int get offlineSectors => _towers.fold(0, (s, t) => s + t.offlineCount);
  int get warningSectors => _towers.fold(0, (s, t) => s + t.warningCount);
  int get totalClients => _towers.fold(0, (s, t) => s + t.totalClients);
  int get unreadAlerts => _alerts.where((a) => !a.isRead).length;

  /// تحميل البيانات المحفوظة
  Future<void> loadData() async {
    _towers = StorageService.loadTowers();
    _alerts = StorageService.loadAlerts();
    _settings = StorageService.loadSettings();
    notifyListeners();
    _startPeriodicCheck();
  }

  /// بدء الفحص الدوري
  void _startPeriodicCheck() {
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(
      Duration(minutes: _settings.checkIntervalMinutes),
      (_) => checkAllSectors(),
    );
  }

  /// إعادة تشغيل المؤقت عند تغيير الإعدادات
  void _restartTimer() {
    _startPeriodicCheck();
  }

  // ---- إدارة الأبراج ----

  Future<void> addTower(Tower tower) async {
    _towers.add(tower);
    await StorageService.saveTowers(_towers);
    notifyListeners();
  }

  Future<void> updateTower(Tower tower) async {
    final idx = _towers.indexWhere((t) => t.id == tower.id);
    if (idx != -1) {
      _towers[idx] = tower;
      await StorageService.saveTowers(_towers);
      notifyListeners();
    }
  }

  Future<void> deleteTower(String towerId) async {
    _towers.removeWhere((t) => t.id == towerId);
    await StorageService.saveTowers(_towers);
    notifyListeners();
  }

  // ---- إدارة السكاتر ----

  Future<void> addSector(String towerId, Sector sector) async {
    final tower = _towers.firstWhere((t) => t.id == towerId);
    tower.sectors.add(sector);
    await StorageService.saveTowers(_towers);
    notifyListeners();
  }

  Future<void> updateSector(String towerId, Sector sector) async {
    final tower = _towers.firstWhere((t) => t.id == towerId);
    final idx = tower.sectors.indexWhere((s) => s.id == sector.id);
    if (idx != -1) {
      tower.sectors[idx] = sector;
      await StorageService.saveTowers(_towers);
      notifyListeners();
    }
  }

  Future<void> deleteSector(String towerId, String sectorId) async {
    final tower = _towers.firstWhere((t) => t.id == towerId);
    tower.sectors.removeWhere((s) => s.id == sectorId);
    await StorageService.saveTowers(_towers);
    notifyListeners();
  }

  // ---- فحص SNMP ----

  Future<void> checkAllSectors() async {
    if (_isChecking) return;
    _isChecking = true;
    notifyListeners();

    for (final tower in _towers) {
      for (final sector in tower.sectors) {
        await _checkSingleSector(tower, sector);
      }
    }

    _lastFullCheck = DateTime.now();
    _isChecking = false;
    await StorageService.saveTowers(_towers);
    await StorageService.saveAlerts(_alerts);
    notifyListeners();
  }

  Future<void> checkSingleSector(String towerId, String sectorId) async {
    final tower = _towers.firstWhere((t) => t.id == towerId);
    final sector = tower.sectors.firstWhere((s) => s.id == sectorId);

    _isChecking = true;
    notifyListeners();

    await _checkSingleSector(tower, sector);

    _isChecking = false;
    await StorageService.saveTowers(_towers);
    await StorageService.saveAlerts(_alerts);
    notifyListeners();
  }

  Future<void> _checkSingleSector(Tower tower, Sector sector) async {
    final previousStatus = sector.status;
    final result = await SnmpService.checkSector(sector);

    sector.lastCheck = DateTime.now();

    if (result['online'] == true) {
      sector.sysName = result['sysName'] ?? '';
      sector.latencyMs = result['latencyMs'] ?? 0;
      sector.connectedClients = result['clients'] ?? 0;

      // تحقق من تجاوز الحد
      if (sector.connectedClients > sector.maxClients) {
        sector.status = SectorStatus.warning;
        if (previousStatus != SectorStatus.warning) {
          sector.lastStatusChange = DateTime.now();
          _addAlert(
            AlertType.clientOverload,
            tower.name,
            sector.name,
            sector.ipAddress,
            'تجاوز عدد المشتركين الحد المسموح: ${sector.connectedClients}/${sector.maxClients}',
          );
        }
      } else {
        sector.status = SectorStatus.online;
        // إشعار عودة للعمل
        if (previousStatus == SectorStatus.offline) {
          sector.lastStatusChange = DateTime.now();
          _addAlert(
            AlertType.sectorUp,
            tower.name,
            sector.name,
            sector.ipAddress,
            'عاد للعمل - المشتركين: ${sector.connectedClients}',
          );
        }
      }
    } else {
      sector.status = SectorStatus.offline;
      sector.connectedClients = 0;
      sector.latencyMs = 0;

      if (previousStatus != SectorStatus.offline &&
          previousStatus != SectorStatus.unknown) {
        sector.lastStatusChange = DateTime.now();
        _addAlert(
          AlertType.sectorDown,
          tower.name,
          sector.name,
          sector.ipAddress,
          'انقطع الاتصال بالسكتر',
        );
      } else if (previousStatus == SectorStatus.unknown) {
        sector.lastStatusChange = DateTime.now();
      }
    }
  }

  void _addAlert(AlertType type, String towerName, String sectorName,
      String sectorIp, String message) {
    final alert = AlertItem(
      type: type,
      towerName: towerName,
      sectorName: sectorName,
      sectorIp: sectorIp,
      message: message,
    );
    _alerts.insert(0, alert);

    // إرسال إشعار
    if (_settings.notificationsEnabled) {
      String title;
      switch (type) {
        case AlertType.sectorDown:
          title = '⛔ انقطاع: $sectorName - $towerName';
          break;
        case AlertType.sectorUp:
          title = '✅ عودة: $sectorName - $towerName';
          break;
        case AlertType.clientOverload:
          title = '⚠️ تحذير: $sectorName - $towerName';
          break;
      }
      NotificationService.showNotification(title: title, body: message);
    }
  }

  // ---- التنبيهات ----

  Future<void> markAlertRead(String alertId) async {
    final alert = _alerts.firstWhere((a) => a.id == alertId);
    alert.isRead = true;
    await StorageService.saveAlerts(_alerts);
    notifyListeners();
  }

  Future<void> markAllAlertsRead() async {
    for (final a in _alerts) {
      a.isRead = true;
    }
    await StorageService.saveAlerts(_alerts);
    notifyListeners();
  }

  Future<void> clearAlerts() async {
    _alerts.clear();
    await StorageService.saveAlerts(_alerts);
    notifyListeners();
  }

  // ---- الإعدادات ----

  Future<void> updateSettings(AppSettings newSettings) async {
    _settings = newSettings;
    await StorageService.saveSettings(_settings);
    _restartTimer();
    notifyListeners();
  }

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }
}

// ============================================================================
// WorkManager - فحص في الخلفية
// ============================================================================

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await StorageService.initialize();
      final towers = StorageService.loadTowers();
      final alerts = StorageService.loadAlerts();
      final settings = StorageService.loadSettings();

      await NotificationService.initialize();

      for (final tower in towers) {
        for (final sector in tower.sectors) {
          final previousStatus = sector.status;
          final result = await SnmpService.checkSector(sector);

          sector.lastCheck = DateTime.now();

          if (result['online'] == true) {
            sector.sysName = result['sysName'] ?? '';
            sector.latencyMs = result['latencyMs'] ?? 0;
            sector.connectedClients = result['clients'] ?? 0;

            if (sector.connectedClients > sector.maxClients) {
              sector.status = SectorStatus.warning;
              if (previousStatus != SectorStatus.warning) {
                sector.lastStatusChange = DateTime.now();
                final alert = AlertItem(
                  type: AlertType.clientOverload,
                  towerName: tower.name,
                  sectorName: sector.name,
                  sectorIp: sector.ipAddress,
                  message:
                      'تجاوز عدد المشتركين: ${sector.connectedClients}/${sector.maxClients}',
                );
                alerts.insert(0, alert);
                if (settings.notificationsEnabled) {
                  await NotificationService.showNotification(
                    title: '⚠️ تحذير: ${sector.name} - ${tower.name}',
                    body: alert.message,
                  );
                }
              }
            } else {
              sector.status = SectorStatus.online;
              if (previousStatus == SectorStatus.offline) {
                sector.lastStatusChange = DateTime.now();
                final alert = AlertItem(
                  type: AlertType.sectorUp,
                  towerName: tower.name,
                  sectorName: sector.name,
                  sectorIp: sector.ipAddress,
                  message: 'عاد للعمل - المشتركين: ${sector.connectedClients}',
                );
                alerts.insert(0, alert);
                if (settings.notificationsEnabled) {
                  await NotificationService.showNotification(
                    title: '✅ عودة: ${sector.name} - ${tower.name}',
                    body: alert.message,
                  );
                }
              }
            }
          } else {
            sector.status = SectorStatus.offline;
            sector.connectedClients = 0;
            sector.latencyMs = 0;

            if (previousStatus != SectorStatus.offline &&
                previousStatus != SectorStatus.unknown) {
              sector.lastStatusChange = DateTime.now();
              final alert = AlertItem(
                type: AlertType.sectorDown,
                towerName: tower.name,
                sectorName: sector.name,
                sectorIp: sector.ipAddress,
                message: 'انقطع الاتصال بالسكتر',
              );
              alerts.insert(0, alert);
              if (settings.notificationsEnabled) {
                await NotificationService.showNotification(
                  title: '⛔ انقطاع: ${sector.name} - ${tower.name}',
                  body: alert.message,
                );
              }
            }
          }
        }
      }

      await StorageService.saveTowers(towers);
      await StorageService.saveAlerts(alerts);
    } catch (_) {}
    return Future.value(true);
  });
}

// ============================================================================
// نقطة البداية
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await StorageService.initialize();
  await NotificationService.initialize();

  // تهيئة WorkManager
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  final settings = StorageService.loadSettings();
  await Workmanager().registerPeriodicTask(
    AppConstants.bgTaskName,
    AppConstants.bgTaskTag,
    frequency: Duration(minutes: max(15, settings.checkIntervalMinutes)),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..loadData(),
      child: const WispMonitorApp(),
    ),
  );
}

// ============================================================================
// التطبيق الرئيسي
// ============================================================================

class WispMonitorApp extends StatelessWidget {
  const WispMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WISP Monitor',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppConstants.bgPrimary,
        primaryColor: AppConstants.accentCyan,
        colorScheme: const ColorScheme.dark(
          primary: AppConstants.accentCyan,
          secondary: AppConstants.accentCyan,
          surface: AppConstants.bgCard,
          error: AppConstants.statusOffline,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppConstants.bgSecondary,
          foregroundColor: AppConstants.textPrimary,
          elevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardTheme(
          color: AppConstants.bgCard,
          elevation: 4,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppConstants.accentCyan,
          foregroundColor: AppConstants.bgPrimary,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppConstants.bgCardLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide:
                BorderSide(color: AppConstants.accentCyan.withOpacity(0.2)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppConstants.accentCyan),
          ),
          labelStyle: const TextStyle(color: AppConstants.textSecondary),
          hintStyle: const TextStyle(color: AppConstants.textSecondary),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppConstants.accentCyan,
            foregroundColor: AppConstants.bgPrimary,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppConstants.accentCyan,
          ),
        ),
        dialogTheme: DialogTheme(
          backgroundColor: AppConstants.bgSecondary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppConstants.bgCardLight,
          contentTextStyle: TextStyle(color: AppConstants.textPrimary),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: AppConstants.bgSecondary,
          selectedItemColor: AppConstants.accentCyan,
          unselectedItemColor: AppConstants.textSecondary,
          type: BottomNavigationBarType.fixed,
        ),
      ),
      locale: const Locale('ar'),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      home: const MainScreen(),
    );
  }
}

// ============================================================================
// الشاشة الرئيسية مع التنقل السفلي
// ============================================================================

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final _pages = const [
    DashboardPage(),
    TowersPage(),
    AlertsPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<AppState>().unreadAlerts;
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: AppConstants.accentCyan.withOpacity(0.15), width: 1),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (i) => setState(() => _currentIndex = i),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_rounded),
              label: 'الرئيسية',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.cell_tower_rounded),
              label: 'الأبراج',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread',
                    style: const TextStyle(fontSize: 10, color: Colors.white)),
                backgroundColor: AppConstants.statusOffline,
                child: const Icon(Icons.notifications_rounded),
              ),
              label: 'التنبيهات',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.settings_rounded),
              label: 'الإعدادات',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// أدوات مساعدة للواجهة
// ============================================================================

class _UIHelpers {
  static String formatDateTime(DateTime? dt) {
    if (dt == null) return '---';
    final formatter = intl.DateFormat('yyyy/MM/dd HH:mm:ss', 'en');
    return formatter.format(dt);
  }

  static String timeAgo(DateTime? dt) {
    if (dt == null) return '---';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    return 'منذ ${diff.inDays} يوم';
  }

  static Color statusColor(SectorStatus status) {
    switch (status) {
      case SectorStatus.online:
        return AppConstants.statusOnline;
      case SectorStatus.offline:
        return AppConstants.statusOffline;
      case SectorStatus.warning:
        return AppConstants.statusWarning;
      case SectorStatus.unknown:
        return AppConstants.textSecondary;
    }
  }

  static String statusText(SectorStatus status) {
    switch (status) {
      case SectorStatus.online:
        return 'متصل';
      case SectorStatus.offline:
        return 'منقطع';
      case SectorStatus.warning:
        return 'تحذير';
      case SectorStatus.unknown:
        return 'غير معروف';
    }
  }

  static IconData statusIcon(SectorStatus status) {
    switch (status) {
      case SectorStatus.online:
        return Icons.check_circle;
      case SectorStatus.offline:
        return Icons.cancel;
      case SectorStatus.warning:
        return Icons.warning;
      case SectorStatus.unknown:
        return Icons.help_outline;
    }
  }

  static String deviceTypeText(DeviceType type) {
    switch (type) {
      case DeviceType.ubnt:
        return 'UBNT (AirOS)';
      case DeviceType.mikrotik:
        return 'MikroTik';
    }
  }
}

// ============================================================================
// ويدجت بطاقة إحصائية
// ============================================================================

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppConstants.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              color: AppConstants.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// صفحة لوحة المعلومات (الرئيسية)
// ============================================================================

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering,
                color: AppConstants.accentCyan, size: 24),
            const SizedBox(width: 8),
            const Text(
              'WISP Monitor',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 20,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        actions: [
          if (state.isChecking)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppConstants.accentCyan,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'فحص الآن',
              onPressed: () => state.checkAllSectors(),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppConstants.accentCyan,
        backgroundColor: AppConstants.bgCard,
        onRefresh: () => state.checkAllSectors(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // آخر فحص
            if (state.lastFullCheck != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(Icons.access_time,
                        size: 14, color: AppConstants.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      'آخر فحص: ${_UIHelpers.timeAgo(state.lastFullCheck)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),

            // بطاقات الإحصائيات
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.3,
              children: [
                _StatCard(
                  title: 'الأبراج',
                  value: '${state.totalTowers}',
                  icon: Icons.cell_tower_rounded,
                  color: AppConstants.accentCyan,
                ),
                _StatCard(
                  title: 'السكاتر',
                  value: '${state.totalSectors}',
                  icon: Icons.router_rounded,
                  color: const Color(0xFF7C4DFF),
                ),
                _StatCard(
                  title: 'متصل',
                  value: '${state.onlineSectors}',
                  icon: Icons.check_circle_rounded,
                  color: AppConstants.statusOnline,
                ),
                _StatCard(
                  title: 'منقطع',
                  value: '${state.offlineSectors}',
                  icon: Icons.cancel_rounded,
                  color: AppConstants.statusOffline,
                ),
                _StatCard(
                  title: 'تحذير',
                  value: '${state.warningSectors}',
                  icon: Icons.warning_rounded,
                  color: AppConstants.statusWarning,
                ),
                _StatCard(
                  title: 'المشتركين',
                  value: '${state.totalClients}',
                  icon: Icons.people_rounded,
                  color: const Color(0xFF00BFA5),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // قائمة الأبراج السريعة
            if (state.towers.isNotEmpty) ...[
              Row(
                children: [
                  const Icon(Icons.cell_tower,
                      color: AppConstants.accentCyan, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'حالة الأبراج',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...state.towers.map((tower) => _TowerQuickCard(tower: tower)),
            ] else ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Column(
                    children: [
                      Icon(Icons.cell_tower_rounded,
                          size: 64,
                          color: AppConstants.accentCyan.withOpacity(0.3)),
                      const SizedBox(height: 16),
                      const Text(
                        'لا توجد أبراج بعد',
                        style: TextStyle(
                          fontSize: 18,
                          color: AppConstants.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'اذهب لصفحة الأبراج لإضافة أول برج',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppConstants.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TowerQuickCard extends StatelessWidget {
  final Tower tower;
  const _TowerQuickCard({required this.tower});

  @override
  Widget build(BuildContext context) {
    final statusColor = _UIHelpers.statusColor(tower.overallStatus);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppConstants.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          right: BorderSide(color: statusColor, width: 4),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.cell_tower, color: statusColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tower.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppConstants.textPrimary,
                  ),
                ),
                if (tower.location.isNotEmpty)
                  Text(
                    tower.location,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppConstants.textSecondary,
                    ),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _miniStat(Icons.router, '${tower.sectors.length}',
                        AppConstants.textSecondary),
                    const SizedBox(width: 12),
                    _miniStat(Icons.check_circle, '${tower.onlineCount}',
                        AppConstants.statusOnline),
                    const SizedBox(width: 12),
                    _miniStat(Icons.cancel, '${tower.offlineCount}',
                        AppConstants.statusOffline),
                    const SizedBox(width: 12),
                    _miniStat(Icons.people, '${tower.totalClients}',
                        AppConstants.accentCyan),
                  ],
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_left,
              color: AppConstants.textSecondary.withOpacity(0.5)),
        ],
      ),
    );
  }

  Widget _miniStat(IconData icon, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Text(value,
            style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ============================================================================
// صفحة الأبراج
// ============================================================================

class TowersPage extends StatelessWidget {
  const TowersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('الأبراج'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: state.isChecking ? null : () => state.checkAllSectors(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTowerDialog(context),
        child: const Icon(Icons.add),
      ),
      body: state.towers.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cell_tower_rounded,
                      size: 80,
                      color: AppConstants.accentCyan.withOpacity(0.2)),
                  const SizedBox(height: 16),
                  const Text(
                    'لا توجد أبراج',
                    style: TextStyle(
                        fontSize: 20, color: AppConstants.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'اضغط + لإضافة برج جديد',
                    style: TextStyle(
                        fontSize: 14, color: AppConstants.textSecondary),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: state.towers.length,
              itemBuilder: (ctx, i) =>
                  _TowerCard(tower: state.towers[i]),
            ),
    );
  }

  void _showTowerDialog(BuildContext context, {Tower? tower}) {
    final nameCtrl = TextEditingController(text: tower?.name ?? '');
    final locCtrl = TextEditingController(text: tower?.location ?? '');
    final isEdit = tower != null;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'تعديل البرج' : 'إضافة برج جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'اسم البرج',
                prefixIcon: Icon(Icons.cell_tower),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: locCtrl,
              decoration: const InputDecoration(
                labelText: 'الموقع (اختياري)',
                prefixIcon: Icon(Icons.location_on),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              final state = context.read<AppState>();
              if (isEdit) {
                tower!.name = nameCtrl.text.trim();
                tower.location = locCtrl.text.trim();
                state.updateTower(tower);
              } else {
                state.addTower(Tower(
                  name: nameCtrl.text.trim(),
                  location: locCtrl.text.trim(),
                ));
              }
              Navigator.pop(ctx);
            },
            child: Text(isEdit ? 'حفظ' : 'إضافة'),
          ),
        ],
      ),
    );
  }
}

class _TowerCard extends StatelessWidget {
  final Tower tower;
  const _TowerCard({required this.tower});

  @override
  Widget build(BuildContext context) {
    final statusColor = _UIHelpers.statusColor(tower.overallStatus);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TowerDetailPage(towerId: tower.id)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.cell_tower, color: statusColor, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tower.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        if (tower.location.isNotEmpty)
                          Text(
                            tower.location,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppConstants.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        color: AppConstants.textSecondary),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'edit', child: Text('تعديل')),
                      const PopupMenuItem(
                          value: 'delete',
                          child: Text('حذف',
                              style:
                                  TextStyle(color: AppConstants.statusOffline))),
                    ],
                    onSelected: (val) {
                      if (val == 'edit') {
                        _editTower(context);
                      } else if (val == 'delete') {
                        _confirmDelete(context);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // إحصائيات مصغرة
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppConstants.bgPrimary.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat('السكاتر', '${tower.sectors.length}',
                        AppConstants.textSecondary),
                    _divider(),
                    _stat('متصل', '${tower.onlineCount}',
                        AppConstants.statusOnline),
                    _divider(),
                    _stat('منقطع', '${tower.offlineCount}',
                        AppConstants.statusOffline),
                    _divider(),
                    _stat('المشتركين', '${tower.totalClients}',
                        AppConstants.accentCyan),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                fontSize: 10, color: AppConstants.textSecondary)),
      ],
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 30,
      color: AppConstants.textSecondary.withOpacity(0.2),
    );
  }

  void _editTower(BuildContext context) {
    final nameCtrl = TextEditingController(text: tower.name);
    final locCtrl = TextEditingController(text: tower.location);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل البرج'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'اسم البرج',
                prefixIcon: Icon(Icons.cell_tower),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: locCtrl,
              decoration: const InputDecoration(
                labelText: 'الموقع',
                prefixIcon: Icon(Icons.location_on),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              tower.name = nameCtrl.text.trim();
              tower.location = locCtrl.text.trim();
              context.read<AppState>().updateTower(tower);
              Navigator.pop(ctx);
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف البرج'),
        content: Text(
            'هل أنت متأكد من حذف "${tower.name}" وجميع السكاتر التابعة له؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.statusOffline),
            onPressed: () {
              context.read<AppState>().deleteTower(tower.id);
              Navigator.pop(ctx);
            },
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// صفحة تفاصيل البرج
// ============================================================================

class TowerDetailPage extends StatelessWidget {
  final String towerId;
  const TowerDetailPage({super.key, required this.towerId});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tower = state.towers.firstWhere((t) => t.id == towerId,
        orElse: () => Tower(name: ''));

    if (tower.name.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('غير موجود')),
        body: const Center(child: Text('البرج غير موجود')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tower.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: state.isChecking
                ? null
                : () {
                    for (final s in tower.sectors) {
                      state.checkSingleSector(tower.id, s.id);
                    }
                  },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showSectorDialog(context, tower),
        child: const Icon(Icons.add),
      ),
      body: tower.sectors.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.router_rounded,
                      size: 80,
                      color: AppConstants.accentCyan.withOpacity(0.2)),
                  const SizedBox(height: 16),
                  const Text(
                    'لا توجد سكاتر',
                    style: TextStyle(
                        fontSize: 20, color: AppConstants.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'اضغط + لإضافة سكتر جديد',
                    style: TextStyle(
                        fontSize: 14, color: AppConstants.textSecondary),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: tower.sectors.length,
              itemBuilder: (ctx, i) => _SectorCard(
                tower: tower,
                sector: tower.sectors[i],
              ),
            ),
    );
  }

  void _showSectorDialog(BuildContext context, Tower tower,
      {Sector? sector}) {
    final isEdit = sector != null;
    final nameCtrl = TextEditingController(text: sector?.name ?? '');
    final ipCtrl = TextEditingController(text: sector?.ipAddress ?? '');
    final modelCtrl = TextEditingController(text: sector?.model ?? '');
    final communityCtrl = TextEditingController(
        text: sector?.community ?? AppConstants.defaultCommunity);
    final maxClientsCtrl = TextEditingController(
        text: '${sector?.maxClients ?? AppConstants.defaultMaxClients}');
    DeviceType selectedType = sector?.deviceType ?? DeviceType.ubnt;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEdit ? 'تعديل السكتر' : 'إضافة سكتر جديد'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'اسم السكتر *',
                    prefixIcon: Icon(Icons.router),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: ipCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'عنوان IP *',
                    prefixIcon: Icon(Icons.lan),
                    hintText: '10.46.203.155',
                  ),
                ),
                const SizedBox(height: 10),
                // نوع الجهاز
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppConstants.bgCardLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppConstants.accentCyan.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.devices,
                          color: AppConstants.textSecondary),
                      const SizedBox(width: 12),
                      const Text('النوع:',
                          style:
                              TextStyle(color: AppConstants.textSecondary)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<DeviceType>(
                          segments: const [
                            ButtonSegment(
                                value: DeviceType.ubnt, label: Text('UBNT')),
                            ButtonSegment(
                                value: DeviceType.mikrotik,
                                label: Text('MikroTik')),
                          ],
                          selected: {selectedType},
                          onSelectionChanged: (s) {
                            setDialogState(() => selectedType = s.first);
                          },
                          style: ButtonStyle(
                            backgroundColor:
                                WidgetStateProperty.resolveWith((states) {
                              if (states.contains(WidgetState.selected)) {
                                return AppConstants.accentCyan.withOpacity(0.2);
                              }
                              return Colors.transparent;
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: modelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'الموديل (اختياري)',
                    prefixIcon: Icon(Icons.info_outline),
                    hintText: 'LiteBeam 5AC, SXT Lite5...',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: communityCtrl,
                  decoration: const InputDecoration(
                    labelText: 'SNMP Community',
                    prefixIcon: Icon(Icons.key),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: maxClientsCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'الحد الأقصى للمشتركين',
                    prefixIcon: Icon(Icons.people),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty ||
                    ipCtrl.text.trim().isEmpty) {
                  return;
                }
                final state = context.read<AppState>();
                if (isEdit) {
                  sector!.name = nameCtrl.text.trim();
                  sector.ipAddress = ipCtrl.text.trim();
                  sector.deviceType = selectedType;
                  sector.model = modelCtrl.text.trim();
                  sector.community = communityCtrl.text.trim().isEmpty
                      ? AppConstants.defaultCommunity
                      : communityCtrl.text.trim();
                  sector.maxClients =
                      int.tryParse(maxClientsCtrl.text) ??
                          AppConstants.defaultMaxClients;
                  state.updateSector(tower.id, sector);
                } else {
                  state.addSector(
                    tower.id,
                    Sector(
                      name: nameCtrl.text.trim(),
                      ipAddress: ipCtrl.text.trim(),
                      deviceType: selectedType,
                      model: modelCtrl.text.trim(),
                      community: communityCtrl.text.trim().isEmpty
                          ? AppConstants.defaultCommunity
                          : communityCtrl.text.trim(),
                      maxClients: int.tryParse(maxClientsCtrl.text) ??
                          AppConstants.defaultMaxClients,
                    ),
                  );
                }
                Navigator.pop(ctx);
              },
              child: Text(isEdit ? 'حفظ' : 'إضافة'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectorCard extends StatelessWidget {
  final Tower tower;
  final Sector sector;
  const _SectorCard({required this.tower, required this.sector});

  @override
  Widget build(BuildContext context) {
    final color = _UIHelpers.statusColor(sector.status);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showSectorDetails(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  // أيقونة الحالة
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(_UIHelpers.statusIcon(sector.status),
                        color: color, size: 26),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sector.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              sector.ipAddress,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppConstants.accentCyan.withOpacity(0.7),
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppConstants.bgCardLight,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _UIHelpers.deviceTypeText(sector.deviceType),
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppConstants.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert,
                        color: AppConstants.textSecondary, size: 20),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'check', child: Text('فحص الآن')),
                      const PopupMenuItem(
                          value: 'edit', child: Text('تعديل')),
                      const PopupMenuItem(
                          value: 'delete',
                          child: Text('حذف',
                              style: TextStyle(
                                  color: AppConstants.statusOffline))),
                    ],
                    onSelected: (val) {
                      final state = context.read<AppState>();
                      if (val == 'check') {
                        state.checkSingleSector(tower.id, sector.id);
                      } else if (val == 'edit') {
                        _editSector(context);
                      } else if (val == 'delete') {
                        _confirmDelete(context);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // معلومات مصغرة
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppConstants.bgPrimary.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _info(
                      Icons.signal_cellular_alt,
                      _UIHelpers.statusText(sector.status),
                      color,
                    ),
                    _info(
                      Icons.people,
                      '${sector.connectedClients}/${sector.maxClients}',
                      sector.connectedClients > sector.maxClients
                          ? AppConstants.statusWarning
                          : AppConstants.accentCyan,
                    ),
                    _info(
                      Icons.speed,
                      sector.latencyMs > 0
                          ? '${sector.latencyMs}ms'
                          : '---',
                      sector.latencyMs > 100
                          ? AppConstants.statusWarning
                          : AppConstants.statusOnline,
                    ),
                    _info(
                      Icons.access_time,
                      _UIHelpers.timeAgo(sector.lastCheck),
                      AppConstants.textSecondary,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _info(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                fontSize: 11, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }

  void _showSectorDetails(BuildContext context) {
    final color = _UIHelpers.statusColor(sector.status);
    showModalBottomSheet(
      context: context,
      backgroundColor: AppConstants.bgSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // المقبض
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppConstants.textSecondary.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            // العنوان
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(_UIHelpers.statusIcon(sector.status),
                      color: color, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sector.name,
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.textPrimary)),
                      Text(
                        '${tower.name} • ${_UIHelpers.deviceTypeText(sector.deviceType)}',
                        style: const TextStyle(
                            fontSize: 13, color: AppConstants.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // التفاصيل
            _detailRow('عنوان IP', sector.ipAddress),
            _detailRow('الحالة', _UIHelpers.statusText(sector.status)),
            _detailRow('الموديل', sector.model.isEmpty ? '---' : sector.model),
            _detailRow('SNMP Community', sector.community),
            _detailRow('اسم النظام (sysName)',
                sector.sysName.isEmpty ? '---' : sector.sysName),
            _detailRow('المشتركين',
                '${sector.connectedClients} / ${sector.maxClients}'),
            _detailRow('زمن الاستجابة',
                sector.latencyMs > 0 ? '${sector.latencyMs} ms' : '---'),
            _detailRow('آخر فحص', _UIHelpers.formatDateTime(sector.lastCheck)),
            _detailRow('آخر تغيير حالة',
                _UIHelpers.formatDateTime(sector.lastStatusChange)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  context
                      .read<AppState>()
                      .checkSingleSector(tower.id, sector.id);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('فحص الآن'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppConstants.textSecondary)),
          Flexible(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppConstants.textPrimary,
                    fontWeight: FontWeight.w500),
                textAlign: TextAlign.left),
          ),
        ],
      ),
    );
  }

  void _editSector(BuildContext context) {
    final nameCtrl = TextEditingController(text: sector.name);
    final ipCtrl = TextEditingController(text: sector.ipAddress);
    final modelCtrl = TextEditingController(text: sector.model);
    final communityCtrl = TextEditingController(text: sector.community);
    final maxClientsCtrl =
        TextEditingController(text: '${sector.maxClients}');
    DeviceType selectedType = sector.deviceType;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('تعديل السكتر'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: 'اسم السكتر',
                        prefixIcon: Icon(Icons.router))),
                const SizedBox(height: 10),
                TextField(
                    controller: ipCtrl,
                    decoration: const InputDecoration(
                        labelText: 'عنوان IP',
                        prefixIcon: Icon(Icons.lan))),
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppConstants.bgCardLight,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Text('النوع:',
                          style:
                              TextStyle(color: AppConstants.textSecondary)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<DeviceType>(
                          segments: const [
                            ButtonSegment(
                                value: DeviceType.ubnt, label: Text('UBNT')),
                            ButtonSegment(
                                value: DeviceType.mikrotik,
                                label: Text('MikroTik')),
                          ],
                          selected: {selectedType},
                          onSelectionChanged: (s) {
                            setDialogState(() => selectedType = s.first);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: modelCtrl,
                    decoration: const InputDecoration(
                        labelText: 'الموديل',
                        prefixIcon: Icon(Icons.info_outline))),
                const SizedBox(height: 10),
                TextField(
                    controller: communityCtrl,
                    decoration: const InputDecoration(
                        labelText: 'SNMP Community',
                        prefixIcon: Icon(Icons.key))),
                const SizedBox(height: 10),
                TextField(
                    controller: maxClientsCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                        labelText: 'الحد الأقصى للمشتركين',
                        prefixIcon: Icon(Icons.people))),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty ||
                    ipCtrl.text.trim().isEmpty) return;
                sector.name = nameCtrl.text.trim();
                sector.ipAddress = ipCtrl.text.trim();
                sector.deviceType = selectedType;
                sector.model = modelCtrl.text.trim();
                sector.community = communityCtrl.text.trim().isEmpty
                    ? AppConstants.defaultCommunity
                    : communityCtrl.text.trim();
                sector.maxClients = int.tryParse(maxClientsCtrl.text) ??
                    AppConstants.defaultMaxClients;
                context.read<AppState>().updateSector(tower.id, sector);
                Navigator.pop(ctx);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف السكتر'),
        content: Text('هل أنت متأكد من حذف "${sector.name}"؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.statusOffline),
            onPressed: () {
              context.read<AppState>().deleteSector(tower.id, sector.id);
              Navigator.pop(ctx);
            },
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// صفحة التنبيهات
// ============================================================================

class AlertsPage extends StatelessWidget {
  const AlertsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('التنبيهات'),
        actions: [
          if (state.alerts.isNotEmpty) ...[
            IconButton(
              icon: const Icon(Icons.done_all),
              tooltip: 'قراءة الكل',
              onPressed: () => state.markAllAlertsRead(),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'مسح الكل',
              onPressed: () => _confirmClear(context),
            ),
          ],
        ],
      ),
      body: state.alerts.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.notifications_off_rounded,
                      size: 80,
                      color: AppConstants.accentCyan.withOpacity(0.2)),
                  const SizedBox(height: 16),
                  const Text(
                    'لا توجد تنبيهات',
                    style: TextStyle(
                        fontSize: 20, color: AppConstants.textSecondary),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: state.alerts.length,
              itemBuilder: (ctx, i) {
                final alert = state.alerts[i];
                return _AlertCard(alert: alert);
              },
            ),
    );
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('مسح التنبيهات'),
        content: const Text('هل أنت متأكد من مسح جميع التنبيهات؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.statusOffline),
            onPressed: () {
              context.read<AppState>().clearAlerts();
              Navigator.pop(ctx);
            },
            child: const Text('مسح', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AlertItem alert;
  const _AlertCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: alert.isRead
            ? AppConstants.bgCard
            : AppConstants.bgCard.withOpacity(0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border(
          right: BorderSide(color: alert.color, width: 4),
        ),
        boxShadow: alert.isRead
            ? null
            : [
                BoxShadow(
                  color: alert.color.withOpacity(0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (!alert.isRead) {
            context.read<AppState>().markAlertRead(alert.id);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: alert.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(alert.icon, color: alert.color, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${alert.emoji} ${alert.sectorName}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: alert.isRead
                                  ? FontWeight.normal
                                  : FontWeight.bold,
                              color: AppConstants.textPrimary,
                            ),
                          ),
                        ),
                        if (!alert.isRead)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: AppConstants.accentCyan,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      alert.towerName,
                      style: const TextStyle(
                          fontSize: 12, color: AppConstants.textSecondary),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      alert.message,
                      style: const TextStyle(
                          fontSize: 13, color: AppConstants.textPrimary),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.access_time,
                            size: 11, color: AppConstants.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          _UIHelpers.formatDateTime(alert.timestamp),
                          style: const TextStyle(
                              fontSize: 11, color: AppConstants.textSecondary),
                        ),
                        if (alert.sectorIp.isNotEmpty) ...[
                          const SizedBox(width: 12),
                          Text(
                            alert.sectorIp,
                            style: TextStyle(
                              fontSize: 11,
                              color:
                                  AppConstants.accentCyan.withOpacity(0.6),
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// صفحة الإعدادات
// ============================================================================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _intervalCtrl;
  late TextEditingController _communityCtrl;
  late TextEditingController _maxClientsCtrl;
  late TextEditingController _timeoutCtrl;
  late bool _notificationsEnabled;
  late bool _soundEnabled;
  late bool _vibrationEnabled;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppState>().settings;
    _intervalCtrl =
        TextEditingController(text: '${settings.checkIntervalMinutes}');
    _communityCtrl =
        TextEditingController(text: settings.defaultCommunity);
    _maxClientsCtrl =
        TextEditingController(text: '${settings.defaultMaxClients}');
    _timeoutCtrl =
        TextEditingController(text: '${settings.snmpTimeoutSeconds}');
    _notificationsEnabled = settings.notificationsEnabled;
    _soundEnabled = settings.soundEnabled;
    _vibrationEnabled = settings.vibrationEnabled;
  }

  @override
  void dispose() {
    _intervalCtrl.dispose();
    _communityCtrl.dispose();
    _maxClientsCtrl.dispose();
    _timeoutCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final state = context.read<AppState>();
    final newSettings = AppSettings(
      checkIntervalMinutes:
          int.tryParse(_intervalCtrl.text) ?? AppConstants.defaultCheckInterval,
      defaultCommunity: _communityCtrl.text.trim().isEmpty
          ? AppConstants.defaultCommunity
          : _communityCtrl.text.trim(),
      defaultMaxClients: int.tryParse(_maxClientsCtrl.text) ??
          AppConstants.defaultMaxClients,
      snmpTimeoutSeconds:
          int.tryParse(_timeoutCtrl.text) ?? AppConstants.snmpTimeout,
      notificationsEnabled: _notificationsEnabled,
      soundEnabled: _soundEnabled,
      vibrationEnabled: _vibrationEnabled,
    );
    state.updateSettings(newSettings);

    // إعادة تسجيل WorkManager
    Workmanager().registerPeriodicTask(
      AppConstants.bgTaskName,
      AppConstants.bgTaskTag,
      frequency:
          Duration(minutes: max(15, newSettings.checkIntervalMinutes)),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم حفظ الإعدادات'),
        backgroundColor: AppConstants.accentCyanDark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save_rounded),
            tooltip: 'حفظ',
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // قسم المراقبة
          _sectionTitle('المراقبة', Icons.monitor_heart),
          const SizedBox(height: 10),
          _settingCard([
            _textField(
              controller: _intervalCtrl,
              label: 'فترة الفحص (دقائق)',
              icon: Icons.timer,
              hint: 'الحد الأدنى 1 دقيقة (15 دقيقة في الخلفية)',
              isNumber: true,
            ),
            const Divider(color: AppConstants.bgPrimary),
            _textField(
              controller: _timeoutCtrl,
              label: 'مهلة SNMP (ثواني)',
              icon: Icons.hourglass_bottom,
              hint: 'الافتراضي 5 ثواني',
              isNumber: true,
            ),
          ]),

          const SizedBox(height: 20),

          // قسم SNMP
          _sectionTitle('SNMP الافتراضي', Icons.settings_ethernet),
          const SizedBox(height: 10),
          _settingCard([
            _textField(
              controller: _communityCtrl,
              label: 'Community الافتراضي',
              icon: Icons.key,
              hint: 'public',
            ),
            const Divider(color: AppConstants.bgPrimary),
            _textField(
              controller: _maxClientsCtrl,
              label: 'الحد الأقصى للمشتركين (افتراضي)',
              icon: Icons.people,
              hint: '8',
              isNumber: true,
            ),
          ]),

          const SizedBox(height: 20),

          // قسم الإشعارات
          _sectionTitle('الإشعارات', Icons.notifications),
          const SizedBox(height: 10),
          _settingCard([
            _switchTile(
              'تفعيل الإشعارات',
              Icons.notifications_active,
              _notificationsEnabled,
              (v) => setState(() => _notificationsEnabled = v),
            ),
            const Divider(color: AppConstants.bgPrimary),
            _switchTile(
              'صوت الإشعار',
              Icons.volume_up,
              _soundEnabled,
              (v) => setState(() => _soundEnabled = v),
            ),
            const Divider(color: AppConstants.bgPrimary),
            _switchTile(
              'الاهتزاز',
              Icons.vibration,
              _vibrationEnabled,
              (v) => setState(() => _vibrationEnabled = v),
            ),
          ]),

          const SizedBox(height: 20),

          // معلومات
          _sectionTitle('معلومات', Icons.info_outline),
          const SizedBox(height: 10),
          _settingCard([
            _infoRow('الإصدار', '1.0.0'),
            const Divider(color: AppConstants.bgPrimary),
            _infoRow('بروتوكول', 'SNMP v2c'),
            const Divider(color: AppConstants.bgPrimary),
            _infoRow('OID فحص الاتصال', 'sysName (1.3.6.1.2.1.1.5.0)'),
            const Divider(color: AppConstants.bgPrimary),
            _infoRow('OID مشتركين UBNT', '1.3.6.1.4.1.41112.1.4.7.1.1'),
            const Divider(color: AppConstants.bgPrimary),
            _infoRow(
                'OID مشتركين MikroTik', '1.3.6.1.4.1.14988.1.1.1.2.1.1'),
          ]),

          const SizedBox(height: 30),

          // زر الحفظ
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('حفظ الإعدادات',
                  style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppConstants.accentCyan, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppConstants.accentCyan,
          ),
        ),
      ],
    );
  }

  Widget _settingCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: AppConstants.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppConstants.accentCyan.withOpacity(0.1)),
      ),
      padding: const EdgeInsets.all(4),
      child: Column(children: children),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? hint,
    bool isNumber = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        controller: controller,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        inputFormatters:
            isNumber ? [FilteringTextInputFormatter.digitsOnly] : null,
        style: const TextStyle(color: AppConstants.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, color: AppConstants.accentCyan, size: 20),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  Widget _switchTile(
      String title, IconData icon, bool value, Function(bool) onChanged) {
    return ListTile(
      leading: Icon(icon, color: AppConstants.accentCyan, size: 22),
      title: Text(title,
          style: const TextStyle(
              fontSize: 14, color: AppConstants.textPrimary)),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppConstants.accentCyan,
        activeTrackColor: AppConstants.accentCyan.withOpacity(0.3),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppConstants.textSecondary)),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 12,
                color: AppConstants.textPrimary,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.left,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
