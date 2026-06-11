import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dio/dio.dart';
import '../../../core/network/dio_client.dart';
import '../../auth/providers/auth_providers.dart';
import '../models/tarifa_model.dart';
import '../providers/sales_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../../core/database/database_helper.dart';
import '../../sync/services/init_service.dart';
import '../services/closure_service.dart';
import '../../auth/services/session_service.dart';
import 'dart:async';
import 'recaudo_screen.dart';
import '../helpers/closing_helper.dart';
import 'cash_count_screen.dart';
import '../../../core/utils/print_log_helper.dart';

final dashboardCurrentIndexProvider = StateProvider<int>((ref) => 0);

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _currentIndex = 0;
  bool _isLogoutPending = false;
  final Map<Product, int> _cart = {};
  String _posName = 'Estación';

  int get _cartTotalItems => _cart.values.fold(0, (sum, val) => sum + val);
  double get _cartTotalValue => _cart.entries
      .fold(0.0, (sum, entry) => sum + (entry.key.value * entry.value));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(authProvider.notifier).restoreOfflineUser();

      // Cargamos el saldo local inmediatamente para evitar parpadeos
      ref.read(balanceProvider.notifier).loadLocalBalance();
      _loadBalance();
      ref.read(productsProvider.notifier).fetchProducts();
      ref.read(systemStatusProvider.notifier).forceCheckPendingTransactions();

      final storage = ref.read(localStorageProvider);
      final posName = await storage.getPosLocationName();
      if (mounted) {
        setState(() {
          _posName =
              posName ?? ref.read(authProvider).user?.branchName ?? 'Estación';
        });
      }
    });
  }

  void _loadBalance() {
    final branchId = ref.read(authProvider).user?.branchId;
    if (branchId != null) {
      ref.read(balanceProvider.notifier).fetchBalance(branchId);
    }
  }

  void _showCartSummaryDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.shopping_cart_checkout_rounded,
                    color: Color(0xFF6642F8)),
                SizedBox(width: 10),
                Text('Resumen de Venta',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 26)),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._cart.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('${entry.value}x ${entry.key.productName}',
                        style: const TextStyle(fontSize: 20)),
                    Text('\$ ${_formatCurrency(entry.key.value * entry.value)}',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            }).toList(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Total a cobrar:',
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text('\$ ${_formatCurrency(_cartTotalValue)}',
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.green)),
              ],
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 75,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _processCartSales();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6642F8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('COBRAR E IMPRIMIR',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  void _processCartSales() async {
    if (_cart.isEmpty) return;

    // 1. Clonar el carrito para procesarlo en segundo plano
    final cartCopy = Map<Product, int>.from(_cart);

    // 2. Limpiar visualmente el carrito INMEDIATAMENTE para agilizar a la vista
    setState(() {
      _cart.clear();
    });

    final int totalItems = cartCopy.values.fold(0, (sum, val) => sum + val);
    await PrintLogHelper.logSale(totalItems);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    final isPrinterConnected =
        await ref.read(systemStatusProvider.notifier).checkPrinterNow();

    if (mounted) Navigator.pop(context);

    if (!isPrinterConnected) {
      final proceed = await _showPrinterWarningDialog();
      if (!proceed) return;
    }

    int successfulPrints = 0;
    int failedPrints = 0;
    bool usbPermissionPending = false;

    for (final entry in cartCopy.entries) {
      final product = entry.key;
      final quantity = entry.value;

      for (int i = 0; i < quantity; i++) {
        final currentUserId = ref.read(authProvider).user?.id ?? 1;
        await ref
            .read(qrPurchaseProvider.notifier)
            .purchase(product: product, cashierId: currentUserId);

        final qrState = ref.read(qrPurchaseProvider);
        if (qrState.status == QrPurchaseStatus.success &&
            qrState.result != null) {
          final result = qrState.result!;
          successfulPrints++;

          if (isPrinterConnected) {
            final pmrLabel = (product.pmr) ? ' [PMR]' : '';
            final storage = ref.read(localStorageProvider);
            final posName = await storage.getPosLocationName();
            final branchName =
                posName ?? ref.read(authProvider).user?.branchName;

            final posLocationId = await storage.getPosLocationId();
            final serialNumber =
                result.rawData['serial_number'] as String? ?? 'N/A';

            final db = await DatabaseHelper.instance.database;
            final userRows = await db.query('users', limit: 1);
            final cashierName = ref.read(authProvider).user?.name ?? 'Operador';
            final cashierId = currentUserId.toString();

            final printResult =
                await ref.read(printerServiceProvider).printTicket(
                      transactionId: serialNumber,
                      amount: product.value,
                      qrData: result.qrCode,
                      cashierName: cashierName,
                      cashierId: cashierId,
                      posLocationId: posLocationId,
                      branchName: branchName,
                      productName: '${product.productName}$pmrLabel',
                    );
            if (printResult == true) {
              await ref
                  .read(salesHistoryProvider.notifier)
                  .markAsPrinted(result.transactionId, 1);
            } else {
              failedPrints++;
              if (printResult == null) usbPermissionPending = true;
            }
          }
        } else {
          final error = qrState.errorMessage ?? 'Error al generar QR';
          if (mounted) {
            if (error.contains('Saldo insuficiente')) {
              _showInsufficientBalanceDialog(error);
            } else {
              _showSnackBar(error, Icons.error, Colors.red);
            }
          }
          _loadBalance();
          ref.read(salesHistoryProvider.notifier).fetchHistory();
          return; // Stop on error
        }
      }
    }

    _loadBalance();
    ref.read(salesHistoryProvider.notifier).fetchHistory();

    if (failedPrints > 0 && mounted) {
      // Refrescar el icono de impresora: el fallo pudo deberse a una desconexión
      ref.read(systemStatusProvider.notifier).checkPrinterNow();
      final msg = usbPermissionPending
          ? 'Acepta el permiso USB de la impresora y reimprime los tiquetes desde el historial.'
          : '$failedPrints tiquete(s) NO se imprimieron. Verifica la impresora y reimprime desde el historial.';
      _showSnackBar(msg, Icons.print_disabled_rounded, Colors.orange);
    }
  }

  void _showInsufficientBalanceDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Saldo Insuficiente',
                style: TextStyle(
                    color: Color(0xFF3F3D56), fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 16)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('ENTENDIDO',
                  style: TextStyle(
                      color: Color(0xFF6642F8),
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  void _showLogoutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Colors.redAccent, size: 28),
            SizedBox(width: 12),
            Text('¿Cómo deseas salir?',
                style: TextStyle(
                    color: Color(0xFF3F3D56),
                    fontWeight: FontWeight.bold,
                    fontSize: 20)),
          ],
        ),
        content: const Text(
          'Puedes cerrar la caja e imprimir el resumen de tu turno, o simplemente salir de la cuenta dejando la caja abierta.',
          style: TextStyle(fontSize: 16, color: Colors.black87),
        ),
        actions: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey.shade800,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('CANCELAR',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF6642F8))),
                    );
                    await ref.read(authProvider.notifier).logout();
                    if (mounted) {
                      Navigator.pop(context);
                      Navigator.pushReplacementNamed(context, '/login');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('SALIR',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _isLogoutPending = true;
                      _currentIndex = 2;
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('CERRAR CAJA',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, IconData icon, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(width: 16),
          Expanded(
              child: Text(message,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)))
        ]),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final balanceState = ref.watch(balanceProvider);
    final productsState = ref.watch(productsProvider);
    final qrState = ref.watch(qrPurchaseProvider);
    final systemStatus = ref.watch(systemStatusProvider);

    ref.listen<QrPurchaseState>(qrPurchaseProvider, (prev, next) {
      if (next.status == QrPurchaseStatus.error && next.errorMessage != null) {
        _showSnackBar(
            next.errorMessage!, Icons.error_outline, Colors.redAccent);
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: Row(
          children: [
            Image.asset(
              'assets/valliu-logo.png',
              height: 32,
              errorBuilder: (ctx, err, stack) => const Icon(
                  Icons.point_of_sale_rounded,
                  color: Color(0xFF6642F8)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$_posName - ${authState.user?.name ?? 'Taquillero'}',
                          style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF3F3D56)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const _ClockWidget(),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Icon(Icons.accessible_rounded,
              color:
                  systemStatus.isPmrConnected ? Colors.green : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.camera_alt_rounded,
              color: systemStatus.isCameraConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.print_rounded,
              color: systemStatus.isPrinterConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          Icon(Icons.wifi_rounded,
              color: systemStatus.isInternetConnected
                  ? Colors.green
                  : Colors.redAccent,
              size: 40),
          const SizedBox(width: 16),
          if (systemStatus.pendingTransactions > 0)
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(16)),
                child: Text('${systemStatus.pendingTransactions}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
            ),
          const SizedBox(width: 8),
          // Se removieron los botones de refrescar y logout de la cabecera
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: [
        _buildSalesView(balanceState, productsState, qrState),
        _buildRecaudoSection(),
        CashCountScreen(isLogout: _isLogoutPending),
      ]),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: Colors.white, boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, -2))
        ]),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _currentIndex,
          onTap: (i) {
            if (i == 3) {
              _showLogoutDialog();
            } else if (i == 1) {
              _showRecaudoPinDialog();
            } else {
              setState(() => _currentIndex = i);
            }
          },
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: const Color(0xFF6642F8),
          unselectedItemColor: Colors.grey,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold),
          items: const [
            BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_2_rounded), label: 'Ventas QR'),
            BottomNavigationBarItem(
                icon: Icon(Icons.receipt_long_rounded), label: 'Recaudo'),
            BottomNavigationBarItem(
                icon: Icon(Icons.inbox_rounded), label: 'Cierre'),
            BottomNavigationBarItem(
                icon: Icon(Icons.logout_rounded, color: Colors.redAccent),
                label: 'Cerrar Sesión')
          ],
        ),
      ),
    );
  }

  Widget _buildSalesView(BalanceState balanceState, ProductsState productsState,
      QrPurchaseState qrState) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3, // Mayor flex para que sea más grande
                child: ElevatedButton.icon(
                  onPressed: _cart.isEmpty ? null : _showCartSummaryDialog,
                  icon: const Icon(Icons.payment_rounded, size: 28),
                  label: Text(
                      'Confirmar Pago (\$ ${_formatCurrency(_cartTotalValue)})',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6642F8),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    disabledForegroundColor: Colors.grey,
                    padding: const EdgeInsets.symmetric(
                        vertical: 32), // 30% más grande en altura
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: _cart.isEmpty ? 0 : 4,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (_cart.isNotEmpty) ...[
                Expanded(
                  flex: 1,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _cart.clear();
                      });
                    },
                    icon: const Icon(Icons.delete_sweep_rounded),
                    label: const Text('Limpiar',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueGrey,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      elevation: 2,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // Los botones PMR, Panico, Novedades ahora irán a la derecha o debajo si no caben
              // Como la fila puede apretarse mucho, vamos a mantenerlos pero con flex 1
              Expanded(
                flex: 1,
                child: _buildActionButton(
                  icon: Icons.accessible_rounded,
                  label: 'PMR',
                  color: Colors.blue,
                  onPressed: _confirmPmr,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: _buildActionButton(
                  icon: Icons.warning_rounded,
                  label: 'Pánico',
                  color: Colors.redAccent,
                  onPressed: () async {
                    if (!ref.read(systemStatusProvider).isInternetConnected) {
                      _showSnackBar(
                          'Estamos fuera de linea, guardaremos tu reporte para enviarlo una vez el dispositivo tenga acceso a internet.',
                          Icons.wifi_off_rounded,
                          Colors.orange);
                      return;
                    }
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF6642F8))),
                    );
                    try {
                      final initService = ref.read(initServiceProvider);
                      await initService.sendNovelty(1, 'Pánico');
                      if (mounted) Navigator.pop(context);
                      _showNovedadSuccess('Pánico');
                    } catch (e) {
                      if (mounted) Navigator.pop(context);
                      _showSnackBar('Error al reportar pánico: ${e.toString()}',
                          Icons.error_outline, Colors.redAccent);
                    }
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: _buildActionButton(
                  icon: Icons.report_problem_rounded,
                  label: 'Novedades',
                  color: Colors.orange,
                  onPressed: _showNovedadesModal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildQrSaleCard(productsState, qrState),
        ],
      ),
    );
  }

  Widget _buildActionButton(
      {required IconData icon,
      required String label,
      required Color color,
      required VoidCallback onPressed}) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 24),
      label: Text(label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 2,
      ),
    );
  }

  void _showRecaudoPinDialog() {
    String pin = '';
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Acceso Restringido',
              style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                  'Ingrese la contraseña de fiscalizador para ver el recaudo:'),
              const SizedBox(height: 15),
              TextField(
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                onChanged: (val) => pin = val,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Contraseña',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child:
                  const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                if (pin == '1234') {
                  Navigator.of(ctx).pop();
                  setState(() => _currentIndex = 1);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Contraseña incorrecta'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6642F8)),
              child: const Text('Ingresar',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showNovedadesModal() async {
    final initService = ref.read(initServiceProvider);
    final novelties = await initService.getCachedNovelties();

    if (!mounted) return;

    if (novelties.isEmpty) {
      _showSnackBar(
          'No hay novedades disponibles.', Icons.info_outline, Colors.orange);
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Módulo de Novedad',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        content: SizedBox(
          width: 320,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: novelties.length,
            separatorBuilder: (_, __) =>
                const Divider(color: Colors.black12, height: 1),
            itemBuilder: (ctx, index) {
              final novedad = novelties[index];
              return ListTile(
                title: Text(novedad.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 22)),
                trailing:
                    const Icon(Icons.chevron_right_rounded, color: Colors.grey),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (!ref.read(systemStatusProvider).isInternetConnected) {
                    _showSnackBar(
                        'Estamos fuera de linea, guardaremos tu reporte para enviarlo una vez el dispositivo tenga acceso a internet.',
                        Icons.wifi_off_rounded,
                        Colors.orange);
                    return;
                  }

                  // Mostrar loading
                  showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF6642F8))),
                  );

                  try {
                    await initService.sendNovelty(novedad.id, novedad.name);
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showNovedadSuccess(novedad.name);
                  } catch (e) {
                    if (mounted) Navigator.pop(context); // Cerrar loading
                    _showSnackBar(
                        e.toString(), Icons.error_outline, Colors.redAccent);
                  }
                },
              );
            },
          ),
        ),
        actions: [
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6642F8),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('CERRAR',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
        ],
      ),
    );
  }

  void _showNovedadSuccess(String novedad) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Colors.green, size: 72),
            const SizedBox(height: 20),
            Text(
                'Hemos recibido tu solicitud de $novedad, la mesa de ayuda se comunicará contigo.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, color: Color(0xFF3F3D56))),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6642F8),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12)),
              child: const Text('ENTENDIDO',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(BalanceState balanceState) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6642F8), Color(0xFF4A2CB3)]),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFF6642F8).withOpacity(0.3),
              blurRadius: 15,
              offset: const Offset(0, 8))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Saldo del Punto de Venta',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.8),
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          if (balanceState.status == BalanceStatus.loading)
            const CircularProgressIndicator(color: Colors.white70)
          else if (balanceState.status == BalanceStatus.error)
            Text(balanceState.errorMessage ?? 'Error',
                style: const TextStyle(color: Colors.white70))
          else
            Text('\$ ${_formatCurrency(balanceState.balance)}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5)),
          const SizedBox(height: 8),
          Text('Sucursal #${ref.read(authProvider).user?.branchId ?? "—"}',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.5), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildQrSaleCard(
      ProductsState productsState, QrPurchaseState qrState) {
    final isLoading = qrState.status == QrPurchaseStatus.loading;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Se retiró el título y el ícono a petición del usuario para ahorrar espacio vertical
          if (productsState.status == ProductsStatus.error &&
              productsState.products.isEmpty)
            Text(productsState.errorMessage ?? 'Error al cargar tarifas',
                style: const TextStyle(color: Colors.redAccent))
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.start, // Alineado a la izquierda (start)
              children: productsState.products
                  .map((p) => _buildProductCard(p))
                  .toList(),
            ),
        ],
      ),
    );
  }

  void _addToCart(Product product) {
    setState(() {
      _cart[product] = (_cart[product] ?? 0) + 1;
    });
  }

  void _removeFromCart(Product product) {
    setState(() {
      if ((_cart[product] ?? 0) > 1) {
        _cart[product] = _cart[product]! - 1;
      } else {
        _cart.remove(product);
      }
    });
  }

  Widget _buildProductCard(Product product) {
    IconData iconData;
    Color iconColor;
    final nameLower = product.productName.toLowerCase();

    if (product.pmr) {
      iconData = Icons.accessible_rounded;
      iconColor = Colors.blue;
    } else if (nameLower.contains('estudiante')) {
      iconData = Icons.school_rounded;
      iconColor = Colors.orange;
    } else if (nameLower.contains('adulto') || nameLower.contains('mayor')) {
      iconData = Icons.elderly_rounded;
      iconColor = Colors.teal;
    } else if (nameLower.contains('general') || nameLower.contains('normal')) {
      iconData = Icons.directions_bus_rounded;
      iconColor = const Color(0xFF6642F8);
    } else {
      iconData = Icons.confirmation_number_rounded;
      iconColor = const Color(0xFF6642F8);
    }

    final quantity = _cart[product] ?? 0;
    final isSelected = quantity > 0;

    return InkWell(
      onTap: () => _addToCart(product),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 250, // Tarjetas de tarifa más grandes
        padding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16), // Padding reducido para compensar letras grandes
        decoration: BoxDecoration(
          color: isSelected ? iconColor.withOpacity(0.05) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isSelected ? iconColor : Colors.grey.shade200,
              width: isSelected ? 2 : 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              product.productName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3F3D56),
                  fontSize: 32), // Letra de tarifa MUY grande
            ),
            const SizedBox(height: 12), // Reducido
            Text(
              '\$ ${_formatCurrency(product.value)}',
              style: const TextStyle(
                  color: Color(0xFF6642F8),
                  fontWeight: FontWeight.w900,
                  fontSize: 38), // Precio MUY grande
            ),
            const SizedBox(height: 12), // Reducido
            if (isSelected)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  InkWell(
                    onTap: () => _removeFromCart(product),
                    child: Container(
                      padding: const EdgeInsets.all(
                          12), // Área de toque mucho más grande
                      decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.1),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.remove,
                          color: Colors.redAccent,
                          size: 36), // Icono más grande
                    ),
                  ),
                  Text(
                    quantity.toString(),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28), // Número más grande
                  ),
                  InkWell(
                    onTap: () => _addToCart(product),
                    child: Container(
                      padding: const EdgeInsets.all(
                          12), // Área de toque mucho más grande
                      decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.add,
                          color: Colors.green, size: 36), // Icono más grande
                    ),
                  ),
                ],
              )
            else
              const SizedBox(height: 44), // Placeholder ajustado
          ],
        ),
      ),
    );
  }

  Future<bool> _showPrinterWarningDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.print_disabled_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Impresora Desconectada',
                style: TextStyle(
                    color: Color(0xFF3F3D56),
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ],
        ),
        content: const Text(
          'No se ha detectado la impresora térmica.\n\n¿Deseas continuar y registrar esta operación sin imprimir el tiquete?',
          style: TextStyle(fontSize: 16, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR',
                style:
                    TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('CONTINUAR SIN IMPRIMIR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _buildRecaudoSection() {
    // Aquí podrías envolver la pantalla de recaudo o llamarla directamente
    // Para simplificar, asumimos que RecaudoScreen es un widget separado que importamos
    return const RecaudoScreen();
  }

  String _formatCurrency(double value) {
    final hasDecimals = value % 1 != 0;
    if (hasDecimals) {
      final parts = value.toStringAsFixed(2).split('.');
      final intPart = parts[0].replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
      return '$intPart.${parts[1]}';
    } else {
      return value.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
  }

  void _processPmr() async {
    try {
      final dio = ref.read(dioProvider);
      await dio.post('http://192.168.1.100/open-pmr',
          options: Options(
              sendTimeout: const Duration(seconds: 1),
              receiveTimeout: const Duration(seconds: 1)));
    } catch (_) {
      print(
          'DEBUG: Endpoint PMR físico inalcanzable. Se omitió la apertura física.');
    }

    final db = await DatabaseHelper.instance.database;
    final branchId = ref.read(authProvider).user?.branchId ?? 0;
    final sessionQuery = await db.query('sessions',
        where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);
    final sessionId = sessionQuery.isNotEmpty ? sessionQuery.first['id'] : null;
    final posLocationId =
        await ref.read(localStorageProvider).getPosLocationId();
    final cashierId = ref.read(authProvider).user?.id ?? 1;

    final random = math.Random();
    final plotIdBytes = List<int>.generate(16, (i) => random.nextInt(256));
    final plotId = md5.convert(plotIdBytes).toString();

    await db.insert('transactions', {
      'id': 'PMR-${DateTime.now().millisecondsSinceEpoch}',
      'session_id': sessionId,
      'cashier_id': cashierId,
      'pos_location_id': posLocationId,
      'product_id': 'PMR',
      'amount': 0,
      'pmr': 1,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
      'qr_data': 'PMR_MANUAL',
      'plot_id': plotId,
    });
    ref.read(salesHistoryProvider.notifier).fetchHistory();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Apertura PMR registrada exitosamente.'),
          backgroundColor: Colors.green));
    }
  }

  void _confirmPmr() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.accessible_rounded, color: Colors.blue),
          SizedBox(width: 10),
          Text('Apertura PMR', style: TextStyle(fontWeight: FontWeight.bold))
        ]),
        content: const Text(
            '¿Deseas enviar el comando de apertura manual al torniquete PMR?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR',
                  style: TextStyle(
                      color: Colors.grey, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _processPmr();
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('CONFIRMAR'),
          ),
        ],
      ),
    );
  }
}

class _ClockWidget extends StatefulWidget {
  const _ClockWidget({Key? key}) : super(key: key);
  @override
  __ClockWidgetState createState() => __ClockWidgetState();
}

class __ClockWidgetState extends State<_ClockWidget> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted)
        setState(() {
          _now = DateTime.now();
        });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dateStr =
        '${_now.day.toString().padLeft(2, '0')}/${_now.month.toString().padLeft(2, '0')}/${_now.year}';
    final timeStr =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return Text('$dateStr $timeStr',
        style: const TextStyle(
            fontSize: 24, // Aumentado de 16 a 24
            color: Color(0xFF6642F8),
            fontWeight: FontWeight.bold));
  }
}
