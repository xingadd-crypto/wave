enum MessageType { text, image, file, system, voice }

enum MessageStatus { sending, sent, delivered, read, failed, pending }

class Message {
  final String id;
  final String senderId;
  final String receiverId;
  final String content;
  final DateTime timestamp;
  final MessageType type;
  final bool isMe;
  final MessageStatus status;
  final String? senderName;
  final String? fileName;
  final String? filePath;
  final int? fileSize;
  final String? transferId;
  final bool played;

  Message({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.timestamp,
    required this.type,
    required this.isMe,
    this.status = MessageStatus.sent,
    this.senderName,
    this.fileName,
    this.filePath,
    this.fileSize,
    this.transferId,
    this.played = false,
  });

  Message copyWith({
    String? id,
    String? senderId,
    String? receiverId,
    String? content,
    DateTime? timestamp,
    MessageType? type,
    bool? isMe,
    MessageStatus? status,
    String? senderName,
    String? fileName,
    String? filePath,
    int? fileSize,
    String? transferId,
    bool? played,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      isMe: isMe ?? this.isMe,
      status: status ?? this.status,
      senderName: senderName ?? this.senderName,
      fileName: fileName ?? this.fileName,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      transferId: transferId ?? this.transferId,
      played: played ?? this.played,
    );
  }
}
