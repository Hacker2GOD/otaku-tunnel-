import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
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
        ),
        home: const Splash(),
      );
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
  List<String> configs = [];
  int sel = 0;
  final Map<int, String> pings = {};
  final List<String> logs = [];
  bool lightTheme = false;

  bool get connected => state == 'CONNECTED';
  bool get busy => state == 'CONNECTING';

  @override
  void initState() {
    super.initState();
    spin = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    v2ray = FlutterV2ray(onStatusChanged: (s) {
      if (!mounted) return;
      setState(() {
        state = s.state;
        logs.add('${DateTime.now().toIso8601String().substring(11, 19)}  ${s.state}');
        (connected || busy) ? spin.repeat() : spin.stop();
      });
    });
    v2ray.initializeV2Ray();
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      configs = p.getStringList('configs') ?? [];
      sel = p.getInt('sel') ?? 0;
      if (sel >= configs.length) sel = 0;
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('configs', configs);
    await p.setInt('sel', sel);
  }

  void snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

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

  Future<void> toggle() async {
    if (connected || busy) {
      v2ray.stopV2Ray();
      return;
    }
    if (configs.isEmpty) return snack('Ajoute d\'abord une config (onglet Configs)');
    final p = parse(configs[sel]);
    if (p == null) return snack('Config invalide');
    if (await v2ray.requestPermission()) {
      v2ray.startV2Ray(
        remark: p.remark,
        config: p.getFullConfiguration(),
        proxyOnly: false,
        bypassSubnets: null,
        blockedApps: null,
      );
    }
  }

  Future<void> ping() async {
    final p = configs.isEmpty ? null : parse(configs[sel]);
    if (p == null) return;
    snack('Ping en cours...');
    final d = await v2ray.getServerDelay(config: p.getFullConfiguration());
    setState(() => pings[sel] = '$d ms');
  }

  Future<void> addConfig() async {
    final c = TextEditingController();
    final clip = (await Clipboard.getData('text/plain'))?.text ?? '';
    if (clip.contains('://')) c.text = clip.trim();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Importer une config'),
        content: TextField(
          controller: c,
          maxLines: 4,
          decoration: const InputDecoration(
              hintText: 'vless:// vmess:// trojan:// ss://'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final links = c.text
                  .split('\n')
                  .map((e) => e.trim())
                  .where((e) => e.contains('://') && parse(e) != null)
                  .toList();
              if (links.isEmpty) return snack('Aucun lien valide');
              setState(() => configs.addAll(links));
              _save();
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Importer'),
          ),
        ],
      ),
    );
  }

  // ----- Onglet Connexion -----
  Widget connectionTab() {
    final p = configs.isEmpty ? null : parse(configs[sel]);
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
            const Text('OTAKU TUNNEL', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
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
          Text(connected ? 'Mangekyō activé' : busy ? 'Activation...' : 'Touche le Sharingan',
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
              onPressed: ping,
              icon: const Icon(Icons.network_ping),
              label: Text(pings[sel] ?? 'PING')),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(16)),
            child: p == null
                ? const Text('Aucune config sélectionnée')
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${proto(configs[sel])}  •  ${p.remark}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(p.address, style: const TextStyle(color: Colors.white60)),
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
            IconButton.filledTonal(onPressed: addConfig, icon: const Icon(Icons.add)),
          ]),
        ),
        Expanded(
          child: configs.isEmpty
              ? const Center(child: Text('Aucune config. Appuie sur +'))
              : ListView.builder(
                  itemCount: configs.length,
                  itemBuilder: (_, i) {
                    final p = parse(configs[i]);
                    return Card(
                      color: kCard,
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        leading: Icon(sel == i ? Icons.check_circle : Icons.circle_outlined,
                            color: sel == i ? kRed : Colors.white38),
                        title: Text('${proto(configs[i])}  ${p?.remark ?? ''}'),
                        subtitle: Text(p?.address ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          setState(() => sel = i);
                          _save();
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() {
                              configs.removeAt(i);
                              if (sel >= configs.length) sel = 0;
                            });
                            _save();
                          },
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]);

  // ----- Onglet Réglages -----
  Widget settingsTab() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Réglages', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SwitchListTile(
          title: const Text('Partager le VPN par hotspot'),
          subtitle: const Text('Bientôt disponible'),
          value: false,
          onChanged: null,
        ),
        const ListTile(title: Text('Options DNS'), subtitle: Text('Bientôt disponible')),
        const ListTile(title: Text('Anti-censure'), subtitle: Text('Bientôt disponible')),
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
          title: Text('OTAKU TUNNEL v1.0'),
          subtitle: Text('Créé par APPOH GODWIN • alias HACKER GODWIN'),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: [connectionTab(), configsTab(), settingsTab()][tab]),
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
