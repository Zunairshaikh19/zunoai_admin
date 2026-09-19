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
          final filteredPrompts = allPrompts.where((p) => 
            p.category.toLowerCase().contains(query) || 
            p.hiddenPrompt.toLowerCase().contains(query)
          ).toList();

          if (filteredPrompts.isEmpty) {
            return const Center(child: Text("No prompts found matching your search."));
          }

          return GridView.builder(
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
                        Expanded(child: Image.network(prompt.imageUrl, fit: BoxFit.cover)),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(prompt.category, style: const TextStyle(fontWeight: FontWeight.bold)),
                              Text(prompt.isPremium ? "Premium" : "Free", style: TextStyle(color: prompt.isPremium ? Colors.amber : Colors.white54)),
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
                    ],
                  ],
                ),
              ),
            );
          },
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

        await ref.read(firebaseServiceProvider).bulkUploadPrompts(
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
            content: Text(finalProgress.isCancelled 
                ? "Upload cancelled. ${finalProgress.current} items processed." 
                : "Bulk upload completed: ${finalProgress.total} items processed"),
            backgroundColor: finalProgress.isCancelled ? Colors.orange : Colors.green,
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

