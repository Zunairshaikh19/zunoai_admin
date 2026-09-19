import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'features/dashboard/presentation/admin_root_screen.dart';
import 'features/auth/presentation/admin_login_screen.dart';
import 'services/firebase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyCmoGoxenH5dFqT56SKIf12WMxjb84wIWo",
      authDomain: "zunoai-b924f.firebaseapp.com",
      projectId: "zunoai-b924f",
      storageBucket: "zunoai-b924f.firebasestorage.app",
      messagingSenderId: "31792471355",
      appId: "1:31792471355:web:431c13c8667f20f5576b1e",
      measurementId: "G-9FWH61P4KX",
    ),
  );
  runApp(const ProviderScope(child: AdminApp()));
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zuno AI Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.purpleAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const AdminAuthWrapper(),
    );
  }
}

class AdminAuthWrapper extends ConsumerWidget {
  const AdminAuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) {
          return FutureBuilder<bool>(
            future: FirebaseService().isAdmin(snapshot.data!.uid),
            builder: (context, adminSnapshot) {
              if (adminSnapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              if (adminSnapshot.data == true) {
                return const AdminRootScreen();
              }
              FirebaseAuth.instance.signOut();
              return const AdminLoginScreen(
                error: 'This account does not have admin access.',
              );
            },
          );
        }
        return const AdminLoginScreen();
      },
    );
  }
}
