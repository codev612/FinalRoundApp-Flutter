import 'package:flutter/material.dart';

/// User-created meeting mode. Stored in DB / local storage.
class CustomMeetingMode {
  final String id;
  final String label;
  final int iconCodePoint; // IconData.codePoint for serialization
  final String realTimePrompt;
  final String notesTemplate;

  const CustomMeetingMode({
    required this.id,
    required this.label,
    required this.iconCodePoint,
    this.realTimePrompt = '',
    this.notesTemplate = '',
  });

  IconData get icon => IconData(iconCodePoint, fontFamily: 'MaterialIcons');

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'iconCodePoint': iconCodePoint,
        'realTimePrompt': realTimePrompt,
        'notesTemplate': notesTemplate,
      };

  factory CustomMeetingMode.fromJson(Map<String, dynamic> json) {
    return CustomMeetingMode(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      iconCodePoint: json['iconCodePoint'] as int? ?? Icons.star.codePoint,
      realTimePrompt: json['realTimePrompt'] as String? ?? '',
      notesTemplate: json['notesTemplate'] as String? ?? '',
    );
  }

  CustomMeetingMode copyWith({
    String? id,
    String? label,
    int? iconCodePoint,
    String? realTimePrompt,
    String? notesTemplate,
  }) {
    return CustomMeetingMode(
      id: id ?? this.id,
      label: label ?? this.label,
      iconCodePoint: iconCodePoint ?? this.iconCodePoint,
      realTimePrompt: realTimePrompt ?? this.realTimePrompt,
      notesTemplate: notesTemplate ?? this.notesTemplate,
    );
  }
}
