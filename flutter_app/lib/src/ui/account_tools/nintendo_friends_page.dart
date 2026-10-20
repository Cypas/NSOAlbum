import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../backend/nintendo_account_tools_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../display_time.dart';
import 'account_tool_errors.dart';
import 'account_tool_frame.dart';
import 'account_tool_operation.dart';

class NintendoFriendsPage extends StatefulWidget {
  const NintendoFriendsPage({
    super.key,
    required this.backend,
    required this.profile,
    required this.mobile,
  });
  final NintendoAccountToolsBackend backend;
  final NintendoAccountProfile profile;
  final bool mobile;
  @override
  State<NintendoFriendsPage> createState() => _NintendoFriendsPageState();
}

class _NintendoFriendsPageState extends State<NintendoFriendsPage> {
  NintendoFriendsSnapshot? snapshot;
  Object? error;
  String? operationId;
  bool onlineExpanded = true;
  bool offlineExpanded = false;
  bool favoritesExpanded = true;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (operationId != null) return;
    final id = accountToolOperationId('friends');
    setState(() {
      operationId = id;
      error = null;
    });
    try {
      final result = await widget.backend.loadNintendoFriends(
        widget.profile.accountId,
        id,
      );
      if (mounted && operationId == id) setState(() => snapshot = result);
    } catch (failure) {
      if (widget.backend case final AppBackend logging) {
        unawaited(
          logging
              .logError('[friends] Snapshot failed', failure)
              .catchError((Object _) {}),
        );
      }
      if (mounted && operationId == id) setState(() => error = failure);
    } finally {
      if (mounted && operationId == id) setState(() => operationId = null);
    }
  }

  @override
  void dispose() {
    final id = operationId;
    operationId = null;
    if (id != null) {
      unawaited(cancelAccountToolQuietly(widget.backend, id));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final friends = [...?snapshot?.friends]
      ..sort((a, b) {
        final favorite = (b.isFavorite ? 1 : 0) - (a.isFavorite ? 1 : 0);
        if (favorite != 0) return favorite;
        final name = a.nickname.compareTo(b.nickname);
        return name == 0 ? a.friendId.compareTo(b.friendId) : name;
      });
    final online = friends.where((f) => f.presence == 'ONLINE').toList();
    final offline = friends.where((f) => f.presence != 'ONLINE').toList();
    final favorites = friends.where((f) => f.isFavorite).toList();
    final list = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.profile.nickname),
                if (snapshot != null)
                  Text(
                    context.l10n.select(
                      zh: '更新时间：${formatUserDateTime(snapshot!.updatedAt)}',
                      en: 'Updated: ${formatUserDateTime(snapshot!.updatedAt)}',
                    ),
                  ),
                if (operationId != null) const LinearProgressIndicator(),
                if (error != null)
                  AccountToolError(error: error!, onRetry: load),
                if (snapshot?.activityError != null)
                  Text(
                    context.l10n.select(
                      zh: '部分喷三活动信息暂不可用。',
                      en: 'Some Splatoon 3 activity details are unavailable.',
                    ),
                  ),
                if (snapshot != null && friends.isEmpty)
                  Text(context.l10n.select(zh: '暂无好友', en: 'No friends yet')),
              ],
            ),
          ),
        ),
        for (final group in [
          (
            favorites,
            favoritesExpanded,
            context.l10n.select(zh: '特别关注', en: 'Favorites'),
            'favorites',
          ),
          (
            online.where((f) => !f.isFavorite).toList(),
            onlineExpanded,
            context.l10n.select(zh: '在线好友', en: 'Online friends'),
            'online',
          ),
          (
            offline.where((f) => !f.isFavorite).toList(),
            offlineExpanded,
            context.l10n.select(zh: '离线好友', en: 'Offline friends'),
            'offline',
          ),
        ]) ...[
          SliverToBoxAdapter(
            child: ListTile(
              title: Text(
                group.$3,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              trailing: Icon(group.$2 ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() {
                if (group.$4 == 'favorites') {
                  favoritesExpanded = !favoritesExpanded;
                } else if (group.$4 == 'online') {
                  onlineExpanded = !onlineExpanded;
                } else if (group.$4 == 'offline') {
                  offlineExpanded = !offlineExpanded;
                }
              }),
            ),
          ),
          if (group.$2)
            SliverLayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final columns =
                    (constraints.crossAxisExtent / (160 * scale.clamp(1, 2)))
                        .floor()
                        .clamp(1, 8);
                return SliverList.builder(
                  itemCount: (group.$1.length / columns).ceil(),
                  itemBuilder: (context, row) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var column = 0; column < columns; column++)
                            Expanded(
                              child: row * columns + column < group.$1.length
                                  ? _FriendTile(
                                      key: ValueKey(
                                        '${widget.profile.accountId}:${group.$1[row * columns + column].friendId}',
                                      ),
                                      friend: group.$1[row * columns + column],
                                      accountId: widget.profile.accountId,
                                      backend: widget.backend,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ],
    );
    return AccountToolFrame(
      mobile: widget.mobile,
      title: context.l10n.select(zh: '好友列表', en: 'Friends'),
      actions: [
        IconButton(
          tooltip: context.l10n.select(zh: '刷新', en: 'Refresh'),
          onPressed: operationId == null ? load : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
      child: widget.mobile
          ? RefreshIndicator(onRefresh: load, child: list)
          : list,
    );
  }
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({
    super.key,
    required this.friend,
    required this.accountId,
    required this.backend,
  });
  final NintendoFriend friend;
  final String accountId;
  final NintendoAccountToolsBackend backend;

  @override
  Widget build(BuildContext context) {
    final status = friend.presence == 'ONLINE'
        ? context.l10n.select(zh: '在线', en: 'Online')
        : friend.presence == 'OFFLINE'
        ? context.l10n.select(zh: '离线', en: 'Offline')
        : context.l10n.select(zh: '状态未公开', en: 'Presence unavailable');
    final activity = switch (friend.activity) {
      'MATCHING' => context.l10n.select(zh: '匹配中', en: 'Matchmaking'),
      'REGULAR' => context.l10n.select(zh: '涂地对战', en: 'Turf War'),
      'BANKARA_OPEN' => context.l10n.select(zh: '蛮颓开放', en: 'Anarchy Open'),
      'BANKARA_CHALLENGE' => context.l10n.select(
        zh: '蛮颓挑战',
        en: 'Anarchy Series',
      ),
      'X_MATCH' => context.l10n.select(zh: 'X 比赛', en: 'X Battle'),
      'PRIVATE' => context.l10n.select(zh: '私人比赛', en: 'Private Battle'),
      'COOP' => context.l10n.select(zh: '鲑鱼跑', en: 'Salmon Run'),
      'FEST_OPEN' => context.l10n.select(zh: '祭典开放', en: 'Splatfest Open'),
      'FEST_CHALLENGE' => context.l10n.select(zh: '祭典挑战', en: 'Splatfest Pro'),
      'FEST_TRICOLOR' => context.l10n.select(zh: '祭典三色', en: 'Tricolor Battle'),
      'EVENT' => context.l10n.select(zh: '活动比赛', en: 'Challenge'),
      _ => null,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                _FriendAvatar(
                  key: ValueKey('${friend.friendId}:${friend.avatarUrl ?? ''}'),
                  backend: backend,
                  accountId: accountId,
                  friendId: friend.friendId,
                  avatarUrl: friend.avatarUrl,
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    key: Key('android-friend-status-${friend.friendId}'),
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: friend.presence == 'ONLINE'
                          ? Colors.green
                          : Colors.grey,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              friend.nickname,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (friend.isFavorite)
              Icon(
                Icons.star,
                size: 16,
                semanticLabel: context.l10n.select(
                  zh: '星标好友',
                  en: 'Best friend',
                ),
              ),
            Text([status, ?friend.gameName, ?activity].join(' · ')),
            if (friend.note.isNotEmpty) Text(friend.note),
            if (friend.totalPlayTimeMinutes != null)
              Text(
                context.l10n.select(
                  zh: '游玩时间：${friend.totalPlayTimeMinutes! ~/ 60} 小时',
                  en: 'Play time: ${friend.totalPlayTimeMinutes! ~/ 60} hours',
                ),
              ),
            if (friend.logoutAt != null && friend.presence == 'OFFLINE')
              Text(
                context.l10n.select(
                  zh: '上次在线：${formatUserDateTime(friend.logoutAt!)}',
                  en: 'Last online: ${formatUserDateTime(friend.logoutAt!)}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FriendAvatar extends StatefulWidget {
  const _FriendAvatar({
    super.key,
    required this.backend,
    required this.accountId,
    required this.friendId,
    required this.avatarUrl,
  });
  final NintendoAccountToolsBackend backend;
  final String accountId;
  final String friendId;
  final String? avatarUrl;
  @override
  State<_FriendAvatar> createState() => _FriendAvatarState();
}

class _FriendAvatarState extends State<_FriendAvatar> {
  final id = accountToolOperationId('friend-avatar');
  Uint8List? bytes;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (bytes != null) return;
    try {
      final value = await widget.backend.loadNintendoFriendAvatar(
        widget.accountId,
        widget.friendId,
        id,
      );
      if (value.isNotEmpty) {
        if (mounted) setState(() => bytes = value);
      }
    } catch (failure) {
      if (widget.backend case final AppBackend logging) {
        unawaited(
          logging
              .logError('[friends] Avatar failed', failure)
              .catchError((Object _) {}),
        );
      }
      // Avatars are optional; keep the friend and their presence visible.
    }
  }

  @override
  void dispose() {
    unawaited(cancelAccountToolQuietly(widget.backend, id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CircleAvatar(
    foregroundImage: bytes == null ? null : MemoryImage(bytes!),
    child: bytes == null ? const Icon(Icons.person_outline) : null,
  );
}
