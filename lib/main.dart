import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart' as cr;
import 'package:file_selector/file_selector.dart';
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
  String expiry;
  int limitMb;
  int used;
  String sub;
  Cfg(this.name, this.link, this.hidden,
      {this.expiry = '', this.limitMb = 0, this.used = 0, this.sub = ''});

  Map<String, dynamic> toJson() => {
        'name': name,
        'link': link,
        'hidden': hidden,
        'expiry': expiry,
        'limitMb': limitMb,
      };
  Map<String, dynamic> toStore() => {...toJson(), 'used': used, 'sub': sub};

  factory Cfg.fromJson(Map<String, dynamic> j) => Cfg(
        (j['name'] ?? '').toString(),
        (j['link'] ?? '').toString(),
        j['hidden'] == true,
        expiry: (j['expiry'] ?? '').toString(),
        limitMb: num.tryParse('${j['limitMb'] ?? 0}')?.toInt() ?? 0,
        used: num.tryParse('${j['used'] ?? 0}')?.toInt() ?? 0,
        sub: (j['sub'] ?? '').toString(),
      );

  bool get expired {
    if (expiry.isEmpty) return false;
    final d = DateTime.tryParse(expiry);
    if (d == null) return false;
    return DateTime.now().isAfter(d.add(const Duration(days: 1)));
  }

  bool get overLimit => limitMb > 0 && used >= limitMb * 1048576;
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

List<double> hueMatrix(double deg) {
  final r = deg * pi / 180;
  final c = cos(r), s = sin(r);
  return <double>[
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0,
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0,
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

// ---------- Chiffrement des fichiers .otaku ----------
cr.Pbkdf2 _kdf() =>
    cr.Pbkdf2(macAlgorithm: cr.Hmac.sha256(), iterations: 50000, bits: 256);

Future<String> encryptText(String plain, String pw) async {
  final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final key = await _kdf().deriveKeyFromPassword(password: pw, nonce: salt);
  final box = await cr.AesGcm.with256bits().encrypt(utf8.encode(plain), secretKey: key);
  return 'OTAKU2:${base64Encode([...salt, ...box.concatenation()])}';
}

Future<String?> decryptText(String data, String pw) async {
  try {
    final bytes = base64Decode(data);
    final salt = bytes.sublist(0, 16);
    final box = cr.SecretBox.fromConcatenation(bytes.sublist(16),
        nonceLength: 12, macLength: 16);
    final key = await _kdf().deriveKeyFromPassword(password: pw, nonce: salt);
    final clear = await cr.AesGcm.with256bits().decrypt(box, secretKey: key);
    return utf8.decode(clear);
  } catch (_) {
    return null;
  }
}

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
  final Map<String, int> usage = {};
  List<Map<String, dynamic>> subs = [];
  int dlSpeed = 0, upSpeed = 0, dlTotal = 0, upTotal = 0, lastTot = 0, tick = 0;
  String duration = '00:00:00';
  bool wantOn = false, searching = false, testing = false;
  double? speedMbps;
  int retries = 0;
  bool turbo = false, autoReco = true, autoBest = false, proxyOnly = false;
  bool autoConnect = false, mangekyoColor = true;
  String dns = 'auto';
  String excluded = '';

  bool get connected => state == 'CONNECTED';
  bool get busy => state == 'CONNECTING' || searching;
  List<String> get excludedApps =>
      excluded.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

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
          final tot = dlTotal + upTotal;
          final delta = tot - lastTot;
          if (delta > 0) _account(delta);
          lastTot = tot;
        } else {
          hist.clear();
          lastTot = 0;
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

  String _today() => DateTime.now().toIso8601String().substring(0, 10);

  void _account(int delta) {
    if (sel < configs.length) configs[sel].used += delta;
    final k = _today();
    usage[k] = (usage[k] ?? 0) + delta;
    tick++;
    if (tick % 15 == 0) {
      _save();
      _saveUsage();
    }
    if (sel < configs.length && configs[sel].overLimit && wantOn) {
      wantOn = false;
      v2ray.stopV2Ray();
      log('Limite de données atteinte');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) snack('Limite de données atteinte : déconnexion');
      });
    }
  }

  void _onState(String now) {
    if (now == 'CONNECTED') retries = 0;
    if (now == 'DISCONNECTED') {
      _save();
      _saveUsage();
      if (wantOn && autoReco && retries < 3) {
        retries++;
        log('Reconnexion automatique ($retries/3)');
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && wantOn && state == 'DISCONNECTED') _start(skipBest: true);
        });
      }
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
    final u = <String, int>{};
    try {
      final m = jsonDecode(p.getString('usage') ?? '{}') as Map<String, dynamic>;
      m.forEach((k, v) => u[k] = toInt(v));
    } catch (_) {}
    final sb = <Map<String, dynamic>>[];
    try {
      for (final e in (jsonDecode(p.getString('subs') ?? '[]') as List)) {
        sb.add(Map<String, dynamic>.from(e as Map));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      configs = l;
      usage
        ..clear()
        ..addAll(u);
      subs = sb;
      sel = p.getInt('sel') ?? 0;
      if (sel >= configs.length) sel = 0;
      turbo = p.getBool('turbo') ?? false;
      dns = p.getString('dns') ?? 'auto';
      autoReco = p.getBool('autoReco') ?? true;
      autoBest = p.getBool('autoBest') ?? false;
      proxyOnly = p.getBool('proxyOnly') ?? false;
      autoConnect = p.getBool('autoConnect') ?? false;
      mangekyoColor = p.getBool('mangekyoColor') ?? true;
      excluded = p.getString('excluded') ?? '';
    });
    if (subs.isNotEmpty) await updateSubs(quiet: true);
    if (autoConnect && configs.isNotEmpty && mounted) {
      wantOn = true;
      await _start();
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('cfgs2', configs.map((c) => jsonEncode(c.toStore())).toList());
    await p.setInt('sel', sel);
  }

  Future<void> _saveUsage() async {
    final p = await SharedPreferences.getInstance();
    final keys = usage.keys.toList()..sort();
    while (keys.length > 30) {
      usage.remove(keys.removeAt(0));
    }
    await p.setString('usage', jsonEncode(usage));
  }

  Future<void> _saveSubs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('subs', jsonEncode(subs));
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('turbo', turbo);
    await p.setString('dns', dns);
    await p.setBool('autoReco', autoReco);
    await p.setBool('autoBest', autoBest);
    await p.setBool('proxyOnly', proxyOnly);
    await p.setBool('autoConnect', autoConnect);
    await p.setBool('mangekyoColor', mangekyoColor);
    await p.setString('excluded', excluded);
  }

  void snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

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
      if (configs[i].expired || configs[i].overLimit) continue;
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
    final c = configs[sel];
    if (c.expired) return snack('Cette config est expirée');
    if (c.overLimit) return snack('Limite de données atteinte pour cette config');
    final p = parse(c.link);
    if (p == null) return snack('Config invalide');
    if (await v2ray.requestPermission()) {
      final apps = excludedApps;
      v2ray.startV2Ray(
        remark: c.name,
        config: buildConfig(p),
        proxyOnly: proxyOnly,
        bypassSubnets: null,
        blockedApps: apps.isEmpty ? null : apps,
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

  Future<void> speedTest() async {
    if (testing) return;
    setState(() {
      testing = true;
      speedMbps = null;
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    double res = -1;
    try {
      final sw = Stopwatch()..start();
      final req = await client
          .getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=10000000'));
      final r = await req.close();
      var n = 0;
      await for (final chunk in r) {
        n += chunk.length;
        if (sw.elapsed.inSeconds >= 10) break;
      }
      final secs = max(sw.elapsedMilliseconds / 1000, 0.001);
      res = n * 8 / 1000000 / secs;
    } catch (_) {
      res = -1;
    } finally {
      client.close(force: true);
    }
    if (!mounted) return;
    setState(() {
      testing = false;
      speedMbps = res;
    });
  }

  // ----- Abonnements -----
  Future<void> updateSubs({bool quiet = false}) async {
    var n = 0;
    for (final s in List<Map<String, dynamic>>.from(subs)) {
      final url = '${s['url']}';
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        var body = (await res.transform(utf8.decoder).join()).trim();
        client.close();
        if (!body.contains('://')) {
          try {
            body = utf8.decode(base64Decode(base64.normalize(body)));
          } catch (_) {}
        }
        final list = _linesToCfgs(body, s['hidden'] == true);
        if (list.isNotEmpty) {
          for (final c in list) {
            c.sub = url;
          }
          if (!mounted) return;
          setState(() {
            configs.removeWhere((c) => c.sub == url);
            configs.addAll(list);
            if (sel >= configs.length) sel = 0;
          });
          n += list.length;
        }
      } catch (_) {}
    }
    _save();
    if (!quiet) snack(n > 0 ? '$n config(s) mises à jour' : 'Aucune mise à jour');
  }

  Future<void> addSub() async {
    final c = TextEditingController();
    var hide = false;
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Ajouter un abonnement'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: c,
                  decoration: const InputDecoration(hintText: 'https://...')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Cacher les infos'),
                value: hide,
                onChanged: (v) => setD(() => hide = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final u = c.text.trim();
                if (!u.startsWith('http')) return snack('Lien invalide');
                setState(() => subs.add({'url': u, 'hidden': hide}));
                _saveSubs();
                Navigator.pop(ctx);
                updateSubs();
              },
              style: FilledButton.styleFrom(backgroundColor: kRed),
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
  }

  // ----- Import / export -----
  List<Cfg> _linesToCfgs(String text, bool hide) {
    final out = <Cfg>[];
    for (final l in text.split(RegExp(r'[\r\n]+'))) {
      final t = l.trim();
      if (t.contains('://')) {
        final p = parse(t);
        if (p != null) out.add(Cfg(p.remark, t, hide));
      }
    }
    return out;
  }

  List<Cfg> _fromJson(String s, bool forceHidden) {
    final out = <Cfg>[];
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      for (final c in (j['configs'] as List)) {
        final cf = Cfg.fromJson(Map<String, dynamic>.from(c as Map));
        cf.used = 0;
        cf.sub = '';
        if (parse(cf.link) != null) {
          if (forceHidden) cf.hidden = true;
          out.add(cf);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<List<Cfg>> parseImport(String input, bool forceHidden) async {
    final text = input.trim();
    if (text.startsWith('OTAKU2:')) {
      final pw = await askText('Mot de passe du fichier', 'Mot de passe', obscure: true);
      if (pw == null) return [];
      final clear = await decryptText(text.substring(7).trim(), pw);
      if (clear == null) {
        snack('Mot de passe incorrect');
        return [];
      }
      return _fromJson(clear, forceHidden);
    }
    if (text.startsWith('OTAKU1:')) {
      try {
        return _fromJson(utf8.decode(base64Decode(text.substring(7).trim())), forceHidden);
      } catch (_) {
        return [];
      }
    }
    return _linesToCfgs(text, forceHidden);
  }

  Future<String> exportText(List<Cfg> list, {String password = ''}) async {
    final j = jsonEncode({
      'otaku': 2,
      'creator': 'APPOH GODWIN',
      'configs': list.map((c) => c.toJson()).toList()
    });
    if (password.isNotEmpty) return encryptText(j, password);
    return 'OTAKU1:${base64Encode(utf8.encode(j))}';
  }

  Future<String?> askText(String title, String hint, {bool obscure = false}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            obscureText: obscure,
            decoration: InputDecoration(hintText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<String?> prepareExport(List<Cfg> list) async {
    final pw = await askText(
        'Mot de passe (facultatif)', 'Laisse vide pour ne pas chiffrer',
        obscure: true);
    if (pw == null) return null;
    return exportText(list, password: pw);
  }

  Future<void> copyCode(List<Cfg> list) async {
    final txt = await prepareExport(list);
    if (txt == null) return;
    await Clipboard.setData(ClipboardData(text: txt));
    snack('Code OTAKU copié');
  }

  Future<void> shareFile(List<Cfg> list, String name) async {
    try {
      final txt = await prepareExport(list);
      if (txt == null) return;
      final dir = await getTemporaryDirectory();
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final f = File('${dir.path}/${safe.isEmpty ? 'config' : safe}.otaku');
      await f.writeAsString(txt);
      await Share.shareXFiles([XFile(f.path)], text: 'Config OTAKU TUNNEL');
    } catch (_) {
      snack('Partage impossible');
    }
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
      final XFile? f = await openFile();
      if (f == null) return;
      final txt = await f.readAsString();
      _addImported(await parseImport(txt, hide));
    } catch (_) {
      snack('Fichier illisible');
    }
  }

  Future<void> importDialog() async {
    final c = TextEditingController();
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (clip.contains('://') || clip.startsWith('OTAKU')) c.text = clip.trim();
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
                    hintText: 'Lien (vless://, vmess://...) ou code OTAKU'),
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
              onPressed: () async {
                Navigator.pop(ctx);
                _addImported(await parseImport(c.text, hide));
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
    final e = TextEditingController(text: c.expiry);
    final m = TextEditingController(text: c.limitMb > 0 ? '${c.limitMb}' : '');
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
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Lien')),
            const SizedBox(height: 8),
            TextField(
                controller: e,
                decoration: const InputDecoration(
                    labelText: 'Expire le (AAAA-MM-JJ, facultatif)')),
            const SizedBox(height: 8),
            TextField(
                controller: m,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Limite de données en Mo (0 = aucune)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              if (parse(l.text.trim()) == null) return snack('Lien invalide');
              final ex = e.text.trim();
              if (ex.isNotEmpty && DateTime.tryParse(ex) == null) {
                return snack('Date invalide (ex : 2026-12-31)');
              }
              setState(() {
                if (n.text.trim().isNotEmpty) c.name = n.text.trim();
                c.link = l.text.trim();
                c.expiry = ex;
                c.limitMb = int.tryParse(m.text.trim()) ?? 0;
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
    } else if (v == 'resetuse') {
      setState(() => c.used = 0);
      _save();
    } else if (v == 'copylink') {
      await Clipboard.setData(ClipboardData(text: c.link));
      snack('Lien copié');
    } else if (v == 'copycode') {
      await copyCode([c]);
    } else if (v == 'share') {
      await shareFile([c], c.name);
    } else if (v == 'sharelock') {
      await shareFile([Cfg(c.name, c.link, true, expiry: c.expiry, limitMb: c.limitMb)], c.name);
    } else if (v == 'del') {
      setState(() {
        configs.removeAt(i);
        if (sel >= configs.length) sel = 0;
        pings.clear();
      });
      _save();
    }
  }

  // ----- Fenêtres des réglages -----
  Future<void> excludeDialog() async {
    final c = TextEditingController(text: excluded);
    const presets = {
      'Telegram': 'org.telegram.messenger',
      'WhatsApp': 'com.whatsapp',
      'YouTube': 'com.google.android.youtube',
      'TikTok': 'com.zhiliaoapp.musically',
      'Facebook': 'com.facebook.katana',
      'Instagram': 'com.instagram.android',
    };
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Applis hors VPN'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Ces applis utilisent ta connexion directe, sans passer par le VPN.',
                style: TextStyle(color: Colors.white60, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(
              controller: c,
              maxLines: 3,
              decoration: const InputDecoration(
                  hintText: 'noms de paquet séparés par des virgules'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: presets.entries
                  .map((e) => ActionChip(
                        label: Text(e.key),
                        onPressed: () {
                          final cur = c.text.trim();
                          final has = cur.split(',').map((x) => x.trim()).contains(e.value);
                          if (!has) c.text = cur.isEmpty ? e.value : '$cur,${e.value}';
                        },
                      ))
                  .toList(),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              setState(() => excluded = c.text.trim());
              _saveSettings();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void killSwitchInfo() => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Coupure de sécurité'),
          content: const Text(
              'Pour bloquer tout internet si le VPN tombe, active-le dans Android :\n\n'
              'Réglages > Réseau et Internet > VPN > roue dentée à côté de OTAKU TUNNEL.\n\n'
              'Active « VPN permanent » puis « Bloquer les connexions sans VPN ».\n\n'
              'Les noms des menus varient selon les téléphones.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Compris'))
          ],
        ),
      );

  void usageDialog() {
    final keys = usage.keys.toList()..sort((a, b) => b.compareTo(a));
    final shown = keys.take(14).toList();
    final mx = shown.isEmpty ? 1 : shown.map((k) => usage[k]!).reduce(max);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Consommation'),
        content: SizedBox(
          width: double.maxFinite,
          child: shown.isEmpty
              ? const Text('Aucune donnée pour le moment.')
              : ListView(
                  shrinkWrap: true,
                  children: shown
                      .map((k) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('$k  •  ${fmtBytes(usage[k]!)}',
                                      style: const TextStyle(fontSize: 12)),
                                  const SizedBox(height: 2),
                                  LinearProgressIndicator(
                                      value: usage[k]! / mx,
                                      color: kRed,
                                      backgroundColor: Colors.white12),
                                ]),
                          ))
                      .toList(),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          TextButton(
            onPressed: () {
              setState(() => usage.clear());
              _saveUsage();
              Navigator.pop(ctx);
            },
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
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
        Text('Durée : $duration',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ]);

  String pingLabel(int? d) {
    if (d == null) return 'Tester le serveur';
    if (d == 0) return 'Test en cours...';
    return d > 0 ? '$d ms' : 'Injoignable';
  }

  String speedLabel() {
    if (testing) return 'Test en cours...';
    final s = speedMbps;
    if (s == null) return 'Test de vitesse';
    return s < 0 ? 'Test impossible' : '${s.toStringAsFixed(1)} Mb/s';
  }

  Widget eye() {
    final deg = mangekyoColor ? [0.0, 260.0, 200.0, 120.0, 40.0, 310.0][sel % 6] : 0.0;
    final glow = connected ? HSLColor.fromAHSL(1, deg, 0.85, 0.5).toColor() : kRed;
    Widget img = Image.asset(
        connected ? 'assets/images/mangekyo.png' : 'assets/images/sharingan.png');
    if (connected && deg != 0) {
      img = ColorFiltered(colorFilter: ColorFilter.matrix(hueMatrix(deg)), child: img);
    }
    return Container(
      width: 190,
      height: 190,
      decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
        BoxShadow(color: glow.withOpacity(connected ? 0.8 : 0.3), blurRadius: 40),
      ]),
      child: img,
    );
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
            child: RotationTransition(turns: spin, child: eye()),
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
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: speedTest,
            icon: const Icon(Icons.speed),
            label: Text(speedLabel()),
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
                    if (c.limitMb > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                          value: min(c.used / (c.limitMb * 1048576), 1.0),
                          color: kRed,
                          backgroundColor: Colors.white12),
                      const SizedBox(height: 4),
                      Text('${fmtBytes(c.used)} / ${c.limitMb} Mo',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ],
                    if (c.expiry.isNotEmpty)
                      Text(c.expired ? 'Expirée le ${c.expiry}' : 'Valide jusqu\'au ${c.expiry}',
                          style: TextStyle(
                              color: c.expired ? Colors.redAccent : Colors.white54,
                              fontSize: 12)),
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
  String subtitleFor(Cfg c, int i) {
    final p = parse(c.link);
    final d = pings[i];
    final b = StringBuffer(c.hidden ? 'Infos masquées' : (p?.address ?? ''));
    if (d != null) {
      b.write(d > 0 ? '  •  $d ms' : d == 0 ? '  •  test...' : '  •  injoignable');
    }
    if (c.expired) {
      b.write('  •  expirée');
    } else if (c.expiry.isNotEmpty) {
      b.write('  •  jusqu\'au ${c.expiry}');
    }
    if (c.limitMb > 0) b.write('  •  ${fmtBytes(c.used)}/${c.limitMb} Mo');
    return b.toString();
  }

  Widget configsTab() => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(children: [
            const Text('Configs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
            const Spacer(),
            IconButton(
                tooltip: 'Meilleur serveur', onPressed: bestServer, icon: const Icon(Icons.bolt)),
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
                        subtitle: Text(subtitleFor(c, i),
                            maxLines: 2, overflow: TextOverflow.ellipsis),
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
                            if (c.limitMb > 0)
                              const PopupMenuItem(
                                  value: 'resetuse', child: Text('Remettre la conso à zéro')),
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

  Widget sw(String title, String sub, bool v, void Function(bool) f) => SwitchListTile(
        title: Text(title),
        subtitle: Text(sub),
        value: v,
        onChanged: (x) {
          setState(() => f(x));
          _saveSettings();
        },
      );

  Widget settingsTab() => ListView(padding: const EdgeInsets.all(8), children: [
        const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Réglages',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
        sec('Vitesse et stabilité'),
        sw('Mode Turbo', 'Multiplexage : accélère pages et applis (à tester)', turbo,
            (v) => turbo = v),
        sw('Meilleur serveur automatique', 'Teste tes configs avant de se connecter', autoBest,
            (v) => autoBest = v),
        sw('Reconnexion automatique', 'Relance si la connexion tombe', autoReco,
            (v) => autoReco = v),
        sw('Connexion au lancement', 'Se connecte quand tu ouvres l\'appli', autoConnect,
            (v) => autoConnect = v),
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
        sec('Mode et applis'),
        sw('Proxy seulement', 'Sans VPN système (pour apps compatibles)', proxyOnly,
            (v) => proxyOnly = v),
        ListTile(
          leading: const Icon(Icons.apps),
          title: const Text('Applis hors VPN'),
          subtitle: Text(excludedApps.isEmpty
              ? 'Aucune'
              : '${excludedApps.length} appli(s) en accès direct'),
          onTap: excludeDialog,
        ),
        sec('Sécurité'),
        ListTile(
          leading: const Icon(Icons.shield_moon_outlined),
          title: const Text('Coupure de sécurité (kill switch)'),
          subtitle: const Text('Comment bloquer internet si le VPN tombe'),
          onTap: killSwitchInfo,
        ),
        sec('Apparence'),
        sw('Mangekyō selon le serveur', 'Une couleur différente par config', mangekyoColor,
            (v) => mangekyoColor = v),
        sec('Abonnements'),
        ListTile(
          leading: const Icon(Icons.add_link),
          title: const Text('Ajouter un abonnement'),
          onTap: addSub,
        ),
        if (subs.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Mettre à jour maintenant'),
            onTap: () => updateSubs(),
          ),
        for (var i = 0; i < subs.length; i++)
          ListTile(
            dense: true,
            title: Text('${subs[i]['url']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(subs[i]['hidden'] == true ? 'Infos masquées' : 'Infos visibles'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                final u = '${subs[i]['url']}';
                setState(() {
                  subs.removeAt(i);
                  configs.removeWhere((c) => c.sub == u);
                  if (sel >= configs.length) sel = 0;
                });
                _saveSubs();
                _save();
              },
            ),
          ),
        sec('Données'),
        ListTile(
          leading: const Icon(Icons.bar_chart),
          title: const Text('Consommation'),
          subtitle: const Text('Historique par jour'),
          onTap: usageDialog,
        ),
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
          onTap: () {
            if (configs.isEmpty) return snack('Aucune config');
            copyCode(configs);
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
          title: Text('OTAKU TUNNEL v3.0'),
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
