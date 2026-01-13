import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'src/presentation/app/app_di.dart';
import 'src/presentation/bloc/logs/logs_cubit.dart';
import 'src/presentation/bloc/peers/peers_cubit.dart';
import 'src/presentation/pages/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final di = AppDi(displayName: 'BeeBEEP Dart');
  await di.startNode();

  runApp(BeeBeepApp(di: di));
}

class BeeBeepApp extends StatefulWidget {
  const BeeBeepApp({super.key, required this.di});

  final AppDi di;

  @override
  State<BeeBeepApp> createState() => _BeeBeepAppState();
}

class _BeeBeepAppState extends State<BeeBeepApp> {
  @override
  void dispose() {
    widget.di.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [RepositoryProvider.value(value: widget.di.connectToPeer)],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (_) => PeersCubit(
              startDiscovery: widget.di.startDiscovery,
              stopDiscovery: widget.di.stopDiscovery,
              watchPeers: widget.di.watchPeers,
              watchPeerIdentities: widget.di.watchPeerIdentities,
            ),
          ),
          BlocProvider(
            create: (_) => LogsCubit(watchLogs: widget.di.watchLogs),
          ),
        ],
        child: MaterialApp(
          title: 'BeeBEEP',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          home: const HomePage(),
        ),
      ),
    );
  }
}
