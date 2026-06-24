import 'package:flutter/material.dart';
import 'package:app_settings/app_settings.dart';
import 'dart:async';
import '../services/kiosk_service.dart';

class KioskLogoButton extends StatefulWidget {
  final Widget child;
  final String pin;
  final int requiredTaps;
  final VoidCallback? onSuccess;

  const KioskLogoButton({
    super.key,
    required this.child,
    this.pin = '1510',
    this.requiredTaps = 3,
    this.onSuccess,
  });

  @override
  State<KioskLogoButton> createState() => _KioskLogoButtonState();
}

class _KioskLogoButtonState extends State<KioskLogoButton> {
  int _tapCount = 0;
  Timer? _tapTimer;

  void _handleTap() {
    setState(() {
      _tapCount++;
    });

    if (_tapTimer != null && _tapTimer!.isActive) {
      _tapTimer!.cancel();
    }

    if (_tapCount >= widget.requiredTaps) {
      _tapCount = 0;
      _showPinDialog();
    } else {
      _tapTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) {
          setState(() {
            _tapCount = 0;
          });
        }
      });
    }
  }

  void _showPinDialog() {
    final TextEditingController pinController = TextEditingController();
    bool isError = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('Acceso Administrador',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                      'Ingrese el PIN para salir del modo kiosco y acceder a los ajustes del sistema.'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'PIN de seguridad',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      errorText: isError ? 'PIN incorrecto' : null,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('CANCELAR',
                      style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final now = DateTime.now();
                    final dynamicPin = '${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';

                    if (pinController.text == dynamicPin) {
                      Navigator.pop(ctx);
                      if (widget.onSuccess != null) {
                        widget.onSuccess!();
                      } else {
                        // Con el Lock Task activo, Android bloquea abrir
                        // Settings: hay que salir del kiosco primero.
                        await KioskService.stop();
                        AppSettings.openAppSettings();
                      }
                    } else {
                      setStateDialog(() {
                        isError = true;
                      });
                    }
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6642F8),
                      foregroundColor: Colors.white),
                  child: const Text('INGRESAR'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    _tapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: widget.child,
    );
  }
}
