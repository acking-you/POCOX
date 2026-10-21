import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/relay_diagnosis.dart';

void main() {
  const error =
      'querying relay keys\n\nCaused by:\n'
      '    0: listing keys on lb7666.top:7666\n'
      '    1: administrator request timed out after 5s';

  test('the relay named by the failed request is the one diagnosed', () {
    expect(relayAddressOf(null, error), 'lb7666.top:7666');
    expect(relayAddressOf('relay.example:7666', error), 'relay.example:7666');
  });

  test('a name resolving only to a virtual address says so', () async {
    final virtual = await relayVirtualAddressOf(
      'lb7666.top:7666',
      lookup: (_) async => [InternetAddress('198.19.0.99')],
    );
    expect(virtual?.address, '198.19.0.99');
    expect(
      await relayVirtualAddressOf(
        'lb7666.top:7666',
        lookup: (_) async => [InternetAddress('43.161.216.219')],
      ),
      isNull,
    );
  });

  test('a request that timed out is a relay with no answer', () {
    expect(relayFailureOf('lb7666.top:7666', error), isA<RelayNoAnswer>());
    // Any other failure has nothing to add to its own words.
    expect(relayFailureOf('lb7666.top:7666', 'credential rejected'), isNull);
  });
}
