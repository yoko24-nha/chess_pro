// lib/ai/easy_ai.dart
import 'dart:math';

import 'package:chess/chess.dart' as chess;

/// EasyAI - AI chess với mức độ ~700 Elo
/// - Độ sâu tìm kiếm thấp (2-3)
/// - Xác suất blunder cao (15-20%)
/// - Đánh giá đơn giản (chỉ material + mobility cơ bản)
/// - Không có transposition table phức tạp
class EasyAI {
  final int maxDepth;
  final double blunderProb;
  final Random _rng;
  final int timeLimitMillis;

  // Piece values (centipawns)
  static const Map<String, int> _pieceValue = {
    'p': 100,
    'n': 320,
    'b': 330,
    'r': 500,
    'q': 900,
    'k': 20000,
  };

  EasyAI({
    this.maxDepth = 2,
    this.blunderProb = 0.18,
    this.timeLimitMillis = 800,
    int? seed,
  }) : _rng = Random(seed);

  // Đánh giá vị trí đơn giản: chỉ material + mobility cơ bản
  int _evaluate(chess.Chess game) {
    int score = 0;

    // Material evaluation
    final boardList = game.board;
    for (int i = 0; i < boardList.length; i++) {
      final p = boardList[i];
      if (p == null) continue;
      final type = p.type;
      final color = p.color;
      final base = _pieceValue[type] ?? 0;
      if (color == chess.Color.WHITE) {
        score += base;
      } else {
        score -= base;
      }
    }

    // Mobility (số nước đi có thể) - đơn giản
    try {
      final moves = game.moves();
      if (game.turn == chess.Color.WHITE) {
        score += moves.length * 5;
      } else {
        score -= moves.length * 5;
      }
    } catch (_) {}

    return score;
  }

  // Kiểm tra có phải capture không
  bool _isCapture(chess.Chess g, dynamic mv) {
    try {
      final fenBefore = g.fen ?? g.generate_fen();
      final ok = g.move(mv);
      if (!ok) return false;
      final fenAfter = g.fen ?? g.generate_fen();
      g.undo();
      return fenBefore.split(' ')[0] != fenAfter.split(' ')[0] ||
          mv.toString().contains('x');
    } catch (_) {
      return mv.toString().contains('x');
    }
  }

  // Quiescence search đơn giản (chỉ xem captures)
  int _quiescence(chess.Chess game, int alpha, int beta, int depthLeft) {
    if (depthLeft <= 0)
      return _evaluate(game) * (game.turn == chess.Color.WHITE ? 1 : -1);

    final standPat =
        _evaluate(game) * (game.turn == chess.Color.WHITE ? 1 : -1);
    if (standPat >= beta) return beta;
    if (alpha < standPat) alpha = standPat;

    final moves = game.moves();
    final captures = <dynamic>[];
    for (final mv in moves) {
      if (_isCapture(game, mv)) captures.add(mv);
    }

    // Xáo trộn captures để có tính ngẫu nhiên
    captures.shuffle(_rng);

    for (final mv in captures) {
      if (!game.move(mv)) continue;
      final score = -_quiescence(game, -beta, -alpha, depthLeft - 1);
      game.undo();
      if (score >= beta) return beta;
      if (score > alpha) alpha = score;
    }

    return alpha;
  }

  // Minimax với alpha-beta pruning (đơn giản)
  int _minimax(chess.Chess game, int depth, int alpha, int beta) {
    if (depth <= 0 || game.game_over) {
      return _quiescence(game, alpha, beta, 2);
    }

    final moves = game.moves();
    if (moves.isEmpty) {
      return _evaluate(game) * (game.turn == chess.Color.WHITE ? 1 : -1);
    }

    // Xáo trộn moves để có tính ngẫu nhiên
    final shuffledMoves = List.from(moves);
    shuffledMoves.shuffle(_rng);

    // Sắp xếp đơn giản: captures trước
    shuffledMoves.sort((a, b) {
      final aCapture = _isCapture(game, a);
      final bCapture = _isCapture(game, b);
      if (aCapture && !bCapture) return -1;
      if (!aCapture && bCapture) return 1;
      return 0;
    });

    int bestValue = -100000000;

    for (final mv in shuffledMoves) {
      if (!game.move(mv)) continue;
      final val = -_minimax(game, depth - 1, -beta, -alpha);
      game.undo();

      if (val >= beta) return beta; // Beta cutoff
      if (val > bestValue) {
        bestValue = val;
      }
      if (val > alpha) alpha = val;
    }

    return bestValue;
  }

  // Chọn nước đi
  String chooseMove(chess.Chess game) {
    final moves = game.moves();
    if (moves.isEmpty) return '';

    // Xác suất blunder: đánh ngẫu nhiên
    if (_rng.nextDouble() < blunderProb) {
      final randomMove = moves[_rng.nextInt(moves.length)];
      return randomMove is String ? randomMove : randomMove.toString();
    }

    String bestMove = moves[_rng.nextInt(moves.length)].toString();
    int bestScore = -100000000;

    // Xáo trộn để có tính ngẫu nhiên
    final shuffledMoves = List.from(moves);
    shuffledMoves.shuffle(_rng);

    // Sắp xếp: captures và checks trước
    shuffledMoves.sort((a, b) {
      final aCapture = _isCapture(game, a);
      final bCapture = _isCapture(game, b);
      final aCheck = _givesCheck(game, a);
      final bCheck = _givesCheck(game, b);

      if (aCheck && !bCheck) return -1;
      if (!aCheck && bCheck) return 1;
      if (aCapture && !bCapture) return -1;
      if (!aCapture && bCapture) return 1;
      return 0;
    });

    final startTime = DateTime.now();

    for (final mv in shuffledMoves) {
      // Kiểm tra thời gian
      if (timeLimitMillis > 0) {
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        if (elapsed >= timeLimitMillis) break;
      }

      if (!game.move(mv)) continue;
      final score = -_minimax(game, maxDepth - 1, -100000000, 100000000);
      game.undo();

      if (score > bestScore) {
        bestScore = score;
        bestMove = mv is String ? mv : mv.toString();
      }
    }

    return bestMove;
  }

  // Kiểm tra nước đi có gây check không
  bool _givesCheck(chess.Chess g, dynamic mv) {
    try {
      final ok = g.move(mv);
      if (!ok) return false;
      final inCheck = g.in_check;
      g.undo();
      return inCheck;
    } catch (_) {
      return false;
    }
  }

  // Chọn nước từ FEN
  Map<String, String> chooseMoveFromFen(String fen) {
    final game = chess.Chess();
    try {
      game.load(fen);
    } catch (e) {
      try {
        final g2 = chess.Chess.fromFEN(fen);
        return _computeFromGame(g2);
      } catch (_) {
        return {'fen': fen, 'move': ''};
      }
    }
    return _computeFromGame(game);
  }

  Map<String, String> _computeFromGame(chess.Chess game) {
    final move = chooseMove(game);
    if (move.isEmpty) {
      return {'fen': game.fen ?? game.generate_fen(), 'move': ''};
    }

    final ok = game.move(move);
    if (!ok) {
      return {'fen': game.fen ?? game.generate_fen(), 'move': move};
    }

    final String newFen = (game.fen?.isNotEmpty == true)
        ? game.fen!
        : game.generate_fen();
    return {'fen': newFen, 'move': move};
  }
}

/// Wrapper function cho compute (isolates)
Map<String, String> computeBestMoveEasyAI(Map<String, dynamic> args) {
  final fen = args['fen'] as String? ?? '';
  final depth = args['maxDepth'] as int? ?? 2;
  final blunder = args['blunderProb'] as double? ?? 0.18;
  final timeLimit = args['timeLimitMillis'] as int? ?? 800;
  final seed = args['seed'] as int?;

  final ai = EasyAI(
    maxDepth: depth,
    blunderProb: blunder,
    timeLimitMillis: timeLimit,
    seed: seed,
  );
  return ai.chooseMoveFromFen(fen);
}
