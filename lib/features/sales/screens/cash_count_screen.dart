import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../helpers/closing_helper.dart';

class CashCountScreen extends ConsumerStatefulWidget {
  final bool isLogout;

  const CashCountScreen({super.key, required this.isLogout});

  @override
  ConsumerState<CashCountScreen> createState() => _CashCountScreenState();
}

class _CashCountScreenState extends ConsumerState<CashCountScreen> {
  final TextEditingController _coinsController = TextEditingController();
  final TextEditingController _billsController = TextEditingController();
  TextEditingController? _activeController;

  @override
  void initState() {
    super.initState();
    _activeController = _coinsController;
  }

  /*
  // Monedas
  int c1 = 0;
  int c5 = 0;
  int c10 = 0;
  int c25 = 0;
  int c50 = 0;
  int c100 = 0; // 1 dólar moneda

  // Billetes
  int b1 = 0;
  int b5 = 0;
  int b10 = 0;
  int b20 = 0;
  int b100 = 0;
  */

  double get totalValue {
    final coins = double.tryParse(_coinsController.text) ?? 0.0;
    final bills = double.tryParse(_billsController.text) ?? 0.0;
    return coins + bills;
  }

  void _showConfirmModal() async {
    try {
      // Mostrar indicador de carga mientras obtiene el total
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFF6642F8))),
      );

      final totalSistema = await ClosingHelper.getUnclosedTotal(ref);
      final currentTotal = totalValue;

      if (!context.mounted) return;
      Navigator.pop(context); // Cierra el indicador de carga

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar Cierre'),
        content: Text(
          '¿Estás seguro que deseas enviar el cierre por un valor de \$${currentTotal.toStringAsFixed(2)}?',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              
              // balance = Efectivo Declarado - Total Sistema
              final balance = currentTotal - totalSistema;

              final coinsAmount = double.tryParse(_coinsController.text) ?? 0.0;
              final billsAmount = double.tryParse(_billsController.text) ?? 0.0;

              // En lugar de cashList, pasamos el resumen en un map temporal que enviaremos a la trama RC172
              final Map<String, dynamic> cashList = {
                "coins_total": coinsAmount,
                "bills_total": billsAmount,
                "cash": currentTotal
              };

              await ClosingHelper.performArqueoClosing(
                context, 
                ref, 
                cashList, // Adaptado para recibir el mapa nuevo
                currentTotal, 
                balance,
                isLogout: true // SIEMPRE DEBE CERRAR SESIÓN AL ENVIAR CIERRE
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0066CC)),
            child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Cierra el indicador si hay error
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al preparar cierre: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // _showSuccessModal no longer needed directly here, as ClosingHelper handles success and logout.

  void _onNumPadTap(String value) {
    if (_activeController == null) return;
    final text = _activeController!.text;
    
    if (value == '⌫') {
      if (text.isNotEmpty) {
        _activeController!.text = text.substring(0, text.length - 1);
      }
    } else if (value == '.') {
      if (!text.contains('.')) {
        _activeController!.text = text.isEmpty ? '0.' : '$text.';
      }
    } else {
      if (text == '0' && value != '.') {
        _activeController!.text = value;
      } else {
        _activeController!.text += value;
      }
    }
    setState(() {}); // Actualiza totalValue
  }

  Widget _buildNumPad() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280), // Reducido de 380 a 280
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        mainAxisSpacing: 8, // Reducido
        crossAxisSpacing: 8, // Reducido
        childAspectRatio: 1.5, // Más aplastado para hacerlo compacto
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 1; i <= 9; i++) _buildNumButton(i.toString()),
          _buildNumButton('.', color: Colors.blueGrey),
          _buildNumButton('0'),
          _buildNumButton('⌫', icon: Icons.backspace_outlined, color: Colors.redAccent),
        ],
      ),
    );
  }

  Widget _buildNumButton(String label, {IconData? icon, Color? color}) {
    return Material(
      color: color?.withOpacity(0.1) ?? Colors.grey.shade100,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _onNumPadTap(label),
        child: Center(
          child: icon != null
              ? Icon(icon, color: color ?? const Color(0xFF3F3D56), size: 24) // Reducido
              : Text(label,
                  style: TextStyle(
                      fontSize: 24, // Reducido de 28
                      fontWeight: FontWeight.bold,
                      color: color ?? const Color(0xFF3F3D56))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF5F5F5),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  // Lado izquierdo: Inputs
                  Expanded(
                    flex: 5,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Saldo en Monedas', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.orange)),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _coinsController,
                            readOnly: true,
                            showCursor: true,
                            onTap: () => setState(() => _activeController = _coinsController),
                            decoration: InputDecoration(
                              prefixText: '\$ ',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              hintText: '0.00',
                              filled: _activeController == _coinsController,
                              fillColor: Colors.orange.withOpacity(0.1),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Colors.orange, width: 2),
                              ),
                            ),
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 30),
                          const Text('Saldo en Billetes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green)),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _billsController,
                            readOnly: true,
                            showCursor: true,
                            onTap: () => setState(() => _activeController = _billsController),
                            decoration: InputDecoration(
                              prefixText: '\$ ',
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                              hintText: '0.00',
                              filled: _activeController == _billsController,
                              fillColor: Colors.green.withOpacity(0.1),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Colors.green, width: 2),
                              ),
                            ),
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Separador
                  Container(width: 1, height: double.infinity, color: Colors.grey.shade200),
                  // Lado derecho: Teclado Numérico
                  Expanded(
                    flex: 6,
                    child: Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _buildNumPad(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Footer de Totales y Botón
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Valor: ${totalValue.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _showConfirmModal,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0066CC),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text(
                        'Enviar cierre',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
