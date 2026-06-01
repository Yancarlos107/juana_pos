import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../core/utils/currency_formatter.dart';

/// Widget que representa el ticket de pasaje para impresión térmica.
/// Se renderiza como imagen y se envía a la impresora.
class TicketWidget extends StatelessWidget {
  final int transactionId;
  final double amount;
  final String qrData;
  final String cashierName;
  final String? branchName;
  final String? productName;

  const TicketWidget({
    super.key,
    required this.transactionId,
    required this.amount,
    required this.qrData,
    required this.cashierName,
    this.branchName,
    this.productName,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    return Container(
      width: 384, // Ancho estándar para papel de 58mm (203 DPI)
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // === Encabezado ===
          const Text(
            'Juana',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: Colors.black,
              letterSpacing: 4,
            ),
          ),
          const Text(
            'Red de Recarga',
            style: TextStyle(
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
          if (branchName != null)
            Text(
              '$cashierName - $branchName',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          const SizedBox(height: 6),
          _divider(),
          const SizedBox(height: 6),

          // === Datos de transacción ===
          _infoRow('Fecha', dateStr),
          _infoRow('Hora', timeStr),
          _infoRow('Transaccion', '#$transactionId'),
          _infoRow('Cajero', cashierName),
          const SizedBox(height: 6),
          _divider(),
          const SizedBox(height: 8),

          // === Tipo de pasaje ===
          const Text(
            'PASAJE DE TRANSPORTE',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          if (productName != null)
            Text(
              productName!,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          const SizedBox(height: 8),

          // === Monto ===
          Text(
            '\$ ${CurrencyFormatter.format(amount)}',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          _divider(),
          const SizedBox(height: 10),

          // === QR Code ===
          QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
          ),
          const SizedBox(height: 6),
          Text(
            qrData.length > 35 ? '${qrData.substring(0, 35)}...' : qrData,
            style: const TextStyle(fontSize: 8, color: Colors.black45),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          _divider(),
          const SizedBox(height: 6),

          // === Pie ===
          const Text(
            'Gracias por usar Juana!',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          const Text(
            'Conserve este recibo como\ncomprobante de su pasaje.',
            style: TextStyle(fontSize: 10, color: Colors.black54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          _divider(),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: double.infinity,
      height: 1,
      color: Colors.black26,
      margin: const EdgeInsets.symmetric(vertical: 2),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black)),
        ],
      ),
    );
  }
}

/// Widget de ticket de cierre de caja.
class ClosingTicketWidget extends StatelessWidget {
  final String cashierName;
  final String branchName;
  final int totalTransactions;
  final double totalAmount;
  final String startTime;
  final String endTime;

  const ClosingTicketWidget({
    super.key,
    required this.cashierName,
    required this.branchName,
    required this.totalTransactions,
    required this.totalAmount,
    required this.startTime,
    required this.endTime,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';

    return Container(
      width: 384, // Ancho estándar para papel de 58mm (203 DPI)
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Juana',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                  letterSpacing: 4)),
          const Text('CIERRE DE CAJA',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black)),
          Text(branchName,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          Container(height: 1, color: Colors.black26),
          const SizedBox(height: 6),
          _row('Fecha', dateStr),
          _row('Cajero', cashierName),
          _row('Inicio', startTime),
          _row('Cierre', endTime),
          const SizedBox(height: 6),
          Container(height: 1, color: Colors.black26),
          const SizedBox(height: 6),
          _row('Transacciones', '$totalTransactions'),
          const SizedBox(height: 8),
          Text(
            'TOTAL: \$ ${CurrencyFormatter.format(totalAmount)}',
            style: const TextStyle(
                fontSize: 24, fontWeight: FontWeight.w900, color: Colors.black),
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: Colors.black26),
          const SizedBox(height: 4),
          const Text('Documento generado automaticamente',
              style: TextStyle(fontSize: 8, color: Colors.black38)),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
          Text(value,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.black)),
        ],
      ),
    );
  }
}
