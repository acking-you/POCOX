import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/window_title_bar.dart';

/// Read another device's pairing QR with the camera. Only a
/// `pocox://pair?c=<code>` invitation counts, and it only returns its code to
/// the page that asked, which previews it: a scan never links anything.
class PairingScanScreen extends ConsumerStatefulWidget {
  /// Creates the scanner.
  const PairingScanScreen({super.key});

  @override
  ConsumerState<PairingScanScreen> createState() => _PairingScanState();
}

class _PairingScanState extends ConsumerState<PairingScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  bool _notOurs = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    final api = ref.read(bridgeApiProvider);
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final code = api.pairingParseInvitation(raw);
      if (code != null) {
        _done = true;
        context.pop(code);
        return;
      }
    }
    if (!_notOurs) setState(() => _notOurs = true);
  }

  @override
  Widget build(BuildContext context) {
    // A camera page is dark in either theme, so its controls take the dark
    // palette rather than light ones drawn on black.
    return Theme(
      data: darkTheme(),
      child: Builder(builder: _page),
    );
  }

  Widget _page(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final white = theme.textTheme.bodyMedium?.copyWith(color: Colors.white);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: WindowTitleBar(
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => context.pop(),
          icon: const Icon(AppIcons.close),
        ),
        automaticallyImplyLeading: false,
        title: Text(l10n.pairingScanTitle),
        centerTitle: true,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: ValueListenableBuilder<MobileScannerState>(
        valueListenable: _controller,
        builder: (context, state, _) {
          final error = state.error;
          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: _detected,
                // The message below says why; the preview stays black.
                errorBuilder: (_, _) => const SizedBox.shrink(),
              ),
              Center(
                child: error == null
                    ? Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? l10n.pairingCameraDenied
                              : l10n.pairingCameraFailed,
                          key: const Key('pairing-scan-error'),
                          textAlign: TextAlign.center,
                          style: white,
                        ),
                      ),
              ),
              Positioned(
                left: 24,
                right: 24,
                bottom: 32,
                child: SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (error == null) ...[
                        Text(
                          _notOurs
                              ? l10n.pairingScanNotOurs
                              : l10n.pairingScanHint,
                          textAlign: TextAlign.center,
                          style: white,
                        ),
                        const SizedBox(height: 14),
                      ],
                      OutlinedButton(
                        key: const Key('pairing-scan-by-hand'),
                        onPressed: () => context.pop(),
                        child: Text(l10n.pairingByHand),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
