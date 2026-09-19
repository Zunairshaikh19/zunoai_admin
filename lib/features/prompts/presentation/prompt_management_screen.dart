import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker_web/image_picker_web.dart';
import 'package:file_picker/file_picker.dart' as fp;
import '../../../models/image_prompt.dart';
import '../../users/presentation/user_management_screen.dart';

final promptsStreamProvider = StreamProvider((ref) {
  // Keep the data in memory even if the screen is not active
  ref.keepAlive();
  return ref.watch(firebaseServiceProvider).getPrompts();
});
final selectedPromptsProvider = StateProvider<Set<String>>((ref) => {});

/// 'all' | 'published' | 'draft' | 'cleanup' — draft/cleanup let an admin
/// find what a bulk import left behind for review without scrolling the
/// whole gallery.
final promptFilterProvider = StateProvider<String>((ref) => 'all');

class UploadProgress {
  final int current;
  final int total;
  final bool isCancelled;

  UploadProgress({this.current = 0, this.total = 0, this.isCancelled = false});
}

final uploadProgressProvider = StateProvider<UploadProgress>((ref) => UploadProgress());
final promptSearchQueryProvider = StateProvider<String>((ref) => "");

class PromptManagementScreen extends ConsumerWidget {
  const PromptManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final promptsAsync = ref.watch(promptsStreamProvider);
    final selectedIds = ref.watch(selectedPromptsProvider);
    final searchQuery = ref.watch(promptSearchQueryProvider);
    final isSelectionMode = selectedIds.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(selectedPromptsProvider.notifier).state = {},
              )
            : null,
        title: isSelectionMode 
          ? Text("${selectedIds.length} Selected")
          : SizedBox(
              width: 300,
              child: TextField(
                onChanged: (val) => ref.read(promptSearchQueryProvider.notifier).state = val,
                decoration: InputDecoration(
                  hintText: "Search categories or prompts...",
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.white10,
                ),
              ),
            ),
        actions: isSelectionMode
            ? [
                TextButton.icon(
                  onPressed: () {
                    final allIds = promptsAsync.value?.map((p) => p.id).toSet() ?? {};
                    ref.read(selectedPromptsProvider.notifier).state = allIds;
                  },
                  icon: const Icon(Icons.select_all, color: Colors.white),
                  label: const Text("Select All", style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.workspace_premium, color: Colors.amber),
                  tooltip: "Make Premium",
                  onPressed: () => _handleBatchPremium(ref, selectedIds, true),
                ),
                IconButton(
                  icon: const Icon(Icons.money_off, color: Colors.white70),
                  tooltip: "Make Free",
                  onPressed: () => _handleBatchPremium(ref, selectedIds, false),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.visibility, color: Colors.lightGreenAccent),
                  tooltip: "Publish Selected",
                  onPressed: () => _handleBatchPublish(ref, selectedIds, true),
                ),
                IconButton(
                  icon: const Icon(Icons.visibility_off, color: Colors.white70),
                  tooltip: "Unpublish Selected",
                  onPressed: () => _handleBatchPublish(ref, selectedIds, false),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                  tooltip: "Delete Selected",
                  onPressed: () => _handleBatchDelete(context, ref, selectedIds),
                ),
                const SizedBox(width: 16),
              ]
            : [
                IconButton(
                  onPressed: () => ref.invalidate(promptsStreamProvider),
                  icon: const Icon(Icons.refresh),
                  tooltip: "Refresh from Firebase",
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _handleBulkUpload(context, ref),
                  icon: const Icon(Icons.upload_file),
                  label: const Text("Bulk Upload JSON"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blueGrey),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () => _showAddPromptDialog(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text("Add New Prompt"),
                ),
                const SizedBox(width: 16),
              ],
      ),
      body: promptsAsync.when(
        data: (allPrompts) {
          final query = searchQuery.toLowerCase();
          final statusFilter = ref.watch(promptFilterProvider);
          final filteredPrompts = allPrompts.where((p) {
            final matchesSearch = p.category.toLowerCase().contains(query) ||
                p.hiddenPrompt.toLowerCase().contains(query);
            if (!matchesSearch) return false;
            switch (statusFilter) {
              case 'published':
                return p.isPublished;
              case 'draft':
                return !p.isPublished;
              case 'cleanup':
                return p.needsCleanup;
              default:
                return true;
            }
          }).toList();

          final draftCount = allPrompts.where((p) => !p.isPublished).length;
          final cleanupCount = allPrompts.where((p) => p.needsCleanup).length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text("All"),
                      selected: statusFilter == 'all',
                      onSelected: (_) => ref.read(promptFilterProvider.notifier).state = 'all',
                    ),
                    ChoiceChip(
                      label: const Text("Published"),
                      selected: statusFilter == 'published',
                      onSelected: (_) => ref.read(promptFilterProvider.notifier).state = 'published',
                    ),
                    ChoiceChip(
                      label: Text("Draft ($draftCount)"),
                      selected: statusFilter == 'draft',
                      selectedColor: Colors.orange.withValues(alpha: 0.3),
                      onSelected: (_) => ref.read(promptFilterProvider.notifier).state = 'draft',
                    ),
                    ChoiceChip(
                      label: Text("Needs Cleanup ($cleanupCount)"),
                      selected: statusFilter == 'cleanup',
                      selectedColor: Colors.redAccent.withValues(alpha: 0.3),
                      onSelected: (_) => ref.read(promptFilterProvider.notifier).state = 'cleanup',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filteredPrompts.isEmpty
                    ? const Center(child: Text("No prompts found matching your search."))
                    : GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              childAspectRatio: 0.8,
            ),
            itemCount: filteredPrompts.length,
            itemBuilder: (context, index) {
              final prompt = filteredPrompts[index];
              final isSelected = selectedIds.contains(prompt.id);

            return InkWell(
              onTap: () {
                if (isSelectionMode) {
                  _toggleSelection(ref, prompt.id);
                } else {
                  _showPromptTextDialog(context, prompt);
                }
              },
              onLongPress: () => _toggleSelection(ref, prompt.id),
              child: Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: isSelected ? Colors.purpleAccent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Stack(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Image.network(
                            prompt.imageUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              // The source link is dead/broken — surface it in
                              // the same "Needs Cleanup" queue as text issues,
                              // once, instead of leaving it silently broken.
                              if (!prompt.needsCleanup) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  ref.read(firebaseServiceProvider).flagImageNeedsCleanup(prompt.id);
                                });
                              }
                              return Container(
                                color: Colors.red.withValues(alpha: 0.12),
                                child: const Center(
                                  child: Icon(Icons.broken_image, color: Colors.redAccent, size: 40),
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(prompt.category, style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text(prompt.isPremium ? "Premium" : "Free", style: TextStyle(color: prompt.isPremium ? Colors.amber : Colors.white54)),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  _StatusPill(
                                    label: prompt.isPublished ? "Published" : "Draft",
                                    color: prompt.isPublished ? Colors.lightGreenAccent : Colors.orange,
                                  ),
                                  GestureDetector(
                                    onTap: () => _showGenderPicker(context, ref, prompt),
                                    child: _StatusPill(label: "${prompt.gender} ✎", color: Colors.blueGrey.shade200),
                                  ),
                                  if (prompt.needsCleanup)
                                    const _StatusPill(label: "Needs Cleanup", color: Colors.redAccent),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (isSelected)
                      Container(
                        color: Colors.purpleAccent.withValues(alpha: 0.2),
                        child: const Center(
                          child: Icon(Icons.check_circle, color: Colors.purpleAccent, size: 48),
                        ),
                      ),
                    if (!isSelectionMode) ...[
                      Positioned(
                        top: 8,
                        left: 8,
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          radius: 18,
                          child: IconButton(
                            icon: Icon(
                              prompt.isPremium ? Icons.workspace_premium : Icons.money_off,
                              color: prompt.isPremium ? Colors.amber : Colors.white70,
                              size: 18,
                            ),
                            onPressed: () => ref.read(firebaseServiceProvider).updatePromptPremiumStatus(prompt.id, !prompt.isPremium),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          radius: 18,
                          child: IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                            onPressed: () => ref.read(firebaseServiceProvider).deletePrompt(prompt.id),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          radius: 18,
                          child: IconButton(
                            icon: Icon(
                              prompt.isPublished ? Icons.visibility : Icons.visibility_off,
                              color: prompt.isPublished ? Colors.lightGreenAccent : Colors.white70,
                              size: 18,
                            ),
                            tooltip: prompt.isPublished ? "Unpublish" : "Publish",
                            onPressed: () => ref.read(firebaseServiceProvider).updatePromptPublished(prompt.id, !prompt.isPublished),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: CircleAvatar(
                          backgroundColor: Colors.black54,
                          radius: 18,
                          child: IconButton(
                            icon: const Icon(Icons.edit, color: Colors.lightBlueAccent, size: 18),
                            tooltip: "Edit image & prompt",
                            onPressed: () => _showEditPromptDialog(context, ref, prompt),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
                        },
                      ),
              ),
            ],
          );
        },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text("Error: $err")),
    ),
  );
}

  void _showPromptTextDialog(BuildContext context, ImagePrompt prompt) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(prompt.category),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              prompt.hiddenPrompt.isEmpty ? "(No prompt text set)" : prompt.hiddenPrompt,
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close")),
          ElevatedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: prompt.hiddenPrompt));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Prompt copied to clipboard")),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text("Copy Prompt"),
          ),
        ],
      ),
    );
  }

  void _toggleSelection(WidgetRef ref, String id) {
    final current = ref.read(selectedPromptsProvider);
    final notifier = ref.read(selectedPromptsProvider.notifier);
    if (current.contains(id)) {
      notifier.state = current.where((element) => element != id).toSet();
    } else {
      notifier.state = {...current, id};
    }
  }

  void _handleBatchDelete(BuildContext context, WidgetRef ref, Set<String> selectedIds) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Confirm Delete"),
        content: Text("Are you sure you want to delete ${selectedIds.length} prompts?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context); // Close confirm dialog
              try {
                await ref.read(firebaseServiceProvider).deleteMultiplePrompts(selectedIds.toList());
                ref.read(selectedPromptsProvider.notifier).state = {};
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Successfully deleted ${selectedIds.length} prompts")),
                );
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text("Delete failed: $e")),
                );
              }
            },
            child: const Text("Delete"),
          ),
        ],
      ),
    );
  }

  void _handleBatchPremium(WidgetRef ref, Set<String> selectedIds, bool isPremium) async {
    try {
      await ref.read(firebaseServiceProvider).updateMultiplePromptsPremiumStatus(selectedIds.toList(), isPremium);
      ref.read(selectedPromptsProvider.notifier).state = {};
    } catch (e) {
      debugPrint("Batch update failed: $e");
    }
  }

  void _showEditPromptDialog(BuildContext context, WidgetRef ref, ImagePrompt prompt) {
    final categoryController = TextEditingController(text: prompt.category);
    final promptController = TextEditingController(text: prompt.hiddenPrompt);
    bool isPremium = prompt.isPremium;
    String gender = prompt.gender;
    dynamic newImageBytes; // null until admin picks a replacement

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text("Edit Prompt"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    final bytes = await ImagePickerWeb.getImageAsBytes();
                    if (bytes != null) {
                      setState(() => newImageBytes = bytes);
                    }
                  },
                  child: Container(
                    height: 150,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: newImageBytes != null
                          ? Image.memory(newImageBytes, fit: BoxFit.cover)
                          : Image.network(
                              prompt.imageUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.broken_image, size: 40, color: Colors.redAccent),
                                  SizedBox(height: 8),
                                  Text("Current image is broken — tap to replace", style: TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text("Tap image to replace it", style: TextStyle(fontSize: 11, color: Colors.white54)),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: categoryController,
                  decoration: const InputDecoration(labelText: "Category Name", border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: promptController,
                  decoration: const InputDecoration(
                    labelText: "Hidden AI Prompt",
                    border: OutlineInputBorder(),
                    helperText: "Strip any leftover Midjourney parameters here (--ar, --v, --stylize, etc.)",
                  ),
                  maxLines: 6,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: gender,
                  decoration: const InputDecoration(labelText: "Shows in gallery for", border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'unisex', child: Text("Everyone (unisex)")),
                    DropdownMenuItem(value: 'male', child: Text("Male")),
                    DropdownMenuItem(value: 'female', child: Text("Female")),
                    DropdownMenuItem(value: 'couple', child: Text("Couple (2 photos)")),
                  ],
                  onChanged: (val) => setState(() => gender = val ?? 'unisex'),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text("Premium Prompt"),
                  subtitle: const Text("Only visible to paid users"),
                  value: isPremium,
                  activeThumbColor: Colors.amber,
                  onChanged: (val) => setState(() => isPremium = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                if (categoryController.text.trim().isEmpty || promptController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Category and prompt text can't be empty")),
                  );
                  return;
                }

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const Center(child: CircularProgressIndicator()),
                );

                try {
                  String imageUrl = prompt.imageUrl;
                  if (newImageBytes != null) {
                    imageUrl = await ref.read(firebaseServiceProvider).uploadImageWeb(newImageBytes);
                  }
                  await ref.read(firebaseServiceProvider).updatePromptDetails(
                        prompt.id,
                        imageUrl: imageUrl,
                        category: categoryController.text.trim(),
                        hiddenPrompt: promptController.text.trim(),
                        gender: gender,
                        isPremium: isPremium,
                      );
                  if (!context.mounted) return;
                  Navigator.pop(context); // Pop loading
                  Navigator.pop(context); // Pop dialog
                } catch (e) {
                  if (!context.mounted) return;
                  Navigator.pop(context); // Pop loading
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Update failed: $e")),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.lightBlueAccent),
              child: const Text("Save Changes"),
            ),
          ],
        ),
      ),
    );
  }

  void _showGenderPicker(BuildContext context, WidgetRef ref, ImagePrompt prompt) {
    const options = ['unisex', 'male', 'female', 'couple'];
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text("Shows in gallery for", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final option in options)
              ListTile(
                title: Text(option[0].toUpperCase() + option.substring(1)),
                trailing: prompt.gender == option ? const Icon(Icons.check, color: Colors.purpleAccent) : null,
                onTap: () {
                  ref.read(firebaseServiceProvider).updatePromptGender(prompt.id, option);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _handleBatchPublish(WidgetRef ref, Set<String> selectedIds, bool isPublished) async {
    try {
      await ref.read(firebaseServiceProvider).updateMultiplePromptsPublished(selectedIds.toList(), isPublished);
      ref.read(selectedPromptsProvider.notifier).state = {};
    } catch (e) {
      debugPrint("Batch publish update failed: $e");
    }
  }

  void _handleBulkUpload(BuildContext context, WidgetRef ref) async {
    final result = await fp.FilePicker.pickFile(
      type: fp.FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result != null) {
      try {
        final bytes = await result.readAsBytes();
        if (!context.mounted) return;

        final content = utf8.decode(bytes);
        final List<dynamic> jsonList = jsonDecode(content);
        
        if (jsonList.isEmpty) return;

        // Reset and Show Progress Dialog
        ref.read(uploadProgressProvider.notifier).state = UploadProgress(total: jsonList.length);
        
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const _BulkUploadProgressDialog(),
        );

        final uploadResult = await ref.read(firebaseServiceProvider).bulkUploadPrompts(
          jsonList.cast<Map<String, dynamic>>(),
          (count, total) {
            ref.read(uploadProgressProvider.notifier).state = UploadProgress(
              current: count,
              total: total,
            );
          },
          shouldCancel: () => ref.read(uploadProgressProvider).isCancelled,
        );

        if (!context.mounted) return;
        final finalProgress = ref.read(uploadProgressProvider);
        Navigator.pop(context); // Close progress dialog

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              finalProgress.isCancelled
                  ? "Upload cancelled. ${finalProgress.current} of ${finalProgress.total} processed — ${uploadResult.added} added as drafts, ${uploadResult.skippedDuplicate} skipped as duplicates."
                  : "Done: ${uploadResult.added} added as drafts, ${uploadResult.skippedDuplicate} skipped as duplicates, ${uploadResult.flaggedForCleanup} flagged for cleanup. Review and publish them in the Draft filter.",
            ),
            backgroundColor: finalProgress.isCancelled ? Colors.orange : Colors.green,
            duration: const Duration(seconds: 6),
          ),
        );
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Bulk upload failed: $e")),
        );
      }
    }
  }

  void _showAddPromptDialog(BuildContext context, WidgetRef ref) {
    final categoryController = TextEditingController();
    final promptController = TextEditingController();
    bool isPremium = false;
    String gender = 'unisex';
    dynamic imageBytes;

    // Get existing categories for suggestions
    final existingPrompts = ref.read(promptsStreamProvider).value ?? [];
    final categories = existingPrompts.map((e) => e.category).toSet().toList();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text("Add New AI Prompt"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () async {
                    final bytes = await ImagePickerWeb.getImageAsBytes();
                    if (bytes != null) {
                      setState(() => imageBytes = bytes);
                    }
                  },
                  child: Container(
                    height: 150,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: imageBytes == null
                        ? const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_a_photo, size: 40),
                              SizedBox(height: 8),
                              Text("Click to select Sample Image", style: TextStyle(fontSize: 12)),
                            ],
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(imageBytes, fit: BoxFit.cover),
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: categoryController,
                  decoration: const InputDecoration(
                    labelText: "Category Name",
                    border: OutlineInputBorder(),
                    hintText: "Enter new or select below",
                  ),
                ),
                const SizedBox(height: 12),
                if (categories.isNotEmpty) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text("Existing Categories:", style: TextStyle(fontSize: 12, color: Colors.white54)),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: categories.map((cat) => ActionChip(
                      label: Text(cat, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        setState(() => categoryController.text = cat);
                      },
                      backgroundColor: categoryController.text == cat 
                          ? Colors.purpleAccent.withValues(alpha: 0.2) 
                          : Colors.white10,
                      side: BorderSide(
                        color: categoryController.text == cat 
                            ? Colors.purpleAccent 
                            : Colors.white10
                      ),
                    )).toList(),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: promptController,
                  decoration: const InputDecoration(
                    labelText: "Hidden AI Prompt",
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: gender,
                  decoration: const InputDecoration(
                    labelText: "Shows in gallery for",
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'unisex', child: Text("Everyone (unisex)")),
                    DropdownMenuItem(value: 'male', child: Text("Male")),
                    DropdownMenuItem(value: 'female', child: Text("Female")),
                    DropdownMenuItem(value: 'couple', child: Text("Couple (2 photos)")),
                  ],
                  onChanged: (val) => setState(() => gender = val ?? 'unisex'),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text("Premium Prompt"),
                  subtitle: const Text("Only visible to paid users"),
                  value: isPremium,
                  activeThumbColor: Colors.amber,
                  onChanged: (val) => setState(() => isPremium = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
            ElevatedButton(
              onPressed: () async {
                if (imageBytes == null || categoryController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Please select image and enter category")),
                  );
                  return;
                }

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => const Center(child: CircularProgressIndicator()),
                );

                try {
                  final url = await ref.read(firebaseServiceProvider).uploadImageWeb(imageBytes);
                  final newPrompt = ImagePrompt(
                    id: '',
                    imageUrl: url,
                    category: categoryController.text.trim(),
                    hiddenPrompt: promptController.text.trim(),
                    isPremium: isPremium,
                    gender: gender,
                    isPublished: true,
                  );
                  await ref.read(firebaseServiceProvider).addPrompt(newPrompt);
                  if (!context.mounted) return;
                  Navigator.pop(context); // Pop loading
                  Navigator.pop(context); // Pop dialog
                } catch (e) {
                  if (!context.mounted) return;
                  Navigator.pop(context); // Pop loading
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Upload failed: $e")),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purpleAccent),
              child: const Text("Upload & Save"),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _BulkUploadProgressDialog extends ConsumerWidget {
  const _BulkUploadProgressDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(uploadProgressProvider);
    final percent = progress.total > 0 ? progress.current / progress.total : 0.0;

    return AlertDialog(
      title: const Text("Bulk Uploading..."),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: percent),
          const SizedBox(height: 16),
          Text("Uploading ${progress.current} of ${progress.total}..."),
          const SizedBox(height: 8),
          const Text(
            "Downloading images, uploading to ImgBB & saving to Firestore. Please wait...",
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            ref.read(uploadProgressProvider.notifier).state = UploadProgress(
              current: progress.current,
              total: progress.total,
              isCancelled: true,
            );
          },
          child: const Text("Cancel Upload", style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
  }
}

