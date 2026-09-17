package com.wave.ggwave;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/** ggwave encode/decode DSP binding (pure native compute, no audio I/O). */
public class GgwaveNativePlugin implements FlutterPlugin, MethodCallHandler {
  private static final String CHANNEL = "ggwave_native";

  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    try {
      System.loadLibrary("ggwave_native_jni");
    } catch (UnsatisfiedLinkError e) {
      // Native library missing; native calls will fail loudly below.
    }
    channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
  }

  @Override
  public void onMethodCall(MethodCall call, Result result) {
    switch (call.method) {
      case "encode": {
        String payload = call.argument("payload");
        Boolean audible = call.argument("audible");
        if (payload == null || payload.isEmpty()) {
          result.error("bad_argument", "encode expects a non-empty payload", null);
          return;
        }
        byte[] pcm = nativeEncode(payload, audible != null && audible);
        if (pcm == null) {
          result.error("encode_failed", "ggwave could not encode payload (too long?)", null);
        } else {
          result.success(pcm);
        }
        break;
      }
      case "decode": {
        byte[] pcm = call.argument("pcm");
        if (pcm == null || pcm.length == 0) {
          result.success(null);
          return;
        }
        result.success(nativeDecode(pcm));
        break;
      }
      default:
        result.notImplemented();
    }
  }

  private static native byte[] nativeEncode(String payload, boolean audible);

  private static native String nativeDecode(byte[] pcm);
}