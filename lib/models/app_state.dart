import 'package:flutter/material.dart';

class AppState {
  final bool isInitialized;
  final bool isRegistered;
  final String? userId;
  final String? shortId;
  final String? nickname;
  final ThemeMode themeMode;
  final bool isConnected;
  final String? serverAddress;

  AppState({
    this.isInitialized = false,
    this.isRegistered = false,
    this.userId,
    this.shortId,
    this.nickname,
    this.themeMode = ThemeMode.system,
    this.isConnected = false,
    this.serverAddress,
  });

  AppState copyWith({
    bool? isInitialized,
    bool? isRegistered,
    String? userId,
    String? shortId,
    String? nickname,
    ThemeMode? themeMode,
    bool? isConnected,
    String? serverAddress,
  }) {
    return AppState(
      isInitialized: isInitialized ?? this.isInitialized,
      isRegistered: isRegistered ?? this.isRegistered,
      userId: userId ?? this.userId,
      shortId: shortId ?? this.shortId,
      nickname: nickname ?? this.nickname,
      themeMode: themeMode ?? this.themeMode,
      isConnected: isConnected ?? this.isConnected,
      serverAddress: serverAddress ?? this.serverAddress,
    );
  }
}
