import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

class LanguageSelectScreen extends StatelessWidget {
  const LanguageSelectScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'ВЫБЕРИТЕ ЯЗЫК\nSELECT LANGUAGE\nVALI KEEL',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 60),
            _LangButton(label: 'Eesti', lang: 'et'),
            const SizedBox(height: 20),
            _LangButton(label: 'English', lang: 'en'),
            const SizedBox(height: 20),
            _LangButton(label: 'Русский', lang: 'ru'),
          ],
        ),
      ),
    );
  }
}

class _LangButton extends StatelessWidget {
  final String label;
  final String lang;
  const _LangButton({required this.label, required this.lang});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 72,
      child: ElevatedButton(
        onPressed: () {
          final notifier = context.read<AppNotifier>();
          notifier.setLanguage(lang);
          notifier.transition(AppState.standby);
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2E2E2E),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF2EC4B6), width: 1.5),
          ),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        child: Text(label),
      ),
    );
  }
}
