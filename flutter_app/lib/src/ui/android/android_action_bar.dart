import 'package:flutter/material.dart';

class AndroidAction {
  const AndroidAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
}

class AndroidActionMenu extends StatelessWidget {
  const AndroidActionMenu({
    super.key,
    required this.label,
    required this.actions,
  });
  final String label;
  final List<AndroidAction> actions;

  @override
  Widget build(BuildContext context) => PopupMenuButton<int>(
    tooltip: label,
    icon: const Icon(Icons.more_vert),
    onSelected: (index) => actions[index].onPressed?.call(),
    itemBuilder: (_) => [
      for (var i = 0; i < actions.length; i++)
        PopupMenuItem(
          value: i,
          enabled: actions[i].onPressed != null,
          child: Row(
            children: [
              Icon(actions[i].icon),
              const SizedBox(width: 12),
              Flexible(child: Text(actions[i].label)),
            ],
          ),
        ),
    ],
  );
}
