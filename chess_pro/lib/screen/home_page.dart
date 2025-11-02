// lib/screen/home_page.dart
import 'dart:async';
import 'dart:math';

import 'package:chess_pro/ai/easy_ai.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';
import 'package:chess/chess.dart' as chess;

import '../services/firestore_service.dart';
import '../services/theme_service.dart';
import '../widgets/chess_board_widget.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Controllers & services
  final ChessBoardController _controller = ChessBoardController();
  final FirestoreService _fsService = FirestoreService();
  final TextEditingController _joinController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();

  // Room & Firestore
  String _roomId = '';
  StreamSubscription? _roomSub;
  late Stream<QuerySnapshot<Map<String, dynamic>>>? _chatStream;

  // UI state
  String _playerName = '';
  List<String> _playersInRoom = [];

  // Game flags / result
  String? _surrenderedBy;
  String? _timeoutWinner;
  String? _drawOfferedBy;
  bool _isDraw = false;
  bool _hasShownDrawDialog = false;
  bool _hasShownSurrenderMessage = false;

  // Clock
  Timer? _clockTimer;
  int _timePerPlayer = 0;
  int _whiteRemaining = 0;
  int _blackRemaining = 0;
  String _currentTurn = 'white'; // 'white' or 'black'

  // AI state
  bool _aiEnabled = false;
  bool _humanIsWhite = true;
  EasyAI? _ai;
  bool _isPerformingAIMove = false;
  bool _isApplyingRemote = false;

  // FEN history to avoid repetition
  final List<String> _fenHistory = [];
  final Random _rng = Random();
  static const int _fenHistoryMax = 16;

  // Prevent duplicate handling of the same FEN shortly after applying it
  String? _lastAppliedFen;
  DateTime? _lastAppliedFenAt;

  // AI/move guards
  int? _lastAIPly; // ply of last AI-applied position
  bool _aiScheduled = false;
  Timer? _applyRemoteFallbackTimer;
  bool _lastMoveByAI = false; // whether last move was by AI

  // human move token to avoid race (incremented each human move)
  int _humanMoveId = 0;
  int? _aiScheduledForHumanId;

  final Random _random = Random();

  // Board theme
  BoardColor _boardColor = BoardColor.brown;

  // Clock state: track if first move has been made
  bool _firstMoveMade = false;

  @override
  void initState() {
    super.initState();
    try {
      _fenHistory.add(_controller.getFen());
    } catch (_) {}
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final theme = await ThemeService.getTheme();
    if (mounted) {
      setState(() {
        _boardColor = theme;
      });
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _roomSub?.cancel();
    _joinController.dispose();
    _chatController.dispose();
    _applyRemoteFallbackTimer?.cancel();
    super.dispose();
  }

  void _addFenToHistory(String fen) {
    if (fen.isEmpty) return;
    if (_fenHistory.isEmpty || _fenHistory.last != fen) {
      _fenHistory.add(fen);
      if (_fenHistory.length > _fenHistoryMax) {
        _fenHistory.removeRange(0, _fenHistory.length - _fenHistoryMax);
      }
      debugPrint('[HISTORY] len=${_fenHistory.length} fen=$fen');
    }
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  bool get _isGameOver {
    bool cm = false;
    try {
      cm = _controller.isCheckMate();
    } catch (_) {}
    return _timeoutWinner != null || _surrenderedBy != null || cm || _isDraw;
  }

  Future<void> _setPlayerNameDialog() async {
    final controller = TextEditingController(text: _playerName);
    final res = await showDialog<String?>(
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
    if (res != null && res.isNotEmpty) {
      setState(() => _playerName = res);
      if (_roomId.isNotEmpty)
        await _fsService.addPlayerToRoom(_roomId, _playerName);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Name set: $_playerName')));
    }
  }

  Future<String?> _showJoinDialog() async {
    final controller = TextEditingController();
    return showDialog<String?>(
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
      _drawOfferedBy = null;
      _isDraw = false;
      _hasShownDrawDialog = false;
      _playersInRoom = [];
      _firstMoveMade = false; // Reset khi tạo room mới
    });
    _listenRoom(id);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Room created: $id')));
  }

  Future<void> _joinRoom() async {
    final id = _joinController.text.trim();
    String? roomId = id.isEmpty ? await _showJoinDialog() : id;
    if (roomId == null || roomId.isEmpty) return;
    if (_playerName.isEmpty) {
      await _setPlayerNameDialog();
      if (_playerName.isEmpty) return;
    }
    await _fsService.addPlayerToRoom(roomId, _playerName);
    setState(() => _roomId = roomId);
    _listenRoom(roomId);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Joined room: $roomId')));
  }

  Future<void> _leaveRoom() async {
    if (_roomId.isEmpty) return;
    if (_playerName.isNotEmpty)
      await _fsService.removePlayerFromRoom(_roomId, _playerName);
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
      _drawOfferedBy = null;
      _isDraw = false;
      _hasShownDrawDialog = false;
      _firstMoveMade = false; // Reset khi rời room
    });
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Left room')));
  }

  void _listenRoom(String roomId) {
    _chatStream = _fsService.listenMessages(roomId);
    _roomSub?.cancel();
    _roomSub = _fsService.listenRoom(roomId, (data) {
      if (data == null) {
        setState(() => _playersInRoom = []);
        return;
      }

      final String? surrendered = data['surrenderedBy'] as String?;
      final String? timeoutWinner = data['timeoutWinner'] as String?;
      final String? drawOffer = (data['drawOffer'] is String)
          ? data['drawOffer'] as String
          : null;
      final String? result = (data['result'] is String)
          ? data['result'] as String
          : null;
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

      debugPrint('[listenRoom] turn=$serverTurn players=${players.length}');

      setState(() {
        _timePerPlayer = timePer;
        _whiteRemaining = adjustedWhite;
        _blackRemaining = adjustedBlack;
        _currentTurn = serverTurn;
        _timeoutWinner = timeoutWinner;
        _surrenderedBy = surrendered;
        _playersInRoom = players;
        _drawOfferedBy = drawOffer;
        _isDraw = (result == 'draw');
      });

      if (surrendered != null) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$surrendered đã đầu hàng!')));
        FirebaseFirestore.instance
            .collection(_fsService.roomsColl)
            .doc(roomId)
            .update({'surrenderedBy': null});
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

      if (drawOffer != null && drawOffer != _playerName && result != 'draw') {
        if (!_hasShownDrawDialog) {
          _hasShownDrawDialog = true;
          _showDrawOfferDialog(drawOffer);
        }
      } else if (drawOffer == null) {
        _hasShownDrawDialog = false;
      }

      if (result == 'draw') {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Ván cờ kết thúc hòa')));
        _clockTimer?.cancel();
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
            _firstMoveMade = false; // Reset khi ván hòa
          });
          _fsService.clearGameResult(_roomId);
        });
      }

      // KHÔNG tự động start đồng hồ khi có 2 players
      // Đồng hồ chỉ start sau khi trắng đánh nước đầu tiên (trong _onFenChanged)

      final String fen = (data['fen'] as String?) ?? '';
      final String currentFen = _controller.getFen();

      // Phát hiện nước đầu tiên từ server: khi ply = 1 (trắng đã đánh xong)
      if (fen.isNotEmpty && timePer > 0) {
        final serverPly = _plyFromFen(fen);
        final turnInFen = _turnFromFen(fen);
        if (serverPly == 1 && turnInFen == 'black') {
          // Trắng vừa đánh xong, đến lượt đen -> đây là nước đầu tiên
          _firstMoveMade = true;
          debugPrint('[LISTENROOM] First move detected from server');
        }
      }

      if (fen.isNotEmpty && fen != currentFen) {
        // Nếu đây là echo của nước AI vừa gửi, không trigger AI lại
        final isAIMoveEcho =
            _lastMoveByAI == true &&
            _lastAppliedFen != null &&
            fen == _lastAppliedFen;
        if (isAIMoveEcho) {
          debugPrint('[LISTENROOM] ignoring AI move echo from server');
        }

        _isApplyingRemote = true;
        try {
          _controller.loadFen(fen);
          debugPrint('[LISTENROOM] loaded fen from server: $fen');
        } catch (e) {
          debugPrint('[LISTENROOM] loadFen error: $e');
        }
        Future.delayed(const Duration(milliseconds: 120), () {
          _isApplyingRemote = false;
          _addFenToHistory(fen);
          // Chỉ trigger AI nếu đây KHÔNG phải echo của nước AI
          if (!isAIMoveEcho) {
            _maybeTriggerAIMove();
          } else {
            debugPrint(
              '[LISTENROOM] skipped _maybeTriggerAIMove because this is AI echo',
            );
          }
        });
      }
    });
  }

  void _startClockTicker() {
    if (_timePerPlayer <= 0) return;
    // Chỉ start đồng hồ sau khi đã có nước đi đầu tiên
    if (!_firstMoveMade) {
      debugPrint('[startClockTicker] skipped: first move not made yet');
      return;
    }
    _clockTimer?.cancel();
    debugPrint(
      '[startClockTicker] start; turn=$_currentTurn white=$_whiteRemaining black=$_blackRemaining',
    );
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final nowTurn = _currentTurn;
      setState(() {
        // Đếm ngược cho bên ĐANG có lượt (đang chơi)
        if (nowTurn == 'white') {
          _whiteRemaining = (_whiteRemaining - 1).clamp(0, _timePerPlayer);
        } else {
          _blackRemaining = (_blackRemaining - 1).clamp(0, _timePerPlayer);
        }
      });
      debugPrint(
        '[tick] nowTurn=$nowTurn white=$_whiteRemaining black=$_blackRemaining',
      );
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

  // -------------------- AI helpers --------------------
  bool _aiShouldMove(String fen) {
    if (!_aiEnabled) return false;
    if (_isGameOver) return false;
    if (_isPerformingAIMove) return false;
    final parts = fen.split(' ');
    final active = (parts.length > 1) ? parts[1] : 'w';
    final aiColor = _humanIsWhite ? 'b' : 'w';
    return active == aiColor;
  }

  int _plyFromFen(String fen) {
    try {
      final parts = fen.split(' ');
      if (parts.length < 6) return 0;
      final fullmove = int.tryParse(parts[5]) ?? 1;
      final active = (parts.length > 1) ? parts[1] : 'w';
      final ply = (fullmove - 1) * 2 + (active == 'b' ? 1 : 0);
      return ply;
    } catch (_) {
      return 0;
    }
  }

  // Lấy lượt hiện tại từ FEN
  String _turnFromFen(String fen) {
    try {
      final parts = fen.split(' ');
      if (parts.length < 2) return 'white';
      final active = parts[1].toLowerCase();
      return active == 'w' ? 'white' : 'black';
    } catch (_) {
      return 'white';
    }
  }

  void _maybeTriggerAIMove() {
    try {
      final fen = _controller.getFen();
      final curPly = _plyFromFen(fen);
      debugPrint(
        '[AI] maybeTrigger fen=$fen ply=$curPly aiEnabled=$_aiEnabled performing=$_isPerformingAIMove scheduled=$_aiScheduled applying=$_isApplyingRemote lastAIPly=$_lastAIPly humanId=$_humanMoveId',
      );

      if (!_aiEnabled) return;
      if (_isGameOver) return;

      // nếu nước vừa rồi do AI thì không trigger
      if (_lastMoveByAI) {
        debugPrint('[AI] skip: last move was by AI');
        return;
      }

      // guards
      final since = DateTime.now()
          .difference(
            _lastAppliedFenAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          )
          .inMilliseconds;
      if (_lastAppliedFen != null && _lastAppliedFen == fen && since < 400) {
        debugPrint('[AI] skip: recent apply guard');
        return;
      }
      if (_isApplyingRemote) {
        debugPrint('[AI] skip: _isApplyingRemote true');
        return;
      }
      if (_isPerformingAIMove) {
        debugPrint('[AI] skip: _isPerformingAIMove true');
        return;
      }
      if (_aiScheduled) {
        debugPrint('[AI] skip: already scheduled');
        return;
      }
      // Kiểm tra ply: chỉ trigger nếu ply tăng so với lastAIPly (đảm bảo đây là nước mới của người)
      if (_lastAIPly != null && curPly <= _lastAIPly!) {
        debugPrint(
          '[AI] skip: curPly ($curPly) <= lastAIPly ($_lastAIPly) - this is still AI\'s move',
        );
        return;
      }
      // Thêm kiểm tra: nếu fen trùng với lastAppliedFen và lastMoveByAI là true, skip
      if (_lastAppliedFen != null &&
          fen == _lastAppliedFen &&
          _lastMoveByAI == true) {
        debugPrint(
          '[AI] skip: fen matches lastAppliedFen and lastMoveByAI is true',
        );
        return;
      }
      if (!_aiShouldMove(fen)) return;

      // schedule AI for the current human move id (token)
      final scheduledFor = _humanMoveId;
      _aiScheduledForHumanId = scheduledFor;
      _aiScheduled = true;
      debugPrint('[AI] scheduled for humanId=$scheduledFor');

      Future.delayed(const Duration(milliseconds: 200), () async {
        // if human moved again since scheduling, abort
        if (_humanMoveId != scheduledFor) {
          debugPrint(
            '[AI] abort scheduled run: human moved (scheduledFor=$scheduledFor current=$_humanMoveId)',
          );
          _aiScheduled = false;
          _aiScheduledForHumanId = null;
          return;
        }

        // clear scheduled marker and actually perform
        _aiScheduled = false;
        _aiScheduledForHumanId = null;
        // call internal performer with the scheduled token for further checks
        _isPerformingAIMove = true;
        try {
          await _performAIMoveInternal(scheduledFor);
        } catch (e) {
          debugPrint('[AI] scheduled perform error: $e');
        } finally {
          _isPerformingAIMove = false;
        }
      });
    } catch (e) {
      debugPrint('[AI] maybeTrigger error: $e');
    }
  }

  Future<void> _performAIMoveInternal(int scheduledForHumanId) async {
    if (!_aiEnabled || _ai == null) return;

    // Double-check human did not move meanwhile
    if (_humanMoveId != scheduledForHumanId) {
      debugPrint(
        '[AI] abort perform: human moved before start (scheduledFor=$scheduledForHumanId current=$_humanMoveId)',
      );
      return;
    }

    final fen = _controller.getFen();
    debugPrint('[AI] perform START fen=$fen scheduledFor=$scheduledForHumanId');

    final args = {
      'fen': fen,
      'maxDepth': _ai!.maxDepth,
      'blunderProb': _ai!.blunderProb,
      'timeLimitMillis': _ai!.timeLimitMillis,
      'seed': DateTime.now().millisecondsSinceEpoch,
    };

    Map<String, String> result = {'fen': fen, 'move': ''};
    try {
      result = await compute(computeBestMoveEasyAI, args);
    } catch (e, st) {
      debugPrint('[AI] compute error: $e\n$st');
    }

    final proposedFen = result['fen'] ?? fen;
    final moveStr = result['move'] ?? '';
    debugPrint(
      '[AI] computed move=$moveStr fen=$proposedFen (scheduledFor=$scheduledForHumanId)',
    );

    // If human moved while AI was computing -> abort
    if (_humanMoveId != scheduledForHumanId) {
      debugPrint(
        '[AI] abort after compute: human moved (scheduledFor=$scheduledForHumanId current=$_humanMoveId)',
      );
      return;
    }

    if (moveStr.isEmpty || proposedFen == fen) {
      debugPrint('[AI] no move or fen unchanged');
      return;
    }

    // If proposedFen in history, try alternatives (existing logic)...
    if (_fenHistory.contains(proposedFen)) {
      debugPrint('[AI] proposedFen in history, trying alternatives...');
      try {
        final chessGame = chess.Chess();
        chessGame.load(fen);
        final moves = chessGame.moves();
        final alternatives = <String>[];
        for (final mv in moves) {
          final ok = chessGame.move(mv);
          if (!ok) continue;
          final f = (chessGame.fen?.isNotEmpty == true)
              ? chessGame.fen!
              : chessGame.generate_fen();
          chessGame.undo();
          if (!_fenHistory.contains(f)) alternatives.add(f);
        }
        if (alternatives.isNotEmpty) {
          final altFen = alternatives[_rng.nextInt(alternatives.length)];
          // recheck human didn't move
          if (_humanMoveId != scheduledForHumanId) {
            debugPrint('[AI] abort before applying alt: human moved');
            return;
          }
          // Apply alt
          if (_roomId.isNotEmpty) {
            // mark before update
            _lastAppliedFen = altFen;
            _lastAppliedFenAt = DateTime.now();
            _isApplyingRemote = true;
            _lastMoveByAI = true;
            _lastAIPly = _plyFromFen(altFen);
            _applyRemoteFallbackTimer?.cancel();
            _applyRemoteFallbackTimer = Timer(
              const Duration(milliseconds: 2500),
              () {
                if (_isApplyingRemote) {
                  debugPrint(
                    '[AI] applyRemoteFallbackTimer clearing _isApplyingRemote (fallback)',
                  );
                  _isApplyingRemote = false;
                }
              },
            );
            try {
              await _fsService.updateRoomFen(_roomId, altFen);
            } catch (e, st) {
              debugPrint('[AI] updateRoomFen alt failed: $e\n$st');
              _applyAIMoveLocally(altFen);
              _applyRemoteFallbackTimer?.cancel();
            }
          } else {
            _lastMoveByAI = true;
            _lastAIPly = _plyFromFen(altFen);
            _applyAIMoveLocally(altFen);
          }
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('AI played: (alt) $moveStr'),
                duration: const Duration(milliseconds: 700),
              ),
            );
          return;
        }
      } catch (e, st) {
        debugPrint('[AI] alt search error: $e\n$st');
      }
    }

    // Final apply proposedFen (re-check human didn't move)
    if (_humanMoveId != scheduledForHumanId) {
      debugPrint('[AI] abort before final apply: human moved');
      return;
    }

    if (_roomId.isNotEmpty) {
      try {
        _lastAppliedFen = proposedFen;
        _lastAppliedFenAt = DateTime.now();
        _isApplyingRemote = true;
        _lastMoveByAI = true;
        _lastAIPly = _plyFromFen(proposedFen);
        _applyRemoteFallbackTimer?.cancel();
        _applyRemoteFallbackTimer = Timer(const Duration(milliseconds: 2500), () {
          if (_isApplyingRemote) {
            debugPrint(
              '[AI] applyRemoteFallbackTimer clearing _isApplyingRemote (fallback)',
            );
            _isApplyingRemote = false;
          }
        });
        await _fsService.updateRoomFen(_roomId, proposedFen);
        debugPrint('[AI] updated room with fen (server).');
      } catch (e, st) {
        debugPrint('[AI] updateRoomFen failed: $e\n$st');
        _lastMoveByAI = true;
        _lastAIPly = _plyFromFen(proposedFen);
        _applyAIMoveLocally(proposedFen);
        _applyRemoteFallbackTimer?.cancel();
      }
    } else {
      _lastMoveByAI = true;
      _lastAIPly = _plyFromFen(proposedFen);
      _applyAIMoveLocally(proposedFen);
    }

    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('AI played: $moveStr'),
          duration: const Duration(milliseconds: 700),
        ),
      );
    debugPrint('[AI] perform END scheduledFor=$scheduledForHumanId');
  }

  Future<void> _performAIMove() async {
    final id = _humanMoveId;
    if (_isPerformingAIMove) return;
    _isPerformingAIMove = true;
    try {
      await _performAIMoveInternal(id);
    } finally {
      _isPerformingAIMove = false;
    }
  }

  void _applyAIMoveLocally(String newFen) {
    // mark we are applying a change we triggered, and record it to avoid duplicates
    _isApplyingRemote = true;
    _lastAppliedFen = newFen;
    _lastAppliedFenAt = DateTime.now();

    // mark that the last move was by AI so maybeTrigger won't fire again.
    _lastMoveByAI = true;
    _lastAIPly = _plyFromFen(newFen);

    // cancel any existing fallback timer and create a fresh one to clear _isApplyingRemote
    _applyRemoteFallbackTimer?.cancel();
    _applyRemoteFallbackTimer = Timer(const Duration(milliseconds: 2500), () {
      if (_isApplyingRemote) {
        debugPrint(
          '[AI] applyRemoteFallbackTimer clearing _isApplyingRemote (fallback)',
        );
        _isApplyingRemote = false;
      }
    });

    try {
      debugPrint('[AI] applying newFen locally: $newFen');
      _controller.loadFen(newFen);
    } catch (e) {
      debugPrint('[AI] loadFen failed: $e');
    }

    // Keep suppressed state briefly for safety, then add history.
    Future.delayed(const Duration(milliseconds: 150), () {
      _isApplyingRemote = false;
      _addFenToHistory(newFen);
    });
  }

  void _onFenChanged(String fen) async {
    debugPrint(
      '[ONFEN] fen=$fen isApplying=$_isApplyingRemote roomId=$_roomId lastApplied=$_lastAppliedFen lastAIPly=$_lastAIPly lastMoveByAI=$_lastMoveByAI isPerforming=$_isPerformingAIMove',
    );

    // 1) Nếu đang trong trạng thái "đang apply" do AI/server thì:
    if (_isApplyingRemote) {
      // Nếu đây đúng là echo của fen mà ta vừa apply -> ignore (điều mình muốn)
      if (_lastAppliedFen != null && fen == _lastAppliedFen) {
        debugPrint(
          '[ONFEN] ignored because _isApplyingRemote is true and fen == lastAppliedFen',
        );
        return;
      }
      // Nếu _isApplyingRemote true nhưng FEN KHÔNG phải là lastAppliedFen => race; bỏ cờ và xử lý tiếp
      debugPrint(
        '[ONFEN] _isApplyingRemote true but fen != lastAppliedFen -> clearing _isApplyingRemote and continuing',
      );
      _isApplyingRemote = false;
    }

    // 2) Duplicate recent-apply guard (grace window)
    if (_lastAppliedFen != null && fen == _lastAppliedFen) {
      final since = DateTime.now()
          .difference(
            _lastAppliedFenAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          )
          .inMilliseconds;
      if (since < 2000) {
        debugPrint('[ONFEN] ignored duplicate fen (recent): $fen');
        return;
      }
    }

    // 3) Nếu AI đang tính hoặc đang thực hiện move, kiểm tra kỹ trước khi xử lý
    if (_isPerformingAIMove) {
      // Nếu đây là FEN do AI vừa apply (trùng lastAppliedFen), bỏ qua hoàn toàn
      if (_lastAppliedFen != null &&
          fen == _lastAppliedFen &&
          _lastMoveByAI == true) {
        debugPrint(
          '[ONFEN] AI is performing and fen matches lastAppliedFen — ignoring completely',
        );
        return;
      }
      // Nếu ply <= lastAIPly, đây vẫn là nước của AI
      final checkPly = _plyFromFen(fen);
      if (_lastMoveByAI == true &&
          _lastAIPly != null &&
          checkPly <= _lastAIPly!) {
        debugPrint(
          '[ONFEN] AI is performing and ply ($checkPly) <= lastAIPly ($_lastAIPly) — ignoring',
        );
        _addFenToHistory(fen);
        return;
      }
      debugPrint(
        '[ONFEN] note: _isPerformingAIMove == true but continuing (might be human move during AI calculation)',
      );
    }

    // 4) Special commands
    if (fen == 'DRAW_REQUESTED') {
      if (_roomId.isNotEmpty) await _fsService.offerDraw(_roomId, _playerName);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Đã gửi lời đề nghị hòa')));
      return;
    }
    if (fen == 'SURRENDERED') {
      if (_roomId.isNotEmpty) {
        await _fsService.updateRoomFen(_roomId, _controller.getFen());
        await _fsService.surrender(_roomId, _playerName);
      } else {
        _controller.resetBoard();
      }
      if (!_hasShownSurrenderMessage) {
        _hasShownSurrenderMessage = true;
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$_playerName đã đầu hàng! Ván đấu kết thúc.'),
            ),
          );
        await Future.delayed(const Duration(seconds: 2));
        _hasShownSurrenderMessage = false;
      }
      return;
    }

    // 5) Kiểm tra: nếu đây là nước của AI (fen trùng lastAppliedFen hoặc ply <= lastAIPly), KHÔNG coi là nước người
    final curPly = _plyFromFen(fen);

    // Quan trọng: Nếu FEN trùng với lastAppliedFen và lastMoveByAI == true,
    // đây chắc chắn là echo của AI move, bỏ qua hoàn toàn (kể cả khi _isApplyingRemote đã clear)
    if (_lastAppliedFen != null &&
        fen == _lastAppliedFen &&
        _lastMoveByAI == true) {
      debugPrint(
        '[ONFEN] detected AI move echo (fen matches lastAppliedFen) — ignoring completely',
      );
      _addFenToHistory(fen);
      return;
    }

    // Kiểm tra ply: nếu ply <= lastAIPly và lastMoveByAI == true, đây vẫn là nước của AI
    if (_lastMoveByAI == true && _lastAIPly != null && curPly <= _lastAIPly!) {
      debugPrint(
        '[ONFEN] detected AI move (ply=$curPly <= lastAIPly=$_lastAIPly) — not resetting _lastMoveByAI',
      );
      _addFenToHistory(fen);
      return;
    }

    // 6) Nếu tới đây, ta coi event này là một nước do "người" thực hiện.
    //    CHỈ reset _lastMoveByAI và tăng _humanMoveId nếu chắc chắn đây là nước MỚI của người (ply tăng lên)
    //    Điều này ngăn việc trigger AI nhiều lần từ cùng một nước đi (nếu có nhiều events)
    bool isConfirmedNewHumanMove = false;

    if (_lastAIPly == null) {
      // Nếu chưa có lastAIPly, có thể là nước đầu tiên hoặc chưa có AI move
      _lastMoveByAI = false;
      isConfirmedNewHumanMove = true;
    } else if (curPly > _lastAIPly!) {
      // Ply tăng lên so với lastAIPly → chắc chắn là nước mới của người
      debugPrint(
        '[ONFEN] confirmed human move: ply increased from $_lastAIPly to $curPly',
      );
      _lastMoveByAI = false;
      isConfirmedNewHumanMove = true;
    } else {
      // curPly <= lastAIPly: có thể là:
      // - AI move (đã được xử lý ở trên và return)
      // - Event trùng lặp từ cùng một nước đi
      // Không coi đây là nước mới của người
      debugPrint(
        '[ONFEN] ply not increased (curPly=$curPly, lastAIPly=$_lastAIPly) — ignoring as duplicate event',
      );
      _addFenToHistory(fen);
      return;
    }

    // CHỈ increment human move token nếu đây là nước mới thực sự
    if (isConfirmedNewHumanMove) {
      _humanMoveId++;
      debugPrint('[ONFEN] humanMoveId incremented to $_humanMoveId');
    }

    // Normal move: if in room, update server; otherwise local -> trigger AI
    if (_roomId.isNotEmpty) {
      if (_timePerPlayer > 0) {
        // Xác định bên vừa đánh dựa trên lượt hiện tại trong FEN
        final turnInFen = _turnFromFen(fen);
        // Bên vừa đánh là bên NGƯỢC với turn hiện tại trong FEN
        final sideMoved = (turnInFen == 'white') ? 'black' : 'white';
        final nextTurn = turnInFen;

        // Phát hiện nước đầu tiên: khi ply = 1 (trắng vừa đánh xong, đến lượt đen)
        final isFirstMove = (curPly == 1 && sideMoved == 'white');
        if (isFirstMove) {
          _firstMoveMade = true;
          debugPrint(
            '[ONFEN] First move detected: white has moved, starting clock',
          );
        }

        if (_playersInRoom.length >= 2) {
          // Dừng đồng hồ của bên vừa đánh (nếu đã start)
          _clockTimer?.cancel();

          setState(() {
            _currentTurn = nextTurn;
          });

          // Chỉ start đồng hồ cho bên tiếp theo nếu đã có nước đầu tiên
          if (_firstMoveMade &&
              _timePerPlayer > 0 &&
              _timeoutWinner == null &&
              _surrenderedBy == null) {
            // Start đồng hồ cho bên tiếp theo (đang có lượt)
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
          debugPrint('[ONFEN] updateRoomOnMove failed: $e');
        }
      } else {
        try {
          await _fsService.updateRoomFen(_roomId, fen);
        } catch (e) {
          debugPrint('[ONFEN] updateRoomFen failed: $e');
        }
      }
      // server will push fen back and listener will apply; it will also add to history there
    } else {
      // local-only: record history and check AI
      _addFenToHistory(fen);
      // small delay then maybe trigger AI
      Future.delayed(const Duration(milliseconds: 200), () {
        final since = DateTime.now()
            .difference(
              _lastAppliedFenAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            )
            .inMilliseconds;
        if (_lastAppliedFen == fen && since < 400) {
          debugPrint(
            '[ONFEN] not triggering AI because fen was just applied locally.',
          );
          return;
        }
        _maybeTriggerAIMove();
      });
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

  Future<void> _showThemeDialog() async {
    final themes = ThemeService.getAvailableThemes();
    final selectedTheme = await showDialog<BoardColor>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chọn màu bàn cờ'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: themes.length,
            itemBuilder: (context, index) {
              final theme = themes[index];
              final color = theme['color'] as BoardColor;
              final name = theme['name'] as String;
              final isSelected = color == _boardColor;

              return ListTile(
                leading: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected ? Theme.of(context).primaryColor : null,
                ),
                title: Text(name),
                subtitle: Text(theme['description'] as String),
                selected: isSelected,
                onTap: () => Navigator.of(ctx).pop(color),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
        ],
      ),
    );

    if (selectedTheme != null && selectedTheme != _boardColor) {
      await ThemeService.setTheme(selectedTheme);
      if (mounted) {
        setState(() {
          _boardColor = selectedTheme;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Đã đổi theme thành: ${themes.firstWhere((t) => t['color'] == selectedTheme)['name']}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
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
      try {
        await _fsService.respondDraw(_roomId, true);
      } catch (e) {
        debugPrint('[draw] respondDraw failed: $e');
      }
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Ván cờ kết thúc hòa')));
    } else if (accept == false) {
      try {
        await _fsService.respondDraw(_roomId, false);
      } catch (e) {
        debugPrint('[draw] reject failed: $e');
      }
    }
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
            ListTile(
              leading: const Icon(Icons.handshake),
              title: const Text('Xin hòa'),
              onTap: () {
                Navigator.of(context).pop();
                if (_roomId.isNotEmpty && _playerName.isNotEmpty) {
                  _fsService.offerDraw(_roomId, _playerName);
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã gửi lời đề nghị hòa')),
                    );
                } else {
                  setState(() => _isDraw = true);
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Đã hòa (local)')),
                    );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy),
              title: const Text('Play vs AI (≈700 Elo)'),
              subtitle: const Text('Depth & blunder tunable'),
              onTap: () async {
                Navigator.of(context).pop();
                final pick = await showDialog<String?>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Chọn màu cho người chơi'),
                    content: const Text('Bạn muốn chơi màu trắng hay đen?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop('white'),
                        child: const Text('Trắng'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop('black'),
                        child: const Text('Đen'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                );
                if (pick == null) return;
                setState(() {
                  _aiEnabled = true;
                  _humanIsWhite = (pick == 'white');
                  // EasyAI với mức độ ~700 Elo
                  _ai = EasyAI(
                    maxDepth: 2,
                    blunderProb: 0.18,
                    timeLimitMillis: 800,
                  );
                  _controller.resetBoard();
                  _roomId = '';
                  _playersInRoom = [];
                  _fenHistory.clear();
                  _addFenToHistory(_controller.getFen());
                });
                if (!_humanIsWhite)
                  Future.delayed(
                    const Duration(milliseconds: 250),
                    () => _maybeTriggerAIMove(),
                  );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.palette),
              title: const Text('Đổi màu bàn cờ'),
              subtitle: const Text('Change board theme'),
              onTap: () {
                Navigator.of(context).pop();
                _showThemeDialog();
              },
            ),
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
                  boardColor: _boardColor,
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
                                if (!snapshot.hasData)
                                  return const Center(
                                    child: CircularProgressIndicator(),
                                  );
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
