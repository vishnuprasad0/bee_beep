import '../repositories/settings_repository.dart';

/// Loads the display name used for discovery.
class LoadDiscoveryName {
  const LoadDiscoveryName(this._repo);

  final SettingsRepository _repo;

  Future<String> call({required String fallback}) async {
    final current = await _repo.getDisplayName();
    final trimmed = current?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }
}
