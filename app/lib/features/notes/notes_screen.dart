import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';

/// Placeholder home shown when authenticated. The Keep-style notes grid is
/// built in the next chunk.
class NotesScreen extends ConsumerWidget {
  const NotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pb = ref.watch(pocketBaseProvider);
    final email = pb.authStore.record?.data['email'] as String? ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notes'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => pb.authStore.clear(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.note_alt_outlined, size: 64),
            const SizedBox(height: 12),
            Text('Signed in as $email'),
            const SizedBox(height: 4),
            const Text('Notes UI coming next.'),
          ],
        ),
      ),
    );
  }
}
