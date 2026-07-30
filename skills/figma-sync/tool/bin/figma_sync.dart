// Figma Snapshot Sync — role map 기반 Figma 실측값 스냅샷 + Dart 상수 생성기.
// (dolomoodProto tools/figma_extractor 에서 이식 — 경로만 renew 단일 앱 구조로 변경)
//
// 입력:
//   .claude/skills/figma-sync/tool/config/figma-snapshot-{slug}.json  (role map)
//   환경변수 FIGMA_TOKEN, FIGMA_FILE_KEY  (.env 파일)
//
// 출력:
//   docs/figma-snapshots/{slug}.json                   (SSOT, git-tracked)
//   lib/design_system/generated/{slug}_tokens.dart     (Dart 상수)
//
// 사용법:
//   cd .claude/skills/figma-sync/tool
//   dart run bin/figma_sync.dart --slug mvp-intro
//   dart run bin/figma_sync.dart --slug mvp-intro --dry-run   # snapshot diff만 출력
//
// 설계 원칙:
//   1. Figma 가 SSOT — snapshot 은 기계 SSOT, 위젯 코드는 generated 상수 참조
//   2. `git diff docs/figma-snapshots/{slug}.json` 로 Figma 변경사항 리뷰
//   3. fetchedAt 타임스탬프 + fileKey 로 재현성 보장
//   4. **fail-closed (INV-1, INV-2)** — root/element 한 개라도 미해석이면
//      snapshot 미작성 + exit 2. 빈 `screens` config 도 거부.
//      home-theme-progression 캐스케이드 (2026-05-15) 의 직접 원인이었음.
//
// Exit codes:
//   0  성공
//   2  unresolved Figma node (INV-1 위반) — snapshot 미작성
//   64 usage
//   65 .env 누락
//   66 Figma API HTTP error
//   67 config 결함 (빈 screens, screen 에 elements 없음 등)
//   70 generated dart format 실패 (해시 기준 확보 불가 — 생성 실패 취급)

import 'dart:convert';
import 'dart:io';

const _baseUrl = 'https://api.figma.com/v1';

Future<void> main(List<String> args) async {
  final slug = _arg(args, '--slug');
  if (slug == null) {
    stderr.writeln(
      'usage: dart run bin/figma_sync.dart --slug <slug> [--dry-run]',
    );
    exit(64);
  }
  final dryRun = args.contains('--dry-run');
  final regenDartOnly = args.contains('--regen-dart-only');

  final repoRootForRegen = _findRepoRoot();
  if (regenDartOnly) {
    final snapshotPath = '$repoRootForRegen/docs/figma-snapshots/$slug.json';
    final snapshot =
        jsonDecode(File(snapshotPath).readAsStringSync())
            as Map<String, dynamic>;
    final dartPath =
        '$repoRootForRegen/lib/design_system/generated/${slug.replaceAll('-', '_')}_tokens.dart';
    File(dartPath).writeAsStringSync(_generateDart(slug, snapshot));
    _writeIntegrity(repoRootForRegen, slug, dartPath);
    stderr.writeln('✅ regen dart only → $dartPath');
    exit(0);
  }

  final env = _loadDotEnv();
  final token = env['FIGMA_TOKEN'] ?? Platform.environment['FIGMA_TOKEN'];
  final fileKey =
      env['FIGMA_FILE_KEY'] ?? Platform.environment['FIGMA_FILE_KEY'];
  if (token == null || fileKey == null) {
    stderr.writeln('FIGMA_TOKEN / FIGMA_FILE_KEY 필요 (.env 또는 환경변수)');
    exit(65);
  }

  final repoRoot = _findRepoRoot();
  final configPath =
      '$repoRoot/.claude/skills/figma-sync/tool/config/figma-snapshot-$slug.json';
  final configFile = File(configPath);
  if (!configFile.existsSync()) {
    stderr.writeln('❌ config 누락: $configPath');
    exit(67);
  }
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final screensRaw = config['screens'];
  if (screensRaw is! Map || screensRaw.isEmpty) {
    stderr.writeln(
      '❌ config $configPath: `screens` 가 비어 있거나 Map 이 아님 — '
      'INV-2 위반 (빈 screens snapshot 금지)',
    );
    exit(67);
  }
  final screens = screensRaw.cast<String, dynamic>();
  for (final entry in screens.entries) {
    final cfg = entry.value;
    if (cfg is! Map ||
        cfg['rootNodeId'] is! String ||
        (cfg['rootNodeId'] as String).isEmpty) {
      stderr.writeln('❌ config screen ${entry.key}: rootNodeId 누락/빈 문자열');
      exit(67);
    }
    final elements = cfg['elements'];
    if (elements is! Map || elements.isEmpty) {
      stderr.writeln(
        '❌ config screen ${entry.key}: elements 비어 있음 — '
        'role map 에 최소 1개 노드 정의 필요',
      );
      exit(67);
    }
  }

  // 1. 모든 nodeId 수집
  final allIds = <String>{};
  for (final screen in screens.values) {
    allIds.add(screen['rootNodeId'] as String);
    final elements = (screen['elements'] as Map).cast<String, String>();
    allIds.addAll(elements.values);
  }
  stderr.writeln('→ ${allIds.length}개 노드 fetch 중... ($fileKey)');

  // 2. 단일 요청으로 일괄 fetch (Figma API 는 ids 쉼표 구분 지원)
  final uri = Uri.parse(
    '$_baseUrl/files/$fileKey/nodes?ids=${allIds.join(',')}',
  );
  final req = await HttpClient().getUrl(uri);
  req.headers.set('X-Figma-Token', token);
  final res = await req.close();
  if (res.statusCode != 200) {
    stderr.writeln(
      'Figma API ${res.statusCode}: ${await res.transform(utf8.decoder).join()}',
    );
    exit(66);
  }
  final data =
      jsonDecode(await res.transform(utf8.decoder).join())
          as Map<String, dynamic>;
  final nodes = (data['nodes'] as Map).cast<String, dynamic>();

  // 3. Snapshot 조립 — fail-closed: 미해석 노드 1개라도 있으면 snapshot 미작성
  final now = DateTime.now().toUtc().toIso8601String();
  final snapshot = {
    'slug': slug,
    'fetchedAt': now,
    'figmaFile': fileKey,
    // v2: fillArgb/gradient/shadows/layoutGrids/textColorArgb 추가 (additive).
    // v3: blurs 추가 (additive).
    'schemaVersion': 3,
    'screens': <String, dynamic>{},
  };
  final unresolved = <String>[];
  for (final entry in screens.entries) {
    final screenKey = entry.key;
    final screenCfg = entry.value as Map<String, dynamic>;
    final rootId = screenCfg['rootNodeId'] as String;
    final elements = (screenCfg['elements'] as Map).cast<String, String>();

    final rootNode = nodes[rootId]?['document'] as Map<String, dynamic>?;
    if (rootNode == null) {
      unresolved.add('$screenKey.<root> ($rootId)');
      continue;
    }

    final elementsOut = <String, dynamic>{};
    for (final elemEntry in elements.entries) {
      final node = nodes[elemEntry.value]?['document'] as Map<String, dynamic>?;
      if (node == null) {
        unresolved.add('$screenKey.${elemEntry.key} (${elemEntry.value})');
        continue;
      }
      elementsOut[elemEntry.key] = _extractNode(node);
    }

    (snapshot['screens'] as Map)[screenKey] = {
      'rootNodeId': rootId,
      'root': _extractNode(rootNode, includeChildren: false),
      'elements': elementsOut,
    };
  }

  if (unresolved.isNotEmpty) {
    stderr.writeln('❌ Figma source 불해석 ${unresolved.length}개 — INV-1 위반');
    stderr.writeln(
      '   file_key=$fileKey 에서 해당 node 가 사라졌거나, '
      'config 의 node id 가 다른 파일 소유일 수 있음.',
    );
    stderr.writeln('   확인: https://www.figma.com/file/$fileKey');
    for (final id in unresolved) {
      stderr.writeln('   - $id');
    }
    stderr.writeln('→ snapshot 미작성 (fail-closed). 해결 후 재실행.');
    exit(2);
  }

  // 4. Snapshot 쓰기
  final snapshotPath = '$repoRoot/docs/figma-snapshots/$slug.json';
  final snapshotJson = const JsonEncoder.withIndent('  ').convert(snapshot);
  if (dryRun) {
    stderr.writeln('--- DRY RUN: snapshot preview ---');
    stdout.writeln(snapshotJson);
    exit(0);
  }
  Directory(snapshotPath).parent.createSync(recursive: true);
  File(snapshotPath).writeAsStringSync('$snapshotJson\n');
  stderr.writeln('✅ $snapshotPath');

  // 5. Dart 상수 생성 (+ 무결성 사이드카 — 수기 수정/재생성 누락 감지용)
  final dartPath =
      '$repoRoot/lib/design_system/generated/${slug.replaceAll('-', '_')}_tokens.dart';
  Directory(
    dartPath.substring(0, dartPath.lastIndexOf('/')),
  ).createSync(recursive: true);
  File(dartPath).writeAsStringSync(_generateDart(slug, snapshot));
  _writeIntegrity(repoRoot, slug, dartPath);
  stderr.writeln('✅ $dartPath');
}

/// generated dart 를 `dart format` 으로 정규화한 뒤 무결성 사이드카를 기록한다.
/// 게이트의 `dart format .` 이 generated 도 건드리므로 포맷 후 본문이 해시
/// 기준이어야 안정적이다. 사이드카 형식(2줄):
///   1줄 = generated dart 본문 FNV-1a64  → 수기 수정·재생성 누락 감지
///   2줄 = snapshot json 본문 FNV-1a64   → snapshot 수기 변조(fetchedAt 유지) 감지
/// drift 테스트가 양쪽을 재계산·대조한다 (codex 평가 M3 + 재평가 보강).
void _writeIntegrity(String repoRoot, String slug, String dartPath) {
  final fmt = Process.runSync(Platform.resolvedExecutable, [
    'format',
    dartPath,
  ]);
  if (fmt.exitCode != 0) {
    // 포맷 실패 본문을 해시하면 게이트와 영원히 어긋난다 — 생성 실패로 처리.
    stderr.writeln('❌ dart format 실패(${fmt.exitCode}): ${fmt.stderr}');
    exit(70);
  }
  final formatted = File(dartPath).readAsStringSync();
  final snapshotJson = File(
    '$repoRoot/docs/figma-snapshots/$slug.json',
  ).readAsStringSync();
  final path = '$repoRoot/docs/figma-snapshots/$slug.tokens.fnv1a';
  File(path).writeAsStringSync(
    '${_fnv1a64(utf8.encode(formatted))}\n'
    '${_fnv1a64(utf8.encode(snapshotJson))}\n',
  );
  stderr.writeln('✅ $path');
}

/// FNV-1a 64-bit (Dart int 는 64-bit wrap-around — JS 컴파일 미사용 CLI 전용).
/// 음수 int 의 toRadixString 은 '-' 를 붙이므로 32-bit 반쪽으로 나눠 렌더링.
String _fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash *= 0x100000001b3;
  }
  final hi = hash >>> 32;
  final lo = hash & 0xFFFFFFFF;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (File('${dir.path}/CLAUDE.md').existsSync()) return dir.path;
    dir = dir.parent;
  }
  throw StateError('CLAUDE.md 못 찾음');
}

Map<String, String> _loadDotEnv() {
  // .env 를 실행 위치에서 위로 5단계까지 탐색 — 스킬 폴더(.claude/skills/figma-sync/.env)
  // 우선, 리포 루트 .env fallback. extract_doc.dart 의 _loadEnv 와 동일 규약(세 도구 일치).
  var dir = Directory.current;
  for (var depth = 0; depth < 5; depth++) {
    final env = File('${dir.path}/.env');
    if (env.existsSync()) {
      final out = <String, String>{};
      for (final line in env.readAsLinesSync()) {
        final s = line.trim();
        if (s.isEmpty || s.startsWith('#')) continue;
        final eq = s.indexOf('=');
        if (eq < 0) continue;
        out[s.substring(0, eq)] = s
            .substring(eq + 1)
            .replaceAll('"', '')
            .replaceAll("'", '');
      }
      return out;
    }
    dir = dir.parent;
  }
  return {};
}

Map<String, dynamic> _extractNode(
  Map<String, dynamic> n, {
  bool includeChildren = false,
}) {
  final out = <String, dynamic>{
    'nodeId': n['id'],
    'name': n['name'],
    'type': n['type'],
  };
  final bb = n['absoluteBoundingBox'] as Map?;
  if (bb != null) out['bbox'] = {'w': bb['width'], 'h': bb['height']};

  if (n.containsKey('cornerRadius')) {
    out['cornerRadius'] = (n['cornerRadius'] as num).toDouble();
  }
  // 비-TEXT 노드의 stroke 추출 (border) — fake-bold 와 분리. visible:false 스킵.
  if (n['type'] != 'TEXT') {
    final strokes = (n['strokes'] as List?)
        ?.cast<Map<String, dynamic>>()
        .where((s) => s['visible'] != false)
        .toList();
    final strokeWeight = n['strokeWeight'] as num?;
    if (strokes != null &&
        strokes.isNotEmpty &&
        strokeWeight != null &&
        strokeWeight > 0) {
      final s = strokes.first as Map?;
      if (s != null && s['type'] == 'SOLID') {
        final c = s['color'] as Map?;
        if (c != null) {
          out['stroke'] = {
            'width': strokeWeight.toDouble(),
            'colorHex': _rgbToHex(c),
            'colorArgb': _argbHex(c, s['opacity'] as num?),
          };
        }
      }
    }
  }
  // 비-TEXT 노드의 fill 추출 — 단색(SOLID)은 hex+argb, 그라디언트는 stops/handles.
  // visible:false 페인트는 스킵하고 첫 "보이는" fill 을 쓴다 (codex 평가 M8 부분 반영;
  // BACKGROUND_BLUR 는 v3 에서 effects 블록이 추출. 다중 페인트 합성은 백로그).
  if (n['type'] != 'TEXT') {
    final fills = (n['fills'] as List?)
        ?.cast<Map<String, dynamic>>()
        .where((f) => f['visible'] != false)
        .toList();
    if (fills != null && fills.isNotEmpty) {
      final f = fills.first as Map?;
      if (f != null && f['type'] == 'SOLID') {
        final c = f['color'] as Map?;
        if (c != null) {
          out['fillHex'] = _rgbToHex(c);
          out['fillArgb'] = _argbHex(c, f['opacity'] as num?);
        }
      } else if (f != null &&
          (f['type'] as String? ?? '').startsWith('GRADIENT_')) {
        final stops = (f['gradientStops'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        final handles = (f['gradientHandlePositions'] as List? ?? const [])
            .cast<Map<String, dynamic>>();
        out['gradient'] = {
          'type': f['type'],
          'opacity': (f['opacity'] as num?)?.toDouble() ?? 1.0,
          'stops': [
            for (final s in stops)
              {
                'position': (s['position'] as num).toDouble(),
                'argb': _argbHex(s['color'] as Map, f['opacity'] as num?),
              },
          ],
          // [0]=begin, [1]=end, [2]=width 핸들 (Figma 좌표는 노드 비율 0~1).
          'handles': [
            for (final h in handles)
              {
                'x': (h['x'] as num).toDouble(),
                'y': (h['y'] as num).toDouble(),
              },
          ],
        };
      }
    }
  }
  // 이펙트 추출 — 보이는 DROP_SHADOW/INNER_SHADOW + BACKGROUND_BLUR/LAYER_BLUR
  // (schema v3 — codex 평가 M8 잔여 해소).
  final effects = n['effects'] as List?;
  if (effects != null && effects.isNotEmpty) {
    final shadows = <Map<String, dynamic>>[];
    final blurs = <Map<String, dynamic>>[];
    for (final e in effects.cast<Map<String, dynamic>>()) {
      final type = e['type'] as String? ?? '';
      if (e['visible'] == false) continue;
      if (type.contains('SHADOW')) {
        final offset = e['offset'] as Map? ?? const {'x': 0, 'y': 0};
        shadows.add({
          'type': type,
          'argb': _argbHex(e['color'] as Map, null),
          'offsetX': (offset['x'] as num).toDouble(),
          'offsetY': (offset['y'] as num).toDouble(),
          'radius': ((e['radius'] as num?) ?? 0).toDouble(),
          if (e['spread'] != null) 'spread': (e['spread'] as num).toDouble(),
        });
      } else if (type == 'BACKGROUND_BLUR' || type == 'LAYER_BLUR') {
        blurs.add({
          'type': type,
          'radius': ((e['radius'] as num?) ?? 0).toDouble(),
        });
      }
    }
    if (shadows.isNotEmpty) out['shadows'] = shadows;
    if (blurs.isNotEmpty) out['blurs'] = blurs;
  }
  // 레이아웃 그리드 (GRID 스타일 소스 노드 / 프레임의 그리드 설정).
  final grids = n['layoutGrids'] as List?;
  if (grids != null && grids.isNotEmpty) {
    out['layoutGrids'] = [
      for (final g in grids.cast<Map<String, dynamic>>())
        {
          'pattern': g['pattern'],
          if (g['alignment'] != null) 'alignment': g['alignment'],
          if (g['sectionSize'] != null)
            'sectionSize': (g['sectionSize'] as num).toDouble(),
          if (g['count'] != null) 'count': g['count'],
          if (g['gutterSize'] != null)
            'gutterSize': (g['gutterSize'] as num).toDouble(),
          if (g['offset'] != null) 'offset': (g['offset'] as num).toDouble(),
        },
    ];
  }
  if (n.containsKey('layoutMode') && n['layoutMode'] != 'NONE') {
    out['autoLayout'] = {
      'mode': n['layoutMode'],
      if (n['itemSpacing'] != null)
        'itemSpacing': (n['itemSpacing'] as num).toDouble(),
      if (n['paddingLeft'] != null)
        'paddingLeft': (n['paddingLeft'] as num).toDouble(),
      if (n['paddingTop'] != null)
        'paddingTop': (n['paddingTop'] as num).toDouble(),
      if (n['paddingRight'] != null)
        'paddingRight': (n['paddingRight'] as num).toDouble(),
      if (n['paddingBottom'] != null)
        'paddingBottom': (n['paddingBottom'] as num).toDouble(),
      if (n['counterAxisAlignItems'] != null)
        'counterAxisAlignItems': n['counterAxisAlignItems'],
    };
  }
  if (n['type'] == 'TEXT') {
    final s = (n['style'] as Map?) ?? {};
    out['characters'] = n['characters'];
    out['style'] = {
      'fontFamily': s['fontFamily'],
      'fontWeight': s['fontWeight'],
      'fontSize': (s['fontSize'] as num?)?.toDouble(),
      'lineHeightPx': (s['lineHeightPx'] as num?)?.toDouble(),
      'letterSpacing': (s['letterSpacing'] as num?)?.toDouble(),
      'textAlign': s['textAlignHorizontal'],
    };
    // fill color (단색만)
    final fills = n['fills'] as List?;
    if (fills != null && fills.isNotEmpty) {
      final f = fills.first as Map?;
      if (f != null && f['type'] == 'SOLID') {
        final c = f['color'] as Map?;
        if (c != null) {
          out['style']['fill'] = _rgbToHex(c);
          out['style']['fillArgb'] = _argbHex(c, f['opacity'] as num?);
        }
      }
    }
    // fake-bold 감지: fill ≈ stroke + strokeWeight ≤ 1.0
    final strokes = n['strokes'] as List?;
    final strokeWeight = n['strokeWeight'] as num?;
    if (strokes != null &&
        strokes.isNotEmpty &&
        strokeWeight != null &&
        strokeWeight <= 1.0) {
      final sc = (strokes.first as Map?)?['color'] as Map?;
      if (sc != null) {
        final strokeHex = _rgbToHex(sc);
        if (strokeHex == out['style']['fill']) {
          out['fakeBold'] = {'strokeWidth': strokeWeight.toDouble()};
        }
      }
    }
    // character overrides (부분 굵기 등)
    final overrides = n['characterStyleOverrides'] as List?;
    final styleTable = n['styleOverrideTable'] as Map?;
    if (overrides != null &&
        overrides.isNotEmpty &&
        overrides.any((e) => (e as num) != 0)) {
      final runs = <Map<String, dynamic>>[];
      final chars = (n['characters'] as String?) ?? '';
      int? currentOverride;
      var start = 0;
      for (var i = 0; i <= overrides.length; i++) {
        final curr = i == overrides.length
            ? null
            : (overrides[i] as num).toInt();
        if (curr != currentOverride) {
          if (currentOverride != null) {
            final styleDelta = (styleTable?['$currentOverride'] as Map?)
                ?.cast<String, dynamic>();
            runs.add({
              'start': start,
              'end': i,
              'text': chars.substring(start, i),
              if (styleDelta != null) 'override': styleDelta,
            });
          }
          currentOverride = curr;
          start = i;
        }
      }
      out['textRuns'] = runs;
    }
  }
  if (includeChildren && n['children'] is List) {
    out['children'] = (n['children'] as List)
        .cast<Map<String, dynamic>>()
        .map((c) => _extractNode(c, includeChildren: true))
        .toList();
  }
  return out;
}

/// AARRGGBB 8자리 hex — Figma color.a 와 fill/effect 의 opacity 를 합성한다.
/// Dart 생성 시 `0x` 접두로 그대로 int 리터럴이 된다.
String _argbHex(Map<dynamic, dynamic> c, num? opacity) {
  int ch(num v) => (v * 255).round().clamp(0, 255);
  final a = ((c['a'] as num? ?? 1) * (opacity ?? 1));
  String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return '${h(ch(a))}${h(ch(c['r'] as num))}'
      '${h(ch(c['g'] as num))}${h(ch(c['b'] as num))}';
}

String _rgbToHex(Map<dynamic, dynamic> c) {
  int ch(num v) => (v * 255).round().clamp(0, 255);
  final r = ch(c['r'] as num);
  final g = ch(c['g'] as num);
  final b = ch(c['b'] as num);
  return '#${r.toRadixString(16).padLeft(2, '0').toUpperCase()}'
      '${g.toRadixString(16).padLeft(2, '0').toUpperCase()}'
      '${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

String _generateDart(String slug, Map<String, dynamic> snapshot) {
  final className = _toClassName(slug);
  final buf = StringBuffer();
  buf.writeln('// GENERATED FILE — DO NOT EDIT.');
  buf.writeln('// Source: docs/figma-snapshots/$slug.json');
  buf.writeln('// fetchedAt: ${snapshot['fetchedAt']}');
  buf.writeln('// figmaFile: ${snapshot['figmaFile']}');
  buf.writeln(
    '// Regenerate: cd .claude/skills/figma-sync/tool && dart run bin/figma_sync.dart --slug $slug',
  );
  buf.writeln('//');
  // renew 의 very_good_analysis 기준 — 생성 파일에서 의미 없는 스타일 린트만 끈다
  // (경계 린트 harness_lints 는 끄지 않음; ci.yml/local_ci 의 우회금지 grep 도
  // 6개 경계 룰명만 검사하므로 이 목록과 충돌 없음).
  buf.writeln(
    '// ignore_for_file: constant_identifier_names, lines_longer_than_80_chars',
  );
  buf.writeln(
    '// ignore_for_file: prefer_int_literals, unnecessary_library_directive',
  );
  buf.writeln('library;');
  buf.writeln();
  buf.writeln('/// Figma 실측값에서 자동 생성된 상수. 위젯 코드는 이 상수만 참조하라.');
  buf.writeln('/// 값 변경하려면 Figma 에서 수정 후 `figma_sync.dart` 를 다시 실행한다.');
  buf.writeln('abstract final class $className {');
  final screens = snapshot['screens'] as Map;
  for (final screenEntry in screens.entries) {
    final screenKey = screenEntry.key as String;
    final screenData = screenEntry.value as Map<String, dynamic>;
    buf.writeln();
    buf.writeln('  // ═══════════════════════════════════════════════════════');
    buf.writeln('  // $screenKey  (root ${screenData['rootNodeId']})');
    buf.writeln('  // ═══════════════════════════════════════════════════════');
    final elements = screenData['elements'] as Map<String, dynamic>;
    for (final elemEntry in elements.entries) {
      final elemKey = elemEntry.key;
      final elem = elemEntry.value as Map<String, dynamic>;
      final prefix = '${_camel(screenKey)}_${_camel(elemKey)}';
      buf.writeln();
      buf.writeln(
        '  // ─── $screenKey.$elemKey (${elem['type']}, ${elem['nodeId']}) ───',
      );
      final bbox = elem['bbox'] as Map?;
      if (bbox != null) {
        buf.writeln('  static const double ${prefix}_w = ${_num(bbox['w'])};');
        buf.writeln('  static const double ${prefix}_h = ${_num(bbox['h'])};');
      }
      if (elem['cornerRadius'] != null) {
        buf.writeln(
          '  static const double ${prefix}_cornerRadius = ${_num(elem['cornerRadius'])};',
        );
      }
      // border (stroke) 토큰
      final stroke = elem['stroke'] as Map?;
      if (stroke != null) {
        buf.writeln(
          '  static const double ${prefix}_strokeWidth = ${_num(stroke['width'])};',
        );
        buf.writeln(
          "  static const String ${prefix}_strokeColorHex = '${stroke['colorHex']}';",
        );
        if (stroke['colorArgb'] != null) {
          buf.writeln(
            '  static const int ${prefix}_strokeColorArgb = 0x${stroke['colorArgb']};',
          );
        }
      }
      // 비-TEXT 노드의 fill (배경 색) — argb 는 Color(0x..) 로 바로 쓰는 용도.
      if (elem['fillHex'] != null) {
        buf.writeln(
          "  static const String ${prefix}_fillHex = '${elem['fillHex']}';",
        );
      }
      if (elem['fillArgb'] != null) {
        buf.writeln(
          '  static const int ${prefix}_fillArgb = 0x${elem['fillArgb']};',
        );
      }
      // 그라디언트 fill — stops(색/위치) + begin/end 핸들(노드 비율 0~1 좌표).
      // stop 별 스칼라 상수(`_gradientColor{i}Argb`/`_gradientStop{i}`)를 함께
      // 방출한다 — const List 인덱싱은 const 가 아니어서, 시맨틱 레이어가
      // const LinearGradient 를 만들 때 손 복제 대신 스칼라를 참조하게(codex M4).
      // 핸들/stop 위치는 픽셀이 아니라 비율 좌표라 2자리 반올림이 정밀도를
      // 깨뜨림(codex M5) → _ratio(6자리) 사용.
      final gradient = elem['gradient'] as Map?;
      if (gradient != null) {
        final stops = (gradient['stops'] as List).cast<Map<String, dynamic>>();
        final handles = (gradient['handles'] as List)
            .cast<Map<String, dynamic>>();
        buf.writeln(
          "  static const String ${prefix}_gradientType = '${gradient['type']}';",
        );
        buf.writeln(
          '  static const List<int> ${prefix}_gradientColors = '
          '[${stops.map((s) => '0x${s['argb']}').join(', ')}];',
        );
        buf.writeln(
          '  static const List<double> ${prefix}_gradientStops = '
          '[${stops.map((s) => _ratio(s['position'])).join(', ')}];',
        );
        for (var i = 0; i < stops.length; i++) {
          buf.writeln(
            '  static const int ${prefix}_gradientColor${i}Argb = '
            '0x${stops[i]['argb']};',
          );
          buf.writeln(
            '  static const double ${prefix}_gradientStop$i = '
            '${_ratio(stops[i]['position'])};',
          );
        }
        if (handles.length >= 2) {
          buf.writeln(
            '  static const double ${prefix}_gradientBeginX = ${_ratio(handles[0]['x'])};',
          );
          buf.writeln(
            '  static const double ${prefix}_gradientBeginY = ${_ratio(handles[0]['y'])};',
          );
          buf.writeln(
            '  static const double ${prefix}_gradientEndX = ${_ratio(handles[1]['x'])};',
          );
          buf.writeln(
            '  static const double ${prefix}_gradientEndY = ${_ratio(handles[1]['y'])};',
          );
        }
      }
      // 그림자 (DROP_SHADOW/INNER_SHADOW) — 인덱스 붙여 전부 방출.
      final shadows = (elem['shadows'] as List?)?.cast<Map<String, dynamic>>();
      if (shadows != null) {
        for (var i = 0; i < shadows.length; i++) {
          final s = shadows[i];
          buf.writeln(
            '  static const int ${prefix}_shadow${i}ColorArgb = 0x${s['argb']};',
          );
          buf.writeln(
            '  static const double ${prefix}_shadow${i}OffsetX = ${_num(s['offsetX'])};',
          );
          buf.writeln(
            '  static const double ${prefix}_shadow${i}OffsetY = ${_num(s['offsetY'])};',
          );
          buf.writeln(
            '  static const double ${prefix}_shadow${i}Radius = ${_num(s['radius'])};',
          );
          if (s['spread'] != null) {
            buf.writeln(
              '  static const double ${prefix}_shadow${i}Spread = ${_num(s['spread'])};',
            );
          }
        }
      }
      // 블러 (BACKGROUND_BLUR/LAYER_BLUR) — 인덱스 붙여 전부 방출.
      // radius 는 Figma 픽셀 치수 — Flutter ImageFilter.blur 의 sigma 변환은
      // 위젯 구현에서 한다 (여기서 굽지 않는다).
      final blurs = (elem['blurs'] as List?)?.cast<Map<String, dynamic>>();
      if (blurs != null) {
        for (var i = 0; i < blurs.length; i++) {
          final b = blurs[i];
          buf.writeln(
            "  static const String ${prefix}_blur${i}Type = '${b['type']}';",
          );
          buf.writeln(
            '  static const double ${prefix}_blur${i}Radius = ${_num(b['radius'])};',
          );
        }
      }
      // 레이아웃 그리드 — 인덱스 붙여 전부 방출.
      final layoutGrids = (elem['layoutGrids'] as List?)
          ?.cast<Map<String, dynamic>>();
      if (layoutGrids != null) {
        for (var i = 0; i < layoutGrids.length; i++) {
          final g = layoutGrids[i];
          buf.writeln(
            "  static const String ${prefix}_grid${i}Pattern = '${g['pattern']}';",
          );
          if (g['alignment'] != null) {
            buf.writeln(
              "  static const String ${prefix}_grid${i}Alignment = '${g['alignment']}';",
            );
          }
          if (g['count'] != null) {
            buf.writeln(
              '  static const int ${prefix}_grid${i}Count = ${g['count']};',
            );
          }
          if (g['sectionSize'] != null) {
            buf.writeln(
              '  static const double ${prefix}_grid${i}SectionSize = ${_num(g['sectionSize'])};',
            );
          }
          if (g['gutterSize'] != null) {
            buf.writeln(
              '  static const double ${prefix}_grid${i}GutterSize = ${_num(g['gutterSize'])};',
            );
          }
          if (g['offset'] != null) {
            buf.writeln(
              '  static const double ${prefix}_grid${i}Offset = ${_num(g['offset'])};',
            );
          }
        }
      }
      final al = elem['autoLayout'] as Map?;
      if (al != null) {
        if (al['itemSpacing'] != null) {
          buf.writeln(
            '  static const double ${prefix}_itemSpacing = ${_num(al['itemSpacing'])};',
          );
        }
        if (al['paddingLeft'] != null)
          buf.writeln(
            '  static const double ${prefix}_paddingLeft = ${_num(al['paddingLeft'])};',
          );
        if (al['paddingTop'] != null)
          buf.writeln(
            '  static const double ${prefix}_paddingTop = ${_num(al['paddingTop'])};',
          );
        if (al['paddingRight'] != null)
          buf.writeln(
            '  static const double ${prefix}_paddingRight = ${_num(al['paddingRight'])};',
          );
        if (al['paddingBottom'] != null)
          buf.writeln(
            '  static const double ${prefix}_paddingBottom = ${_num(al['paddingBottom'])};',
          );
      }
      final style = elem['style'] as Map?;
      if (style != null) {
        if (style['fontFamily'] != null)
          buf.writeln(
            "  static const String ${prefix}_fontFamily = '${style['fontFamily']}';",
          );
        if (style['fontWeight'] != null)
          buf.writeln(
            '  static const int ${prefix}_fontWeight = ${style['fontWeight']};',
          );
        if (style['fontSize'] != null)
          buf.writeln(
            '  static const double ${prefix}_fontSize = ${_num(style['fontSize'])};',
          );
        if (style['lineHeightPx'] != null)
          buf.writeln(
            '  static const double ${prefix}_lineHeightPx = ${_num(style['lineHeightPx'])};',
          );
        if (style['letterSpacing'] != null)
          buf.writeln(
            '  static const double ${prefix}_letterSpacing = ${_num(style['letterSpacing'])};',
          );
        if (style['fill'] != null)
          buf.writeln(
            "  static const String ${prefix}_fillHex = '${style['fill']}';",
          );
        if (style['fillArgb'] != null)
          buf.writeln(
            '  static const int ${prefix}_textColorArgb = 0x${style['fillArgb']};',
          );
      }
      if (elem['fakeBold'] != null) {
        final fb = elem['fakeBold'] as Map;
        buf.writeln('  static const bool ${prefix}_fakeBold = true;');
        buf.writeln(
          '  static const double ${prefix}_fakeBoldStroke = ${_num(fb['strokeWidth'])};',
        );
      }
      final runs = elem['textRuns'] as List?;
      if (runs != null && runs.isNotEmpty) {
        for (var i = 0; i < runs.length; i++) {
          final r = runs[i] as Map;
          buf.writeln(
            '  static const int ${prefix}_run${i}Start = ${r['start']};',
          );
          buf.writeln('  static const int ${prefix}_run${i}End = ${r['end']};');
          final ov = r['override'] as Map?;
          if (ov != null && ov['fontWeight'] != null) {
            buf.writeln(
              '  static const int ${prefix}_run${i}FontWeight = ${ov['fontWeight']};',
            );
          }
        }
      }
    }
  }
  buf.writeln();
  buf.writeln('  // ─── metadata ───');
  buf.writeln("  static const String figmaFile = '${snapshot['figmaFile']}';");
  buf.writeln("  static const String fetchedAt = '${snapshot['fetchedAt']}';");
  buf.writeln(
    '  static const int schemaVersion = ${snapshot['schemaVersion']};',
  );
  buf.writeln('}');
  return buf.toString();
}

String _num(dynamic v) {
  if (v is num) {
    // Figma API 는 10 을 10.000000953674316 처럼 돌려준다. 픽셀 치수는
    // 소수 2자리로 반올림 (비율 좌표는 _ratio 사용 — 2자리는 정밀도 손실).
    final rounded = (v * 100).round() / 100;
    if (rounded == rounded.toInt()) return '${rounded.toInt()}.0';
    return rounded.toString();
  }
  return v.toString();
}

/// 0~1 비율 좌표/위치(그라디언트 핸들·stop)용 — 6자리 보존 (codex M5).
String _ratio(dynamic v) {
  if (v is num) {
    final rounded = (v * 1000000).round() / 1000000;
    if (rounded == rounded.toInt()) return '${rounded.toInt()}.0';
    return rounded.toString();
  }
  return v.toString();
}

String _camel(String s) {
  final parts = s.split(RegExp(r'[-_ ]'));
  if (parts.isEmpty) return s;
  return parts.first +
      parts
          .skip(1)
          .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1))
          .join();
}

String _toClassName(String slug) {
  final parts = slug.split('-');
  return '${parts.map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1)).join()}Tokens';
}
