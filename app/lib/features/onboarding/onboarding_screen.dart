import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers.dart';

/// One-time first-run intro (mobile). Three slides covering the offline-first
/// model, optional sync, and key features; "Get started" marks it seen so the
/// app drops into the notes screen and never shows it again.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static List<({IconData icon, String title, String body})> _slidesFor(
          AppLocalizations l10n) =>
      [
        (
          icon: Icons.bolt_outlined,
          title: l10n.onboardOfflineTitle,
          body: l10n.onboardOfflineBody,
        ),
        (
          icon: Icons.sync_outlined,
          title: l10n.onboardSyncTitle,
          body: l10n.onboardSyncBody,
        ),
        (
          icon: Icons.group_outlined,
          title: l10n.onboardShareTitle,
          body: l10n.onboardShareBody,
        ),
        (
          icon: Icons.checklist_outlined,
          title: l10n.onboardNotesTitle,
          body: l10n.onboardNotesBody,
        ),
      ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finish() => ref.read(onboardingSeenProvider.notifier).markSeen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final slides = _slidesFor(context.l10n);
    final isLast = _page == slides.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: Text(context.l10n.onboardSkip)),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final s = slides[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(s.icon, size: 96, color: theme.colorScheme.primary),
                        const SizedBox(height: 32),
                        Text(s.title,
                            style: theme.textTheme.headlineSmall,
                            textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        Text(s.body,
                            style: theme.textTheme.bodyLarge,
                            textAlign: TextAlign.center),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < slides.length; i++)
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: isLast
                      ? _finish
                      : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                  child: Text(isLast ? context.l10n.onboardGetStarted : context.l10n.onboardNext),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
