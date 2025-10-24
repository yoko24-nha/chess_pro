// lib/widgets/chess_board_widget.dart
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

/// Reusable chess board widget with controls and callback when FEN changes.
/// Now the board height is limited so it won't push other UI off-screen.
class FlutterChessWidget extends StatefulWidget {
  final ChessBoardController controller;
  final void Function(String fen)? onFenChanged;
  final String? initialFen;

  const FlutterChessWidget({
    Key? key,
    required this.controller,
    this.onFenChanged,
    this.initialFen,
  }) : super(key: key);

  @override
  State<FlutterChessWidget> createState() => _FlutterChessWidgetState();
}

class _FlutterChessWidgetState extends State<FlutterChessWidget> {
  bool _isWhiteOrientation = true;

  @override
  void initState() {
    super.initState();
    if ((widget.initialFen ?? '').isNotEmpty) {
      try {
        widget.controller.loadFen(widget.initialFen!);
      } catch (_) {}
    }
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final fen = widget.controller.getFen();
    if (widget.onFenChanged != null) widget.onFenChanged!(fen);
    setState(() {}); // update moves display etc.
  }

  void _toggleOrientation() {
    setState(() {
      _isWhiteOrientation = !_isWhiteOrientation;
    });
  }

  Future<void> _copyFenToClipboard() async {
    final fen = widget.controller.getFen();
    await Clipboard.setData(ClipboardData(text: fen));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('FEN copied to clipboard')));
    }
  }

  Future<void> _importFenDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import FEN'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Paste FEN here'),
          maxLines: 2,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Load')),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        widget.controller.loadFen(result);
        if (widget.onFenChanged != null) widget.onFenChanged!(widget.controller.getFen());
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid FEN')));
      }
    }
  }

  void _undoMove() {
    widget.controller.undoMove();
    if (widget.onFenChanged != null) widget.onFenChanged!(widget.controller.getFen());
  }

  void _resetBoard() {
    widget.controller.resetBoard();
    if (widget.onFenChanged != null) widget.onFenChanged!(widget.controller.getFen());
  }

  @override
  Widget build(BuildContext context) {
    final moves = widget.controller.getSan();

    // Compute a reasonable max height for board:
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final screenW = media.size.width;
    // leave room for appbar + controls (approx 220), but calculate defensively
    final maxBoardHeight = min(screenH * 0.60, screenW - 32); // at most 60% screen height or fit width
    final boardHeight = max(240.0, maxBoardHeight); // minimum reasonable size

    return Column(
      children: [
        // Board constrained by a fixed max height (prevents overflow)
        SizedBox(
          height: boardHeight,
          width: double.infinity,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: boardHeight, maxWidth: boardHeight),
              child: ChessBoard(
                controller: widget.controller,
                boardColor: BoardColor.brown,
                boardOrientation: _isWhiteOrientation ? PlayerColor.white : PlayerColor.black,
                enableUserMoves: true,
              ),
            ),
          ),
        ),

        // Controls row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _toggleOrientation,
                icon: const Icon(Icons.screen_rotation),
                label: const Text('Flip'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _undoMove,
                icon: const Icon(Icons.undo),
                label: const Text('Undo'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _resetBoard,
                icon: const Icon(Icons.refresh),
                label: const Text('Reset'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Copy FEN',
                onPressed: _copyFenToClipboard,
                icon: const Icon(Icons.copy),
              ),
              IconButton(
                tooltip: 'Import FEN',
                onPressed: _importFenDialog,
                icon: const Icon(Icons.input),
              ),
            ],
          ),
        ),

        // Moves display (fixed height to avoid pushing)
        Container(
          width: double.infinity,
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          color: Colors.grey.shade100,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              moves.isEmpty ? 'No moves yet' : moves.join('  '),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    );
  }
}
