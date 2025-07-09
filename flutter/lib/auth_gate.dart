import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/material.dart';
import 'home.dart';
import 'main.dart'; // Ensure initializeService and requestPermissions are available from main.dart

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Flag to ensure service is only initialized once upon login
  bool _serviceInitialized = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // If user is logged in
        if (snapshot.hasData) {
          // If the service hasn't been initialized yet for this login session
          if (!_serviceInitialized) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              // Permissions are now requested in main.dart upon app startup.
              // No need to request them again here.
              // await requestPermissions(); // REMOVED THIS LINE

              final service = FlutterBackgroundService();
              final isRunning = await service.isRunning();
              if (!isRunning) {
                print("User logged in, starting background service...");
                // initializeService() is already called in main.dart
                // await initializeService(); // No need to call again if already called in main
                await service.startService(); // Explicitly start it
              }
              if (mounted) {
                setState(() {
                  _serviceInitialized = true; // Mark as initialized
                });
              }
            });
          }
          return const HomeScreen();
        } else {
          // User is not logged in, show SignInScreen
          // Reset service initialized flag if user logs out
          if (_serviceInitialized) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              final service = FlutterBackgroundService();
              final isRunning = await service.isRunning();
              if (isRunning) {
                print("User logged out, stopping background service...");
                service.invoke("stopService"); // Signal to stop the service
              }
              if (mounted) {
                setState(() {
                  _serviceInitialized = false; // Reset the flag
                });
              }
            });
          }

          return Stack(
            children: [
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.fromARGB(255, 33, 72, 93),
                      Color.fromARGB(255, 25, 55, 79),
                      Color.fromARGB(255, 84, 103, 103),
                    ],
                    stops: [0.0, 0.46, 1.0],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30.0, vertical: 45),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Material(
                    color: const Color.fromARGB(40, 145, 141, 141),
                    child: Theme(
                      data: ThemeData.dark().copyWith(
                        cardTheme: const CardThemeData(
                          color: Color.fromARGB(180, 0, 0, 0),
                          shadowColor: Colors.transparent,
                        ),
                        scaffoldBackgroundColor: const Color.fromARGB(0, 255, 255, 255),
                        dialogTheme: const DialogThemeData(backgroundColor: Color.fromARGB(180, 0, 0, 0)),
                      ),
                      child: SignInScreen(
                        providers: [EmailAuthProvider()],
                        headerBuilder: (context, constraints, shrinkOffset) {
                          return Padding(
                            padding: const EdgeInsets.all(20),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: Image.asset("assets/new_app_icon.png", fit: BoxFit.contain),
                            ),
                          );
                        },
                        subtitleBuilder: (context, action) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: Text(
                              action == AuthAction.signIn
                                  ? 'Welcome to Ocular Sensus, please sign in!'
                                  : 'Sign up to be a part of this awesome community!!!',
                              style: const TextStyle(color: Colors.white),
                            ),
                          );
                        },
                        actions: [
                          ForgotPasswordAction((context, _) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => Scaffold(
                                  backgroundColor: Colors.transparent,
                                  body: Container(
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color.fromARGB(255, 33, 72, 93),
                                          Color.fromARGB(255, 25, 55, 79),
                                          Color.fromARGB(255, 84, 103, 103),
                                        ],
                                        stops: [0.0, 0.46, 1.0],
                                      ),
                                    ),
                                    child: ForgotPasswordScreen(
                                      email: FirebaseAuth.instance.currentUser?.email,
                                      headerMaxExtent: 200,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );
  }
}