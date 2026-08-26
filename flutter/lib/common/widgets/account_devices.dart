import 'dart:async';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/user_model.dart';
import 'package:get/get.dart';

import '../../common.dart';
import 'dialog.dart';
import 'login.dart';

void accountDevicesDialog([BuildContext? hostContext]) {
  if (!gFFI.userModel.isLogin) {
    loginDialog();
    return;
  }

  unawaited(gFFI.userModel.loadDevices());
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Row(
        children: [
          const Icon(Icons.devices_rounded, color: MyTheme.accent),
          const SizedBox(width: 10),
          Text(translate('My devices')),
        ],
      ),
      contentBoxConstraints:
          const BoxConstraints(maxWidth: 560, maxHeight: 520),
      content: Obx(() {
        final model = gFFI.userModel;
        if (model.devicesLoading.value && model.devices.isEmpty) {
          return const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (model.devicesError.value.isNotEmpty && model.devices.isEmpty) {
          return _DeviceLoadError(
            message: model.devicesError.value,
            onRetry: model.loadDevices,
          );
        }
        if (model.devices.isEmpty) {
          return SizedBox(
            height: 120,
            child: Center(child: Text(translate('No devices'))),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (model.devicesLoading.value)
              const LinearProgressIndicator(minHeight: 2),
            if (model.devicesError.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  model.devicesError.value,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: model.devices.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) => _DeviceTile(
                  device: model.devices[index],
                  close: close,
                  hostContext: hostContext ?? context,
                ),
              ),
            ),
          ],
        );
      }),
      actions: [
        dialogButton('Refresh',
            onPressed: gFFI.userModel.loadDevices, isOutline: true),
        dialogButton('Close', onPressed: close),
      ],
      onCancel: close,
    );
  });
}

class _DeviceLoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _DeviceLoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(translate('Retry')),
              ),
            ],
          ),
        ),
      );
}

class _DeviceTile extends StatelessWidget {
  final AccountDevice device;
  final VoidCallback close;
  final BuildContext hostContext;

  const _DeviceTile({
    required this.device,
    required this.close,
    required this.hostContext,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = device.name.isEmpty ? device.rustdeskId : device.name;
    final details = <String>[
      'ID ${device.rustdeskId}',
      if (device.os.isNotEmpty) device.os,
      device.online
          ? translate('Online')
          : '${translate('Last seen')}: ${_formatLastSeen(device.lastSeenAt)}',
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.computer_rounded, size: 30),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: device.online ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).dialogBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child:
                Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (device.isCurrent)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: MyTheme.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                translate('This device'),
                style: const TextStyle(fontSize: 11, color: MyTheme.accent),
              ),
            ),
        ],
      ),
      subtitle: Text(details.join(' · '), maxLines: 2),
      trailing: PopupMenuButton<_DeviceAction>(
        tooltip: translate('Actions'),
        onSelected: (action) => _handleAction(action),
        itemBuilder: (_) => [
          if (!device.isCurrent)
            PopupMenuItem(
              value: _DeviceAction.connect,
              child: Text(translate('Connect')),
            ),
          PopupMenuItem(
            value: _DeviceAction.rename,
            child: Text(translate('Rename')),
          ),
          PopupMenuItem(
            value: _DeviceAction.revoke,
            child: Text(translate('Remove device')),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(_DeviceAction action) async {
    switch (action) {
      case _DeviceAction.connect:
        close();
        await connect(hostContext, device.rustdeskId);
        break;
      case _DeviceAction.rename:
        renameDialog(
          oldName: device.name,
          validator: (value) => value == null || value.trim().isEmpty
              ? translate('Name is required')
              : null,
          onSubmit: (value) async {
            if (!await gFFI.userModel.renameDevice(device.id, value)) {
              BotToast.showText(
                contentColor: Colors.red,
                text: translate('Failed to rename device'),
              );
            }
          },
        );
        break;
      case _DeviceAction.revoke:
        _confirmRevokeDevice(device, close);
        break;
    }
  }
}

enum _DeviceAction { connect, rename, revoke }

void _confirmRevokeDevice(AccountDevice device, VoidCallback devicesClose) {
  var submitting = false;
  gFFI.dialogManager.show((setState, close, context) {
    Future<void> submit() async {
      setState(() => submitting = true);
      final success = await gFFI.userModel.revokeDevice(device);
      close();
      if (device.isCurrent && success) {
        devicesClose();
      } else if (!success) {
        BotToast.showText(
          contentColor: Colors.red,
          text: translate('Failed to remove device'),
        );
      }
    }

    return CustomAlertDialog(
      title: Text(translate('Remove device')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(translate(device.isCurrent
              ? 'Removing this device will log it out.'
              : 'This device will be logged out and can no longer use account access.')),
          if (submitting) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        dialogButton('Cancel',
            onPressed: submitting ? null : close, isOutline: true),
        dialogButton('Remove', onPressed: submitting ? null : submit),
      ],
      onCancel: submitting ? null : close,
    );
  });
}

String _formatLastSeen(int timestamp) {
  if (timestamp <= 0) return translate('Unknown');
  final value = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000).toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
