import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseHelper {
  static const _databaseName = "ValliuPos.db";
  static const _databaseVersion = 1;

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
    );
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

    // 2. Tarifas (Productos)
    await db.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY,
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
        type TEXT NOT NULL, -- 'sale', 'pmr_manual', etc.
        amount REAL NOT NULL,
        product_id INTEGER,
        pmr INTEGER DEFAULT 0,
        session_id INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        status TEXT NOT NULL -- 'pending', 'synced'
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
