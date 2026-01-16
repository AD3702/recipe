import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:recipe/utils/list_extenstion.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_multipart/shelf_multipart.dart';

class DBFunctions {
  DBFunctions._();

  static Future<void> createTableFromClass(Connection connection, String tableName, Map<String, dynamic> sampleJson) async {
    final columns = sampleJson.entries
        .map((entry) {
          final sqlType = entry.key == 'id' ? 'SERIAL PRIMARY KEY' : '${dartTypeToSQL(entry.value)} NULL';
          return '${entry.key} $sqlType';
        })
        .join(', ');
    final createQuery = 'CREATE TABLE IF NOT EXISTS "$tableName" ($columns);';
    var res = await connection.execute(createQuery);
    // Fetch existing columns safely
    final result = await connection.execute("SELECT column_name FROM information_schema.columns WHERE table_name = '$tableName' ORDER BY ordinal_position");
    final existingColumns = result.map((row) => row[0] as String).toSet();
    // Add missing columns except 'id'
    for (var entry in sampleJson.entries) {
      if (entry.key == 'id') continue; // don't alter id column
      if (!existingColumns.contains(entry.key)) {
        final sqlType = '${dartTypeToSQL(entry.value)} NULL';
        final alterQuery = 'ALTER TABLE "$tableName" ADD COLUMN ${entry.key} $sqlType;';
        await connection.execute(alterQuery);
      }
    }
  }

  static String dartTypeToSQL(dynamic value) {
    if (value is int) return 'INTEGER';
    if (value is String) return 'TEXT';
    if (value is double) return 'DOUBLE PRECISION';
    if (value is bool) return 'BOOLEAN';
    if (value is DateTime) return 'TIMESTAMP';
    return 'TEXT'; // default
  }

  static Map<String, dynamic> generateInsertQueryFromClass(String tableName, Map<String, dynamic> data) {
    // Exclude 'id' if present, as it's usually auto-generated
    final filteredEntries = data.entries.where((e) => e.key != 'id').toList();
    final columns = filteredEntries.map((e) => e.key).join(', ');
    final placeholders = List.generate(filteredEntries.length, (i) => '@$i').join(', ');
    final values = filteredEntries.map((e) => e.value).toList();

    final query = 'INSERT INTO "$tableName" ($columns) VALUES ($placeholders) RETURNING *;';
    return {'query': query, 'params': values};
  }

  static Map<String, dynamic> generateSmartUpdate({
    required String table,
    required Map<String, dynamic> oldData,
    required Map<String, dynamic> newData,
    List<String> ignoreParameters = const [],
    String primaryKey = 'uuid',
  }) {
    ignoreParameters.add('id');
    print(ignoreParameters);
    for (var k in ignoreParameters) {
      oldData.remove(k);
      newData.remove(k);
    }
    if (!oldData.containsKey(primaryKey)) {
      throw Exception('Primary key "$primaryKey" missing in oldData');
    }

    final Map<String, dynamic> updates = {};

    // Only copy changed, non-null values
    newData.forEach((key, value) {
      if (value == null) return;
      if (key == primaryKey) return;
      if (key == 'created_at') return;

      if (oldData[key] != value) {
        updates[key] = value;
      }
    });

    if (updates.isEmpty) {
      throw Exception('No fields changed');
    }

    int i = 0;
    final List<String> sets = [];
    final List<dynamic> params = [];

    updates.forEach((key, value) {
      sets.add('$key = @$i');
      params.add(value);
      i++;
    });

    // WHERE
    final whereIndex = i;
    params.add(oldData[primaryKey]);

    final query =
        '''
UPDATE "$table"
SET ${sets.join(', ')}
WHERE $primaryKey = @$whereIndex
RETURNING *;
''';

    return {'query': query, 'params': params, 'changedKeys': updates.keys.toList()};
  }

  static Map<String, dynamic> generateInsertListQueryFromClass(String tableName, List<Map<String, dynamic>> dataList) {
    if (dataList.isEmpty) {
      throw ArgumentError('dataList cannot be empty');
    }

    // Build an ordered set of columns across all rows, excluding 'id'
    final Set<String> colSet = {};
    // Preserve order from the first row first
    for (final entry in dataList.first.entries) {
      if (entry.key != 'id') colSet.add(entry.key);
    }
    // Include any additional keys from subsequent rows
    for (final row in dataList.skip(1)) {
      for (final key in row.keys) {
        if (key != 'id') colSet.add(key);
      }
    }

    final columns = colSet.toList();

    // Prepare placeholders and flat params list
    final params = <dynamic>[];
    final valueGroups = <String>[];
    var paramIndex = 0;

    for (final row in dataList) {
      final placeholders = <String>[];
      for (final col in columns) {
        placeholders.add('@$paramIndex');
        params.add(row.containsKey(col) ? row[col] : null);
        paramIndex++;
      }
      valueGroups.add('(${placeholders.join(', ')})');
    }

    final query = 'INSERT INTO "$tableName" (${columns.join(', ')}) VALUES ${valueGroups.join(', ')} RETURNING *;';

    return {'query': query, 'params': params};
  }

  static Map<String, dynamic> buildConditions(Map<String, dynamic> requestBody, {List<String>? searchKeys, bool deleted = false, int? limit, int? offset}) {
    final conditions = <String>['deleted = $deleted'];
    final params = <dynamic>[];

    for (var key in requestBody.keys) {
      var value = requestBody[key];
      // Ignore pagination-related keys
      if (key == 'page_number' || key == 'page_size') {
        continue; // skip these keys from WHERE conditions
      }
      if (key == 'search' && value != null && value.toString().isNotEmpty && searchKeys != null) {
        final search = value.toString().toLowerCase();
        final searchCondition = searchKeys.map((k) => 'LOWER($k) LIKE @${params.length + searchKeys.indexOf(k)}').join(' OR ');
        conditions.add('($searchCondition)');
        for (int i = 0; i < searchKeys.length; i++) {
          params.add('%$search%');
        }
      } else if (value is bool) {
        conditions.add('$key = @${params.length}');
        params.add(value);
      } else if (value is List && value.isNotEmpty) {
        final placeholders = value.map((v) => '@${params.length + value.indexOf(v)}').join(', ');
        conditions.add('$key IN ($placeholders)');
        params.addAll(value);
      } else if (value != null && value.toString().isNotEmpty) {
        conditions.add('$key = @${params.length}');
        params.add(value);
      }
    }

    requestBody.forEach((key, value) {});

    final suffixParts = <String>[];
    final suffixParams = <dynamic>[];
    if (limit != null) {
      suffixParts.add('LIMIT @${suffixParams.length + params.length}');
      suffixParams.add(limit);
    }
    if (offset != null) {
      suffixParts.add('OFFSET @${suffixParams.length + params.length}');
      suffixParams.add(offset);
    }
    final suffix = suffixParts.join(' ');
    return {'conditions': conditions, 'params': params, 'suffix': suffix, 'suffixParams': suffixParams};
  }

  /// Returns ordered column names for a given table.
  ///
  /// Example: `await DBFunctions.getColumnNames(connection, 'recipe_details');`
  static Future<List<String>> getColumnNames(Connection connection, String tableName, {String schema = 'public'}) async {
    final res = await connection.execute(
      Sql.named('''
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = @0 AND table_name = @1
        ORDER BY ordinal_position;
      '''),
      parameters: [schema, tableName],
    );

    return res.map((row) => row[0] as String).toList();
  }

  /// Convenience: prints key/value pairs for the first row in a Result.
  /// (Column names are not reliably available from `Result` in all postgres package versions.)
  static void debugPrintFirstRow(Result res, List<String> keys) {
    return;
    if (res.isEmpty) return;
    for (int i = 0; i < keys.length && i < res.first.length; i++) {
      print('${keys[i]} | ${res.first[i]}');
    }
  }

  static mapFromResultRow(Result res, List<String> keys) {
    debugPrintFirstRow(res, keys);
    return res.map((row) => Map.fromIterables(keys, row.toList())).toList();
  }

  static String generateRandomPassword({int length = 12}) {
    const String chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#\$%^&*()_+[]{}';
    Random random = Random.secure();
    return List.generate(length, (index) => chars[random.nextInt(chars.length)]).join();
  }

  static String generateRandomOtp({int length = 6}) {
    const String chars = '0123456789';
    Random random = Random.secure();
    return '123456' ?? List.generate(length, (index) => chars[random.nextInt(chars.length)]).join();
  }

  static String? checkParamValidRequest(List<String> requestParams, List<String> requiredParams) {
    if (!requestParams.containsAllElements(requiredParams)) {
      requiredParams.removeWhere((element) => requestParams.contains(element));
      return 'Required parameters ${requiredParams.join(', ')} are missing';
    }
    return null;
  }

  static multipartImageConfigure(Request request, String directory, String fileTitle) async {
    Map<String, dynamic> response = {'status': 400};

    final multipart = request.multipart();
    if (multipart == null) {
      response['message'] = 'Content-Type must be multipart/form-data';
      return Response.badRequest(body: jsonEncode(response));
    }

    const allowedExt = {'jpg', 'jpeg', 'png', 'webp'};
    const maxBytes = 5 * 1024 * 1024; // 5 MB per file

    // Ensure directory exists
    final root = Directory('uploads/$directory');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }

    final List<String> savedPaths = [];
    int index = 0;

    await for (final part in multipart.parts) {
      final bytes = await part.readBytes();
      if (bytes.isEmpty) continue;

      if (bytes.length > maxBytes) {
        response['message'] = 'One of the files is too large. Max allowed size is 5 MB';
        return Response.badRequest(body: jsonEncode(response));
      }

      final filename = fileTitle;
      String ext = 'jpg';
      if (filename.contains('.')) {
        ext = filename.split('.').last.toLowerCase();
      }

      if (!allowedExt.contains(ext)) {
        response['message'] = 'Only image files are allowed. Supported: ${allowedExt.toList()}';
        return Response.badRequest(body: jsonEncode(response));
      }

      // 1st file → no suffix, others → _1, _2, ...
      final suffix = '_$index';
      final fileName = '$fileTitle$suffix.$ext';
      final filePath = '${root.path}/$fileName';

      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      savedPaths.add(file.path.replaceAll('\\', '/'));
      index++;
    }

    if (savedPaths.isEmpty) {
      response['message'] = 'No file found in form-data with key "file"';
      return Response.badRequest(body: jsonEncode(response));
    }

    return savedPaths.length == 1 ? savedPaths.first : savedPaths;
  }
}
