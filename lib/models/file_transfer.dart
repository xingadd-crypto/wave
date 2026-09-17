enum FileTransferDirection { send, receive }

enum FileTransferStatus { transferring, done, failed, cancelled }

/// Outcome of an attempted file send. [cancelled] distinguishes a user abort
/// from a genuine failure, so callers never re-queue an aborted file (which
/// would otherwise resend it in an endless cancel/retry loop).
class FileSendResult {
  const FileSendResult({required this.ok, required this.cancelled});
  final bool ok;
  final bool cancelled;
}

class FileTransferProgress {
  final String transferId;
  final String friendId;
  final FileTransferDirection direction;
  final String fileName;
  final int total;
  final int done;
  final FileTransferStatus status;
  final String? error;

  const FileTransferProgress({
    required this.transferId,
    required this.friendId,
    required this.direction,
    required this.fileName,
    required this.total,
    required this.done,
    required this.status,
    this.error,
  });

  double get fraction => total == 0 ? 0 : done / total;

  FileTransferProgress copyWith({
    int? done,
    FileTransferStatus? status,
    String? error,
  }) {
    return FileTransferProgress(
      transferId: transferId,
      friendId: friendId,
      direction: direction,
      fileName: fileName,
      total: total,
      done: done ?? this.done,
      status: status ?? this.status,
      error: error ?? this.error,
    );
  }
}

class FileDownloaded {
  final String fromHex;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String transferId;

  const FileDownloaded({
    required this.fromHex,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.transferId,
  });
}

/// An inbound file offer waiting on the user's accept/reject + save-location
/// decision. Surfaced to the UI; the pending decision is resolved through
/// `IrohService.respondIncomingFile`.
class IncomingFileOffer {
  final String fileId;
  final String fromHex;
  final String fromName;
  final String name;
  final int size;
  final bool compressed;

  const IncomingFileOffer({
    required this.fileId,
    required this.fromHex,
    required this.fromName,
    required this.name,
    required this.size,
    required this.compressed,
  });
}
