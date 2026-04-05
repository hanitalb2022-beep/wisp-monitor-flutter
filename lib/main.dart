import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dart_snmp/dart_snmp.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const bg = Color(0xFF05080F);
const card = Color(0xFF111D2E);
const border = Color(0xFF1C2D44);
const cyan = Color(0xFF00E5FF);
const green = Color(0xFF00E676);
const red = Color(0xFFFF1744);
const amber = Color(0xFFFFAB00);
const textSec = Color(0xFF8899B0);
const textMut = Color(0xFF4A5D78);

enum Brand { ubnt, mikrotik }

class Sector {
  final String id;
  String name, ip, model, community;
  Brand brand;
  int subs, maxSubs;
  bool online;
  double? ping;
  DateTime? checked;
  Sector({required this.id, required this.name, required this.ip, this.brand = Brand.ubnt, this.model = '', this.community = 'public', this.subs = 0, this.maxSubs = 8, this.online = false, this.ping, this.checked});
  bool get over => subs > maxSubs;
  Map toJson() => {'id': id, 'name': name, 'ip': ip, 'brand': brand.index, 'model': model, 'community': community, 'subs': subs, 'maxSubs': maxSubs, 'online': online, 'ping': ping, 'checked': checked?.toIso8601String()};
  factory Sector.fromJson(Map j) => Sector(id: j['id'], name: j['name'], ip: j['ip'], brand: Brand.values[j['brand'] ?? 0], model: j['model'] ?? '', community: j['community'] ?? 'public', subs: j['subs'] ?? 0, maxSubs: j['maxSubs'] ?? 8, online: j['online'] ?? false, ping: j['ping']?.toDouble(), checked: j['checked'] != null ? DateTime.parse(j['checked']) : null);
}

class Tower {
  final String id;
  String name, location;
  List<Sector> sectors;
  Tower({required this.id, required this.name, this.location = '', List<Sector>? sectors}) : sectors = sectors ?? [];
  int get totalSubs => sectors.fold(0, (a, s) => a + s.subs);
  int get offCount => sectors.where((s) => !s.online).length;
  int get overCount => sectors.where((s) => s.over).length;
  bool get hasIssue => offCount > 0 || overCount > 0;
  Map toJson() => {'id': id, 'name': name, 'location': location, 'sectors': sectors.map((s) => s.toJson()).toList()};
  factory Tower.fromJson(Map j) => Tower(id: j['id'], name: j['name'], location: j['location'] ?? '', sectors: (j['sectors'] as List?)?.map((s) => Sector.fromJson(s)).toList() ?? []);
}

class SnmpSvc {
  static Future<Map<String, dynamic>> check(Sector s) async {
    final sw = Stopwatch()..start();
    Snmp? sess;
    try {
      sess = await Snmp.createSession(InternetAddress(s.ip), community: s.community);
      final msg = await sess.get(Oid.fromString('1.3.6.1.2.1.1.5.0')).timeout(const Duration(seconds: 3));
      sw.stop();
      if (msg.pdu.varbinds.isEmpty) return {'online': false};
      int? count = await _getSubs(sess, s.brand);
      return {'online': true, 'ping': sw.elapsedMilliseconds.toDouble(), 'subs': count};
    } catch (e) {
      return {'online': false};
    } finally {
      sess?.close();
    }
  }

  static Future<int?> _getSubs(Snmp sess, Brand brand) async {
    try {
      final base = brand == Brand.ubnt ? '1.3.6.1.4.1.41112.1.4.7.1.1' : '1.3.6.1.4.1.14988.1.1.1.2.1.1';
      int count = 0;
      var current = Oid.fromString(base);
      for (int i = 0; i < 100; i++) {
        try {
          final msg = await sess.getNext(current).timeout(const Duration(seconds: 2));
          if (msg.pdu.varbinds.isEmpty) break;
          final next = msg.pdu.varbinds.first.oid.toString();
          if (!next.startsWith(base + '.')) break;
          count++;
          current = Oid.fromString(next);
        } catch (_) { break; }
      }
      return count;
    } catch (_) { return null; }
  }
}

class Notif {
  static final _p = FlutterLocalNotificationsPlugin();
  static Future<void> init() async {
    await _p.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    await _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }
  static Future<void> show(String title, String body) async {
    await _p.show(DateTime.now().millisecondsSinceEpoch.remainder(100000), title, body, const NotificationDetails(android: AndroidNotificationDetails('wisp', 'تنبيهات', importance: Importance.max, priority: Priority.max, playSound: true, enableVibration: true)));
  }
}

class AppState extends ChangeNotifier {
  List<Tower> towers = [];
  List<String> alerts = [];
  bool scanning = false, loading = true;
  Timer? _t;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('towers');
    if (s != null) { try { towers = (jsonDecode(s) as List).map((j) => Tower.fromJson(j)).toList(); } catch (_) {} }
    final a = p.getString('alerts');
    if (a != null) { try { alerts = List<String>.from(jsonDecode(a)); } catch (_) {} }
    loading = false;
    notifyListeners();
    _t = Timer.periodic(const Duration(minutes: 5), (_) => scanAll());
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('towers', jsonEncode(towers.map((t) => t.toJson()).toList()));
    await p.setString('alerts', jsonEncode(alerts));
  }

  int get totalSectors => towers.fold(0, (a, t) => a + t.sectors.length);
  int get totalSubs => towers.fold(0, (a, t) => a + t.totalSubs);
  int get onlineCount => towers.fold(0, (a, t) => a + t.sectors.where((s) => s.online).length);
  int get offCount => towers.fold(0, (a, t) => a + t.offCount);
  int get overCount => towers.fold(0, (a, t) => a + t.overCount);

  Future<void> scanAll() async {
    if (scanning || towers.isEmpty) return;
    scanning = true;
    notifyListeners();
    for (final t in towers) {
      for (final s in t.sectors) {
        await _checkOne(t, s);
      }
    }
    await _save();
    scanning = false;
    notifyListeners();
  }

  Future<void> scanOne(Tower t, Sector s) async {
    scanning = true;
    notifyListeners();
    await _checkOne(t, s);
    await _save();
    scanning = false;
    notifyListeners();
  }

  Future<void> _checkOne(Tower t, Sector s) async {
    final wasOnline = s.online;
    final oldSubs = s.subs;
    final result = await SnmpSvc.check(s);
    s.online = result['online'] ?? false;
    s.ping = result['ping'];
    s.checked = DateTime.now();
    if (result['subs'] != null) s.subs = result['subs'];

    if (wasOnline && !s.online) {
      _alert('⛔ ${s.name} في ${t.name} - انقطعت الخدمة');
      Notif.show('⛔ سكتر متوقف', '${s.name} - ${t.name}');
    } else if (!wasOnline && s.online) {
      _alert('✅ ${s.name} في ${t.name} - عاد للاتصال');
    }
    if (s.subs > s.maxSubs && oldSubs <= s.maxSubs) {
      _alert('⚠️ ${s.name} في ${t.name} - ${s.subs} مشترك');
      Notif.show('⚠️ سكتر محمّل', '${s.name} - ${s.subs} مشترك');
    }
  }

  void _alert(String msg) {
    alerts.insert(0, '${DateTime.now().toIso8601String()}|$msg');
    if (alerts.length > 50) alerts = alerts.sublist(0, 50);
  }

  Future<void> addTower(String name, String loc) async {
    towers.add(Tower(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name, location: loc));
    await _save();
    notifyListeners();
  }

  Future<void> removeTower(String id) async {
    towers.removeWhere((t) => t.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> addSector(String tid, Sector s) async {
    towers.firstWhere((t) => t.id == tid).sectors.add(s);
    await _save();
    notifyListeners();
  }

  Future<void> removeSector(String tid, String sid) async {
    towers.firstWhere((t) => t.id == tid).sectors.removeWhere((s) => s.id == sid);
    await _save();
    notifyListeners();
  }

  void clearAlerts() { alerts.clear(); _save(); notifyListeners(); }

  @override
  void dispose() { _t?.cancel(); super.dispose(); }
  }
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notif.init();
  runApp(ChangeNotifierProvider(create: (_) => AppState()..init(), child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
    title: 'مراقب الشبكة',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: cyan, surface: card, error: red),
      appBarTheme: const AppBarTheme(backgroundColor: card, elevation: 0),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: cyan, foregroundColor: bg),
      elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(backgroundColor: cyan, foregroundColor: bg, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)))),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: bg, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: border)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: border)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: cyan))),
    ),
    home: const Dashboard(),
  );
}

class Dashboard extends StatelessWidget {
  const Dashboard({super.key});
  @override
  Widget build(BuildContext c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Consumer<AppState>(
      builder: (c, s, _) => s.loading ? const Scaffold(body: Center(child: CircularProgressIndicator(color: cyan))) : Scaffold(
        appBar: AppBar(
          title: const Row(children: [Icon(Icons.cell_tower, color: cyan), SizedBox(width: 8), Text('مراقب الشبكة', style: TextStyle(fontWeight: FontWeight.w900))]),
          actions: [
            IconButton(onPressed: s.scanning ? null : () => s.scanAll(), icon: s.scanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: cyan)) : const Icon(Icons.refresh, color: cyan)),
            Stack(children: [
              IconButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const AlertsView())), icon: Icon(Icons.notifications_outlined, color: s.alerts.isNotEmpty ? amber : textMut)),
              if (s.alerts.isNotEmpty) Positioned(right: 8, top: 8, child: Container(padding: const EdgeInsets.all(4), decoration: const BoxDecoration(color: red, shape: BoxShape.circle), child: Text('${s.alerts.length}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white)))),
            ]),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            _stat(Icons.cell_tower, 'أبراج', '${s.towers.length}', cyan),
            const SizedBox(width: 8),
            _stat(Icons.router, 'سكاتر', '${s.totalSectors}', cyan),
            const SizedBox(width: 8),
            _stat(Icons.people, 'مشتركين', '${s.totalSubs}', green),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _chip('${s.onlineCount} متصل', green),
            const SizedBox(width: 8),
            _chip('${s.offCount} منقطع', red),
            const SizedBox(width: 8),
            _chip('${s.overCount} محمّل', amber),
          ]),
          const SizedBox(height: 16),
          const Text('الأبراج', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          if (s.towers.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Column(children: [Icon(Icons.cell_tower, size: 64, color: textMut), SizedBox(height: 12), Text('لا توجد أبراج', style: TextStyle(color: textSec)), SizedBox(height: 4), Text('اضغط + لإضافة أول برج', style: TextStyle(fontSize: 13, color: textMut))])),
          ...s.towers.map((t) => _towerCard(c, t)),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: () => _addTowerSheet(c), child: const Icon(Icons.add)),
      ),
    ),
  );

  Widget _stat(IconData i, String l, String v, Color col) => Expanded(child: Container(padding: const EdgeInsets.symmetric(vertical: 14), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)), child: Column(children: [Icon(i, size: 18, color: col), const SizedBox(height: 4), Text(v, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: col)), Text(l, style: const TextStyle(fontSize: 11, color: textMut))])));

  Widget _chip(String l, Color col) => Expanded(child: Container(padding: const EdgeInsets.symmetric(vertical: 8), decoration: BoxDecoration(color: col.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: col.withOpacity(0.25))), child: Center(child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: col)))));

  Widget _towerCard(BuildContext c, Tower t) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    color: card,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.hasIssue ? (t.offCount > 0 ? red : amber).withOpacity(0.4) : border)),
    child: InkWell(
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TowerView(tid: t.id))),
      borderRadius: BorderRadius.circular(14),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: (t.hasIssue ? (t.offCount > 0 ? red : amber) : cyan).withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.cell_tower, color: t.hasIssue ? (t.offCount > 0 ? red : amber) : cyan)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            if (t.location.isNotEmpty) Text(t.location, style: const TextStyle(fontSize: 11, color: textMut)),
            const SizedBox(height: 4),
            Text('${t.sectors.length} سكتر • ${t.totalSubs} مشترك', style: const TextStyle(fontSize: 12, color: textSec)),
          ])),
          if (t.offCount > 0) _badge('⛔ ${t.offCount}', red),
          if (t.overCount > 0) _badge('⚠️ ${t.overCount}', amber),
          if (!t.hasIssue && t.sectors.isNotEmpty) _badge('✓', green),
          const Icon(Icons.chevron_left, color: textMut),
        ]),
        if (t.sectors.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: t.sectors.map((s) => Expanded(child: Container(height: 4, margin: const EdgeInsets.symmetric(horizontal: 2), decoration: BoxDecoration(color: !s.online ? red : s.over ? amber : green, borderRadius: BorderRadius.circular(2))))).toList()),
        ],
      ])),
    ),
  );

  Widget _badge(String t, Color col) => Container(margin: const EdgeInsets.only(right: 4), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: col.withOpacity(0.15), borderRadius: BorderRadius.circular(6)), child: Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: col)));

  void _addTowerSheet(BuildContext c) {
    final n = TextEditingController(), l = TextEditingController();
    showModalBottomSheet(context: c, isScrollControlled: true, backgroundColor: card, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => Directionality(textDirection: TextDirection.rtl, child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('إضافة برج جديد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 20),
      TextField(controller: n, autofocus: true, decoration: const InputDecoration(labelText: 'اسم البرج', prefixIcon: Icon(Icons.cell_tower))),
      const SizedBox(height: 12),
      TextField(controller: l, decoration: const InputDecoration(labelText: 'الموقع (اختياري)', prefixIcon: Icon(Icons.location_on_outlined))),
      const SizedBox(height: 20),
      ElevatedButton.icon(onPressed: () { if (n.text.trim().isEmpty) return; c.read<AppState>().addTower(n.text.trim(), l.text.trim()); Navigator.pop(ctx); }, icon: const Icon(Icons.add), label: const Text('إضافة')),
      const SizedBox(height: 20),
    ]))));
  }
}

class TowerView extends StatelessWidget {
  final String tid;
  const TowerView({super.key, required this.tid});
  @override
  Widget build(BuildContext c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Consumer<AppState>(builder: (c, s, _) {
      final t = s.towers.firstWhere((x) => x.id == tid, orElse: () => Tower(id: '', name: ''));
      if (t.id.isEmpty) { WidgetsBinding.instance.addPostFrameCallback((_) => Navigator.pop(c)); return const Scaffold(); }
      return Scaffold(
        appBar: AppBar(
          title: Text(t.name),
          actions: [
            IconButton(onPressed: s.scanning ? null : () => s.scanAll(), icon: const Icon(Icons.refresh, color: cyan)),
            IconButton(onPressed: () { s.removeTower(t.id); Navigator.pop(c); }, icon: const Icon(Icons.delete_outline, color: red)),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (t.sectors.isEmpty) const Padding(padding: EdgeInsets.all(40), child: Column(children: [Icon(Icons.router, size: 48, color: textMut), SizedBox(height: 8), Text('لا توجد سكاتر', style: TextStyle(color: textSec)), Text('اضغط + لإضافة سكتر', style: TextStyle(fontSize: 12, color: textMut))])),
          ...t.sectors.map((sec) => _sectorCard(c, s, t, sec)),
        ]),
        floatingActionButton: FloatingActionButton(onPressed: () => _addSectorSheet(c, t), child: const Icon(Icons.add)),
      );
    }),
  );

  Widget _sectorCard(BuildContext c, AppState st, Tower t, Sector s) {
    final col = !s.online ? red : s.over ? amber : border;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: !s.online ? red.withOpacity(0.05) : s.over ? amber.withOpacity(0.05) : card, borderRadius: BorderRadius.circular(14), border: Border.all(color: col.withOpacity(0.4))),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: s.online ? green : red, boxShadow: [BoxShadow(color: (s.online ? green : red).withOpacity(0.6), blurRadius: 8)])),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text('${s.brand == Brand.ubnt ? "UBNT" : "MikroTik"}${s.model.isNotEmpty ? " — ${s.model}" : ""}', style: TextStyle(fontSize: 11, color: s.brand == Brand.ubnt ? const Color(0xFF0077FF) : const Color(0xFFC62828), fontWeight: FontWeight.w700)),
          ])),
          IconButton(onPressed: () => st.scanOne(t, s), icon: const Icon(Icons.refresh, size: 18, color: cyan), visualDensity: VisualDensity.compact),
          IconButton(onPressed: () => st.removeSector(t.id, s.id), icon: const Icon(Icons.delete_outline, size: 18, color: textMut), visualDensity: VisualDensity.compact),
        ]),
        const SizedBox(height: 10),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)), child: Row(children: [
          const Icon(Icons.language, size: 14, color: textMut),
          const SizedBox(width: 6),
          Text(s.ip, style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          const Spacer(),
          Text(s.ping != null ? '${s.ping!.toInt()}ms' : '—', style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: s.ping != null ? (s.ping! < 30 ? green : s.ping! < 60 ? amber : red) : red)),
        ])),
        const SizedBox(height: 10),
        Row(children: [
          const Icon(Icons.people, size: 16, color: textMut),
          const SizedBox(width: 6),
          Text('${s.subs}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: s.over ? red : s.subs == s.maxSubs ? amber : Colors.white)),
          Text(' / ${s.maxSubs} مشترك', style: const TextStyle(fontSize: 12, color: textSec)),
          const SizedBox(width: 10),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: (s.subs / (s.maxSubs + 4)).clamp(0.0, 1.0), backgroundColor: border, valueColor: AlwaysStoppedAnimation(s.over ? red : s.subs == s.maxSubs ? amber : cyan), minHeight: 5))),
        ]),
        if (s.over) Padding(padding: const EdgeInsets.only(top: 8), child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: amber.withOpacity(0.12), borderRadius: BorderRadius.circular(6)), child: Text('⚠️ تجاوز ${s.subs - s.maxSubs} مشترك عن الحد', style: const TextStyle(fontSize: 12, color: amber, fontWeight: FontWeight.w700)))),
        if (!s.online) const Padding(padding: EdgeInsets.only(top: 8), child: Text('⛔ السكتر متوقف — فصلت الخدمة', style: TextStyle(fontSize: 12, color: red, fontWeight: FontWeight.w700))),
      ])),
    );
  }

  void _addSectorSheet(BuildContext c, Tower t) {
    final n = TextEditingController(), ip = TextEditingController(), m = TextEditingController(), com = TextEditingController(text: 'public'), mx = TextEditingController(text: '8');
    Brand b = Brand.ubnt;
    showModalBottomSheet(context: c, isScrollControlled: true, backgroundColor: card, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))), builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => Directionality(textDirection: TextDirection.rtl, child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom, left: 20, right: 20, top: 20), child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('إضافة سكتر جديد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 20),
      TextField(controller: n, autofocus: true, decoration: const InputDecoration(labelText: 'اسم السكتر', prefixIcon: Icon(Icons.router))),
      const SizedBox(height: 12),
      TextField(controller: ip, textDirection: TextDirection.ltr, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عنوان IP', hintText: '10.46.203.155', prefixIcon: Icon(Icons.language))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: GestureDetector(onTap: () => setS(() => b = Brand.ubnt), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: b == Brand.ubnt ? const Color(0xFF0077FF).withOpacity(0.15) : bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: b == Brand.ubnt ? const Color(0xFF0077FF) : border, width: b == Brand.ubnt ? 2 : 1)), child: const Center(child: Text('UBNT', style: TextStyle(fontWeight: FontWeight.w800)))))),
        const SizedBox(width: 8),
        Expanded(child: GestureDetector(onTap: () => setS(() => b = Brand.mikrotik), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: b == Brand.mikrotik ? const Color(0xFFC62828).withOpacity(0.15) : bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: b == Brand.mikrotik ? const Color(0xFFC62828) : border, width: b == Brand.mikrotik ? 2 : 1)), child: const Center(child: Text('MikroTik', style: TextStyle(fontWeight: FontWeight.w800)))))),
      ]),
      const SizedBox(height: 12),
      TextField(controller: m, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'الموديل (اختياري)', prefixIcon: Icon(Icons.devices))),
      const SizedBox(height: 12),
      TextField(controller: com, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'SNMP Community', prefixIcon: Icon(Icons.vpn_key))),
      const SizedBox(height: 12),
      TextField(controller: mx, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الحد الأقصى للمشتركين', prefixIcon: Icon(Icons.people))),
      const SizedBox(height: 20),
      ElevatedButton.icon(onPressed: () {
        if (n.text.trim().isEmpty || ip.text.trim().isEmpty) return;
        c.read<AppState>().addSector(t.id, Sector(id: DateTime.now().microsecondsSinceEpoch.toString(), name: n.text.trim(), ip: ip.text.trim(), brand: b, model: m.text.trim(), community: com.text.trim().isEmpty ? 'public' : com.text.trim(), maxSubs: int.tryParse(mx.text) ?? 8));
        Navigator.pop(ctx);
      }, icon: const Icon(Icons.add), label: const Text('إضافة السكتر')),
      const SizedBox(height: 20),
    ]))))));
  }
}

class AlertsView extends StatelessWidget {
  const AlertsView({super.key});
  @override
  Widget build(BuildContext c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Consumer<AppState>(builder: (c, s, _) => Scaffold(
      appBar: AppBar(
        title: Text('التنبيهات (${s.alerts.length})'),
        actions: [if (s.alerts.isNotEmpty) IconButton(onPressed: () => s.clearAlerts(), icon: const Icon(Icons.delete_outline, color: textMut))],
      ),
      body: s.alerts.isEmpty ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text('✅', style: TextStyle(fontSize: 48)), SizedBox(height: 12), Text('لا توجد تنبيهات', style: TextStyle(fontSize: 16, color: textSec))])) : ListView.builder(padding: const EdgeInsets.all(16), itemCount: s.alerts.length, itemBuilder: (c, i) {
        final parts = s.alerts[i].split('|');
        final time = DateTime.tryParse(parts[0]);
        final msg = parts.length > 1 ? parts.sublist(1).join('|') : s.alerts[i];
        final col = msg.contains('⛔') ? red : msg.contains('⚠️') ? amber : green;
        return Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: col.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: col.withOpacity(0.25))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(msg, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (time != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_fmt(time), style: const TextStyle(fontSize: 11, color: textMut))),
        ]));
      }),
    )),
  );
  String _fmt(DateTime dt) { final d = DateTime.now().difference(dt); if (d.inSeconds < 60) return 'الآن'; if (d.inMinutes < 60) return 'قبل ${d.inMinutes} د'; if (d.inHours < 24) return 'قبل ${d.inHours} س'; return '${dt.day}/${dt.month}'; }
}
