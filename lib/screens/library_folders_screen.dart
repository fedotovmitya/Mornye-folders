import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/local_library_artwork_builder.dart';
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
  for (final group in groups.values) {
    group.tracks.sort((a, b) {
      final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
      if (disc != 0) return disc;
      final number = (a.trackNumber ?? 999).compareTo(b.trackNumber ?? 999);
      return number != 0 ? number : a.trackName.compareTo(b.trackName);
    });
  }
  final result = groups.values.toList(growable: false)
    ..sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return byName != 0 ? byName : a.key.compareTo(b.key);
    });
  return result;
}

/// Standalone page (own app bar) for places that open Folders as a screen.
class LibraryFoldersScreen extends StatelessWidget {
  const LibraryFoldersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.libraryFolders)),
      body: const LibraryFoldersView(),
    );
  }
}

/// Folder list of the local library, without any app bar so it can sit
/// inside the Library tab pager as well as in [LibraryFoldersScreen].
class LibraryFoldersView extends ConsumerStatefulWidget {
  const LibraryFoldersView({super.key});

  @override
  ConsumerState<LibraryFoldersView> createState() => _LibraryFoldersViewState();
}

class _LibraryFoldersViewState extends ConsumerState<LibraryFoldersView>
    with AutomaticKeepAliveClientMixin {
  List<LibraryFolderGroup>? _folders;
  Object? _error;
  int _loadedVersion = -1;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _loadedVersion = ref.read(localLibraryProvider).loadedIndexVersion;
    try {
      final rows = await LibraryDatabase.instance.getAll();
      final folders = groupLibraryTracksByFolder(
        rows.map(LocalLibraryItem.fromJson),
      );
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
    final firstCover = folder.tracks.first.coverPath;
    String? cover = firstCover != null && firstCover.isNotEmpty
        ? firstCover
        : null;
    if (cover == null) {
      for (final track in folder.tracks) {
        final path = track.coverPath;
        if (path != null && path.isNotEmpty) {
          cover = path;
          break;
        }
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
    super.build(context);
    // Reload when a library scan finishes while this view is open.
    ref.listen(localLibraryProvider.select((s) => s.loadedIndexVersion), (
      _,
      next,
    ) {
      if (next != _loadedVersion) _load();
    });

    final colors = Theme.of(context).colorScheme;
    final folders = _folders;

    if (_error != null) {
      return Center(child: Text(_error.toString()));
    }
    if (folders == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (folders.isEmpty) {
      return Center(
        child: Text(
          context.l10n.libraryEmptyCollection,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return CustomScrollView(
      slivers: [
        SliverList.separated(
          itemCount: folders.length,
          separatorBuilder: (context, index) =>
              const Divider(height: 1, indent: 72),
          itemBuilder: (context, index) {
            final folder = folders[index];
            return ListTile(
              leading: _FolderArtwork(track: folder.tracks.first),
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folder.parent.isEmpty
                    ? context.l10n.queueTrackCount(folder.tracks.length)
                    : '${context.l10n.queueTrackCount(folder.tracks.length)}'
                          ' · ${folder.parent}',
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
        ),
        const NavBarSliverSpacer(),
      ],
    );
  }
}

/// Cover of the folder's first track, like an album thumbnail. Folders whose
/// first track has no artwork show a folder icon instead.
class _FolderArtwork extends StatelessWidget {
  const _FolderArtwork({required this.track});

  final LocalLibraryItem track;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget fallback(BuildContext context) => ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.folder_outlined, size: 26, color: colors.primary),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox.square(
        dimension: 52,
        child: LocalLibraryArtworkBuilder(
          coverPath: track.coverPath,
          filePath: track.filePath,
          builder: (context, cover) => cover == null
              ? fallback(context)
              : LocalOrNetworkCoverImage(
                  url: cover,
                  fit: BoxFit.cover,
                  localCacheWidth: 156,
                  placeholder: fallback,
                ),
        ),
      ),
    );
  }
}
