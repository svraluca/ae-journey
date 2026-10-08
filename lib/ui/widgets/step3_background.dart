import 'package:flutter/material.dart';

/// Static wizard background (`assets/backgorundstep3.png`).
class Step3Background extends StatelessWidget {
  const Step3Background({super.key});

  static const _asset = 'assets/backgorundstep3.png';

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
