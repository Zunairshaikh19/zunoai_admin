// Standalone command-line importer for the prompts JSON dump.
//
// Why this exists: the in-app "Bulk Upload JSON" button runs inside Flutter
// Web (Chrome), and the browser's CORS rules block a page from *reading* the
// bytes of an image hosted on a bucket that doesn't send
// Access-Control-Allow-Origin headers (like the R2 bucket these prompts'
// images live on) — the browser happily shows the picture in an <img> tag,
// but refuses to let JavaScript read it, which is exactly what re-hosting to
// ImgBB requires ("ClientException: Failed to fetch").
//
// Running this as a plain command-line Dart script has no browser and no
// CORS restriction, so it can actually mirror every image to ImgBB the way
// the in-app importer was meant to — so if the original R2 link ever goes
// away, the app's copy on ImgBB keeps working.
//
// It does the exact same dedup / draft / needsCleanup / gender-tagging logic
// as the in-app bulk uploader, just without the browser in the way.
//
// Usage (run from inside the zunoai_admin project folder):
//   dart run tool/bulk_import_prompts.dart <prompts.json> <admin_email> <admin_password> <imgbb_api_key>
//
// Note: the admin password is passed as a plain argument, so it will be
// visible in shell history / process list on this machine. Fine for a
// one-off personal import; don't share the command or your terminal history.

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const String _firebaseApiKey = "AIzaSyCmoGoxenH5dFqT56SKIf12WMxjb84wIWo";
const String _projectId = "zunoai-b924f";

final RegExp _midjourneyFlagPattern =
    RegExp(r'--(ar|v|stylize|sref|raw|profile|chaos|weird|niji|q|seed|style)\b', caseSensitive: false);
final RegExp _maleWordPattern =
    RegExp(r'\b(man|men|boy|boys|male|guy|guys|groom|husband|father|dad)\b', caseSensitive: false);
final RegExp _femaleWordPattern =
    RegExp(r'\b(woman|women|girl|girls|female|lady|ladies|bride|wife|mother|mom)\b', caseSensitive: false);

String detectGender(String text) {
  final hasMale = _maleWordPattern.hasMatch(text);
  final hasFemale = _femaleWordPattern.hasMatch(text);
  if (hasMale && hasFemale) return 'couple';
  if (hasMale) return 'male';
  if (hasFemale) return 'female';
  return 'unisex';
}

bool needsCleanup(String text) => _midjourneyFlagPattern.hasMatch(text);

void main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln(
      'Usage: dart run tool/bulk_import_prompts.dart <prompts.json> <admin_email> <admin_password> <imgbb_api_key>',
    );
    exit(1);
  }

  final jsonPath = args[0];
  final adminEmail = args[1];
  final adminPassword = args[2];
  final imgbbKey = args[3];

  final file = File(jsonPath);
  if (!file.existsSync()) {
    stderr.writeln('File not found: $jsonPath');
    exit(1);
  }

  print('Reading $jsonPath ...');
  final List<dynamic> jsonList = jsonDecode(await file.readAsString());
  print('Loaded ${jsonList.length} entries.');

  print('Signing in as $adminEmail ...');
  final idToken = await _signIn(adminEmail, adminPassword);
  print('Signed in.');

  print('Fetching existing prompts for de-duplication ...');
  final seenHiddenPrompts = await _fetchExistingHiddenPrompts();
  print('Found ${seenHiddenPrompts.length} existing prompts.');
  print('');

  int processed = 0, added = 0, skippedDuplicate = 0, flaggedForCleanup = 0, failed = 0;
  final total = jsonList.length;

  for (final raw in jsonList) {
    processed++;
    final data = raw as Map<String, dynamic>;
    try {
      final hiddenPrompt = (data['hiddenPrompt'] ?? '').toString().trim();
      if (hiddenPrompt.isEmpty || seenHiddenPrompts.contains(hiddenPrompt)) {
        skippedDuplicate++;
        _printProgress(processed, total, added, skippedDuplicate, flaggedForCleanup, failed);
        continue;
      }
      seenHiddenPrompts.add(hiddenPrompt);

      String imageUrl = (data['imageUrl'] ?? '').toString();
      if (imageUrl.isNotEmpty && imageUrl.startsWith('http') && !imageUrl.contains('imgbb.com')) {
        try {
          final resp = await http.get(Uri.parse(imageUrl));
          if (resp.statusCode == 200) {
            imageUrl = await _uploadToImgBB(resp.bodyBytes, imgbbKey);
          } else {
            stderr.writeln('\n  (HTTP ${resp.statusCode} fetching image for "$hiddenPrompt" — keeping original URL)');
          }
        } catch (e) {
          stderr.writeln('\n  (could not re-host image for "$hiddenPrompt", keeping original URL: $e)');
        }
      }

      final flagCleanup = needsCleanup(hiddenPrompt);
      if (flagCleanup) flaggedForCleanup++;

      await _createPromptDoc(
        idToken: idToken,
        imageUrl: imageUrl,
        category: (data['category'] ?? 'General').toString(),
        hiddenPrompt: hiddenPrompt,
        isPremium: data['isPremium'] == true,
        gender: detectGender(hiddenPrompt),
        needsCleanup: flagCleanup,
      );
      added++;
    } catch (e) {
      failed++;
      stderr.writeln('\n  Failed on entry $processed: $e');
    }
    _printProgress(processed, total, added, skippedDuplicate, flaggedForCleanup, failed);
  }

  print('');
  print('');
  print('Done. $added added as drafts, $skippedDuplicate skipped as duplicates, '
      '$flaggedForCleanup flagged for cleanup, $failed failed, out of $total total.');
  print('Open the admin panel > Prompts > "Draft" filter to review and publish them.');
}

void _printProgress(int processed, int total, int added, int skipped, int cleanup, int failed) {
  stdout.write(
    '\rProcessed $processed/$total — added:$added skipped:$skipped cleanup:$cleanup failed:$failed   ',
  );
}

Future<String> _signIn(String email, String password) async {
  final res = await http.post(
    Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$_firebaseApiKey'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
  );
  final data = jsonDecode(res.body);
  if (res.statusCode != 200 || data['idToken'] == null) {
    throw 'Sign-in failed: ${res.body}';
  }
  return data['idToken'] as String;
}

Future<Set<String>> _fetchExistingHiddenPrompts() async {
  final seen = <String>{};
  String? pageToken;
  do {
    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents/prompts'
      '?pageSize=300&mask.fieldPaths=hiddenPrompt${pageToken != null ? '&pageToken=$pageToken' : ''}',
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw 'Failed to list existing prompts: ${res.body}';
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final docs = (data['documents'] as List<dynamic>? ?? []);
    for (final doc in docs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      final hp = fields?['hiddenPrompt']?['stringValue'] as String?;
      if (hp != null && hp.trim().isNotEmpty) seen.add(hp.trim());
    }
    pageToken = data['nextPageToken'] as String?;
  } while (pageToken != null);
  return seen;
}

Future<String> _uploadToImgBB(List<int> bytes, String imgbbKey) async {
  final req = http.MultipartRequest('POST', Uri.parse('https://api.imgbb.com/1/upload?key=$imgbbKey'));
  req.files.add(http.MultipartFile.fromBytes('image', bytes, filename: 'prompt.jpg'));
  final streamed = await req.send();
  final body = await streamed.stream.bytesToString();
  if (streamed.statusCode != 200) {
    throw 'ImgBB upload failed: $body';
  }
  final data = jsonDecode(body);
  return data['data']['url'] as String;
}

Future<void> _createPromptDoc({
  required String idToken,
  required String imageUrl,
  required String category,
  required String hiddenPrompt,
  required bool isPremium,
  required String gender,
  required bool needsCleanup,
}) async {
  final res = await http.post(
    Uri.parse('https://firestore.googleapis.com/v1/projects/$_projectId/databases/(default)/documents/prompts'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $idToken',
    },
    body: jsonEncode({
      'fields': {
        'imageUrl': {'stringValue': imageUrl},
        'category': {'stringValue': category},
        'hiddenPrompt': {'stringValue': hiddenPrompt},
        'isPremium': {'booleanValue': isPremium},
        'gender': {'stringValue': gender},
        'isPublished': {'booleanValue': false},
        'needsCleanup': {'booleanValue': needsCleanup},
      },
    }),
  );
  if (res.statusCode != 200) {
    throw 'Firestore write failed: ${res.body}';
  }
}
