import 'package:equatable/equatable.dart';

import 'beebeep_constants.dart';

class BeeBeepMessage extends Equatable {
  const BeeBeepMessage({
    required this.type,
    required this.id,
    required this.flags,
    required this.data,
    required this.timestamp,
    required this.text,
  });

  final BeeBeepMessageType type;
  final int id;
  final int flags;
  final String data;
  final DateTime timestamp;
  final String text;

  bool get isCompressed =>
      (flags & beeBeepFlagBit(BeeBeepMessageFlag.compressed)) != 0;

  @override
  List<Object?> get props => [type, id, flags, data, timestamp, text];

  BeeBeepMessage copyWith({
    BeeBeepMessageType? type,
    int? id,
    int? flags,
    String? data,
    DateTime? timestamp,
    String? text,
  }) {
    return BeeBeepMessage(
      type: type ?? this.type,
      id: id ?? this.id,
      flags: flags ?? this.flags,
      data: data ?? this.data,
      timestamp: timestamp ?? this.timestamp,
      text: text ?? this.text,
    );
  }
}
