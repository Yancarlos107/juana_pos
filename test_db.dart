import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
void main() async {
  sqfliteFfiInit();
  var dbFactory = databaseFactoryFfi;
  var db = await dbFactory.openDatabase('C:\\Users\\yanca\\AppData\\Local\\sistema_pos\\databases\\pos_database.db');
  var results = await db.query('transactions', where: 'product_id = ?', whereArgs: ['CIERRE DE CAJA'], orderBy: 'created_at DESC', limit: 5);
  for (var r in results) {
    print('Closure: \ | Cashier: \ | Date: \ | Pos: \');
  }
}
