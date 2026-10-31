import 'package:flutter/material.dart';

class ChooseControls extends StatefulWidget {
  final ColorScheme colors;

  final Set<String> selectedFeatures;
  final List<dynamic> controlFeatures;

  final bool featuresLoading;
  final bool writeSettingsOk;
  final bool dndOk;

  final String testResult;

  final IconData Function(String) featureIcon;

  final VoidCallback onSaveFeatureSelection;
  final VoidCallback onOpenWriteSettings;
  final VoidCallback onOpenDndAccess;

  final Function(String) onFeatureSelectionChanged;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;

  const ChooseControls({
    super.key,
    required this.colors,
    required this.selectedFeatures,
    required this.controlFeatures,
    required this.featuresLoading,
    required this.writeSettingsOk,
    required this.dndOk,
    required this.testResult,
    required this.featureIcon,
    required this.onSaveFeatureSelection,
    required this.onOpenWriteSettings,
    required this.onOpenDndAccess,
    required this.onFeatureSelectionChanged,
    required this.onSelectAll,
    required this.onClearAll,
  });

  @override
  State<ChooseControls> createState() => _ChooseControlsState();
}

class _ChooseControlsState extends State<ChooseControls> {
  late Set<String> _selectedFeatures;

  @override
  void initState() {
    super.initState();

    // Local copy of selected controls.
    _selectedFeatures = {...widget.selectedFeatures};
  }

  void _toggleFeature(String id) {
    final checked = !_selectedFeatures.contains(id);

    // Update the UI immediately.
    setState(() {
      if (checked) {
        _selectedFeatures.add(id);
      } else {
        _selectedFeatures.remove(id);
      }
    });

    // Update parent selection.
    widget.onFeatureSelectionChanged(id);

    // Save selection.
    widget.onSaveFeatureSelection();
  }

  void _selectAll() {
    final allSelected =
        _selectedFeatures.length == widget.controlFeatures.length;

    setState(() {
      if (allSelected) {
        _selectedFeatures.clear();
      } else {
        _selectedFeatures
          ..clear()
          ..addAll(widget.controlFeatures.map((f) => f.id));
      }
    });

    if (allSelected) {
      widget.onClearAll();
    } else {
      widget.onSelectAll();
    }

    widget.onSaveFeatureSelection();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return Scaffold(
      appBar: AppBar(title: const Text('Choose Phone Controls')),
      body: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(5),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Choose your phone controls',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        '${_selectedFeatures.length} selected',
                        style: TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 6),

                  Text(
                    'Only the controls this phone supports are shown. '
                    'Voice Assistant will only change the ones you tick.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),

                  const SizedBox(height: 10),

                  if (widget.featuresLoading)
                    const Center(child: CircularProgressIndicator())
                  else if (widget.controlFeatures.isEmpty)
                    Text(
                      'No controllable features were found on this phone.',
                      style: TextStyle(color: Colors.grey.shade600),
                    )
                  else ...[
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _selectAll,
                        child: Text(
                          _selectedFeatures.length ==
                                  widget.controlFeatures.length
                              ? 'Clear all'
                              : 'Select all',
                        ),
                      ),
                    ),

                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in widget.controlFeatures)
                          FilterChip(
                            key: ValueKey(f.id),
                            avatar: Icon(widget.featureIcon(f.id), size: 18),
                            label: Text(f.name),
                            tooltip: 'Say: "${f.example}"',
                            selected: _selectedFeatures.contains(f.id),
                            onSelected: (_) {
                              _toggleFeature(f.id);
                            },
                          ),
                      ],
                    ),
                  ],

                  if (_selectedFeatures.contains('AUTO_ROTATE') &&
                      !widget.writeSettingsOk) ...[
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: widget.onOpenWriteSettings,
                      child: const Text('Allow auto-rotate (faster)'),
                    ),
                  ],

                  if (_selectedFeatures.contains('DND') && !widget.dndOk) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: widget.onOpenDndAccess,
                      child: const Text('Allow Do Not Disturb (faster)'),
                    ),
                  ],

                  const SizedBox(height: 12),

                  if (widget.testResult.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      widget.testResult,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
