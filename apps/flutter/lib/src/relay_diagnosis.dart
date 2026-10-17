import 'dart:io';

/// Why the relay could not be reached, when the failure itself can tell.
sealed class RelayDiagnosis {
  const RelayDiagnosis();
}

/// The relay's name resolves only to a proxy's or VPN's virtual address.
///
/// DNS-intercepting proxies and VPNs answer every name with an address from
/// 198.18.0.0/15 (a range reserved for benchmarking, never a real host) and
/// route that range themselves. Once that tunnel is down while its DNS still
/// answers, every name resolves to an address nothing routes.
final class RelayVirtualAddress extends RelayDiagnosis {
  /// Creates the diagnosis for [host] resolving to [address].
  const RelayVirtualAddress(this.host, this.address);

  /// The relay's host name.
  final String host;

  /// The virtual address it resolved to.
  final String address;
}

/// The relay accepted no request in time.
final class RelayNoAnswer extends RelayDiagnosis {
  /// Creates the diagnosis for [relay] (`host:port`).
  const RelayNoAnswer(this.relay);

  /// The relay's `host:port`.
  final String relay;
}

/// The relay's `host:port`: [configured] when set, else the one the error
/// names (`… on host:port`, how a failed relay request reads).
String? relayAddressOf(String? configured, String error) {
  final relay = configured?.trim();
  if (relay != null && relay.isNotEmpty) return relay;
  return RegExp(r'\bon ([A-Za-z0-9.\-\[\]:]+:\d+)').firstMatch(error)?[1];
}

/// Whether [address] lies in 198.18.0.0/15, the range proxies and VPNs hand
/// out as virtual addresses.
bool isVirtualAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  return address.type == InternetAddressType.IPv4 &&
      bytes[0] == 198 &&
      (bytes[1] == 18 || bytes[1] == 19);
}

/// What [error], a failed request to [relay] (`host:port`), says by itself;
/// null when nothing beyond its own words.
RelayDiagnosis? relayFailureOf(String? relay, String error) {
  final lower = error.toLowerCase();
  if (relay != null &&
      (lower.contains('timed out') || lower.contains('timeout'))) {
    return RelayNoAnswer(relay);
  }
  return null;
}

/// [relay]'s name when it resolves only to a virtual address, which explains
/// a relay that cannot be reached; null otherwise.
///
/// Waits on the system resolver's own limits: nothing waits on the answer,
/// which only refines what is already shown. [lookup] stands in for the
/// system resolver in tests.
Future<RelayVirtualAddress?> relayVirtualAddressOf(
  String? relay, {
  Future<List<InternetAddress>> Function(String host)? lookup,
}) async {
  if (relay == null) return null;
  final colon = relay.lastIndexOf(':');
  final host = (colon > 0 ? relay.substring(0, colon) : relay).replaceAll(
    RegExp(r'^\[|\]$'),
    '',
  );
  if (host.isEmpty || InternetAddress.tryParse(host) != null) return null;
  try {
    final addresses = await (lookup ?? InternetAddress.lookup)(host);
    if (addresses.isNotEmpty && addresses.every(isVirtualAddress)) {
      return RelayVirtualAddress(host, addresses.first.address);
    }
  } catch (_) {
    // Unresolvable: nothing more to say than the error.
  }
  return null;
}
