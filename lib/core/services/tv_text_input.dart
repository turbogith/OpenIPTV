import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// How a TV text field was closed: Back, the keyboard's action key, the
/// D-pad leaving the field once the keyboard is gone, or focus taken away.
enum TvTextInputClose { back, action, up, down, blur }

/// Typing on a TV through a native Android text box (native
/// `TvTextInput.kt`). Google TV's keyboard ignores the remote while a Flutter
/// text field owns the input, so the remote fell through to the app and
/// closed the keyboard on its first move (flutter/flutter#125541). The
/// native box is invisible; what's typed is mirrored into [controller], so
/// the Flutter field on screen shows it.
///
/// One field at a time: opening another closes the previous one.
class TvTextInput {
  TvTextInput._();

  static const _channel = MethodChannel('openiptv/tv_input');
  static _Session? _session;
  static bool _listening = false;

  static bool get isOpen => _session != null;

  /// True while the native keyboard is up. Google TV's keyboard floats over
  /// the app without reporting any insets, so [TvKeyboardInset] uses this to
  /// make room for it.
  static final ValueNotifier<bool> showing = ValueNotifier(false);

  static void _setSession(_Session? s) {
    _session = s;
    showing.value = s != null;
  }

  static Future<void> open({
    required TextEditingController controller,
    TextInputType? keyboardType,
    bool obscureText = false,
    bool enableSuggestions = true,
    TextInputAction? textInputAction,
    int? maxLength,
    ValueChanged<String>? onChanged,
    VoidCallback? onAction,
    void Function(TvTextInputClose how)? onClosed,
  }) async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    // iOS : le clavier Flutter standard fonctionne (pas de bug Gboard TV).
    // On laisse le TextField natif Flutter gérer la saisie.
    if (Platform.isIOS) return;
    final previous = _session;
    _setSession(_Session(controller, onChanged, onAction, onClosed));
    previous?.onClosed?.call(TvTextInputClose.blur);
    try {
      await _channel.invokeMethod('open', {
      'text': controller.text,
      'type': _type(keyboardType),
      'obscure': obscureText,
      'suggestions': enableSuggestions && !obscureText,
      'action': _action(textInputAction),
        'maxLength': maxLength,
      });
    } on MissingPluginException {
      // Pas de côté natif (tests, iOS sans le fichier Swift) : repli
      // sur le clavier Flutter standard.
      _setSession(null);
    } on PlatformException {
      _setSession(null);
    }
  }

  /// Closes the keyboard without reporting it to the field (it asked).
  static Future<void> close() async {
    if (_session == null) return;
    _setSession(null);
    if (Platform.isIOS) return;
    try {
      await _channel.invokeMethod('close');
    } on MissingPluginException {
    } on PlatformException {
    }
  }

  static Future<void> _handle(MethodCall call) async {
    final session = _session;
    if (session == null) return;
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    switch (call.method) {
      case 'changed':
        final text = args['text'] as String? ?? '';
        session.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        session.onChanged?.call(text);
      case 'action':
        session.onAction?.call();
      case 'closed':
        _setSession(null);
        final how = TvTextInputClose.values.asNameMap()[args['reason']] ??
            TvTextInputClose.blur;
        session.onClosed?.call(how);
    }
  }

  static String _type(TextInputType? type) {
    if (type == TextInputType.number || type == TextInputType.phone) {
      return 'number';
    }
    if (type == TextInputType.url) return 'url';
    if (type == TextInputType.emailAddress) return 'email';
    return 'text';
  }

  static String _action(TextInputAction? action) => switch (action) {
        TextInputAction.search => 'search',
        TextInputAction.next => 'next',
        TextInputAction.go => 'go',
        _ => 'done',
      };
}

class _Session {
  _Session(this.controller, this.onChanged, this.onAction, this.onClosed);

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onAction;
  final void Function(TvTextInputClose how)? onClosed;
}

/// Reserves the bottom of the screen for the TV keyboard while it's open,
/// as a bottom view inset — dialogs and scaffolds then move their content
/// above it, as they would for a phone keyboard — and draws a full-width
/// tray behind it. Google TV's Gboard is narrower than the screen, so
/// without the tray the page was cut off in a hard line on both sides of
/// the keyboard. The tray is Gboard's own panel colour and height, so the
/// two read as one keyboard; it slides in with the inset.
class TvKeyboardInset extends StatelessWidget {
  const TvKeyboardInset({super.key, required this.child});

  final Widget child;

  /// Gboard's letter keyboard (with its suggestion strip) on a 1080p TV:
  /// its top edge is 600 px from the top. The number pad is a little
  /// shorter and sits inside the tray.
  static const keyboardFraction = 0.445;

  /// Gboard's panel colour on Google TV.
  static const trayColor = Color(0xFF191D23);

  static const _slide = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: TvTextInput.showing,
        builder: (context, showing, child) => TweenAnimationBuilder<double>(
          tween: Tween(end: showing ? 1 : 0),
          duration: _slide,
          curve: Curves.easeOutCubic,
          child: child,
          builder: (context, t, child) {
            if (t == 0) return child!;
            final mq = MediaQuery.of(context);
            final tray = mq.size.height * keyboardFraction * t;
            return Stack(
              fit: StackFit.expand,
              children: [
                MediaQuery(
                  data: mq.copyWith(
                    viewInsets: mq.viewInsets.copyWith(
                        bottom: tray > mq.viewInsets.bottom
                            ? tray
                            : mq.viewInsets.bottom),
                  ),
                  child: child!,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: tray,
                  child: const IgnorePointer(child: _KeyboardTray()),
                ),
              ],
            );
          },
        ),
        child: child,
      );
}

class _KeyboardTray extends StatelessWidget {
  const _KeyboardTray();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          color: TvKeyboardInset.trayColor,
          border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
          boxShadow: [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 32,
              offset: Offset(0, -6),
            ),
          ],
        ),
      );
}
