import 'package:equatable/equatable.dart';

class Peer extends Equatable {
  const Peer({
    required this.id,
    required this.displayName,
    required this.host,
    required this.port,
  });

  final String id;
  final String displayName;
  final String host;
  final int port;

  @override
  List<Object?> get props => [id, displayName, host, port];
}
