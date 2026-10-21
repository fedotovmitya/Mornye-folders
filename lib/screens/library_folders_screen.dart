import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/saf_display_path.dart';
import 'package:path/path.dart' as p;

/// One folder of the local library: every scanned track whose file sits
/// directly inside it.
class LibraryFolderGroup {
  LibraryFolderGroup({
    required this.key,
    required this.name,
    required this.parent,
  });

  final String key;
  final String name;
  final String parent;
  final List<LocalLibraryItem> tracks = [];
}

/// Folder identity of a stored library path. Handles plain file paths,
/// Android SAF `content://` URIs, CUE virtual tracks and `network://` paths.
({String key, String name, String parent}) libraryFolderOf(String rawPath) {
  final realPath = isCueVirtualPath(rawPath)
      ? stripCueTrackSuffix(rawPath)
      : rawPath;

  var display = realPath;
  if (isContentUri(realPath)) {
    display = formatSafUriForDisplay(realPath);
    if (isContentUri(display)) {
      // Opaque provider URI: fall back to the SAF tree + relative directory.
      final location = resolveSafDocumentLocation(realPath);
      if (location == null) {
        return (key: realPath, name: realPath, parent: '');
      }
      final relative = location.relativeDir;
      final name = relative.isEmpty
          ? Uri.decodeComponent(location.treeUri.split('/').last)
          : p.posix.basename(relative);
      final parent = relative.isEmpty ? '' : p.posix.dirname(relative);
      return (
        key: '${location.treeUri}|$relative',
        name: name,
        parent: parent == '.' ? '' : parent,
      );
    }
  }

  final normalized = display.replaceAll('\\', '/');
  final dir = p.posix.dirname(normalized);
  final name = p.posix.basename(dir);
  final parent = p.posix.dirname(dir);
  return (
    key: dir,
    name: name.isEmpty || name == '.' ? dir : name,
    parent: parent == dir || parent == '.' ? '' : parent,
  );
}

/// Groups tracks by their containing folder, sorted by folder name.
List<LibraryFolderGroup> groupLibraryTracksByFolder(
  Iterable<LocalLibraryItem> items,
) {
  final groups = <String, LibraryFolderGroup>{};
  for (final item in items) {
    final folder = libraryFolderOf(item.filePath);
    groups
        .putIfAbsent(
          folder.key,
          () => LibraryFolderGroup(
            key: folder.key,
            name: folder.name,
            parent: folder.parent,
          ),
        )
        .tracks
        .add(item);
  }
  final result = groups.values.toList(growable: false)
    ..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.key.compareTo(b.key);
    });
  return result;
}

/// Browse the local library by the folders the music lives in.
class LibraryFoldersScreen extends ConsumerStatefulWidget {
  const LibraryFoldersScreen({super.key});

  @override
  ConsumerState<LibraryFoldersScreen> createState() =>
      _LibraryFoldersScreenState();
}

class _LibraryFoldersScreenState extends ConsumerState<LibraryFoldersScreen> {
  List<LibraryFolderGroup>? _folders;
  Object? _error;
  int _loadedVersion = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final version = ref.read(localLibraryProvider).loadedIndexVersion;
    _loadedVersion = version;
    try {
      final rows = await LibraryDatabase.instance.getAll();
      final items = rows.map(LocalLibraryItem.fromJson);
      final folders = groupLibraryTracksByFolder(items);
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _openFolder(LibraryFolderGroup folder) {
    String? cover;
    for (final track in folder.tracks) {
      final path = track.coverPath;
      if (path != null && path.isNotEmpty) {
        cover = path;
        break;
      }
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalAlbumScreen(
          albumName: folder.name,
          artistName: folder.parent,
          coverPath: cover,
          tracks: folder.tracks,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Reload when a library scan finishes while this screen is open.
    ref.listen(localLibraryProvider.select((s) => s.loadedIndexVersion), (
      _,
      next,
    ) {
      if (next != _loadedVersion) _load();
    });

    final colors = Theme.of(context).colorScheme;
    final folders = _folders;

    Widget body;
    if (_error != null) {
      body = Center(child: Text(_error.toString()));
    } else if (folders == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (folders.isEmpty) {
      body = Center(
        child: Text(
          context.l10n.libraryEmptyCollection,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: folders.length,
        separatorBuilder: (context, index) => const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) {
          final folder = folders[index];
          return ListTile(
            leading: Icon(
              Icons.folder_outlined,
              color: colors.primary,
              size: 28,
            ),
            title: Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              folder.parent.isEmpty
                  ? '${folder.tracks.length}'
                  : '${folder.tracks.length} · ${folder.parent}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: colors.onSurfaceVariant,
            ),
            onTap: () => _openFolder(folder),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.libraryFolders)),
      body: body,
    );
  }
}
