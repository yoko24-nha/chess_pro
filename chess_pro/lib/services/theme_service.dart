// lib/services/theme_service.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

class ThemeService {
  static const String _themeKey = 'chess_board_theme';
  static BoardColor _defaultTheme = BoardColor.brown;

  // Lấy theme hiện tại từ SharedPreferences
  static Future<BoardColor> getTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final themeName = prefs.getString(_themeKey);
      if (themeName != null) {
        return _parseBoardColor(themeName);
      }
    } catch (e) {
      debugPrint('[ThemeService] Error loading theme: $e');
    }
    return _defaultTheme;
  }

  // Lưu theme vào SharedPreferences
  static Future<void> setTheme(BoardColor theme) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeKey, _boardColorToString(theme));
    } catch (e) {
      debugPrint('[ThemeService] Error saving theme: $e');
    }
  }

  // Chuyển BoardColor thành String
  static String _boardColorToString(BoardColor color) {
    switch (color) {
      case BoardColor.brown:
        return 'brown';
      case BoardColor.darkBrown:
        return 'darkBrown';
      case BoardColor.orange:
        return 'orange';
      case BoardColor.green:
        return 'green';
      default:
        return 'brown';
    }
  }

  // Parse String thành BoardColor
  static BoardColor _parseBoardColor(String name) {
    switch (name) {
      case 'brown':
        return BoardColor.brown;
      case 'darkBrown':
        return BoardColor.darkBrown;
      case 'orange':
        return BoardColor.orange;
      case 'green':
        return BoardColor.green;
      default:
        return BoardColor.brown;
    }
  }

  // Lấy danh sách tất cả themes có sẵn
  static List<Map<String, dynamic>> getAvailableThemes() {
    return [
      {
        'color': BoardColor.brown,
        'name': 'Nâu cổ điển',
        'description': 'Classic Brown',
      },
      {
        'color': BoardColor.darkBrown,
        'name': 'Nâu đậm',
        'description': 'Dark Brown',
      },
      {
        'color': BoardColor.orange,
        'name': 'Cam',
        'description': 'Orange',
      },
      {
        'color': BoardColor.green,
        'name': 'Xanh lá',
        'description': 'Green',
      },
    ];
  }
}

