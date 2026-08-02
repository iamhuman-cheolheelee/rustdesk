// [Custom] 소프트 키보드(IME) 입력 → 원격 전송 액션 변환 로직.
//
// 원격은 IME 를 대신 돌려주지 않는다. 우리가 보낸 문자가 그대로 찍힐 뿐이다.
// 그래서 클라이언트가 "원격 화면에 지금 무엇이 찍혀 있는지"(_sent) 를 들고,
// TextField 의 현재 텍스트와 매 변화마다 대조해 그 차이만 보낸다.
//
// 기존 remote_page.dart 의 처리는 문자열의 "길이 변화" 만 보고 증가분을
// 전송했기 때문에, 조합형 문자(한글/일본어)처럼 같은 위치의 글자가 계속
// 치환되는 IME 에서 입력이 통째로 누락됐다.
//   예) "ㅇ" -> "아" -> "안" 은 모두 길이 1 이라 아무것도 전송되지 않고,
//       이어지는 "안ㄴ" 에서 'ㄴ' 만 전송되어 원격에는 "ㅇㄴ" 이 찍힌다.
//
// 여기서는 조합 중인 글자도 즉시 전송한다. 조합이 진행되며 글자가 바뀌면
// 공통 prefix 까지 백스페이스로 되감고 새 글자를 보낸다("아" -> 백스페이스
// 1회 -> "안"). 덕분에 원격 화면이 손 안의 화면을 실시간으로 따라오고,
// 마지막 글자가 확정될 때까지 안 보이는 문제가 없다.
//
// 조합 구간(composing)을 일부러 보지 않는다. 조합을 기다렸다 보내면 항상 한
// 음절씩 늦게 찍히고, IME 가 이미 확정한 앞 글자까지 다시 조합 구간으로
// 되돌리는 동작(reconversion, 삼성 키보드의 예측·자동수정)에 로직이 말려든다.
// "화면에 보이는 텍스트" 하나만 기준으로 삼으면 두 문제가 같이 사라진다.

/// 원격으로 보낼 단위 동작.
abstract class SoftKeyAction {
  const SoftKeyAction();
}

/// 백스페이스 [count] 회.
class BackspaceAction extends SoftKeyAction {
  final int count;
  const BackspaceAction(this.count);

  @override
  bool operator ==(Object other) =>
      other is BackspaceAction && other.count == count;
  @override
  int get hashCode => count.hashCode;
  @override
  String toString() => 'Backspace($count)';
}

/// 문자열 [text] 를 seq 로 전송(sessionInputString).
class InsertTextAction extends SoftKeyAction {
  final String text;
  const InsertTextAction(this.text);

  @override
  bool operator ==(Object other) =>
      other is InsertTextAction && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'InsertText(${_q(text)})';
}

/// 단일 키 이벤트로 전송(VK_RETURN / VK_SPACE / 단일 ASCII 문자).
/// modifier(ctrl/alt/shift) 조합과 게임·터미널 호환을 위해 단일 문자는
/// seq 가 아니라 키 이벤트로 보낸다.
class KeyAction extends SoftKeyAction {
  final String char;
  const KeyAction(this.char);

  @override
  bool operator ==(Object other) => other is KeyAction && other.char == char;
  @override
  int get hashCode => char.hashCode;
  @override
  String toString() => 'Key(${_q(char)})';
}

String _q(String s) => "'${s.replaceAll('\n', '\\n')}'";

/// TextField 의 변화를 원격 입력 액션으로 변환한다.
///
/// [sent] 는 "원격 화면에 찍혀 있다고 간주하는 텍스트". TextField 는
/// 백스페이스 감지를 위해 앞에 더미 텍스트(initText)를 채워두므로,
/// 생성 시 그 초기 문자열을 그대로 넘긴다.
class SoftKeyboardInputTracker {
  String _sent;
  String? _sentinelChar;

  SoftKeyboardInputTracker(String initialValue) : _sent = initialValue {
    _sentinelChar = initialValue.isEmpty ? null : initialValue[0];
  }

  String get sentValue => _sent;

  /// TextField 가 [initialValue] 로 리셋됐을 때 상태를 맞춘다.
  void reset(String initialValue) {
    _sent = initialValue;
    _sentinelChar = initialValue.isEmpty ? null : initialValue[0];
  }

  /// [newValue] 는 TextField 의 현재 전체 텍스트.
  List<SoftKeyAction> onChanged(String newValue) {
    if (newValue == _sent) return const [];

    // 클립보드 붙여넣기 등으로 더미 prefix 까지 통째로 치환된 경우.
    // 공통 prefix diff 를 그대로 적용하면 더미 길이(1024)만큼 백스페이스가
    // 나가므로, 삭제 없이 삽입만 한다. (기존 동작과 동일)
    final sentinel = _sentinelChar;
    if (sentinel != null &&
        _sent.startsWith(sentinel) &&
        !newValue.startsWith(sentinel)) {
      _sent = newValue;
      return newValue.isEmpty ? const [] : _insertActions(newValue);
    }

    final common = _commonPrefixLength(_sent, newValue);
    final actions = <SoftKeyAction>[];

    final removed = _sent.substring(common);
    if (removed.isNotEmpty) {
      actions.add(BackspaceAction(removed.runes.length));
    }

    final inserted = newValue.substring(common);
    if (inserted.isNotEmpty) {
      actions.addAll(_insertActions(inserted));
    }

    _sent = newValue;
    return actions;
  }

  /// 삽입 텍스트를 액션으로 쪼갠다. 개행은 seq 로 보내면 원격 앱에 따라
  /// 무시될 수 있어 VK_RETURN 키 이벤트로 분리한다.
  static List<SoftKeyAction> _insertActions(String text) {
    final actions = <SoftKeyAction>[];
    final segments = text.split('\n');
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) actions.add(const KeyAction('VK_RETURN'));
      final seg = segments[i];
      if (seg.isEmpty) continue;
      if (seg.runes.length == 1 && seg.runes.first < 128) {
        actions.add(KeyAction(seg == ' ' ? 'VK_SPACE' : seg));
      } else {
        actions.add(InsertTextAction(seg));
      }
    }
    return actions;
  }

  /// 서로게이트 페어가 쪼개지지 않도록 rune 경계에서만 공통 prefix 를 센다.
  static int _commonPrefixLength(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var i = 0;
    var safe = 0;
    while (i < max && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
      final unit = a.codeUnitAt(i - 1);
      final isHighSurrogate = unit >= 0xD800 && unit <= 0xDBFF;
      if (!isHighSurrogate) safe = i;
    }
    return safe;
  }
}
