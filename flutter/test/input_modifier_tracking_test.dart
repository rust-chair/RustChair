import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/input_model.dart';

void main() {
  test('right Alt is released from the right modifier slot', () {
    final tracked = ToReleaseKeys();
    final down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.altRight,
      logicalKey: LogicalKeyboardKey.altRight,
      timeStamp: Duration.zero,
    );

    tracked.updateKeyDown(down.logicalKey, down);

    expect(tracked.lastLAltKeyEvent, isNull);
    expect(tracked.lastRAltKeyEvent, isNotNull);

    tracked.updateKeyUp(LogicalKeyboardKey.altRight);

    expect(tracked.lastRAltKeyEvent, isNull);
  });
}
