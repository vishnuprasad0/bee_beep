import '../repositories/local_node_repository.dart';
import '../repositories/settings_repository.dart';

/// Updates the local discovery name and persists it.
class UpdateDiscoveryName {
  const UpdateDiscoveryName(this._settingsRepo, this._localNodeRepo);

  final SettingsRepository _settingsRepo;
  final LocalNodeRepository _localNodeRepo;

  Future<void> call(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    await _settingsRepo.setDisplayName(trimmed);
    await _localNodeRepo.updateDisplayName(trimmed);
  }
}
