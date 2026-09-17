import 'dart:convert';
import 'dart:typed_data';
import 'package:iroh_flutter/iroh_flutter.dart';

class PostcardWriter {
  final BytesBuilder _buf = BytesBuilder();

  void writeVarint(int value) {
    var v = value.toUnsigned(64);
    while (v > 0x7f) {
      _buf.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    _buf.addByte(v & 0x7f);
  }

  void writeU8(int v) => _buf.addByte(v & 0xff);

  void writeBytes(Uint8List data) {
    writeVarint(data.length);
    _buf.add(data);
  }

  void writeString(String s) {
    final bytes = Uint8List.fromList(utf8.encode(s));
    writeBytes(bytes);
  }

  void writeRawBytes(Uint8List data) {
    _buf.add(data);
  }

  Uint8List toBytes() => _buf.takeBytes();
}

class PostcardReader {
  final Uint8List _data;
  int _pos = 0;

  PostcardReader(this._data);

  int readVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (_pos >= _data.length) throw Exception('Postcard: unexpected end');
      final byte = _data[_pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  int readU8() {
    if (_pos >= _data.length) throw Exception('Postcard: unexpected end');
    return _data[_pos++];
  }

  Uint8List readRawBytes(int len) {
    if (_pos + len > _data.length) throw Exception('Postcard: unexpected end');
    final result = _data.sublist(_pos, _pos + len);
    _pos += len;
    return result;
  }

  Uint8List readBytes() {
    final len = readVarint();
    return readRawBytes(len);
  }

  String readString() {
    final bytes = readBytes();
    return utf8.decode(bytes);
  }

  bool get isAtEnd => _pos >= _data.length;
}

// --- Moon DNS protocol types ---

class MoonDnsRegistryEntry {
  final Uint8List id;
  final String name;
  final String shortId;
  final EndpointAddr? addr;

  MoonDnsRegistryEntry(this.id, this.name, this.shortId, this.addr);

  // Debug logging routed through one helper so Dart's avoid_print lint is
  // contained to a single spot (these are connection-triaging messages only).
  // ignore: avoid_print
  static void _log(String line) => print(line);

  static MoonDnsRegistryEntry decode(PostcardReader r) {
    final id = r.readRawBytes(32);
    final name = r.readString();
    final shortId = r.readString();
    // EndpointAddr is decoded via iroh's built-in postcard decoder.
    // If the addr bytes can't be parsed, keep the entry with a null addr rather
    // than failing the whole lookup — the peer is still reachable by its id.
    final addrBytes = _readEndpointAddrBytesSafe(r);
    EndpointAddr? addr;
    if (addrBytes != null) {
      try {
        addr = EndpointAddr.decode(addrBytes);
      } catch (_) {
        _log('DNS: EndpointAddr.decode failed (${addrBytes.length} bytes)');
      }
    }
    return MoonDnsRegistryEntry(id, name, shortId, addr);
  }

  static Uint8List? _readEndpointAddrBytesSafe(PostcardReader r) {
    final start = r._pos;
    try {
      return _readEndpointAddrBytes(r);
    } catch (e) {
      _log('DNS: EndpointAddr span parse failed at pos=$start: $e');
      // EndpointAddr is the last field of a registry entry; fall back to the
      // remaining buffer (valid when addr is the final field, e.g. lookup).
      if (start < r._data.length) {
        return Uint8List.fromList(r._data.sublist(start));
      }
      return null;
    }
  }

  static Uint8List _readEndpointAddrBytes(PostcardReader r) {
    final start = r._pos;
    r.readRawBytes(32); // id: PublicKey
    final count = r.readVarint(); // addrs: BTreeSet
    final log = StringBuffer('EndpointAddr parse: id=32, count=$count');
    for (var i = 0; i < count; i++) {
      final variant = r.readVarint();
      switch (variant) {
        case 0: // Relay(RelayUrl)
          final u = r.readBytes();
          log.write(', relay=${String.fromCharCodes(u)}');
          break;
        case 1: // Ip(SocketAddr)
          final ipVer = r.readVarint(); // SocketAddr V4=0 or V6=1
          final ipBytes = r.readRawBytes(ipVer == 0 ? 4 : 16);
          final port = r.readVarint(); // u16 port
          final ipStr = ipVer == 0
              ? ipBytes.join('.')
              : List.generate(8, (i) => (ipBytes[i*2] << 8) | ipBytes[i*2+1]).map((v) => v.toRadixString(16)).join(':');
          log.write(', ip:$ipStr:$port');
          break;
        case 2: // Custom
          throw Exception('CustomAddr not supported');
        default:
          throw Exception('Unknown TransportAddr variant: $variant');
      }
    }
    _log('DNS: $log');
    return Uint8List.fromList(r._data.sublist(start, r._pos));
  }
}

// --- P2P MessageBody (matches Rust protocol::MessageBody) ---

enum MessageBodyKind {
  aboutMe,
  chat,
  ping,
  friendRequest,
  friendAccept,
  friendReject,
  friendRemove,
  nickChanged,
  fileOffer,
  fileChunk,
  fileDone,
  fileCancel,
  fileAck,
  voiceMessage,
  imageMessage,
  callInvite,
  callAccept,
  callReject,
  callBusy,
  callHangup,
  callAudio,
  presenceProbe,
  presenceReply,
  momentFetch,
  momentFeed,
  momentImage,
  momentImageData,
  momentReact,
  momentDelete,
  updateRequest,
  updateReply,
}

/// A single moments post as carried on the wire (text + image count only;
/// image payloads are fetched on demand via [MessageBody.momentImage]).
class MomentPostInfo {
  final String id;
  final String text;
  final int imageCount;
  final int ts;

  const MomentPostInfo(this.id, this.text, this.imageCount, this.ts);
}

class MessageBody {
  final MessageBodyKind kind;
  final String? text;
  final String? fromName;
  final String? name;
  final String? shortId;
  final String? newName;
  final String? fileId;
  final int? fileSize;
  final bool? fileCompressed;
  final int? fileOffset;
  final Uint8List? fileData;
  final Uint8List? fileHash;
  final bool? fileOk;
  final String? fileError;
  final String? callId;
  final String? callReason;
  final int? callSeq;
  final Uint8List? callData;
  final bool? online;
  final String? voiceName;
  final int? voiceDuration;
  final Uint8List? voiceData;
  final String? imageName;
  final int? imageWidth;
  final int? imageHeight;
  final Uint8List? imageData;
  final Uint8List? imageThumb;
  final int? since;
  final int? before;
  final int? limit;
  final List<MomentPostInfo>? moments;
  final List<String>? deletedIds;
  final String? momentId;
  final int? momentIndex;
  final Uint8List? momentData;
  final int? reactType;
  final int? momentTs;

  /// App version announced in a presence reply (optional trailing field).
  final String? version;

  /// Platform ('android'|'windows') of the announcing peer, so the UI only
  /// offers fetches from friends running the same platform build.
  final String? presencePlatform;

  // Peer update-push handshake (receiver-initiated).
  final String? updatePlatform;
  final String? updateCurrentVersion;
  final bool? updateOk;
  final String? updateVersion;
  final String? updateFileName;
  final int? updateSize;
  final String? updateReason;

  MessageBody._(this.kind,
      {this.text,
      this.fromName,
      this.name,
      this.shortId,
      this.newName,
      this.fileId,
      this.fileSize,
      this.fileCompressed,
      this.fileOffset,
      this.fileData,
      this.fileHash,
      this.fileOk,
      this.fileError,
      this.callId,
      this.callReason,
      this.callSeq,
      this.callData,
      this.online,
      this.voiceName,
      this.voiceDuration,
      this.voiceData,
      this.imageName,
      this.imageWidth,
      this.imageHeight,
      this.imageData,
      this.imageThumb,
      this.since,
      this.before,
      this.limit,
      this.moments,
      this.deletedIds,
      this.momentId,
      this.momentIndex,
      this.momentData,
      this.reactType,
      this.momentTs,
      this.version,
      this.presencePlatform,
      this.updatePlatform,
      this.updateCurrentVersion,
      this.updateOk,
      this.updateVersion,
      this.updateFileName,
      this.updateSize,
      this.updateReason});

  MessageBody.chat(String text, String fromName)
      : this._(MessageBodyKind.chat, text: text, fromName: fromName);

  MessageBody.friendRequest(String name, String shortId)
      : this._(MessageBodyKind.friendRequest, name: name, shortId: shortId);

  MessageBody.friendAccept()
      : this._(MessageBodyKind.friendAccept);

  MessageBody.friendReject()
      : this._(MessageBodyKind.friendReject);

  MessageBody.friendRemove()
      : this._(MessageBodyKind.friendRemove);

  MessageBody.aboutMe(String name)
      : this._(MessageBodyKind.aboutMe, name: name);

  MessageBody.ping()
      : this._(MessageBodyKind.ping);

  MessageBody.nickChanged(String newName)
      : this._(MessageBodyKind.nickChanged, newName: newName);

  MessageBody.fileOffer(
      String fileId, String name, int fileSize, String fromName,
      {bool compressed = false})
      : this._(MessageBodyKind.fileOffer,
            fileId: fileId,
            name: name,
            fileSize: fileSize,
            fromName: fromName,
            fileCompressed: compressed);

  MessageBody.fileChunk(String fileId, int fileOffset, Uint8List fileData)
      : this._(MessageBodyKind.fileChunk,
            fileId: fileId, fileOffset: fileOffset, fileData: fileData);

  MessageBody.fileDone(String fileId, Uint8List fileHash)
      : this._(MessageBodyKind.fileDone, fileId: fileId, fileHash: fileHash);

  MessageBody.fileCancel(String fileId)
      : this._(MessageBodyKind.fileCancel, fileId: fileId);

  MessageBody.fileAck(String fileId, bool fileOk, String? fileError)
      : this._(MessageBodyKind.fileAck,
            fileId: fileId, fileOk: fileOk, fileError: fileError);

  MessageBody.callInvite(String callId, String fromName, String shortId)
      : this._(MessageBodyKind.callInvite,
            callId: callId, fromName: fromName, shortId: shortId);

  MessageBody.callAccept(String callId)
      : this._(MessageBodyKind.callAccept, callId: callId);

  MessageBody.callReject(String callId, String callReason)
      : this._(MessageBodyKind.callReject, callId: callId, callReason: callReason);

  MessageBody.callBusy(String callId)
      : this._(MessageBodyKind.callBusy, callId: callId);

  MessageBody.callHangup(String callId)
      : this._(MessageBodyKind.callHangup, callId: callId);

  MessageBody.callAudio(String callId, int callSeq, Uint8List callData)
      : this._(MessageBodyKind.callAudio,
            callId: callId, callSeq: callSeq, callData: callData);

  MessageBody.voiceMessage(String voiceName, int voiceDuration, Uint8List voiceData)
      : this._(MessageBodyKind.voiceMessage,
            voiceName: voiceName, voiceDuration: voiceDuration, voiceData: voiceData);

  MessageBody.imageMessage(String fromName, String name, int width, int height,
      Uint8List data, Uint8List thumb)
      : this._(MessageBodyKind.imageMessage,
            fromName: fromName,
            imageName: name,
            imageWidth: width,
            imageHeight: height,
            imageData: data,
            imageThumb: thumb);

  MessageBody.presenceProbe()
      : this._(MessageBodyKind.presenceProbe);

  MessageBody.presenceReply(bool online, {String? version, String? platform})
      : this._(MessageBodyKind.presenceReply,
            online: online, version: version, presencePlatform: platform);

  /// Receiver-initiated request for the peer's newest update package matching
  /// [platform] ('android'|'windows') and newer than [currentVersion].
  MessageBody.updateRequest({
    required String platform,
    required String currentVersion,
  }) : this._(MessageBodyKind.updateRequest,
            updatePlatform: platform, updateCurrentVersion: currentVersion);

  /// Response to [MessageBody.updateRequest]: [ok] mirrors whether a matching
  /// package will be sent. On success the peer streams the file right after via
  /// the ordinary fileOffer flow; the receiver auto-accepts it.
  MessageBody.updateReply({
    required bool ok,
    String? version,
    String? fileName,
    int? size,
    String? reason,
  }) : this._(MessageBodyKind.updateReply,
            updateOk: ok,
            updateVersion: version,
            updateFileName: fileName,
            updateSize: size,
            updateReason: reason);

  MessageBody.momentFetch({int? since, int? before, int limit = 20})
      : this._(MessageBodyKind.momentFetch,
            since: since, before: before, limit: limit);

  MessageBody.momentFeed(List<MomentPostInfo> posts,
      {List<String> deletedIds = const []})
      : this._(MessageBodyKind.momentFeed, moments: posts, deletedIds: deletedIds);

  MessageBody.momentImage(String postId, int index)
      : this._(MessageBodyKind.momentImage,
            momentId: postId, momentIndex: index);

  MessageBody.momentImageData(String postId, int index, Uint8List data)
      : this._(MessageBodyKind.momentImageData,
            momentId: postId, momentIndex: index, momentData: data);

  MessageBody.momentReact(String postId, int reactType,
      {String? text, required int ts})
      : this._(MessageBodyKind.momentReact,
            momentId: postId, reactType: reactType, text: text, momentTs: ts);

  MessageBody.momentDelete(String postId)
      : this._(MessageBodyKind.momentDelete, momentId: postId);

  Uint8List encode() {
    final w = PostcardWriter();
    w.writeVarint(kind.index);
    switch (kind) {
      case MessageBodyKind.aboutMe:
        w.writeString(name!);
        break;
      case MessageBodyKind.chat:
        w.writeString(text!);
        w.writeString(fromName!);
        break;
      case MessageBodyKind.ping:
        break;
      case MessageBodyKind.friendRequest:
        w.writeString(name!);
        w.writeString(shortId!);
        break;
      case MessageBodyKind.friendAccept:
      case MessageBodyKind.friendReject:
      case MessageBodyKind.friendRemove:
        break;
      case MessageBodyKind.nickChanged:
        w.writeString(newName!);
        break;
      case MessageBodyKind.fileOffer:
        w.writeString(fileId!);
        w.writeString(name!);
        w.writeVarint(fileSize!);
        w.writeString(fromName!);
        w.writeU8(fileCompressed ?? false ? 1 : 0);
        break;
      case MessageBodyKind.fileChunk:
        w.writeString(fileId!);
        w.writeVarint(fileOffset!);
        w.writeBytes(fileData!);
        break;
      case MessageBodyKind.fileDone:
        w.writeString(fileId!);
        w.writeRawBytes(fileHash!);
        break;
      case MessageBodyKind.fileCancel:
        w.writeString(fileId!);
        break;
      case MessageBodyKind.fileAck:
        w.writeString(fileId!);
        w.writeU8(fileOk! ? 1 : 0);
        if (fileError != null) {
          w.writeU8(1);
          w.writeString(fileError!);
        } else {
          w.writeU8(0);
        }
        break;
      case MessageBodyKind.callInvite:
        w.writeString(callId!);
        w.writeString(fromName!);
        w.writeString(shortId!);
        break;
      case MessageBodyKind.callAccept:
        w.writeString(callId!);
        break;
      case MessageBodyKind.callReject:
        w.writeString(callId!);
        w.writeString(callReason!);
        break;
      case MessageBodyKind.callBusy:
        w.writeString(callId!);
        break;
      case MessageBodyKind.callHangup:
        w.writeString(callId!);
        break;
      case MessageBodyKind.callAudio:
        w.writeString(callId!);
        w.writeVarint(callSeq!);
        w.writeBytes(callData!);
        break;
      case MessageBodyKind.voiceMessage:
        w.writeString(voiceName!);
        w.writeVarint(voiceDuration!);
        w.writeBytes(voiceData!);
        break;
      case MessageBodyKind.imageMessage:
        w.writeString(fromName!);
        w.writeString(imageName!);
        w.writeVarint(imageWidth!);
        w.writeVarint(imageHeight!);
        w.writeBytes(imageData!);
        w.writeBytes(imageThumb!);
        break;
      case MessageBodyKind.presenceProbe:
        break;
      case MessageBodyKind.presenceReply:
        w.writeU8(online! ? 1 : 0);
        if (version != null && version!.isNotEmpty) {
          w.writeU8(1);
          w.writeString(version!);
        } else {
          w.writeU8(0);
        }
        if (presencePlatform != null && presencePlatform!.isNotEmpty) {
          w.writeU8(1);
          w.writeString(presencePlatform!);
        } else {
          w.writeU8(0);
        }
        break;
      case MessageBodyKind.updateRequest:
        w.writeString(updatePlatform ?? '');
        w.writeString(updateCurrentVersion ?? '');
        break;
      case MessageBodyKind.updateReply:
        w.writeU8(updateOk == true ? 1 : 0);
        if (updateOk == true) {
          w.writeString(updateVersion ?? '');
          w.writeString(updateFileName ?? '');
          w.writeVarint(updateSize ?? 0);
        } else {
          w.writeString(updateReason ?? '');
        }
        break;
      case MessageBodyKind.momentFetch:
        final s = since;
        final b = before;
        if (s != null) {
          w.writeU8(1);
          w.writeVarint(s);
        } else {
          w.writeU8(0);
        }
        if (b != null) {
          w.writeU8(1);
          w.writeVarint(b);
        } else {
          w.writeU8(0);
        }
        w.writeVarint(limit ?? 20);
        break;
      case MessageBodyKind.momentFeed:
        final posts = moments ?? const <MomentPostInfo>[];
        w.writeVarint(posts.length);
        for (final p in posts) {
          w.writeString(p.id);
          w.writeString(p.text);
          w.writeU8(p.imageCount);
          w.writeVarint(p.ts);
        }
        final dels = deletedIds ?? const <String>[];
        w.writeVarint(dels.length);
        for (final d in dels) {
          w.writeString(d);
        }
        break;
      case MessageBodyKind.momentImage:
        w.writeString(momentId!);
        w.writeU8(momentIndex!);
        break;
      case MessageBodyKind.momentImageData:
        w.writeString(momentId!);
        w.writeU8(momentIndex!);
        w.writeBytes(momentData!);
        break;
      case MessageBodyKind.momentReact:
        w.writeString(momentId!);
        w.writeU8(reactType!);
        if (text != null) {
          w.writeU8(1);
          w.writeString(text!);
        } else {
          w.writeU8(0);
        }
        w.writeVarint(momentTs!);
        break;
      case MessageBodyKind.momentDelete:
        w.writeString(momentId!);
        break;
    }
    return w.toBytes();
  }

  static MessageBody decode(Uint8List bytes) {
    final r = PostcardReader(bytes);
    final variant = r.readVarint();
    switch (variant) {
      case 0: // AboutMe
        return MessageBody._(MessageBodyKind.aboutMe, name: r.readString());
      case 1: // Chat
        return MessageBody._(MessageBodyKind.chat, text: r.readString(), fromName: r.readString());
      case 2: // Ping
        return MessageBody._(MessageBodyKind.ping);
      case 3: // FriendRequest
        return MessageBody._(MessageBodyKind.friendRequest, name: r.readString(), shortId: r.readString());
      case 4: // FriendAccept
        return MessageBody._(MessageBodyKind.friendAccept);
      case 5: // FriendReject
        return MessageBody._(MessageBodyKind.friendReject);
      case 6: // FriendRemove
        return MessageBody._(MessageBodyKind.friendRemove);
      case 7: // NickChanged
        return MessageBody._(MessageBodyKind.nickChanged, newName: r.readString());
      case 8: // FileOffer { id, name, size, from_name, compressed }
        return MessageBody._(MessageBodyKind.fileOffer,
            fileId: r.readString(),
            name: r.readString(),
            fileSize: r.readVarint(),
            fromName: r.readString(),
            fileCompressed: r.readU8() == 1);
      case 9: // FileChunk { id, offset, data }
        return MessageBody._(MessageBodyKind.fileChunk,
            fileId: r.readString(), fileOffset: r.readVarint(), fileData: r.readBytes());
      case 10: // FileDone { id, hash: [u8;32] }
        return MessageBody._(MessageBodyKind.fileDone, fileId: r.readString(), fileHash: r.readRawBytes(32));
      case 11: // FileCancel { id }
        return MessageBody._(MessageBodyKind.fileCancel, fileId: r.readString());
      case 12: // FileAck { id, ok, error: Option<String> }
        final aid = r.readString();
        final ok = r.readU8() == 1;
        final hasErr = r.readU8() == 1;
        return MessageBody._(MessageBodyKind.fileAck,
            fileId: aid, fileOk: ok, fileError: hasErr ? r.readString() : null);
      case 13: // VoiceMessage { from_name, duration_ms, data }
        return MessageBody._(MessageBodyKind.voiceMessage,
            voiceName: r.readString(), voiceDuration: r.readVarint(), voiceData: r.readBytes());
      case 14: // ImageMessage { from_name, name, width, height, data, thumb }
        return MessageBody._(
            MessageBodyKind.imageMessage,
            fromName: r.readString(),
            imageName: r.readString(),
            imageWidth: r.readVarint(),
            imageHeight: r.readVarint(),
            imageData: r.readBytes(),
            imageThumb: r.readBytes());
      case 15: // CallInvite { call_id, from_name, from_short_id }
        return MessageBody._(MessageBodyKind.callInvite,
            callId: r.readString(), fromName: r.readString(), shortId: r.readString());
      case 16: // CallAccept { call_id }
        return MessageBody._(MessageBodyKind.callAccept, callId: r.readString());
      case 17: // CallReject { call_id, reason }
        return MessageBody._(MessageBodyKind.callReject, callId: r.readString(), callReason: r.readString());
      case 18: // CallBusy { call_id }
        return MessageBody._(MessageBodyKind.callBusy, callId: r.readString());
      case 19: // CallHangup { call_id }
        return MessageBody._(MessageBodyKind.callHangup, callId: r.readString());
      case 20: // CallAudio { call_id, seq, data }
        return MessageBody._(MessageBodyKind.callAudio,
            callId: r.readString(), callSeq: r.readVarint(), callData: r.readBytes());
      case 21: // PresenceProbe
        return MessageBody._(MessageBodyKind.presenceProbe);
      case 22: // PresenceReply { online, version?, platform?: Option<String> }
        final online = r.readU8() == 1;
        String? version;
        String? platform;
        if (!r.isAtEnd) {
          try {
            if (r.readU8() == 1) version = r.readString();
          } catch (_) {
            // Old peers encode only `online`; tolerate the short payload.
          }
        }
        if (!r.isAtEnd) {
          try {
            if (r.readU8() == 1) platform = r.readString();
          } catch (_) {}
        }
        return MessageBody._(MessageBodyKind.presenceReply,
            online: online, version: version, presencePlatform: platform);
      case 23: // MomentFetch { since: Option<u64>, before: Option<u64>, limit: u16 }
        final s = r.readU8() == 1 ? r.readVarint() : null;
        final b = r.readU8() == 1 ? r.readVarint() : null;
        return MessageBody._(MessageBodyKind.momentFetch,
            since: s, before: b, limit: r.readVarint());
      case 24: // MomentFeed { posts: Vec<MomentPost>, deleted_ids: Vec<String> }
        final n = r.readVarint();
        final posts = <MomentPostInfo>[];
        for (var i = 0; i < n; i++) {
          posts.add(MomentPostInfo(
              r.readString(), r.readString(), r.readU8(), r.readVarint()));
        }
        final dn = r.readVarint();
        final dels = <String>[];
        for (var i = 0; i < dn; i++) {
          dels.add(r.readString());
        }
        return MessageBody._(MessageBodyKind.momentFeed,
            moments: posts, deletedIds: dels);
      case 25: // MomentImage { post_id, index }
        return MessageBody._(MessageBodyKind.momentImage,
            momentId: r.readString(), momentIndex: r.readU8());
      case 26: // MomentImageData { post_id, index, data }
        return MessageBody._(MessageBodyKind.momentImageData,
            momentId: r.readString(),
            momentIndex: r.readU8(),
            momentData: r.readBytes());
      case 27: // MomentReact { post_id, react_type, text: Option<String>, ts }
        final rid = r.readString();
        final rt = r.readU8();
        final hasText = r.readU8() == 1;
        return MessageBody._(MessageBodyKind.momentReact,
            momentId: rid,
            reactType: rt,
            text: hasText ? r.readString() : null,
            momentTs: r.readVarint());
      case 28: // MomentDelete { post_id }
        return MessageBody._(MessageBodyKind.momentDelete,
            momentId: r.readString());
      case 29: // UpdateRequest { platform, current_version }
        return MessageBody._(MessageBodyKind.updateRequest,
            updatePlatform: r.readString(), updateCurrentVersion: r.readString());
      case 30: // UpdateReply { ok, version, file_name, size } | { ok=false, reason }
        final ok = r.readU8() == 1;
        if (ok) {
          return MessageBody._(MessageBodyKind.updateReply,
              updateOk: true,
              updateVersion: r.readString(),
              updateFileName: r.readString(),
              updateSize: r.readVarint());
        }
        return MessageBody._(MessageBodyKind.updateReply,
            updateOk: false, updateReason: r.readString());
      default:
        throw Exception('Unknown MessageBody variant: $variant');
    }
  }
}

// --- SignedMessage (matches Rust protocol::SignedMessage) ---

class SignedMessage {
  final Uint8List from; // 32 bytes PublicKey
  final Uint8List data; // postcard-encoded MessageBody
  final Uint8List signature; // 64 bytes ed25519

  SignedMessage(this.from, this.data, this.signature);

  /// Sign a MessageBody with a SecretKey, returns postcard-encoded SignedMessage bytes.
  /// Format matches Rust postcard serialization:
  ///   PublicKey(32 raw) + Bytes(data: varint-len + raw) + ByteArray<64>(sig: varint-len + raw)
  static Uint8List sign(SecretKey secretKey, MessageBody body) {
    final bodyBytes = body.encode();
    final sig = secretKey.sign(bodyBytes);
    final sigBytes = sig.toBytes();

    final w = PostcardWriter();
    w.writeRawBytes(secretKey.publicKey.asBytes()); // 32 bytes (no varint)
    w.writeVarint(bodyBytes.length); // varint length prefix for data
    w.writeRawBytes(bodyBytes); // raw body
    w.writeVarint(sigBytes.length); // varint length prefix for signature (64)
    w.writeRawBytes(sigBytes); // 64 bytes
    return w.toBytes();
  }

  /// Verify and decode a SignedMessage. Returns (senderPublicKey, MessageBody).
  /// Format matches Rust postcard serialization:
  ///   PublicKey(32 raw) + Bytes(data: varint-len + raw) + ByteArray<64>(sig: varint-len + raw)
  static (PublicKey, MessageBody) verify(Uint8List bytes) {
    if (bytes.length < 32 + 1 + 1 + 64) {
      throw Exception('SignedMessage too short: ${bytes.length} bytes');
    }

    final fromBytes = bytes.sublist(0, 32);
    final publicKey = PublicKey.fromBytes(fromBytes);

    // Read data: varint length prefix + raw bytes
    final reader = PostcardReader(bytes.sublist(32));
    final data = reader.readBytes();
    reader.readVarint(); // signature length prefix (64)
    final sigBytes = reader.readRawBytes(64);

    final sig = Signature.fromBytes(sigBytes);
    if (!publicKey.verify(data, sig)) {
      throw Exception('Invalid signature');
    }

    final body = MessageBody.decode(data);
    return (publicKey, body);
  }
}

enum MoonDnsRequestKind { register, lookup, lookupByName, delete, list }

class MoonDnsRequest {
  final MoonDnsRequestKind kind;
  final Uint8List? id;
  final String? name;
  final EndpointAddr? addr;
  final String? shortId;

  MoonDnsRequest.register(this.id, this.name, this.addr)
      : kind = MoonDnsRequestKind.register,
        shortId = null;

  MoonDnsRequest.lookup(this.shortId)
      : kind = MoonDnsRequestKind.lookup,
        id = null,
        name = null,
        addr = null;

  MoonDnsRequest.lookupByName(this.name)
      : kind = MoonDnsRequestKind.lookupByName,
        id = null,
        shortId = null,
        addr = null;

  MoonDnsRequest.delete(this.shortId)
      : kind = MoonDnsRequestKind.delete,
        id = null,
        name = null,
        addr = null;

  MoonDnsRequest.list()
      : kind = MoonDnsRequestKind.list,
        id = null,
        name = null,
        addr = null,
        shortId = null;

  Uint8List encode() {
    final w = PostcardWriter();
    w.writeVarint(kind.index);
    switch (kind) {
      case MoonDnsRequestKind.register:
        w.writeRawBytes(id!);
        w.writeString(name!);
        // EndpointAddr: use iroh's built-in postcard encoder
        w.writeRawBytes(addr!.encode());
        break;
      case MoonDnsRequestKind.lookup:
        w.writeString(shortId!);
        break;
      case MoonDnsRequestKind.lookupByName:
        w.writeString(name!);
        break;
      case MoonDnsRequestKind.delete:
        w.writeString(shortId!);
        break;
      case MoonDnsRequestKind.list:
        break;
    }
    return w.toBytes();
  }
}

enum MoonDnsResponseKind { registered, lookupResult, deleted, listResult, error }

class MoonDnsResponse {
  final MoonDnsResponseKind kind;
  final String? shortId;
  final String? name;
  final MoonDnsRegistryEntry? entry;
  final List<MoonDnsRegistryEntry>? entries;
  final String? msg;

  MoonDnsResponse.registered(this.shortId)
      : kind = MoonDnsResponseKind.registered,
        name = null,
        entry = null,
        entries = null,
        msg = null;

  MoonDnsResponse.lookupResult(this.entry)
      : kind = MoonDnsResponseKind.lookupResult,
        shortId = null,
        name = null,
        entries = null,
        msg = null;

  MoonDnsResponse.listResult(this.entries)
      : kind = MoonDnsResponseKind.listResult,
        shortId = null,
        name = null,
        entry = null,
        msg = null;

  MoonDnsResponse.deleted(this.shortId)
      : kind = MoonDnsResponseKind.deleted,
        name = null,
        entry = null,
        entries = null,
        msg = null;

  MoonDnsResponse.error(this.msg)
      : kind = MoonDnsResponseKind.error,
        shortId = null,
        name = null,
        entry = null,
        entries = null;

  static MoonDnsResponse decode(Uint8List bytes) {
    final r = PostcardReader(bytes);
    final variant = r.readVarint();
    switch (variant) {
      case 0: // Registered { short_id: String }
        return MoonDnsResponse.registered(r.readString());
      case 1: // LookupResult { entry: Option<DnsRegistryEntry> }
        if (r.readU8() == 0) {
          return MoonDnsResponse.lookupResult(null);
        }
        return MoonDnsResponse.lookupResult(MoonDnsRegistryEntry.decode(r));
      case 2: // Deleted { short_id: String }
        return MoonDnsResponse.deleted(r.readString());
      case 3: // ListResult { entries: Vec<DnsRegistryEntry> }
        final count = r.readVarint();
        final entries = <MoonDnsRegistryEntry>[];
        for (var i = 0; i < count; i++) {
          entries.add(MoonDnsRegistryEntry.decode(r));
        }
        return MoonDnsResponse.listResult(entries);
      case 4: // Error { msg: String }
        return MoonDnsResponse.error(r.readString());
      default:
        throw Exception('Unknown DNS response variant: $variant');
    }
  }
}
