import 'package:flutter/services.dart';

/// A figure typed at two places at most -- the scale's, the invoices' and the
/// statements' (ADR-085; ADR-086 law 4); the server refuses a third.
TextInputFormatter twoPlaces({bool signed = false}) {
  final pattern = RegExp(signed ? r'^-?\d*\.?\d{0,2}$' : r'^\d*\.?\d{0,2}$');
  return TextInputFormatter.withFunction(
    (oldValue, newValue) => pattern.hasMatch(newValue.text) ? newValue : oldValue,
  );
}

/// A weight counted: at two places, never below zero.
final twoPlaceGrams = twoPlaces();
