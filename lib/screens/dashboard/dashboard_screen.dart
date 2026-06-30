import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:event_scan/models/barcode_model.dart';
import 'package:event_scan/models/scan_event_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';

import '../../services/database.dart';
import '../../models/category_model.dart';
import 'manage_users_screen.dart';
import 'report_screen.dart';

class DashboardScreen extends StatefulWidget {
  final List<CategoryModel> categories;

  const DashboardScreen({super.key, required this.categories});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  List<BarcodeModel> _users = [];
  List<ScanEventModel> _events = [];
  bool _isLoading = true;
  bool _showAllDates = false;
  late DateTime _selectedDate;
  DateTime? _minDate;
  DateTime? _maxDate;
  late AnimationController _initialAnimationController;
  late Animation<double> _initialAnimation;
  bool _hasAnimated = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initialAnimationController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _initialAnimation = CurvedAnimation(
      parent: _initialAnimationController,
      curve: Curves.easeOut,
    );
    _selectedDate = Database.startOfDay(DateTime.now());
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _initialAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    final settings = await Database.getSettings();
    final startDate = (settings['startDate'] as Timestamp?)?.toDate();
    final endDate = (settings['endDate'] as Timestamp?)?.toDate();
    final normalizedNow = Database.startOfDay(DateTime.now());

    _minDate = startDate != null ? Database.startOfDay(startDate) : null;
    _maxDate = endDate != null ? Database.startOfDay(endDate) : null;

    if (_minDate != null && _selectedDate.isBefore(_minDate!)) {
      _selectedDate = _minDate!;
    } else if (_maxDate != null && _selectedDate.isAfter(_maxDate!)) {
      _selectedDate = _maxDate!;
    } else if (_selectedDate.isAfter(normalizedNow)) {
      _selectedDate = normalizedNow;
    }

    final users = await Database.getUsers();
    final events = _showAllDates
        ? await Database.getScanEvents(
            startDate: _minDate ?? _selectedDate,
            endDate: _maxDate ?? _selectedDate,
          )
        : await Database.getScanEvents(selectedDate: _selectedDate);

    if (!mounted) return;
    setState(() {
      _users = users;
      _events = events;
      _isLoading = false;
    });

    if (!_hasAnimated) {
      _initialAnimationController.forward();
      _hasAnimated = true;
    }
  }

  Future<void> _pickDate() async {
    final initialDate = _selectedDate;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: _minDate ?? DateTime(2020),
      lastDate: _maxDate ?? DateTime(2100),
    );

    if (pickedDate == null) return;
    setState(() {
      _selectedDate = Database.startOfDay(pickedDate);
      _showAllDates = false;
    });
    await _loadData();
  }

  List<ScanEventModel> get _filteredEvents => _events;

  int _registeredUsersCount() => _users.length;

  int _activeUsersCount() => _filteredEvents.map((event) => event.barcode).toSet().length;

  int _entriesCount() => _filteredEvents.where((event) => event.action == 'entry').length;

  int _exitsCount() => _filteredEvents.where((event) => event.action == 'exit').length;

  int _categoryCount(String categoryName) {
    return _filteredEvents
        .where((event) => event.category == categoryName)
        .map((event) => event.barcode)
        .toSet()
        .length;
  }

  String get _dateLabel {
    if (_showAllDates) return 'All dates';
    return Database.formatDateTime(_selectedDate).split(' ').take(3).join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Colors.indigo, Colors.blueAccent]),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(118),
          child: Column(
            children: [
              _buildFilters(),
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
                  Tab(icon: Icon(Icons.bar_chart), text: 'Reports'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildDashboardTab(),
                ReportScreen(
                  users: _users,
                  events: _events,
                  selectedDate: _showAllDates ? null : _selectedDate,
                  categories: widget.categories,
                ),
              ],
            ),
    );
  }

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          ActionChip(
            avatar: const Icon(Icons.calendar_month, size: 18),
            label: Text(_dateLabel),
            onPressed: _pickDate,
          ),
          FilterChip(
            selected: _showAllDates,
            label: const Text('All dates'),
            onSelected: (selected) async {
              setState(() => _showAllDates = selected);
              await _loadData();
            },
          ),
          TextButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardTab() {
    return Stack(
      children: [
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildStatsCards(),
          ),
        ),
        _buildManageFAB(),
      ],
    );
  }

  Widget _buildManageFAB() {
    return Positioned(
      bottom: 16,
      right: 16,
      child: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (context) => ManageUsersScreen(users: _users)))
            .then((_) => _loadData()),
        icon: const Icon(Icons.manage_accounts),
        label: const Text('Manage'),
      ),
    );
  }

  Widget _buildStatsCards() {
    return AnimationLimiter(
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        padding: const EdgeInsets.all(16),
        childAspectRatio: 1.15,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        children: AnimationConfiguration.toStaggeredList(
          duration: const Duration(milliseconds: 375),
          childAnimationBuilder: (widget) => SlideAnimation(
            verticalOffset: 50,
            child: FadeInAnimation(child: widget),
          ),
          children: [
            _buildAnimatedStatCard('Registered', _registeredUsersCount(), Icons.people, Colors.green),
            _buildAnimatedStatCard('Active', _activeUsersCount(), Icons.badge, Colors.orange),
            _buildAnimatedStatCard('Entries', _entriesCount(), Icons.login, Colors.cyan),
            _buildAnimatedStatCard('Exits', _exitsCount(), Icons.logout, Colors.pink),
            ...widget.categories.map((category) => _buildAnimatedStatCard(
                  category.name,
                  _categoryCount(category.name),
                  category.icon.data,
                  Color(category.colorValue),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedStatCard(String title, int value, IconData icon, Color color) {
    return AnimatedBuilder(
      animation: _initialAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, 50 * (1 - _initialAnimation.value)),
          child: Opacity(
            opacity: _initialAnimation.value,
            child: Transform.scale(
              scale: _initialAnimation.value,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: value.toDouble()),
                duration: const Duration(milliseconds: 500),
                builder: (context, val, _) {
                  return _buildStatCard(title, val.toInt().toString(), icon, color);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Card(
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color.withValues(alpha: 0.7), color],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 40, color: Colors.white),
                const SizedBox(height: 10),
                Text(
                  value,
                  style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold),
                ),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
