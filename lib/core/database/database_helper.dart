import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "JuanaPos.db";
  static const _databaseVersion = 5;

  // Singleton class
  DatabaseHelper._privateConstructor();
  static final DatabaseHelper instance = DatabaseHelper._privateConstructor();

  static Database? _database;
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, _databaseName);
    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migración v1 → v2: Recrear tabla transactions con esquema correcto
      await db.execute('DROP TABLE IF EXISTS transactions');
      await db.execute('''
        CREATE TABLE transactions (
          local_id INTEGER PRIMARY KEY AUTOINCREMENT,
          id TEXT,
          session_id INTEGER,
          product_id TEXT,
          amount REAL NOT NULL,
          pmr INTEGER DEFAULT 0,
          status TEXT NOT NULL,
          created_at TEXT NOT NULL,
          qr_data TEXT
        )
      ''');
    }
    if (oldVersion < 3) {
      // Migración v2 → v3: products.id pasa de INTEGER a TEXT (MongoDB _id)
      await db.execute('DROP TABLE IF EXISTS products');
      await db.execute('''
        CREATE TABLE products (
          id TEXT PRIMARY KEY,
          product_name TEXT NOT NULL,
          value REAL NOT NULL,
          pmr INTEGER DEFAULT 0,
          created_at TEXT
        )
      ''');
    }
    if (oldVersion < 4) {
      // Migración v3 → v4: Add print_status column to transactions
      await db.execute(
          'ALTER TABLE transactions ADD COLUMN print_status INTEGER DEFAULT 0');
    }
    if (oldVersion < 5) {
      // Migración v4 → v5: Add cashier_id column to transactions
      await db.execute(
          'ALTER TABLE transactions ADD COLUMN cashier_id INTEGER DEFAULT 1');
    }
  }

  Future _onCreate(Database db, int version) async {
    // 1. Usuarios (Hash)
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        email TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        name TEXT,
        branch_id INTEGER,
        roles TEXT
      )
    ''');

    // 2. Tarifas (Productos) — id es el _id de MongoDB (TEXT)
    await db.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        product_name TEXT NOT NULL,
        value REAL NOT NULL,
        pmr INTEGER DEFAULT 0,
        created_at TEXT
      )
    ''');

    // 3. Rutas
    await db.execute('''
      CREATE TABLE routes (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT
      )
    ''');

    // 4. Transacciones (Ventas, aperturas PMR)
    await db.execute('''
      CREATE TABLE transactions (
        local_id INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT,
        session_id INTEGER,
        product_id TEXT,
        amount REAL NOT NULL,
        pmr INTEGER DEFAULT 0,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        qr_data TEXT,
        print_status INTEGER DEFAULT 0,
        cashier_id INTEGER DEFAULT 1
      )
    ''');

    // 5. Sesiones de Caja
    await db.execute('''
      CREATE TABLE sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        branch_id INTEGER NOT NULL,
        opened_at TEXT NOT NULL,
        closed_at TEXT,
        status TEXT NOT NULL, -- 'open', 'closed', 'late_closed'
        is_late INTEGER DEFAULT 0
      )
    ''');
  }
}
