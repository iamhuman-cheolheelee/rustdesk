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

const init = '111';

void main() {
  // 1. 한글 "안녕" — 삼성/Gboard 조합 시퀀스
  {
    final t = SoftKeyboardInputTracker(init);
    check('ko ㅇ', t.onChanged('111ㅇ', composingStart: 3, composingEnd: 4), []);
    check('ko 아', t.onChanged('111아', composingStart: 3, composingEnd: 4), []);
    check('ko 안', t.onChanged('111안', composingStart: 3, composingEnd: 4), []);
    check('ko 안ㄴ', t.onChanged('111안ㄴ', composingStart: 4, composingEnd: 5),
        [InsertTextAction('안')]);
    check('ko 안녀', t.onChanged('111안녀', composingStart: 4, composingEnd: 5), []);
    check('ko 안녕', t.onChanged('111안녕', composingStart: 4, composingEnd: 5), []);
    check('ko 확정', t.onChanged('111안녕'), [InsertTextAction('녕')]);
    check('ko 최종상태', [], []);
    if (t.sentValue != '111안녕') {
      failures++;
      print('FAIL  ko sentValue = ${t.sentValue}');
    }
  }

  // 2. 한글 조합 중 백스페이스 ("각" -> "가") 는 전송되지 않아야
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111가', composingStart: 3, composingEnd: 4);
    t.onChanged('111각', composingStart: 3, composingEnd: 4);
    check('ko 조합중 backspace',
        t.onChanged('111가', composingStart: 3, composingEnd: 4), []);
    check('ko 조합 취소', t.onChanged('111', composingStart: -1, composingEnd: -1),
        []);
  }

  // 3. 확정된 한글을 지우면 백스페이스 1회
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111안ㄴ', composingStart: 4, composingEnd: 5);
    check('ko 확정 후 삭제', t.onChanged('111'), [BackspaceAction(1)]);
  }

  // 4. 영문은 조합 중이라도 지연 없이 즉시 전송
  {
    final t = SoftKeyboardInputTracker(init);
    check('en h', t.onChanged('111h', composingStart: 3, composingEnd: 4),
        [KeyAction('h')]);
    check('en i', t.onChanged('111hi', composingStart: 3, composingEnd: 5),
        [KeyAction('i')]);
    check('en space', t.onChanged('111hi '), [KeyAction('VK_SPACE')]);
  }

  // 5. 영문 예측 변환 치환 — 공통 prefix diff 로 교정
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111helo', composingStart: 3, composingEnd: 7);
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
    check('ja 조합', t.onChanged('111かんじ', composingStart: 3, composingEnd: 6),
        []);
    check('ja 변환확정', t.onChanged('111漢字'), [InsertTextAction('漢字')]);
  }

  // 10. 변화 없음
  {
    final t = SoftKeyboardInputTracker(init);
    check('no-op', t.onChanged('111'), []);
  }

  // 11. 한 -> 영 전환: 조합 중이던 한글이 확정되고 영문이 이어짐
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111한', composingStart: 3, composingEnd: 4);
    // 한/영 키 -> IME 가 조합 확정 (composing 해제)
    check('한→영 확정', t.onChanged('111한'), [InsertTextAction('한')]);
    check('한→영 a', t.onChanged('111한a', composingStart: 4, composingEnd: 5),
        [KeyAction('a')]);
    check('한→영 b', t.onChanged('111한ab', composingStart: 4, composingEnd: 6),
        [KeyAction('b')]);
  }

  // 12. 영 -> 한 전환: 이미 전송된 영문은 그대로, 한글은 조합 후 확정
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111ab', composingStart: 3, composingEnd: 5);
    check('영→한 조합시작',
        t.onChanged('111ab하', composingStart: 5, composingEnd: 6), []);
    check('영→한 조합중', t.onChanged('111ab한', composingStart: 5, composingEnd: 6),
        []);
    check('영→한 확정', t.onChanged('111ab한'), [InsertTextAction('한')]);
  }

  // 13. 한/영 반복 전환 — 최종 문자열이 정확해야
  {
    final t = SoftKeyboardInputTracker(init);
    final steps = [
      ['111ㄱ', 3, 4], ['111가', 3, 4], ['111가', -1, -1], // 한
      ['111가A', 4, 5], ['111가A', -1, -1], // 영
      ['111가Aㄴ', 5, 6], ['111가A나', 5, 6], ['111가A나', -1, -1], // 한
      ['111가A나Z', 6, 7], ['111가A나Z', -1, -1], // 영
    ];
    for (final s in steps) {
      t.onChanged(s[0] as String,
          composingStart: s[1] as int, composingEnd: s[2] as int);
    }
    if (t.sentValue != '111가A나Z') {
      failures++;
      print('FAIL  한영 반복전환 최종값 = ${t.sentValue} (want 111가A나Z)');
    } else {
      print('ok    한영 반복전환 최종값 -> ${t.sentValue}');
    }
  }

  // 14. flush — 조합 미확정 상태로 키보드가 닫혀도 누락되지 않아야
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111안ㄴ', composingStart: 4, composingEnd: 5);
    t.onChanged('111안녕', composingStart: 4, composingEnd: 5);
    if (!t.hasPending) {
      failures++;
      print('FAIL  hasPending 이 false');
    }
    check('flush 미확정 조합', t.flush(), [InsertTextAction('녕')]);
    check('flush 재호출 무해', t.flush(), []);
  }

  // 15. 클립보드 붙여넣기로 더미 prefix 까지 통째로 치환 — 백스페이스 폭주 금지
  {
    final t = SoftKeyboardInputTracker('1' * 1024);
    check('클립보드 전체치환', t.onChanged('pasted 텍스트'),
        [InsertTextAction('pasted 텍스트')]);
  }

  // 16. 중국어 병음(ASCII 조합 -> 한자 확정) — 자동 교정으로 최종 결과 정확
  {
    final t = SoftKeyboardInputTracker(init);
    check('zh 병음 n', t.onChanged('111n', composingStart: 3, composingEnd: 4),
        [KeyAction('n')]);
    check('zh 병음 ni', t.onChanged('111ni', composingStart: 3, composingEnd: 5),
        [KeyAction('i')]);
    check('zh 한자 확정', t.onChanged('111你'),
        [BackspaceAction(2), InsertTextAction('你')]);
  }

  // 17. 커서를 중간으로 옮겨 조합 (조합 구간 뒤에 텍스트가 남는 경우)
  {
    final t = SoftKeyboardInputTracker(init);
    t.onChanged('111abc');
    check('중간 조합', t.onChanged('111a한bc', composingStart: 4, composingEnd: 5),
        [BackspaceAction(2)]);
    check('중간 조합 확정', t.onChanged('111a한bc'),
        [InsertTextAction('한bc')]);
  }

  print(failures == 0 ? '\nALL PASS' : '\n$failures FAILED');
}
