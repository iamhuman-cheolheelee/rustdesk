// IME 조합 입력 로직 검증. flutter_test 없이 실행 가능:
//   cd flutter && dart run test/soft_keyboard_input_check.dart
import '../lib/mobile/pages/soft_keyboard_input.dart';

int failures = 0;

void check(String name, List<SoftKeyAction> got, List<SoftKeyAction> want) {
  final ok = got.length == want.length &&
      List.generate(got.length, (i) => got[i] == want[i]).every((e) => e);
  if (!ok) {
    failures++;
    print('FAIL  $name\n      got : $got\n      want: $want');
  } else {
    print('ok    $name  -> $got');
  }
}

void expectSent(String name, SoftKeyboardInputTracker t, String want) {
  if (t.sentValue != want) {
    failures++;
    print('FAIL  $name  sent=${t.sentValue}  want=$want');
  } else {
    print('ok    $name  -> $want');
  }
}

/// 값 시퀀스를 순서대로 흘려보내고 최종 상태를 확인한다.
void drive(String name, List<String> values, String want) {
  final t = SoftKeyboardInputTracker(init);
  for (final v in values) {
    t.onChanged(v);
  }
  expectSent(name, t, want);
}

const init = '111';

void main() {
  // 1. 한글 "안녕" — 조합 중인 글자도 즉시 반영되고, 바뀌면 되감아 교정한다
  {
    final t = SoftKeyboardInputTracker(init);
    check('ko ㅇ', t.onChanged('111ㅇ'), [InsertTextAction('ㅇ')]);
    check('ko 아', t.onChanged('111아'),
        [BackspaceAction(1), InsertTextAction('아')]);
    check('ko 안', t.onChanged('111안'),
        [BackspaceAction(1), InsertTextAction('안')]);
    check('ko 안ㄴ', t.onChanged('111안ㄴ'), [InsertTextAction('ㄴ')]);
    check('ko 안녀', t.onChanged('111안녀'),
        [BackspaceAction(1), InsertTextAction('녀')]);
    check('ko 안녕', t.onChanged('111안녕'),
        [BackspaceAction(1), InsertTextAction('녕')]);
    expectSent('ko 최종', t, '111안녕');
  }

  // 2. 조합 중 백스페이스 ("각" -> "가") 도 원격에 그대로 반영
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111가');
    t.onChanged('111각');
    check('ko 조합중 backspace', t.onChanged('111가'),
        [BackspaceAction(1), InsertTextAction('가')]);
    check('ko 조합 취소', t.onChanged('111'), [BackspaceAction(1)]);
  }

  // 3. 확정된 한글 삭제
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111안');
    check('ko 확정 후 삭제', t.onChanged('111'), [BackspaceAction(1)]);
  }

  // 4. 영문은 되감기 없이 바로바로
  {
    final t = SoftKeyboardInputTracker(init);
    check('en h', t.onChanged('111h'), [KeyAction('h')]);
    check('en i', t.onChanged('111hi'), [KeyAction('i')]);
    check('en space', t.onChanged('111hi '), [KeyAction('VK_SPACE')]);
    expectSent('en 최종', t, '111hi ');
  }

  // 5. 영문 예측 변환 치환 — 공통 prefix diff 로 교정
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111helo');
    check('en 자동교정', t.onChanged('111hello'),
        [BackspaceAction(1), InsertTextAction('lo')]);
  }

  // 6. 개행
  {
    final t = SoftKeyboardInputTracker(init);
    check('newline', t.onChanged('111a\nb'),
        [KeyAction('a'), KeyAction('VK_RETURN'), KeyAction('b')]);
  }

  // 7. 붙여넣기 (멀티바이트 여러 글자)
  {
    final t = SoftKeyboardInputTracker(init);
    check('paste ko', t.onChanged('111안녕하세요'), [InsertTextAction('안녕하세요')]);
  }

  // 8. 이모지 (서로게이트 페어) — 백스페이스 1회로 계산
  {
    final t = SoftKeyboardInputTracker(init);
    check('emoji 입력', t.onChanged('111😀'), [InsertTextAction('😀')]);
    check('emoji 삭제', t.onChanged('111'), [BackspaceAction(1)]);
  }

  // 9. 일본어 조합 (かんじ -> 漢字 변환)
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111か');
    t.onChanged('111かん');
    t.onChanged('111かんじ');
    check('ja 변환확정', t.onChanged('111漢字'),
        [BackspaceAction(3), InsertTextAction('漢字')]);
  }

  // 10. 변화 없음
  {
    final t = SoftKeyboardInputTracker(init);
    check('no-op', t.onChanged('111'), []);
  }

  // 11. reconversion — IME 가 확정한 앞 글자를 다시 조합 구간으로 되돌려도
  //     화면 텍스트가 그대로면 아무것도 전송하지 않는다 (조합 구간을 안 보므로)
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111안');
    check('reconv 무변화', t.onChanged('111안'), []);
    check('reconv 다음글자', t.onChanged('111안ㄴ'), [InsertTextAction('ㄴ')]);
    expectSent('reconv 최종', t, '111안ㄴ');
  }

  // 12. 마지막 글자가 확정을 기다리지 않고 즉시 나간다 (지연 없음)
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111ㅎ');
    t.onChanged('111하');
    check('마지막 글자 즉시', t.onChanged('111한'),
        [BackspaceAction(1), InsertTextAction('한')]);
    expectSent('마지막 글자 반영됨', t, '111한');
  }

  // 13. 클립보드 붙여넣기로 더미 prefix 까지 통째로 치환 — 백스페이스 폭주 금지
  {
    final t = SoftKeyboardInputTracker('1' * 1024);
    check('클립보드 전체치환', t.onChanged('pasted 텍스트'),
        [InsertTextAction('pasted 텍스트')]);
  }

  // 14. 중국어 병음 (ni -> 你)
  {
    final t = SoftKeyboardInputTracker(init);
    check('zh n', t.onChanged('111n'), [KeyAction('n')]);
    check('zh ni', t.onChanged('111ni'), [KeyAction('i')]);
    check('zh 한자 확정', t.onChanged('111你'),
        [BackspaceAction(2), InsertTextAction('你')]);
  }

  // 15. 커서를 중간으로 옮겨 삽입
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111abc');
    check('중간 삽입', t.onChanged('111a한bc'),
        [BackspaceAction(2), InsertTextAction('한bc')]);
    expectSent('중간 삽입 최종', t, '111a한bc');
  }

  // --- 전체 문장 주행: 최종 결과가 화면과 일치해야 한다 ---

  drive('주행: 안녕하세요', [
    '111ㅇ', '111아', '111안',
    '111안ㄴ', '111안녀', '111안녕',
    '111안녕ㅎ', '111안녕하',
    '111안녕하ㅅ', '111안녕하세',
    '111안녕하세ㅇ', '111안녕하세요',
  ], '111안녕하세요');

  drive('주행: 한영 반복 전환', [
    '111ㄱ', '111가',
    '111가A',
    '111가Aㄴ', '111가A나',
    '111가A나Z',
  ], '111가A나Z');

  drive('주행: 한글 지우고 다시 쓰기', [
    '111ㅅ', '111사', '111산',
    '111사', '111삼',
    '111삼ㅅ', '111삼시', '111삼십',
  ], '111삼십');

  drive('주행: 영문 단어 + 공백 + 한글', [
    '111h', '111hi', '111hi ',
    '111hi ㄱ', '111hi 가', '111hi 감',
  ], '111hi 감');

  print(failures == 0 ? '\nALL PASS' : '\n$failures FAILED');
}
