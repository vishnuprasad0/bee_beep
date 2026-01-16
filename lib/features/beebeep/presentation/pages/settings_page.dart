import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/use_cases/load_discovery_name.dart';
import '../../domain/use_cases/update_discovery_name.dart';
import 'logs_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _displayNameController = TextEditingController();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentName();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentName() async {
    final loader = context.read<LoadDiscoveryName>();
    final name = await loader(fallback: 'BeeBEEP Dart');
    if (!mounted) return;
    _displayNameController.text = name;
  }

  Future<void> _saveName() async {
    final value = _displayNameController.text.trim();
    if (value.isEmpty) return;

    setState(() => _isSaving = true);
    final updater = context.read<UpdateDiscoveryName>();
    await updater(value);
    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Discovery name updated')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('BeeBEEP Dart Client'),
            subtitle: Text('Version 1.0.0'),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Discovery name',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _displayNameController,
              decoration: const InputDecoration(
                hintText: 'Device name',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _saveName(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _saveName,
                icon: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Save'),
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.description),
            title: const Text('Connection logs'),
            subtitle: const Text('View discovery and connection activity'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LogsPage()),
              );
            },
          ),
        ],
      ),
    );
  }
}
