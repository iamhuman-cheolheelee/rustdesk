// [Custom] 소프트 키보드(IME) 입력 → 원격 전송 액션 변환 로직.
//
// 기존 remote_page.dart 의 처리는 TextField 문자열의 "길이 변화" 만 보고
// 증가분을 전송했기 때문에, 조합형 문자(한글/일본어/중국어)처럼 같은 위치의
// 글자가 계속 치환되는 IME 에서 입력이 누락되거나 자모가 분리되어 전달됐다.
//   예) "ㅇ" -> "아" -> "안" 은 모두 길이 1 이라 아무것도 전송되지 않고,
//       이어지는 "안ㄴ" 에서 'ㄴ' 만 전송되어 원격에는 "ㅇㄴ" 이 찍힌다.
//
// 여기서는 IME 의 composing(조합 중) 구간을 1급 정보로 사용한다.
//   - 조합 중인 텍스트가 non-ASCII 면 확정될 때까지 전송을 보류한다.
//   - ASCII 조합(영문 단어 예측 등)은 지연 없이 즉시 반영하고,
//     예측 변환으로 앞부분이 치환되면 공통 prefix diff 로 백스페이스 교정한다.
// 두 경우 모두 "원격에 실제로 보낸 문자열"(_sent) 과 목표 문자열의 공통 prefix 를
// 비교하는 단일 경로로 처리되므로, 삽입/삭제/치환이 모두 일관되게 동작한다.

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
  String toString() => 'InsertText(${jsonish(text)})';
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
  String toString() => 'Key(${jsonish(char)})';
}

String jsonish(String s) => "'${s.replaceAll('\n', '\\n')}'";

/// TextField 의 변화를 원격 입력 액션으로 변환한다.
///
/// [sent] 는 "원격에 이미 반영됐다고 간주하는 텍스트". TextField 는
/// 백스페이스 감지를 위해 앞에 더미 텍스트(initText)를 채워두므로,
/// 생성 시 그 초기 문자열을 그대로 넘긴다.
class SoftKeyboardInputTracker {
  String _sent;
  String? _sentinelChar;
  String? _lastRaw;

  SoftKeyboardInputTracker(String initialValue) : _sent = initialValue {
    _sentinelChar = initialValue.isEmpty ? null : initialValue[0];
  }

  String get sentValue => _sent;

  /// 아직 조합 중이라 전송하지 않은 텍스트가 있는지.
  bool get hasPending => _lastRaw != null && _lastRaw != _sent;

  /// TextField 가 [initialValue] 로 리셋됐을 때 상태를 맞춘다.
  void reset(String initialValue) {
    _sent = initialValue;
    _lastRaw = null;
    _sentinelChar = initialValue.isEmpty ? null : initialValue[0];
  }

  /// 조합이 확정되지 않은 채 키보드가 닫히거나 포커스를 잃을 때 호출한다.
  /// 보류 중이던 조합 문자를 그대로 확정해 전송한다. (없으면 빈 목록)
  List<SoftKeyAction> flush() {
    final raw = _lastRaw;
    if (raw == null) return const [];
    return onChanged(raw);
  }

  /// [newValue] 는 TextField 전체 텍스트, [composingStart]/[composingEnd] 는
  /// IME 조합 구간(UTF-16 인덱스). 조합 중이 아니면 둘 다 -1.
  List<SoftKeyAction> onChanged(
    String newValue, {
    int composingStart = -1,
    int composingEnd = -1,
  }) {
    _lastRaw = newValue;
    final target = _resolveTarget(newValue, composingStart, composingEnd);
    if (target == _sent) return const [];

    // 클립보드 붙여넣기 등으로 더미 prefix 까지 통째로 치환된 경우.
    // 공통 prefix diff 를 그대로 적용하면 더미 길이(1024)만큼 백스페이스가
    // 나가므로, 삭제 없이 삽입만 한다. (기존 동작과 동일)
    final sentinel = _sentinelChar;
    if (sentinel != null &&
        _sent.startsWith(sentinel) &&
        !target.startsWith(sentinel)) {
      _sent = target;
      return target.isEmpty ? const [] : _insertActions(target);
    }

    final common = _commonPrefixLength(_sent, target);
    final actions = <SoftKeyAction>[];

    final removed = _sent.substring(common);
    if (removed.isNotEmpty) {
      actions.add(BackspaceAction(removed.runes.length));
    }

    final inserted = target.substring(common);
    if (inserted.isNotEmpty) {
      actions.addAll(_insertActions(inserted));
    }

    _sent = target;
    return actions;
  }

  /// 조합 중인 구간을 전송 대상에 포함할지 결정한다.
  String _resolveTarget(String value, int start, int end) {
    final composingValid =
        start >= 0 && end >= start && end <= value.length && start != end;
    if (!composingValid) return value;

    final composingText = value.substring(start, end);
    final isMultiByte = composingText.runes.any((r) => r > 127);
    // 한글 등 조합형은 확정 전까지 글자가 계속 치환되므로 보류한다.
    // 뒤쪽(조합 구간 이후) 텍스트는 커서가 조합 구간에 있는 한 존재하지 않는다.
    return isMultiByte ? value.substring(0, start) : value;
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
