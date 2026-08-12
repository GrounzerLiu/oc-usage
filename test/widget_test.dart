import 'package:flutter_test/flutter_test.dart';
import 'package:oc_usage/models.dart';
import 'package:oc_usage/theme.dart';

void main() {
  test('fmtTokens 中文单位', () {
    expect(fmtTokens(56789012), '5678.90万');
    expect(fmtTokens(235000000), '2.35亿');
    expect(fmtTokens(890), '890');
  });

  test('UsageWindow resetText', () {
    final w = UsageWindow(label: '滚动', usagePercent: 12.5, resetInSec: 2 * 3600 + 600);
    expect(w.resetText(), '2 小时 10 分钟');
    expect(w.remainingPercent, 87.5);
  });

  test('GoData summaryLines 不含余额', () {
    final go = GoData(
      subscribed: true,
      rolling: UsageWindow(label: '滚动', usagePercent: 10, resetInSec: 3600),
      balance: 1.23,
    );
    final lines = go.summaryLines();
    expect(lines.any((l) => l.contains('余额')), isFalse);
    expect(lines.length, 1);
  });
}
