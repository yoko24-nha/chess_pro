// lib/screen/home_page.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
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
  bool _hasShownSurrenderMessage = false;
  bool _hasShownDrawDialog = false;
  String _playerName = '';
  List<String> _playersInRoom = [];
  final TextEditingController _chatController = TextEditingController();
  late Stream<QuerySnapshot<Map<String, dynamic>>>? _chatStream;

  // --- DRAW FEATURE ---
  String? _drawOfferedBy; // who offered draw (from server)
  bool _isDraw = false; // whether the game has become a draw
  // --- END DRAW FEATURE ---

  // Clock state
  Timer? _clockTimer;
  int _timePerPlayer = 0; // seconds (0 = no clock)
  int _whiteRemaining = 0;
  int _blackRemaining = 0;
  String _currentTurn = 'white'; // 'white' or 'black'

  // room-end state from Firestore
  String? _timeoutWinner;
  String? _surrenderedBy;

  @override
  void dispose() {
    _clockTimer?.cancel();
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
          decoration: const InputDecoration(
            hintText: 'Enter your display name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      setState(() => _playerName = result);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Name set: $_playerName')));
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

    final minutesController = TextEditingController(text: '5');
    final result = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Time per player (minutes)'),
        content: TextField(
          controller: minutesController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Minutes per player (leave blank for no clock)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(
              ctx,
            ).pop(int.tryParse(minutesController.text ?? '0')),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    int? minutes = result;
    int? timePerSec;
    if (minutes != null && minutes > 0) timePerSec = minutes * 60;

    final id = await _fsService.createRoom(
      _controller.getFen(),
      _playerName,
      timePerPlayer: timePerSec,
    );
    setState(() {
      _roomId = id;
      if (timePerSec != null) {
        _timePerPlayer = timePerSec;
        _whiteRemaining = timePerSec;
        _blackRemaining = timePerSec;
        _currentTurn = 'white';
      } else {
        _timePerPlayer = 0;
      }
      _timeoutWinner = null;
      _surrenderedBy = null;
      // --- DRAW FEATURE ---
      _drawOfferedBy = null;
      _isDraw = false;
      _hasShownDrawDialog = false;
      // --- END DRAW FEATURE ---
    });
    _listenRoom(id);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Room created: $id')));
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
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Joined room: $roomIdToJoin')));
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
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _surrender() async {
    if (_roomId.isEmpty || _playerName.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận đầu hàng'),
        content: const Text('Bạn có chắc muốn đầu hàng ván này không?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Đầu hàng'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _fsService.surrender(_roomId, _playerName);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bạn đã đầu hàng!')));
  }

  Future<void> _showDrawOfferDialog(String offerPlayer) async {
    final accept = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Lời đề nghị hòa'),
        content: Text('$offerPlayer muốn hòa. Bạn có chấp nhận không?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Từ chối'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Chấp nhận'),
          ),
        ],
      ),
    );

    if (accept == true) {
      // call firestore respondDraw -> will set gameOver/result in DB
      try {
        await _fsService.respondDraw(_roomId, true);
      } catch (e) {
        debugPrint('[draw] respondDraw failed: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Ván cờ kết thúc hòa')));
      }
    } else if (accept == false) {
      try {
        await _fsService.respondDraw(_roomId, false);
      } catch (e) {
        debugPrint('[draw] reject failed: $e');
      }
    }
  }

  // ----------------- CORE: listenRoom (robust) -----------------
  void _listenRoom(String roomId) {
    _chatStream = _fsService.listenMessages(roomId);

    _roomSub?.cancel();
    _roomSub = _fsService.listenRoom(roomId, (data) {
      if (data == null) {
        setState(() => _playersInRoom = []);
        return;
      }

      // read raw fields safely
      final String? surrendered = data['surrenderedBy'] as String?;
      final String? timeoutWinner = data['timeoutWinner'] as String?;
      // --- DRAW FEATURE: read draw fields from server ---
      final String? drawOffer = (data['drawOffer'] is String)
          ? data['drawOffer'] as String
          : null;
      final String? result = (data['result'] is String)
          ? data['result'] as String
          : null;
      // --- END DRAW FEATURE ---
      final int timePer = (data['timePerPlayer'] is int)
          ? data['timePerPlayer'] as int
          : _timePerPlayer;
      final int whiteRemFromServer = (data['whiteRemaining'] is int)
          ? data['whiteRemaining'] as int
          : _whiteRemaining;
      final int blackRemFromServer = (data['blackRemaining'] is int)
          ? data['blackRemaining'] as int
          : _blackRemaining;
      final String serverTurn = (data['turn'] is String)
          ? data['turn'] as String
          : _currentTurn;
      final Timestamp? lastUpdate = data['lastUpdate'] as Timestamp?;

      final players = <String>[];
      if (data['players'] is List) {
        for (final e in (data['players'] as List)) {
          if (e is String) players.add(e);
        }
      }

      // compute adjusted remaining (subtract elapsed only from side that server says is running)
      int adjustedWhite = whiteRemFromServer;
      int adjustedBlack = blackRemFromServer;
      if (lastUpdate != null && timePer > 0) {
        final lastUtc = lastUpdate.toDate().toUtc();
        final elapsed = DateTime.now().toUtc().difference(lastUtc).inSeconds;
        if (elapsed > 0) {
          if (serverTurn == 'white') {
            adjustedWhite = (whiteRemFromServer - elapsed).clamp(0, timePer);
          } else {
            adjustedBlack = (blackRemFromServer - elapsed).clamp(0, timePer);
          }
        }
      }

      // log for debugging
      debugPrint(
        '[listenRoom] serverTurn=$serverTurn lastUpdate=${lastUpdate?.toDate().toIso8601String()} players=${players.length}',
      );
      debugPrint(
        '[listenRoom] serverWhite=$whiteRemFromServer serverBlack=$blackRemFromServer adjustedW=$adjustedWhite adjustedB=$adjustedBlack',
      );

      // update state once
      setState(() {
        _timePerPlayer = timePer;
        _whiteRemaining = adjustedWhite;
        _blackRemaining = adjustedBlack;
        _currentTurn = serverTurn;
        _timeoutWinner = timeoutWinner;
        _surrenderedBy = surrendered;
        _playersInRoom = players;
        // --- DRAW FEATURE state update ---
        _drawOfferedBy = drawOffer;
        // if server declares result == 'draw' we mark local flag
        _isDraw = (result == 'draw');
      });

      // notifications
      if (surrendered != null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$surrendered đã đầu hàng!')));

          FirebaseFirestore.instance
              .collection(_fsService.roomsColl)
              .doc(roomId)
              .update({'surrenderedBy': null});
        }
      }
      if (timeoutWinner != null) {
        if (mounted) {
          final text = timeoutWinner == 'white'
              ? 'bên trắng thắng (timeout)'
              : 'bên đen thắng (timeout)';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(text)));
        }
        _clockTimer?.cancel();
      }

      // --- DRAW FEATURE: react to draw offer / accepted ---
      if (drawOffer != null && drawOffer != _playerName && result != 'draw') {
        // someone else offered draw; show dialog once
        if (!_hasShownDrawDialog) {
          _hasShownDrawDialog = true;
          // fire-and-forget dialog (dialog itself will call respondDraw)
          _showDrawOfferDialog(drawOffer);
        }
      } else if (drawOffer == null) {
        // reset shown flag so future offers will show again
        _hasShownDrawDialog = false;
      }

      if (result == 'draw') {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Ván cờ kết thúc hòa')));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ván cờ kết thúc hòa')),
          );
        }

        _clockTimer?.cancel();

        // ✅ Reset board & local state
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;

          setState(() {
            _controller.resetBoard();
            _whiteRemaining = _timePerPlayer;
            _blackRemaining = _timePerPlayer;
            _currentTurn = 'white';
            _drawOfferedBy = null;
            _isDraw = false;
            _hasShownDrawDialog = false;
          });
          // ✅ Clear result & drawOffer in Firestore after reset
          _fsService.clearGameResult(_roomId);
        });
      }

      // --- END DRAW FEATURE ---

      // decide whether to start/stop ticker:
      final playersCount = players.length;
      if (_timePerPlayer > 0 &&
          _timeoutWinner == null &&
          _surrenderedBy == null &&
          lastUpdate != null &&
          playersCount >= 2) {
        _startClockTicker();
      } else {
        _clockTimer?.cancel();
      }

      // apply fen if needed
      final String fen = (data['fen'] as String?) ?? '';
      final String currentFen = _controller.getFen();
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

  // ----------------- clock ticker (single source of truth) -----------------
  void _startClockTicker() {
    if (_timePerPlayer <= 0) return;

    // Cancel previous timer to avoid duplicates
    _clockTimer?.cancel();

    debugPrint(
      '[startClockTicker] start; currentTurn=$_currentTurn white=$_whiteRemaining black=$_blackRemaining',
    );

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      // read current turn at tick time to avoid closure capturing stale value
      final nowTurn = _currentTurn;

      setState(() {
        if (nowTurn == 'white') {
          _whiteRemaining = (_whiteRemaining - 1).clamp(0, _timePerPlayer);
        } else {
          _blackRemaining = (_blackRemaining - 1).clamp(0, _timePerPlayer);
        }
      });

      // debug each tick
      debugPrint(
        '[tick] nowTurn=$nowTurn white=$_whiteRemaining black=$_blackRemaining',
      );

      // if timeout -> claim once and stop
      if (_whiteRemaining <= 0 || _blackRemaining <= 0) {
        final winner = _whiteRemaining <= 0 ? 'black' : 'white';
        try {
          await _fsService.claimTimeout(_roomId, winner);
        } catch (e) {
          debugPrint('[tick] claimTimeout failed: $e');
        }
        if (mounted) {
          final text = winner == 'white'
              ? 'bên trắng thắng (timeout)'
              : 'bên đen thắng (timeout)';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(text)));
        }
        _clockTimer?.cancel();
      }
    });
  }

  // ----------------- when local user makes a move -----------------
  // Thay thế toàn bộ hàm _onFenChanged bằng đoạn này
  void _onFenChanged(String fen) async {
    if (_isApplyingRemote) return;
    if (_roomId.isNotEmpty) {
      // --- NEW: xử lý xin hòa ---
      if (fen == 'DRAW_REQUESTED') {
        await _fsService.offerDraw(_roomId, _playerName);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Đã gửi lời đề nghị hòa'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return; // không cần xử lý FEN tiếp
      }
      // --- END NEW ---

      if (fen == 'SURRENDERED') {
        await _fsService.updateRoomFen(_roomId, _controller.getFen());
        await _fsService.surrender(_roomId, _playerName);

        if (!_hasShownSurrenderMessage) {
          _hasShownSurrenderMessage = true;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('$_playerName đã đầu hàng! Ván đấu kết thúc.'),
                duration: const Duration(seconds: 2),
              ),
            );
          }
          await Future.delayed(const Duration(seconds: 2));
          setState(() {
            _controller.resetBoard();
          });
          _hasShownSurrenderMessage = false;
        }
      } else {
        // Nếu có clock thì dùng transaction để update room
        if (_timePerPlayer > 0) {
          final sideMoved = _currentTurn; // 'white' hoặc 'black'
          final nextTurn = (sideMoved == 'white') ? 'black' : 'white';

          debugPrint(
            '[local move] sideMoved=$sideMoved computed nextTurn=$nextTurn players=${_playersInRoom.length}',
          );

          if (_playersInRoom.length >= 2) {
            setState(() {
              _currentTurn = nextTurn;
            });
            if (_timePerPlayer > 0 &&
                _timeoutWinner == null &&
                _surrenderedBy == null) {
              _startClockTicker();
            }
          }

          try {
            await _fsService.updateRoomOnMove(
              _roomId,
              fen,
              whiteRemaining: _whiteRemaining,
              blackRemaining: _blackRemaining,
              nextTurn: nextTurn,
            );
          } catch (e) {
            debugPrint('[local move] updateRoomOnMove failed: $e');
          }
        } else {
          await _fsService.updateRoomFen(_roomId, fen);
        }
      }
    }
  }

  void _sendMessage() async {
    if (_chatController.text.trim().isEmpty ||
        _roomId.isEmpty ||
        _playerName.isEmpty)
      return;
    await _fsService.sendMessage(
      _roomId,
      _playerName,
      _chatController.text.trim(),
    );
    _chatController.clear();
  }

  void _copyRoomId() {
    if (_roomId.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _roomId));
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Room ID copied')));
  }

  Future<void> _leaveRoom() async {
    if (_roomId.isEmpty) return;
    if (_playerName.isNotEmpty) {
      await _fsService.removePlayerFromRoom(_roomId, _playerName);
    }
    _roomSub?.cancel();
    _clockTimer?.cancel();
    setState(() {
      _roomId = '';
      _playersInRoom = [];
      _timePerPlayer = 0;
      _whiteRemaining = 0;
      _blackRemaining = 0;
      _timeoutWinner = null;
      _surrenderedBy = null;
      // --- DRAW FEATURE reset ---
      _drawOfferedBy = null;
      _isDraw = false;
      _hasShownDrawDialog = false;
      // --- END DRAW FEATURE ---
    });
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Left room')));
  }

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                _playerName.isEmpty ? 'No name set' : _playerName,
              ),
              accountEmail: Text(
                _roomId.isEmpty ? 'Not in room' : 'Room: $_roomId',
              ),
              currentAccountPicture: CircleAvatar(
                child: Text(
                  (_playerName.isNotEmpty ? _playerName[0] : '?').toUpperCase(),
                ),
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
            ListTile(
              leading: const Icon(Icons.flag),
              title: const Text('Đầu hàng'),
              onTap: () {
                Navigator.of(context).pop();
                _surrender();
              },
            ),
            // --- DRAW FEATURE: Xin hòa in Drawer ---
            ListTile(
              leading: const Icon(Icons.handshake),
              title: const Text('Xin hòa'),
              onTap: () {
                Navigator.of(context).pop();
                if (_roomId.isNotEmpty && _playerName.isNotEmpty) {
                  // call service to offer draw
                  _fsService.offerDraw(_roomId, _playerName);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã gửi lời đề nghị hòa')),
                  );
                }
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
          children: _playersInRoom
              .map(
                (p) => Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Chip(label: Text(p)),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  bool get _isGameOver {
    // also include checkmate via controller
    bool cm = false;
    try {
      cm = _controller.isCheckMate();
    } catch (_) {
      cm = false;
    }
    return _timeoutWinner != null || _surrenderedBy != null || cm || _isDraw;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Chess — Local + Firestore')),
      drawer: _buildDrawer(),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: FlutterChessWidget(
                  controller: _controller,
                  onFenChanged: _onFenChanged,
                  enableUserMoves: !_isGameOver,
                ),
              ),
              const Divider(),
              Container(
                width: double.infinity,
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 10.0,
                ),
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
                        Text(
                          'Room: ${_roomId.isEmpty ? "(not in room)" : _roomId}',
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _copyRoomId,
                          icon: const Icon(Icons.copy),
                        ),
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
                    const Divider(height: 32),
                    Text(
                      'Chat:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),

                    Container(
                      height: 200,
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 8.0,
                      ),
                      padding: const EdgeInsets.all(8.0),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: _roomId.isEmpty
                          ? const Center(
                              child: Text('(Tham gia phòng để chat)'),
                            )
                          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                              stream: _chatStream,
                              builder: (context, snapshot) {
                                if (!snapshot.hasData) {
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
                                }
                                final docs = snapshot.data!.docs;
                                if (docs.isEmpty)
                                  return const Text('(Chưa có tin nhắn)');
                                return ListView.builder(
                                  reverse: true,
                                  itemCount: docs.length,
                                  itemBuilder: (ctx, i) {
                                    final msg = docs[i].data();
                                    final sender = msg['sender'] ?? 'Unknown';
                                    final text = msg['text'] ?? '';
                                    return Align(
                                      alignment: sender == _playerName
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: sender == _playerName
                                              ? Colors.blue.shade100
                                              : Colors.grey.shade300,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text('$sender: $text'),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                    ),

                    // Ô nhập chat
                    if (_roomId.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 4.0,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _chatController,
                                decoration: const InputDecoration(
                                  hintText: 'Nhập tin nhắn...',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _sendMessage(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.send, color: Colors.blue),
                              onPressed: _sendMessage,
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 12),
                    if (_timePerPlayer > 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Column(
                            children: [
                              Text(
                                'White',
                                style: TextStyle(
                                  fontWeight: _currentTurn == 'white'
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              Text(
                                _formatTime(_whiteRemaining),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                          Column(
                            children: [
                              Text(
                                'Black',
                                style: TextStyle(
                                  fontWeight: _currentTurn == 'black'
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              Text(
                                _formatTime(_blackRemaining),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    if (_timeoutWinner != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          _timeoutWinner == 'white'
                              ? 'bên trắng thắng (timeout)'
                              : 'bên đen thắng (timeout)',
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    if (_surrenderedBy != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          '$_surrenderedBy đã đầu hàng',
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    // --- DRAW FEATURE: visual indicators ---
                    if (_drawOfferedBy != null &&
                        _drawOfferedBy != _playerName &&
                        !_isDraw)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          '$_drawOfferedBy đã gửi lời đề nghị hòa...',
                          style: const TextStyle(color: Colors.orange),
                        ),
                      ),
                    if (_isDraw)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          'Ván cờ đã hòa',
                          style: const TextStyle(color: Colors.green),
                        ),
                      ),

                    // --- END DRAW FEATURE ---
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
