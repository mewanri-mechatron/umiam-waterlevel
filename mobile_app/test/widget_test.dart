import 'package:flutter_test/flutter_test.dart';
import 'package:water_level/core/constants/app_constants.dart';

void main() {
  test('app constants', () {
    expect(AppConstants.appName, 'WaterLevel');
    expect(AppConstants.gatewayIp, '192.168.4.1');
  });
}
