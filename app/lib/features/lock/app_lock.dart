import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../config/app_config.dart';
import '../../providers.dart';

/// App-lock state (mobile only). [locked] is true when the unlock screen should
/// be shown; it's set on launch (if [enabled]) and whenever the app is
/// backgrounded.
class AppLockState {
  const AppLockState({
    required this.enabled,
    required this.biometric,
    required this.locked,
  });

  final bool enabled;
  final bool biometric;
  final bool locked;

  AppLockState copyWith({bool? enabled, bool? biometric, bool? locked}) =>
      AppLockState(
        enabled: enabled ?? this.enabled,
        biometric: biometric ?? this.biometric,
        locked: locked ?? this.locked,
      );
}

/// Whole-app lock with a PIN (hashed in secure storage) and optional biometric
/// unlock. The PIN hash is the only secret; the on/off + biometric flags are
/// plain prefs.
class AppLockController extends Notifier<AppLockState> {
  static const _pinKey = 'app_lock_pin_hash';
  final _storage = const FlutterSecureStorage();

  @override
  AppLockState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final enabled = prefs.getBool(AppConfig.kAppLockEnabled) ?? false;
    return AppLockState(
      enabled: enabled,
      biometric: prefs.getBool(AppConfig.kAppLockBiometric) ?? false,
      locked: enabled, // start locked when the lock is on
    );
  }

  String _hash(String pin) => sha256.convert(utf8.encode(pin)).toString();

  /// Turn the lock on with [pin]. Leaves the app unlocked for this session.
  Future<void> enable(String pin) async {
    await _storage.write(key: _pinKey, value: _hash(pin));
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConfig.kAppLockEnabled, true);
    state = state.copyWith(enabled: true, locked: false);
  }

  /// Turn the lock off (also clears biometric + the stored PIN).
  Future<void> disable() async {
    await _storage.delete(key: _pinKey);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(AppConfig.kAppLockEnabled, false);
    await prefs.setBool(AppConfig.kAppLockBiometric, false);
    state = const AppLockState(enabled: false, biometric: false, locked: false);
  }

  Future<void> setBiometric(bool value) async {
    await ref
        .read(sharedPreferencesProvider)
        .setBool(AppConfig.kAppLockBiometric, value);
    state = state.copyWith(biometric: value);
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    return stored != null && stored == _hash(pin);
  }

  Future<void> changePin(String newPin) async {
    await _storage.write(key: _pinKey, value: _hash(newPin));
  }

  /// Re-lock (called when the app is backgrounded). No-op when the lock is off.
  void lock() {
    if (state.enabled && !state.locked) state = state.copyWith(locked: true);
  }

  void unlock() => state = state.copyWith(locked: false);
}

final appLockProvider =
    NotifierProvider<AppLockController, AppLockState>(AppLockController.new);
