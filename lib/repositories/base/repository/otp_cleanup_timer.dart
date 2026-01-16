import 'dart:async';
import 'dart:io';
import 'package:postgres/postgres.dart';
import 'package:recipe/repositories/auth/model/generate_otp.dart';
import 'package:recipe/repositories/base/repository/base_repository.dart';
import 'package:recipe/utils/config.dart';
import 'package:recipe/utils/db_functions.dart';

// Call this once at server startup
class OtpCleanupScheduler {
  static Duration interval = const Duration(minutes: 30);
  static Timer? _timer;
  static bool _running = false;

  OtpCleanupScheduler._();

  static void start() {
    // run once at boot
    _tick();

    // run periodically
    _timer = Timer.periodic(interval, (_) => _tick());

    // graceful shutdown
    ProcessSignal.sigterm.watch().listen((_) => stop());
    ProcessSignal.sigint.watch().listen((_) => stop());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> _tick() async {
    if (_running) return; // avoid overlapping runs
    _running = true;
    try {
      final stopwatch = Stopwatch()..start();
      var keys = GenerateOtp().toTableJson.keys.toList();
      // Postgres example – delete OTPs older than 30 minutes
      // Adjust table/column names to yours (AppConfig.generateOtp, created_at)
      final query = 'SELECT ${keys.join(',')} FROM ${AppConfig.generateOtp}';
      final res = await BaseRepository.baseRepository.connection.execute(Sql.named(query));
      var resList = DBFunctions.mapFromResultRow(res, keys) as List;
      List<GenerateOtp> otpList = [];
      for (var user in resList) {
        otpList.add(GenerateOtp.fromJson(user));
      }
      otpList = otpList.where((element) => element.createdAt.difference(DateTime.now()).inMinutes.abs() > 30).toList();
      if (otpList.isNotEmpty) {
        final deleteQuery = 'DELETE FROM ${AppConfig.generateOtp} WHERE id in ${otpList.map((e) => e.id)}';
        await BaseRepository.baseRepository.connection.execute(Sql.named(deleteQuery));
      }
      stopwatch.stop();
      // Optionally: VACUUM or log how many rows were deleted
    } catch (e, st) {
      // Log but don't crash the timer
    } finally {
      _running = false;
    }
  }
}
