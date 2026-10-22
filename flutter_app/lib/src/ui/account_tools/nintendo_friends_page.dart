import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../backend/nintendo_account_tools_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../state/account_tool_images.dart';
import '../display_time.dart';
import 'account_tool_errors.dart';
import 'account_tool_frame.dart';
import 'account_tool_operation.dart';
import 'friend_note_dialog.dart';
import 'avatar_preview.dart';
import '../android/android_page_frame.dart';

/// Converts the display forms `SW-xxxx-xxxx-xxxx`, `xxxx-xxxx-xxxx`,
/// and the compact numeric form to the Rust bridge's twelve-digit input.
String? normalizeNintendoFriendCode(String input) {
  final digits = input.replaceAll(RegExp(r'[^0-9]'), '');
  return digits.length == 12 ? digits : null;
}

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

  Future<void> addFriend() async {
    final codeOperation = accountToolOperationId('friend-code');
    try {
      final own = await widget.backend.loadNintendoFriendCode(
        widget.profile.accountId,
        codeOperation,
      );
      if (!mounted) return;
      final requestedFriendId = await showDialog<String>(
        context: context,
        builder: (context) => _AddFriendDialog(
          backend: widget.backend,
          accountId: widget.profile.accountId,
          ownCode: own.friendCode,
        ),
      );
      if (requestedFriendId != null && mounted) {
        await load();
        if (!mounted) return;
        final nowFriends =
            snapshot?.friends.any(
              (friend) => friend.friendId == requestedFriendId,
            ) ==
            true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              nowFriends
                  ? context.l10n.select(
                      zh: '已成为好友。',
                      en: 'You are now friends.',
                    )
                  : context.l10n.select(
                      zh: '好友申请已发送。',
                      en: 'Friend request sent.',
                    ),
            ),
          ),
        );
      }
    } catch (failure) {
      if (mounted) androidMessage(context, failure);
    } finally {
      unawaited(cancelAccountToolQuietly(widget.backend, codeOperation));
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
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  widget.profile.nickname,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
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
                    nintendoConditionText(
                          context.l10n,
                          snapshot!.activityError!,
                        ) ??
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
                final minCardWidth = widget.mobile ? 120.0 : 160.0;
                final columns =
                    (constraints.crossAxisExtent /
                            (minCardWidth * scale.clamp(1, 2)))
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
                                      mobile: widget.mobile,
                                      onChanged: load,
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
          tooltip: context.l10n.select(zh: '添加好友', en: 'Add friend'),
          onPressed: operationId == null ? addFriend : null,
          icon: const Icon(Icons.person_add_alt_1),
        ),
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

class _AddFriendDialog extends StatefulWidget {
  const _AddFriendDialog({
    required this.backend,
    required this.accountId,
    required this.ownCode,
  });
  final NintendoAccountToolsBackend backend;
  final String accountId;
  final String ownCode;

  @override
  State<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<_AddFriendDialog> {
  final code = TextEditingController();
  final operations = <String>{};
  NintendoFriendCodeUser? preview;
  String? previewCode;
  bool? alreadyFriend;
  Object? error;
  bool busy = false;
  bool invalidCode = false;
  bool ownAccount = false;

  @override
  void dispose() {
    for (final operation in operations) {
      unawaited(cancelAccountToolQuietly(widget.backend, operation));
    }
    code.dispose();
    super.dispose();
  }

  Future<void> lookup() async {
    if (busy) return;
    final normalized = normalizeNintendoFriendCode(code.text);
    if (normalized == null) {
      setState(() {
        invalidCode = true;
        error = null;
      });
      return;
    }
    if (normalized == normalizeNintendoFriendCode(widget.ownCode)) {
      setState(() {
        ownAccount = true;
        invalidCode = false;
        error = null;
        preview = null;
        previewCode = null;
        alreadyFriend = null;
      });
      return;
    }
    final operation = accountToolOperationId('friend-lookup');
    final friendshipOperation = accountToolOperationId('friend-check');
    operations.addAll([operation, friendshipOperation]);
    setState(() {
      busy = true;
      invalidCode = false;
      ownAccount = false;
      error = null;
      preview = null;
      previewCode = null;
      alreadyFriend = null;
    });
    try {
      final result = await widget.backend.lookupNintendoFriendCode(
        widget.accountId,
        normalized,
        operation,
      );
      if (!mounted) return;
      setState(() => preview = result);
      final friends = await widget.backend.loadNintendoFriends(
        widget.accountId,
        friendshipOperation,
      );
      if (mounted) {
        setState(() {
          alreadyFriend = friends.friends.any(
            (friend) => friend.friendId == result.friendId,
          );
          previewCode = normalized;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      unawaited(cancelAccountToolQuietly(widget.backend, operation));
      unawaited(cancelAccountToolQuietly(widget.backend, friendshipOperation));
      operations.removeAll([operation, friendshipOperation]);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send() async {
    final target = preview;
    if (target == null ||
        busy ||
        alreadyFriend != false ||
        previewCode != normalizeNintendoFriendCode(code.text)) {
      return;
    }
    final operation = accountToolOperationId('friend-request');
    operations.add(operation);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.backend.sendNintendoFriendRequest(
        widget.accountId,
        target.friendId,
        operation,
      );
      if (!result.accepted) throw StateError('account_tool_request_rejected');
      if (mounted) Navigator.pop(context, target.friendId);
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      unawaited(cancelAccountToolQuietly(widget.backend, operation));
      operations.remove(operation);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.select(zh: '添加好友', en: 'Add friend')),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.select(
              zh: '我的 Switch 码：SW-${widget.ownCode}',
              en: 'My Switch code: SW-${widget.ownCode}',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: code,
            enabled: !busy,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {
              preview = null;
              previewCode = null;
              alreadyFriend = null;
              error = null;
              invalidCode = false;
              ownAccount = false;
            }),
            decoration: InputDecoration(
              labelText: context.l10n.select(
                zh: '好友 Switch 码',
                en: 'Friend Switch code',
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (preview case final target?)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _FriendAvatar(
                key: ValueKey(
                  'friend-lookup-avatar:${target.friendId}:${target.avatarUrl}',
                ),
                backend: widget.backend,
                accountId: widget.accountId,
                friendId: target.friendId,
                avatarUrl: target.avatarUrl,
              ),
              title: Text(target.nickname),
              subtitle: alreadyFriend == true
                  ? Text(context.l10n.select(zh: '已是好友', en: 'Already friends'))
                  : null,
            ),
          if (ownAccount || invalidCode || error != null)
            Text(
              ownAccount
                  ? context.l10n.select(
                      zh: '不能向自己发送好友申请。',
                      en: 'You cannot send a friend request to yourself.',
                    )
                  : invalidCode
                  ? context.l10n.select(
                      zh: '请输入 sw-xxxx-xxxx-xxxx 格式的好友码。',
                      en: 'Enter a friend code in the format sw-xxxx-xxxx-xxxx.',
                    )
                  : androidReadableError(context, error!),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
      ),
      if (preview == null || alreadyFriend == null)
        FilledButton(
          onPressed: busy ? null : lookup,
          child: Text(
            error != null
                ? context.l10n.select(zh: '重试', en: 'Retry')
                : context.l10n.select(zh: '查询', en: 'Look up'),
          ),
        )
      else if (alreadyFriend == false)
        FilledButton(
          onPressed: busy ? null : send,
          child: Text(context.l10n.select(zh: '确认发送', en: 'Send request')),
        ),
    ],
  );
}

class _FriendTile extends StatelessWidget {
  const _FriendTile({
    super.key,
    required this.friend,
    required this.accountId,
    required this.backend,
    required this.mobile,
    required this.onChanged,
  });
  final NintendoFriend friend;
  final String accountId;
  final NintendoAccountToolsBackend backend;
  final bool mobile;
  final VoidCallback onChanged;

  Future<void> _openDetail(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NintendoFriendDetailPage(
          backend: backend,
          friend: friend,
          accountId: accountId,
          mobile: mobile,
        ),
      ),
    );
    if (context.mounted) onChanged();
  }

  Future<void> _editNote(BuildContext context) async {
    final value = await showFriendNoteDialog(
      context,
      friend.note,
      onSave: (note) async {
        final operation = accountToolOperationId('friend-note');
        try {
          await backend.updateNintendoFriendNote(
            accountId,
            friend.friendId,
            note,
            operation,
          );
        } finally {
          unawaited(cancelAccountToolQuietly(backend, operation));
        }
      },
    );
    if (value != null && context.mounted) onChanged();
  }

  @override
  Widget build(BuildContext context) {
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
      child: InkWell(
        key: Key('friend-card-open-${friend.friendId}'),
        onTap: () => _openDetail(context),
        onLongPress: () => _editNote(context),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    InkWell(
                      key: Key('friend-avatar-open-${friend.friendId}'),
                      customBorder: const CircleBorder(),
                      onTap: () => _openDetail(context),
                      child: _FriendAvatar(
                        key: ValueKey(
                          '${friend.friendId}:${friend.avatarUrl ?? ''}',
                        ),
                        backend: backend,
                        accountId: accountId,
                        friendId: friend.friendId,
                        avatarUrl: friend.avatarUrl,
                      ),
                    ),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Semantics(
                        label: friend.presence == 'ONLINE'
                            ? context.l10n.select(zh: '在线', en: 'Online')
                            : friend.presence == 'OFFLINE'
                            ? context.l10n.select(zh: '离线', en: 'Offline')
                            : context.l10n.select(
                                zh: '状态未公开',
                                en: 'Presence unavailable',
                              ),
                        child: Container(
                          key: Key('android-friend-status-${friend.friendId}'),
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: friend.presence == 'ONLINE'
                                ? Colors.green
                                : friend.presence == 'OFFLINE'
                                ? Colors.grey
                                : Colors.amber,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: Text(
                  friend.nickname,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (friend.gameName != null || activity != null)
                _FriendInfoRow(
                  icon: Icons.sports_esports_outlined,
                  text: [
                    friend.gameName,
                    activity,
                  ].whereType<String>().join(' · '),
                  maxLines: 2,
                ),
              if (friend.note.isNotEmpty)
                _FriendInfoRow(
                  icon: Icons.sticky_note_2_outlined,
                  text: friend.note,
                ),
              if (friend.logoutAt != null && friend.presence == 'OFFLINE')
                _FriendInfoRow(
                  icon: Icons.schedule_outlined,
                  text: formatUserDateTime(friend.logoutAt!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class NintendoFriendDetailPage extends StatefulWidget {
  const NintendoFriendDetailPage({
    super.key,
    required this.backend,
    required this.friend,
    required this.accountId,
    required this.mobile,
  });

  final NintendoAccountToolsBackend backend;
  final NintendoFriend friend;
  final String accountId;
  final bool mobile;

  @override
  State<NintendoFriendDetailPage> createState() =>
      _NintendoFriendDetailPageState();
}

class _NintendoFriendDetailPageState extends State<NintendoFriendDetailPage> {
  late String note = widget.friend.note;
  bool savingNote = false;
  bool loadingPlayLog = true;
  bool playLogExpanded = false;
  List<NintendoFriendGame> playLog = const [];
  Object? playLogError;
  String? playLogOperationId;

  @override
  void initState() {
    super.initState();
    unawaited(loadPlayLog());
  }

  Future<void> loadPlayLog() async {
    if (playLogOperationId != null) return;
    final operation = accountToolOperationId('friend-play-log');
    setState(() {
      playLogOperationId = operation;
      loadingPlayLog = true;
      playLogError = null;
    });
    try {
      final result = await widget.backend.loadNintendoFriendPlayLog(
        widget.accountId,
        widget.friend.friendId,
        operation,
      );
      if (mounted && playLogOperationId == operation) {
        setState(() => playLog = result);
      }
    } catch (error) {
      if (mounted && playLogOperationId == operation) {
        setState(() => playLogError = error);
      }
    } finally {
      unawaited(cancelAccountToolQuietly(widget.backend, operation));
      if (mounted && playLogOperationId == operation) {
        setState(() {
          playLogOperationId = null;
          loadingPlayLog = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final operation = playLogOperationId;
    playLogOperationId = null;
    if (operation != null) {
      unawaited(cancelAccountToolQuietly(widget.backend, operation));
    }
    super.dispose();
  }

  Future<void> editNote() async {
    try {
      final value = await showFriendNoteDialog(
        context,
        note,
        onSave: (value) async {
          final operation = accountToolOperationId('friend-detail-note');
          if (mounted) setState(() => savingNote = true);
          try {
            await widget.backend.updateNintendoFriendNote(
              widget.accountId,
              widget.friend.friendId,
              value,
              operation,
            );
          } finally {
            unawaited(cancelAccountToolQuietly(widget.backend, operation));
            if (mounted) setState(() => savingNote = false);
          }
        },
      );
      if (value != null && mounted) setState(() => note = value);
    } finally {
      if (mounted) setState(() => savingNote = false);
    }
  }

  String? get activityLabel => switch (widget.friend.activity) {
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

  String? get friendshipSourceLabel => switch (widget.friend.friendshipSource) {
    'FRIEND_CODE' => context.l10n.select(zh: '好友码添加', en: 'Friend code'),
    'NX_FACED' => context.l10n.select(zh: '本机用户', en: 'Local user'),
    'IN_APP' => context.l10n.select(zh: '游戏内添加', en: 'Added in a game'),
    'NINTENDO_ACCOUNT' => context.l10n.select(
      zh: 'Nintendo Account 推荐',
      en: 'Nintendo Account suggestion',
    ),
    'CAMPUS' => context.l10n.select(zh: 'GameChat 添加', en: 'GameChat'),
    null || '' => null,
    _ => context.l10n.select(zh: '其他来源', en: 'Other'),
  };

  @override
  Widget build(BuildContext context) {
    final friend = widget.friend;
    final playTime = friend.totalPlayTimeMinutes;
    return AccountToolFrame(
      mobile: widget.mobile,
      title: context.l10n.select(zh: '好友详情', en: 'Friend details'),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: _FriendAvatar(
              backend: widget.backend,
              accountId: widget.accountId,
              friendId: friend.friendId,
              avatarUrl: friend.avatarUrl,
              radius: 48,
              onPreview: (bytes) => showNintendoAvatarPreview(
                context,
                bytes: bytes,
                nickname: friend.nickname,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            friend.nickname,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          if (friend.isFavorite)
            Center(
              child: Text(
                context.l10n.select(zh: '特别关注', en: 'Favorite'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.sticky_note_2_outlined),
                  title: Text(
                    note.isEmpty
                        ? context.l10n.select(zh: '暂无备注', en: 'No note')
                        : note,
                  ),
                  trailing: IconButton(
                    tooltip: context.l10n.select(zh: '编辑备注', en: 'Edit note'),
                    onPressed: savingNote ? null : editNote,
                    icon: savingNote
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.edit_outlined),
                  ),
                ),
                if (friend.gameName != null)
                  ListTile(
                    leading: _FriendGameImage(
                      backend: widget.backend,
                      accountId: widget.accountId,
                      name: friend.gameName!,
                      url: friend.gameImageUrl,
                    ),
                    title: Text(
                      context.l10n.select(zh: '正在游玩', en: 'Playing now'),
                    ),
                    subtitle: Text(
                      [
                        friend.gameName!,
                        if (playTime != null)
                          context.l10n.select(
                            zh: '累计游玩 $playTime 分钟',
                            en: '$playTime minutes played',
                          ),
                        if (friend.firstPlayedAt != null)
                          context.l10n.select(
                            zh: '首次游玩：${formatUserDateTime(friend.firstPlayedAt!)}',
                            en: 'First played: ${formatUserDateTime(friend.firstPlayedAt!)}',
                          ),
                      ].join('\n'),
                    ),
                  ),
                if (activityLabel != null)
                  ListTile(
                    leading: const Icon(Icons.bolt_outlined),
                    title: Text(
                      context.l10n.select(zh: '当前活动', en: 'Current activity'),
                    ),
                    subtitle: Text(activityLabel!),
                  ),
                if (friend.logoutAt != null)
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: Text(
                      context.l10n.select(zh: '最近离线', en: 'Last offline'),
                    ),
                    subtitle: Text(formatUserDateTime(friend.logoutAt!)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(
                    context.l10n.select(zh: '游戏记录', en: 'Game history'),
                  ),
                ),
                if (loadingPlayLog)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (playLogError != null)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(androidReadableError(context, playLogError!)),
                    trailing: IconButton(
                      tooltip: context.l10n.select(zh: '重试', en: 'Retry'),
                      onPressed: loadPlayLog,
                      icon: const Icon(Icons.refresh),
                    ),
                  )
                else if (playLog.isNotEmpty) ...[
                  for (final game
                      in playLogExpanded ? playLog : playLog.take(6))
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      minVerticalPadding: 2,
                      leading: _FriendGameImage(
                        backend: widget.backend,
                        accountId: widget.accountId,
                        name: game.name,
                        url: game.imageUrl,
                      ),
                      title: Text(game.name),
                      subtitle: Text(
                        [
                          if (game.totalPlayTimeMinutes != null)
                            context.l10n.select(
                              zh: '累计游玩 ${game.totalPlayTimeMinutes} 分钟',
                              en: '${game.totalPlayTimeMinutes} minutes played',
                            ),
                          if (game.firstPlayedAt != null)
                            context.l10n.select(
                              zh: '首次游玩：${formatUserDateTime(game.firstPlayedAt!)}',
                              en: 'First played: ${formatUserDateTime(game.firstPlayedAt!)}',
                            ),
                        ].join('\n'),
                      ),
                    ),
                ] else
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(
                      context.l10n.select(
                        zh: '暂无可见的游戏记录',
                        en: 'No visible game history',
                      ),
                    ),
                  ),
                if (playLog.length > 6)
                  Center(
                    child: IconButton(
                      tooltip: playLogExpanded
                          ? context.l10n.select(
                              zh: '收起游戏记录',
                              en: 'Collapse game history',
                            )
                          : context.l10n.select(
                              zh: '展开全部游戏记录',
                              en: 'Show all game history',
                            ),
                      onPressed: () =>
                          setState(() => playLogExpanded = !playLogExpanded),
                      icon: Icon(
                        playLogExpanded ? Icons.expand_less : Icons.expand_more,
                      ),
                    ),
                  ),
                if (playLog.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      context.l10n.select(
                        zh: '记录范围取决于好友的隐私设置。',
                        en: 'Available entries depend on this friend’s privacy settings.',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(context.l10n.select(zh: '好友关系', en: 'Friendship')),
              subtitle: Text(
                [
                  ?friendshipSourceLabel,
                  if (friend.friendshipGameName?.isNotEmpty == true)
                    context.l10n.select(
                      zh: '来源游戏：${friend.friendshipGameName}',
                      en: 'Source game: ${friend.friendshipGameName}',
                    ),
                  if (friend.inGameName?.isNotEmpty == true)
                    context.l10n.select(
                      zh: '游戏内名称：${friend.inGameName}',
                      en: 'In-game name: ${friend.inGameName}',
                    ),
                  if (friend.friendCreatedAt != null)
                    context.l10n.select(
                      zh: '成为好友：${formatUserDateTime(friend.friendCreatedAt!)}',
                      en: 'Friends since: ${formatUserDateTime(friend.friendCreatedAt!)}',
                    ),
                  if (friendshipSourceLabel == null &&
                      friend.friendCreatedAt == null &&
                      friend.friendshipGameName?.isNotEmpty != true &&
                      friend.inGameName?.isNotEmpty != true)
                    context.l10n.select(
                      zh: '当前服务未提供好友关系详情。',
                      en: 'Friendship details are unavailable from the service.',
                    ),
                ].join('\n'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FriendGameImage extends StatefulWidget {
  const _FriendGameImage({
    required this.backend,
    required this.accountId,
    required this.name,
    required this.url,
  });
  final NintendoAccountToolsBackend backend;
  final String accountId;
  final String name;
  final String? url;

  @override
  State<_FriendGameImage> createState() => _FriendGameImageState();
}

class _FriendGameImageState extends State<_FriendGameImage> {
  AccountImageLease? lease;
  Uint8List? bytes;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    bytes = null;
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    final cache = AccountToolImages.of(widget.backend);
    bytes = cache.game(widget.name, url);
    if (bytes != null) return;
    final request = cache.loadGame(widget.accountId, widget.name, url);
    lease = request;
    unawaited(() async {
      try {
        final result = await request.future;
        if (mounted && identical(lease, request) && result.isNotEmpty) {
          setState(() => bytes = result);
        }
      } catch (_) {
        // Optional art must not hide the game's name or play time.
      }
    }());
  }

  @override
  void didUpdateWidget(covariant _FriendGameImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.name != widget.name ||
        oldWidget.url != widget.url) {
      lease?.release();
      lease = null;
      _start();
    }
  }

  @override
  void dispose() {
    lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = bytes;
    if (image == null) {
      return SizedBox(
        key: ValueKey('friend-game-image:${widget.url}'),
        width: 48,
        height: 48,
        child: const Icon(Icons.sports_esports_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        image,
        key: ValueKey('friend-game-image:${widget.url}'),
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const SizedBox(width: 48, height: 48, child: Icon(Icons.games)),
      ),
    );
  }
}

class _FriendInfoRow extends StatelessWidget {
  const _FriendInfoRow({
    required this.icon,
    required this.text,
    this.maxLines = 1,
  });
  final IconData icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2, right: 5),
        child: Icon(
          icon,
          size: 15,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      Expanded(
        child: Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

class _FriendAvatar extends StatefulWidget {
  const _FriendAvatar({
    super.key,
    required this.backend,
    required this.accountId,
    required this.friendId,
    required this.avatarUrl,
    this.radius = 20,
    this.onPreview,
  });
  final NintendoAccountToolsBackend backend;
  final String accountId;
  final String friendId;
  final String? avatarUrl;
  final double radius;
  final Future<void> Function(Uint8List)? onPreview;
  @override
  State<_FriendAvatar> createState() => _FriendAvatarState();
}

class _FriendAvatarState extends State<_FriendAvatar> {
  AccountImageLease? lease;
  Uint8List? bytes;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final cache = AccountToolImages.of(widget.backend);
    bytes = cache.avatar(widget.accountId, widget.friendId, widget.avatarUrl);
    if (bytes == null) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant _FriendAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.friendId != widget.friendId ||
        oldWidget.avatarUrl != widget.avatarUrl) {
      lease?.release();
      _start();
    }
  }

  Future<void> load() async {
    if (bytes != null) return;
    final request = AccountToolImages.of(widget.backend)
        .loadAvatar(widget.accountId, widget.friendId, widget.avatarUrl);
    lease = request;
    try {
      final value = await request.future;
      if (value.isNotEmpty) {
        if (mounted && identical(lease, request)) setState(() => bytes = value);
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
    lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: widget.radius,
      foregroundImage: bytes == null ? null : MemoryImage(bytes!),
      child: bytes == null ? const Icon(Icons.person_outline) : null,
    );
    return widget.onPreview == null
        ? avatar
        : InkWell(
            customBorder: const CircleBorder(),
            onTap: bytes == null ? null : () => widget.onPreview!(bytes!),
            child: avatar,
          );
  }
}
