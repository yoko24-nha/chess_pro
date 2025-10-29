// lib/services/firestore_service.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Create a new room with initial FEN and creator name.
  /// The room document will contain:
  /// { fen: <initialFen>, createdAt: <ts>, players: [creatorName] }
  Future<String> createRoom(String initialFen, String creatorName) async {
    final docRef = await _db.collection('rooms').add({
      'fen': initialFen,
      'createdAt': FieldValue.serverTimestamp(),
      'players': FieldValue.arrayUnion([creatorName]),
    });
    return docRef.id;
  }

  /// Update fen of a room (merge)
  Future<void> updateRoomFen(String roomId, String fen) async {
    await _db.collection('rooms').doc(roomId).set({
      'fen': fen,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Add player's name into room.players array (no duplicates thanks to arrayUnion)
  Future<void> addPlayerToRoom(String roomId, String playerName) async {
    await _db.collection('rooms').doc(roomId).set({
      'players': FieldValue.arrayUnion([playerName]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Remove a player name from room.players (optional helper)
  Future<void> removePlayerFromRoom(String roomId, String playerName) async {
    await _db.collection('rooms').doc(roomId).set({
      'players': FieldValue.arrayRemove([playerName]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Mark the room as surrendered by a player.
  Future<void> surrender(String roomId, String playerName) async {
    await _db.collection('rooms').doc(roomId).set({
      'surrenderedBy': playerName,
      'winner': FieldValue.arrayRemove([
        playerName,
      ]), // hoặc xác định người thắng tùy logic
      'endedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Listen to full room document. Callback receives the document data map (or null if not exists).
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> listenRoom(
    String roomId,
    void Function(Map<String, dynamic>? data) onRoomChanged,
  ) {
    final sub = _db.collection('rooms').doc(roomId).snapshots().listen((
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
}
