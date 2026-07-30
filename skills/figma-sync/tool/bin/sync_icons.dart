// Icon Sync — Figma `icons/normal` 프레임을 PNG 에셋 + manifest + Dart 카탈로그로 동기화.
// (codex 평가 M9 해소: 아이콘 추출을 손작업이 아닌 기계 동기화 체인으로 — figma_sync.dart 와
//  동일한 .env/리포루트/FNV-1a 패턴을 따른다)
//
// 입력:
//   Figma file (.env 의 FIGMA_FILE_KEY) 의 node 4051:1118 (② Theme > Icon `icons/normal`)
//   환경변수 FIGMA_TOKEN, FIGMA_FILE_KEY  (.env 파일)
//
// 출력:
//   assets/icons/{,2.0x/,3.0x/}{name}.png            (scale 1/2/3 PNG)
//   docs/figma-snapshots/icons.manifest.json         (SSOT — nodeId·크기·PNG FNV-1a)
//   lib/design_system/app_icons.dart                 (AppIcons 카탈로그, DO NOT EDIT)
//
// 사용법:
//   cd .claude/skills/figma-sync/tool
//   dart run bin/sync_icons.dart --dry-run   # 디스크 대비 추가/삭제/이름변경 예상만 출력
//   dart run bin/sync_icons.dart             # 실제 동기화
//
// 이름 정규화 규칙 (산출 이름의 SSOT — app_icons.dart 헤더에도 동일 문서화):
//   1. 세트 이름 kebab-case → snake_case, 제어문자 제거, 소문자화
//   2. 변형값 `Property 1=Default` → 접미사 없음, 그 외 → `_<변형값>` 접미사
//   3. 세트명 == 변형값이면 중복 축약 (loading/loading → loading)
//   4. 동명 충돌 시 뒤의 것에 `_<가로px>` 접미사 (예: chevron_left_8)
//   5. `_blank` 템플릿 세트·문서/주석 프레임 제외,
//      cursor 의 Variant2(4051:1400)는 Figma 렌더 불가로 제외 (_knownUnrenderable)
//
// Exit codes:
//   0  성공
//   2  이름 충돌 미해소 (가로px 접미사로도 충돌)
//   65 .env 누락
//   66 Figma API HTTP error (1회 재시도 후)
//   70 generated dart format 실패

import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _baseUrl = 'https://api.figma.com/v1';

/// ② Theme > Icon `icons/normal` 프레임.
const _frameNodeId = '4051:1118';

/// Figma images API 가 PNG 렌더를 거부(null)하는 것으로 확인된 노드 — 카탈로그 제외.
/// (cursor 세트의 `Property 1=Variant2`)
const _knownUnrenderable = {'4051:1400'};

/// images API 1회 요청당 node id 개수 상한.
const _batchSize = 50;

final _http = HttpClient();

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');

  final env = _loadDotEnv();
  final token = env['FIGMA_TOKEN'] ?? Platform.environment['FIGMA_TOKEN'];
  final fileKey =
      env['FIGMA_FILE_KEY'] ?? Platform.environment['FIGMA_FILE_KEY'];
  if (token == null || fileKey == null) {
    stderr.writeln('FIGMA_TOKEN / FIGMA_FILE_KEY 필요 (.env 또는 환경변수)');
    exit(65);
  }
  final repoRoot = _findRepoRoot();

  // 1. 아이콘 프레임 subtree fetch
  stderr.writeln('→ 프레임 $_frameNodeId fetch 중... ($fileKey)');
  final data = await _getJson(
    '$_baseUrl/files/$fileKey/nodes?ids=$_frameNodeId',
    token,
  );
  final doc =
      ((data['nodes'] as Map?)?[_frameNodeId] as Map?)?['document']
          as Map<String, dynamic>?;
  if (doc == null) {
    stderr.writeln('❌ node $_frameNodeId 미해석 — file_key 또는 권한 확인.');
    exit(66);
  }

  // 2. COMPONENT_SET/COMPONENT 열거 + 이름 정규화
  var icons = _enumerateIcons(doc);
  stderr.writeln('→ 아이콘 ${icons.length}개 열거됨');

  // 3. dry-run: 디스크 대비 diff 예상만 출력하고 종료
  if (dryRun) {
    _printDryRunDiff(repoRoot, icons);
    exit(0);
  }

  // 4. export URL 확보 — tintable=SVG(1장), brand(sns_*)=PNG(1/2/3x). 50개 배치.
  final svgIcons = icons.where((i) => i.tintable).toList();
  final pngIcons = icons.where((i) => !i.tintable).toList();
  stderr.writeln(
    '→ SVG(단색·틴팅) ${svgIcons.length}개 · PNG(브랜드) ${pngIcons.length}개',
  );
  final svgUrls = svgIcons.isEmpty
      ? <String, String?>{}
      : await _exportUrls(
          fileKey,
          token,
          svgIcons.map((i) => i.nodeId).toList(),
          1,
          format: 'svg',
        );
  final pngUrlsByScale = <int, Map<String, String?>>{};
  for (final scale in [1, 2, 3]) {
    if (pngIcons.isEmpty) break;
    stderr.writeln('→ PNG export 요청 (scale=$scale)...');
    pngUrlsByScale[scale] = await _exportUrls(
      fileKey,
      token,
      pngIcons.map((i) => i.nodeId).toList(),
      scale,
    );
  }

  // null 반환 노드 = 실패 처리 (fail-closed — codex BLOCKER). 일시 장애면 재실행,
  // 영구 렌더 불가면 열거 제외 목록(_knownUnrenderable)에 추가.
  final failed = <_Icon>[];
  for (final icon in svgIcons) {
    if (svgUrls[icon.nodeId] == null) {
      failed.add(icon);
      stderr.writeln('❌ SVG export 실패: ${icon.name} (${icon.nodeId})');
    }
  }
  for (final icon in pngIcons) {
    final missing = [
      1,
      2,
      3,
    ].where((s) => pngUrlsByScale[s]?[icon.nodeId] == null).toList();
    if (missing.isNotEmpty) {
      failed.add(icon);
      stderr.writeln(
        '❌ PNG export 실패: ${icon.name} (${icon.nodeId}) — scale $missing null',
      );
    }
  }
  if (failed.isNotEmpty) {
    stderr.writeln(
      '❌ ${failed.length}개 아이콘 export 실패 — 디스크/카탈로그/manifest 를 '
      '건드리지 않고 중단 (fail-closed). 일시 장애면 재실행, 영구 렌더 불가면 '
      '열거 제외 목록에 추가하라.',
    );
    exit(2);
  }

  // 5. 다운로드 — SVG 는 루트 1장, PNG 는 {,2.0x/,3.0x/} 3장. FNV-1a 기록.
  const scaleDirs = {1: '', 2: '2.0x/', 3: '3.0x/'};
  for (final dir in scaleDirs.values) {
    Directory('$repoRoot/assets/icons/$dir').createSync(recursive: true);
  }
  for (final icon in svgIcons) {
    final bytes = await _downloadBytes(svgUrls[icon.nodeId]!);
    File('$repoRoot/assets/icons/${icon.name}.svg').writeAsBytesSync(bytes);
    icon.fnv1a['svg'] = _fnv1a64(bytes);
    stderr.writeln('  ✓ ${icon.name}.svg');
  }
  for (final icon in pngIcons) {
    for (final entry in scaleDirs.entries) {
      final bytes = await _downloadBytes(
        pngUrlsByScale[entry.key]![icon.nodeId]!,
      );
      File(
        '$repoRoot/assets/icons/${entry.value}${icon.name}.png',
      ).writeAsBytesSync(bytes);
      icon.fnv1a['x${entry.key}'] = _fnv1a64(bytes);
    }
    stderr.writeln('  ✓ ${icon.name}.png');
  }

  // 6. 고아 정리 — 각 아이콘 기대 포맷과 다른 파일 삭제(포맷 전환 시 구파일 포함).
  final svgNames = svgIcons.map((i) => i.name).toSet();
  final pngNames = pngIcons.map((i) => i.name).toSet();
  var deleted = 0;
  void purge(Directory d, bool Function(String base, String ext) keep) {
    if (!d.existsSync()) return;
    for (final f in d.listSync().whereType<File>()) {
      final fn = f.path.split('/').last;
      final dot = fn.lastIndexOf('.');
      if (dot < 0) continue;
      final ext = fn.substring(dot + 1);
      if (ext != 'png' && ext != 'svg') continue;
      if (!keep(fn.substring(0, dot), ext)) {
        f.deleteSync();
        deleted++;
        stderr.writeln('  ✗ 삭제: ${f.path.substring(repoRoot.length + 1)}');
      }
    }
  }

  // 루트: name.svg(svg 아이콘) · name.png(png 아이콘 1x) 만 유지.
  purge(
    Directory('$repoRoot/assets/icons'),
    (base, ext) =>
        (ext == 'svg' && svgNames.contains(base)) ||
        (ext == 'png' && pngNames.contains(base)),
  );
  // 2.0x/3.0x: png 아이콘만 유지(svg 는 변형 없음).
  for (final dir in ['2.0x', '3.0x']) {
    purge(
      Directory('$repoRoot/assets/icons/$dir'),
      (base, ext) => ext == 'png' && pngNames.contains(base),
    );
  }

  // 7. manifest 기록 (git-tracked SSOT — 무결성 테스트가 해시를 대조)
  final manifestPath = '$repoRoot/docs/figma-snapshots/icons.manifest.json';
  final manifest = {
    'fetchedAt': DateTime.now().toUtc().toIso8601String(),
    'figmaFile': fileKey,
    'frameNodeId': _frameNodeId,
    'icons': [
      for (final icon in icons)
        {
          'name': icon.name,
          'nodeId': icon.nodeId,
          'setName': icon.setName,
          'variant': icon.variant,
          'format': icon.format,
          'tintable': icon.tintable,
          'width': _jsonNum(icon.width),
          'height': _jsonNum(icon.height),
          'fnv1a': icon.fnv1a,
        },
    ],
  };
  Directory(manifestPath).parent.createSync(recursive: true);
  File(manifestPath).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stderr.writeln('✅ $manifestPath');

  // 8. AppIcons 카탈로그 재생성 + dart format
  final dartPath = '$repoRoot/lib/design_system/app_icons.dart';
  File(dartPath).writeAsStringSync(_generateDart(fileKey, icons));
  final fmt = Process.runSync(Platform.resolvedExecutable, [
    'format',
    dartPath,
  ]);
  if (fmt.exitCode != 0) {
    stderr.writeln('❌ dart format 실패(${fmt.exitCode}): ${fmt.stderr}');
    exit(70);
  }
  stderr.writeln('✅ $dartPath');

  stderr.writeln(
    '완료: 아이콘 ${icons.length}개 동기화'
    '${deleted == 0 ? '' : ' · 고아 삭제 $deleted개'}',
  );
  _http.close();
}

// ───────────────────────── 열거 + 이름 정규화 ─────────────────────────

class _Icon {
  _Icon({
    required this.name,
    required this.nodeId,
    required this.setName,
    required this.variant,
    required this.width,
    required this.height,
  });

  final String name;
  final String nodeId;
  final String setName;
  final String variant;
  final double width;
  final double height;

  /// 틴팅 가능(단색 라인) 여부 — 브랜드 멀티컬러(sns_*)는 false(PNG 유지).
  /// 단색 UI 아이콘은 SVG 로 추출해 런타임 틴팅(라이트/다크 대비)한다.
  /// codex denylist 시드: sns_apple/google/kakao + 각 _circle = sns_ prefix.
  bool get tintable => !name.startsWith('sns_');

  /// 추출/저장 포맷 — tintable=svg(1장), brand=png(1/2/3x).
  String get format => tintable ? 'svg' : 'png';

  /// 포맷별 바이트 FNV-1a64 — 다운로드 후 채워진다.
  /// svg: {'svg': hash} · png: {'x1','x2','x3': hash}.
  final Map<String, String> fnv1a = {};
}

/// 프레임 subtree 에서 COMPONENT_SET 하위 COMPONENT 들을 정규화 규칙대로 열거한다.
/// 문서 순서(=Figma children 순서)로 처리해야 동명 충돌 접미사가 결정적이다.
List<_Icon> _enumerateIcons(Map<String, dynamic> root) {
  final sets = <Map<String, dynamic>>[];
  void walk(Map<String, dynamic> n) {
    if (n['type'] == 'COMPONENT_SET') {
      sets.add(n);
      return;
    }
    for (final c
        in (n['children'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      walk(c);
    }
  }

  walk(root);

  final used = <String>{};
  final out = <_Icon>[];
  for (final set in sets) {
    final setBase = _normalize(set['name'] as String? ?? '');
    // `_blank` 템플릿 세트 제외 (Docs-desc 등 문서 프레임은 타입 필터로 이미 제외).
    if (setBase.isEmpty || setBase.startsWith('_')) continue;
    for (final comp
        in (set['children'] as List? ?? const [])
            .cast<Map<String, dynamic>>()) {
      if (comp['type'] != 'COMPONENT') continue;
      final nodeId = comp['id'] as String;
      if (_knownUnrenderable.contains(nodeId)) {
        stderr.writeln('  (제외: $setBase $nodeId — 렌더 불가 노드)');
        continue;
      }
      // 변형값 = `Property 1=Default` 의 `=` 뒤 — 없으면 이름 전체.
      final rawName = comp['name'] as String? ?? '';
      final eq = rawName.lastIndexOf('=');
      final variant = _normalize(eq < 0 ? rawName : rawName.substring(eq + 1));
      // Default → 무접미사 / 세트명==변형값 → 중복 축약 / 그 외 → `_<변형값>`
      var name = (variant == 'default' || variant == setBase)
          ? setBase
          : '${setBase}_$variant';
      final bb = (comp['absoluteBoundingBox'] as Map?) ?? const {};
      final w = ((bb['width'] as num?) ?? 0).toDouble();
      final h = ((bb['height'] as num?) ?? 0).toDouble();
      // 동명 충돌 → `_<가로px>` 접미사 (뒤에 오는 쪽이 양보)
      if (used.contains(name)) {
        name = '${name}_${w.round()}';
        if (used.contains(name)) {
          stderr.writeln('❌ 이름 충돌 미해소: $name ($nodeId)');
          exit(2);
        }
      }
      used.add(name);
      out.add(
        _Icon(
          name: name,
          nodeId: nodeId,
          setName: setBase,
          variant: variant,
          width: w,
          height: h,
        ),
      );
    }
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// 제어문자 제거 → 소문자 → kebab/공백/구분 기호 → snake_case.
/// 파일명·Dart 식별자 양쪽에 안전해야 한다 (codex 최종 검수 보강):
/// `/`·구두점은 `_` 로, 그 외 비허용 문자는 제거, 숫자 시작이면 `icon_` 접두.
/// 기존 82개 이름(kebab/공백만 포함)에는 전부 no-op 이다.
String _normalize(String raw) {
  var s = raw
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[-\s/.:+]+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9_]'), '')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (s.startsWith(RegExp(r'[0-9]'))) s = 'icon_$s';
  return s;
}

// ───────────────────────── dry-run diff ─────────────────────────

/// 다운로드 없이 (현재 디스크 1x 대비) 추가/삭제/이름변경 예상을 출력한다.
/// 기존 manifest 가 있으면 nodeId 매칭으로 이름변경을 구분한다.
void _printDryRunDiff(String repoRoot, List<_Icon> icons) {
  final dir = Directory('$repoRoot/assets/icons');
  final onDisk = !dir.existsSync()
      ? <String>{}
      : dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png') || f.path.endsWith('.svg'))
            .map((f) {
              final n = f.path.split('/').last;
              return n.substring(0, n.lastIndexOf('.'));
            })
            .toSet();
  final newNames = icons.map((i) => i.name).toSet();
  final added = newNames.difference(onDisk).toList()..sort();
  final removed = onDisk.difference(newNames).toList()..sort();

  // 기존 manifest 의 nodeId → name 으로 이름변경(같은 노드, 다른 이름) 감지
  final renames = <String>[];
  final manifestFile = File(
    '$repoRoot/docs/figma-snapshots/icons.manifest.json',
  );
  if (manifestFile.existsSync()) {
    final old =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final oldByNode = {
      for (final e
          in (old['icons'] as List? ?? const []).cast<Map<String, dynamic>>())
        e['nodeId'] as String: e['name'] as String,
    };
    for (final icon in icons) {
      final oldName = oldByNode[icon.nodeId];
      if (oldName != null && oldName != icon.name) {
        renames.add('$oldName → ${icon.name} (${icon.nodeId})');
        added.remove(icon.name);
        removed.remove(oldName);
      }
    }
  }

  stdout.writeln(
    '--- DRY RUN: 아이콘 ${icons.length}개 / 디스크 ${onDisk.length}개 ---',
  );
  stdout.writeln('추가 예상 (${added.length}): ${added.isEmpty ? '없음' : ''}');
  for (final n in added) {
    stdout.writeln('  + $n');
  }
  stdout.writeln('삭제 예상 (${removed.length}): ${removed.isEmpty ? '없음' : ''}');
  for (final n in removed) {
    stdout.writeln('  - $n');
  }
  stdout.writeln('이름변경 예상 (${renames.length}): ${renames.isEmpty ? '없음' : ''}');
  for (final n in renames) {
    stdout.writeln('  ~ $n');
  }
  if (added.isEmpty && removed.isEmpty && renames.isEmpty) {
    stdout.writeln('이름 diff 0 — 픽셀 변경 여부는 실제 실행 후 git diff 로 확인.');
  }
}

// ───────────────────────── Figma API ─────────────────────────

/// GET → JSON. 실패(비 200/네트워크) 시 1회 재시도 후 exit 66.
Future<Map<String, dynamic>> _getJson(String url, String token) async {
  for (var attempt = 0; ; attempt++) {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      req.headers.set('X-Figma-Token', token);
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw HttpException(
          'HTTP ${res.statusCode}: $body',
          uri: Uri.parse(url),
        );
      }
      return jsonDecode(body) as Map<String, dynamic>;
    } on Exception catch (e) {
      if (attempt >= 1) {
        stderr.writeln('❌ Figma API 실패 (재시도 후): $e');
        exit(66);
      }
      stderr.writeln('  재시도 1회: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

/// images API 로 export URL 확보 — 50개 배치, null 은 그대로 전달(호출부가 스킵).
/// format='png'(scale 적용) 또는 'svg'(scale 무시 — 벡터).
Future<Map<String, String?>> _exportUrls(
  String fileKey,
  String token,
  List<String> ids,
  int scale, {
  String format = 'png',
}) async {
  final out = <String, String?>{};
  final scaleParam = format == 'svg' ? '' : '&scale=$scale';
  for (var i = 0; i < ids.length; i += _batchSize) {
    final batch = ids.sublist(i, min(i + _batchSize, ids.length));
    final data = await _getJson(
      '$_baseUrl/images/$fileKey?ids=${batch.join(',')}&format=$format$scaleParam',
      token,
    );
    final images = (data['images'] as Map? ?? const {}).cast<String, dynamic>();
    for (final id in batch) {
      out[id] = images[id] as String?;
    }
  }
  return out;
}

/// PNG 바이트 다운로드 — 실패 1회 재시도 후 exit 66.
Future<List<int>> _downloadBytes(String url) async {
  for (var attempt = 0; ; attempt++) {
    try {
      final req = await _http.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      final bytes = <int>[];
      await res.forEach(bytes.addAll);
      return bytes;
    } on Exception catch (e) {
      if (attempt >= 1) {
        stderr.writeln('❌ PNG 다운로드 실패 (재시도 후): $e');
        exit(66);
      }
      stderr.writeln('  재시도 1회: $e');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
}

// ───────────────────────── 카탈로그 생성 ─────────────────────────

String _generateDart(String fileKey, List<_Icon> icons) {
  final buf = StringBuffer()
    ..writeln('// GENERATED FILE — DO NOT EDIT.')
    ..writeln('// Source: docs/figma-snapshots/icons.manifest.json')
    ..writeln(
      '// Regenerate: cd .claude/skills/figma-sync/tool && dart run bin/sync_icons.dart',
    )
    ..writeln('//')
    ..writeln('// DML Design System(Figma) ② Theme > Icon — 아이콘 에셋 카탈로그.')
    ..writeln(
      '// 출처: Figma file $fileKey, `icons/normal` 프레임(node $_frameNodeId)',
    )
    ..writeln('// 단색 라인 아이콘 = SVG(런타임 틴팅), 브랜드 멀티컬러(sns_*) = PNG 1/2/3x.')
    ..writeln('//')
    ..writeln('// 이름 정규화: 세트 이름 kebab-case → snake_case, 제어문자 제거,')
    ..writeln('// 변형(Property)이 Default 면 접미사 없음, 그 외는 `_<변형>` 접미사,')
    ..writeln('// 세트명==변형값이면 중복 축약 (loading), 동명 세트 충돌 시')
    ..writeln('// `_<가로px>` 접미사 (예: chevron_left_8).')
    ..writeln('// 제외: `_blank` 템플릿 세트, 문서/주석 프레임,')
    ..writeln('// `cursor` 의 Variant2(4051:1400, Figma 렌더 불가로 추출 실패).')
    ..writeln()
    ..writeln('/// DML 디자인시스템 아이콘 에셋 경로 모음.')
    ..writeln('///')
    ..writeln('/// 렌더는 `DoloAssetIcon(AppIcons.chevronLeft)`, 탭 가능하면')
    ..writeln(
      '/// `DoloIconButton(iconAsset: AppIcons.chevronLeft)` 로 쓴다. 아이콘 목적의 raw',
    )
    ..writeln(
      '/// `Image.asset`/`SvgPicture.asset` 직접 호출 금지(DS-first, AGENTS.md).',
    )
    ..writeln('/// Flutter 가 기기 배율에 맞춰 2.0x/3.0x 변형을 자동 선택한다.')
    ..writeln('abstract final class AppIcons {');
  for (final icon in icons) {
    buf
      ..writeln(
        '  /// `${icon.name}` (${icon.format}) — Figma node ${icon.nodeId}',
      )
      ..writeln(
        "  static const String ${_camel(icon.name)} = 'assets/icons/${icon.name}.${icon.format}';",
      )
      ..writeln();
  }
  return '${buf.toString().trimRight()}\n}\n';
}

/// snake_case → lowerCamelCase (예: chevron_left_8 → chevronLeft8).
String _camel(String s) {
  final parts = s.split('_');
  return parts.first +
      parts
          .skip(1)
          .map((p) => p.isEmpty ? '' : p[0].toUpperCase() + p.substring(1))
          .join();
}

// ───────────────────────── 공용 유틸 (figma_sync.dart 와 동일 패턴) ─────────────────────────

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

/// Figma 의 24.000001 류 노이즈를 2자리 반올림 — 정수면 int 로 (JSON 가독성).
Object _jsonNum(double v) {
  final rounded = (v * 100).round() / 100;
  return rounded == rounded.toInt() ? rounded.toInt() : rounded;
}
