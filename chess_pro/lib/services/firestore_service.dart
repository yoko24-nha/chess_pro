import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final String roomsColl = 'rooms';

  Future<String> createRoom(
    String initialFen,
    String creatorName, {
    int? timePerPlayer,
  }) async {
    final Map<String, dynamic> payload = {
      'fen': initialFen,
      'createdAt': FieldValue.serverTimestamp(),
      'players': FieldValue.arrayUnion([creatorName]),
      'creatorName': creatorName,
      'whitePlayer': creatorName, // Người tạo phòng cầm quân trắng ván đầu
      'blackPlayer': null,
      'gameNumber': 1,
      'rematchRequests': <String>[],
      'rematchAccepted': false,
    };

    if (timePerPlayer != null && timePerPlayer > 0) {
      payload.addAll({
        'timePerPlayer': timePerPlayer,
        'whiteRemaining': timePerPlayer,
        'blackRemaining': timePerPlayer,
        'turn': 'white',
        'timeoutWinner': null,
      });
    }

    final docRef = await _db.collection(roomsColl).add(payload);
    return docRef.id;
  }

  Future<void> updateRoomFen(String roomId, String fen) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'fen': fen,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> addPlayerToRoom(String roomId, String playerName) async {
    final docRef = _db.collection(roomsColl).doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      
      // Nếu chưa có blackPlayer, set người join làm blackPlayer
      final blackPlayer = data['blackPlayer'] as String?;
      final updates = <String, dynamic>{
        'players': FieldValue.arrayUnion([playerName]),
        'updatedAt': FieldValue.serverTimestamp(),
      };
      
      if (blackPlayer == null) {
        updates['blackPlayer'] = playerName;
      }
      
      tx.update(docRef, updates);
    });
  }

  Future<void> removePlayerFromRoom(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'players': FieldValue.arrayRemove([playerName]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> surrender(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'surrenderedBy': playerName,
      'endedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

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

  Future<void> updateRoomOnMove(
    String roomId,
    String fen, {
    required int whiteRemaining,
    required int blackRemaining,
    required String nextTurn,
  }) async {
    final docRef = _db.collection(roomsColl).doc(roomId);

    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;

      final data = snap.data()!;
      final playersList = (data['players'] is List)
          ? (data['players'] as List)
          : [];
      final playersCount = playersList.length;

      if (playersCount < 2) {
        tx.update(docRef, {
          'fen': fen,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }

      final int timePerPlayer = (data['timePerPlayer'] is int)
          ? data['timePerPlayer'] as int
          : (whiteRemaining > 0 ? whiteRemaining : 0);
      final int serverWhite = (data['whiteRemaining'] is int)
          ? data['whiteRemaining'] as int
          : whiteRemaining;
      final int serverBlack = (data['blackRemaining'] is int)
          ? data['blackRemaining'] as int
          : blackRemaining;
      final String currentTurn = (data['turn'] as String?) ?? 'white';

      int elapsed = 0;
      if (data['lastUpdate'] is Timestamp) {
        final last = (data['lastUpdate'] as Timestamp).toDate().toUtc();
        elapsed = DateTime.now().toUtc().difference(last).inSeconds;
        if (elapsed < 0) elapsed = 0;
      } else {
        elapsed = 0;
      }

      int newWhite = serverWhite;
      int newBlack = serverBlack;
      if (currentTurn == 'white') {
        newWhite = (serverWhite - elapsed).clamp(0, timePerPlayer);
      } else {
        newBlack = (serverBlack - elapsed).clamp(0, timePerPlayer);
      }

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

      tx.update(docRef, {
        'fen': fen,
        'whiteRemaining': newWhite,
        'blackRemaining': newBlack,
        'turn': nextTurn,
        'lastUpdate': FieldValue.serverTimestamp(),
      });
    });
  }

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

  // --- DRAW FEATURE ---
  Future<void> offerDraw(String roomId, String playerName) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'drawOffer': playerName,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> respondDraw(String roomId, bool accept) async {
    final docRef = _db.collection(roomsColl).doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      if (accept) {
        tx.update(docRef, {
          'drawOffer': null,
          'gameOver': true,
          'result': 'draw',
          'endedAt': FieldValue.serverTimestamp(),
        });
      } else {
        if (data['drawOffer'] != null) {
          tx.update(docRef, {'drawOffer': null});
        }
      }
    });
  }

  /// Gửi tin nhắn trong room
  Future<void> sendMessage(String roomId, String sender, String text) async {
    await _db.collection('rooms').doc(roomId).collection('messages').add({
      'sender': sender,
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Lắng nghe tin nhắn realtime
  Stream<QuerySnapshot<Map<String, dynamic>>> listenMessages(String roomId) {
    return _db
        .collection('rooms')
        .doc(roomId)
        .collection('messages')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
    // Reset bàn cờ sau khi cả hai đồng ý hòa
  Future<void> requestResetAfterDraw(String roomId) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'resetRequested': true,
    }, SetOptions(merge: true));
  }

  Future<void> clearResetSignal(String roomId) async {
    await _db.collection(roomsColl).doc(roomId).set({
      'resetRequested': false,
    }, SetOptions(merge: true));
  }
  // Clear result/drawOffer/winner/resetRequested to stop repeated notifications
  Future<void> clearGameResult(String roomId) async {
    await _db.collection(roomsColl).doc(roomId).update({
      'result': FieldValue.delete(),
      'drawOffer': FieldValue.delete(),
      'winner': FieldValue.delete(),
      'resetRequested': FieldValue.delete(),
    });
  }

  Future<void> saveUserTheme(String userId, String theme) async {
  await FirebaseFirestore.instance
      .collection('users')
      .doc(userId)
      .set({'theme': theme}, SetOptions(merge: true));
}

  Stream<String?> listenUserTheme(String userId) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .snapshots()
        .map((snap) => snap.data()?['theme'] as String?);
  }

  // --- REMATCH FEATURE ---
  Future<void> requestRematch(String roomId, String playerName) async {
    final docRef = _db.collection(roomsColl).doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      final requests = (data['rematchRequests'] as List?)?.cast<String>() ?? [];
      if (!requests.contains(playerName)) {
        tx.update(docRef, {
          'rematchRequests': FieldValue.arrayUnion([playerName]),
        });
      }
    });
  }

  Future<void> acceptRematch(String roomId) async {
    final docRef = _db.collection(roomsColl).doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(docRef);
      if (!snap.exists) return;
      final data = snap.data()!;
      
      final gameNumber = (data['gameNumber'] as int?) ?? 1;
      final creatorName = data['creatorName'] as String?;
      final currentWhitePlayer = data['whitePlayer'] as String?;
      final currentBlackPlayer = data['blackPlayer'] as String?;
      
      // Đổi quân: ván mới (gameNumber + 1)
      // Ván 1: creator = white, other = black
      // Ván 2: creator = black, other = white (đổi quân)
      // Ván 3: creator = white, other = black (đổi lại)
      // Logic: ván lẻ (1, 3, 5...) -> creator cầm trắng
      //        ván chẵn (2, 4, 6...) -> creator cầm đen
      final newGameNumber = gameNumber + 1;
      final newWhitePlayer = (newGameNumber % 2 == 1) ? creatorName : currentBlackPlayer;
      final newBlackPlayer = (newGameNumber % 2 == 1) ? currentBlackPlayer : creatorName;
      
      // Reset bàn cờ
      final initialFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      
      final updateData = <String, dynamic>{
        'gameNumber': newGameNumber,
        'whitePlayer': newWhitePlayer,
        'blackPlayer': newBlackPlayer,
        'rematchRequests': <String>[],
        'rematchAccepted': true,
        'fen': initialFen,
        'result': FieldValue.delete(),
        'drawOffer': FieldValue.delete(),
        'surrenderedBy': FieldValue.delete(),
        'timeoutWinner': FieldValue.delete(),
        'turn': 'white',
        'lastUpdate': FieldValue.serverTimestamp(),
      };
      
      if (data['timePerPlayer'] != null) {
        updateData['whiteRemaining'] = data['timePerPlayer'];
        updateData['blackRemaining'] = data['timePerPlayer'];
      }
      
      tx.update(docRef, updateData);
    });
  }

}
