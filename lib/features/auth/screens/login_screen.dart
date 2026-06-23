import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import '../providers/auth_providers.dart';
import '../../printer/services/printer_service.dart';
import '../../../core/storage/local_storage_repository.dart';
import '../widgets/location_selection_dialog.dart';
import '../../sales/services/closure_service.dart';
import '../../sales/helpers/closing_helper.dart';
import '../../../core/database/database_helper.dart';
import '../../monitoring/services/system_status_service.dart';
import '../../../core/network/dio_client.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';
import 'package:app_settings/app_settings.dart';
import '../../../core/widgets/kiosk_logo_button.dart';
import '../../../core/services/kiosk_service.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/utils/device_utils.dart';
import '../../../core/utils/crypto_utils.dart';
import 'package:barcode_scan2/barcode_scan2.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _pinController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _userFocusNode = FocusNode();
  final _pinFocusNode = FocusNode();

  TextEditingController? _activeController;
  bool _obscurePin = true;
  bool _hasUnclosedSales = false;
  String _macAddress = '';
  bool _isFirstLogin = false;
  bool _isLoadingLogin = false;

  @override
  void initState() {
    super.initState();
    _activeController = _pinController;
    _checkFirstLogin();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUnclosedSales();
      _loadMacAddress();
    });
    _userFocusNode.addListener(() {
      if (_userFocusNode.hasFocus) {
        setState(() => _activeController = _emailController);
      }
    });
    _pinFocusNode.addListener(() {
      if (_pinFocusNode.hasFocus) {
        setState(() => _activeController = _pinController);
      }
    });

    Future.microtask(() {
      if (mounted) {
        ref.read(reviewerNameProvider.notifier).state = null;
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  Future<void> _checkFirstLogin() async {
    final storage = ref.read(localStorageProvider);
    final isFirst = await storage.getIsFirstLogin();
    if (mounted) {
      setState(() {
        _isFirstLogin = isFirst;
        if (isFirst) {
          _activeController = _emailController;
        }
      });
    }
  }

  Future<void> _loadMacAddress() async {
    final mac = await DeviceUtils.getMacAddress();
    if (mounted) {
      setState(() {
        _macAddress = mac ?? 'Desconocida';
      });
    }
  }

  @override
  void dispose() {
    _userFocusNode.dispose();
    _pinFocusNode.dispose();
    _emailController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _checkUnclosedSales() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.query(
        'transactions',
        where: 'is_closed = 0 AND product_id != ? AND product_id != ?',
        whereArgs: ['CIERRE DE CAJA', 'APERTURA DE CAJA'],
        limit: 1,
      );
      if (mounted) {
        setState(() {
          _hasUnclosedSales = result.isNotEmpty;
        });
      }
    } catch (_) {}
  }

  Future<void> _showPendingSalesModal() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF6642F8))),
    );

    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.rawQuery('''
        SELECT 
          u.name, 
          COUNT(t.local_id) as pending_count, 
          SUM(t.amount) as pending_amount
        FROM transactions t
        LEFT JOIN users u ON t.cashier_id = u.id
        WHERE t.is_closed = 0 AND t.product_id != 'CIERRE DE CAJA' AND t.product_id != 'APERTURA DE CAJA' AND t.product_id != 'PMR' AND t.product_id != 'INGRESO_FISCALIZADOR'
        GROUP BY t.cashier_id
        HAVING pending_count > 0
      ''');

      if (mounted) Navigator.pop(context); // quitar loader

      if (result.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'La caja está limpia. Ningún usuario tiene ventas pendientes de cierre.'),
            backgroundColor: Colors.green,
          ));
        }
        return;
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.account_balance_wallet_rounded,
                    color: Colors.orange, size: 28),
                SizedBox(width: 12),
                Text('Ventas Pendientes por Usuario',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ],
            ),
            content: SizedBox(
              width: 450,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: result.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (ctx, i) {
                  final row = result[i];
                  final name = row['name']?.toString() ?? 'Cajero Desconocido';
                  final count = row['pending_count'] as int? ?? 0;
                  final amount =
                      (row['pending_amount'] as num?)?.toDouble() ?? 0;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Color(0xFF3F3D56))),
                    subtitle: Text('Ventas sin cerrar: $count'),
                    trailing: Text('\$${amount.toStringAsFixed(2)}',
                        style: const TextStyle(
                            color: Color(0xFF6642F8),
                            fontWeight: FontWeight.bold,
                            fontSize: 18)),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('ENTENDIDO',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _scanLoginQR() async {
    try {
      final result = await BarcodeScanner.scan(
        options: const ScanOptions(
          strings: {
            'cancel': 'Cancelar',
            'flash_on': 'Flash on',
            'flash_off': 'Flash off',
          },
          restrictFormat: [BarcodeFormat.qr],
        ),
      );

      if (result.type == ResultType.Barcode && result.rawContent.isNotEmpty) {
        final scannedCode = result.rawContent;
        try {
          final decrypted =
              CryptoUtils.decryptLoginQR(scannedCode, 'juana-777');
          final parts = decrypted.split('#');
          if (parts.length >= 2) {
            _pinController.text = parts[1]; // Use password part as PIN
            await _login();
          } else {
            _showErrorSnackBar('Formato QR inválido (sin clave).');
          }
        } catch (e) {
          _showErrorSnackBar('Error descifrado:\n$e');
        }
      }
    } catch (e) {
      _showErrorSnackBar('Error de cámara: $e');
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Future<void> _login() async {
    if (_isLoadingLogin) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoadingLogin = true);

    try {
      // Limpiar cualquier estado residual de fiscalizador ANTES de iniciar sesión con un usuario normal
    ref.read(reviewerNameProvider.notifier).state = null;

    if (_isFirstLogin) {
      await ref.read(authProvider.notifier).login(
            _emailController.text.trim(),
            _pinController.text.trim(),
          );
      
      final authResult = ref.read(authProvider);
      if (mounted && authResult.status == AuthStatus.authenticated) {
        await ref.read(localStorageProvider).setFirstLoginCompleted();
      }
    } else {
      final pin = _pinController.text.trim();
      final db = await DatabaseHelper.instance.database;
      final pinHash = sha1.convert(utf8.encode(pin)).toString();

      final results = await db.query('users',
          where: 'password_hash = ?', whereArgs: [pinHash], limit: 1);

      if (results.isEmpty) {
        _showErrorSnackBar('PIN incorrecto o no autorizado');
        _pinController.clear();
        _pinFocusNode.requestFocus();
        return;
      }

      final email = results.first['email']?.toString() ?? '01';

      await ref.read(authProvider.notifier).login(email, pin);
    }

    final authState = ref.read(authProvider);
    // Si llegamos aquí sin excepción, solicitamos el Punto de Venta
    if (mounted && authState.status == AuthStatus.authenticated) {
      // 1. (Eliminado: Petición directa al servidor RC171 para evitar duplicidad, ahora se encola abajo)

      // 2. Capturar y guardar GPS (Solo se pide una vez al iniciar sesión)
      try {
        bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (serviceEnabled) {
          LocationPermission permission = await Geolocator.checkPermission();
          if (permission == LocationPermission.denied) {
            permission = await Geolocator.requestPermission();
          }
          if (permission == LocationPermission.whileInUse ||
              permission == LocationPermission.always) {
            Position position = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.medium);
            await ref
                .read(localStorageProvider)
                .saveGpsLocation(position.latitude, position.longitude);
            print(
                'DEBUG: GPS capturado en login: ${position.latitude}, ${position.longitude}');
          }
        }
      } catch (e) {
        print('DEBUG: Error capturando GPS en login: $e');
      }

      // 3. Pedimos punto de venta (UI)
      final success = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const LocationSelectionDialog(),
      );

      if (mounted) {
        if (success == true) {
          if (_isFirstLogin) {
            // Aseguramiento del PIN en SQLite para evitar que la inicialización lo borre o corrompa el hash
            try {
              final pin = _pinController.text.trim();
              if (pin.isNotEmpty) {
                final db = await DatabaseHelper.instance.database;
                final userId = authState.user?.id;
                final pinHash = sha1.convert(utf8.encode(pin)).toString();

                if (userId != null) {
                  // Actualizamos el hash si el usuario fue insertado por InitService
                  final updatedCount = await db.update(
                    'users',
                    {'password_hash': pinHash},
                    where: 'id = ?',
                    whereArgs: [userId],
                  );

                  // Si el usuario fue borrado por completo y no venía en la lista de InitService, lo reinsertamos
                  if (updatedCount == 0) {
                    final user = authState.user!;
                    final email = _emailController.text.trim();
                    await db.insert(
                      'users',
                      {
                        'id': user.id,
                        'email': email,
                        'password_hash': pinHash,
                        'name': user.name,
                        'branch_id': user.branchId,
                        'roles': user.roles.join(','),
                      },
                    );
                  }
                }
              }
            } catch (e) {
              print('DEBUG: Error asegurando PIN post-login: $e');
            }

            setState(() => _isFirstLogin = false);
            _emailController.clear();
            _pinController.clear();
          }

          // 4. Guardamos la transacción offline de Apertura de Caja para que se sincronice en la RC171
          try {
            final db = await DatabaseHelper.instance.database;
            final posLocationId =
                await ref.read(localStorageProvider).getPosLocationId();
            final gpsData =
                await ref.read(localStorageProvider).getGpsLocation();
            final cashierId = authState.user?.id ?? 1;

            final random = math.Random();
            final plotIdBytes =
                List<int>.generate(16, (i) => random.nextInt(256));
            final plotId = md5.convert(plotIdBytes).toString();

            await db.insert('transactions', {
              'id':
                  'open-${DateTime.now().microsecondsSinceEpoch}-$posLocationId',
              'session_id': null,
              'cashier_id': cashierId,
              'pos_location_id': posLocationId,
              'product_id': 'APERTURA DE CAJA',
              'amount': 0.0,
              'pmr': 0,
              'status': 'pending',
              'created_at': DateTime.now().toIso8601String(),
              'qr_data': '', // Token vacío
              'print_status': 0,
              'lat': gpsData?['lat'],
              'lon': gpsData?['lon'],
              'plot_id': plotId,
            });
            print(
                'DEBUG: Transacción de APERTURA DE CAJA guardada localmente para desencole (RC174).');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Caja abierta offline exitosamente (RC174)'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } catch (e) {
            print('DEBUG: Error al guardar APERTURA DE CAJA: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error guardando RC174: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }

          Navigator.pushReplacementNamed(context, '/dashboard');
        } else {
          // Si el usuario cancela, cerramos la sesión parcial
          await ref.read(authProvider.notifier).logout(ref);
        }
      }
    }
    } finally {
      if (mounted) setState(() => _isLoadingLogin = false);
    }
  }

  Future<void> _printLastClosure() async {
    if (_pinController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ingresa tu PIN para autorizar la impresión',
              style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    print('DEBUG: Iniciando _printLastClosure con validación de usuario...');
    final printer = ref.read(printerServiceProvider);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF6642F8)),
                SizedBox(height: 16),
                Text('Validando y buscando cierre...',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );

    // 1. Validar Credenciales via PIN
    final pin = _pinController.text.trim();
    final db = await DatabaseHelper.instance.database;
    final pinHash = sha1.convert(utf8.encode(pin)).toString();

    final resultsUser = await db.query('users',
        where: 'password_hash = ?', whereArgs: [pinHash], limit: 1);

    if (resultsUser.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      _showErrorSnackBar('PIN incorrecto o no autorizado');
      _pinController.clear();
      _pinFocusNode.requestFocus();
      return;
    }

    final email = resultsUser.first['email']?.toString() ?? '01';

    await ref.read(authProvider.notifier).login(email, pin);

    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      if (mounted) Navigator.of(context).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error de red o cuenta inactiva',
                style: TextStyle(fontWeight: FontWeight.bold)),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // 2. Revisar si hay ventas pendientes por cerrar
    bool success = false;
    String errorMessage = 'No hay cierres guardados';

    try {
      final db = await DatabaseHelper.instance.database;
      final currentCashierId = authState.user?.id ?? 1;

      final storage = ref.read(localStorageProvider);
      final branchId = await storage.getBranchId() ?? 0;
      final sessionQuery = await db.query('sessions',
          where: 'status = ? AND branch_id = ?', whereArgs: ['open', branchId]);

      if (sessionQuery.isNotEmpty) {
        final sessionId = sessionQuery.first['id'] as int;

        final unclosedSales = await db.query('transactions',
            where:
                'session_id = ? AND cashier_id = ? AND is_closed = 0 AND product_id NOT IN (?, ?)',
            whereArgs: [
              sessionId,
              currentCashierId,
              'CIERRE DE CAJA',
              'APERTURA DE CAJA'
            ]);

        if (unclosedSales.isNotEmpty) {
          if (mounted)
            Navigator.of(context).pop(); // Cierra el loader de "buscando"
          await _showPendingClosureDialog(
              currentCashierId, sessionId, unclosedSales);
          return; // Detiene la reimpresión y delega al flujo de nuevo cierre
        }
      }

      // 3. Proceder con la reimpresión normal si NO hay ventas pendientes
      bool success = false;
      String errorMessage = 'No hay cierres guardados';

      final results = await db.query(
        'transactions',
        where: 'product_id = ? AND cashier_id = ?',
        whereArgs: ['CIERRE DE CAJA', currentCashierId],
        orderBy: 'created_at DESC',
        limit: 1,
      );

      if (results.isNotEmpty) {
        final closure = results.first;
        final qrData = closure['qr_data']?.toString() ?? '';
        final jsonStr = utf8.decode(base64Decode(qrData));
        final data = jsonDecode(jsonStr);
        final sessionId = closure['session_id'];
        final cashierId = closure['cashier_id'];
        final createdAt = closure['created_at'];

        // Cargar nombres de productos
        final productsQuery = await db.query('products');
        final Map<String, String> productNames = {
          for (var p in productsQuery)
            p['id'].toString():
                p['product_name']?.toString() ?? "Tarifa \${p['id']}"
        };

        // 1. Reconstruir desglose del cajero (Breakdown)
        // Buscamos si hubo un cierre anterior en la misma sesión para este cajero
        final previousClosure = await db.query(
          'transactions',
          where:
              'session_id = ? AND cashier_id = ? AND product_id = ? AND created_at < ?',
          whereArgs: [sessionId, cashierId, 'CIERRE DE CAJA', createdAt],
          orderBy: 'created_at DESC',
          limit: 1,
        );
        String? previousCreatedAt;
        if (previousClosure.isNotEmpty) {
          previousCreatedAt = previousClosure.first['created_at']?.toString();
        }

        String breakdownWhere =
            '(session_id = ? OR session_id IS NULL) AND cashier_id = ? AND product_id != ? AND product_id != ? AND product_id != ? AND created_at <= ?';
        List<Object?> breakdownArgs = [
          sessionId,
          cashierId,
          'CIERRE DE CAJA',
          'APERTURA DE CAJA',
          'INGRESO_FISCALIZADOR',
          createdAt
        ];

        if (previousCreatedAt != null) {
          breakdownWhere += ' AND created_at > ?';
          breakdownArgs.add(previousCreatedAt);
        }

        final unclosedSales = await db.query('transactions',
            where: breakdownWhere, whereArgs: breakdownArgs);

        Map<String, int> breakdownQty = {};
        Map<String, double> breakdownTotal = {};
        for (final sale in unclosedSales) {
          if (sale['product_id'] == 'PMR') continue;
          final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
          final productId = sale['product_id']?.toString() ?? 'Desc.';
          breakdownQty[productId] = (breakdownQty[productId] ?? 0) + 1;
          breakdownTotal[productId] = (breakdownTotal[productId] ?? 0) + amount;
        }

        List<String> breakdownLines = [];
        breakdownQty.forEach((pId, qty) {
          final t = breakdownTotal[pId] ?? 0;
          final pName = productNames[pId] ?? 'Tarifa $pId';
          final qtyStr = '${qty}x'.padRight(4);
          final nameStr =
              pName.length > 15 ? pName.substring(0, 15) : pName.padRight(15);
          final valStr = '\$${CurrencyFormatter.format(t)}'.padLeft(8);
          breakdownLines.add('$qtyStr $nameStr $valStr');
        });

        // 2. Reconstruir Resumen del Día (Arrastre)
        final lastSaleQuery = await db.query(
          'transactions',
          where:
              '(session_id = ? OR session_id IS NULL) AND cashier_id = ? AND product_id NOT IN (?, ?, ?, ?)',
          whereArgs: [
            sessionId,
            cashierId,
            'CIERRE DE CAJA',
            'APERTURA DE CAJA',
            'INGRESO_FISCALIZADOR',
            'PMR'
          ],
          orderBy: 'created_at DESC',
          limit: 1,
        );
        String? limitDate =
            createdAt?.toString(); // Fallback al cierre si no tiene ventas
        if (lastSaleQuery.isNotEmpty) {
          limitDate = lastSaleQuery.first['created_at']?.toString() ??
              createdAt?.toString();
        }

        final todayStr = "${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}-${DateTime.now().day.toString().padLeft(2, '0')}";
        final allSales = await db.query('transactions',
            where:
                'created_at LIKE ? AND product_id != ? AND product_id != ? AND product_id != ? AND created_at <= ?',
            whereArgs: [
              '${todayStr}%',
              'CIERRE DE CAJA',
              'APERTURA DE CAJA',
              'INGRESO_FISCALIZADOR',
              limitDate
            ]);

        int dayCount = 0;
        double dayTotalAmount = 0;
        Map<String, int> dayBreakdownQty = {};
        Map<String, double> dayBreakdownTotal = {};

        for (final sale in allSales) {
          if (sale['product_id'] == 'PMR') continue;
          final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
          final productId = sale['product_id']?.toString() ?? 'Desc.';
          dayCount++;
          dayTotalAmount += amount;
          dayBreakdownQty[productId] = (dayBreakdownQty[productId] ?? 0) + 1;
          dayBreakdownTotal[productId] =
              (dayBreakdownTotal[productId] ?? 0) + amount;
        }

        List<String> dayBreakdownLines = [];
        dayBreakdownQty.forEach((pId, qty) {
          final t = dayBreakdownTotal[pId] ?? 0;
          final pName = productNames[pId] ?? 'Tarifa $pId';
          final qtyStr = '${qty}x'.padRight(4);
          final nameStr =
              pName.length > 15 ? pName.substring(0, 15) : pName.padRight(15);
          final valStr = '\$${CurrencyFormatter.format(t)}'.padLeft(8);
          dayBreakdownLines.add('$qtyStr $nameStr $valStr');
        });

        final daySummary = {
          'totalTransactions': dayCount,
          'totalAmount': dayTotalAmount,
          'breakdown': dayBreakdownLines
        };

        Map<String, dynamic>? cashList;
        if (data.containsKey('coins_total') &&
            data.containsKey('bills_total')) {
          cashList = {
            'coins_total': data['coins_total'],
            'bills_total': data['bills_total'],
          };
        }
        final double? cash =
            data['cash'] != null ? (data['cash'] as num).toDouble() : null;
        final double? balance = data['balance'] != null
            ? (data['balance'] as num).toDouble()
            : null;

        final userEmail = ref.read(authProvider).user?.email ?? '01';
        final currentUserCode = userEmail.split('@').first;

        bool shouldPrintBreakdown = false;
        if (cashList == null && cash == null) {
          // Si no hay cash ni cashList, fue fiscalizador
          shouldPrintBreakdown = true;
        } else if (cash != null && cash > 0) {
          // Si hay cash y es mayor a 0, fue un cajero con efectivo
          shouldPrintBreakdown = true;
        }

        final posName =
            await ref.read(localStorageProvider).getPosLocationName();
        final branchName = posName ?? authState.user?.branchName ?? 'Sucursal';

        final endDate = data["d"]?.toString() ?? 'Fecha no disp.';
        final endTimeStr = data["t"]?.toString() ?? '';

        final printResult = await printer.printClosingTicket(
          cashierName: data['c']?.toString() ?? 'Operador',
          cashierId: currentUserCode,
          branchName: branchName,
          totalTransactions: data['q'] ?? 0,
          totalAmount: (data['a'] as num?)?.toDouble() ?? 0,
          startTime: 'Turno',
          endTime: '$endDate $endTimeStr'.trim(),
          qrData: qrData,
          breakdown: shouldPrintBreakdown ? breakdownLines : null,
          pmrCount: data['pmr_q'] ?? 0,
          reprintsCount: 1,
          daySummary: daySummary,
          cashList: cashList,
          cash: cash,
          balance: balance,
        );
        success = printResult ?? false;

        if (printResult == null) {
          errorMessage = 'Acepta el permiso USB e intenta de nuevo';
        } else if (!success) {
          errorMessage = 'Error: No se detectó impresora USB';
        }
      }
    } catch (e) {
      errorMessage = 'Error al leer el cierre: $e';
    }

    // 3. Cerrar sesión automáticamente tras autorizar la impresión
    await ref.read(authProvider.notifier).logout(ref);

    if (mounted) Navigator.of(context).pop();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(success ? '¡Cierre impreso exitosamente!' : errorMessage),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _showPendingClosureDialog(int cashierId, int sessionId,
      List<Map<String, dynamic>> unclosedSales) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 32),
            SizedBox(width: 10),
            Text('Ventas Pendientes',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Hay ventas pendientes por cerrar en tu turno.\n¿Deseas confirmar el cierre de caja ahora mismo?',
          style: TextStyle(fontSize: 18),
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
              backgroundColor: const Color(0xFF6642F8),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('SÍ, CERRAR CAJA',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      double totalSistema = 0;
      for (final sale in unclosedSales) {
        if (sale['product_id'] == 'PMR') continue;
        final amount = (sale['amount'] as num?)?.toDouble() ?? 0;
        totalSistema += amount;
      }

      ClosingHelper.performClosing(
        context,
        ref,
        false, // isLogout
        isArrastre: true,
        cash: 0,
        balance: -totalSistema,
      ).then((_) {
        _pinController.clear();
        _pinFocusNode.requestFocus();
      });
    } else {
      _pinController.clear();
      _pinFocusNode.requestFocus();
    }
  }

  Future<void> _showSupportOptions() async {
    final bool isDeviceOwner = await KioskService.isDeviceOwner();
    final bool isInKiosk = await KioskService.isInKioskMode();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Opciones de Soporte',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.settings, color: Color(0xFF6642F8)),
              title: const Text('Ajustes del Sistema'),
              subtitle: isInKiosk
                  ? const Text('Sale del kiosco para permitir el acceso')
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                // Con el Lock Task activo, Android bloquea abrir Settings:
                // hay que salir del kiosco primero.
                await KioskService.stop();
                AppSettings.openAppSettings();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.file_download, color: Color(0xFF6642F8)),
              title: const Text('Exportar Tramas a TXT'),
              onTap: () {
                Navigator.pop(ctx);
                _exportTransactions();
              },
            ),
            ListTile(
              leading: const Icon(Icons.sync_problem, color: Colors.orange),
              title: const Text('Forzar Reenvío de Ventas (Debug)'),
              subtitle: const Text(
                  'Marca las ventas enviadas como pendientes para reintentar'),
              onTap: () async {
                Navigator.pop(ctx);
                final todayStr = DateTime.now().toIso8601String().split('T')[0];
                final db = await DatabaseHelper.instance.database;
                int count = await db.rawUpdate('''
                  UPDATE transactions 
                  SET status = 'pending' 
                  WHERE status = 'synced' 
                    AND product_id NOT IN ('CIERRE DE CAJA', 'APERTURA DE CAJA', 'INGRESO_FISCALIZADOR', 'PMR')
                    AND created_at LIKE ?
                ''', ['$todayStr%']);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Se marcaron $count ventas para reenvío'),
                    backgroundColor: Colors.green,
                  ));
                }
                ref
                    .read(systemStatusProvider.notifier)
                    .forceCheckPendingTransactions();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link, color: Color(0xFF6642F8)),
              title: const Text('Vincular Ventas Huérfanas'),
              subtitle: const Text(
                  'Asigna las ventas sin sesión a la sesión abierta actual'),
              onTap: () async {
                Navigator.pop(ctx);
                final db = await DatabaseHelper.instance.database;
                
                final lastSaleQuery = await db.query('transactions',
                    where: 'session_id IS NOT NULL',
                    orderBy: 'created_at DESC',
                    limit: 1);
                    
                if (lastSaleQuery.isNotEmpty) {
                  final sessionId = lastSaleQuery.first['session_id'] as int;
                  int count = await db.rawUpdate('''
                    UPDATE transactions 
                    SET session_id = ? 
                    WHERE session_id IS NULL AND is_closed = 0
                  ''', [sessionId]);
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Se vincularon $count ventas a la última sesión ($sessionId)'),
                      backgroundColor: Colors.green,
                    ));
                  }
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('No hay historial de sesiones para vincular las ventas'),
                      backgroundColor: Colors.orange,
                    ));
                  }
                }
              },
            ),
            if (isDeviceOwner && !isInKiosk)
              ListTile(
                leading: const Icon(Icons.lock, color: Color(0xFF6642F8)),
                title: const Text('Activar Modo Kiosco'),
                subtitle: const Text('Vuelve a bloquear el dispositivo'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await KioskService.start();
                },
              ),
            if (isDeviceOwner)
              ListTile(
                leading: const Icon(Icons.lock_open, color: Colors.red),
                title: const Text('Liberar Dispositivo',
                    style: TextStyle(color: Colors.red)),
                subtitle: const Text(
                    'Permite desinstalar la app. Requiere ADB para revertir.'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmClearDeviceOwner();
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CERRAR', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  void _confirmClearDeviceOwner() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Liberar Dispositivo?',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
            'La app dejará de ser Device Owner: el modo kiosco quedará '
            'desactivado y la app podrá desinstalarse desde Ajustes.\n\n'
            'Para volver a bloquear el dispositivo será necesario '
            'aprovisionarlo de nuevo por ADB.\n\n'
            'Use esta opción solo para desinstalar o cambiar de versión.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final ok = await KioskService.clearDeviceOwner();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(ok
                      ? 'Dispositivo liberado. La app ya puede desinstalarse.'
                      : 'No se pudo liberar el dispositivo.'),
                  backgroundColor: ok ? Colors.green : Colors.red,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('LIBERAR'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportTransactions() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final db = await DatabaseHelper.instance.database;
      final txs = await db.query('transactions');

      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final sb = StringBuffer();
      sb.writeln('=== EXPORTACIÓN DE TRAMAS ===');
      sb.writeln('Fecha: ${DateTime.now().toIso8601String()}');
      sb.writeln('Total registros: ${txs.length}');
      sb.writeln('==============================\n');

      for (final tx in txs) {
        sb.writeln(jsonEncode(tx));
      }

      File? file;
      String finalPath = '';

      try {
        // Opción 1: Carpeta de descargas pública
        final Directory downDir = Directory('/storage/emulated/0/Download');
        if (downDir.existsSync()) {
          file = File('${downDir.path}/tramas_exportadas.txt');
          await file.writeAsString(sb.toString());
          finalPath = file.path;
        } else {
          throw Exception('Download no existe');
        }
      } catch (e) {
        // Opción 2: Carpeta pública de la app en Android/data/ (Visible al conectar por USB o gestores de archivos)
        try {
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            file = File('${extDir.path}/tramas_exportadas.txt');
            await file.writeAsString(sb.toString());
            finalPath = file.path;
          } else {
            throw Exception('Directorio externo no disponible');
          }
        } catch (e2) {
          // Opción 3: Carpeta interna estricta (invisible sin root)
          final appDir = await getApplicationDocumentsDirectory();
          file = File('${appDir.path}/tramas_exportadas.txt');
          await file.writeAsString(sb.toString());
          finalPath = file.path;
        }
      }

      if (mounted) {
        Navigator.pop(context); // Cerrar loader
        showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
                  title: const Text('Tramas Guardadas'),
                  content: SizedBox(
                    width: double.maxFinite,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Archivo guardado en:',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          SelectableText(finalPath,
                              style: const TextStyle(color: Colors.blue)),
                          const SizedBox(height: 10),
                          const Divider(),
                          const Text('Contenido:'),
                          const SizedBox(height: 10),
                          SelectableText(sb.toString()),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('CERRAR'),
                    )
                  ],
                ));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error al exportar: $e',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  void _onNumPadTap(String value) {
    if (_activeController == null) return;
    final text = _activeController!.text;
    if (value == 'C') {
      _activeController!.clear();
    } else if (value == '⌫') {
      if (text.isNotEmpty) {
        _activeController!.text = text.substring(0, text.length - 1);
      }
    } else {
      _activeController!.text += value;
    }
  }

  Widget _buildNumPad(AuthState authState) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Column(
        children: [
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.3,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 1; i <= 9; i++) _buildNumButton(i.toString()),
              _buildNumButton('C', color: Colors.redAccent),
              _buildNumButton('0'),
              _buildNumButton('⌫', icon: Icons.backspace_outlined),
            ],
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: authState.status == AuthStatus.loading ? null : _login,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 64),
              backgroundColor: const Color(0xFF6642F8),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: authState.status == AuthStatus.loading
                ? const SizedBox(
                    height: 28,
                    width: 28,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 3))
                : const Text('INICIAR SESIÓN',
                    style: TextStyle(
                        fontSize: 22, // Aumentado de 18 a 22
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1)),
          ),
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
              ? Icon(icon, color: color ?? const Color(0xFF3F3D56), size: 28)
              : Text(label,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: color ?? const Color(0xFF3F3D56))),
        ),
      ),
    );
  }

  Widget _buildForm() {
    final authState = ref.watch(authProvider);

    return Form(
      key: _formKey,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: KioskLogoButton(
              pin: '1510',
              requiredTaps: 3,
              onSuccess: _showSupportOptions,
              child: Image.asset(
                'assets/valliu-logo.png',
                height: 90,
                errorBuilder: (ctx, err, stack) => Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6642F8).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.point_of_sale_rounded,
                      color: Color(0xFF6642F8), size: 40),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Bienvenido a Juana',
            style: TextStyle(
              fontSize: 32, // Aumentado de 26 a 32
              fontWeight: FontWeight.w900,
              color: Color(0xFF3F3D56),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inicia sesión con tu código',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.grey, fontSize: 18), // Aumentado de 15 a 18
          ),
          const SizedBox(height: 36),
          if (_isFirstLogin) ...[
            TextFormField(
              controller: _emailController,
              focusNode: _userFocusNode,
              readOnly: true,
              showCursor: true,
              onTap: () => setState(() => _activeController = _emailController),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Usuario / Identificación',
                prefixIcon: const Icon(Icons.person_outline),
                filled: _activeController == _emailController,
                fillColor: const Color(0xFF6642F8).withOpacity(0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF6642F8), width: 2),
                ),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Requerido';
                if (v.length < 4) return 'Mínimo 4 caracteres';
                return null;
              },
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _pinController,
              focusNode: _pinFocusNode,
              readOnly: true,
              showCursor: true,
              obscureText: _obscurePin,
              onTap: () => setState(() => _activeController = _pinController),
              style: const TextStyle(
                  fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: 'Contraseña',
                prefixIcon: const Icon(Icons.lock_outline),
                filled: _activeController == _pinController,
                fillColor: const Color(0xFF6642F8).withOpacity(0.05),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscurePin ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFF6642F8), width: 2),
                ),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Requerido';
                if (v.length < 4) return 'Mínimo 4 caracteres';
                return null;
              },
            ),
          ] else ...[
            TextFormField(
              controller: _pinController,
              focusNode: _pinFocusNode,
              readOnly: true,
              showCursor: true,
              obscureText: _obscurePin,
              maxLength: 4,
              onTap: () => setState(() => _activeController = _pinController),
              style: const TextStyle(
                  fontSize: 48, letterSpacing: 24, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: "", // Ocultar el contador de maxLength
                labelText: 'PIN de Acceso',
                prefixIcon: const Icon(Icons.lock_outline, size: 32),
                filled: true,
                fillColor: const Color(0xFF6642F8).withOpacity(0.05),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscurePin ? Icons.visibility_off : Icons.visibility,
                      size: 28),
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide:
                      const BorderSide(color: Color(0xFF6642F8), width: 3),
                ),
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Requerido';
                if (v.length != 4) return 'Debe tener 4 dígitos';
                return null;
              },
            ),
          ],
          if (authState.errorMessage != null) ...[
            const SizedBox(height: 24),
            Text(
              'Error (${authState.errorMessage})',
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final systemStatus = ref.watch(systemStatusProvider);

    final scaffoldContent = Scaffold(
          backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        leadingWidth: 100,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16.0, top: 8.0, bottom: 8.0),
          child: ElevatedButton(
            onPressed: _scanLoginQR,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6642F8).withOpacity(0.1),
              foregroundColor: const Color(0xFF6642F8),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: EdgeInsets.zero,
            ),
            child: const Icon(Icons.qr_code_scanner, size: 45),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _showPendingSalesModal,
            tooltip: _hasUnclosedSales
                ? 'Ver ventas pendientes de cierre'
                : 'No hay ventas pendientes',
            icon: Icon(
              Icons.account_balance_wallet_rounded,
              color: _hasUnclosedSales ? Colors.redAccent : Colors.green,
              size: 40,
            ),
          ),
          const SizedBox(width: 16),
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _printLastClosure,
        backgroundColor: const Color(0xFF6642F8),
        tooltip: 'Imprimir último cierre',
        child: const Icon(Icons.point_of_sale_rounded, color: Colors.white),
      ),
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 800) {
                  // Pantalla grande: Mostrar en dos columnas (Row)
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 48, vertical: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            flex: 5,
                            child: SingleChildScrollView(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 32),
                                child: _buildForm(),
                              ),
                            ),
                          ),
                          Container(
                              width: 1,
                              height: 400,
                              color: Colors.grey.shade200),
                          Expanded(
                            flex: 6,
                            child: Center(
                              child: SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 32),
                                  child: _buildNumPad(authState),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                } else {
                  // Pantalla pequeña: Mostrar en una sola columna (Column)
                  return Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _buildForm(),
                          const SizedBox(height: 48),
                          _buildNumPad(authState),
                        ],
                      ),
                    ),
                  );
                }
              },
            ),
          ),
          Positioned(
            bottom: 16,
            left: 16,
            child: Text(
              '${ApiConstants.displayVersion} - MAC: ${_macAddress.isEmpty ? 'Cargando...' : _macAddress}',
              style: const TextStyle(
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    return Stack(
      children: [
        scaffoldContent,
        if (_isLoadingLogin)
          Container(
            color: Colors.black54,
            child: const Center(
              child: CircularProgressIndicator(color: Color(0xFF6642F8)),
            ),
          ),
      ],
    );
  }
}
