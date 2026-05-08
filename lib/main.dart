import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'offline/models/note.dart';
import 'offline/repository/notes_repository.dart';
import 'offline/storage/local_note_store.dart';
import 'offline/sync/firebase_mock.dart';
import 'offline/sync/sync_logger.dart';
import 'offline/sync/sync_queue.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Notes Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const OfflineDemoPage(),
    );
  }
}

class OfflineDemoPage extends StatefulWidget {
  const OfflineDemoPage({super.key});

  @override
  State<OfflineDemoPage> createState() => _OfflineDemoPageState();
}

class _OfflineDemoPageState extends State<OfflineDemoPage> {
  bool _loading = true;
  bool _online = true;

  int _pendingQueueSize = 0;
  List<Note> _notes = <Note>[];

  late final SyncLogger _logger;
  late final FirebaseMock _firebase;
  late final OfflineSyncQueue _queue;
  late final NotesRepository _repo;

  Future<void> _refreshAll() async {
    final notes = await _repo.getNotes(ttl: const Duration(minutes: 10));
    final pending = await _repo.pendingQueueSize();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _pendingQueueSize = pending;
    });
  }

  Future<void> _init() async {
    final appDir = await getApplicationDocumentsDirectory();
    Hive.init(appDir.path);

    final notesBox = await Hive.openBox<String>('notesBox');
    final queueBox = await Hive.openBox<String>('queueBox');
    final metaBox = await Hive.openBox<String>('metaBox');

    _logger = SyncLogger();
    _firebase = FirebaseMock(userId: 'user_1')..setOnline(_online);

    _queue = OfflineSyncQueue(
      queueBox: queueBox,
      metaBox: metaBox,
      logger: _logger,
      applier: _firebase,
      backoffMillis: 500,
      maxRetries: 1,
    );

    final localStore = LocalNoteStore(notesBox: notesBox, metaBox: metaBox);
    _repo = NotesRepository(
      localStore: localStore,
      queue: _queue,
      firebase: _firebase,
      logger: _logger,
      userId: 'user_1',
    );

    setState(() => _loading = false);
    await _refreshAll();
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Notes Demo'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Text('Backend'),
                      const SizedBox(width: 12),
                      Switch(
                        value: _online,
                        onChanged: (value) {
                          setState(() {
                            _online = value;
                            _firebase.setOnline(value);
                          });
                        },
                      ),
                      const Spacer(),
                      Text('Queue: $_pendingQueueSize'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      ElevatedButton(
                        onPressed: () async {
                          await _repo.addNote(
                            'Note ${_notes.length + 1}',
                          );
                          await _refreshAll();
                        },
                        child: const Text('Add note'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _notes.isEmpty
                            ? null
                            : () async {
                                final first = _notes.first;
                                await _repo.likeNote(
                                  first.id,
                                  liked: !first.likedByMe,
                                );
                                await _refreshAll();
                              },
                        child: const Text('Like first'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _notes.isEmpty
                            ? null
                            : () async {
                                final first = _notes.first;
                                await _repo.saveNote(
                                  first.id,
                                  saved: !first.savedByMe,
                                );
                                await _refreshAll();
                              },
                        child: const Text('Save first'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_online)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () async {
                          await _queue.syncDueActions();
                          await _refreshAll();
                        },
                        child: const Text('Sync now'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _notes.length,
                      itemBuilder: (context, index) {
                        final note = _notes[index];
                        return Card(
                          child: ListTile(
                            title: Text(note.text),
                            subtitle: Text(
                              'likes=${note.likeCount} saved=${note.savedByMe}',
                            ),
                            trailing: Text(
                              note.likedByMe ? 'Liked' : 'Not liked',
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
