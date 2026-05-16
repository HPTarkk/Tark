import 'package:flutter/foundation.dart';

class Logger {
  const Logger._();

  static void log(Object? data) {
    if (kDebugMode) print(data);
  }
}
