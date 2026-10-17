// Reading device / kind / name out of a relay service key, in both the
// self-hosted and account-mode shapes.

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/service_key.dart';

void main() {
  test('installation devices read as hostname and source; others as is', () {
    const id = '12345678123441238123123456789abc';
    const device = 'wsl-ubuntu-24-04.studio.$id';
    expect(installationOf(device), (
      source: 'wsl-ubuntu-24-04',
      hostname: 'studio',
      id: id,
    ));
    // A WSL distribution keeps its whole name: two of them must differ.
    expect(deviceLabel(device), 'studio (WSL Ubuntu-24.04)');
    expect(deviceLabel('wsl-ubuntu.studio.$id'), 'studio (WSL Ubuntu)');
    expect(deviceLabel('windows.studio.$id'), 'studio (Windows)');
    expect(deviceLabel('macos.mbp.$id'), 'mbp (macOS)');
    expect(
      deviceLabel('linux-debian-gnu-linux-12.build.$id'),
      'build (Linux Debian)',
    );
    // Explicit overrides and hostname-only devices are never reinterpreted.
    for (final other in ['my.explicit.device', 'lb7666', '.studio.$id']) {
      expect(installationOf(other), isNull, reason: other);
      expect(deviceLabel(other), other);
    }
    expect(serviceKeyDevice('pcxu:user:$device:host:pocket'), device);
    expect(
      serviceKeyLabel('pcxu:user:$device:app:default'),
      'studio (WSL Ubuntu-24.04) · default',
    );
    expect(shortId('12345678-1234-4123-8123-123456789abc'), '12345678');
  });

  test('only installations that read the same need their short ID', () {
    const a = 'windows.studio.11111111123441238123123456789abc';
    const b = 'windows.studio.22222222123441238123123456789abc';
    const c = 'wsl-ubuntu.studio.33333333123441238123123456789abc';
    expect(sameNamedDevices([a, b, c, a, 'lb7666']), {a, b});
    expect(deviceShortId(b), '22222222');
    expect(deviceShortId('lb7666'), isNull);
  });
  test('parses a self-hosted key', () {
    final parsed = parseServiceKey('pcx:lb7666:app:default');
    expect(parsed.device, 'lb7666');
    expect(parsed.kind, 'app');
    expect(parsed.name, 'default');
  });

  test('an account key names the machine, not the account', () {
    // The regression this helper exists for: an account key carries the user
    // ahead of the device, so reading the device positionally from the front
    // labelled every hosted service with the account login.
    final parsed = parseServiceKey('pcxu:acking-you:lb7666:api:default');
    expect(parsed.device, 'lb7666');
    expect(parsed.kind, 'api');
    expect(parsed.name, 'default');
    expect(
      serviceKeyLabel('pcxu:acking-you:lb7666:api:default'),
      'lb7666 · default',
    );
  });

  test('a name may contain colons', () {
    // Nothing forbids it, and splitting on the last colon would truncate the
    // name to its final fragment.
    final parsed = parseServiceKey('pcx:box:app:my:instance');
    expect(parsed.device, 'box');
    expect(parsed.name, 'my:instance');
  });

  test('the meta kind parses too', () {
    // Never returned by discovery — it is derived from an app host — but it is a
    // real kind and a key carrying it must not fall through to "unparseable".
    expect(parseServiceKey('pcx:box:meta:default').kind, 'meta');
  });

  test('ACP keys parse, even when the name equals a kind', () {
    final self = parseServiceKey('pcx:box:acp:acp');
    expect(self.device, 'box');
    expect(self.kind, 'acp');
    expect(self.name, 'acp');
    final account = parseServiceKey('pcxu:u1:box:acp:app');
    expect(account.device, 'box');
    expect(account.kind, 'acp');
    expect(account.name, 'app');
    expect(isAcpKey('pcx:box:acp:work'), isTrue);
    expect(isAcpKey('pcx:box:app:acp'), isFalse);
    expect(isSessionKind('acp'), isTrue);
    expect(isSessionKind('app'), isTrue);
    expect(isSessionKind('api'), isFalse);
  });

  test('a non-key yields empties, and labels fall back to the raw string', () {
    // Callers pass whatever they hold; an index-based parse would crash here.
    expect(parseServiceKey('not-a-key').device, '');
    expect(serviceKeyLabel('not-a-key'), 'not-a-key');
    expect(serviceKeyName('not-a-key'), 'not-a-key');
    expect(serviceKeyDevice(''), '');
  });
}
