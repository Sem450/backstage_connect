// lib/widgets/todo_panel.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TodoPanel extends StatefulWidget {
  final List<Map<String, dynamic>> managedRows;
  final bool showDebug;
  /// 'manager' or 'artist' (controls who you can assign to)
  final String currentRole;

  const TodoPanel({
    super.key,
    required this.managedRows,
    this.showDebug = false,
    this.currentRole = 'manager', // set to 'artist' on the artist dashboard
  });

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  final _sp = Supabase.instance.client;

  bool _loading = false;
  List<Map<String, dynamic>> _items = [];
  final List<String> _console = [];

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  void _log(String msg) {
    final line = '[TodoPanel] $msg';
    // ignore: avoid_print
    print(line);
    if (!mounted) return;
    setState(() => _console.add(line));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String get _uid => _sp.auth.currentUser?.id ?? '';

  // ---------- Managed helpers (nested/flat rows) ----------
  Map<String, String>? _extractProfile(Map<String, dynamic> row) {
    Map<String, dynamic>? prof;

    if (row['artist_profile'] is Map) {
      prof = (row['artist_profile'] as Map).cast<String, dynamic>();
    } else if (row['manager_profile'] is Map) {
      prof = (row['manager_profile'] as Map).cast<String, dynamic>();
    } else if (row['profile'] is Map) {
      prof = (row['profile'] as Map).cast<String, dynamic>();
    } else if (row['user'] is Map) {
      prof = (row['user'] as Map).cast<String, dynamic>();
    }

    final id = (prof?['id'] ??
            row['artist_id'] ??
            row['manager_id'] ??
            row['id'] ??
            '')
        .toString();

    if (id.isEmpty) return null;

    final dn = (prof?['display_name'] ?? row['display_name'] ?? '').toString();
    final email = (prof?['email'] ?? row['email'] ?? '').toString();
    final label = dn.trim().isNotEmpty
        ? dn.trim()
        : (email.isNotEmpty ? email.split('@').first : 'User');

    return {'id': id, 'label': label, 'email': email};
  }

  List<Map<String, String>> _buildAssignees() {
    final out = <Map<String, String>>[];

    // Artists can only assign to themselves
    if (widget.currentRole == 'artist') {
      if (_uid.isNotEmpty) out.add({'id': _uid, 'label': 'Me'});
      return out;
    }

    // Managers: Me + managed artists
    if (_uid.isNotEmpty) out.add({'id': _uid, 'label': 'Me'});
    for (final r in widget.managedRows) {
      final p = _extractProfile(r);
      if (p == null) continue;
      if (out.indexWhere((e) => e['id'] == p['id']) == -1) {
        out.add({'id': p['id']!, 'label': p['label']!});
      }
    }
    return out;
  }

  String _nameForUser(String userId) {
    if (userId == _uid) return 'Me';
    for (final r in widget.managedRows) {
      final p = _extractProfile(r);
      if (p != null && p['id'] == userId) return p['label']!;
    }
    return 'User';
  }

  // ---------- misc ----------
  String _dueLabel(dynamic iso) {
    if (iso == null || iso.toString().isEmpty) return 'No due date';
    final dt = DateTime.tryParse(iso.toString());
    if (dt == null) return 'No due date';
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  bool _isCompleted(dynamic status) {
    final s = (status ?? '').toString().toLowerCase().trim();
    return s == 'completed' || s == 'done';
  }

  // ---------- data ----------
  Future<void> _loadTodos() async {
    _log('loadTodos() uid=$_uid');
    if (_uid.isEmpty) {
      _snack('Not signed in');
      _log('ABORT: no auth user');
      return;
    }
    setState(() => _loading = true);
    try {
      final rows = await _sp
          .from('todos')
          .select(
            'id,title,details,due_date,status,assignee_id,creator_id,created_at,updated_at',
          )
          .or('creator_id.eq.$_uid,assignee_id.eq.$_uid')
          .order('created_at', ascending: false);
      _log('loadTodos ok: ${rows.runtimeType} length=${(rows as List).length}');
      final list = (rows as List)
          .map<Map<String, dynamic>>((r) => Map<String, dynamic>.from(r))
          .toList();
      if (!mounted) return;
      setState(() => _items = list);
    } catch (e) {
      _log('loadTodos ERROR: $e');
      _snack('Error loading todos: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createTask({
    required String title,
    required String details,
    required String assigneeId,
    DateTime? due,
  }) async {
    _log('createTask(title="$title", assigneeId=$assigneeId, due=$due)');
    try {
      await _sp.from('todos').insert({
        'title': title.trim(),
        'details': details.trim(),
        'due_date': due?.toUtc().toIso8601String(),
        'status': 'incomplete',
        'creator_id': _uid,
        'assignee_id': assigneeId,
      });
      _snack('Task created');
      await _loadTodos();
    } catch (e) {
      _log('createTask ERROR: $e');
      _snack('Error saving: $e');
    }
  }

  Future<void> _toggleComplete(int id, bool currentlyCompleted) async {
    final newStatus = currentlyCompleted ? 'incomplete' : 'completed';
    _log('toggleComplete(id=$id -> $newStatus)');
    try {
      await _sp.from('todos').update({'status': newStatus}).eq('id', id);
      final idx = _items.indexWhere((t) => t['id'] == id);
      if (idx != -1) {
        final updated = Map<String, dynamic>.from(_items[idx]);
        updated['status'] = newStatus;
        setState(() => _items[idx] = updated);
      }
    } catch (e) {
      _log('toggleComplete ERROR: $e');
      _snack('Update failed: $e');
    }
  }

  Future<void> _deleteTask(int id) async {
    _log('deleteTask(id=$id)');
    try {
      await _sp.from('todos').delete().eq('id', id);
      setState(() => _items.removeWhere((e) => e['id'] == id));
      _snack('Deleted');
    } catch (e) {
      _log('deleteTask ERROR: $e');
      _snack('Delete failed: $e');
    }
  }

  // ---------- UI actions ----------
  Future<void> _openCreateTaskFlow() async {
    _log(
      'Set task tapped (role=${widget.currentRole}, uid=$_uid, managed=${widget.managedRows.length})',
    );
    if (_uid.isEmpty) {
      _snack('You need to be signed in to create a task.');
      return;
    }

    final assignees = _buildAssignees();
    String? selectedAssignee =
        assignees.isNotEmpty ? assignees.first['id'] : null;
    DateTime? due;
    final titleC = TextEditingController();
    final detailsC = TextEditingController();

    final isArtistLocked = widget.currentRole == 'artist';

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black54,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final kb = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, kb + 16),
          child: StatefulBuilder(
            builder: (ctx, setSB) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'New task',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: titleC,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    filled: true,
                    fillColor: const Color(0xFFF5F6FA),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: detailsC,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Details (optional)',
                    filled: true,
                    fillColor: const Color(0xFFF5F6FA),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                if (isArtistLocked) ...[
                  const Text('Assign to',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  InputDecorator(
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFFF5F6FA),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    child: const Text('Me'),
                  ),
                ] else
                  DropdownButtonFormField<String>(
                    value: selectedAssignee,
                    items: assignees
                        .map(
                          (a) => DropdownMenuItem<String>(
                            value: a['id'],
                            child: Text(a['label']!),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setSB(() => selectedAssignee = v),
                    decoration: InputDecoration(
                      labelText: 'Assign to',
                      filled: true,
                      fillColor: const Color(0xFFF5F6FA),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),

                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: ctx,
                            firstDate: DateTime(now.year - 1),
                            lastDate: DateTime(now.year + 5),
                            initialDate: due ?? now,
                          );
                          if (picked != null) setSB(() => due = picked);
                        },
                        icon: const Icon(Icons.event),
                        label: Text(
                          due == null
                              ? 'Choose due date'
                              : _dueLabel(due!.toIso8601String()),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      if ((selectedAssignee ?? '').isEmpty) {
                        _snack('Please select an assignee');
                        return;
                      }
                      if (titleC.text.trim().isEmpty) {
                        _snack('Please enter a title');
                        return;
                      }
                      Navigator.pop(ctx);
                      await _createTask(
                        title: titleC.text,
                        details: detailsC.text,
                        assigneeId: selectedAssignee!,
                        due: due,
                      );
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Create task'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1F1F1F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // quick “it’s me” test insert
  Future<void> _insertTestForMe() async {
    if (_uid.isEmpty) {
      _snack('No user id');
      _log('insertTestForMe ABORT no uid');
      return;
    }
    _log('insertTestForMe start');
    await _createTask(
      title: 'Debug test task',
      details: 'Created from Set task (debug)',
      assigneeId: _uid,
      due: DateTime.now().add(const Duration(days: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const outerBg = Color(0xFFF4F5FB);   // page block bg
    const btnBg   = Color(0xFFE9ECF2);   // light grey pill button
    const btnFg   = Color(0xFF1F1F1F);
    const taskBg  = Color(0xFFF5F6FA);   // task row bg

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: outerBg,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Material(
            color: Colors.white,                // panel color
            elevation: 12,                      // 👈 raised effect
            shadowColor: Colors.black26,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: Colors.black.withOpacity(0.05), // subtle edge
                ),
              ),
              child: Column(
                children: [
                  // header
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Tasks',
                          style: TextStyle(
                            color: Color(0xFF2E2C2C),
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _openCreateTaskFlow,
                        icon: const Icon(Icons.task_alt, size: 18, color: btnFg),
                        label: const Text('Set task',
                            style: TextStyle(color: btnFg)),
                        style: TextButton.styleFrom(
                          backgroundColor: btnBg,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Nothing here yet.',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: _items.map((row) {
                        final id          = row['id'] as int;
                        final title       = (row['title'] ?? '').toString();
                        final details     = (row['details'] ?? '').toString();
                        final due         = _dueLabel(row['due_date']);
                        final isDone      = _isCompleted(row['status']);
                        final assigneeId  = (row['assignee_id'] ?? '').toString();
                        final creatorId   = (row['creator_id'] ?? '').toString();

                        final assigneeName = _nameForUser(assigneeId);
                        final creatorName  = _nameForUser(creatorId);

                        return Container(
                          margin: const EdgeInsets.only(top: 10),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                          decoration: BoxDecoration(
                            color: taskBg,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.06),
                                blurRadius: 10,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              InkWell(
                                onTap: () => _toggleComplete(id, isDone),
                                borderRadius: BorderRadius.circular(999),
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: isDone
                                          ? Colors.green
                                          : Colors.grey.shade400,
                                      width: 2,
                                    ),
                                    color: isDone
                                        ? Colors.green.withOpacity(0.12)
                                        : null,
                                  ),
                                  child: Icon(
                                    isDone
                                        ? Icons.check
                                        : Icons.circle_outlined,
                                    size: 18,
                                    color: isDone
                                        ? Colors.green
                                        : Colors.grey.shade500,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),

                              // text column
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title.isEmpty ? '(untitled)' : title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF1F1F1F),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 2),

                                    // Assigned to ... • by ...
                                    Text(
                                      'Assigned to $assigneeName • by $creatorName',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.black54,
                                        fontSize: 12,
                                      ),
                                    ),

                                    if (details.trim().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        details,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.black45,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              // right column: due + status chip + menu
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    due,
                                    style: const TextStyle(
                                      color: Color(0xFF1F1F1F),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isDone
                                          ? Colors.green.withOpacity(0.12)
                                          : Colors.orange.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(999),
                                      border: Border.all(
                                        color: isDone
                                            ? Colors.green.withOpacity(0.35)
                                            : Colors.orange.withOpacity(0.35),
                                      ),
                                    ),
                                    child: Text(
                                      isDone ? 'Completed' : 'Incomplete',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: isDone
                                            ? Colors.green
                                            : Colors.orange,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 6),
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'toggle') {
                                    _toggleComplete(id, isDone);
                                  } else if (v == 'delete') {
                                    _deleteTask(id);
                                  }
                                },
                                itemBuilder: (ctx) => const [
                                  PopupMenuItem(
                                      value: 'toggle',
                                      child: Text('Toggle complete')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('Delete')),
                                ],
                                icon: const Icon(Icons.more_horiz,
                                    color: Colors.black54),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),

                  if (widget.showDebug) const SizedBox(height: 10),
                  if (widget.showDebug)
                    _DebugDrawer(
                      uid: _uid,
                      onReload: _loadTodos,
                      onTestInsert: _insertTestForMe,
                      console: _console,
                      onClear: () => setState(() => _console.clear()),
                      rawItemsProvider: () => _items,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DebugDrawer extends StatelessWidget {
  final String uid;
  final VoidCallback onReload;
  final VoidCallback onTestInsert;
  final List<String> console;
  final VoidCallback onClear;
  final List<Map<String, dynamic>> Function() rawItemsProvider;

  const _DebugDrawer({
    required this.uid,
    required this.onReload,
    required this.onTestInsert,
    required this.console,
    required this.onClear,
    required this.rawItemsProvider,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      initiallyExpanded: true,
      iconColor: Colors.white70,
      collapsedIconColor: Colors.white70,
      title:
          const Text('Debug console', style: TextStyle(color: Colors.white70)),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _chip('user: ${uid.isEmpty ? "(none)" : uid.substring(0, 8)}'),
            ActionChip(label: const Text('Reload'), onPressed: onReload),
            ActionChip(
                label: const Text('Insert test (Me)'),
                onPressed: onTestInsert),
            ActionChip(
              label: const Text('Dump rows'),
              onPressed: () {
                final items = rawItemsProvider();
                // ignore: avoid_print
                print('[TodoPanel] DUMP items: $items');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content:
                          Text('Dumped ${items.length} rows to console')),
                );
              },
            ),
            ActionChip(label: const Text('Clear console'), onPressed: onClear),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 120,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF2A1D49),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white24),
          ),
          child: ListView(
            children: console
                .map((l) => Text(l,
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)))
                .toList(),
          ),
        ),
      ],
    );
  }

  Widget _chip(String t) => Chip(
        label: Text(t),
        labelStyle: const TextStyle(fontSize: 12),
        backgroundColor: const Color(0xFFE9ECF2),
        side: const BorderSide(color: Color(0xFF1F1F1F)),
      );
}
