import 'dart:async';
import 'dart:math';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

// ================== 数据模型 ==================

enum HealthLevel { normal, warning, critical, offline }

extension HealthLevelX on HealthLevel {
  String get label {
    switch (this) {
      case HealthLevel.normal: return '正常';
      case HealthLevel.warning: return '注意';
      case HealthLevel.critical: return '严重';
      case HealthLevel.offline: return '离线';
    }
  }

  Color get color {
    switch (this) {
      case HealthLevel.normal: return const Color(0xFF35C46B);
      case HealthLevel.warning: return const Color(0xFFF0B429);
      case HealthLevel.critical: return const Color(0xFFE5484D);
      case HealthLevel.offline: return const Color(0xFF6B7683);
    }
  }

  int get weight {
    switch (this) {
      case HealthLevel.normal: return 100;
      case HealthLevel.warning: return 72;
      case HealthLevel.critical: return 35;
      case HealthLevel.offline: return 0;
    }
  }
}

final BoxDecoration kCardDecoration = BoxDecoration(
  color: const Color(0xFF141F2B),
  borderRadius: BorderRadius.circular(14),
  border: Border.all(color: const Color(0xFF1E2C3B)),
);

String _p(int v) => v.toString().padLeft(2, '0');
String fmtTime(DateTime t) => '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';
String fmtDateTime(DateTime t) => '${_p(t.month)}-${_p(t.day)} ${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}';

class Metric {
  final String name;
  final String unit;
  double? value;
  final double? min;
  final double? max;
  final String? textValue;
  final bool isText;

  Metric({
    required this.name, this.unit = '', this.value, this.min, this.max, this.textValue, this.isText = false,
  });

  bool get abnormal {
    if (isText || value == null) return false;
    if (min != null && value! < min!) return true;
    if (max != null && value! > max!) return true;
    return false;
  }

  String get display {
    if (isText) return textValue ?? '--';
    if (value == null) return '--';
    final v = value!;
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  String get rangeText {
    if (isText) return '状态量';
    if (min == null || max == null) return '—';
    return '${min!.toStringAsFixed(0)} ~ ${max!.toStringAsFixed(0)} $unit';
  }
}

class SubUnit {
  final String name;
  final String state;
  final HealthLevel level;
  const SubUnit({required this.name, required this.state, required this.level});
}

class DomainHealth {
  final String key;
  final String name;
  final String subtitle;
  HealthLevel level;
  double load;
  final List<Metric> metrics;
  final List<SubUnit> subunits;

  DomainHealth({
    required this.key, required this.name, required this.subtitle, required this.level, required this.load, required this.metrics, required this.subunits,
  });

  int get abnormalCount => metrics.where((m) => m.abnormal).length;
}

class FaultEvent {
  final String id;
  final String code;
  final String domainKey;
  final String title;
  final String affected;
  final String detail;
  final DateTime time;
  final HealthLevel severity;
  bool resolved;
  DateTime? resolvedAt;

  FaultEvent({
    required this.id, required this.code, required this.domainKey, required this.title, required this.affected, required this.detail, required this.time, required this.severity, this.resolved = false, this.resolvedAt,
  });
}

// ================== 知识库 ==================

class AdviceRule {
  final String code;
  final String title;
  final List<String> possibleCauses;
  final List<String> actions;
  final List<String> cautions;

  const AdviceRule({required this.code, required this.title, required this.possibleCauses, required this.actions, this.cautions = const []});
}

class KnowledgeBase {
  KnowledgeBase._();
  static const Map<String, AdviceRule> rules = {
    'AUX-OC-01': AdviceRule(
      code: 'AUX-OC-01', title: '辅助变流器输出过流',
      possibleCauses: ['负载侧短路或接地', '辅助变流器功率模块异常', '输出电流传感器漂移'],
      actions: ['确认当前车速；若为 0 km/h，可尝试复位辅助控制单元', '复位无效时隔离该辅助模块，维持其余辅助系统运行', '前方站停车后检查负载侧绝缘与接线'],
      cautions: ['隔离后将失去部分辅助供电，注意确认蓄电池充电状态'],
    ),
    'NET-CRC-02': AdviceRule(
      code: 'NET-CRC-02', title: 'MVB 总线负载 / 误码率升高',
      possibleCauses: ['总线终端电阻异常', '某从设备通信频繁重发', 'MVB 线缆屏蔽接地不良'],
      actions: ['检查 TCMS 网关是否出现间歇性掉线', '若冗余通道正常，可维持运行并记录故障码', '回段后使用 MVB 分析仪定位异常节点'],
    ),
    'BRK-SLOW-03': AdviceRule(
      code: 'BRK-SLOW-03', title: '制动施加响应缓慢',
      possibleCauses: ['制动缸 EP 阀响应迟滞', '制动缸压力传感器偏差', 'BCU 控制周期异常'],
      actions: ['立即确认制动缸压力实际建立情况', '若响应时间持续超过 1.5 s，按行车规程采取限速措施', '停车后对 BCU 执行自检，检查 EP 阀动作'],
      cautions: ['本告警影响制动性能，须按行车安全规程处置'],
    ),
  };
  static AdviceRule? lookup(String code) => rules[code];
}

// ================== 数据服务 ==================

class TelemetryService extends ChangeNotifier {
  TelemetryService._internal() { _initDomains(); }
  static final TelemetryService instance = TelemetryService._internal();

  String locoNo = 'HXD1 0027';
  String trainNo = 'K1178';
  String workMode = '牵引运行';
  double speed = 78;
  DateTime lastUpdate = DateTime.now();
  bool connected = true;

  final List<DomainHealth> domains = [];
  final List<FaultEvent> faults = [];

  Timer? _timer;
  int _tick = 0;
  final Random _rand = Random(20261116);
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _onTick());
  }

  void stop() { _timer?.cancel(); _started = false; }

  Future<void> refresh() async {
    await Future.delayed(const Duration(milliseconds: 500));
    _onTick();
  }

  @visibleForTesting
  void tickOnce() => _onTick();

  @visibleForTesting
  void resetForTest() {
    _tick = 0; speed = 78; lastUpdate = DateTime.now(); faults.clear();
    _initDomains(); notifyListeners();
  }

  double get healthScore {
    if (domains.isEmpty) return 0;
    final sum = domains.map((d) => d.level.weight).reduce((a, b) => a + b);
    return sum / domains.length;
  }

  DomainHealth? domainOf(String key) {
    for (final d in domains) { if (d.key == key) return d; }
    return null;
  }

  List<FaultEvent> get activeFaults => faults.where((f) => !f.resolved).toList(growable: false);

  void _initDomains() {
    domains
      ..clear()
      ..add(DomainHealth(key: 'traction', name: '牵引控制', subtitle: '主变流器 / 牵引电机', level: HealthLevel.normal, load: 0.78, metrics: [
        Metric(name: '牵引电机电流', unit: 'A', value: 412, min: 0, max: 620),
        Metric(name: '主变流器冷却液温度', unit: '℃', value: 61, min: 0, max: 85),
        Metric(name: '直流母线电压', unit: 'V', value: 1650, min: 1400, max: 1900),
        Metric(name: '牵引接触器 KM1', isText: true, textValue: '闭合'),
      ], subunits: const [
        SubUnit(name: '四象限整流器', state: '运行', level: HealthLevel.normal),
        SubUnit(name: '牵引逆变器 M1', state: '运行', level: HealthLevel.normal),
        SubUnit(name: '牵引逆变器 M2', state: '运行', level: HealthLevel.normal),
      ]))
      ..add(DomainHealth(key: 'brake', name: '制动控制', subtitle: 'BCU / 制动缸 / 均衡风缸', level: HealthLevel.normal, load: 0.35, metrics: [
        Metric(name: '列车管压力', unit: 'kPa', value: 560, min: 480, max: 600),
        Metric(name: '制动缸压力', unit: 'kPa', value: 0, min: 0, max: 420),
        Metric(name: '均衡风缸压力', unit: 'kPa', value: 555, min: 480, max: 600),
        Metric(name: '制动施加响应时间', unit: 's', value: 0.8, min: 0, max: 1.2),
      ], subunits: const [
        SubUnit(name: 'BCU 制动控制单元', state: '就绪', level: HealthLevel.normal),
        SubUnit(name: '制动缸 EP 阀', state: '就绪', level: HealthLevel.normal),
        SubUnit(name: '速度传感器', state: '就绪', level: HealthLevel.normal),
      ]))
      ..add(DomainHealth(key: 'aux', name: '辅助系统', subtitle: '辅助变流器 / 充电机 / 蓄电池', level: HealthLevel.normal, load: 0.62, metrics: [
        Metric(name: '辅助变流器输出电流', unit: 'A', value: 268, min: 0, max: 450),
        Metric(name: '辅助变流器输出电压', unit: 'V', value: 398, min: 370, max: 420),
        Metric(name: '辅助模块温度', unit: '℃', value: 54, min: 0, max: 80),
        Metric(name: '蓄电池电压', unit: 'V', value: 110, min: 100, max: 130),
      ], subunits: const [
        SubUnit(name: '辅助变流器 AUX-1', state: '运行', level: HealthLevel.normal),
        SubUnit(name: '辅助变流器 AUX-2', state: '运行', level: HealthLevel.normal),
        SubUnit(name: '充电机', state: '运行', level: HealthLevel.normal),
      ]))
      ..add(DomainHealth(key: 'network', name: '网络通信', subtitle: 'MVB / TCMS 网关', level: HealthLevel.normal, load: 0.55, metrics: [
        Metric(name: 'MVB 总线负载', unit: '%', value: 42, min: 0, max: 70),
        Metric(name: '网关心跳周期', unit: 'ms', value: 18, min: 0, max: 100),
        Metric(name: '丢帧计数', unit: '帧/h', value: 3, min: 0, max: 50),
        Metric(name: '网络冗余状态', isText: true, textValue: '双网正常'),
      ], subunits: const [
        SubUnit(name: 'TCMS 网关', state: '运行', level: HealthLevel.normal),
        SubUnit(name: 'MVB 主通道', state: '正常', level: HealthLevel.normal),
        SubUnit(name: 'MVB 备通道', state: '正常', level: HealthLevel.normal),
      ]))
      ..add(DomainHealth(key: 'power', name: '电源回路', subtitle: 'DC110V / 主断路器', level: HealthLevel.normal, load: 0.48, metrics: [
        Metric(name: '控制电源电压', unit: 'V', value: 110, min: 100, max: 130),
        Metric(name: 'DC110V 绝缘电阻', unit: 'MΩ', value: 22, min: 1, max: 100),
        Metric(name: '控制柜内部温度', unit: '℃', value: 36, min: 0, max: 55),
        Metric(name: '主断路器 QF1', isText: true, textValue: '闭合'),
      ], subunits: const [
        SubUnit(name: '控制电源模块', state: '运行', level: HealthLevel.normal),
        SubUnit(name: '主断路器 QF1', state: '闭合', level: HealthLevel.normal),
        SubUnit(name: '蓄电池组', state: '正常', level: HealthLevel.normal),
      ]));
  }

  void _onTick() {
    _tick++;
    speed = (speed + _rand.nextDouble() * 6 - 3).clamp(0.0, 120.0).toDouble();
    for (final d in domains) {
      for (final m in d.metrics) {
        if (m.isText || m.value == null || m.abnormal) continue;
        final base = m.value!;
        final lo = m.min ?? base * 0.8;
        final hi = m.max ?? base * 1.2;
        final span = hi - lo;
        if (span <= 0) continue;
        final delta = (_rand.nextDouble() - 0.5) * span * 0.02;
        m.value = (base + delta).clamp(lo + span * 0.05, hi - span * 0.05).toDouble();
      }
    }
    _simulateScenario();
    lastUpdate = DateTime.now();
    notifyListeners();
  }

  void _simulateScenario() {
    switch (_tick) {
      case 6:
        _raiseFault(domainKey: 'aux', code: 'AUX-OC-01', title: '辅助变流器 2 输出过流', affected: '辅助系统 / 辅助变流器 AUX-2', detail: 'AUX-2 输出电流持续高于额定值，已进入限流运行状态。', severity: HealthLevel.warning);
        _setMetric('aux', '辅助变流器输出电流', 505);
        break;
      case 18:
        _clearFault('AUX-OC-01');
        _setMetric('aux', '辅助变流器输出电流', 268);
        break;
      case 28:
        _raiseFault(domainKey: 'network', code: 'NET-CRC-02', title: 'MVB 总线负载升高', affected: '网络通信 / MVB 主通道', detail: 'MVB 主通道负载超过 70%，出现间歇性重发。', severity: HealthLevel.warning);
        _setMetric('network', 'MVB 总线负载', 82);
        break;
      case 45:
        _clearFault('NET-CRC-02');
        _setMetric('network', 'MVB 总线负载', 42);
        break;
      case 60:
        _raiseFault(domainKey: 'brake', code: 'BRK-SLOW-03', title: '制动施加响应缓慢', affected: '制动控制 / 制动缸 EP 阀', detail: '制动施加响应时间 2.4 s，超出标准上限 1.2 s。', severity: HealthLevel.critical);
        _setMetric('brake', '制动施加响应时间', 2.4);
        break;
    }
  }

  void _setMetric(String domainKey, String name, double value) {
    final d = domainOf(domainKey);
    if (d == null) return;
    for (final m in d.metrics) { if (m.name == name) m.value = value; }
  }

  void _raiseFault({required String domainKey, required String code, required String title, required String affected, required String detail, required HealthLevel severity}) {
    final d = domainOf(domainKey);
    if (d == null) return;
    d.level = severity;
    faults.insert(0, FaultEvent(id: 'F${DateTime.now().millisecondsSinceEpoch}', code: code, domainKey: domainKey, title: title, affected: affected, detail: detail, time: DateTime.now(), severity: severity, resolved: false));
  }

  void _clearFault(String code) {
    for (final f in faults) {
      if (f.code == code && !f.resolved) { f.resolved = true; f.resolvedAt = DateTime.now(); }
    }
    final target = faults.firstWhere((f) => f.code == code, orElse: () => faults.first);
    final d = domainOf(target.domainKey);
    if (d != null) d.level = HealthLevel.normal;
  }
}

// ================== 组件 ==================

class LevelBadge extends StatelessWidget {
  final HealthLevel level;
  final String? text;
  const LevelBadge({super.key, required this.level, this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: level.color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: level.color.withOpacity(0.6)),
      ),
      child: Text(text ?? level.label, style: TextStyle(color: level.color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class PetalChart extends StatelessWidget {
  final List<DomainHealth> domains;
  final String centerTitle;
  final String centerValue;
  final Color centerColor;

  const PetalChart({super.key, required this.domains, required this.centerTitle, required this.centerValue, required this.centerColor});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(constraints.maxWidth, 280.0);
        return Center(
          child: SizedBox(
            width: side, height: side,
            child: CustomPaint(painter: _PetalPainter(domains: domains, centerTitle: centerTitle, centerValue: centerValue, centerColor: centerColor)),
          ),
        );
      },
    );
  }
}

class _PetalPainter extends CustomPainter {
  final List<DomainHealth> domains;
  final String centerTitle;
  final String centerValue;
  final Color centerColor;

  _PetalPainter({required this.domains, required this.centerTitle, required this.centerValue, required this.centerColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide / 2;
    canvas.drawCircle(center, r * 0.96, Paint()..color = const Color(0xFF101B27));
    canvas.drawCircle(center, r * 0.96, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFF22303F));
    final n = domains.length;
    if (n == 0) return;
    final d = r * 0.36;
    final a = r * 0.34;
    final b = r * 0.20;
    for (var i = 0; i < n; i++) {
      final theta = i * 2 * math.pi / n;
      final domain = domains[i];
      final color = domain.level.color;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(theta);
      final rect = Rect.fromCenter(center: const Offset(0, 0) - Offset(0, d), width: b * 2, height: a * 2);
      canvas.drawOval(rect.inflate(4), Paint()..color = color.withOpacity(0.20)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      canvas.drawOval(rect, Paint()..color = const Color(0xFF16222F));
      canvas.save();
      canvas.clipPath(Path()..addOval(rect));
      final fillHeight = rect.height * domain.load.clamp(0.0, 1.0).toDouble();
      canvas.drawRect(Rect.fromLTRB(rect.left, rect.bottom - fillHeight, rect.right, rect.bottom), Paint()..color = color.withOpacity(0.34));
      canvas.restore();
      canvas.drawOval(rect, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = color.withOpacity(0.9));
      canvas.restore();
      final labelCenter = Offset(center.dx + math.sin(theta) * (d + a + 16), center.dy - math.cos(theta) * (d + a + 16));
      _paintText(canvas, domain.name, labelCenter, color, 12, FontWeight.w600);
    }
    canvas.drawCircle(center, r * 0.24, Paint()..color = const Color(0xFF0B141D));
    canvas.drawCircle(center, r * 0.24, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = centerColor.withOpacity(0.85));
    _paintText(canvas, centerValue, center.translate(0, -9), centerColor, 22, FontWeight.w700);
    _paintText(canvas, centerTitle, center.translate(0, 16), const Color(0xFF8FA3B8), 11, FontWeight.w500);
  }

  void _paintText(Canvas canvas, String text, Offset center, Color color, double size, FontWeight weight) {
    final tp = TextPainter(text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size, fontWeight: weight)), textDirection: TextDirection.ltr, textAlign: TextAlign.center)..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _PetalPainter old) => true;
}

class MetricBar extends StatelessWidget {
  final Metric metric;
  const MetricBar({super.key, required this.metric});

  @override
  Widget build(BuildContext context) {
    final m = metric;
    final valueColor = m.abnormal ? const Color(0xFFE5484D) : const Color(0xFFE6EDF3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(m.name, style: const TextStyle(color: Color(0xFFB7C4D3), fontSize: 13))),
              Text(m.isText ? m.display : '${m.display} ${m.unit}', style: TextStyle(color: valueColor, fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
          if (!m.isText && m.min != null && m.max != null && m.value != null) ...[
            const SizedBox(height: 6),
            _bar(m),
            const SizedBox(height: 4),
            Text('正常范围 ${m.rangeText}', style: const TextStyle(color: Color(0xFF5E7186), fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _bar(Metric m) {
    final min = m.min!;
    final max = m.max!;
    final range = (max - min) == 0 ? 1.0 : (max - min);
    final pos = ((m.value! - min) / range).clamp(0.0, 1.0).toDouble();
    final color = m.abnormal ? const Color(0xFFE5484D) : const Color(0xFF35C46B);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        return SizedBox(
          height: 10,
          child: Stack(
            children: [
              Positioned.fill(child: Container(decoration: BoxDecoration(color: const Color(0xFF1B2836), borderRadius: BorderRadius.circular(5)))),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                left: (pos * w - 4).clamp(0.0, w - 8).toDouble(),
                top: 0,
                child: Container(width: 8, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================== 页面 ==================

class HomeScreen extends StatelessWidget {
  final VoidCallback onOpenFaultLog;
  const HomeScreen({super.key, required this.onOpenFaultLog});

  @override
  Widget build(BuildContext context) {
    final service = TelemetryService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        return RefreshIndicator(
          onRefresh: service.refresh,
          color: const Color(0xFF35C46B),
          backgroundColor: const Color(0xFF141F2B),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
            children: [
              _Header(service: service),
              const SizedBox(height: 14),
              _ChartCard(service: service),
              const SizedBox(height: 16),
              const _SectionTitle(title: '分系统状态', trailing: '点击查看分层诊断'),
              const SizedBox(height: 8),
              ...service.domains.map((d) => _DomainTile(domain: d)),
              const SizedBox(height: 16),
              _SectionTitle(title: '当前告警', trailing: service.activeFaults.isEmpty ? '无' : '${service.activeFaults.length} 条未恢复'),
              const SizedBox(height: 8),
              _AlertPanel(service: service, onTap: onOpenFaultLog),
            ],
          ),
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String trailing;
  const _SectionTitle({required this.title, required this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const Spacer(),
        Text(trailing, style: const TextStyle(fontSize: 11, color: Color(0xFF5E7186))),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final TelemetryService service;
  const _Header({required this.service});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('机车 ${service.locoNo}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${service.trainNo} · ${service.workMode} · ${service.speed.toStringAsFixed(0)} km/h', style: const TextStyle(color: Color(0xFF8FA3B8), fontSize: 13)),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: service.connected ? const Color(0xFF35C46B) : const Color(0xFFE5484D), shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(service.connected ? '已连接' : '离线', style: const TextStyle(fontSize: 12, color: Color(0xFF8FA3B8))),
              ],
            ),
            const SizedBox(height: 4),
            Text(fmtTime(service.lastUpdate), style: const TextStyle(fontSize: 11, color: Color(0xFF5E7186))),
          ],
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  final TelemetryService service;
  const _ChartCard({required this.service});

  @override
  Widget build(BuildContext context) {
    final score = service.healthScore;
    final color = score >= 90 ? const Color(0xFF35C46B) : score >= 70 ? const Color(0xFFF0B429) : const Color(0xFFE5484D);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: kCardDecoration,
      child: Column(
        children: [
          PetalChart(domains: service.domains, centerTitle: '综合健康度', centerValue: score.toStringAsFixed(0), centerColor: color),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: HealthLevel.values.take(3).map((l) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text(l.label, style: const TextStyle(fontSize: 11, color: Color(0xFF8FA3B8))),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _DomainTile extends StatelessWidget {
  final DomainHealth domain;
  const _DomainTile({required this.domain});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => DiagnosisScreen(domainKey: domain.key)));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: kCardDecoration,
          child: Row(
            children: [
              Container(width: 4, height: 34, decoration: BoxDecoration(color: domain.level.color, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(domain.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(domain.subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF5E7186))),
                  ],
                ),
              ),
              if (domain.abnormalCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('${domain.abnormalCount} 项越限', style: const TextStyle(fontSize: 11, color: Color(0xFFE5484D))),
                ),
              LevelBadge(level: domain.level),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 18, color: Color(0xFF5E7186)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertPanel extends StatelessWidget {
  final TelemetryService service;
  final VoidCallback onTap;
  const _AlertPanel({required this.service, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = service.activeFaults;
    if (active.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: kCardDecoration,
        child: Row(
          children: [
            const Icon(Icons.verified_outlined, color: Color(0xFF35C46B), size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('控制柜各分系统运行正常，暂无活动告警。', style: TextStyle(fontSize: 13, color: Color(0xFFB7C4D3)))),
            TextButton(onPressed: onTap, child: const Text('历史记录')),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: kCardDecoration,
        padding: const EdgeInsets.all(14),
        child: Column(
          children: active.take(3).map((f) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 4), child: LevelBadge(level: f.severity, text: f.severity.label)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(f.title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('${f.code} · ${f.affected}', style: const TextStyle(fontSize: 11, color: Color(0xFF5E7186))),
                        const SizedBox(height: 2),
                        Text(fmtDateTime(f.time), style: const TextStyle(fontSize: 11, color: Color(0xFF5E7186))),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 18, color: Color(0xFF5E7186)),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class DiagnosisScreen extends StatelessWidget {
  final String domainKey;
  const DiagnosisScreen({super.key, required this.domainKey});

  @override
  Widget build(BuildContext context) {
    final service = TelemetryService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final domain = service.domainOf(domainKey);
        if (domain == null) return Scaffold(appBar: AppBar(title: const Text('诊断')), body: const Center(child: Text('未找到该分系统')));
        final relatedFaults = service.faults.where((f) => f.domainKey == domainKey && !f.resolved).toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: Text(domain.name),
            actions: [Padding(padding: const EdgeInsets.only(right: 14), child: Center(child: LevelBadge(level: domain.level)))],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              _Summary(domain: domain),
              const SizedBox(height: 16),
              const _Title('故障描述'),
              if (relatedFaults.isEmpty) _emptyLine('该分系统当前无活动故障') else ...relatedFaults.map((f) => _FaultCard(fault: f)),
              const SizedBox(height: 16),
              const _Title('关键参数实时值'),
              Container(
                decoration: kCardDecoration,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Column(children: domain.metrics.map((m) => MetricBar(metric: m)).toList()),
              ),
              const SizedBox(height: 16),
              const _Title('关联子单元'),
              Container(
                decoration: kCardDecoration,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Column(
                  children: domain.subunits.map((s) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(color: s.level.color, shape: BoxShape.circle)),
