import 'package:flutter/material.dart';

class RecorderSize {
  static double x20 = 20;

  void init(BuildContext context) {
    final scale = MediaQuery.sizeOf(context).shortestSide / 400;
    x20 = 20 * scale;
  }
}
