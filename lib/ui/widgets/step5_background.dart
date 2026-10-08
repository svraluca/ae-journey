import 'package:flutter/material.dart';

/// Static wizard background (`assets/backgroundstep4.png`).
class Step5Background extends StatelessWidget {
  const Step5Background({super.key});

  static const _asset = 'assets/backgroundstep4.png';

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: AssetImage(_asset),
            fit: BoxFit.cover,
            alignment: Alignment.center,
          ),
        ),
      ),
    );
  }
}
