import 'package:flutter/gestures.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:url_launcher/url_launcher.dart';
import 'package:dartssh2/dartssh2.dart' as ssh;
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
  String msg, cmsg;
  Cfg(this.name, this.link, this.hidden,
      {this.expiry = '',
      this.limitMb = 0,
      this.used = 0,
      this.sub = '',
      this.msg = '',
      this.cmsg = ''});

  Map<String, dynamic> toJson() => {
        'name': name,
        'link': link,
        'hidden': hidden,
        'expiry': expiry,
        'limitMb': limitMb,
        'msg': msg,
        'cmsg': cmsg,
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
        msg: (j['msg'] ?? '').toString(),
        cmsg: (j['cmsg'] ?? '').toString(),
      );

  bool get expired {
    if (expiry.isEmpty) return false;
    final d = DateTime.tryParse(expiry);
    if (d == null) return false;
    return DateTime.now().isAfter(d.add(const Duration(days: 1)));
  }

  bool get overLimit => limitMb > 0 && used >= limitMb * 1048576;
  bool get isJson => link.startsWith('xrayjson://');
}

class SpeedRes {
  final double mbps;
  final int bytes;
  final int ttfb;
  final String error;
  SpeedRes(this.mbps, this.bytes, this.ttfb, this.error);
}

// Résultat de lecture d'une config (lien classique ou JSON complet du moteur).
class Parsed {
  final String remark;
  final String address;
  final String Function() full;
  Parsed(this.remark, this.address, this.full);
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


const kChan = MethodChannel('otaku/intent');

// ---------- Skins : œil du personnage + sa photo derrière ----------
class Skin {
  final String id;
  String name;
  final String file;
  final bool asset;
  final int w, h;
  final double ex, ey, es; // centre de l'œil et côté du carré (fractions de la photo)
  int color;
  ImageProvider? mem;
  Skin(this.id, this.name, this.file, this.asset, this.w, this.h, this.ex, this.ey, this.es,
      this.color);

  factory Skin.fromJson(Map<String, dynamic> j, bool asset) => Skin(
        '${j['id']}',
        '${j['name']}',
        '${j['file']}',
        asset,
        toInt(j['w']),
        toInt(j['h']),
        (num.tryParse('${j['ex']}') ?? 0.5).toDouble(),
        (num.tryParse('${j['ey']}') ?? 0.5).toDouble(),
        (num.tryParse('${j['es']}') ?? 0.3).toDouble(),
        toInt(j['color']) == 0 ? 0xFFE53935 : toInt(j['color']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'file': file,
        'w': w,
        'h': h,
        'ex': ex,
        'ey': ey,
        'es': es,
        'color': color,
      };

  Color get aura => Color(color);
  ImageProvider get provider =>
      mem ?? (asset ? AssetImage(file) as ImageProvider : FileImage(File(file)));
}

// Cercle sur l'œil du personnage (recadrage fait à l'affichage, la photo n'est pas modifiée).
class CharEye extends StatelessWidget {
  final Skin skin;
  final double size;
  final bool ring;
  const CharEye({super.key, required this.skin, required this.size, this.ring = true});

  @override
  Widget build(BuildContext context) {
    final side = max(skin.es * skin.w, 8.0);
    final scale = size / side;
    final cx = skin.ex * skin.w, cy = skin.ey * skin.h;
    final target = min(skin.w.toDouble(), size * 3 / max(skin.es, 0.05)).round();
    final img = Image(
      image: ResizeImage(skin.provider, width: target, allowUpscaling: false),
      width: skin.w * scale,
      height: skin.h * scale,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black,
        border: ring ? Border.all(color: skin.aura, width: max(2.0, size / 48)) : null,
        boxShadow: ring
            ? [BoxShadow(color: skin.aura.withValues(alpha: 0.7), blurRadius: size / 4)]
            : null,
      ),
      child: ClipOval(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(-(cx - side / 2) * scale, -(cy - side / 2) * scale),
            child: img,
          ),
        ),
      ),
    );
  }
}

// Photo du personnage en fond : assombrie, légèrement floutée (plus si elle est petite).
class CharBackground extends StatelessWidget {
  final Skin skin;
  const CharBackground({super.key, required this.skin});

  @override
  Widget build(BuildContext context) {
    final sigma = skin.w < 500 ? 2.6 : 1.2;
    return Stack(fit: StackFit.expand, children: [
      ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Image(
          image: ResizeImage(skin.provider, width: min(skin.w, 900), allowUpscaling: false),
          fit: BoxFit.cover,
          color: const Color(0xFF949494),
          colorBlendMode: BlendMode.modulate,
          filterQuality: FilterQuality.high,
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.55),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.85),
            ],
            stops: const [0, 0.16, 0.5, 1],
          ),
        ),
      ),
    ]);
  }
}

// Créateur de skin : choisis ta photo, place le cercle sur l'œil, donne un nom.
class SkinMaker extends StatefulWidget {
  const SkinMaker({super.key});
  @override
  State<SkinMaker> createState() => _SkinMakerState();
}

class _SkinMakerState extends State<SkinMaker> {
  Uint8List? bytes;
  String ext = 'jpg';
  int iw = 0, ih = 0;
  double ex = 0.5, ey = 0.4, es = 0.3;
  int color = 0xFFE53935, autoColor = 0xFFE53935;
  final name = TextEditingController();
  bool busy = false;

  static const palette = [
    0xFFE53935, 0xFFFF9800, 0xFFFFC107, 0xFF4CAF50, 0xFF00BCD4,
    0xFF2196F3, 0xFF9C27B0, 0xFFE91E63, 0xFFFFFFFF,
  ];

  void _msg(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  int _auto(ByteData bd) {
    final hist = List<double>.filled(36, 0);
    for (var i = 0; i + 3 < bd.lengthInBytes; i += 4) {
      final hsv = HSVColor.fromColor(
          Color.fromARGB(255, bd.getUint8(i), bd.getUint8(i + 1), bd.getUint8(i + 2)));
      if (hsv.saturation > 0.5 && hsv.value > 0.5) {
        hist[(hsv.hue ~/ 10) % 36] += hsv.saturation * hsv.value;
      }
    }
    var best = 0;
    for (var i = 1; i < 36; i++) {
      if (hist[i] > hist[best]) best = i;
    }
    if (hist[best] == 0) return 0xFFE53935;
    return HSVColor.fromAHSV(1, best * 10 + 5.0, 0.85, 1).toColor().toARGB32();
  }

  Future<void> pick() async {
    try {
      final f = await openFile(acceptedTypeGroups: [
        XTypeGroup(
            label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'webp'], mimeTypes: ['image/*'])
      ]);
      if (f == null) return;
      final b = await f.readAsBytes();
      final c1 = await ui.instantiateImageCodec(b);
      final f1 = await c1.getNextFrame();
      final w = f1.image.width, h = f1.image.height;
      f1.image.dispose();
      final c2 = await ui.instantiateImageCodec(b, targetWidth: 64);
      final f2 = await c2.getNextFrame();
      final bd = await f2.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final ac = bd == null ? 0xFFE53935 : _auto(bd);
      final dot = f.name.lastIndexOf('.');
      final e = dot >= 0 ? f.name.substring(dot + 1).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '') : '';
      if (!mounted) return;
      setState(() {
        bytes = b;
        iw = w;
        ih = h;
        ext = e.isEmpty ? 'jpg' : e;
        ex = 0.5;
        ey = 0.4;
        es = 0.3;
        autoColor = ac;
        color = ac;
        if (name.text.isEmpty) {
          final base = dot > 0 ? f.name.substring(0, dot) : f.name;
          name.text = base.length > 18 ? base.substring(0, 18) : base;
        }
      });
    } catch (_) {
      if (mounted) _msg('Photo illisible');
    }
  }

  Future<void> save() async {
    final b = bytes;
    if (b == null || iw == 0) return _msg('Choisis d\'abord une photo');
    setState(() => busy = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final sd = Directory('${dir.path}/skins');
      if (!sd.existsSync()) sd.createSync(recursive: true);
      final id = 'u${DateTime.now().millisecondsSinceEpoch}';
      final path = '${sd.path}/$id.$ext';
      await File(path).writeAsBytes(b);
      final n = name.text.trim().isEmpty ? 'Mon skin' : name.text.trim();
      if (!mounted) return;
      Navigator.pop(context, Skin(id, n, path, false, iw, ih, ex, ey, es, color));
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        _msg('Enregistrement impossible');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    Skin? tmp;
    if (b != null) {
      tmp = Skin('tmp', '', '', false, iw, ih, ex, ey, es, color)..mem = MemoryImage(b);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Créer un skin'),
        actions: [TextButton(onPressed: busy ? null : save, child: const Text('Enregistrer'))],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        OutlinedButton.icon(
          onPressed: pick,
          icon: const Icon(Icons.photo_library),
          label: Text(b == null ? 'Choisir une photo' : 'Changer de photo'),
        ),
        if (tmp != null) ...[
          const SizedBox(height: 12),
          const Text('Touche ou glisse sur la photo pour placer le cercle sur l\'œil.',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (ctx, bc) {
            const bh = 340.0;
            final bw = bc.maxWidth;
            final ar = iw / ih;
            final dw = (bw / bh > ar) ? bh * ar : bw;
            final dh = (bw / bh > ar) ? bh : bw / ar;
            final ox = (bw - dw) / 2, oy = (bh - dh) / 2;
            void place(Offset p) => setState(() {
                  ex = ((p.dx - ox) / dw).clamp(0.0, 1.0);
                  ey = ((p.dy - oy) / dh).clamp(0.0, 1.0);
                });
            final r = es * dw / 2;
            return SizedBox(
              width: bw,
              height: bh,
              child: GestureDetector(
                onTapDown: (d) => place(d.localPosition),
                onPanUpdate: (d) => place(d.localPosition),
                child: Stack(children: [
                  Positioned(
                    left: ox,
                    top: oy,
                    width: dw,
                    height: dh,
                    child: Image(image: MemoryImage(b!), fit: BoxFit.fill),
                  ),
                  Positioned(
                    left: ox + ex * dw - r,
                    top: oy + ey * dh - r,
                    width: r * 2,
                    height: r * 2,
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Color(color), width: 3),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            );
          }),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Taille'),
            Expanded(
              child: Slider(
                value: es,
                min: 0.05,
                max: 0.9,
                onChanged: (v) => setState(() => es = v),
              ),
            ),
          ]),
          if (es * iw < 90)
            const Text('Photo petite à cet endroit : l\'œil sera un peu flou. Agrandis le cercle.',
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          const SizedBox(height: 8),
          Center(child: CharEye(skin: tmp, size: 160)),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            decoration: const InputDecoration(
                labelText: 'Nom du personnage', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          const Text('Couleur de l\'aura'),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            GestureDetector(
              onTap: () => setState(() => color = autoColor),
              child: Chip(label: const Text('Auto'), backgroundColor: Color(autoColor)),
            ),
            for (final c in palette)
              GestureDetector(
                onTap: () => setState(() => color = c),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(c),
                    border: Border.all(
                        color: color == c ? Colors.white : Colors.transparent, width: 3),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : save,
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Enregistrer le skin'),
          ),
        ],
      ]),
    );
  }
}

List<int> b64dec(String s) {
  final t = s.trim().replaceAll('-', '+').replaceAll('_', '/');
  return base64Decode(base64.normalize(t));
}

bool validDate(String s) {
  final d = DateTime.tryParse(s);
  return d != null && d.toIso8601String().substring(0, 10) == s;
}

// Lit un lien vmess/vless/trojan/ss et le transforme en champs modifiables.
Map<String, String>? parseLink(String link) {
  final l = link.trim();
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(utf8.decode(b64dec(l.substring(8)))) as Map<String, dynamic>;
      String g(String k, [String d = '']) {
        final v = j[k];
        return (v == null || '$v'.isEmpty) ? d : '$v';
      }

      return {
        'proto': 'vmess',
        'remark': g('ps'),
        'add': g('add'),
        'port': g('port', '443'),
        'id': g('id'),
        'aid': g('aid', '0'),
        'scn': g('scy', g('scn', 'auto')),
        'net': g('net', 'tcp'),
        'type': g('type', 'none'),
        'host': g('host'),
        'path': g('path'),
        'tls': g('tls'),
        'sni': g('sni'),
        'alpn': g('alpn'),
        'fp': g('fp'),
        'ins': g('allowInsecure'),
      };
    }
    if (l.startsWith('vless://') || l.startsWith('trojan://')) {
      final u = Uri.parse(l);
      final q = u.queryParameters;
      const known = {
        'type', 'security', 'host', 'path', 'sni', 'alpn', 'fp', 'flow', 'encryption',
        'serviceName', 'allowInsecure', 'headerType'
      };
      final f = <String, String>{
        'proto': u.scheme,
        'remark': Uri.decodeComponent(u.fragment),
        'add': u.host,
        'port': '${u.hasPort ? u.port : 443}',
        'id': Uri.decodeComponent(u.userInfo),
        'net': q['type'] ?? 'tcp',
        'tls': q['security'] ?? 'none',
        'host': q['host'] ?? '',
        'path': q['path'] ?? '',
        'sni': q['sni'] ?? '',
        'alpn': q['alpn'] ?? '',
        'fp': q['fp'] ?? '',
        'flow': q['flow'] ?? '',
        'enc': q['encryption'] ?? 'none',
        'svc': q['serviceName'] ?? '',
        'ins': q['allowInsecure'] ?? '',
        'type': q['headerType'] ?? 'none',
      };
      q.forEach((k, v) {
        if (!known.contains(k)) f['x_$k'] = v;
      });
      return f;
    }
    if (l.startsWith('dns://')) {
      final j = jsonDecode(utf8.decode(b64dec(l.substring(6)))) as Map<String, dynamic>;
      return {
        'proto': 'dns',
        'remark': '${j['n'] ?? ''}',
        'add': '',
        'domain': '${j['d'] ?? ''}',
        'pubkey': '${j['pk'] ?? ''}',
        'transport': '${j['tr'] ?? 'udp'}',
        'resolver': '${j['rs'] ?? '8.8.8.8:53'}',
        'smethod': '${j['m'] ?? 'ssh'}',
        'suser': '${j['su'] ?? ''}',
        'spass': '${j['sp'] ?? ''}',
        'user': '${j['u'] ?? ''}',
        'id': '${j['p'] ?? ''}',
        'port': '${j['port'] ?? 22}',
      };
    }
    if (l.startsWith('ssh://')) {
      final body = l.substring(6);
      try {
        final j = jsonDecode(utf8.decode(b64dec(body))) as Map<String, dynamic>;
        return {
          'proto': 'ssh',
          'remark': '${j['n'] ?? ''}',
          'add': '${j['h'] ?? ''}',
          'port': '${j['port'] ?? 22}',
          'user': '${j['u'] ?? ''}',
          'id': '${j['p'] ?? ''}',
          'mode': '${j['m'] ?? 'direct'}',
          'sni': '${j['sni'] ?? ''}',
          'payload': '${j['pl'] ?? ''}',
          'rproxy': '${j['rp'] ?? ''}',
        };
      } catch (_) {
        final u = Uri.parse(l);
        final ui = u.userInfo.split(':');
        return {
          'proto': 'ssh',
          'remark': Uri.decodeComponent(u.fragment),
          'add': u.host,
          'port': '${u.hasPort ? u.port : 22}',
          'user': Uri.decodeComponent(ui.first),
          'id': ui.length > 1 ? Uri.decodeComponent(ui.sublist(1).join(':')) : '',
          'mode': 'direct',
          'sni': '',
          'payload': '',
          'rproxy': '',
        };
      }
    }
    if (l.startsWith('ss://')) {
      var rest = l.substring(5);
      var remark = '';
      final h = rest.indexOf('#');
      if (h >= 0) {
        remark = Uri.decodeComponent(rest.substring(h + 1));
        rest = rest.substring(0, h);
      }
      var raw = '';
      final qm = rest.indexOf('?');
      if (qm >= 0) {
        raw = rest.substring(qm + 1);
        rest = rest.substring(0, qm);
      }
      String cred;
      String hostPort;
      if (rest.contains('@')) {
        final at = rest.lastIndexOf('@');
        var ui = Uri.decodeComponent(rest.substring(0, at));
        hostPort = rest.substring(at + 1);
        if (!ui.contains(':')) ui = utf8.decode(b64dec(ui));
        cred = ui;
      } else {
        final d = utf8.decode(b64dec(rest));
        final at = d.lastIndexOf('@');
        cred = d.substring(0, at);
        hostPort = d.substring(at + 1);
      }
      final c = cred.indexOf(':');
      final colon = hostPort.lastIndexOf(':');
      return {
        'proto': 'ss',
        'remark': remark,
        'add': hostPort.substring(0, colon),
        'port': hostPort.substring(colon + 1).replaceAll('/', ''),
        'method': cred.substring(0, c),
        'id': cred.substring(c + 1),
        'x_raw': raw,
      };
    }
  } catch (_) {}
  return null;
}

// Reconstruit un lien à partir des champs.
String? buildLink(Map<String, String> f) {
  final p = f['proto'] ?? '';
  final remark = f['remark'] ?? '';
  final port = int.tryParse(f['port'] ?? '') ?? 443;
  if (p != 'dns' && (f['add'] ?? '').isEmpty) return null;
  if (p == 'vmess') {
    final j = {
      'v': '2',
      'ps': remark,
      'add': f['add'],
      'port': port,
      'id': f['id'] ?? '',
      'aid': int.tryParse(f['aid'] ?? '0') ?? 0,
      'scy': (f['scn'] ?? '').isEmpty ? 'auto' : f['scn'],
      'net': f['net'] ?? 'tcp',
      'type': f['type'] ?? 'none',
      'host': f['host'] ?? '',
      'path': f['path'] ?? '',
      'tls': f['tls'] ?? '',
      'sni': f['sni'] ?? '',
      'alpn': f['alpn'] ?? '',
      'fp': f['fp'] ?? '',
    };
    if ((f['ins'] ?? '').isNotEmpty) j['allowInsecure'] = f['ins'];
    return 'vmess://${base64Encode(utf8.encode(jsonEncode(j)))}';
  }
  if (p == 'vless' || p == 'trojan') {
    final q = <String, String>{};
    void put(String k, String? v) {
      if (v != null && v.isNotEmpty) q[k] = v;
    }

    put('type', f['net']);
    put('security', f['tls']);
    if (p == 'vless') put('encryption', (f['enc'] ?? '').isEmpty ? 'none' : f['enc']);
    put('flow', f['flow']);
    put('host', f['host']);
    put('path', f['path']);
    put('sni', f['sni']);
    put('alpn', f['alpn']);
    put('fp', f['fp']);
    put('serviceName', f['svc']);
    final ht = f['type'] ?? 'none';
    if (ht.isNotEmpty && ht != 'none') q['headerType'] = ht;
    if ((f['ins'] ?? '').isNotEmpty) q['allowInsecure'] = f['ins']!;
    f.forEach((k, v) {
      if (k.startsWith('x_') && v.isNotEmpty) q[k.substring(2)] = v;
    });
    final id = f['id'] ?? '';
    return Uri(
      scheme: p,
      userInfo: id.isEmpty ? null : id,
      host: f['add'],
      port: port,
      queryParameters: q.isEmpty ? null : q,
      fragment: remark.isEmpty ? null : remark,
    ).toString();
  }
  if (p == 'dns') {
    final j = {
      'n': remark,
      'd': f['domain'] ?? '',
      'pk': f['pubkey'] ?? '',
      'tr': f['transport'] ?? 'udp',
      'rs': f['resolver'] ?? '',
      'm': f['smethod'] ?? 'ssh',
      'su': f['suser'] ?? '',
      'sp': f['spass'] ?? '',
      'u': f['user'] ?? '',
      'p': f['id'] ?? '',
      'port': (f['port'] ?? '').isEmpty ? 22 : port,
    };
    return 'dns://${base64Encode(utf8.encode(jsonEncode(j)))}';
  }
  if (p == 'ssh') {
    final j = {
      'n': remark,
      'h': f['add'],
      'port': (f['port'] ?? '').isEmpty ? 22 : port,
      'u': f['user'] ?? '',
      'p': f['id'] ?? '',
      'm': f['mode'] ?? 'direct',
      'sni': f['sni'] ?? '',
      'pl': f['payload'] ?? '',
      'rp': f['rproxy'] ?? '',
    };
    return 'ssh://${base64Encode(utf8.encode(jsonEncode(j)))}';
  }
  if (p == 'ss') {
    final cred = base64Encode(utf8.encode('${f['method'] ?? 'aes-256-gcm'}:${f['id'] ?? ''}'));
    final raw = f['x_raw'] ?? '';
    final extra = raw.isEmpty ? '' : '?$raw';
    final frag = remark.isEmpty ? '' : '#${Uri.encodeComponent(remark)}';
    return 'ss://$cred@${f['add']}:$port$extra$frag';
  }
  return null;
}

// ---------- Éditeur de config (champs détaillés) ----------
class ConfigEditor extends StatefulWidget {
  final Cfg? cfg;
  final bool defaultInsecure;
  const ConfigEditor({super.key, this.cfg, this.defaultInsecure = false});
  @override
  State<ConfigEditor> createState() => _ConfigEditorState();
}

class _ConfigEditorState extends State<ConfigEditor> {
  late String proto;
  String net = 'ws', tls = 'tls', vtype = 'none';
  String smode = 'direct';
  String dtrans = 'udp', dmethod = 'ssh';
  bool insecure = false;
  final Map<String, TextEditingController> c = {};
  final Map<String, String> extra = {};
  bool isNew = true;

  static const keys = [
    'remark', 'add', 'port', 'id', 'aid', 'scn', 'host', 'path', 'sni', 'alpn', 'fp',
    'flow', 'enc', 'svc', 'method', 'expiry', 'limit', 'user', 'payload', 'rproxy', 'msg', 'cmsg', 'domain', 'pubkey', 'resolver', 'suser', 'spass'
  ];

  @override
  void initState() {
    super.initState();
    for (final k in keys) {
      c[k] = TextEditingController();
    }
    final cf = widget.cfg;
    final f = cf == null ? null : parseLink(cf.link);
    if (f != null && cf != null) {
      isNew = false;
      proto = f['proto'] ?? 'vmess';
      f.forEach((k, v) {
        if (c.containsKey(k)) c[k]!.text = v;
        if (k.startsWith('x_')) extra[k] = v;
      });
      net = f['net'] ?? 'tcp';
      tls = f['tls'] ?? '';
      vtype = f['type'] ?? 'none';
      smode = f['mode'] ?? 'direct';
      dtrans = f['transport'] ?? 'udp';
      dmethod = f['smethod'] ?? 'ssh';
      final ir = f['ins'] ?? '';
      insecure = ir.isEmpty ? widget.defaultInsecure : (ir == '1' || ir.toLowerCase() == 'true');
      c['expiry']!.text = cf.expiry;
      c['limit']!.text = cf.limitMb > 0 ? '${cf.limitMb}' : '';
      c['msg']!.text = cf.msg;
      c['cmsg']!.text = cf.cmsg;
    } else {
      proto = 'vmess';
      _defaults();
    }
  }

  void _defaults() {
    c['port']!.text = '443';
    c['aid']!.text = '0';
    c['scn']!.text = 'auto';
    c['enc']!.text = 'none';
    c['method']!.text = 'aes-256-gcm';
    net = 'ws';
    tls = 'tls';
    insecure = widget.defaultInsecure;
    if (proto == 'dns') {
      c['port']!.text = '22';
      c['resolver']!.text = '8.8.8.8:53';
      dtrans = 'udp';
      dmethod = 'ssh';
    }
    if (proto == 'ssh') {
      c['port']!.text = '22';
      smode = 'direct';
      if (c['payload']!.text.isEmpty) {
        c['payload']!.text =
            'GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]';
      }
    }
  }

  Future<void> scanDns() async {
    final dom = c['domain']!.text.trim();
    if (dom.isEmpty) return _err('Entre d\'abord le domaine du tunnel');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Test des résolveurs...'),
        ]),
      ),
    );
    final res = await Future.wait(kResolvers.map((r) async => MapEntry(r, await dnsProbe(r, dom))));
    if (!mounted) return;
    Navigator.pop(context);
    final ok = res.where((e) => e.value >= 0).toList()..sort((a, b) => a.value.compareTo(b.value));
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ok.isEmpty ? 'Aucun résolveur ne répond' : 'Résolveurs qui répondent'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (final e in ok)
              ListTile(
                dense: true,
                title: Text(e.key),
                trailing: Text('${e.value} ms'),
                onTap: () {
                  c['resolver']!.text = e.key;
                  Navigator.pop(ctx);
                },
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))],
      ),
    );
  }

  void _err(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  void _save() {
    final f = <String, String>{'proto': proto, 'net': net, 'tls': tls, 'type': vtype};
    for (final k in keys) {
      f[k] = c[k]!.text.trim();
    }
    f.addAll(extra);
    f['ins'] = insecure ? '1' : '0';
    f['mode'] = smode;
    f['transport'] = dtrans;
    f['smethod'] = dmethod;
    final link = buildLink(f);
    if (link == null) return _err('Le serveur cible est obligatoire');
    if (proto == 'dns') {
      if ((f['domain'] ?? '').isEmpty) return _err('Domaine du tunnel obligatoire');
      if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(f['pubkey'] ?? '')) {
        return _err('Clé publique : 64 caractères hexadécimaux');
      }
      if (dmethod == 'ssh' && (f['user'] ?? '').isEmpty) return _err('Utilisateur SSH obligatoire');
    } else if (proto == 'ssh') {
      if ((f['user'] ?? '').isEmpty) return _err('Utilisateur SSH obligatoire');
    } else {
      try {
        FlutterV2ray.parseFromURL(link);
      } catch (_) {
        return _err('Config invalide : vérifie les champs');
      }
    }
    final ex = c['expiry']!.text.trim();
    if (ex.isNotEmpty && !validDate(ex)) {
      return _err('Date invalide (ex : 2026-12-31)');
    }
    final old = widget.cfg;
    final name = f['remark']!.isEmpty ? (proto == 'dns' ? f['domain']! : f['add']!) : f['remark']!;
    Navigator.pop(
      context,
      Cfg(name, link, false,
          expiry: ex,
          limitMb: int.tryParse(c['limit']!.text.trim()) ?? 0,
          used: old?.used ?? 0,
          sub: old?.sub ?? '',
          msg: c['msg']!.text.trim(),
          cmsg: c['cmsg']!.text.trim()),
    );
  }

  Widget field(String k, String label, {TextInputType? type, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c[k],
          keyboardType: type,
          maxLines: lines,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        ),
      );

  Widget drop(String label, String value, List<String> opts, void Function(String) on,
      {Map<String, String>? names}) {
    final list = opts.contains(value) ? opts : [...opts, value];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isDense: true,
            isExpanded: true,
            value: value,
            items: list
                .map((o) => DropdownMenuItem(
                    value: o, child: Text(names?[o] ?? (o.isEmpty ? 'Aucune' : o))))
                .toList(),
            onChanged: (v) {
              if (v != null) on(v);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(isNew ? 'Nouvelle config' : 'Modifier la config'),
          actions: [TextButton(onPressed: _save, child: const Text('Enregistrer'))],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (isNew)
            drop('Protocole', proto, ['vmess', 'vless', 'trojan', 'ss', 'ssh', 'dns'],
                (v) => setState(() {
                      proto = v;
                      _defaults();
                    }),
                names: {
                  'vmess': 'VMess',
                  'vless': 'VLESS',
                  'trojan': 'Trojan',
                  'ss': 'Shadowsocks',
                  'ssh': 'SSH (tunnel)',
                  'dns': 'DNS tunnel (SlowDNS / DNSTT)'
                }),
          field('remark', 'Nom'),
          if (proto != 'dns') field('add', 'Serveur cible (target)'),
          if (proto != 'dns') field('port', 'Port', type: TextInputType.number),
          if (proto == 'vmess') ...[
            field('id', 'UUID'),
            field('aid', 'AlterId', type: TextInputType.number),
            drop(
                'Chiffrement (security)',
                c['scn']!.text.isEmpty ? 'auto' : c['scn']!.text,
                ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'none', 'zero'],
                (v) => setState(() => c['scn']!.text = v)),
          ],
          if (proto == 'vless') ...[
            field('id', 'UUID'),
            field('enc', 'Encryption (none)'),
            field('flow', 'Flow (facultatif)'),
          ],
          if (proto == 'trojan') field('id', 'Mot de passe'),
          if (proto == 'dns') ...[
            field('domain', 'Domaine du tunnel (NS)'),
            field('pubkey', 'Clé publique (64 caractères hexadécimaux)'),
            drop('Transport DNS', dtrans, ['udp', 'dot', 'doh'], (v) => setState(() => dtrans = v),
                names: {'udp': 'UDP', 'dot': 'DoT (TLS)', 'doh': 'DoH (HTTPS)'}),
            field('resolver', 'Résolveur DNS (hôte:port)'),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OutlinedButton.icon(
                onPressed: scanDns,
                icon: const Icon(Icons.search),
                label: const Text('Chercher des résolveurs qui marchent'),
              ),
            ),
            drop('Méthode de connexion', dmethod, ['ssh', 'socks'], (v) => setState(() => dmethod = v),
                names: {'ssh': 'SSH (dans le tunnel)', 'socks': 'SOCKS'}),
            if (dmethod == 'ssh') ...[
              field('port', 'Port SSH', type: TextInputType.number),
              field('user', 'Utilisateur SSH'),
              field('id', 'Mot de passe SSH'),
            ] else ...[
              field('suser', 'Utilisateur SOCKS5 (facultatif)'),
              field('spass', 'Mot de passe SOCKS5 (facultatif)'),
            ],
          ],
          if (proto == 'ssh') ...[
            field('user', 'Utilisateur SSH'),
            field('id', 'Mot de passe'),
            drop('Mode de connexion', smode, ['direct', 'ssl', 'payload', 'ssl+payload'],
                (v) => setState(() => smode = v),
                names: {
                  'direct': 'SSH direct',
                  'ssl': 'SSH + SSL/TLS (SNI)',
                  'payload': 'SSH + payload HTTP',
                  'ssl+payload': 'SSH + SSL + payload'
                }),
            if (smode.contains('ssl')) field('sni', 'SNI (nom affiché au serveur)'),
            if (smode.contains('payload')) ...[
              field('payload', 'Payload ([crlf] [host] [host_port] [split])', lines: 4),
              field('rproxy', 'Proxy distant host:port (facultatif)'),
            ],
          ],
          if (proto == 'ss') ...[
            field('method', 'Méthode (ex : aes-256-gcm)'),
            field('id', 'Mot de passe'),
          ],
          if (proto != 'ss' && proto != 'ssh' && proto != 'dns') ...[
            drop('Réseau', net, ['tcp', 'ws', 'grpc', 'h2', 'httpupgrade', 'kcp', 'quic'],
                (v) => setState(() => net = v)),
            drop('En-tête (head type)', vtype,
                ['none', 'http', 'srtp', 'utp', 'wechat-video', 'dtls', 'wireguard'],
                (v) => setState(() => vtype = v)),
            drop('Sécurité', tls, proto == 'vmess' ? ['', 'tls'] : ['none', 'tls', 'reality'],
                (v) => setState(() => tls = v),
                names: {'': 'Aucune', 'none': 'Aucune', 'tls': 'TLS', 'reality': 'Reality'}),
            field('host', 'Host (header host)'),
            field('path', 'Path'),
            field('sni', 'SNI (server name indication)'),
            field('alpn', 'ALPN (ex : h2,http/1.1)'),
            field('fp', 'Fingerprint (ex : chrome)'),
            if (tls == 'tls' || tls == 'reality')
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Autoriser certificat non vérifié'),
                subtitle: const Text('allowInsecure : utile si le SNI diffère du serveur'),
                value: insecure,
                onChanged: (v) => setState(() => insecure = v),
              ),
            if (proto == 'vless') field('svc', 'Nom du service (gRPC)'),
          ],
          const Divider(),
          field('expiry', 'Expire le (AAAA-MM-JJ, facultatif)'),
          field('limit', 'Limite de données en Mo (0 = aucune)', type: TextInputType.number),
          const Divider(),
          const Text('Messages (facultatif)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
              'HTML simple (<b>, <i>, <u>, <h1>, <br>, <center>, <span style="color:#ff0">) et '
              'variables {ip} {pays} {ville} {heure} {serveur}. Le code Python n\'est jamais exécuté.',
              style: TextStyle(color: Colors.white60, fontSize: 11)),
          const SizedBox(height: 8),
          field('msg', 'Message pour celui qui ouvre le fichier', lines: 4),
          field('cmsg', 'Message de connexion (quand le trafic passe)', lines: 4),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Enregistrer'),
          ),
        ]),
      );
}

// ---------- Config Xray de base (SSH, WireGuard) ----------
const kSshPort = 10810;

Map<String, dynamic> xrayBase(Map<String, dynamic> proxy, {required bool tcpOnly}) => {
      'log': {'loglevel': 'warning'},
      'stats': {},
      'policy': {
        'levels': {
          '8': {'connIdle': 300, 'uplinkOnly': 1, 'downlinkOnly': 1}
        },
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true}
      },
      'dns': {
        'servers': tcpOnly
            ? ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query']
            : ['1.1.1.1', '8.8.8.8'],
        'queryStrategy': 'UseIPv4'
      },
      'inbounds': [
        {
          'tag': 'socks',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls']
          }
        },
        {
          'tag': 'http',
          'port': 10809,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {'userLevel': 8}
        },
      ],
      'outbounds': [
        proxy,
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
        {'tag': 'block', 'protocol': 'blackhole', 'settings': {}},
        {'tag': 'dns-out', 'protocol': 'dns'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': tcpOnly
            ? [
                {'type': 'field', 'port': '53', 'outboundTag': 'dns-out'},
                {'type': 'field', 'network': 'udp', 'outboundTag': 'block'},
              ]
            : [],
      },
    };

// Un tunnel SSH est exposé en SOCKS local (kSshPort) ; le moteur s'y branche.
String sshXrayJson() => jsonEncode(xrayBase({
      'tag': 'proxy',
      'protocol': 'socks',
      'settings': {
        'servers': [
          {'address': '127.0.0.1', 'port': kSshPort}
        ]
      }
    }, tcpOnly: true));

// Fichier WireGuard (.conf) -> config Xray
Map<String, dynamic>? wgToXray(String text) {
  final iface = <String, String>{};
  final peer = <String, String>{};
  var cur = '';
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    final l = raw.trim();
    if (l.isEmpty || l.startsWith('#') || l.startsWith(';')) continue;
    if (l.startsWith('[')) {
      cur = l.toLowerCase();
      continue;
    }
    final i = l.indexOf('=');
    if (i < 0) continue;
    final k = l.substring(0, i).trim().toLowerCase();
    final v = l.substring(i + 1).trim();
    if (cur == '[interface]') {
      iface[k] = v;
    } else if (cur == '[peer]') {
      peer[k] = v;
    }
  }
  final sk = iface['privatekey'], pk = peer['publickey'], ep = peer['endpoint'];
  if (sk == null || pk == null || ep == null) return null;
  List<String> split(String? v, String d) =>
      (v ?? d).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final p = <String, dynamic>{
    'publicKey': pk,
    'endpoint': ep,
    'allowedIPs': split(peer['allowedips'], '0.0.0.0/0, ::/0'),
  };
  if (peer['presharedkey'] != null) p['preSharedKey'] = peer['presharedkey'];
  final cfg = xrayBase({
    'tag': 'proxy',
    'protocol': 'wireguard',
    'settings': {
      'secretKey': sk,
      'address': split(iface['address'], '10.0.0.2/32'),
      'peers': [p],
      'mtu': int.tryParse(iface['mtu'] ?? '') ?? 1280,
    }
  }, tcpOnly: false);
  final host = ep.contains(':') ? ep.substring(0, ep.lastIndexOf(':')) : ep;
  cfg['remarks'] = 'WireGuard $host';
  return cfg;
}

// ---------- Tunnel SSH (direct, SSL/SNI, payload HTTP) ----------
List<String> expandPayload(String p, String host, int port) {
  var raw = p;
  if (!raw.contains('[crlf]') && !raw.contains('[lf]')) {
    raw = raw.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
  }
  final s = raw
      .replaceAll('[crlf]', '\r\n')
      .replaceAll('[lf]', '\n')
      .replaceAll('[cr]', '\r')
      .replaceAll('[host_port]', '$host:$port')
      .replaceAll('[host]', host)
      .replaceAll('[port]', '$port')
      .replaceAll('[method]', 'CONNECT')
      .replaceAll('[protocol]', 'HTTP/1.1')
      .replaceAll('[ua]', 'Mozilla/5.0');
  return s.split('[split]');
}

class _Remote {
  final Socket socket;
  final Stream<Uint8List> stream;
  _Remote(this.socket, this.stream);
}

// Ouvre la connexion vers le serveur SSH : TCP, éventuellement TLS (SNI), éventuellement
// payload HTTP (le flux SSH commence après la réponse du serveur).
Future<_Remote> openRemote(Map<String, String> f, void Function(String) log) async {
  final host = f['add'] ?? '';
  final port = int.tryParse(f['port'] ?? '') ?? 22;
  final mode = f['mode'] ?? 'direct';
  final useSsl = mode.contains('ssl');
  final usePayload = mode.contains('payload');
  var th = host;
  var tp = port;
  final rp = (f['rproxy'] ?? '').trim();
  if (usePayload && rp.contains(':')) {
    th = rp.substring(0, rp.lastIndexOf(':'));
    tp = int.tryParse(rp.substring(rp.lastIndexOf(':') + 1)) ?? port;
  }
  Socket sock = await Socket.connect(th, tp, timeout: const Duration(seconds: 10));
  sock.setOption(SocketOption.tcpNoDelay, true);
  if (useSsl) {
    final sni = (f['sni'] ?? '').trim().isEmpty ? th : (f['sni'] ?? '').trim();
    sock = await SecureSocket.secure(sock, host: sni, onBadCertificate: (_) => true);
  }
  final ctl = StreamController<Uint8List>();
  final hdr = Completer<String>();
  final buf = <int>[];
  var inHeader = usePayload;
  sock.listen((d) {
    if (inHeader) {
      buf.addAll(d);
      var end = -1;
      for (var i = 0; i + 3 < buf.length; i++) {
        if (buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10) {
          end = i;
          break;
        }
      }
      if (end >= 0) {
        inHeader = false;
        final head = utf8.decode(buf.sublist(0, end), allowMalformed: true);
        final rest = buf.sublist(end + 4);
        if (!hdr.isCompleted) hdr.complete(head);
        if (rest.isNotEmpty) ctl.add(Uint8List.fromList(rest));
      }
    } else {
      ctl.add(d);
    }
  }, onDone: () {
    if (!hdr.isCompleted) hdr.completeError('connexion fermée par le serveur');
    ctl.close();
  }, onError: (Object e) {
    if (!hdr.isCompleted) hdr.completeError(e);
    ctl.addError(e);
    ctl.close();
  }, cancelOnError: true);
  if (usePayload) {
    final parts = expandPayload(f['payload'] ?? '', host, port);
    for (var i = 0; i < parts.length; i++) {
      sock.add(utf8.encode(parts[i]));
      await sock.flush();
      if (i < parts.length - 1) await Future.delayed(const Duration(milliseconds: 150));
    }
    final head = await hdr.future.timeout(const Duration(seconds: 10));
    final first = head.split('\r\n').first;
    final m = RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(first);
    final code = m == null ? 0 : int.parse(m.group(1)!);
    log('Réponse payload : $first');
    if (code < 100 || code > 299) {
      sock.destroy();
      throw 'réponse du serveur : $first';
    }
  }
  return _Remote(sock, ctl.stream);
}

class _ByteReader {
  final StreamIterator<Uint8List> it;
  final List<int> buf = [];
  _ByteReader(Stream<Uint8List> s) : it = StreamIterator<Uint8List>(s);
  Future<List<int>> read(int n) async {
    while (buf.length < n) {
      if (!await it.moveNext()) throw StateError('fin de flux');
      buf.addAll(it.current);
    }
    final out = buf.sublist(0, n);
    buf.removeRange(0, n);
    return out;
  }
}

class SshTunnel {
  ssh.SSHClient? client;
  ServerSocket? bridge, socks;
  Socket? remote;
  void Function()? onClosed;
  bool stopped = false;

  Future<void> start(Map<String, String> f, void Function(String) log, {int authSecs = 25}) async {
    stopped = false;
    final host = f['add'] ?? '';
    final port = int.tryParse(f['port'] ?? '') ?? 22;
    final user = f['user'] ?? '';
    final pass = f['id'] ?? '';
    final rem = await openRemote(f, log);
    remote = rem.socket;
    final br = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    bridge = br;
    br.first.then((local) {
      rem.stream.listen((d) {
        try {
          local.add(d);
        } catch (_) {}
      }, onDone: () => local.destroy(), onError: (Object _) => local.destroy(), cancelOnError: true);
      local.listen((d) {
        try {
          rem.socket.add(d);
        } catch (_) {}
      }, onDone: () => rem.socket.destroy(), onError: (Object _) => rem.socket.destroy(), cancelOnError: true);
    }, onError: (Object _) {});
    final sock = await ssh.SSHSocket.connect('127.0.0.1', br.port);
    final c = ssh.SSHClient(
      sock,
      username: user,
      onPasswordRequest: () => pass,
      keepAliveInterval: const Duration(seconds: 15),
    );
    client = c;
    await c.authenticated.timeout(Duration(seconds: authSecs));
    c.done.then((_) {
      if (!stopped) onClosed?.call();
    }, onError: (Object _) {
      if (!stopped) onClosed?.call();
    });
    final sv = await ServerSocket.bind(InternetAddress.loopbackIPv4, kSshPort);
    socks = sv;
    sv.listen(_handle);
    log('SSH connecté : $user@$host:$port');
  }

  Future<void> stop() async {
    stopped = true;
    try {
      client?.close();
    } catch (_) {}
    try {
      await socks?.close();
    } catch (_) {}
    try {
      await bridge?.close();
    } catch (_) {}
    try {
      remote?.destroy();
    } catch (_) {}
    client = null;
    socks = null;
    bridge = null;
    remote = null;
  }

  // Petit serveur SOCKS5 : chaque connexion passe par un canal du tunnel SSH.
  Future<void> _handle(Socket c) async {
    final rd = _ByteReader(c);
    try {
      final h = await rd.read(2);
      await rd.read(h[1]);
      c.add([5, 0]);
      final q = await rd.read(4);
      if (q[1] != 1) {
        c.add([5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        await c.close();
        return;
      }
      String dest;
      if (q[3] == 1) {
        dest = InternetAddress.fromRawAddress(Uint8List.fromList(await rd.read(4))).address;
      } else if (q[3] == 3) {
        final n = (await rd.read(1))[0];
        dest = utf8.decode(await rd.read(n), allowMalformed: true);
      } else {
        dest = InternetAddress.fromRawAddress(Uint8List.fromList(await rd.read(16))).address;
      }
      final pb = await rd.read(2);
      final dport = (pb[0] << 8) | pb[1];
      final cl = client;
      if (cl == null) {
        c.destroy();
        return;
      }
      dynamic ch;
      try {
        ch = await cl.forwardLocal(dest, dport);
      } catch (_) {
        c.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
        await c.close();
        return;
      }
      c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
      ch.stream.listen((d) {
        try {
          c.add(d);
        } catch (_) {}
      }, onDone: () => c.destroy(), onError: (Object _) => c.destroy(), cancelOnError: true);
      if (rd.buf.isNotEmpty) {
        ch.sink.add(Uint8List.fromList(rd.buf));
        rd.buf.clear();
      }
      while (await rd.it.moveNext()) {
        ch.sink.add(rd.it.current);
      }
      await ch.sink.close();
    } catch (_) {
      try {
        c.destroy();
      } catch (_) {}
    }
  }
}

// ---------- Messages : HTML simple + variables (aucun script n'est jamais exécuté) ----------
class IpInfo {
  final String ip, country, cc, city, region, isp, tz;
  final DateTime at;
  IpInfo(this.ip, this.country, this.cc, this.city, this.region, this.isp, this.tz, this.at);
}

String flagOf(String cc) => cc.length == 2
    ? String.fromCharCodes(cc.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 65))
    : '🌐';

const kSteps = ['Config', 'Tunnel', 'Moteur', 'Trafic', 'IP / lieu'];

String fillVars(String s, Map<String, String> v) {
  var out = s;
  v.forEach((k, val) => out = out.replaceAll('{$k}', val));
  return out;
}

String decodeEntities(String s) => s
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)))
    .replaceAll('&amp;', '&');

// ---------- Rendu des messages : HTML/CSS limité, animations et liens (jamais de script) ----------
Color? parseCssColor(String raw) {
  final v = raw.trim().toLowerCase();
  const names = <String, int>{
    'red': 0xFFFF0000, 'green': 0xFF008000, 'lime': 0xFF00FF00, 'blue': 0xFF0000FF,
    'yellow': 0xFFFFFF00, 'orange': 0xFFFFA500, 'purple': 0xFF800080, 'pink': 0xFFFFC0CB,
    'white': 0xFFFFFFFF, 'black': 0xFF000000, 'gray': 0xFF808080, 'grey': 0xFF808080,
    'cyan': 0xFF00FFFF, 'aqua': 0xFF00FFFF, 'magenta': 0xFFFF00FF, 'fuchsia': 0xFFFF00FF,
    'gold': 0xFFFFD700, 'silver': 0xFFC0C0C0, 'brown': 0xFFA52A2A, 'violet': 0xFFEE82EE,
    'indigo': 0xFF4B0082, 'teal': 0xFF008080, 'navy': 0xFF000080, 'crimson': 0xFFDC143C,
    'orangered': 0xFFFF4500, 'hotpink': 0xFFFF69B4, 'deeppink': 0xFFFF1493, 'tomato': 0xFFFF6347,
    'coral': 0xFFFF7F50, 'salmon': 0xFFFA8072, 'skyblue': 0xFF87CEEB, 'dodgerblue': 0xFF1E90FF,
    'royalblue': 0xFF4169E1, 'lightblue': 0xFFADD8E6, 'lightgreen': 0xFF90EE90, 'darkgreen': 0xFF006400,
    'darkred': 0xFF8B0000, 'darkblue': 0xFF00008B, 'chartreuse': 0xFF7FFF00, 'springgreen': 0xFF00FF7F,
    'turquoise': 0xFF40E0D0, 'lavender': 0xFFE6E6FA, 'plum': 0xFFDDA0DD, 'orchid': 0xFFDA70D6,
    'khaki': 0xFFF0E68C, 'maroon': 0xFF800000, 'olive': 0xFF808000, 'beige': 0xFFF5F5DC,
    'ivory': 0xFFFFFFF0, 'wheat': 0xFFF5DEB3, 'tan': 0xFFD2B48C, 'chocolate': 0xFFD2691E,
    'firebrick': 0xFFB22222, 'steelblue': 0xFF4682B4, 'slateblue': 0xFF6A5ACD, 'blueviolet': 0xFF8A2BE2,
    'darkviolet': 0xFF9400D3, 'deepskyblue': 0xFF00BFFF, 'limegreen': 0xFF32CD32, 'forestgreen': 0xFF228B22,
    'seagreen': 0xFF2E8B57, 'lightyellow': 0xFFFFFFE0, 'lightpink': 0xFFFFB6C1, 'lightgray': 0xFFD3D3D3,
    'lightgrey': 0xFFD3D3D3, 'darkgray': 0xFFA9A9A9, 'darkgrey': 0xFFA9A9A9, 'transparent': 0x00000000,
  };
  if (names.containsKey(v)) return Color(names[v]!);
  if (v.startsWith('#')) {
    var h = v.substring(1);
    if (h.length == 3) h = h.split('').map((e) => '$e$e').join();
    if (h.length == 6) {
      final n = int.tryParse(h, radix: 16);
      if (n != null) return Color(0xFF000000 | n);
    }
    if (h.length == 8) {
      final n = int.tryParse(h, radix: 16);
      if (n != null) return Color(((n & 0xFF) << 24) | (n >> 8));
    }
  }
  final m = RegExp(r'rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)').firstMatch(v);
  if (m != null) {
    final a = m.group(4) == null ? 1.0 : (double.tryParse(m.group(4)!) ?? 1.0);
    return Color.fromARGB((a.clamp(0.0, 1.0) * 255).round(), int.parse(m.group(1)!).clamp(0, 255),
        int.parse(m.group(2)!).clamp(0, 255), int.parse(m.group(3)!).clamp(0, 255));
  }
  return null;
}

class HNode {
  final String tag;
  final String text;
  final Map<String, String> attrs;
  final List<HNode> kids = [];
  HNode(this.tag, {this.text = '', Map<String, String>? attrs}) : attrs = attrs ?? {};
}

const _voidTags = {'br', 'hr', 'img', 'input', 'meta', 'link', 'source'};
const _blockTags = {
  'div', 'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'center', 'pre',
  'blockquote', 'section', 'article', 'header', 'footer', 'marquee', 'hr', 'body', 'html'
};

class _TS {
  Color color;
  double size;
  bool b, i, u, s, mono, upper;
  Color? bg;
  double? ls;
  List<Shadow> sh;
  TextAlign? align;
  _TS(this.color, this.size,
      {this.b = false,
      this.i = false,
      this.u = false,
      this.s = false,
      this.mono = false,
      this.upper = false,
      this.bg,
      this.ls,
      List<Shadow>? sh,
      this.align})
      : sh = sh ?? const [];
  _TS copy() => _TS(color, size,
      b: b, i: i, u: u, s: s, mono: mono, upper: upper, bg: bg, ls: ls, sh: sh, align: align);
  TextStyle style() => TextStyle(
        color: color,
        fontSize: size,
        fontWeight: b ? FontWeight.bold : FontWeight.normal,
        fontStyle: i ? FontStyle.italic : FontStyle.normal,
        backgroundColor: bg,
        letterSpacing: ls,
        shadows: sh.isEmpty ? null : sh,
        fontFamily: mono ? 'monospace' : null,
        decoration: TextDecoration.combine([
          if (u) TextDecoration.underline,
          if (s) TextDecoration.lineThrough,
        ]),
      );
}

Map<String, String> _parseAttrs(String a) {
  final out = <String, String>{};
  for (final m in RegExp(
          r'''([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?''')
      .allMatches(a)) {
    out[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? m.group(4) ?? '';
  }
  return out;
}

HNode _parseHtml(String src) {
  final root = HNode('#root');
  final stack = <HNode>[root];
  for (final m in RegExp(r'<[^>]*>|[^<]+').allMatches(src)) {
    final tok = m.group(0)!;
    if (!tok.startsWith('<')) {
      stack.last.kids.add(HNode('', text: tok));
      continue;
    }
    final tm = RegExp(r'^<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)([\s\S]*?)(/?)>$').firstMatch(tok);
    if (tm == null) continue;
    final closing = tm.group(1) == '/';
    final tag = tm.group(2)!.toLowerCase();
    if (closing) {
      for (var i = stack.length - 1; i > 0; i--) {
        if (stack[i].tag == tag) {
          stack.removeRange(i, stack.length);
          break;
        }
      }
      continue;
    }
    final node = HNode(tag, attrs: _parseAttrs(tm.group(3) ?? ''));
    stack.last.kids.add(node);
    final selfClose = tm.group(4) == '/' || _voidTags.contains(tag);
    if (!selfClose && stack.length < 40) stack.add(node);
  }
  return root;
}

List<String> _splitTop(String s) {
  final out = <String>[];
  var depth = 0;
  var cur = StringBuffer();
  for (final ch in s.split('')) {
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      out.add(cur.toString().trim());
      cur = StringBuffer();
    } else {
      cur.write(ch);
    }
  }
  if (cur.toString().trim().isNotEmpty) out.add(cur.toString().trim());
  return out;
}

LinearGradient? _gradient(String v) {
  final m = RegExp(r'linear-gradient\((.*)\)', caseSensitive: false, dotAll: true).firstMatch(v);
  if (m == null) return null;
  var begin = Alignment.topCenter, end = Alignment.bottomCenter;
  final colors = <Color>[];
  for (final p in _splitTop(m.group(1)!)) {
    final t = p.trim();
    final a = RegExp(r'^(-?[\d.]+)deg$').firstMatch(t);
    if (a != null) {
      final r = double.parse(a.group(1)!) * pi / 180;
      begin = Alignment(-sin(r), cos(r));
      end = Alignment(sin(r), -cos(r));
      continue;
    }
    if (t.startsWith('to ')) {
      if (t.contains('right')) {
        begin = Alignment.centerLeft;
        end = Alignment.centerRight;
      } else if (t.contains('left')) {
        begin = Alignment.centerRight;
        end = Alignment.centerLeft;
      } else if (t.contains('top')) {
        begin = Alignment.bottomCenter;
        end = Alignment.topCenter;
      }
      continue;
    }
    final tok = t.split(RegExp(r'\s+(?![^(]*\))')).first;
    final c = parseCssColor(tok);
    if (c != null) colors.add(c);
  }
  if (colors.length < 2) return null;
  return LinearGradient(begin: begin, end: end, colors: colors);
}

double? _px(String? v) {
  if (v == null) return null;
  final m = RegExp(r'(-?[\d.]+)\s*(px|pt|em|rem)?').firstMatch(v);
  if (m == null) return null;
  final n = double.tryParse(m.group(1)!);
  if (n == null) return null;
  final u = m.group(2);
  return (u == 'em' || u == 'rem') ? n * 14 : (u == 'pt' ? n * 1.33 : n);
}

EdgeInsets? _insets(String? v) {
  if (v == null) return null;
  final p = v
      .trim()
      .split(RegExp(r'\s+'))
      .map((e) => (_px(e) ?? 0).clamp(0.0, 60.0).toDouble())
      .toList();
  if (p.isEmpty) return null;
  if (p.length == 1) return EdgeInsets.all(p[0]);
  if (p.length == 2) return EdgeInsets.symmetric(vertical: p[0], horizontal: p[1]);
  if (p.length == 3) return EdgeInsets.fromLTRB(p[1], p[0], p[1], p[2]);
  return EdgeInsets.fromLTRB(p[3], p[0], p[1], p[2]);
}

List<Shadow> _shadows(String v) {
  final out = <Shadow>[];
  for (final part in _splitTop(v)) {
    final colorRe = RegExp(r'rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}|[a-zA-Z]+');
    Color? col;
    for (final m in colorRe.allMatches(part)) {
      final c = parseCssColor(m.group(0)!);
      if (c != null) {
        col = c;
        break;
      }
    }
    final rest = part.replaceAll(colorRe, ' ');
    final nums = RegExp(r'-?[\d.]+')
        .allMatches(rest)
        .map((m) => double.tryParse(m.group(0)!) ?? 0.0)
        .toList();
    if (nums.length >= 2) {
      out.add(Shadow(
          color: col ?? Colors.white,
          offset: Offset(nums[0], nums[1]),
          blurRadius: nums.length > 2 ? nums[2] : 0));
    }
  }
  return out;
}

_TS _apply(_TS p, Map<String, String> css, double base) {
  final s = p.copy();
  css.forEach((k, v0) {
    final v = v0.trim().toLowerCase();
    if (k == 'color') {
      final c = parseCssColor(v);
      if (c != null) s.color = c;
    } else if (k == 'background' || k == 'background-color') {
      final c = parseCssColor(v.split(RegExp(r'\s+(?![^(]*\))')).first);
      if (c != null) s.bg = c;
    } else if (k == 'font-size') {
      final n = _px(v);
      if (n != null) {
        if (v.contains('%')) {
          s.size = base * n / 100;
        } else if (v.contains('em')) {
          s.size = base * n / 14;
        } else {
          s.size = n;
        }
        s.size = s.size.clamp(8.0, 60.0).toDouble();
      }
    } else if (k == 'font-weight') {
      s.b = v.contains('bold') || (int.tryParse(v) ?? 0) >= 600;
    } else if (k == 'font-style') {
      s.i = v.contains('italic');
    } else if (k == 'font-family') {
      s.mono = v.contains('mono') || v.contains('courier');
    } else if (k == 'text-decoration' || k == 'text-decoration-line') {
      s.u = v.contains('underline');
      s.s = v.contains('line-through');
    } else if (k == 'text-align') {
      s.align = v.contains('center')
          ? TextAlign.center
          : (v.contains('right') ? TextAlign.right : TextAlign.left);
    } else if (k == 'letter-spacing') {
      s.ls = _px(v);
    } else if (k == 'text-transform') {
      s.upper = v.contains('uppercase');
    } else if (k == 'text-shadow') {
      s.sh = _shadows(v0);
    }
  });
  return s;
}

_TS _tagDefaults(HNode n, _TS inh, double base) {
  final s = inh.copy();
  switch (n.tag) {
    case 'b':
    case 'strong':
      s.b = true;
      break;
    case 'i':
    case 'em':
    case 'cite':
      s.i = true;
      break;
    case 'u':
    case 'ins':
      s.u = true;
      break;
    case 's':
    case 'strike':
    case 'del':
      s.s = true;
      break;
    case 'small':
      s.size = s.size * 0.85;
      break;
    case 'big':
      s.size = s.size * 1.2;
      break;
    case 'sub':
    case 'sup':
      s.size = s.size * 0.75;
      break;
    case 'code':
    case 'pre':
    case 'tt':
    case 'kbd':
      s.mono = true;
      break;
    case 'mark':
      s.bg = const Color(0xFFFFEB3B);
      s.color = Colors.black;
      break;
    case 'h1':
      s.size = base * 1.8;
      s.b = true;
      break;
    case 'h2':
      s.size = base * 1.5;
      s.b = true;
      break;
    case 'h3':
      s.size = base * 1.25;
      s.b = true;
      break;
    case 'h4':
      s.size = base * 1.1;
      s.b = true;
      break;
    case 'h5':
    case 'h6':
      s.b = true;
      break;
    case 'a':
      s.color = const Color(0xFF64B5F6);
      s.u = true;
      break;
    case 'button':
      s.b = true;
      break;
    case 'font':
      final c = n.attrs['color'];
      if (c != null) s.color = parseCssColor(c) ?? s.color;
      final sz = int.tryParse(n.attrs['size'] ?? '');
      if (sz != null) s.size = base * (0.7 + 0.15 * sz.clamp(1, 7));
      break;
  }
  return s;
}

String _plainOf(HNode n) {
  if (n.tag.isEmpty) return decodeEntities(n.text.replaceAll(RegExp(r'\s+'), ' '));
  if (n.tag == 'br') return '\n';
  return n.kids.map(_plainOf).join();
}

String? _animFromName(String name, Map<String, String> kf) {
  final n = name.toLowerCase();
  if (n.contains('blink') || n.contains('flash')) return 'blink';
  if (n.contains('pulse') || n.contains('beat') || n.contains('heart')) return 'pulse';
  if (n.contains('glow') || n.contains('neon') || n.contains('shine')) return 'glow';
  if (n.contains('rainbow') || n.contains('hue') || n.contains('color')) return 'rainbow';
  if (n.contains('shake') || n.contains('vibrate') || n.contains('wobble')) return 'shake';
  if (n.contains('bounce') || n.contains('jump')) return 'bounce';
  if (n.contains('fade')) return 'fade';
  if (n.contains('wave')) return 'wave';
  if (n.contains('typ')) return 'typewriter';
  if (n.contains('marquee') || n.contains('scroll') || n.contains('slide')) return 'marquee';
  if (n.contains('spin') || n.contains('rotate')) return 'spin';
  final body = kf[n];
  if (body != null) {
    if (body.contains('color')) return 'rainbow';
    if (body.contains('opacity')) return 'blink';
    if (body.contains('rotate')) return 'spin';
    if (body.contains('translate')) return 'bounce';
    return 'pulse';
  }
  return null;
}

class _Render {
  final Map<String, String> sheet;
  final Map<String, String> kf;
  final double base;
  final void Function(String)? onLink;
  _Render(this.sheet, this.kf, this.base, this.onLink);

  Map<String, String> css(HNode n) {
    final m = <String, String>{};
    void merge(String? s) {
      if (s == null) return;
      for (final x in RegExp(r'([a-zA-Z-]+)\s*:\s*([^;]+)').allMatches(s)) {
        m[x.group(1)!.toLowerCase()] = x.group(2)!.trim();
      }
    }

    merge(sheet[n.tag]);
    for (final c in (n.attrs['class'] ?? '').toLowerCase().split(RegExp(r'\s+'))) {
      if (c.isEmpty) continue;
      merge(sheet['.$c']);
      merge(sheet['${n.tag}.$c']);
    }
    final id = n.attrs['id'];
    if (id != null) merge(sheet['#${id.toLowerCase()}']);
    merge(n.attrs['style']);
    return m;
  }

  bool isBlock(HNode n, Map<String, String> c) =>
      _blockTags.contains(n.tag) ||
      const {'block', 'flex', 'grid', 'list-item'}.contains((c['display'] ?? '').toLowerCase());

  bool gradText(Map<String, String> c) {
    final bg = (c['background'] ?? c['background-image'] ?? '').toLowerCase();
    final clip = (c['background-clip'] ?? c['-webkit-background-clip'] ?? '').toLowerCase();
    final fill = (c['-webkit-text-fill-color'] ?? c['color'] ?? '').toLowerCase();
    return bg.contains('linear-gradient') && (clip.contains('text') || fill == 'transparent');
  }

  String? animKind(Map<String, String> c, HNode n) {
    if (n.tag == 'blink') return 'blink';
    var raw = (c['animation-name'] ?? c['animation'] ?? n.attrs['data-anim'] ?? '').toLowerCase();
    if (raw.isEmpty) {
      for (final cl in (n.attrs['class'] ?? '').split(RegExp(r'\s+'))) {
        final k = cl.isEmpty ? null : _animFromName(cl, kf);
        if (k != null && cl.length > 2) return k;
      }
      return null;
    }
    raw = raw.replaceAll(RegExp(r'[\d.]+m?s'), ' ').trim();
    for (final w in raw.split(RegExp(r'[\s,]+'))) {
      if (w.isEmpty || const {'infinite', 'linear', 'ease', 'alternate', 'forwards'}.contains(w)) continue;
      final k = _animFromName(w, kf);
      if (k != null) return k;
    }
    return 'pulse';
  }

  int dur(Map<String, String> c) {
    final raw = (c['animation-duration'] ?? c['animation'] ?? '').toLowerCase();
    final m = RegExp(r'([\d.]+)(ms|s)').firstMatch(raw);
    if (m == null) return 0;
    final n = double.tryParse(m.group(1)!) ?? 1;
    return (m.group(2) == 'ms' ? n : n * 1000).round().clamp(150, 20000);
  }

  List<InlineSpan> inlineKids(List<HNode> kids, _TS st, GestureRecognizer? rec) {
    final out = <InlineSpan>[];
    for (final k in kids) {
      if (k.tag.isEmpty) {
        var t = decodeEntities(k.text.replaceAll(RegExp(r'\s+'), ' '));
        if (t.isEmpty) continue;
        if (st.upper) t = t.toUpperCase();
        out.add(TextSpan(text: t, style: st.style(), recognizer: rec));
      } else if (k.tag == 'br') {
        out.add(const TextSpan(text: '\n'));
      } else {
        out.addAll(inlineS(k, st, rec));
      }
    }
    return out;
  }

  List<InlineSpan> inlineS(HNode n, _TS inh, GestureRecognizer? rec) {
    final c = css(n);
    if ((c['display'] ?? '') == 'none' || n.tag == 'img' || n.tag == 'input' || n.tag == 'hr') {
      return const [];
    }
    var st = _tagDefaults(n, inh, base);
    st = _apply(st, c, base);
    GestureRecognizer? r = rec;
    if (n.tag == 'a') {
      final href = (n.attrs['href'] ?? '').trim();
      final cb = onLink;
      if (href.isNotEmpty && cb != null) r = TapGestureRecognizer()..onTap = () => cb(href);
    }
    final gt = gradText(c);
    if (gt) st.color = Colors.white;
    final kids = inlineKids(n.kids, st, r);
    final anim = animKind(c, n);
    final g = gt ? _gradient(c['background'] ?? c['background-image'] ?? '') : null;
    if (g == null && (anim == null || anim == 'marquee')) return kids;
    Widget w = Text.rich(TextSpan(children: kids), textAlign: st.align);
    if (g != null) {
      w = ShaderMask(blendMode: BlendMode.srcIn, shaderCallback: (rc) => g.createShader(rc), child: w);
    }
    if (anim != null && anim != 'marquee') {
      w = AnimBox(kind: anim, plain: _plainOf(n), style: st.style(), ms: dur(c), child: w);
    }
    return [WidgetSpan(alignment: PlaceholderAlignment.middle, child: w)];
  }

  Widget flow(List<HNode> kids, _TS st, {String bullet = ''}) {
    final items = <Widget>[];
    var run = <InlineSpan>[];
    void flush() {
      if (run.isEmpty) return;
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: SizedBox(
            width: double.infinity,
            child: Text.rich(TextSpan(children: run), textAlign: st.align ?? TextAlign.start)),
      ));
      run = <InlineSpan>[];
    }

    if (bullet.isNotEmpty) run.add(TextSpan(text: bullet, style: st.style()));
    for (final k in kids) {
      if (k.tag.isEmpty) {
        var t = decodeEntities(k.text.replaceAll(RegExp(r'\s+'), ' '));
        if (run.isEmpty) t = t.trimLeft();
        if (t.isEmpty) continue;
        if (st.upper) t = t.toUpperCase();
        run.add(TextSpan(text: t, style: st.style()));
        continue;
      }
      if (k.tag == 'br') {
        run.add(const TextSpan(text: '\n'));
        continue;
      }
      final c = css(k);
      if (isBlock(k, c)) {
        flush();
        items.add(blockW(k, st));
      } else {
        run.addAll(inlineS(k, st, null));
      }
    }
    flush();
    if (items.isEmpty) return const SizedBox.shrink();
    if (items.length == 1) return items.first;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items);
  }

  Widget blockW(HNode n, _TS inh, {String bullet = ''}) {
    final c = css(n);
    if ((c['display'] ?? '') == 'none') return const SizedBox.shrink();
    if (n.tag == 'hr') return const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(color: Colors.white24));
    var st = _tagDefaults(n, inh, base);
    st = _apply(st, c, base);
    st.bg = inh.bg;
    if (n.tag == 'center') st.align = TextAlign.center;
    final al = n.attrs['align'];
    if (al != null) {
      st.align = al.contains('center')
          ? TextAlign.center
          : (al.contains('right') ? TextAlign.right : TextAlign.left);
    }
    final gt = gradText(c);
    if (gt) st.color = Colors.white;
    final bgv = c['background'] ?? c['background-image'] ?? c['background-color'];
    Color? bgColor;
    Gradient? bgGrad;
    if (bgv != null && !gt) {
      bgGrad = _gradient(bgv);
      if (bgGrad == null) bgColor = parseCssColor(bgv.split(RegExp(r'\s+(?![^(]*\))')).first);
    }
    Widget content;
    if (n.tag == 'ul' || n.tag == 'ol') {
      var idx = 0;
      content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final k in n.kids)
          if (k.tag == 'li') blockW(k, st, bullet: n.tag == 'ol' ? '${++idx}. ' : '• '),
      ]);
    } else if (n.tag == 'marquee') {
      content = Marquee(
        plain: _plainOf(n),
        child: Text.rich(TextSpan(children: inlineKids(n.kids, st, null)), maxLines: 1, softWrap: false),
      );
    } else {
      content = flow(n.kids, st, bullet: bullet);
    }
    if (gt) {
      final g = _gradient(bgv ?? '');
      if (g != null) {
        content = ShaderMask(blendMode: BlendMode.srcIn, shaderCallback: (rc) => g.createShader(rc), child: content);
      }
    }
    final anim = animKind(c, n);
    if (anim == 'marquee' && n.tag != 'marquee') {
      content = Marquee(plain: _plainOf(n), child: content);
    } else if (anim != null && anim != 'marquee') {
      content = AnimBox(kind: anim, plain: _plainOf(n), style: st.style(), ms: dur(c), child: content);
    }
    final pad = _insets(c['padding']);
    final rad = _px(c['border-radius']);
    Color? bc;
    var bw = 1.0;
    final bd = c['border'];
    if (bd != null) {
      bw = _px(bd) ?? 1.0;
      for (final t in bd.split(RegExp(r'\s+(?![^(]*\))'))) {
        final cc = parseCssColor(t);
        if (cc != null) bc = cc;
      }
    }
    Widget w = content;
    if (bgColor != null || bgGrad != null || bc != null || pad != null) {
      w = Container(
        padding: pad ?? EdgeInsets.zero,
        decoration: BoxDecoration(
          color: bgColor,
          gradient: bgGrad,
          borderRadius: rad == null ? null : BorderRadius.circular(rad),
          border: bc == null ? null : Border.all(color: bc, width: bw),
        ),
        child: content,
      );
    }
    return Padding(
      padding: _insets(c['margin']) ?? const EdgeInsets.only(bottom: 4),
      child: SizedBox(width: double.infinity, child: w),
    );
  }
}

// Animations simples (aucun code du créateur n'est exécuté : seulement des effets prévus ici).
class AnimBox extends StatefulWidget {
  final String kind;
  final Widget child;
  final String plain;
  final TextStyle style;
  final int ms;
  const AnimBox(
      {super.key,
      required this.kind,
      required this.child,
      required this.plain,
      required this.style,
      this.ms = 0});
  @override
  State<AnimBox> createState() => _AnimBoxState();
}

class _AnimBoxState extends State<AnimBox> with SingleTickerProviderStateMixin {
  late final AnimationController c;
  @override
  void initState() {
    super.initState();
    final k = widget.kind;
    final def = {
      'blink': 1000, 'pulse': 800, 'fade': 1200, 'shake': 600, 'bounce': 800, 'glow': 1400,
      'rainbow': 3000, 'wave': 1500, 'spin': 3000,
    }[k];
    final ms = widget.ms > 0 ? widget.ms : (def ?? (widget.plain.length * 110 + 600));
    c = AnimationController(vsync: this, duration: Duration(milliseconds: ms));
    if (k == 'pulse' || k == 'fade' || k == 'glow') {
      c.repeat(reverse: true);
    } else {
      c.repeat();
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.style;
    return AnimatedBuilder(
      animation: c,
      child: widget.child,
      builder: (_, child) {
        final t = c.value;
        switch (widget.kind) {
          case 'blink':
            return Opacity(opacity: t < 0.5 ? 1 : 0.08, child: child);
          case 'pulse':
            return Transform.scale(scale: 1 + 0.12 * t, child: child);
          case 'fade':
            return Opacity(opacity: 0.2 + 0.8 * t, child: child);
          case 'shake':
            return Transform.translate(offset: Offset(sin(t * 2 * pi * 4) * 3, 0), child: child);
          case 'bounce':
            return Transform.translate(offset: Offset(0, -8 * sin(t * pi).abs()), child: child);
          case 'spin':
            return Transform.rotate(angle: t * 2 * pi, child: child);
          case 'glow':
            final col = (st.color ?? Colors.white);
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(color: col.withValues(alpha: 0.25 + 0.45 * t), blurRadius: 10 + 18 * t)],
              ),
              child: child,
            );
          case 'rainbow':
            final chars = widget.plain.split('');
            return Text.rich(TextSpan(children: [
              for (var i = 0; i < chars.length; i++)
                TextSpan(
                    text: chars[i],
                    style: st.copyWith(
                        color: HSVColor.fromAHSV(1, (t * 360 + i * 22) % 360, 0.85, 1).toColor())),
            ]));
          case 'wave':
            final chars = widget.plain.split('');
            return Text.rich(TextSpan(children: [
              for (var i = 0; i < chars.length; i++)
                WidgetSpan(
                    child: Transform.translate(
                        offset: Offset(0, 5 * sin(t * 2 * pi + i * 0.6)),
                        child: Text(chars[i], style: st))),
            ]));
          case 'typewriter':
            final n = (t * (widget.plain.length + 4)).floor().clamp(0, widget.plain.length);
            return Text(widget.plain.substring(0, n), style: st);
          default:
            return child ?? const SizedBox.shrink();
        }
      },
    );
  }
}

class Marquee extends StatefulWidget {
  final Widget child;
  final String plain;
  const Marquee({super.key, required this.child, required this.plain});
  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController c;
  @override
  void initState() {
    super.initState();
    c = AnimationController(vsync: this, duration: Duration(milliseconds: 6000 + widget.plain.length * 90))
      ..repeat();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
        child: LayoutBuilder(builder: (ctx, bc) {
          final w = bc.maxWidth.isFinite ? bc.maxWidth : 300.0;
          final tw = widget.plain.length * 9.0;
          return SizedBox(
            height: 26,
            child: AnimatedBuilder(
              animation: c,
              child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: double.infinity,
                  child: widget.child),
              builder: (_, child) =>
                  Transform.translate(offset: Offset(w - c.value * (w + tw), 0), child: child),
            ),
          );
        }),
      );
}

Widget _plainMsg(String t, double base, void Function(String)? onLink) {
  final txt = decodeEntities(t);
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in RegExp(r'(https?://[^\s<]+|\bt\.me/[^\s<]+)').allMatches(txt)) {
    if (m.start > last) spans.add(TextSpan(text: txt.substring(last, m.start)));
    final u = m.group(0)!;
    final url = u.startsWith('http') ? u : 'https://$u';
    final cb = onLink;
    spans.add(TextSpan(
      text: u,
      style: const TextStyle(color: Color(0xFF64B5F6), decoration: TextDecoration.underline),
      recognizer: cb == null ? null : (TapGestureRecognizer()..onTap = () => cb(url)),
    ));
    last = m.end;
  }
  if (last < txt.length) spans.add(TextSpan(text: txt.substring(last)));
  return Text.rich(TextSpan(style: TextStyle(color: Colors.white, fontSize: base), children: spans));
}

// Affiche un message : texte simple ou HTML/CSS limité (couleurs, dégradés, animations, liens).
Widget richMessage(String input, {double base = 14, void Function(String)? onLink}) {
  final src = input.length > 8000 ? input.substring(0, 8000) : input;
  var cleaned = src.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  final sheet = <String, String>{};
  final kf = <String, String>{};
  for (final m
      in RegExp(r'<style[^>]*>([\s\S]*?)</style\s*>', caseSensitive: false).allMatches(cleaned)) {
    var css = m.group(1)!;
    for (final k in RegExp(r'@keyframes\s+([\w-]+)\s*\{((?:[^{}]*\{[^{}]*\})*)\s*\}').allMatches(css)) {
      kf[k.group(1)!.toLowerCase()] = k.group(2)!.toLowerCase();
    }
    css = css.replaceAll(RegExp(r'@keyframes\s+[\w-]+\s*\{(?:[^{}]*\{[^{}]*\})*\s*\}'), '');
    for (final r in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(css)) {
      for (final sel in r.group(1)!.split(',')) {
        final s = sel.trim().toLowerCase();
        if (s.isEmpty || s.contains(' ') || s.contains(':') || s.contains('>') || s.startsWith('@')) continue;
        sheet[s] = '${sheet[s] ?? ''};${r.group(2)}';
      }
    }
  }
  cleaned = cleaned.replaceAll(
      RegExp(r'<(script|style|iframe|object|embed)[\s\S]*?</\1\s*>', caseSensitive: false), '');
  if (!RegExp(r'<[a-zA-Z/]').hasMatch(cleaned)) return _plainMsg(cleaned, base, onLink);
  try {
    final root = _parseHtml(cleaned);
    return _Render(sheet, kf, base, onLink).flow(root.kids, _TS(Colors.white, base));
  } catch (_) {
    return Text(decodeEntities(cleaned.replaceAll(RegExp(r'<[^>]*>'), '')),
        style: TextStyle(color: Colors.white, fontSize: base));
  }
}

// ---------- Tunnels DNS (SlowDNS / DNSTT) ----------
const kDnsPort = 10811;
const kResolvers = [
  '8.8.8.8:53', '8.8.4.4:53', '1.1.1.1:53', '1.0.0.1:53', '9.9.9.9:53',
  '208.67.222.222:53', '94.140.14.14:53', '223.5.5.5:53', '185.228.168.9:53', '76.76.2.0:53',
];

Uint8List dnsQuery(String name, int id) {
  final b = BytesBuilder();
  b.add([id >> 8, id & 255, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final label in name.split('.')) {
    if (label.isEmpty) continue;
    final lb = utf8.encode(label);
    b.addByte(lb.length);
    b.add(lb);
  }
  b.add([0, 0, 16, 0, 1]);
  return b.toBytes();
}

// Temps de réponse (ms) d'un résolveur DNS en UDP, ou -1.
Future<int> dnsProbe(String server, String domain) async {
  final parts = server.trim().split(':');
  final host = parts[0];
  final port = parts.length > 1 ? (int.tryParse(parts[1]) ?? 53) : 53;
  RawDatagramSocket? s;
  try {
    final addr = InternetAddress.tryParse(host);
    if (addr == null) return -1;
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final comp = Completer<int>();
    final sw = Stopwatch()..start();
    s.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = s!.receive();
        if (d != null && !comp.isCompleted) comp.complete(sw.elapsedMilliseconds);
      }
    });
    final rnd = Random();
    s.send(dnsQuery('${rnd.nextInt(99999)}.$domain', rnd.nextInt(65535)), addr, port);
    return await comp.future.timeout(const Duration(seconds: 3));
  } catch (_) {
    return -1;
  } finally {
    s?.close();
  }
}

String dnsXrayJson(Map<String, String> f) {
  final viaSsh = (f['smethod'] ?? 'ssh') == 'ssh';
  final server = <String, dynamic>{'address': '127.0.0.1', 'port': viaSsh ? kSshPort : kDnsPort};
  final su = f['suser'] ?? '';
  if (!viaSsh && su.isNotEmpty) {
    server['users'] = [
      {'user': su, 'pass': f['spass'] ?? ''}
    ];
  }
  return jsonEncode(xrayBase({
    'tag': 'proxy',
    'protocol': 'socks',
    'settings': {
      'servers': [server]
    }
  }, tcpOnly: true));
}

List<String> dnsArgs(Map<String, String> f, String keyFile) {
  final tr = f['transport'] ?? 'udp';
  final rs = (f['resolver'] ?? '8.8.8.8:53').trim();
  final a = <String>[];
  if (tr == 'doh') {
    a.addAll(['-doh', rs.startsWith('http') ? rs : 'https://$rs/dns-query']);
  } else if (tr == 'dot') {
    a.addAll(['-dot', rs.contains(':') ? rs : '$rs:853']);
  } else {
    a.addAll(['-udp', rs.contains(':') ? rs : '$rs:53']);
  }
  a.addAll(['-pubkey-file', keyFile, (f['domain'] ?? '').trim(), '127.0.0.1:$kDnsPort']);
  return a;
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
  final ValueNotifier<int> logTick = ValueNotifier<int>(0);
  Timer? _ipTimer;
  IpInfo? ipNow, ipDirect;
  bool ipLoading = false, trafficOk = false;
  List<int> stepSt = List<int>.filled(5, 0);
  final List<double> hist = [];
  final Map<String, int> usage = {};
  List<Map<String, dynamic>> subs = [];
  int dlSpeed = 0, upSpeed = 0, dlTotal = 0, upTotal = 0, lastTot = 0, tick = 0;
  String duration = '00:00:00';
  bool wantOn = false, searching = false, testing = false;
  double? speedMbps;
  String speedInfo = '';
  int retries = 0;
  bool turbo = false, autoReco = true, autoBest = false, proxyOnly = false;
  bool autoConnect = false, mangekyoColor = true;
  String dns = 'auto';
  String excluded = '';
  String skinId = 'classic';
  List<Skin> skins = [];
  Map<String, String> skinNames = {};
  bool hotspot = false;
  SshTunnel? sshT;
  Process? dnsProc;
  bool sshBusy = false;
  bool preResolve = true, autoHost = true;
  bool insecureDefault = true;

  bool get connected => state == 'CONNECTED';
  bool get busy => state == 'CONNECTING' || searching || sshBusy;
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
        duration = s.duration;
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
    kChan.setMethodCallHandler((call) async {
      if (call.method == 'onIntent') _incoming('${call.arguments}');
      return null;
    });
    _ipTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (mounted && tab == 2 && !ipLoading) refreshIp();
    });
    _load();
  }

  void log(String m) {
    logs.add('${DateTime.now().toIso8601String().substring(11, 19)}  $m');
    if (logs.length > 400) logs.removeRange(0, logs.length - 400);
    logTick.value++;
  }

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
    if (now == 'CONNECTING') setStep(2, 1);
    if (now == 'CONNECTED') {
      retries = 0;
      setStep(2, 2);
      _afterConnected();
      Future.delayed(const Duration(seconds: 12), () {
        if (mounted && connected && dlTotal + upTotal == 0) {
          snack('Connecté mais aucun trafic détecté. Touche Diagnostic complet.');
        }
      });
    }
    if (now == 'DISCONNECTED') {
      trafficOk = false;
      if (stepSt[2] != 3) {
        stepSt = List<int>.filled(kSteps.length, 0);
        logTick.value++;
      }
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !connected) refreshIp(force: true);
      });
      _stopSsh();
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
      skinId = p.getString('skinId') ?? 'classic';
      hotspot = p.getBool('hotspot') ?? false;
      preResolve = p.getBool('preResolve') ?? true;
      autoHost = p.getBool('autoHost') ?? true;
      insecureDefault = p.getBool('insecureDefault') ?? true;
    });
    await _loadSkins(p);
    refreshIp();
    try {
      final t = await kChan.invokeMethod<String>('getInitial');
      if (t != null && t.isNotEmpty) await _incoming(t);
    } catch (_) {}
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
    await p.setString('skinId', skinId);
    await p.setBool('hotspot', hotspot);
    await p.setBool('preResolve', preResolve);
    await p.setBool('autoHost', autoHost);
    await p.setBool('insecureDefault', insecureDefault);
  }

  void snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // ----- Outils -----
  String proto(String link) {
    final l = link.toLowerCase();
    if (l.startsWith('xrayjson')) return 'JSON';
    if (l.startsWith('vless')) return 'VLESS';
    if (l.startsWith('vmess')) return 'VMess';
    if (l.startsWith('trojan')) return 'Trojan';
    if (l.startsWith('dns')) return 'DNS';
    if (l.startsWith('ssh')) return 'SSH';
    if (l.startsWith('ss')) return 'Shadowsocks';
    return '?';
  }

  Parsed? parse(String link) {
    try {
      if (link.startsWith('xrayjson://')) {
        final raw = utf8.decode(b64dec(link.substring(11)));
        final j = jsonDecode(raw) as Map<String, dynamic>;
        var addr = '';
        final outs = j['outbounds'];
        if (outs is List && outs.isNotEmpty && outs[0] is Map) {
          final st = (outs[0] as Map)['settings'];
          if (st is Map) {
            final vn = st['vnext'];
            final sv = st['servers'];
            if (vn is List && vn.isNotEmpty && vn[0] is Map) {
              addr = '${(vn[0] as Map)['address']}';
            } else if (sv is List && sv.isNotEmpty && sv[0] is Map) {
              addr = '${(sv[0] as Map)['address']}';
            }
          }
        }
        return Parsed('${j['remarks'] ?? j['remark'] ?? 'Config JSON'}', addr, () => raw);
      }
      if (link.startsWith('dns://')) {
        final f = parseLink(link);
        if (f == null || (f['domain'] ?? '').isEmpty) return null;
        final nm = (f['remark'] ?? '').isEmpty ? f['domain']! : f['remark']!;
        return Parsed(nm, f['domain']!, () => dnsXrayJson(f));
      }
      if (link.startsWith('ssh://')) {
        final f = parseLink(link);
        if (f == null || (f['add'] ?? '').isEmpty) return null;
        final nm = (f['remark'] ?? '').isEmpty ? f['add']! : f['remark']!;
        return Parsed(nm, f['add']!, () => sshXrayJson());
      }
      final v = FlutterV2ray.parseFromURL(link);
      return Parsed(v.remark, v.address, () => v.getFullConfiguration());
    } catch (_) {
      return null;
    }
  }

  // Construit la config du moteur : types corrigés, serveur résolu avec le DNS du
  // téléphone, header host rempli, allowInsecure, Turbo, DNS et hotspot.
  Future<String> buildConfig(Parsed p, String link) async {
    final raw = p.full();
    if (link.startsWith('xrayjson://') || link.startsWith('ssh://') || link.startsWith('dns://')) return raw;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final lf = parseLink(link) ?? <String, String>{};
      final outs = m['outbounds'];
      if (outs is List && outs.isNotEmpty && outs[0] is Map) {
        final o = outs[0] as Map;
        final ss = o['streamSettings'];
        final insRaw = lf['ins'] ?? '';
        final insecure =
            insRaw.isEmpty ? insecureDefault : (insRaw == '1' || insRaw.toLowerCase() == 'true');
        if (ss is Map && ss['tlsSettings'] is Map) {
          (ss['tlsSettings'] as Map)['allowInsecure'] = insecure;
        }
        final st = o['settings'];
        Map? target;
        if (st is Map) {
          final vn = st['vnext'];
          final sv = st['servers'];
          if (vn is List && vn.isNotEmpty && vn[0] is Map) {
            target = vn[0] as Map;
          } else if (sv is List && sv.isNotEmpty && sv[0] is Map) {
            target = sv[0] as Map;
          }
        }
        if (target != null) {
          final pt = target['port'];
          if (pt is String) target['port'] = int.tryParse(pt) ?? 443;
          final us = target['users'];
          if (us is List && us.isNotEmpty && us[0] is Map) {
            final u = us[0] as Map;
            final a = u['alterId'];
            if (a is String) u['alterId'] = int.tryParse(a) ?? 0;
          }
          final addr = '${target['address']}';
          if (InternetAddress.tryParse(addr) == null) {
            if ((autoHost || preResolve) && ss is Map) {
              final ws = ss['wsSettings'];
              if (ws is Map) {
                final h = ws['headers'];
                if (h is Map) {
                  if ('${h['Host'] ?? ''}'.isEmpty) h['Host'] = addr;
                } else {
                  ws['headers'] = {'Host': addr};
                }
              }
              final tl = ss['tlsSettings'];
              if (tl is Map && '${tl['serverName'] ?? ''}'.isEmpty) tl['serverName'] = addr;
            }
            if (preResolve) {
              try {
                final r = await InternetAddress.lookup(addr, type: InternetAddressType.IPv4)
                    .timeout(const Duration(seconds: 5));
                if (r.isNotEmpty) {
                  target['address'] = r.first.address;
                  log('Serveur résolu : $addr -> ${r.first.address}');
                }
              } catch (_) {
                log('Résolution impossible : $addr');
              }
            }
          }
        }
        if (turbo) o['mux'] = {'enabled': true, 'concurrency': 8};
      }
      if (dns != 'auto') {
        final servers = dns == 'cloudflare'
            ? ['1.1.1.1', '1.0.0.1']
            : dns == 'google'
                ? ['8.8.8.8', '8.8.4.4']
                : ['94.140.14.14', '94.140.15.15'];
        m['dns'] = {'servers': servers};
      }
      if (hotspot) {
        final ins = m['inbounds'];
        if (ins is List) {
          for (final i in ins) {
            if (i is Map && (i['protocol'] == 'http' || i['protocol'] == 'socks')) {
              i['listen'] = '0.0.0.0';
            }
          }
        }
      }
      return jsonEncode(m);
    } catch (_) {
      return raw;
    }
  }

  Future<int> _delay(int i) async {
    if (configs[i].link.startsWith('dns://')) return _dnsProbeCfg(configs[i].link);
    if (configs[i].link.startsWith('ssh://')) return _sshProbe(configs[i].link);
    final p = parse(configs[i].link);
    if (p == null) return -1;
    try {
      final cfgJson = await buildConfig(p, configs[i].link);
      return await v2ray
          .getServerDelay(config: cfgJson)
          .timeout(const Duration(seconds: 8));
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
    _resetSteps();
    log('--- Connexion : ${c.name} (${proto(c.link)}) ---');
    if (c.expired) return snack('Cette config est expirée');
    if (c.overLimit) return snack('Limite de données atteinte pour cette config');
    final p = parse(c.link);
    if (p == null) {
      setStep(0, 3);
      return snack('Config invalide');
    }
    setStep(0, 2);
    log('Config lue : ${p.address}');
    final isTun = c.link.startsWith('ssh://') || c.link.startsWith('dns://');
    setStep(1, isTun ? 1 : 4);
    if (isTun) {
      final ok = c.link.startsWith('dns://') ? await _startDns(c) : await _startSsh(c);
      setStep(1, ok ? 2 : 3);
      if (!ok) return;
      if (!wantOn) {
        await _stopSsh();
        return;
      }
    }
    setStep(2, 1);
    log('Demande d\'autorisation VPN');
    if (await v2ray.requestPermission()) {
      final cfgJson = await buildConfig(p, c.link);
      final apps = excludedApps;
      v2ray.startV2Ray(
        remark: c.name,
        config: cfgJson,
        proxyOnly: proxyOnly,
        bypassSubnets: null,
        blockedApps: apps.isEmpty ? null : apps,
      );
    }
  }

  String _short(Object e) {
    final t = e.toString().replaceAll('Exception: ', '').replaceAll('\n', ' ');
    return t.length > 110 ? t.substring(0, 110) : t;
  }

  Future<bool> _startSsh(Cfg c) async {
    final f = parseLink(c.link);
    if (f == null) {
      snack('Config SSH illisible');
      return false;
    }
    setState(() => sshBusy = true);
    SshTunnel? t;
    try {
      await _stopSsh();
      t = SshTunnel();
      t.onClosed = () {
        if (!mounted) return;
        log('SSH : connexion fermée');
        if (connected || busy) v2ray.stopV2Ray();
      };
      await t.start(f, log).timeout(const Duration(seconds: 45));
      sshT = t;
      return true;
    } catch (e) {
      log('SSH : échec : $e');
      snack('SSH impossible : ${_short(e)}');
      try {
        await t?.stop();
      } catch (_) {}
      wantOn = false;
      return false;
    } finally {
      if (mounted) setState(() => sshBusy = false);
    }
  }

  Future<void> _stopSsh() async {
    final t = sshT;
    sshT = null;
    final p = dnsProc;
    dnsProc = null;
    try {
      p?.kill();
    } catch (_) {}
    if (t != null) await t.stop();
  }

  Future<void> toggle() async {
    if (connected || busy) {
      wantOn = false;
      v2ray.stopV2Ray();
      await _stopSsh();
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

  Future<SpeedRes> _download(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
    try {
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 7));
      final res = await req.close().timeout(const Duration(seconds: 7));
      if (res.statusCode != 200) return SpeedRes(-1, 0, 0, 'HTTP ${res.statusCode}');
      final ttfb = sw.elapsedMilliseconds;
      final dl = Stopwatch()..start();
      var n = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 6))) {
          n += chunk.length;
          if (dl.elapsed.inSeconds >= 8) break;
        }
      } catch (_) {}
      final secs = max(dl.elapsedMilliseconds / 1000, 0.001);
      if (n < 30000) return SpeedRes(-1, n, ttfb, 'trop peu de données reçues');
      return SpeedRes(n * 8 / 1000000 / secs, n, ttfb, '');
    } catch (e) {
      return SpeedRes(-1, 0, 0, e.runtimeType.toString());
    } finally {
      client.close(force: true);
    }
  }

  Future<void> speedTest() async {
    if (testing) return;
    setState(() {
      testing = true;
      speedMbps = null;
      speedInfo = '';
    });
    const urls = [
      'https://speed.cloudflare.com/__down?bytes=25000000',
      'https://proof.ovh.net/files/10Mb.dat',
      'http://speedtest.tele2.net/10MB.zip',
      'https://cachefly.cachefly.net/10mb.test',
    ];
    var res = SpeedRes(-1, 0, 0, '');
    var host = '';
    final errs = <String>[];
    for (final u in urls) {
      final r = await _download(u);
      if (r.mbps > 0) {
        res = r;
        host = Uri.parse(u).host;
        break;
      }
      errs.add('${Uri.parse(u).host} : ${r.error}');
    }
    if (!mounted) return;
    setState(() {
      testing = false;
      speedMbps = res.mbps;
      speedInfo = res.mbps > 0
          ? '$host • ${fmtBytes(res.bytes)} reçus • latence ${res.ttfb} ms • '
              '${(res.mbps / 8).toStringAsFixed(2)} Mo/s${connected ? ' • via VPN' : ' • connexion directe'}'
          : errs.join('\n');
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
    final tt = text.trim();
    if (tt.contains('[Interface]') && tt.contains('[Peer]')) {
      final w = wgToXray(tt);
      if (w != null) {
        return [
          Cfg('${w['remarks']}', 'xrayjson://${base64Encode(utf8.encode(jsonEncode(w)))}', hide)
        ];
      }
    }
    if (tt.startsWith('{')) {
      try {
        final j = jsonDecode(tt);
        if (j is Map && j['outbounds'] is List) {
          final nm = '${j['remarks'] ?? j['remark'] ?? 'Config JSON'}';
          return [Cfg(nm, 'xrayjson://${base64Encode(utf8.encode(jsonEncode(j)))}', hide)];
        }
      } catch (_) {}
    }
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
    for (final c in l) {
      if (c.msg.trim().isNotEmpty) {
        showMsgDialog('Message du créateur', c.msg);
        break;
      }
    }
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
    if (clip.contains('://') || clip.startsWith('OTAKU') || clip.trim().startsWith('{') || clip.contains('[Interface]')) {
      c.text = clip.trim();
    }
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
              if (ex.isNotEmpty && !validDate(ex)) {
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

  // Petit client SOCKS5 : demande une page au moteur par son entrée locale.
  Future<String> _socksGet(int port) async {
    final sw = Stopwatch()..start();
    Socket? s;
    try {
      s = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 6));
      final buf = <int>[];
      s.listen((d) => buf.addAll(d), onError: (_) {}, cancelOnError: true);
      Future<bool> wait(int n) async {
        for (var k = 0; k < 160 && buf.length < n; k++) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
        return buf.length >= n;
      }

      s.add([5, 1, 0]);
      if (!await wait(2) || buf[0] != 5 || buf[1] != 0) {
        return 'SOCKS 127.0.0.1:$port -> poignée de main refusée';
      }
      const host = 'connectivitycheck.gstatic.com';
      final hb = utf8.encode(host);
      s.add([5, 1, 0, 3, hb.length, ...hb, 0, 80]);
      if (!await wait(4)) return 'SOCKS 127.0.0.1:$port -> pas de réponse du moteur';
      if (buf[1] != 0) {
        return 'SOCKS 127.0.0.1:$port -> le moteur refuse la connexion (code ${buf[1]})';
      }
      final atyp = buf[3];
      final rl = atyp == 1 ? 10 : (atyp == 4 ? 22 : 7 + (buf.length > 4 ? buf[4] : 0));
      if (!await wait(rl)) return 'SOCKS 127.0.0.1:$port -> réponse incomplète';
      s.add(utf8.encode('GET /generate_204 HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n'));
      if (!await wait(rl + 12)) {
        return 'SOCKS 127.0.0.1:$port -> aucune réponse HTTP (délai dépassé)';
      }
      final end = min(buf.length, rl + 40);
      final line =
          utf8.decode(buf.sublist(rl, end), allowMalformed: true).split('\r\n').first;
      return 'SOCKS 127.0.0.1:$port -> ${line.replaceFirst('HTTP/1.1 ', '')} '
          '(${sw.elapsedMilliseconds} ms)';
    } catch (e) {
      return 'SOCKS 127.0.0.1:$port -> ECHEC ${e.runtimeType}';
    } finally {
      s?.destroy();
    }
  }

  // État du tunnel Android : le programme tun2socks est-il présent et en marche ?
  Future<String> _nativeReport() async {
    String r;
    try {
      r = await kChan.invokeMethod<String>('nativeInfo') ?? 'indisponible';
    } catch (_) {
      return '\n--- Tunnel Android ---\nindisponible (canal natif absent)\n';
    }
    final b = StringBuffer('\n--- Tunnel Android ---\n$r');
    if (r.contains('ABSENT') || r.contains('AUCUN')) {
      b.writeln('=> CAUSE TROUVÉE : le programme du tunnel (tun2socks) est introuvable.');
      b.writeln('   Le VPN s\'allume mais ne peut rien transporter.');
    } else if (r.contains('non trouvé')) {
      b.writeln('=> Le programme existe mais ne tourne pas.');
      b.writeln('   Connecte-toi d\'abord, puis relance ce diagnostic.');
    } else if (r.contains('EN MARCHE')) {
      b.writeln('=> Le tunnel tourne. Si rien ne passe, le blocage est ailleurs (DNS, UDP).');
    }
    return b.toString();
  }

  Future<void> tunnelInfo() async {
    final t = await _nativeReport();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tunnel Android'),
        content: SingleChildScrollView(child: SelectableText(t.trim())),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: t.trim()));
              snack('Copié');
            },
            child: const Text('Copier'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<String> _coreReport(Cfg c) async {
    final p = parse(c.link);
    final b = StringBuffer('\n--- Test du moteur (proxy local) ---\n');
    if (p == null) {
      b.writeln('Config illisible.');
      return b.toString();
    }
    final cfgJson = await buildConfig(p, c.link);
    var port = 10809;
    var hasHttp = false;
    var socks = 10808;
    try {
      final m = jsonDecode(cfgJson) as Map<String, dynamic>;
      for (final i in (m['inbounds'] as List)) {
        if (i is Map && i['protocol'] == 'http') {
          port = toInt(i['port']);
          hasHttp = true;
        } else if (i is Map && i['protocol'] == 'socks') {
          socks = toInt(i['port']);
        }
      }
    } catch (_) {}
    final wasOn = connected;
    if (!wasOn) {
      wantOn = false;
      v2ray.startV2Ray(
        remark: c.name,
        config: cfgJson,
        proxyOnly: true,
        bypassSubnets: null,
        blockedApps: null,
      );
      for (var k = 0; k < 20 && !connected; k++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!connected) {
      b.writeln('Le moteur ne démarre pas : config refusée.');
    } else {
      var ok = false;
      if (!hasHttp) {
        final r = await _socksGet(socks);
        b.writeln(r);
        ok = r.contains('-> 204') || r.contains('-> 200');
      }
      if (hasHttp) for (final url in [
        'http://connectivitycheck.gstatic.com/generate_204',
        'http://www.msftconnecttest.com/connecttest.txt'
      ]) {
        final cl = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        cl.findProxy = (u) => 'PROXY 127.0.0.1:$port';
        final sw = Stopwatch()..start();
        try {
          final req = await cl.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 10));
          final res = await req.close().timeout(const Duration(seconds: 10));
          await res.drain<void>();
          b.writeln('$url -> ${res.statusCode} (${sw.elapsedMilliseconds} ms)');
          if (res.statusCode == 204 || res.statusCode == 200) ok = true;
        } catch (e) {
          b.writeln('$url -> ECHEC ${e.runtimeType}');
        } finally {
          cl.close(force: true);
        }
      }
      b.writeln(ok
          ? '=> Le moteur et le serveur laissent passer le trafic.\n'
              '   Si Android n\'envoie rien, le blocage vient du tunnel VPN du système.'
          : '=> Le moteur ne passe pas par le serveur : Host, Path, port, SNI ou serveur à revoir.');
    }
    if (!wasOn) v2ray.stopV2Ray();
    return b.toString();
  }

  Future<void> openLink(String url) async {
    final u = url.trim();
    if (!RegExp(r'^(https?://|tg://)', caseSensitive: false).hasMatch(u)) {
      return snack('Lien non autorisé');
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ouvrir ce lien ?'),
        content: SelectableText(u),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Ouvrir'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    } catch (_) {
      snack('Impossible d\'ouvrir le lien');
    }
  }

  Future<bool> _startDns(Cfg c) async {
    final f = parseLink(c.link);
    if (f == null) {
      snack('Config DNS illisible');
      return false;
    }
    setState(() => sshBusy = true);
    SshTunnel? t;
    try {
      await _stopSsh();
      var dir = '';
      try {
        dir = await kChan.invokeMethod<String>('nativeDir') ?? '';
      } catch (_) {}
      final bin = '$dir/libdnstt.so';
      if (dir.isEmpty || !File(bin).existsSync()) {
        throw 'le moteur DNS (dnstt) est absent de cet APK';
      }
      final tmp = await getTemporaryDirectory();
      final kf = File('${tmp.path}/dnstt.pub');
      await kf.writeAsString('${(f['pubkey'] ?? '').trim()}\n');
      log('dnstt : lancement (${f['transport']} ${f['resolver']})');
      final p = await Process.start(bin, dnsArgs(f, kf.path),
          environment: {'SSL_CERT_DIR': '/system/etc/security/cacerts'});
      dnsProc = p;
      p.stderr.transform(utf8.decoder).listen((s) {
        for (final l in s.split('\n')) {
          if (l.trim().isNotEmpty) log('dnstt : ${l.trim()}');
        }
      });
      p.stdout.transform(utf8.decoder).listen((_) {});
      p.exitCode.then((code) {
        if (dnsProc == p) {
          log('dnstt : arrêté (code $code)');
          if (connected || busy) v2ray.stopV2Ray();
        }
      });
      var ready = false;
      for (var k = 0; k < 40; k++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          final s = await Socket.connect('127.0.0.1', kDnsPort, timeout: const Duration(seconds: 1));
          s.destroy();
          ready = true;
          break;
        } catch (_) {}
      }
      if (!ready) throw 'le tunnel DNS ne démarre pas (clé, domaine ou résolveur à revoir)';
      log('dnstt : port local prêt');
      if ((f['smethod'] ?? 'ssh') == 'ssh') {
        final sf = <String, String>{
          'add': '127.0.0.1',
          'port': '$kDnsPort',
          'user': f['user'] ?? '',
          'id': f['id'] ?? '',
          'mode': 'direct',
        };
        t = SshTunnel();
        t.onClosed = () {
          if (!mounted) return;
          log('SSH : connexion fermée');
          if (connected || busy) v2ray.stopV2Ray();
        };
        await t.start(sf, log, authSecs: 90).timeout(const Duration(seconds: 120));
        sshT = t;
      }
      return true;
    } catch (e) {
      log('DNS : échec : $e');
      snack('Tunnel DNS impossible : ${_short(e)}');
      try {
        await t?.stop();
      } catch (_) {}
      await _stopSsh();
      wantOn = false;
      return false;
    } finally {
      if (mounted) setState(() => sshBusy = false);
    }
  }

  Future<int> _dnsProbeCfg(String link) async {
    final f = parseLink(link);
    if (f == null) return -1;
    final rs = f['resolver'] ?? '';
    if (rs.startsWith('http') || (f['transport'] ?? 'udp') != 'udp') return -1;
    return dnsProbe(rs, f['domain'] ?? '');
  }

  Future<String> _dnsReport(Cfg c) async {
    final f = parseLink(c.link);
    if (f == null) return 'Config DNS illisible.';
    final b = StringBuffer();
    b.writeln('Protocole : tunnel DNS (dnstt / SlowDNS)');
    b.writeln('Domaine : ${f['domain']}');
    b.writeln('Résolveur : ${f['resolver']} (${f['transport']})   Méthode : ${f['smethod']}');
    final key = f['pubkey'] ?? '';
    b.writeln('Clé publique : ${RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key) ? 'format OK' : 'FORMAT INVALIDE'}');
    var dir = '';
    try {
      dir = await kChan.invokeMethod<String>('nativeDir') ?? '';
    } catch (_) {}
    final has = dir.isNotEmpty && File('$dir/libdnstt.so').existsSync();
    b.writeln('Moteur dnstt : ${has ? 'présent' : 'ABSENT de cet APK'}');
    if ((f['transport'] ?? 'udp') == 'udp' && !(f['resolver'] ?? '').startsWith('http')) {
      final ms = await dnsProbe(f['resolver'] ?? '', f['domain'] ?? '');
      b.writeln('Résolveur : ${ms >= 0 ? 'répond en $ms ms' : 'ne répond pas'}');
    }
    b.writeln('');
    b.writeln(has
        ? '=> Prêt. Connecte-toi : le journal affichera les lignes « dnstt : ... ».'
        : '=> Le moteur DNS n\'est pas dans l\'APK : relance la fabrication sur GitHub (version 6.3).');
    return b.toString();
  }

  Future<int> _sshProbe(String link) async {
    final f = parseLink(link);
    if (f == null) return -1;
    final sw = Stopwatch()..start();
    try {
      final r = await openRemote(f, log);
      final first = await r.stream.first.timeout(const Duration(seconds: 8));
      r.socket.destroy();
      return utf8.decode(first, allowMalformed: true).startsWith('SSH-')
          ? sw.elapsedMilliseconds
          : -1;
    } catch (_) {
      return -1;
    }
  }

  Future<String> _sshReport(Cfg c) async {
    final f = parseLink(c.link);
    if (f == null) return 'Config SSH illisible.';
    final mode = f['mode'] ?? 'direct';
    final b = StringBuffer();
    b.writeln('Protocole : SSH   Mode : $mode');
    b.writeln('Cible : ${f['add']}:${f['port']}   Utilisateur : ${f['user']}');
    if (mode.contains('ssl')) {
      b.writeln('SNI : ${(f['sni'] ?? '').isEmpty ? f['add'] : f['sni']}');
    }
    if ((f['rproxy'] ?? '').isNotEmpty) b.writeln('Proxy distant : ${f['rproxy']}');
    b.writeln('');
    final sw = Stopwatch()..start();
    try {
      final r = await openRemote(f, log);
      b.writeln('1. Connexion : OK (${sw.elapsedMilliseconds} ms)');
      try {
        final first = await r.stream.first.timeout(const Duration(seconds: 8));
        final line = utf8.decode(first, allowMalformed: true).split('\n').first.trim();
        b.writeln('2. Bannière : $line');
        b.writeln(line.startsWith('SSH-')
            ? '=> Le serveur SSH répond. Si la connexion échoue ensuite, vérifie l\'utilisateur et le mot de passe.'
            : '=> Le serveur répond mais ce n\'est pas du SSH : payload ou port à revoir.');
      } catch (_) {
        b.writeln('2. Bannière : aucune réponse en 8 s');
      }
      r.socket.destroy();
    } catch (e) {
      b.writeln('1. Connexion : ECHEC (${_short(e)})');
    }
    return b.toString();
  }

  Future<String> _diagReport(Cfg c, int i) async {
    final f = parseLink(c.link);
    if (f == null) return 'Lien non lisible.';
    final b = StringBuffer();
    final add = f['add'] ?? '';
    final port = int.tryParse(f['port'] ?? '') ?? 443;
    final net = f['net'] ?? 'tcp';
    final tls = (f['tls'] ?? '') == 'tls';
    final host = f['host'] ?? '';
    final path = (f['path'] ?? '').isEmpty ? '/' : f['path']!;
    final sni = (f['sni'] ?? '').isNotEmpty ? f['sni']! : (host.isNotEmpty ? host : add);
    b.writeln('Protocole : ${f['proto']}   Réseau : $net   TLS : ${tls ? 'oui' : 'non'}');
    b.writeln('Cible : $add:$port');
    b.writeln('Host : ${host.isEmpty ? '(vide, donc $add)' : host}');
    b.writeln('SNI : $sni   Path : $path');
    b.writeln('');
    var ip = add;
    var sw = Stopwatch()..start();
    try {
      final r = await InternetAddress.lookup(add, type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 6));
      ip = r.first.address;
      b.writeln('1. DNS : OK -> $ip (${sw.elapsedMilliseconds} ms)');
    } catch (_) {
      b.writeln('1. DNS : ECHEC (le téléphone ne trouve pas ce serveur)');
      return b.toString();
    }
    Socket? sock;
    try {
      sw = Stopwatch()..start();
      sock = await Socket.connect(ip, port, timeout: const Duration(seconds: 8));
      b.writeln('2. Connexion TCP : OK (${sw.elapsedMilliseconds} ms)');
      if (tls) {
        sock = await SecureSocket.secure(sock, host: sni, onBadCertificate: (_) => true);
        b.writeln('3. TLS : OK (SNI $sni)');
      }
      if (net == 'ws') {
        final key = base64Encode(List<int>.generate(16, (_) => Random().nextInt(256)));
        sock.write('GET $path HTTP/1.1\r\nHost: ${host.isEmpty ? add : host}\r\n'
            'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n');
        final data = await sock.first.timeout(const Duration(seconds: 8));
        final line = utf8.decode(data, allowMalformed: true).split('\r\n').first;
        b.writeln('4. WebSocket : $line');
        b.writeln(line.contains('101')
            ? '=> Le serveur accepte ce Host et ce Path.'
            : '=> Le serveur refuse : change le Host, le Path ou le port.');
      } else {
        b.writeln('(Test WebSocket ignoré : réseau $net)');
      }
    } catch (e) {
      b.writeln('ECHEC : ${e.runtimeType} ${e.toString().split('\n').first}');
    } finally {
      sock?.destroy();
    }
    final d = await _delay(i);
    b.writeln('5. Test du moteur : ${d > 0 ? '$d ms' : 'echec'}');
    return b.toString();
  }

  Future<void> diagnose(Cfg c, int i) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Expanded(child: Text('Diagnostic en cours...')),
        ]),
      ),
    );
    final report = c.link.startsWith('dns://')
        ? await _dnsReport(c)
        : c.link.startsWith('ssh://')
        ? await _sshReport(c)
        : (await _diagReport(c, i)) + (await _coreReport(c)) + (await _nativeReport());
    if (!mounted) return;
    Navigator.of(context).pop();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Diagnostic'),
        content: SingleChildScrollView(child: SelectableText(report)),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: report));
                snack('Rapport copié');
              },
              child: const Text('Copier')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> engineView(int i) async {
    final cfg = parse(configs[i].link);
    if (cfg == null) return snack('Config invalide');
    final built = await buildConfig(cfg, configs[i].link);
    String txt;
    try {
      txt = JsonEncoder.withIndent('  ').convert(jsonDecode(built));
    } catch (_) {
      txt = built;
    }
    final masked = txt.replaceAll(
        RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'),
        'UUID');
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Config du moteur'),
        content: SizedBox(
          width: double.maxFinite,
          height: 380,
          child: SingleChildScrollView(
            child: SelectableText(txt, style: const TextStyle(fontSize: 11)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: masked));
              snack('JSON copié (UUID masqué)');
            },
            child: const Text('Copier (UUID masqué)'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Future<void> editJsonDialog(int i) async {
    final c = configs[i];
    final p = parse(c.link);
    if (p == null) return;
    String txt;
    try {
      txt = JsonEncoder.withIndent('  ').convert(jsonDecode(p.full()));
    } catch (_) {
      txt = p.full();
    }
    final t = TextEditingController(text: txt);
    final n = TextEditingController(text: c.name);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Modifier le JSON'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: Column(children: [
            TextField(controller: n, decoration: const InputDecoration(labelText: 'Nom')),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: t,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontSize: 11),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              try {
                final j = jsonDecode(t.text);
                if (j is! Map || j['outbounds'] is! List) {
                  return snack('JSON invalide : il manque « outbounds »');
                }
                setState(() {
                  c.link = 'xrayjson://${base64Encode(utf8.encode(jsonEncode(j)))}';
                  if (n.text.trim().isNotEmpty) c.name = n.text.trim();
                  pings.clear();
                });
                _save();
                Navigator.pop(ctx);
              } catch (_) {
                snack('JSON invalide');
              }
            },
            style: FilledButton.styleFrom(backgroundColor: kRed),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  Future<void> newConfig() async {
    final r = await Navigator.push<Cfg>(
        context, MaterialPageRoute(builder: (_) => ConfigEditor(defaultInsecure: insecureDefault)));
    if (r != null) {
      setState(() => configs.add(r));
      _save();
      snack('Config créée');
    }
  }

  Future<void> _incoming(String t) async {
    final l = await parseImport(t, false);
    if (l.isEmpty) {
      snack('Fichier non reconnu');
      return;
    }
    setState(() => tab = 1);
    _addImported(l);
  }

  Future<void> pickApps() async {
    var apps = <Map<String, String>>[];
    try {
      final r = await kChan.invokeMethod<List<dynamic>>('listApps');
      apps = (r ?? []).map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {}
    if (apps.isEmpty) return excludeDialog();
    final chosen = excludedApps.toSet();
    final q = TextEditingController();
    var filter = '';
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) {
        final shown = apps
            .where((a) =>
                filter.isEmpty ||
                a['name']!.toLowerCase().contains(filter) ||
                a['pkg']!.contains(filter))
            .toList();
        return AlertDialog(
          title: const Text('Applis hors VPN'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: Column(children: [
              TextField(
                controller: q,
                decoration: const InputDecoration(hintText: 'Rechercher'),
                onChanged: (v) => setD(() => filter = v.trim().toLowerCase()),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final a = shown[i];
                    return CheckboxListTile(
                      dense: true,
                      title: Text(a['name']!),
                      subtitle: Text(a['pkg']!, style: const TextStyle(fontSize: 11)),
                      value: chosen.contains(a['pkg']),
                      onChanged: (v) => setD(() {
                        if (v == true) {
                          chosen.add(a['pkg']!);
                        } else {
                          chosen.remove(a['pkg']!);
                        }
                      }),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                setState(() => excluded = chosen.join(','));
                _saveSettings();
                Navigator.pop(ctx);
              },
              style: FilledButton.styleFrom(backgroundColor: kRed),
              child: const Text('Enregistrer'),
            ),
          ],
        );
      }),
    );
  }

  Skin? get curSkin {
    if (skinId == 'classic') return null;
    for (final k in skins) {
      if (k.id == skinId) return k;
    }
    return null;
  }

  Future<void> _loadSkins(SharedPreferences p) async {
    final out = <Skin>[];
    final names = <String, String>{};
    try {
      final m = jsonDecode(p.getString('skinNames') ?? '{}') as Map<String, dynamic>;
      m.forEach((k, v) => names[k] = '$v');
    } catch (_) {}
    try {
      final raw = await rootBundle.loadString('assets/chars/chars.json');
      for (final e in (jsonDecode(raw) as List)) {
        out.add(Skin.fromJson(Map<String, dynamic>.from(e as Map), true));
      }
    } catch (_) {}
    try {
      for (final e in (jsonDecode(p.getString('userSkins') ?? '[]') as List)) {
        final k = Skin.fromJson(Map<String, dynamic>.from(e as Map), false);
        if (File(k.file).existsSync()) out.add(k);
      }
    } catch (_) {}
    for (final k in out) {
      final n = names[k.id];
      if (n != null && n.isNotEmpty) k.name = n;
    }
    if (!mounted) return;
    setState(() {
      skins = out;
      skinNames = names;
      if (skinId != 'classic' && !out.any((k) => k.id == skinId)) skinId = 'classic';
    });
  }

  Future<void> _saveSkins() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'userSkins', jsonEncode(skins.where((k) => !k.asset).map((k) => k.toJson()).toList()));
    await p.setString('skinNames', jsonEncode(skinNames));
    await p.setString('skinId', skinId);
  }

  Future<void> createSkin() async {
    final r = await Navigator.push<Skin>(
        context, MaterialPageRoute(builder: (_) => const SkinMaker()));
    if (r == null) return;
    setState(() {
      skins.add(r);
      skinId = r.id;
    });
    await _saveSkins();
    snack('Skin créé : ${r.name}');
  }

  Future<void> skinMenu(Skin k) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Renommer'),
              onTap: () => Navigator.pop(ctx, 'rename')),
          if (!k.asset)
            ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Supprimer'),
                onTap: () => Navigator.pop(ctx, 'del')),
        ]),
      ),
    );
    if (v == 'rename') {
      final n = await askText('Nom du skin', k.name);
      if (n != null && n.trim().isNotEmpty) {
        setState(() {
          k.name = n.trim();
          if (k.asset) skinNames[k.id] = k.name;
        });
        _saveSkins();
      }
    } else if (v == 'del') {
      try {
        File(k.file).deleteSync();
      } catch (_) {}
      setState(() {
        skins.remove(k);
        if (skinId == k.id) skinId = 'classic';
      });
      _saveSkins();
    }
  }

  Future<void> skinDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Widget tile(String id, String nm, Widget thumb, {Skin? k}) => GestureDetector(
              onTap: () {
                setState(() => skinId = id);
                _saveSkins();
                Navigator.pop(ctx);
              },
              onLongPress: k == null
                  ? null
                  : () async {
                      await skinMenu(k);
                      setD(() {});
                    },
              child: Column(children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: skinId == id ? kRed : Colors.transparent, width: 3),
                  ),
                  padding: const EdgeInsets.all(2),
                  child: thumb,
                ),
                const SizedBox(height: 2),
                Text(nm,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10)),
              ]),
            );
        return AlertDialog(
          title: const Text('Skins'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: GridView.count(
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.78,
              children: [
                tile('classic', 'Classique',
                    ClipOval(child: Image.asset('assets/images/mangekyo.png', width: 64, height: 64))),
                for (final k in skins) tile(k.id, k.name, CharEye(skin: k, size: 64, ring: false), k: k),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  createSkin();
                },
                child: const Text('Créer un skin')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          ],
        );
      }),
    );
  }

  Future<void> hotspotInfo() async {
    final cfg = configs.isEmpty ? null : parse(configs[sel].link);
    final ports = <String>[];
    if (cfg != null) {
      try {
        final m = jsonDecode(await buildConfig(cfg, configs[sel].link)) as Map<String, dynamic>;
        for (final i in (m['inbounds'] as List)) {
          if (i is Map && (i['protocol'] == 'http' || i['protocol'] == 'socks')) {
            ports.add('${i['protocol']} : ${i['port']}');
          }
        }
      } catch (_) {}
    }
    final ips = <String>[];
    try {
      for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in ni.addresses) {
          ips.add('${ni.name} : ${a.address}');
        }
      }
    } catch (_) {}
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Partage par hotspot'),
        content: SingleChildScrollView(
          child: Text(
              '1. Active le hotspot du téléphone et connecte l\'autre appareil.\n'
              '2. Sur l\'autre appareil, règle un proxy manuel avec l\'adresse du hotspot et un port ci-dessous.\n\n'
              'Ports :\n${ports.isEmpty ? 'inconnus (sélectionne une config valide)' : ports.join('\n')}\n\n'
              'Adresses du téléphone :\n${ips.isEmpty ? 'aucune' : ips.join('\n')}\n\n'
              'Attention : toute personne connectée à ton hotspot pourra utiliser ce proxy. '
              'Les applis qui ignorent le proxy ne passeront pas par le VPN.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer'))
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
    } else if (v == 'diag') {
      await diagnose(c, i);
    } else if (v == 'edit') {
      if (parseLink(c.link) == null) {
        await editDialog(i);
      } else {
        final r = await Navigator.push<Cfg>(
            context, MaterialPageRoute(builder: (_) => ConfigEditor(cfg: c, defaultInsecure: insecureDefault)));
        if (r != null) {
          setState(() {
            configs[i] = r;
            pings.clear();
          });
          _save();
        }
      }
    } else if (v == 'messages') {
      await messagesDialog(i);
    } else if (v == 'editjson') {
      await editJsonDialog(i);
    } else if (v == 'engine') {
      await engineView(i);
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
      await shareFile([Cfg(c.name, c.link, true, expiry: c.expiry, limitMb: c.limitMb, msg: c.msg, cmsg: c.cmsg)], c.name);
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
            TextButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    await kChan.invokeMethod('openVpnSettings');
                  } catch (_) {
                    snack('Ouverture impossible, fais-le à la main');
                  }
                },
                child: const Text('Ouvrir les réglages VPN')),
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
    return s < 0 ? 'Échec, réessayer' : '${s.toStringAsFixed(1)} Mb/s';
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
        BoxShadow(color: glow.withValues(alpha: connected ? 0.8 : 0.3), blurRadius: 40),
      ]),
      child: img,
    );
  }

  // Œil du personnage au centre, halo et anneaux qui pulsent dans la couleur de l'aura.
  Widget charEye(Skin k) => AnimatedBuilder(
        animation: spin,
        child: CharEye(skin: k, size: 190),
        builder: (_, child) {
          final t = sin(spin.value * 2 * pi);
          final pulse = 1 + 0.035 * t;
          return SizedBox(
            width: 300,
            height: 300,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                width: 215 * pulse,
                height: 215 * pulse,
                decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [
                  BoxShadow(color: k.aura.withValues(alpha: 0.75), blurRadius: 70, spreadRadius: 14),
                ]),
              ),
              for (final r in [(216.0, 0.8), (250.0, 0.5), (284.0, 0.28)])
                Container(
                  width: r.$1 * pulse,
                  height: r.$1 * pulse,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: k.aura.withValues(alpha: r.$2), width: 2),
                  ),
                ),
              child!,
            ]),
          );
        },
      );

  @override
  void dispose() {
    _ipTimer?.cancel();
    spin.dispose();
    super.dispose();
  }

  void setStep(int i, int st) {
    stepSt[i] = st;
    logTick.value++;
  }

  void _resetSteps() {
    stepSt = List<int>.filled(kSteps.length, 0);
    trafficOk = false;
    logTick.value++;
  }

  Map<String, String> msgVars() {
    final i = ipNow;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return {
      'ip': i?.ip ?? '—',
      'pays': i?.country ?? '—',
      'ville': i?.city ?? '—',
      'region': i?.region ?? '—',
      'fai': i?.isp ?? '—',
      'fuseau': i?.tz ?? '—',
      'heure': '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
      'date': '${two(now.day)}/${two(now.month)}/${now.year}',
      'serveur': configs.isEmpty ? '' : configs[sel].name,
      'duree': duration,
    };
  }

  void showMsgDialog(String title, String html) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: richMessage(fillVars(html, msgVars()), onLink: openLink)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> messagesDialog(int i) async {
    final c = configs[i];
    final m = TextEditingController(text: c.msg);
    final cm = TextEditingController(text: c.cmsg);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Messages du fichier'),
        content: SizedBox(
          width: double.maxFinite,
          height: 440,
          child: SingleChildScrollView(
            child: Column(children: [
              const Text(
                  'HTML simple (<b>, <i>, <u>, <h1>, <br>, <center>, <span style="color:#ff0">) '
                  'et variables {ip} {pays} {ville} {heure} {serveur}. '
                  'Le code Python n\'est jamais exécuté.',
                  style: TextStyle(color: Colors.white60, fontSize: 11)),
              const SizedBox(height: 8),
              TextField(
                controller: m,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: 'Message pour celui qui ouvre le fichier',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cm,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: 'Message de connexion (quand le trafic passe)',
                    border: OutlineInputBorder()),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => showMsgDialog('Aperçu du message', m.text), child: const Text('Aperçu 1')),
          TextButton(onPressed: () => showMsgDialog('Aperçu du message de connexion', cm.text), child: const Text('Aperçu 2')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              setState(() {
                c.msg = m.text.trim();
                c.cmsg = cm.text.trim();
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

  // ----- Adresse IP et localisation (service en ligne, via le VPN quand il est actif) -----
  Future<IpInfo?> _lookupIp() async {
    const urls = [
      'https://ipwho.is/',
      'https://ipapi.co/json/',
      'http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,isp,query,timezone',
    ];
    for (final u in urls) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
      try {
        final req = await client.getUrl(Uri.parse(u)).timeout(const Duration(seconds: 7));
        req.headers.set('User-Agent', 'OtakuTunnel');
        final res = await req.close().timeout(const Duration(seconds: 7));
        if (res.statusCode != 200) continue;
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 7));
        final j = jsonDecode(body) as Map<String, dynamic>;
        final ip = '${j['ip'] ?? j['query'] ?? ''}';
        if (ip.isEmpty) continue;
        String s(dynamic v) => v == null ? '' : '$v';
        final conn = j['connection'];
        final tzv = j['timezone'];
        return IpInfo(
          ip,
          s(j['country_name'] ?? j['country']),
          s(j['country_code'] ?? j['countryCode']),
          s(j['city']),
          s(j['region'] ?? j['regionName']),
          s(conn is Map ? conn['isp'] : (j['isp'] ?? j['org'])),
          s(tzv is Map ? tzv['id'] : tzv),
          DateTime.now(),
        );
      } catch (_) {
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<IpInfo?> refreshIp({bool force = false}) async {
    if (ipLoading && !force) return ipNow;
    if (mounted) setState(() => ipLoading = true);
    final r = await _lookupIp();
    if (!mounted) return r;
    setState(() {
      ipLoading = false;
      if (r != null) {
        ipNow = r;
        if (!connected) ipDirect = r;
      }
    });
    if (r != null) {
      log('IP : ${r.ip} (${r.city.isEmpty ? '' : '${r.city}, '}${r.country})');
    } else {
      log('IP : recherche impossible (pas de trafic ?)');
    }
    return r;
  }

  // Après « Connecté » : on vérifie que le trafic passe vraiment (recherche d'IP à travers le tunnel).
  Future<void> _afterConnected() async {
    setStep(3, 1);
    for (var k = 0; k < 4 && connected; k++) {
      await Future.delayed(Duration(seconds: k == 0 ? 3 : 6));
      if (!mounted || !connected) return;
      final r = await refreshIp(force: true);
      if (r != null) {
        trafficOk = true;
        setStep(3, 2);
        setStep(4, 2);
        log('Trafic OK : IP ${r.ip} (${r.country})');
        if (mounted) {
          final c = configs.isEmpty ? null : configs[sel];
          if (c != null && c.cmsg.trim().isNotEmpty) {
            snack('Message de connexion reçu : voir l\'onglet Journal');
          }
          setState(() {});
        }
        return;
      }
      log('Pas encore de trafic (essai ${k + 1}/4)');
    }
    if (mounted && connected) {
      setStep(3, 3);
      log('Aucun trafic détecté : touche Diagnostic complet');
    }
  }

  // ----- Onglet Journal -----
  Widget journalCard(String title, IconData ic, List<Widget> ch) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ic, size: 18, color: kRed),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 10),
          ...ch,
        ]),
      );

  Widget stepChip(int k) {
    final st = stepSt[k];
    Widget icon;
    if (st == 1) {
      icon = const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (st == 2) {
      icon = const Icon(Icons.check_circle, size: 16, color: Colors.greenAccent);
    } else if (st == 3) {
      icon = const Icon(Icons.cancel, size: 16, color: Colors.redAccent);
    } else if (st == 4) {
      icon = const Icon(Icons.remove, size: 16, color: Colors.white38);
    } else {
      icon = const Icon(Icons.radio_button_unchecked, size: 16, color: Colors.white38);
    }
    return Chip(avatar: icon, label: Text(kSteps[k], style: const TextStyle(fontSize: 12)));
  }

  Color logColor(String l) {
    final x = l.toLowerCase();
    if (x.contains('échec') || x.contains('echec') || x.contains('impossible') || x.contains('aucun trafic') || x.contains('refus')) {
      return Colors.redAccent;
    }
    if (x.contains('connected') || x.contains('trafic ok') || x.contains('connecté') || x.contains('résolu')) {
      return Colors.greenAccent;
    }
    return Colors.white70;
  }

  Widget journalTab() {
    final c = configs.isEmpty ? null : configs[sel];
    final ip = ipNow;
    final vars = msgVars();
    final small = const TextStyle(color: Colors.white54, fontSize: 12);
    String two(int n) => n.toString().padLeft(2, '0');
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Text('Journal', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Spacer(),
        IconButton(
          tooltip: 'Actualiser',
          onPressed: ipLoading ? null : () => refreshIp(),
          icon: ipLoading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
        ),
      ]),
      const SizedBox(height: 8),
      journalCard('Mon IP et ma position', Icons.public, [
        if (ip == null)
          Text(ipLoading ? 'Recherche de ton adresse IP...' : 'Adresse IP inconnue. Touche actualiser.',
              style: small)
        else ...[
          Row(children: [
            Text(flagOf(ip.cc), style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 10),
            Expanded(
                child: SelectableText(ip.ip,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 6),
          Text('${ip.city.isEmpty ? '' : '${ip.city}, '}${ip.region.isEmpty ? '' : '${ip.region}, '}${ip.country}'),
          if (ip.isp.isNotEmpty) Text('Opérateur : ${ip.isp}', style: small),
          if (ip.tz.isNotEmpty) Text('Fuseau : ${ip.tz}', style: small),
          Text(
              'Mis à jour à ${two(ip.at.hour)}:${two(ip.at.minute)}:${two(ip.at.second)} • '
              '${connected ? 'via le VPN' : 'connexion directe'}',
              style: small),
          if (connected && ipDirect != null && ipDirect!.ip != ip.ip)
            Text('IP avant le VPN : ${ipDirect!.ip} (${ipDirect!.country})', style: small),
        ],
        const SizedBox(height: 8),
        Text('Position approximative d\'après l\'adresse IP, donnée par un service en ligne.',
            style: small),
      ]),
      journalCard('Connexion en direct', Icons.timeline, [
        ValueListenableBuilder<int>(
          valueListenable: logTick,
          builder: (_, __, ___) => Wrap(
              spacing: 8, runSpacing: 6, children: [for (var k = 0; k < kSteps.length; k++) stepChip(k)]),
        ),
      ]),
      journalCard('Messages', Icons.mail_outline, [
        if (c == null)
          Text('Ajoute une config pour voir ses messages.', style: small)
        else ...[
          const Text('Message du créateur', style: TextStyle(color: kRed, fontSize: 12)),
          const SizedBox(height: 4),
          if (c.msg.trim().isEmpty)
            Text('Aucun message pour cette config.', style: small)
          else
            richMessage(fillVars(c.msg, vars), onLink: openLink),
          const SizedBox(height: 12),
          const Text('Message de connexion', style: TextStyle(color: kRed, fontSize: 12)),
          const SizedBox(height: 4),
          if (c.cmsg.trim().isEmpty)
            Text('Aucun message de connexion.', style: small)
          else if (!trafficOk)
            Text('Il s\'affichera quand le trafic passera.', style: small)
          else
            richMessage(fillVars(c.cmsg, vars), onLink: openLink),
        ],
      ]),
      journalCard('Journal en direct', Icons.article_outlined, [
        Wrap(spacing: 6, children: [
          TextButton.icon(
            onPressed: () {
              if (configs.isEmpty) return snack('Ajoute d\'abord une config');
              diagnose(configs[sel], sel);
            },
            icon: const Icon(Icons.troubleshoot, size: 18),
            label: const Text('Diagnostic'),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: logs.join('\n')));
              snack('Journal copié');
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copier'),
          ),
          TextButton.icon(
            onPressed: () {
              logs.clear();
              logTick.value++;
            },
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Effacer'),
          ),
        ]),
        ValueListenableBuilder<int>(
          valueListenable: logTick,
          builder: (_, __, ___) {
            final shown = logs.reversed.take(80).toList();
            if (shown.isEmpty) return Text('Aucun événement pour le moment.', style: small);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(l, style: TextStyle(fontSize: 11.5, color: logColor(l))),
                  ),
              ],
            );
          },
        ),
      ]),
    ]);
  }

  Widget connectionTab() {
    final c = configs.isEmpty ? null : configs[sel];
    final p = c == null ? null : parse(c.link);
    final cs = curSkin;
    final statusText = connected
        ? (cs != null ? 'Aura activée' : 'Mangekyō activé')
        : sshBusy
            ? 'Connexion SSH...'
            : searching
            ? 'Recherche du meilleur serveur...'
            : busy
                ? 'Activation...'
                : 'Touche le Sharingan';
    return Stack(children: [
      if (cs != null)
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: connected ? 1 : 0,
              duration: const Duration(milliseconds: 700),
              child: CharBackground(skin: cs),
            ),
          ),
        ),
      ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Connexion', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: (cs != null && connected) ? null : const LinearGradient(
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
            child: (cs != null && connected)
                ? charEye(cs)
                : RotationTransition(turns: spin, child: eye()),
          ),
          const SizedBox(height: 16),
          Text(statusText, style: const TextStyle(color: Colors.white70)),
          if (cs != null && connected)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Skin : ${cs.name}',
                  style: TextStyle(color: cs.aura, fontWeight: FontWeight.bold, fontSize: 18)),
            ),
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
          if (speedInfo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(speedInfo,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              if (configs.isEmpty) return snack('Ajoute d\'abord une config');
              diagnose(configs[sel], sel);
            },
            icon: const Icon(Icons.troubleshoot),
            label: const Text('Diagnostic complet'),
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
      ]),
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
            PopupMenuButton<String>(
              icon: const CircleAvatar(
                  backgroundColor: kRed, child: Icon(Icons.add, color: Colors.white)),
              onSelected: (v) => v == 'new' ? newConfig() : importDialog(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'import', child: Text('Importer (lien, code, fichier)')),
                PopupMenuItem(value: 'new', child: Text('Créer manuellement')),
              ],
            ),
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
                              const PopupMenuItem(value: 'diag', child: Text('Diagnostiquer')),
                            if (!c.hidden && !c.isJson)
                              const PopupMenuItem(value: 'edit', child: Text('Modifier')),
                            if (!c.hidden && c.isJson)
                              const PopupMenuItem(value: 'editjson', child: Text('Modifier le JSON')),
                            if (!c.hidden)
                              const PopupMenuItem(value: 'messages', child: Text('Messages')),
                            if (!c.hidden)
                              const PopupMenuItem(
                                  value: 'engine', child: Text('Voir la config du moteur')),
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
        sw('Résoudre le serveur avant connexion',
            'Corrige les cas « connecté mais rien ne passe »', preResolve, (v) => preResolve = v),
        sw('Host automatique', 'Remplit un header host vide avec l\'adresse du serveur', autoHost,
            (v) => autoHost = v),
        sw('Certificats non vérifiés par défaut', 'Comme V2Ray FastSSH (allowInsecure)',
            insecureDefault, (v) => insecureDefault = v),
        sec('Mode et applis'),
        sw('Proxy seulement', 'Sans VPN système (pour apps compatibles)', proxyOnly,
            (v) => proxyOnly = v),
        sw('Partager le VPN par hotspot', 'Ouvre le proxy aux appareils de ton hotspot', hotspot,
            (v) => hotspot = v),
        if (hotspot)
          ListTile(
            leading: const Icon(Icons.wifi_tethering),
            title: const Text('Infos de partage (adresse et ports)'),
            onTap: hotspotInfo,
          ),
        ListTile(
          leading: const Icon(Icons.apps),
          title: const Text('Applis hors VPN'),
          subtitle: Text(excludedApps.isEmpty
              ? 'Aucune'
              : '${excludedApps.length} appli(s) en accès direct'),
          onTap: pickApps,
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
        ListTile(
          leading: const Icon(Icons.remove_red_eye),
          title: const Text('Skin : œil + photo du personnage'),
          subtitle: Text(curSkin?.name ?? 'Classique (Sharingan puis Mangekyō)'),
          onTap: skinDialog,
        ),
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
          leading: const Icon(Icons.settings_ethernet),
          title: const Text('Infos du tunnel (tun2socks)'),
          subtitle: const Text('Connecte-toi d\'abord pour un résultat complet'),
          onTap: tunnelInfo,
        ),
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
          title: Text('OTAKU TUNNEL v6.3'),
          subtitle: Text('Créé par APPOH GODWIN • alias HACKER GODWIN'),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: [connectionTab(), configsTab(), journalTab(), settingsTab()][tab],
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            setState(() => tab = i);
            if (i == 2 && !ipLoading) refreshIp();
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.shield_outlined), label: 'Connexion'),
            NavigationDestination(icon: Icon(Icons.public), label: 'Configs'),
            NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Journal'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Réglages'),
          ],
        ),
      );
}
