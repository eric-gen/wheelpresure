import 'dart:async';

import 'package:flutter/material.dart';

/* Single-slot toast: newest message replaces the previous one, floats
 * above the content without blocking interaction, auto-dismisses. */

final ValueNotifier<String?> _toast = ValueNotifier(null);
Timer? _toastTimer;

void showAppToast(String msg) {
  _toast.value = msg;
  _toastTimer?.cancel();
  _toastTimer = Timer(const Duration(seconds: 4), () => _toast.value = null);
}

class AppToast extends StatelessWidget {
  const AppToast({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: _toast,
      builder: (context, msg, _) {
        if (msg == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            color: Theme.of(context).colorScheme.inverseSurface,
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: () => _toast.value = null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  msg,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onInverseSurface,
                      fontSize: 13),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
