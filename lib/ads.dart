import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:startapp_sdk/startapp.dart';

// true = pubs de TEST (aucun gain). Le script startio.sh passe à false avec l'option "prod".
const kStartTest = true;

// Une pub plein écran/vidéo à la connexion, puis au plus une toutes les 30 minutes.
const _gap = Duration(minutes: 30);

DateTime? _lastAd;
Future<bool>? _init;
bool Function()? _still;
void Function(String)? _log;
Future<void> Function()? _warn;
Timer? _timer;
bool _showing = false;

// Le module Start.io n'est démarré qu'au moment où il sert, jamais au lancement.
Future<bool> _ensureInit() {
  return _init ??= () async {
    try {
      await StartAppSdk().setTestAdsEnabled(kStartTest);
      return true;
    } catch (_) {
      return false;
    }
  }();
}

Future<void> adsInit() async {}

void adsAfterConnect(bool Function() stillConnected, void Function(String) log,
    {Future<void> Function()? warn}) {
  _still = stillConnected;
  _log = log;
  _warn = warn;
  _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => _maybeShow(false));
  _maybeShow(true);
}

void _safeDispose(StartAppInterstitialAd a) {
  try {
    a.dispose();
  } catch (_) {}
}

Future<void> _maybeShow(bool first) async {
  try {
    if (_showing) return;
    if (!(_still?.call() ?? false)) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final now = DateTime.now();
    if (_lastAd != null && now.difference(_lastAd!) < _gap) return;
    if (!await _ensureInit()) {
      _log?.call('Pub : module Start.io non démarré');
      return;
    }
    _showing = true;
    Timer(const Duration(minutes: 3), () => _showing = false);
    if (!first && _warn != null) await _warn!();
    if (!(_still?.call() ?? false)) {
      _showing = false;
      return;
    }
    late StartAppInterstitialAd ad;
    ad = await StartAppSdk().loadInterstitialAd(
      onAdDisplayed: () {
        _lastAd = DateTime.now();
      },
      onAdNotDisplayed: () {
        _safeDispose(ad);
        _showing = false;
      },
      onAdHidden: () {
        _safeDispose(ad);
        _showing = false;
      },
    );
    final shown = await ad.show();
    if (shown) {
      _log?.call('Pub vidéo affichée');
    } else {
      _safeDispose(ad);
      _showing = false;
      // pas de pub disponible : on réessaie dans 5 minutes
      _lastAd = DateTime.now().subtract(_gap - const Duration(minutes: 5));
      _log?.call('Pub : aucune pub disponible pour le moment');
    }
  } catch (e) {
    _showing = false;
    _lastAd = DateTime.now().subtract(_gap - const Duration(minutes: 5));
    _log?.call('Pub : erreur $e');
  }
}

// Une bannière en bas des onglets Connexion et Journal (visible seulement une fois connecté).
class AdsBanner extends StatefulWidget {
  const AdsBanner({super.key});
  @override
  State<AdsBanner> createState() => _AdsBannerState();
}

class _AdsBannerState extends State<AdsBanner> {
  StartAppBannerAd? _b;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (!await _ensureInit() || !mounted) return;
      final b = await StartAppSdk().loadBannerAd(StartAppBannerType.BANNER);
      if (!mounted) return;
      setState(() => _b = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(height: 56, width: double.infinity, child: StartAppBanner(b)),
    );
  }
}
