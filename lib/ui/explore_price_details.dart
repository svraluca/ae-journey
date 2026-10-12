import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/openai_service.dart';

String explorePriceConversionNote(OpenAIClinic clinic) =>
    clinic.sourceCurrencyBasis == 'platform_converted'
        ? 'WhatClinic displays this price in EUR using its currency conversion. '
          'The clinic’s original currency has not been confirmed.'
        : '';

/// A conversion explanation belongs in details, not below every card price.
class ExplorePriceDetailsButton extends StatelessWidget {
  const ExplorePriceDetailsButton({super.key, required this.clinic, required this.child});
  final OpenAIClinic clinic;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final note = explorePriceConversionNote(clinic);
    if (note.isEmpty) return child;
    return Tooltip(
      message: 'View price details',
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Price details'),
            content: Text(note),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  final url = Uri.tryParse(clinic.priceSourceUrl);
                  if (url != null && url.scheme == 'https') {
                    launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
                child: const Text('Open published price'),
              ),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}
