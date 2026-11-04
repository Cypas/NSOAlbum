import 'package:flutter/material.dart';

import '../../backend/app_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import 'android_back_guard.dart';
import 'android_page_frame.dart';

class AndroidAlbumEditor extends StatefulWidget {
  const AndroidAlbumEditor({super.key, required this.backend, this.album});
  final AppBackend backend;
  final AlbumSummary? album;
  @override
  State<AndroidAlbumEditor> createState() => _AndroidAlbumEditorState();
}

class _AndroidAlbumEditorState extends State<AndroidAlbumEditor> {
  late final name = TextEditingController(text: widget.album?.name ?? '');
  late final description = TextEditingController(
    text: widget.album?.description ?? '',
  );
  late bool smart = widget.album?.albumType == 'smart';
  List<AlbumRule> rules = [];
  bool busy = false;
  bool dirty = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    name.addListener(changed);
    description.addListener(changed);
    if (widget.album != null) {
      widget.backend
          .listAlbumRules(widget.album!.id)
          .then((value) {
            if (mounted) setState(() => rules = value);
          })
          .catchError((Object exception) {
            if (mounted) setState(() => error = exception);
          });
    }
  }

  void changed() {
    if (mounted) setState(() => dirty = true);
  }

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    super.dispose();
  }

  void updateRule(
    int index, {
    int? group,
    String? field,
    String? operator,
    String? value,
  }) {
    final old = rules[index];
    setState(() {
      rules[index] = AlbumRule(
        ruleGroup: group ?? old.ruleGroup,
        field: field ?? old.field,
        operator_: operator ?? old.operator_,
        value: value ?? old.value,
      );
      dirty = true;
    });
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty || (smart && rules.isEmpty)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final existing = widget.album;
      final int id;
      if (existing == null) {
        id = await widget.backend.createAlbum(
          name.text.trim(),
          description: description.text,
          smart: smart,
        );
      } else {
        id = existing.id;
        await widget.backend.updateAlbum(
          id,
          name.text.trim(),
          description: description.text,
          smart: smart,
        );
      }
      await widget.backend.replaceAlbumRules(id, smart ? rules : []);
      if (mounted) Navigator.pop(context, true);
    } catch (exception) {
      if (mounted) {
        setState(() {
          busy = false;
          error = exception;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AndroidBackGuard(
    busy: busy,
    dirty: dirty,
    child: AndroidPageFrame(
      title: context.l10n.select(zh: '编辑相册', en: 'Edit album'),
      secondary: true,
      child: AndroidPageList(
        children: [
          TextField(
            controller: name,
            enabled: !busy,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '名称', en: 'Name'),
            ),
          ),
          TextField(
            controller: description,
            enabled: !busy,
            minLines: 2,
            maxLines: null,
            decoration: InputDecoration(
              labelText: context.l10n.select(zh: '说明', en: 'Description'),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.l10n.select(zh: '自动相册', en: 'Smart album')),
            value: smart,
            onChanged: busy
                ? null
                : (value) => setState(() {
                    smart = value;
                    dirty = true;
                  }),
          ),
          if (smart) ...[
            Text(
              context.l10n.select(
                zh: '同组条件全部满足；任意一组满足即可。',
                en: 'All rules in a group must match; any matching group is enough.',
              ),
            ),
            for (var i = 0; i < rules.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      DropdownButtonFormField<int>(
                        initialValue: rules[i].ruleGroup,
                        decoration: InputDecoration(
                          labelText: context.l10n.select(
                            zh: '规则组',
                            en: 'Group',
                          ),
                        ),
                        items: [
                          for (final group in {
                            0,
                            1,
                            2,
                            3,
                            4,
                            rules[i].ruleGroup,
                          })
                            DropdownMenuItem(
                              value: group,
                              child: Text('${group + 1}'),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => updateRule(i, group: value),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: rules[i].field,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.l10n.select(zh: '字段', en: 'Field'),
                        ),
                        items: [
                          for (final entry in {
                            'tag': context.l10n.select(zh: '标签', en: 'Tag'),
                            'game': context.l10n.select(zh: '游戏', en: 'Game'),
                            'note': context.l10n.select(zh: '备注', en: 'Note'),
                            'favorite': context.l10n.select(
                              zh: '收藏',
                              en: 'Favorite',
                            ),
                            'type': context.l10n.select(
                              zh: '媒体类型',
                              en: 'Media type',
                            ),
                          }.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => updateRule(
                                i,
                                field: value,
                                operator: 'equals',
                                value: '',
                              ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey('operator-$i-${rules[i].field}'),
                        initialValue: rules[i].operator_,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: context.l10n.select(
                            zh: '条件',
                            en: 'Condition',
                          ),
                        ),
                        items: [
                          for (final entry in {
                            'equals': context.l10n.select(
                              zh: '等于',
                              en: 'Equals',
                            ),
                            'not_equals': context.l10n.select(
                              zh: '不等于',
                              en: 'Does not equal',
                            ),
                            if (rules[i].field != 'favorite' &&
                                rules[i].field != 'type') ...{
                              'contains': context.l10n.select(
                                zh: '包含',
                                en: 'Contains',
                              ),
                              'not_contains': context.l10n.select(
                                zh: '不包含',
                                en: 'Does not contain',
                              ),
                              'starts_with': context.l10n.select(
                                zh: '开头为',
                                en: 'Starts with',
                              ),
                              'ends_with': context.l10n.select(
                                zh: '结尾为',
                                en: 'Ends with',
                              ),
                            },
                          }.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (value) => updateRule(i, operator: value),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        key: ValueKey('value-$i-${rules[i].field}'),
                        initialValue: rules[i].value,
                        enabled: !busy,
                        decoration: InputDecoration(
                          labelText: context.l10n.select(
                            zh: rules[i].field == 'favorite'
                                ? '值（true / false）'
                                : rules[i].field == 'type'
                                ? '值（image / video）'
                                : '值',
                            en: rules[i].field == 'favorite'
                                ? 'Value (true / false)'
                                : rules[i].field == 'type'
                                ? 'Value (image / video)'
                                : 'Value',
                          ),
                        ),
                        onChanged: (value) => updateRule(i, value: value),
                      ),
                      IconButton(
                        tooltip: context.l10n.select(
                          zh: '移除规则',
                          en: 'Remove rule',
                        ),
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                rules = List.of(rules)..removeAt(i);
                                dirty = true;
                              }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      rules = [
                        ...rules,
                        const AlbumRule(
                          ruleGroup: 0,
                          field: 'tag',
                          operator_: 'equals',
                          value: '',
                        ),
                      ];
                      dirty = true;
                    }),
              icon: const Icon(Icons.add),
              label: Text(context.l10n.select(zh: '新增规则', en: 'Add rule')),
            ),
          ],
          FilledButton.icon(
            onPressed: busy ? null : save,
            icon: const Icon(Icons.save_outlined),
            label: Text(context.l10n.select(zh: '保存', en: 'Save')),
          ),
          if (error != null) Text(androidReadableError(context, error!)),
        ],
      ),
    ),
  );
}
