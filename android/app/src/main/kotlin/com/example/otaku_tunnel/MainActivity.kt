package com.example.otaku_tunnel

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "otaku/intent")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitial" -> {
                    val t = readIntent(intent)
                    setIntent(Intent(Intent.ACTION_MAIN))
                    result.success(t)
                }
                "openVpnSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_VPN_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "listApps" -> {
                    val pm = packageManager
                    val list = pm.getInstalledApplications(0)
                        .filter { pm.getLaunchIntentForPackage(it.packageName) != null && it.packageName != packageName }
                        .map { mapOf("name" to pm.getApplicationLabel(it).toString(), "pkg" to it.packageName) }
                        .sortedBy { it["name"]!!.lowercase() }
                    result.success(list)
                }
                "nativeInfo" -> {
                    val sb = StringBuilder()
                    sb.appendLine("ABI du téléphone : " + android.os.Build.SUPPORTED_ABIS.joinToString(", "))
                    val dir = applicationInfo.nativeLibraryDir
                    sb.appendLine("Dossier natif : " + dir)
                    val names = java.io.File(dir).list()
                    if (names == null || names.isEmpty()) {
                        sb.appendLine("Fichiers : AUCUN (bibliothèques non extraites)")
                    } else {
                        sb.appendLine("Fichiers : " + names.sorted().joinToString(", "))
                    }
                    val t2s = java.io.File(dir, "libtun2socks.so")
                    if (t2s.exists()) {
                        sb.appendLine("libtun2socks.so : présent, exécutable = " + t2s.canExecute())
                    } else {
                        sb.appendLine("libtun2socks.so : ABSENT")
                    }
                    try {
                        val pr = Runtime.getRuntime().exec(arrayOf("sh", "-c", "ps -A 2>/dev/null | grep [l]ibtun2socks"))
                        val out = pr.inputStream.bufferedReader().readText().trim()
                        sb.appendLine("Processus tun2socks : " + (if (out.isEmpty()) "non trouvé" else "EN MARCHE"))
                    } catch (e: Exception) {
                        sb.appendLine("Processus tun2socks : lecture impossible")
                    }
                    result.success(sb.toString())
                }
                "nativeDir" -> {
                    result.success(applicationInfo.nativeLibraryDir)
                }
                "netInfo" -> {
                    val out = HashMap<String, Any>()
                    val nets = ArrayList<Map<String, String>>()
                    try {
                        val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
                        val activeNet = cm.activeNetwork
                        for (n in cm.allNetworks) {
                            val caps = cm.getNetworkCapabilities(n) ?: continue
                            val lp = cm.getLinkProperties(n)
                            val t = ArrayList<String>()
                            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) t.add("Wi-Fi")
                            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR)) t.add("Données mobiles")
                            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) t.add("Ethernet")
                            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) t.add("VPN")
                            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_BLUETOOTH)) t.add("Bluetooth")
                            val addrs = ArrayList<String>()
                            if (lp != null) {
                                for (la in lp.linkAddresses) {
                                    val h = la.address.hostAddress
                                    if (h != null && !h.contains(":")) addrs.add(h)
                                }
                            }
                            nets.add(mapOf(
                                "type" to t.joinToString(" + "),
                                "iface" to (lp?.interfaceName ?: ""),
                                "addrs" to addrs.joinToString(", "),
                                "active" to (n == activeNet).toString()
                            ))
                        }
                    } catch (e: Throwable) {
                    }
                    out["nets"] = nets
                    try {
                        val tm = getSystemService(android.content.Context.TELEPHONY_SERVICE) as android.telephony.TelephonyManager
                        out["operator"] = tm.networkOperatorName ?: ""
                        out["sim"] = tm.simOperatorName ?: ""
                        out["plmn"] = tm.networkOperator ?: ""
                    } catch (e: Throwable) {
                    }
                    result.success(out)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val t = readIntent(intent)
        if (t != null) channel?.invokeMethod("onIntent", t)
    }

    private fun readIntent(i: Intent?): String? {
        if (i == null) return null
        return try {
            var uri: Uri? = null
            var text: String? = null
            if (i.action == Intent.ACTION_VIEW) {
                uri = i.data
            } else if (i.action == Intent.ACTION_SEND) {
                uri = i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                text = i.getStringExtra(Intent.EXTRA_TEXT)
            }
            if (uri != null) {
                contentResolver.openInputStream(uri)?.use { s -> s.bufferedReader().readText() }
            } else {
                text
            }
        } catch (e: Exception) {
            null
        }
    }
}
