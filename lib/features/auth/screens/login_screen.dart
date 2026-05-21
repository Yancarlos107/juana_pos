import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_providers.dart';
import '../../printer/services/printer_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _userFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  
  TextEditingController? _activeController;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _activeController = _emailController;
    _userFocusNode.addListener(() {
      if (_userFocusNode.hasFocus) {
        setState(() => _activeController = _emailController);
      }
    });
    _passwordFocusNode.addListener(() {
      if (_passwordFocusNode.hasFocus) {
        setState(() => _activeController = _passwordController);
      }
    });
  }

  @override
  void dispose() {
    _userFocusNode.dispose();
    _passwordFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    await ref.read(authProvider.notifier).login(
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );
    
    // Si llegamos aquí sin excepción, navegamos al Dashboard
    if (mounted && ref.read(authProvider).status == AuthStatus.authenticated) {
      Navigator.pushReplacementNamed(context, '/dashboard');
    }
  }

  Future<void> _testPrint() async {
    print('DEBUG: Iniciando _testPrint...');
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
                Text('Buscando impresora USB...', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
        ),
      ),
    );

    print('DEBUG: Llamando a printer.printTicket...');
    final success = await printer.printTicket(
      transactionId: '12345',
      amount: 5000,
      qrData: 'VALLIU-TEST-TICKET',
      cashierName: 'Operador de Prueba',
      branchName: 'Sucursal de Prueba',
    );
    print('DEBUG: Resultado de printTicket: $success');

    if (mounted) Navigator.of(context).pop(); 

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '¡Prueba de impresión exitosa!' : 'Error: No se detectó impresora USB'),
          backgroundColor: success ? Colors.green : Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
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
                ? const SizedBox(height: 28, width: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                : const Text('INICIAR SESIÓN', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1)),
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
            : Text(label, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color ?? const Color(0xFF3F3D56))),
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
          Image.asset(
            'assets/valliu-logo.png',
            height: 90,
            errorBuilder: (ctx, err, stack) => Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF6642F8).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.point_of_sale_rounded, color: Color(0xFF6642F8), size: 40),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Bienvenido a Valliu',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Color(0xFF3F3D56),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Inicia sesión con tu código',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 15),
          ),
          const SizedBox(height: 36),
          TextFormField(
            controller: _emailController,
            focusNode: _userFocusNode,
            readOnly: true,
            showCursor: true,
            onTap: () => setState(() => _activeController = _emailController),
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
                borderSide: const BorderSide(color: Color(0xFF6642F8), width: 2),
              ),
            ),
            validator: (v) => v!.isEmpty ? 'Requerido' : null,
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            readOnly: true,
            showCursor: true,
            obscureText: _obscurePassword,
            onTap: () => setState(() => _activeController = _passwordController),
            decoration: InputDecoration(
              labelText: 'Contraseña',
              prefixIcon: const Icon(Icons.lock_outline),
              filled: _activeController == _passwordController,
              fillColor: const Color(0xFF6642F8).withOpacity(0.05),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF6642F8), width: 2),
              ),
            ),
            validator: (v) => v!.isEmpty ? 'Requerido' : null,
          ),
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

    return Scaffold(
      backgroundColor: Colors.white,
      floatingActionButton: FloatingActionButton(
        onPressed: _testPrint,
        backgroundColor: const Color(0xFF6642F8),
        tooltip: 'Probar Impresora',
        child: const Icon(Icons.print_rounded, color: Colors.white),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 800) {
              // Pantalla grande: Mostrar en dos columnas (Row)
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
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
                      Container(width: 1, height: 400, color: Colors.grey.shade200),
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
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
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
    );
  }
}
