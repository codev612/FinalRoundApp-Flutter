enum TranscriptSource {
  mic,
  system,
  unknown,
}

class TranscriptBubble {
  final TranscriptSource source;
  final String text;
  final DateTime timestamp;
  final bool isDraft;

  const TranscriptBubble({
    required this.source,
    required this.text,
    required this.timestamp,
    this.isDraft = false,
  });

  TranscriptBubble copyWith({
    TranscriptSource? source,
    String? text,
    DateTime? timestamp,
    bool? isDraft,
  }) {
    return TranscriptBubble(
      source: source ?? this.source,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      isDraft: isDraft ?? this.isDraft,
    );
  }
}
