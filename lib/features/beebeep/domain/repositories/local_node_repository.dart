/// Repository for controlling the local node broadcast identity.
abstract interface class LocalNodeRepository {
  /// Updates the local discovery display name.
  Future<void> updateDisplayName(String name);
}
