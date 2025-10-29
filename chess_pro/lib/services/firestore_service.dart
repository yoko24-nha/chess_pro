// lib/services/firestore_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String roomsColl = 'rooms';

  /// Create a new room with optional timePerPlayer (seconds).
  // createRoom: không set lastUpdate ở creation
  Future<String> createRoom(
    String initialFen,
    String creatorName, {
    int? timePerPlayer,
  }) async {
    final Map<String, dynamic> payload = {
      'fen': initialFen,
      'createdAt': FieldValue.serverTimestamp(),
      'players': FieldValue.arrayUnion([creatorName]),
    };

    if (timePerPlayer != null && timePerPlayer > 0) {
      payload.addAll({
        'timePerPlayer': timePerPlayer,
        'whiteRemaining': timePerPlayer,
        'blackRemaining': timePerPlayer,
        'turn': 'white', // trắng đi trước
        // NO lastUpdate here — đồng hồ chưa bắt đầu
        'timeoutWinner': null,
      });
    }

    final docRef = await _db.collection(roomsColl).add(payload);
    return docRef.id;
  }

  /// Update fen of a room (merge)
  Future<void> updateRoomFen(String roomId, String fen) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'fen': fen,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Add player's name into room.players array (no duplicates thanks to arrayUnion)
  Future<void> addPlayerToRoom(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'players': FieldValue.arrayUnion([playerName]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Remove a player name from room.players (optional helper)
  Future<void> removePlayerFromRoom(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'players': FieldValue.arrayRemove([playerName]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Mark the room as surrendered by a player.
  Future<void> surrender(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'surrenderedBy': playerName,
      'endedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Listen to full room document. Callback receives the document data map (or null if not exists).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> listenRoom(
    String roomId,
    void Function(Map<String, dynamic>? data) onRoomChanged,
  ) {
    final sub = _db.collection(roomsColl).doc(roomId).snapshots().listen((
      snapshot,
    ) {
      if (snapshot.exists) {
        onRoomChanged(snapshot.data());
      } else {
        onRoomChanged(null);
      }
    });
    return sub;
  }

  // ---------------- New: transaction cập nhật khi có nước đi ----------------
  // updateRoomOnMove: transaction kiểm tra số player, chỉ bắt clock nếu đã có >=2 players
Future<void> updateRoomOnMove(
  String roomId,
  String fen, {
  required int whiteRemaining,
  required int blackRemaining,
  required String nextTurn, // 'white' or 'black'
}) async {
  final docRef = _db.collection(roomsColl).doc(roomId);

  await _db.runTransaction((tx) async {
    final snap = await tx.get(docRef);
    if (!snap.exists) return;

    final data = snap.data()!;
    final playersList = (data['players'] is List) ? (data['players'] as List) : [];
    final playersCount = playersList.length;

    // Nếu chưa đủ 2 người thì chỉ update FEN thôi (không động chạm clock)
    if (playersCount < 2) {
      tx.update(docRef, {
        'fen': fen,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return;
    }

    final int timePerPlayer = (data['timePerPlayer'] is int) ? data['timePerPlayer'] as int : (whiteRemaining > 0 ? whiteRemaining : 0);
    final int serverWhite = (data['whiteRemaining'] is int) ? data['whiteRemaining'] as int : whiteRemaining;
    final int serverBlack = (data['blackRemaining'] is int) ? data['blackRemaining'] as int : blackRemaining;
    final String currentTurn = (data['turn'] as String?) ?? 'white';

    int elapsed = 0;
    if (data['lastUpdate'] is Timestamp) {
      final last = (data['lastUpdate'] as Timestamp).toDate().toUtc();
      elapsed = DateTime.now().toUtc().difference(last).inSeconds;
      if (elapsed < 0) elapsed = 0;
    } else {
      // first move after both players present: elapsed = 0
      elapsed = 0;
    }

    int newWhite = serverWhite;
    int newBlack = serverBlack;
    if (currentTurn == 'white') {
      newWhite = (serverWhite - elapsed).clamp(0, timePerPlayer);
    } else {
      newBlack = (serverBlack - elapsed).clamp(0, timePerPlayer);
    }

    // Nếu timeout xảy ra -> set timeoutWinner (idempotent)
    if ((newWhite <= 0 || newBlack <= 0) && (data['timeoutWinner'] == null)) {
      final winner = newWhite <= 0 ? 'black' : 'white';
      tx.update(docRef, {
        'timeoutWinner': winner,
        'whiteRemaining': newWhite,
        'blackRemaining': newBlack,
        'lastUpdate': FieldValue.serverTimestamp(),
      });
      return;
    }

    // Không timeout: ghi fen, remaining, đổi turn và set lastUpdate (bắt đầu/tiếp tục clock)
    tx.update(docRef, {
      'fen': fen,
      'whiteRemaining': newWhite,
      'blackRemaining': newBlack,
      'turn': nextTurn,
      'lastUpdate': FieldValue.serverTimestamp(),
    });
  });
}


  /// Claim timeout (idempotent). If already has timeoutWinner, không làm gì.
  Future<void> claimTimeout(String roomId, String winner) async {
    final docRef = _db.collection(roomsColl).doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      if (data['timeoutWinner'] != null) return;
      tx.update(docRef, {
        'timeoutWinner': winner,
        'lastUpdate': FieldValue.serverTimestamp(),
      });
    });
  }
}
