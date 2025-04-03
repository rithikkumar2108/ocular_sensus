import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:flutter/material.dart';
import 'home.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Stack(
            children: [
              // Background Gradient Container
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
              // Fully Transparent SignInScreen
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 30.0, vertical: 45),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20), // Rounded corners
                  child: Material(
                    color: const Color.fromARGB(40, 145, 141, 141), // Ensure Material is transparent
                    child: Theme(
                      data: ThemeData.dark().copyWith(
                        cardTheme: const CardTheme(
                          color: Color.fromARGB(180, 0, 0, 0), // Slight transparency
                          shadowColor: Colors.transparent, // Removes shadow
                        ),
                        scaffoldBackgroundColor: const Color.fromARGB(0, 255, 255, 255), // Keep background transparent
                        dialogBackgroundColor: const Color.fromARGB(180, 0, 0, 0), // Slightly transparent pop-ups
                      ),
                      child: SignInScreen(
                        providers: [
                          EmailAuthProvider(),
                        ],
                        headerBuilder: (context, constraints, shrinkOffset) {
                          return Padding(
                            padding: const EdgeInsets.all(20),
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: Image.asset(
                                "assets/new_app_icon.png",
                                fit: BoxFit.contain,
                              ),
                            ),
                          );
                        },
                        subtitleBuilder: (context, action) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8.0),
                            child: action == AuthAction.signIn
                                ? const Text(
                                    'Welcome to Ocular Sensus, please sign in!',
                                    style: TextStyle(color: Colors.white),
                                  )
                                : const Text(
                                    'Sign up to be a part of this awesome community!!!',
                                    style: TextStyle(color: Colors.white),
                                  ),
                          );
                        },
                        actions: [
                          ForgotPasswordAction((context, _) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => Scaffold(
                                  backgroundColor: Colors.transparent, // Ensure Scaffold is transparent
                                  body: Container( // Apply gradient directly to ForgotPasswordScreen
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
        return const HomeScreen();
      },
    );
  }
}