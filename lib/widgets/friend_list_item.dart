import 'package:flutter/material.dart';
import 'package:flutter_wave/models/friend.dart';
import 'package:flutter_wave/theme/app_theme.dart';

class FriendListItem extends StatelessWidget {
  final Friend friend;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showActions;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final bool showCancelButton;
  final VoidCallback? onCancel;

  const FriendListItem({
    super.key,
    required this.friend,
    this.onTap,
    this.onLongPress,
    this.showActions = false,
    this.onAccept,
    this.onReject,
    this.showCancelButton = false,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
        child: Text(
          friend.displayName[0].toUpperCase(),
          style: const TextStyle(
            fontSize: 18,
            color: AppTheme.primaryColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(
        friend.displayName,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(
        friend.secondaryLabel.isNotEmpty
            ? '#${friend.secondaryLabel}'
            : friend.id,
        style: const TextStyle(
          color: AppTheme.textSecondary,
        ),
      ),
      trailing: _buildTrailing(),
    );
  }

  Widget? _buildTrailing() {
    if (showActions) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(
              Icons.check_circle,
              color: AppTheme.successColor,
            ),
            onPressed: onAccept,
            tooltip: 'Accept',
          ),
          IconButton(
            icon: const Icon(
              Icons.cancel,
              color: AppTheme.errorColor,
            ),
            onPressed: onReject,
            tooltip: 'Reject',
          ),
        ],
      );
    }

    if (showCancelButton) {
      return TextButton(
        onPressed: onCancel,
        child: const Text(
          'Cancel',
          style: TextStyle(color: AppTheme.errorColor),
        ),
      );
    }

    return null;
  }
}
