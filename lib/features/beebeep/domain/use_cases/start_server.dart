import '../repositories/connection_repository.dart';

class StartServer {
  const StartServer(this._repo);

  final ConnectionRepository _repo;

  Future<void> call({required int port}) => _repo.startServer(port: port);
}
