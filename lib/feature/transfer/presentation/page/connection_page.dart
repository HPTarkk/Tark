import 'package:flutter/material.dart';

class ConnectionPage extends StatefulWidget {
  static const path = '/';
  static const name = 'ConnectionPage';
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(body: _buildBody());
  }

  Widget _buildBody() => Container();
}
