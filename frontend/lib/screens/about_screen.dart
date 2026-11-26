import 'package:flutter/material.dart';

/// «حول النظام»: the system's name and version -- as the old settings tab
/// said them, now on a page of its own (settings spec v2, phase 7 cleanup).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('حول النظام')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: cs.surfaceContainerHigh,
            child: ListTile(
              key: const Key('about-app'),
              leading: CircleAvatar(
                radius: 26,
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.diamond, color: cs.onPrimaryContainer, size: 28),
              ),
              title: Text('نظام مجوهرات خالد',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text('الإصدار 2.1 — نظام متكامل لإدارة محلات الذهب والمجوهرات.',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
          ),
        ],
      ),
    );
  }
}
