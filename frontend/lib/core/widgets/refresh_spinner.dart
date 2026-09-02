// ─────────────────────────────────────────────
// core/widgets/refresh_spinner.dart
//
// Small, self-contained rotating icon shown app-wide whenever
// RefreshBus.isRefreshing pulses true — a logo tap, re-tapping the
// active tab, or a booking action completing all trigger this the
// same subtle way. No banner, no "Refreshing…" text — just a small
// spinning icon that appears next to the logo and fades out again
// once the pulse ends.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

import '../services/refresh_bus.dart';

class RefreshSpinner extends StatefulWidget {
  final Color color;
  const RefreshSpinner({super.key, this.color = Colors.white});

  @override
  State<RefreshSpinner> createState() => _RefreshSpinnerState();
}

class _RefreshSpinnerState extends State<RefreshSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: RefreshBus.isRefreshing,
      builder: (context, refreshing, _) {
        if (refreshing) {
          _controller.repeat();
        } else {
          _controller.stop();
        }
        return AnimatedOpacity(
          opacity: refreshing ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: RotationTransition(
            turns: _controller,
            child: Icon(Icons.autorenew_rounded,
                size: 18, color: widget.color),
          ),
        );
      },
    );
  }
}
