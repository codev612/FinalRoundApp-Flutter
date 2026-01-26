import 'package:flutter/material.dart';

enum MeetingMode {
  general('General', Icons.chat),
  interview('Interview', Icons.person),
  presentation('Presentation', Icons.present_to_all),
  discussion('Discussion', Icons.forum),
  lecture('Lecture', Icons.school),
  meeting('Meeting', Icons.groups),
  call('Call', Icons.phone),
  brainstorm('Brainstorm', Icons.lightbulb_outline),
  other('Other', Icons.more_horiz);

  final String label;
  final IconData icon;

  const MeetingMode(this.label, this.icon);

  static MeetingMode fromString(String? value) {
    if (value == null) return MeetingMode.general;
    return MeetingMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => MeetingMode.general,
    );
  }
}
