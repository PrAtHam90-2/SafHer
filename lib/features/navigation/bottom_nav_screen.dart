import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

class BottomNavScreen extends StatefulWidget {
  final Widget child;

  const BottomNavScreen({super.key, required this.child});

  @override
  State<BottomNavScreen> createState() => _BottomNavScreenState();
}

class _BottomNavScreenState extends State<BottomNavScreen> {
  int _currentIndex = 0;

  void _onTap(int index, BuildContext context) {
    if (index == _currentIndex) return;

    setState(() {
      _currentIndex = index;
    });

    switch (index) {
      case 0:
        context.go('/home');
        break;
      case 1:
        context.go('/trip');
        break;
      case 2:
        context.go('/verify');
        break;
      case 3:
        context.go('/sos');
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Determine the current index based on the route location
    // to keep the bottom nav in sync with the current URL/Path.
    final String location = GoRouterState.of(context).uri.toString();
    if (location.startsWith('/home')) {
      _currentIndex = 0;
    } else if (location.startsWith('/trip')) {
      _currentIndex = 1;
    } else if (location.startsWith('/verify')) {
      _currentIndex = 2;
    } else if (location.startsWith('/sos')) {
      _currentIndex = 3;
    }

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => _onTap(index, context),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(LucideIcons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(LucideIcons.map),
            label: 'Trip',
          ),
          BottomNavigationBarItem(
            icon: Icon(LucideIcons.shieldCheck),
            label: 'Verify',
          ),
          BottomNavigationBarItem(
            icon: Icon(LucideIcons.alertCircle), // Better matching icon for SOS
            label: 'SOS',
          ),
        ],
      ),
    );
  }
}
