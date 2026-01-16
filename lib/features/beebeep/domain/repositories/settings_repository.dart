/// Repository for app settings.
abstract interface class SettingsRepository {
  /// Returns the stored display name, if any.
  Future<String?> getDisplayName();

  /// Persists the display name.
  Future<void> setDisplayName(String name);
}
