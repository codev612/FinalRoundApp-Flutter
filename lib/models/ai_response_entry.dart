/// Represents a single AI response entry in the history
class AiResponseEntry {
  final String question;
  final String response;
  final DateTime timestamp;
  final bool hasImages;

  AiResponseEntry({
    required this.question,
    required this.response,
    required this.timestamp,
    this.hasImages = false,
  });

  Map<String, dynamic> toJson() => {
    'question': question,
    'response': response,
    'timestamp': timestamp.toIso8601String(),
    'hasImages': hasImages,
  };

  factory AiResponseEntry.fromJson(Map<String, dynamic> json) {
    return AiResponseEntry(
      question: json['question'] as String? ?? '',
      response: json['response'] as String? ?? '',
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      hasImages: json['hasImages'] as bool? ?? false,
    );
  }
}
