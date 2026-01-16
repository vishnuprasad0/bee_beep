import '../../domain/repositories/settings_repository.dart';
import '../datasources/settings_local_data_source.dart';

/// Hive-backed implementation of [SettingsRepository].
class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._dataSource);

  final SettingsLocalDataSource _dataSource;

  @override
  Future<String?> getDisplayName() async => _dataSource.getDisplayName();

  @override
  Future<void> setDisplayName(String name) => _dataSource.setDisplayName(name);
}
