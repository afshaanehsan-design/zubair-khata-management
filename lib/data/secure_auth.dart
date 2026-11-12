import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps one sign-in per cloud project and organization, so two organizations
/// on the same device stay signed in with their own emails.
class SecureAuthStorage extends LocalStorage {
  final String project;

  /// The organization id. The first organization (`main`) keeps the key that
  /// was used before organizations existed, so it stays signed in.
  final String organization;
  const SecureAuthStorage(this.project, [this.organization = 'main']);
  static const storage = FlutterSecureStorage();
  String get key => organization == 'main'
      ? 'khata.session.$project'
      : 'khata.session.$project.$organization';

  /// Forgets the sign-in of an organization that was removed from the device.
  static Future<void> forget(String project, String organization) =>
      storage.delete(key: SecureAuthStorage(project, organization).key);
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => await storage.containsKey(key: key);
  @override
  Future<String?> accessToken() => storage.read(key: key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: key, value: persistSessionString);
  @override
  Future<void> removePersistedSession() => storage.delete(key: key);
}
