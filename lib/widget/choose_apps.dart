import 'package:flutter/material.dart';

class ChooseApps extends StatefulWidget {
  final ColorScheme colors;
  final Set<String> selectedApps;
  final List<dynamic> installedApps;
  final bool appsLoading;
  final TextEditingController searchController;

  final Function(String) onSearchChanged;
  final Function(String, bool) onAppSelectionChanged;

  /// Select or unselect many apps at once (one parent rebuild, not one per app).
  final void Function(Set<String>, bool) onBulkSelectionChanged;

  final Widget Function(dynamic, ColorScheme, {double size}) appIcon;

  final VoidCallback onSaveSelection;

  const ChooseApps({
    super.key,
    required this.colors,
    required this.selectedApps,
    required this.installedApps,
    required this.appsLoading,
    required this.searchController,
    required this.onSearchChanged,
    required this.onAppSelectionChanged,
    required this.onBulkSelectionChanged,
    required this.appIcon,
    required this.onSaveSelection,
  });

  @override
  State<ChooseApps> createState() => _ChooseAppsState();
}

class _ChooseAppsState extends State<ChooseApps> {
  late Set<String> _selectedApps;

  // The search text lives HERE. Before, the filtered list was handed in once
  // when this page opened, so typing never changed what was shown.
  late String _query;

  List<dynamic> get _visibleApps {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.installedApps;

    return widget.installedApps
        .where((app) => (app.name as String).toLowerCase().contains(query))
        .toList();
  }

  void _searchChanged(String value) {
    setState(() {
      _query = value;
    });

    widget.onSearchChanged(value);
  }

  @override
  void initState() {
    super.initState();
    _selectedApps = {...widget.selectedApps};
    _query = widget.searchController.text;
  }

  @override
  void didUpdateWidget(covariant ChooseApps oldWidget) {
    super.didUpdateWidget(oldWidget);

    _selectedApps = {...widget.selectedApps};
  }

  // Select or remove an app.
  void _toggleApp(String packageName, bool checked) {
    if (!mounted) return;

    setState(() {
      if (checked) {
        _selectedApps.add(packageName);
      } else {
        _selectedApps.remove(packageName);
      }
    });

    widget.onAppSelectionChanged(packageName, checked);
    widget.onSaveSelection();
  }

  // Select every app in the list. While a search is typed, this selects
  // just the apps that match it (all apps when the search box is empty).
  void _selectAll() {
    final packages = _visibleApps
        .map<String>((app) => app.packageName as String)
        .where((pkg) => !_selectedApps.contains(pkg))
        .toSet();

    if (packages.isEmpty) return;

    setState(() {
      _selectedApps.addAll(packages);
    });

    widget.onBulkSelectionChanged(packages, true);
    widget.onSaveSelection();
  }

  // Clear all selected apps.
  void _clearAll() {
    if (_selectedApps.isEmpty) return;

    final packages = {..._selectedApps};

    setState(() {
      _selectedApps.clear();
    });

    widget.onBulkSelectionChanged(packages, false);
    widget.onSaveSelection();
  }

  bool get _allVisibleSelected =>
      _visibleApps.isNotEmpty &&
      _visibleApps.every((app) => _selectedApps.contains(app.packageName));

  // Selected apps section.
  Widget _buildSelectedApps() {
    final selected = widget.installedApps
        .where((app) => _selectedApps.contains(app.packageName))
        .toList();

    if (selected.isEmpty) {
      return Container(
        width: double.infinity,
        height: 95,
        alignment: Alignment.center,
        child: Text(
          'No apps selected yet.',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      );
    }

    return SizedBox(
      height: 115,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,

        padding: const EdgeInsets.only(left: 8, right: 20, top: 12, bottom: 4),

        itemCount: selected.length,

        separatorBuilder: (_, _) => const SizedBox(width: 14),

        itemBuilder: (context, index) {
          final app = selected[index];

          return SizedBox(
            width: 65,
            child: Column(
              children: [
                SizedBox(
                  width: 58,
                  height: 58,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // App icon.
                      Positioned(
                        left: 5,
                        top: 5,
                        child: widget.appIcon(app, widget.colors, size: 48),
                      ),

                      // Close button.
                      Positioned(
                        right: -1,
                        top: -1,
                        child: Material(
                          color: Colors.red,
                          shape: const CircleBorder(),
                          elevation: 2,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () {
                              _toggleApp(app.packageName, false);
                            },
                            child: const SizedBox(
                              width: 23,
                              height: 23,
                              child: Center(
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 5),

                // App name.
                Text(
                  app.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // Search bar.
  Widget _buildSearchBar() {
    return TextField(
      controller: widget.searchController,
      decoration: InputDecoration(
        hintText: 'Search apps',
        prefixIcon: const Icon(Icons.search),

        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  widget.searchController.clear();

                  FocusScope.of(context).unfocus();

                  _searchChanged('');
                },
              ),

        filled: true,
        fillColor: Colors.white,

        contentPadding: const EdgeInsets.symmetric(vertical: 0),

        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: _searchChanged,
    );
  }

  // Installed apps list.
  Widget _buildAppsList() {
    if (widget.appsLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final apps = _visibleApps;

    if (apps.isEmpty) {
      return Center(
        child: Text(
          widget.installedApps.isEmpty
              ? 'No apps found.'
              : 'No app matches "$_query".',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),

      itemCount: apps.length,

      separatorBuilder: (_, _) =>
          Divider(height: 1, color: Colors.grey.shade200),

      itemBuilder: (context, index) {
        final app = apps[index];

        final isSelected = _selectedApps.contains(app.packageName);

        return CheckboxListTile(
          contentPadding: EdgeInsets.zero,

          controlAffinity: ListTileControlAffinity.trailing,

          secondary: widget.appIcon(app, widget.colors),

          title: Text(
            app.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),

          value: isSelected,

          activeColor: widget.colors.primary,

          onChanged: (checked) {
            _toggleApp(app.packageName, checked == true);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Choose your apps')),

      body: Material(
        color: Theme.of(context).scaffoldBackgroundColor,

        child: Padding(
          padding: const EdgeInsets.all(16),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              // Header and selected count.
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Choose your apps',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  Text(
                    '${_selectedApps.length} selected',
                    style: TextStyle(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 4),

              Text(
                'Voice Assistant will only open and control '
                'the apps you tick here.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),

              // Selected apps heading.
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Selected Apps',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  if (!widget.appsLoading && !_allVisibleSelected)
                    TextButton(
                      onPressed: _selectAll,
                      child: Text(
                        _query.trim().isEmpty ? 'Select all' : 'Select results',
                      ),
                    ),

                  if (_selectedApps.isNotEmpty)
                    TextButton(
                      onPressed: _clearAll,
                      child: const Text('Clear all'),
                    ),
                ],
              ),

              // Selected apps icons.
              _buildSelectedApps(),

              // Search bar.
              _buildSearchBar(),

              const SizedBox(height: 8),

              // Installed apps heading.
              const Text(
                'Installed Apps',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),

              const SizedBox(height: 8),

              // Installed apps list.
              Expanded(
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),

                  child: _buildAppsList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
