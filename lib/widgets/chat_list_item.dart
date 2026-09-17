import 'package:flutter/material.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/theme/app_theme.dart';
import 'package:flutter_wave/services/app_version.dart';
import 'package:flutter_wave/services/update_service.dart';

class ChatListItem extends StatelessWidget {
  final Friend friend;
  final VoidCallback? onTap;

  const ChatListItem({
    super.key,
    required this.friend,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
            child: Text(
              friend.displayName[0].toUpperCase(),
              style: const TextStyle(
                fontSize: 20,
                color: AppTheme.primaryColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: friend.isOnline
                    ? AppTheme.successColor
                    : AppTheme.textHint,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              friend.displayName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (friend.version != null && friend.version!.trim().isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _versionColor(friend.version!).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _versionColor(friend.version!).withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
              child: Text(
                'v${friend.version}',
                style: TextStyle(
                  fontSize: 11,
                  color: _versionColor(friend.version!),
                ),
              ),
            ),
          if (friend.lastMessageTime != null)
            Text(
              _formatTime(friend.lastMessageTime!),
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.textHint,
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              friend.lastMessage ?? 'No messages yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: friend.lastMessage != null
                    ? AppTheme.textSecondary
                    : AppTheme.textHint,
              ),
            ),
          ),
          if (friend.unreadCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${friend.unreadCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(time.year, time.month, time.day);

    if (messageDate == today) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else {
      return '${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')}';
    }
  }

  /// Green when the friend runs a newer version than mine, grey otherwise.
  Color _versionColor(String version) => UpdateService.isNewerThan(appVersion, version)
      ? AppTheme.successColor
      : AppTheme.textHint;
}
