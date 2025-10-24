// lib/screen/home_page.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

import '../services/firestore_service.dart';
import '../widgets/chess_board_widget.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ChessBoardController _controller = ChessBoardController();
  final FirestoreService _fsService = FirestoreService();

  final TextEditingController _joinController = TextEditingController();

  String _roomId = '';
  StreamSubscription? _roomSub;
  bool _isApplyingRemote = false;

  String _playerName = '';
  List<String> _playersInRoom = [];

  @override
  void dispose() {
    _roomSub?.cancel();
    _joinController.dispose();
    super.dispose();
  }

  Future<void> _setPlayerNameDialog() async {
    final controller = TextEditingController(text: _playerName);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set your name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter your display name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() => _playerName = result);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Name set: $_playerName')));
      if (_roomId.isNotEmpty) {
        await _fsService.addPlayerToRoom(_roomId, _playerName);
      }
    }
  }

  Future<void> _createRoom() async {
    if (_playerName.isEmpty) {
      await _setPlayerNameDialog();
      if (_playerName.isEmpty) return;
    }

    final id = await _fsService.createRoom(_controller.getFen(), _playerName);
    setState(() => _roomId = id);
    _listenRoom(id);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Room created: $id')));
  }

  Future<void> _joinRoom() async {
    final id = _joinController.text.trim();
    if (id.isEmpty) {
      final input = await _showJoinDialog();
      if (input == null || input.isEmpty) return;
      _joinController.text = input;
    }

    final roomIdToJoin = _joinController.text.trim();
    if (roomIdToJoin.isEmpty) return;

    if (_playerName.isEmpty) {
      await _setPlayerNameDialog();
      if (_playerName.isEmpty) return;
    }

    await _fsService.addPlayerToRoom(roomIdToJoin, _playerName);

    setState(() => _roomId = roomIdToJoin);
    _listenRoom(roomIdToJoin);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Joined room: $roomIdToJoin')));
  }

  Future<String?> _showJoinDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join Room'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter Room ID'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Join')),
        ],
      ),
    );
    return result;
  }

  void _listenRoom(String roomId) {
    _roomSub?.cancel();
    _roomSub = _fsService.listenRoom(roomId, (data) {
      if (data == null) {
        setState(() => _playersInRoom = []);
        return;
      }
      final fen = data['fen'] as String? ?? '';
      final players = <String>[];
      if (data.containsKey('players')) {
        final raw = data['players'];
        if (raw is List) {
          for (final e in raw) {
            if (e is String) players.add(e);
          }
        }
      }
      setState(() => _playersInRoom = players);

      final currentFen = _controller.getFen();
      if (fen.isNotEmpty && fen != currentFen) {
        _isApplyingRemote = true;
        try {
          _controller.loadFen(fen);
        } catch (_) {}
        Future.delayed(const Duration(milliseconds: 50), () {
          _isApplyingRemote = false;
        });
      }
    });
  }

  void _onFenChanged(String fen) {
    if (_isApplyingRemote) return;
    if (_roomId.isNotEmpty) {
      _fsService.updateRoomFen(_roomId, fen);
    }
  }

  void _copyRoomId() {
    if (_roomId.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _roomId));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Room ID copied')));
  }

  Future<void> _leaveRoom() async {
    if (_roomId.isEmpty) return;
    if (_playerName.isNotEmpty) {
      await _fsService.removePlayerFromRoom(_roomId, _playerName);
    }
    _roomSub?.cancel();
    setState(() {
      _roomId = '';
      _playersInRoom = [];
    });
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Left room')));
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(_playerName.isEmpty ? 'No name set' : _playerName),
              accountEmail: Text(_roomId.isEmpty ? 'Not in room' : 'Room: $_roomId'),
              currentAccountPicture: CircleAvatar(
                child: Text((_playerName.isNotEmpty ? _playerName[0] : '?').toUpperCase()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Set Name'),
              onTap: () {
                Navigator.of(context).pop();
                _setPlayerNameDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('Create Room'),
              onTap: () {
                Navigator.of(context).pop();
                _createRoom();
              },
            ),
            ListTile(
              leading: const Icon(Icons.meeting_room),
              title: const Text('Join Room'),
              onTap: () async {
                Navigator.of(context).pop();
                final input = await _showJoinDialog();
                if (input != null && input.isNotEmpty) {
                  _joinController.text = input;
                  _joinRoom();
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy Room ID'),
              onTap: () {
                Navigator.of(context).pop();
                _copyRoomId();
              },
            ),
            ListTile(
              leading: const Icon(Icons.exit_to_app),
              title: const Text('Leave Room'),
              onTap: () {
                Navigator.of(context).pop();
                _leaveRoom();
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                Navigator.of(context).pop();
                showAboutDialog(
                  context: context,
                  applicationName: 'Flutter Chess Starter',
                  applicationVersion: '0.1',
                  children: const [Text('Starter app with Firestore sync.')],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _playersWidget() {
    if (_roomId.isEmpty) return const Text('(Not in a room)');
    if (_playersInRoom.isEmpty) return const Text('(No players yet)');
    return SizedBox(
      height: 56,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _playersInRoom.map((p) => Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Chip(label: Text(p)),
          )).toList(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use SafeArea to avoid system UI and ensure content fits
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Chess — Local + Firestore')),
      drawer: _buildDrawer(),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Board area
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: FlutterChessWidget(
                  controller: _controller,
                  onFenChanged: _onFenChanged,
                ),
              ),

              // Divider (optional)
              const Divider(),

              // Bottom info area
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 10.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Player: ${_playerName.isEmpty ? "(set your name from menu)" : _playerName}',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text('Room: ${_roomId.isEmpty ? "(not in room)" : _roomId}'),
                        const SizedBox(width: 8),
                        IconButton(onPressed: _copyRoomId, icon: const Icon(Icons.copy)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Players in room: '),
                        const SizedBox(width: 8),
                        Expanded(child: _playersWidget()),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
