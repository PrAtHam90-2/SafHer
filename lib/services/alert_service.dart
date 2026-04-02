import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AlertService {
  Future<bool> triggerSOS() async {
    // Simulate API call to emergency services
    await Future.delayed(const Duration(seconds: 1));
    return true; // Alert sent successfully
  }
}

final alertServiceProvider = Provider<AlertService>((ref) {
  return AlertService();
});
