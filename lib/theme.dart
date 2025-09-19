import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

ThemeData appTheme = ThemeData(
  useMaterial3: true,
  textTheme: GoogleFonts.poppinsTextTheme(),
  scaffoldBackgroundColor: const Color(0xFF1e1631),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white.withOpacity(0.06),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.18)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.white.withOpacity(0.18)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 1.6),
    ),
    hintStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
    prefixIconColor: Colors.white.withOpacity(0.8),
  ),
);
