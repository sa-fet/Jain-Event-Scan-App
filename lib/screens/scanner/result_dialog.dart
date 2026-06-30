import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../components/edit_user_dialog.dart';
import '../../models/barcode_model.dart';
import '../../models/category_model.dart';
import '../../services/database.dart';

class ResultDialog extends StatefulWidget {
  final BarcodeModel? result;
  final String barcode;
  final VoidCallback onDismissed;
  final List<CategoryModel>? categories;

  const ResultDialog({
    super.key,
    required this.result,
    required this.barcode,
    required this.onDismissed,
    this.categories,
  });

  @override
  State<ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<ResultDialog> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Color?> _colorAnimation;
  late Animation<double> _scaleAnimation;
  List<CategoryModel>? _categories;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    final success = widget.result != null && widget.result!.code.isNotEmpty;
    _colorAnimation = ColorTween(
      begin: Colors.transparent,
      end: success ? Colors.green[700] : Colors.red[700],
    ).animate(_controller);
    _scaleAnimation = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    if (widget.categories != null) {
      _categories = widget.categories;
    } else {
      _categories = await Database.getCategories();
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final title = result?.title ?? 'Unknown';
    final subtitle = result?.subtitle ?? 'Unknown';
    final extras = result?.extras ?? <ExtraField>[];
    final scanned = result?.scanned ?? const <String, List<int>>{};
    final isKnown = result != null && result.code.isNotEmpty;
    final action = result?.lastScanAction ?? '';
    final category = result?.lastScanCategory ?? '';
    final scanAt = result?.lastScanAt?.toDate();

    if (widget.result?.title.isEmpty == true) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        showDialog(
          context: context,
          builder: (context) => EditUserDialog(usersData: [widget.result!], canEditMultiple: false),
        );
      });
    }

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        _controller.reverse();
        widget.onDismissed();
      },
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedBuilder(
          animation: _colorAnimation,
          builder: (context, child) {
            return AlertDialog(
              backgroundColor: _colorAnimation.value,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isKnown ? (action == 'entry' ? Icons.login : Icons.logout) : Icons.warning_amber,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        isKnown ? 'Marked ${action.toUpperCase()}' : 'Unknown Barcode',
                        style: const TextStyle(color: Colors.white, fontSize: 24),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Code: ${widget.barcode}'),
                  Text('Title: $title'),
                  Text('Subtitle: $subtitle'),
                  if (category.isNotEmpty) Text('Category: $category'),
                  if (scanAt != null) Text('Scanned At: ${Database.formatDateTime(scanAt)}'),
                  ...extras.where((field) => field.value.isNotEmpty).map((field) => Text('${field.key}: ${field.value}')),
                  const SizedBox(height: 12),
                  _buildScannedSummary(scanned),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildScannedSummary(Map<String, List<int>> scanned) {
    if (_categories == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (scanned.isEmpty) {
      return const Text('No attendance history yet.', style: TextStyle(color: Colors.white));
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: scanned.entries.map((entry) {
          CategoryModel? category;
          for (final item in _categories!) {
            if (item.name == entry.key) {
              category = item;
              break;
            }
          }
          if (category == null) {
            return const SizedBox.shrink();
          }
          return Chip(
            avatar: Icon(category.icon.data),
            label: Text('${entry.key} • Days ${entry.value.join(', ')}'),
          );
        }).toList(),
      ),
    );
  }
}
