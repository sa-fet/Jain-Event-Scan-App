import 'dart:convert';
import 'dart:typed_data';

import 'package:event_scan/models/barcode_model.dart';
import 'package:event_scan/models/scan_event_model.dart';
import 'package:event_scan/services/database.dart';
import 'package:excel/excel.dart' hide Border;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../components/edit_user_dialog.dart';
import '../../models/category_model.dart';

class ReportScreen extends StatefulWidget {
  final List<BarcodeModel> users;
  final List<ScanEventModel> events;
  final DateTime? selectedDate;
  final List<CategoryModel> categories;

  const ReportScreen({
    super.key,
    required this.users,
    required this.events,
    required this.selectedDate,
    required this.categories,
  });

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  String _searchQuery = '';
  String _selectedCategory = 'All';
  String _selectedAction = 'All';
  String _selectedState = 'All';
  String _selectedSubtitle = 'All';
  bool _showFilters = false;
  bool _isFabExpanded = false;
  bool _isExporting = false;

  List<String> get _subtitleOptions {
    final values = widget.users
        .map((user) => user.subtitle.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return ['All', ...values];
  }

  Map<String, List<ScanEventModel>> get _eventsByBarcode {
    final map = <String, List<ScanEventModel>>{};
    for (final event in widget.events) {
      map.putIfAbsent(event.barcode, () => <ScanEventModel>[]).add(event);
    }
    for (final events in map.values) {
      events.sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis));
    }
    return map;
  }

  bool get _hasActiveFilters {
    return _selectedCategory != 'All' ||
        _selectedAction != 'All' ||
        _selectedState != 'All' ||
        _selectedSubtitle != 'All';
  }

  List<ScanEventModel> _eventsForUser(BarcodeModel user) {
    final events = List<ScanEventModel>.from(_eventsByBarcode[user.code] ?? const <ScanEventModel>[]);
    return events.where((event) {
      final categoryMatches = _selectedCategory == 'All' || event.category == _selectedCategory;
      final actionMatches = _selectedAction == 'All' || event.action == _selectedAction.toLowerCase();
      return categoryMatches && actionMatches;
    }).toList();
  }

  List<BarcodeModel> _filteredUsers() {
    final users = widget.users.where((user) {
      final userEvents = _eventsForUser(user);
      final stateMatches = switch (_selectedState) {
        'Scanned only' => userEvents.isNotEmpty,
        'Not scanned' => userEvents.isEmpty,
        _ => true,
      };
      final subtitleMatches = _selectedSubtitle == 'All' || user.subtitle == _selectedSubtitle;
      return stateMatches && subtitleMatches && user.query(_searchQuery.toLowerCase());
    }).toList();

    users.sort((a, b) {
      final aEvents = _eventsForUser(a);
      final bEvents = _eventsForUser(b);
      if (aEvents.isNotEmpty && bEvents.isNotEmpty) {
        return bEvents.first.createdAtMillis.compareTo(aEvents.first.createdAtMillis);
      }
      if (aEvents.isNotEmpty) return -1;
      if (bEvents.isNotEmpty) return 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return users;
  }

  void _clearFilters() {
    setState(() {
      _selectedCategory = 'All';
      _selectedAction = 'All';
      _selectedState = 'All';
      _selectedSubtitle = 'All';
    });
  }

  Future<void> _exportToJson() async {
    final filteredUsers = _filteredUsers();
    final payload = filteredUsers.map((user) {
      final events = _eventsForUser(user)
          .map((event) => {
                'barcode': event.barcode,
                'category': event.category,
                'action': event.action,
                'dateKey': event.dateKey,
                'eventDay': event.eventDay,
                'createdAtMillis': event.createdAtMillis,
                'createdAt': event.occurredAt.toIso8601String(),
              })
          .toList();
      return {
        ...user.toJson(),
        'events': events,
      };
    }).toList();

    final jsonString = const JsonEncoder.withIndent('  ').convert(payload);
    final bytes = Uint8List.fromList(jsonString.codeUnits);
    await FilePicker.saveFile(
      dialogTitle: 'Export to JSON',
      fileName: 'event-scan-report.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: bytes,
    );
  }

  Future<void> _exportToExcel() async {
    setState(() => _isExporting = true);
    try {
      final excel = Excel.createExcel();
      excel.rename('Sheet1', 'Users');
      final usersSheet = excel['Users'];
      final eventsSheet = excel['Events'];
      final filteredUsers = _filteredUsers();
      final extraKeys = filteredUsers.expand((user) => user.extras.map((field) => field.key)).toSet().toList()..sort();

      final userHeaders = ['Code', 'Title', 'Subtitle', ...extraKeys, 'Last Action', 'Last Scan At'];
      usersSheet.appendRow(userHeaders.map(TextCellValue.new).toList());
      for (final user in filteredUsers) {
        final row = <CellValue>[
          TextCellValue(user.code),
          TextCellValue(user.title),
          TextCellValue(user.subtitle),
          ...extraKeys.map((key) {
            final value = user.extras
                .firstWhere((field) => field.key == key, orElse: () => ExtraField(key: key, value: ''))
                .value;
            return TextCellValue(value);
          }),
          TextCellValue(user.lastScanAction ?? ''),
          TextCellValue(user.lastScanAt != null ? Database.formatDateTime(user.lastScanAt!.toDate()) : ''),
        ];
        usersSheet.appendRow(row);
      }

      eventsSheet.appendRow([
        TextCellValue('Barcode'),
        TextCellValue('Title'),
        TextCellValue('Subtitle'),
        TextCellValue('Category'),
        TextCellValue('Action'),
        TextCellValue('Date'),
        TextCellValue('Time'),
        TextCellValue('Event Day'),
      ]);

      for (final user in filteredUsers) {
        for (final event in _eventsForUser(user)) {
          eventsSheet.appendRow([
            TextCellValue(user.code),
            TextCellValue(user.title),
            TextCellValue(user.subtitle),
            TextCellValue(event.category),
            TextCellValue(event.action),
            TextCellValue(event.dateKey),
            TextCellValue(Database.formatDateTime(event.occurredAt)),
            IntCellValue(event.eventDay),
          ]);
        }
      }

      final bytes = Uint8List.fromList(excel.save() ?? <int>[]);
      await FilePicker.saveFile(
        dialogTitle: 'Export to Excel',
        fileName: 'event-scan-report.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: bytes,
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredUsers = _filteredUsers();
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeaderCard(filteredUsers.length)),
            if (filteredUsers.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('No attendees found for the selected filters')),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverList.builder(
                  itemCount: filteredUsers.length,
                  itemBuilder: (context, index) => _buildUserCard(filteredUsers[index]),
                ),
              ),
          ],
        ),
        _buildExportFAB(),
        if (_isExporting) _buildExportingOverlay(),
      ],
    );
  }

  Widget _buildHeaderCard(int resultCount) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: 'Search attendee, code, role, or extra fields',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.blue.withValues(alpha: 0.12),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => setState(() => _showFilters = !_showFilters),
                icon: Icon(_showFilters ? Icons.expand_less : Icons.tune),
                label: Text(_showFilters ? 'Hide filters' : 'Show filters'),
              ),
              const SizedBox(width: 8),
              if (_hasActiveFilters)
                TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.clear_all),
                  label: const Text('Clear'),
                ),
            ],
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 720;
                  final itemWidth = compact ? constraints.maxWidth : (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: itemWidth,
                        child: _buildDropdown(
                          label: 'Category',
                          value: _selectedCategory,
                          items: ['All', ...widget.categories.map((category) => category.name)],
                          onChanged: (value) => setState(() => _selectedCategory = value!),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _buildDropdown(
                          label: 'Action',
                          value: _selectedAction,
                          items: const ['All', 'Entry', 'Exit'],
                          onChanged: (value) => setState(() => _selectedAction = value!),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _buildDropdown(
                          label: 'Scan state',
                          value: _selectedState,
                          items: const ['All', 'Scanned only', 'Not scanned'],
                          onChanged: (value) => setState(() => _selectedState = value!),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _buildDropdown(
                          label: 'Role / subtitle',
                          value: _selectedSubtitle,
                          items: _subtitleOptions,
                          onChanged: (value) => setState(() => _selectedSubtitle = value!),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            crossFadeState: _showFilters ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.selectedDate != null)
                Chip(
                  avatar: const Icon(Icons.calendar_today, size: 16),
                  label: Text(Database.dateKeyFromDate(widget.selectedDate!)),
                ),
              Chip(
                avatar: const Icon(Icons.people_alt_outlined, size: 16),
                label: Text('$resultCount attendees'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.04),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          items: items
              .map((item) => DropdownMenuItem<String>(
                    value: item,
                    child: Text(item, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildUserCard(BarcodeModel user) {
    final userEvents = _eventsForUser(user);
    final latestEvent = userEvents.isNotEmpty ? userEvents.first : null;
    final lastThree = user.code.length >= 3 ? user.code.substring(user.code.length - 3) : user.code;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ExpansionTile(
        leading: CircleAvatar(child: Text(lastThree)),
        trailing: latestEvent == null
            ? const Chip(label: Text('No scan'))
            : Chip(
                avatar: Icon(
                  latestEvent.action == 'entry' ? Icons.login : Icons.logout,
                  size: 16,
                  color: Colors.white,
                ),
                backgroundColor: latestEvent.action == 'entry' ? Colors.green : Colors.orange,
                label: Text(
                  latestEvent.action.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
        title: Text(user.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          latestEvent == null
              ? '${user.subtitle}\nCode: ${user.code}'
              : '${user.subtitle}\n${latestEvent.category} • ${Database.formatDateTime(latestEvent.occurredAt)}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => showEditUserDialog(context, [user], canEditMultiple: false),
              icon: const Icon(Icons.edit),
              label: const Text('Edit'),
            ),
          ),
          ...user.extras.where((field) => field.value.isNotEmpty).map((field) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(field.icon ?? Icons.info_outline, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${field.key}: ${field.value}')),
                  ],
                ),
              )),
          const Divider(),
          if (userEvents.isEmpty)
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('No scan records match the selected filters.'),
            )
          else
            Column(
              children: userEvents.map((event) {
                final color = event.action == 'entry' ? Colors.green : Colors.orange;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.15),
                    child: Icon(
                      event.action == 'entry' ? Icons.login : Icons.logout,
                      color: color,
                    ),
                  ),
                  title: Text('${event.category} • Day ${event.eventDay}'),
                  subtitle: Text(Database.formatDateTime(event.occurredAt)),
                  trailing: Text(
                    event.action.toUpperCase(),
                    style: TextStyle(color: color, fontWeight: FontWeight.bold),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildExportFAB() {
    return Positioned(
      bottom: 16,
      right: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (_isFabExpanded) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('JSON', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  onPressed: _exportToJson,
                  child: const Icon(Icons.code),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Excel', style: TextStyle(color: Colors.white70)),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  onPressed: _exportToExcel,
                  child: const Icon(Icons.table_chart),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          FloatingActionButton.extended(
            onPressed: () => setState(() => _isFabExpanded = !_isFabExpanded),
            icon: Icon(_isFabExpanded ? Icons.close : Icons.file_download),
            label: Text(_isFabExpanded ? 'Close' : 'Export'),
          ),
        ],
      ),
    );
  }

  Widget _buildExportingOverlay() {
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Exporting...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
