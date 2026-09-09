package com.monprojet.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "yam/battery_optimization"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    "openBatterySettings" -> {
                        openBatterySettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS : dialog système
        // "Autoriser Yam à ignorer l'optimisation de la batterie ?"
        // Disponible depuis API 23 (minSdk 24 → toujours OK).
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // Fallback : ouvrir les paramètres batterie génériques.
            openBatterySettings()
        }
    }

    private fun openBatterySettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        } else {
            Intent(Settings.ACTION_SETTINGS)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // Dernier recours : paramètres de l'app.
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                })
            } catch (_: Exception) {
                // Aucun intent disponible : on abandonne silencieusement.
            }
        }
    }
}