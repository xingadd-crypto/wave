import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_wave/services/postcard.dart';

void main() {
  group('imageMessage wire format (must match CLI protocol.rs)', () {
    test('encode matches Rust postcard bytes exactly', () {
      final body = MessageBody.imageMessage('alice', 'a.png', 800, 600,
          Uint8List.fromList([1, 2, 3]), Uint8List.fromList([9, 8, 7]));
      final bytes = body.encode();
      // variant 14 + "alice" + "a.png" + width 800 + height 600 + data + thumb
      expect(
        bytes,
        Uint8List.fromList([
          0x0e, // ImageMessage variant (14)
          5, ...'alice'.codeUnits, //
          5, ...'a.png'.codeUnits, //
          0xa0, 0x06, // u32 800 varint
          0xd8, 0x04, // u32 600 varint
          3, 1, 2, 3, // Bytes [1,2,3]
          3, 9, 8, 7, // Bytes [9,8,7]
        ]),
      );
    });

    test('decode round-trips imageMessage fields', () {
      final body = MessageBody.imageMessage('bob', 'photo.jpg', 1280, 720,
          Uint8List.fromList([5, 6, 7, 8]), Uint8List.fromList([11, 12]));
      final decoded = MessageBody.decode(body.encode());
      expect(decoded.kind, MessageBodyKind.imageMessage);
      expect(decoded.fromName, 'bob');
      expect(decoded.imageName, 'photo.jpg');
      expect(decoded.imageWidth, 1280);
      expect(decoded.imageHeight, 720);
      expect(decoded.imageData, Uint8List.fromList([5, 6, 7, 8]));
      expect(decoded.imageThumb, Uint8List.fromList([11, 12]));
    });

    test('variant indices match CLI (image=14, call/presence shifted)', () {
      expect(MessageBody.chat('hi', 'me').encode()[0], 1);
      expect(MessageBody.nickChanged('x').encode()[0], 7);
      expect(MessageBody.voiceMessage('me', 100, Uint8List(1)).encode()[0], 13);
      expect(
        MessageBody.imageMessage('me', 'a.png', 1, 1, Uint8List(1), Uint8List(1))
            .encode()[0],
        14,
      );
      // Decoded old numeric variant 15 must now surface as CallInvite.
      final call = MessageBody.callInvite('call-1', 'alice', 'a1b2');
      final callBytes = call.encode();
      expect(callBytes[0], 15);
      final decoded = MessageBody.decode(callBytes);
      expect(decoded.kind, MessageBodyKind.callInvite);
      expect(decoded.callId, 'call-1');
    });
  });
}