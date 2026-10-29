import 'package:flutter/widgets.dart';

// Version SANS publicité (aucun module Google).
Future<void> adsInit() async {}

void adsAfterConnect(bool Function() stillConnected, void Function(String) log) {}

class AdsBanner extends StatelessWidget {
  const AdsBanner({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
