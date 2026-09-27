import 'package:flutter_test/flutter_test.dart';

import 'package:any_booking/main.dart';

void main() {
  testWidgets('AnyBooking app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AnyBookingApp());

    expect(find.text('AnyBooking'), findsOneWidget);
  });
}
