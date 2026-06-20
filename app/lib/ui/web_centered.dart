import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// On web, centres [child] and caps its width so the mobile-first layouts don't
/// stretch edge-to-edge on a wide monitor. A no-op on mobile (returns [child]).
class WebCentered extends StatelessWidget {
  const WebCentered({super.key, required this.child, this.maxWidth = 640});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
