import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/playback_provider.dart';

/// Filesystem view of audio folders, independent of the indexed local library.
class LocalMusicFoldersScreen extends ConsumerStatefulWidget {
  const LocalMusicFoldersScreen({super.key});

  @override
  ConsumerState<LocalMusicFoldersScreen> createState() =>
      _LocalMusicFoldersScreenState();
}

class _LocalMusicFoldersScreenState
    extends ConsumerState<LocalMusicFoldersScreen> {
  static const _audioExtensions = <String>{
    'mp3', 'm4a', 'aac', 'flac', 'wav', 'aiff', 'aif', 'alac', 'ogg',
    'opus', 'ape', 'wv', 'tta', 'dsf', 'dff', 'mpc', 'ac3', 'eac3',
  };

  bool _loading = true;
  String? _error;
  List<Directory> _folders = const [];
  Directory? _openedFolder;
  List<File> _tracks = const [];

  bool _isAudio(FileSystemEntity entity) {
    if (entity is! File) return false;
    final name = entity.uri.pathSegments.isEmpty
        ? entity.path
        : entity.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot >= 0 &&
        _audioExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  List<Directory> _storageRoots() {
    final roots = <String>{};
    final primary = Directory('/storage/emulated/0');
    if (primary.existsSync()) roots.add(primary.path);
    final storage = Directory('/storage');
    try {
      for (final entity in storage.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.path.split('/').last;
        if (name == 'emulated' || name == 'self' || name.startsWith('.')) {
          continue;
        }
        roots.add(entity.path);
      }
    } catch (_) {}
    return roots.map(Directory.new).toList(growable: false);
  }

  Future<void> _scan() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final folders = <String, Directory>{};
    try {
      for (final root in _storageRoots()) {
        if (!await root.exists()) continue;
        final pending = <Directory>[root];
        while (pending.isNotEmpty) {
          final dir = pending.removeLast();
          final path = dir.path;
          if (path.contains('/Android/data') ||
              path.contains('/Android/obb') ||
              path.contains('/.thumbnails') ||
              path.contains('/Android/media/com.zarz.mornye')) {
            continue;
          }
          try {
            var hasAudio = false;
            await for (final child in dir.list(followLinks: false)) {
              if (child is Directory) {
                pending.add(child);
              } else if (_isAudio(child)) {
                hasAudio = true;
              }
            }
            if (hasAudio) folders[path] = dir;
          } on FileSystemException {
            // Ignore folders which are inaccessible or disappear while scanning.
          } catch (_) {}
        }
      }
      final result = folders.values.toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      if (mounted) {
        setState(() {
          _folders = result;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _openFolder(Directory folder) async {
    final files = <File>[];
    try {
      for (final entity in folder.listSync(followLinks: false)) {
        if (_isAudio(entity)) files.add(entity as File);
      }
    } catch (_) {}
    files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    setState(() {
      _openedFolder = folder;
      _tracks = files;
    });
  }

  LocalLibraryItem _asLibraryItem(File file) {
    final name = file.uri.pathSegments.isEmpty
        ? file.path
        : file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final title = dot > 0 ? name.substring(0, dot) : name;
    final stat = file.statSync();
    return LocalLibraryItem(
      id: 'filesystem:${file.path}',
      sourceId: LocalLibraryItem.legacySourceId,
      trackName: title,
      artistName: 'Unknown artist',
      albumName: _openedFolder?.path.split('/').last ?? 'Local files',
      filePath: file.path,
      scannedAt: stat.modified,
      fileModTime: stat.modified.millisecondsSinceEpoch,
      format: dot > 0 ? name.substring(dot + 1).toLowerCase() : null,
    );
  }

  Future<void> _play(File file) async {
    final items = <LocalLibraryItem>[
      for (final track in _tracks) _asLibraryItem(track),
    ];
    final item = items.firstWhere((e) => e.filePath == file.path);
    await ref
        .read(playbackProvider.notifier)
        .playLocalLibraryQueue(items, startItem: item);
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    final folder = _openedFolder;
    return Scaffold(
      appBar: AppBar(
        leading: folder == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to folders',
                onPressed: () => setState(() {
                  _openedFolder = null;
                  _tracks = const [];
                }),
              ),
        title: Text(folder == null ? 'Folders' : folder.path.split('/').last),
        actions: [
          IconButton(
            onPressed: _loading
                ? null
                : (folder == null ? _scan : () => _openFolder(folder)),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not read device storage. Check file access permission.\n\n$_error',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : folder == null
                  ? _folders.isEmpty
                      ? const Center(
                          child: Text(
                            'No folders containing audio files were found. '
                            'Check file access permission.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: _folders.length,
                          itemBuilder: (context, index) {
                            final item = _folders[index];
                            final relative = item.path.replaceFirst(
                              RegExp(r'^/storage/emulated/0/?'),
                              'Internal storage/',
                            );
                            return ListTile(
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(
                                relative,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _openFolder(item),
                            );
                          },
                        )
                  : _tracks.isEmpty
                      ? const Center(child: Text('No audio files in this folder.'))
                      : ListView.builder(
                          itemCount: _tracks.length,
                          itemBuilder: (context, index) {
                            final file = _tracks[index];
                            final name = file.uri.pathSegments.isEmpty
                                ? file.path
                                : file.uri.pathSegments.last;
                            return ListTile(
                              leading: const Icon(Icons.music_note_outlined),
                              title: Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(_formatBytes(file.statSync().size)),
                              onTap: () => _play(file),
                            );
                          },
                        ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
