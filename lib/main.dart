import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kRed = Color(0xFFE53935);
const kBg = Color(0xFF0A0A0F);
const kCard = Color(0xFF16161F);

void main() => runApp(const OtakuApp());

class OtakuApp extends StatelessWidget {
  const OtakuApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OTAKU TUNNEL',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: kBg,
          colorScheme: const ColorScheme.dark(primary: kRed),
          navigationBarTheme:
              const NavigationBarThemeData(indicatorColor: Color(0xFF5A1114)),
        ),
        home: const Splash(),
      );
}

// ---------- Modèle ----------
class Cfg {
  String name;
  String link;
  bool hidden;
  Cfg(this.name, this.link, this.hidden);
  Map<String, dynamic> toJson() => {'name': name, 'link': link, 'hidden': hidden};
  factory Cfg.fromJson(Map<String, dynamic> j) => Cfg(
      (j['name'] ?? '').toString(),
      (j['link'] ?? '').toString(),
      j['hidden'] == true);
}

String fmtSpeed(num b) {
  if (b < 1024) return '${b.toStringAsFixed(0)} o/s';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} Ko/s';
  return '${(b / 1048576).toStringAsFixed(2)} Mo/s';
}

String fmtBytes(num b) {
  if (b < 1024) return '${b.toStringAsFixed(0)} o';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} Ko';
  if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} Mo';
  return '${(b / 1073741824).toStringAsFixed(2)} Go';
}

int toInt(dynamic v) => num.tryParse('$v')?.toInt() ?? 0;

class Spark extends CustomPainter {
  final List<double> d;
  Spark(this.d);
  @override
  void paint(Canvas c, Size s) {
    if (d.length < 2) return;
    final m = max(d.reduce(max), 1.0);
    final path = Path();
    for (var i = 0; i < d.length; i++) {
      final x = s.width * i / (d.length - 1);
      final y = s.height - (d[i] / m) * s.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    c.drawPath(
        path,
        Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant Spark o) => true;
}

// ---------- Écran d'ouverture ----------
class Splash extends StatefulWidget {
  const Splash({super.key});
  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const Home()));
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(fit: StackFit.expand, children: [
          Image.asset('assets/images/splash.jpg', fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            child: Column(children: [
              Text('OTAKU TUNNEL',
                  style: TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 3)),
              SizedBox(height: 6),
              Text('by APPOH GODWIN • HACKER GODWIN',
                  style: TextStyle(color: Colors.white70)),
            ]),
          ),
        ]),
      );
}

// ---------- Application ----------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with SingleTickerProviderStateMixin {
  late final FlutterV2ray v2ray;
  late final AnimationController spin;
  int tab = 0;
  String state = 'DISCONNECTED';
  List<Cfg> configs = [];
  int sel = 0;
  final Map<int, int> pings = {};
  final List<String> logs = [];
  final List<double> hist = [];
  int dlSpeed = 0, upSpeed = 0, dlTotal = 0, upTotal = 0;
  String duration = '00:00:00';
  bool wantOn = false, searching = false;
  int retries = 0;
  bool turbo = false, autoReco = true, autoBest = false, proxyOnly = false;
  String dns = 'auto';

  bool get connected => state == 'CONNECTED';
  bool get busy => state == 'CONNECTING' || searching;

  @override
  void initState() {
    super.initState();
    spin = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    v2ray = FlutterV2ray(onStatusChanged: (s) {
      if (!mounted) return;
      final prev = state;
      setState(() {
        state = s.state;
        dlSpeed = toInt(s.downloadSpeed);
        upSpeed = toInt(s.uploadSpeed);
        dlTotal = toInt(s.download);
        upTotal = toInt(s.upload);
        duration = '${s.duration}';
        if (connected) {
          hist.add(dlSpeed.toDouble());
          if (hist.length > 40) hist.removeAt(0);
        } else {
          hist.clear();
        }
        if (prev != state) {
          log(state);
          (connected || busy) ? spin.repeat() : spin.stop();
        }
      });
      if (prev != state) _onState(state);
    });
    v2ray.initializeV2Ray();
    _load();
  }

  void log(String m) =>
      logs.add('${DateTime.now().toIso8601String().substring(11, 19)}  $m');

  void _onState(String now) {
    if (now == 'CONNECTED') retries = 0;
    if (now == 'DISCONNECTED' && wantOn && autoReco && retries < 3) {
      retries++;
      log('Reconnexion automatique ($retries/3)');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && wantOn && state == 'DISCONNECTED') _start(skipBest: true);
      });
    }
  }

  // ----- Sauvegarde -----
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList('cfgs2');
    final l = <Cfg>[];
    if (raw != null) {
      for (final s in raw) {
        try {
          l.add(Cfg.fromJson(jsonDecode(s) as Map<String, dynamic>));
        } catch (_) {}
      }
    } else {
      for (final s in (p.getStringList('configs') ?? [])) {
        final q = parse(s);
        if (q != null) l.add(Cfg(q.remark, s, false));
      }
    }
    setState(() {
      configs = l;
      sel = p.getInt('sel') ?? 0;
      if (sel >= configs.length) sel = 0;
      turbo = p.getBool('turbo') ?? false;
      dns = p.getString('dns') ?? 'auto';
      autoReco = p.getBool('autoReco') ?? true;
      autoBest = p.getBool('autoBest') ?? false;
      proxyOnly = p.getBool('proxyOnly') ?? false;
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('cfgs2', configs.map((c) => jsonEncode(c.toJson())).toList());
    await p.setInt('sel', sel);
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('turbo', turbo);
    await p.setString('dns', dns);
    await p.setBool('autoReco', autoReco);
    await p.setBool('autoBest', autoBest);
    await p.setBool('proxyOnly', proxyOnly);
  }

  void snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  // ----- Outils -----
  String proto(String link) {
    final l = link.toLowerCase();
    if (l.startsWith('vless')) return 'VLESS';
    if (l.startsWith('vmess')) return 'VMess';
    if (l.startsWith('trojan')) return 'Trojan';
    if (l.startsWith('ss')) return 'Shadowsocks';
    return '?';
  }

  V2RayURL? parse(String link) {
    try {
      return FlutterV2ray.parseFromURL(link);
    } catch (_) {
      return null;
    }
  }

  String buildConfig(V2RayURL p) {
    final raw = p.getFullConfiguration();
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (turbo) {
        final outs = m['outbounds'];
        if (outs is List && outs.isNotEmpty && outs[0] is Map) {
          (outs[0] as Map)['mux'] = {'enabled': true, 'concurrency': 8};
        }
      }
      if (dns != 'auto') {
        final servers = dns == 'cloudflare'
            ? ['1.1.1.1', '1.0.0.1']
            : dns == 'google'
                ? ['8.8.8.8', '8.8.4.4']
                : ['94.140.14.14', '94.140.15.15'];
        m['dns'] = {'servers': servers};
      }
      return jsonEncode(m);
    } catch (_) {
      return raw;
    }
  }

  Future<int> _delay(int i) async {
    final p = parse(configs[i].link);
    if (p == null) return -1;
    try {
      return await v2ray
          .getServerDelay(config: buildConfig(p))
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      return -1;
    }
  }

  Future<void> bestServer() async {
    if (configs.isEmpty) return;
    setState(() => searching = true);
    snack('Recherche du meilleur serveur...');
    var bestI = -1, bestD = 1 << 30;
    for (var i = 0; i < configs.length; i++) {
      final d = await _delay(i);
      pings[i] = d;
      if (d > 0 && d < bestD) {
        bestD = d;
        bestI = i;
      }
    }
    if (!mounted) return;
    setState(() {
      searching = false;
      if (bestI >= 0) sel = bestI;
    });
    _save();
    snack(bestI >= 0
        ? 'Meilleur serveur : ${configs[bestI].name} ($bestD ms)'
        : 'Aucun serveur ne répond');
  }

  Future<void> _start({bool skipBest = false}) async {
    if (configs.isEmpty) return snack('Ajoute d\'abord une config (onglet Configs)');
    if (autoBest && !skipBest && configs.length > 1) await bestServer();
    final p = parse(configs[sel].link);
    if (p == null) return snack('Config invalide');
    if (await v2ray.requestPermission()) {
      v2ray.startV2Ray(
        remark: configs[sel].name,
        config: buildConfig(p),
        proxyOnly: proxyOnly,
        bypassSubnets: null,
        blockedApps: null,
      );
    }
  }

  Future<void> toggle() async {
    if (connected || busy) {
      wantOn = false;
      v2ray.stopV2Ray();
      return;
    }
    wantOn = true;
    retries = 0;
    await _start();
  }

  Future<void> pingSel() async {
    if (configs.isEmpty) return;
    setState(() => pings[sel] = 0);
    final d = await _delay(sel);
    if (!mounted) return;
    setState(() => pings[sel] = d);
  }

  // ----- Import / export -----
  List<Cfg> parseImport(String input, bool forceHidden) {
    final text = input.trim();
    final out = <Cfg>[];
    if (text.startsWith('OTAKU1:')) {
      try {
        final j = jsonDecode(utf8.decode(base64Decode(text.substring(7).trim())))
            as Map<String, dynamic>;
        for (final c in (j['configs'] as List)) {
          final cf = Cfg.fromJson(Map<String, dynamic>.from(c as Map));
          if (parse(cf.link) != null) {
            if (forceHidden) cf.hidden = true;
            out.add(cf);
          }
        }
      } catch (_) {}
      return out;
    }
    for (final l in text.split(RegExp(r'[\r\n]+'))) {
      final t = l.trim();
      if (t.contains('://')) {
        final p = parse(t);
        if (p != null) out.add(Cfg(p.remark, t, forceHidden));
      }
    }
    return out;
  }

  String exportText(List<Cfg> list) {
    final j = {
      'otaku': 1,
      'creator': 'APPOH GODWIN',
      'configs': list.map((c) => c.toJson()).toList()
    };
    return 'OTAKU1:${base64Encode(utf8.encode(jsonEncode(j)))}';
  }

  void _addImported(List<Cfg> l) {
    if (l.isEmpty) return snack('Aucune config valide trouvée');
    setState(() => configs.addAll(l));
    _save();
    log('Import : ${l.length} config(s)');
    snack('${l.length} config(s) ajoutée(s)');
  }

  Future<void> importFile(bool hide) async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any);
      if (r == null || r.files.single.path == null) return;
      final txt = await File(r.files.single.path!).readAsString();
      _addImported(parseImport(txt, hide));
    } catch (_) {
      snack('Fichier illisible');
    }
  }

  Future<void> shareFile(List<Cfg> list, String name) async {
    try {
      final dir = await getTemporaryDirectory();
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final f = File('${dir.path}/${safe.isEmpty ? 'config' : safe}.otaku');
      await f.writeAsString(exportText(list));
      await Share.shareXFiles([XFile(f.path)], text: 'Config OTAKU TUNNEL');
    } catch (_) {
      snack('Partage impossible');
    }
  }

  Future<void> importDialog() async {
    final c = TextEditingController();
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (clip.contains('://') || clip.startsWith('OTAKU1:')) c.text = clip.trim();
    var hide = false;
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Importer'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: c,
                maxLines: 4,
                decoration: const InputDecoration(
                    hintText: 'Lien (vless://, vmess://...) ou code OTAKU1:'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Cacher les infos'),
                subtitle: const Text('Serveur invisible, partage verrouillé'),
                value: hide,
                onChanged: (v) => setD(() => hide = v),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  importFile(hide);
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Choisir un fichier .otaku'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                _addImported(parseImport(c.text, hide));
                Navigator.pop(ctx);
              },
              style: FilledButton.styleFrom(backgroundColor: kRed),
              child: const Text('Importer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> editDialog(int i) async {
    final c = configs[i];
    final n = TextEditingController(text: c.name);
    final l = TextEditingController(text: c.link);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifier la config'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: n, decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 8),
            TextField(
                controller: l,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Lien')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              if (parse(l.text.trim()) == null) return snack('Lien invalide');
              setState(() {
                if (n.text.trim().isNotEmpty) c.name = n.text.trim();
                c.link = l.text.trim();
                pings.clear();
              });
              _save();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  Future<void> _menu(String v, int i) async {
    final c = configs[i];
    if (v == 'test') {
      setState(() => pings[i] = 0);
      final d = await _delay(i);
      if (!mounted) return;
      setState(() => pings[i] = d);
    } else if (v == 'edit') {
      await editDialog(i);
    } else if (v == 'copylink') {
      await Clipboard.setData(ClipboardData(text: c.link));
      snack('Lien copié');
    } else if (v == 'copycode') {
      await Clipboard.setData(ClipboardData(text: exportText([c])));
      snack('Code OTAKU copié');
    } else if (v == 'share') {
      await shareFile([c], c.name);
    } else if (v == 'sharelock') {
      await shareFile([Cfg(c.name, c.link, true)], c.name);
    } else if (v == 'del') {
      setState(() {
        configs.removeAt(i);
        if (sel >= configs.length) sel = 0;
        pings.clear();
      });
      _save();
    }
  }

  // ----- Onglet Connexion -----
  Widget statBox(IconData ic, String label, String speed, String total, Color col) =>
      Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white10, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ic, size: 16, color: col),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
            const SizedBox(height: 6),
            Text(speed, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text('Total : $total',
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
      );

  Widget statsPanel() => Column(children: [
        Row(children: [
          statBox(Icons.arrow_downward, 'Réception', fmtSpeed(dlSpeed), fmtBytes(dlTotal),
              Colors.greenAccent),
          const SizedBox(width: 10),
          statBox(Icons.arrow_upward, 'Envoi', fmtSpeed(upSpeed), fmtBytes(upTotal),
              Colors.orangeAccent),
        ]),
        const SizedBox(height: 10),
        SizedBox(
            height: 46,
            width: double.infinity,
            child: CustomPaint(painter: Spark(List<double>.from(hist)))),
        const SizedBox(height: 4),
        Text('Durée : $duration', style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ]);

  String pingLabel(int? d) {
    if (d == null) return 'Tester le serveur';
    if (d == 0) return 'Test en cours...';
    return d > 0 ? '$d ms' : 'Injoignable';
  }

  Widget connectionTab() {
    final c = configs.isEmpty ? null : configs[sel];
    final p = c == null ? null : parse(c.link);
    final statusText = connected
        ? 'Mangekyō activé'
        : searching
            ? 'Recherche du meilleur serveur...'
            : busy
                ? 'Activation...'
                : 'Touche le Sharingan';
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Connexion', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
              colors: [Color(0xFF2A0508), Color(0xFF0A0A0F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
        ),
        child: Column(children: [
          Row(children: [
            const Text('OTAKU TUNNEL',
                style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
            const Spacer(),
            Chip(
              label: Text(connected ? 'Connecté' : busy ? 'Connexion...' : 'Déconnecté'),
              backgroundColor: connected ? Colors.green.shade800 : Colors.white12,
            ),
          ]),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: toggle,
            child: RotationTransition(
              turns: spin,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                  BoxShadow(color: kRed.withOpacity(connected ? 0.8 : 0.3), blurRadius: 40),
                ]),
                child: Image.asset(connected
                    ? 'assets/images/mangekyo.png'
                    : 'assets/images/sharingan.png'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(statusText, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          if (connected)
            statsPanel()
          else
            OutlinedButton.icon(
              onPressed: pingSel,
              icon: const Icon(Icons.network_ping),
              label: Text(pingLabel(pings[sel])),
            ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration:
                BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
            child: c == null || p == null
                ? const Text('Aucune config sélectionnée')
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      if (c.hidden)
                        const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: Icon(Icons.lock, size: 16)),
                      Expanded(
                        child: Text('${proto(c.link)}  •  ${c.name}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(c.hidden ? 'Infos masquées' : p.address,
                        style: const TextStyle(color: Colors.white60)),
                  ]),
          ),
        ]),
      ),
      const SizedBox(height: 24),
      const Center(
          child: Text('Créé par APPOH GODWIN — HACKER GODWIN',
              style: TextStyle(color: Colors.white38, fontSize: 12))),
    ]);
  }

  // ----- Onglet Configs -----
  Widget configsTab() => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(children: [
            const Text('Configs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
                tooltip: 'Meilleur serveur',
                onPressed: bestServer,
                icon: const Icon(Icons.bolt)),
            IconButton(
                tooltip: 'Partager tout',
                onPressed: () {
                  if (configs.isEmpty) return snack('Aucune config');
                  shareFile(configs, 'otaku_configs');
                },
                icon: const Icon(Icons.share)),
            IconButton.filledTonal(onPressed: importDialog, icon: const Icon(Icons.add)),
          ]),
        ),
        Expanded(
          child: configs.isEmpty
              ? const Center(child: Text('Aucune config. Appuie sur +'))
              : ListView.builder(
                  itemCount: configs.length,
                  itemBuilder: (_, i) {
                    final c = configs[i];
                    final p = parse(c.link);
                    final d = pings[i];
                    return Card(
                      color: kCard,
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: Icon(sel == i ? Icons.check_circle : Icons.circle_outlined,
                            color: sel == i ? kRed : Colors.white38),
                        title: Row(children: [
                          if (c.hidden)
                            const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.lock, size: 14)),
                          Expanded(
                              child: Text('${proto(c.link)}  ${c.name}',
                                  maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ]),
                        subtitle: Text(
                            '${c.hidden ? 'Infos masquées' : (p?.address ?? '')}'
                            '${d == null ? '' : d > 0 ? '  •  $d ms' : d == 0 ? '  •  test...' : '  •  injoignable'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        onTap: () {
                          setState(() => sel = i);
                          _save();
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) => _menu(v, i),
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'test', child: Text('Tester')),
                            if (!c.hidden)
                              const PopupMenuItem(value: 'edit', child: Text('Modifier')),
                            if (!c.hidden)
                              const PopupMenuItem(
                                  value: 'copylink', child: Text('Copier le lien')),
                            const PopupMenuItem(
                                value: 'copycode', child: Text('Copier le code OTAKU')),
                            const PopupMenuItem(
                                value: 'share', child: Text('Partager (.otaku)')),
                            if (!c.hidden)
                              const PopupMenuItem(
                                  value: 'sharelock', child: Text('Partager verrouillé')),
                            const PopupMenuItem(value: 'del', child: Text('Supprimer')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]);

  // ----- Onglet Réglages -----
  Widget sec(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                color: kRed, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
      );

  Widget settingsTab() => ListView(padding: const EdgeInsets.all(8), children: [
        const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Réglages',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
        sec('Vitesse et stabilité'),
        SwitchListTile(
          title: const Text('Mode Turbo'),
          subtitle: const Text('Multiplexage : accélère pages et applis (à tester)'),
          value: turbo,
          onChanged: (v) {
            setState(() => turbo = v);
            _saveSettings();
          },
        ),
        SwitchListTile(
          title: const Text('Meilleur serveur automatique'),
          subtitle: const Text('Teste tes configs avant de se connecter'),
          value: autoBest,
          onChanged: (v) {
            setState(() => autoBest = v);
            _saveSettings();
          },
        ),
        SwitchListTile(
          title: const Text('Reconnexion automatique'),
          subtitle: const Text('Relance si la connexion tombe'),
          value: autoReco,
          onChanged: (v) {
            setState(() => autoReco = v);
            _saveSettings();
          },
        ),
        ListTile(
          title: const Text('Serveur DNS'),
          trailing: DropdownButton<String>(
            value: dns,
            items: const [
              DropdownMenuItem(value: 'auto', child: Text('Auto')),
              DropdownMenuItem(value: 'cloudflare', child: Text('Cloudflare')),
              DropdownMenuItem(value: 'google', child: Text('Google')),
              DropdownMenuItem(value: 'adguard', child: Text('AdGuard')),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => dns = v);
              _saveSettings();
            },
          ),
        ),
        sec('Mode'),
        SwitchListTile(
          title: const Text('Proxy seulement'),
          subtitle: const Text('Sans VPN système (pour apps compatibles)'),
          value: proxyOnly,
          onChanged: (v) {
            setState(() => proxyOnly = v);
            _saveSettings();
          },
        ),
        sec('Données'),
        ListTile(
          leading: const Icon(Icons.download),
          title: const Text('Importer des configs'),
          onTap: importDialog,
        ),
        ListTile(
          leading: const Icon(Icons.share),
          title: const Text('Exporter toutes les configs'),
          onTap: () {
            if (configs.isEmpty) return snack('Aucune config');
            shareFile(configs, 'otaku_configs');
          },
        ),
        ListTile(
          leading: const Icon(Icons.copy),
          title: const Text('Copier toutes les configs (code OTAKU)'),
          onTap: () async {
            if (configs.isEmpty) return snack('Aucune config');
            await Clipboard.setData(ClipboardData(text: exportText(configs)));
            snack('Code copié');
          },
        ),
        sec('Diagnostic'),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: const Text('Logs'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showModalBottomSheet(
            context: context,
            builder: (_) => ListView(
                padding: const EdgeInsets.all(16),
                children: logs.reversed.map((l) => Text(l)).toList()),
          ),
        ),
        const Divider(),
        const ListTile(
          title: Text('OTAKU TUNNEL v2.0'),
          subtitle: Text('Créé par APPOH GODWIN • alias HACKER GODWIN'),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: [connectionTab(), configsTab(), settingsTab()][tab],
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.shield_outlined), label: 'Connexion'),
            NavigationDestination(icon: Icon(Icons.public), label: 'Configs'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Réglages'),
          ],
        ),
      );
}
