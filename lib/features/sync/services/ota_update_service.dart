import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../../../main.dart';
import '../../../core/storage/local_storage_repository.dart';

class OtaUpdateService {
  static const MethodChannel _channel = MethodChannel('com.dashfleet.pos/ota');
  static bool _isModalOpen = false;

  static void triggerUpdateModal(String version, String urlApk) {
    if (_isModalOpen) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    _isModalOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        bool isDownloading = false;
        double progress = 0;

        return StatefulBuilder(
          builder: (modalContext, setState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.white,
              title: const Text('Actualización Disponible', style: TextStyle(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Hay una nueva versión de la aplicación disponible ($version).', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  if (isDownloading) ...[
                    const CircularProgressIndicator(color: Color(0xFF6642F8)),
                    const SizedBox(height: 10),
                    Text('Descargando: ${(progress * 100).toStringAsFixed(0)}%'),
                  ]
                ],
              ),
              actions: [
                if (!isDownloading)
                  TextButton(
                    onPressed: () {
                      _isModalOpen = false;
                      Navigator.pop(modalContext);
                    },
                    child: const Text('CANCELAR', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                  ),
                if (!isDownloading)
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6642F8)),
                    onPressed: () async {
                      setState(() => isDownloading = true);
                      await _downloadAndInstallApk(version, urlApk, (p) {
                        setState(() => progress = p);
                      });
                      _isModalOpen = false;
                      if (modalContext.mounted) {
                        Navigator.pop(modalContext);
                      }
                    },
                    child: const Text('ACEPTAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
              ],
            );
          },
        );
      },
    ).then((_) {
      _isModalOpen = false;
    });
  }

  static Future<void> _downloadAndInstallApk(String version, String urlApk, Function(double) onProgress) async {
    try {
      final dio = Dio();
      final dir = await getApplicationDocumentsDirectory();
      final apkPath = '${dir.path}/update_$version.apk';
      
      final file = File(apkPath);
      if (await file.exists()) {
        await file.delete();
      }

      await dio.download(
        urlApk,
        apkPath,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            onProgress(received / total);
          }
        },
      );

      final storage = LocalStorageRepository();
      await storage.saveApkVersion(version);

      await _channel.invokeMethod('installApk', {'apkPath': apkPath});
    } catch (e) {
      debugPrint('Error en OTA: $e');
    }
  }
}
