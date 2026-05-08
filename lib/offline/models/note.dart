import 'dart:convert';

class Note {
  Note({
    required this.id,
    required this.text,
    required this.createdAtMillis,
    required this.updatedAtMillis,
    required this.likeCount,
    required this.likedByMe,
    required this.savedByMe,
  });

  final String id;

  final String text;

  
  final int createdAtMillis;

  final int updatedAtMillis;


  /// Derived from server-side state for the demo.
  final int likeCount;


  /// User-specific state. For the demo, we model a single user.
  final bool likedByMe;

  final bool savedByMe;

  Note copyWith({
    String? id,
    String? text,
    int? createdAtMillis,
    int? updatedAtMillis,
    int? likeCount,
    bool? likedByMe,
    bool? savedByMe,
  }) {
    return Note(
      id: id ?? this.id,
      text: text ?? this.text,
      createdAtMillis: createdAtMillis ?? this.createdAtMillis,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
      likeCount: likeCount ?? this.likeCount,
      likedByMe: likedByMe ?? this.likedByMe,
      savedByMe: savedByMe ?? this.savedByMe,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'createdAtMillis': createdAtMillis,
        'updatedAtMillis': updatedAtMillis,
        'likeCount': likeCount,
        'likedByMe': likedByMe,
        'savedByMe': savedByMe,
      };

  static Note fromJson(Map<String, dynamic> json) => Note(
        id: json['id'] as String,
        text: json['text'] as String,
        createdAtMillis: json['createdAtMillis'] as int,
        updatedAtMillis: json['updatedAtMillis'] as int,
        likeCount: json['likeCount'] as int,
        likedByMe: json['likedByMe'] as bool,
        savedByMe: json['savedByMe'] as bool,
      );

  String toJsonString() => jsonEncode(toJson());
  static Note fromJsonString(String jsonString) =>
      fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
}

  
