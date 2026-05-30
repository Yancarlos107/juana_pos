import 'package:flutter/material.dart';
import '../services/epson_epos_service.dart';
import '../services/printer_service.dart';

class EpsonTestScreen extends StatefulWidget {
  const EpsonTestScreen({super.key});

  @override
  State<EpsonTestScreen> createState() => _EpsonTestScreenState();
}

class _EpsonTestScreenState extends State<EpsonTestScreen> {
  final EpsonEposService _epsonService = EpsonEposService();
  final TextEditingController _addressController = TextEditingController(text: '192.168.1.100');
  bool _isLoading = false;

  void _imprimirHola(String targetPrefix) async {
    setState(() => _isLoading = true);

    final target = targetPrefix == 'USB:' ? 'USB:' : '$targetPrefix${_addressController.text}';
    final result = await _epsonService.printTestHola(target);

    if (!mounted) return;
    setState(() => _isLoading = false);

    String message;
    Color color;
    if (result == null) {
      message = 'Permiso USB solicitado. Acepta el diálogo y vuelve a intentar.';
      color = Colors.orange;
    } else if (result) {
      message = 'Comando enviado con éxito a $target';
      color = Colors.green;
    } else {
      message = 'Error al imprimir en $target';
      color = Colors.red;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prueba Impresora Epson TM-T20IIIL'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '1. Conexión USB:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : () => _imprimirHola('USB:'),
              icon: const Icon(Icons.usb),
              label: const Text('IMPRIMIR POR USB'),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '2. Conexión por Red / Bluetooth:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _addressController,
              decoration: const InputDecoration(
                labelText: 'Dirección IP o MAC (Ej: 192.168.1.100 o 00:11:22:33:44:55)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _imprimirHola('TCP:'),
                    icon: const Icon(Icons.wifi),
                    label: const Text('RED (TCP)'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : () => _imprimirHola('BT:'),
                    icon: const Icon(Icons.bluetooth),
                    label: const Text('BLUETOOTH'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              '3. Ticket de prueba:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _isLoading ? null : _imprimirTicketPrueba,
              icon: const Icon(Icons.receipt_long),
              label: const Text('IMPRIMIR TICKET DE PRUEBA'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _mostrarLog,
              icon: const Icon(Icons.bug_report),
              label: const Text('VER LOG DE DIAGNÓSTICO'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey[700],
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            if (_isLoading)
               const Padding(
                 padding: EdgeInsets.only(top: 24.0),
                 child: Center(child: CircularProgressIndicator()),
               )
          ],
        ),
      ),
    );
  }

  void _imprimirTicketPrueba() async {
    setState(() => _isLoading = true);
    final printerService = PrinterService();
    final result = await printerService.printFontAndQrTest();
    if (!mounted) return;
    setState(() => _isLoading = false);

    String message;
    Color color;
    if (result == null) {
      message = 'Permiso USB solicitado. Acepta el diálogo y vuelve a intentar.';
      color = Colors.orange;
    } else if (result) {
      message = 'Ticket de prueba enviado con exito';
      color = Colors.green;
    } else {
      message = 'Error al imprimir ticket de prueba';
      color = Colors.red;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
    );
  }

  void _mostrarLog() async {
    final log = await _epsonService.getEpsonLog();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log Epson SDK'),
        content: SingleChildScrollView(
          child: SelectableText(
            log,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CERRAR'),
          ),
        ],
      ),
    );
  }
}
