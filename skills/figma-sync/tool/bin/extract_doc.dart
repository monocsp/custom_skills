// Figma 정책/문서 추출 (PNG + tree.json + md.skeleton)
// (dolomoodProto tools/figma_extractor 에서 이식 — 기본 출력 경로만 변경)
//
// 디자인 스펙(색/폰트/레이아웃) 수치 고정은 figma_sync.dart 담당.
// 이 도구는 화면/다이어그램 시각 추출용 — 텍스트 + 좌표 + 구조 보존.
//
// 사용법 (cwd = .claude/skills/figma-sync/tool):
//   dart run bin/extract_doc.dart --url "https://figma.com/file/.../?node-id=..."
//   dart run bin/extract_doc.dart --page "페이지명" [--section "1차"]
//   dart run bin/extract_doc.dart --node "1097:63359"
//
// 옵션:
//   --dry-run       실제 추출 없이 예상만 출력
//   --out <dir>     출력 루트 (기본: ../../../../docs/designs = 리포 루트의 docs/designs)
//   --scale <n>     PNG scale 강제 (기본: 자동 계산)

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const _baseUrl = 'https://api.figma.com/v1';
// tool 디렉터리(.claude/skills/figma-sync/tool) 기준 4단계 위 = 리포 루트.
const _defaultOutDir = '../../../../docs/designs';
const _maxImageSide = 10000; // Figma API PNG 한계
const _safetyMargin = 0.9;
const _minReadableTextPx = 10; // 미만이면 가독성 경고

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    _printUsage();
    return;
  }

  final dryRun = args.contains('--dry-run');
  final outDir = _argValue(args, '--out') ?? _defaultOutDir;
  final manualScale = _argValue(args, '--scale');

  final env = _loadEnv();
  String? fileKey = env['FIGMA_FILE_KEY'];
  final token = env['FIGMA_TOKEN'];

  if (token == null) {
    stderr.writeln('오류: .env에 FIGMA_TOKEN 필요');
    exit(1);
  }

  // 노드 결정 (URL > nodeId > pageName)
  String? targetNodeId;
  String? targetName;
  final url = _argValue(args, '--url');
  final pageName = _argValue(args, '--page');
  final sectionName = _argValue(args, '--section');
  final nodeIdArg = _argValue(args, '--node');

  if (url != null) {
    final parsed = _parseFigmaUrl(url);
    if (parsed == null) {
      stderr.writeln('오류: 유효하지 않은 Figma URL');
      exit(1);
    }
    fileKey = parsed['fileKey'];
    targetNodeId = parsed['nodeId'];
  } else if (nodeIdArg != null) {
    targetNodeId = nodeIdArg;
  } else if (pageName == null) {
    _printUsage();
    return;
  }

  if (fileKey == null) {
    stderr.writeln('오류: fileKey 없음 (--url 또는 .env에 FIGMA_FILE_KEY)');
    exit(1);
  }

  final client = HttpClient();
  final api = FigmaApi(client: client, token: token, fileKey: fileKey);

  try {
    // 페이지명 → 노드 ID
    if (targetNodeId == null && pageName != null) {
      final fileInfo = await api.fetchFile(depth: 1);
      final pages = (fileInfo['document']['children'] as List)
          .where((p) => p['type'] == 'CANVAS')
          .toList();
      final matches = pages
          .where((p) => (p['name'] as String).contains(pageName))
          .toList();
      if (matches.isEmpty) {
        stderr.writeln('오류: 페이지 "$pageName" 없음');
        exit(1);
      }
      final page = matches.first as Map<String, dynamic>;
      targetNodeId = page['id'] as String;
      targetName = page['name'] as String;

      if (sectionName != null) {
        final pageData = await api.fetchNodes([targetNodeId]);
        final pageNode =
            pageData['nodes'][targetNodeId]['document'] as Map<String, dynamic>;
        final section = _findSection(pageNode, sectionName);
        if (section == null) {
          stderr.writeln('오류: SECTION "$sectionName" 없음');
          exit(1);
        }
        targetNodeId = section['id'] as String;
        targetName = section['name'] as String;
      }
    }

    stdout.writeln('🎯 추출 대상');
    stdout.writeln('   File: $fileKey');
    stdout.writeln('   Node: $targetNodeId');
    if (targetName != null) stdout.writeln('   Name: $targetName');
    stdout.writeln();

    // 노드 fetch
    stdout.writeln('📡 노드 정보 가져오는 중...');
    final nodeData = await api.fetchNodes([targetNodeId!]);
    final rootNode =
        nodeData['nodes'][targetNodeId]['document'] as Map<String, dynamic>;
    targetName ??= rootNode['name'] as String;

    // 자식 frame 수집
    final frames = <Map<String, dynamic>>[];
    final sectionMap = <String, String>{};
    final children = (rootNode['children'] as List?) ?? [];
    _collectFrames(children, frames, sectionMap, currentSection: null);

    // root 자체가 FRAME/COMPONENT면 그것도 포함
    if ((rootNode['type'] == 'FRAME' || rootNode['type'] == 'COMPONENT') &&
        frames.isEmpty) {
      frames.add(rootNode);
    }

    if (frames.isEmpty) {
      stderr.writeln('⚠️  추출할 frame이 없습니다');
      exit(1);
    }

    // --include-ids / --exclude-ids 필터링
    final includeIds = _argValue(
      args,
      '--include-ids',
    )?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
    final excludeIds = _argValue(
      args,
      '--exclude-ids',
    )?.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

    if (includeIds != null && includeIds.isNotEmpty) {
      frames.removeWhere((f) => !includeIds.contains(f['id']));
      stdout.writeln('🔎 --include-ids: ${frames.length}개로 필터링됨');
    }
    if (excludeIds != null && excludeIds.isNotEmpty) {
      final before = frames.length;
      frames.removeWhere((f) => excludeIds.contains(f['id']));
      stdout.writeln(
        '🚫 --exclude-ids: ${before - frames.length}개 제외됨 (남은 ${frames.length}개)',
      );
    }

    if (frames.isEmpty) {
      stderr.writeln('⚠️  필터링 후 추출할 frame이 없습니다');
      exit(1);
    }

    // Dry Run 분석
    final analyses = frames.map((f) => _analyzeFrame(f, manualScale)).toList();

    stdout.writeln('📋 추출 예정 (총 ${frames.length}개 frame):');

    // 카테고리별 집계
    final byCategory = <String, int>{};
    for (final a in analyses) {
      byCategory[a.category] = (byCategory[a.category] ?? 0) + 1;
    }
    const categoryLabels = {
      'policy': '🟢 정책/다이어그램',
      'ui_mockup': '🟡 UI mockup (모바일 사이즈)',
      'icon': '⚪ 아이콘 (< 200×200)',
      'large_diagram': '🔴 큰 다이어그램 (> 8000px)',
      'auto': '⚫ 자동 이름 (Frame 123 등)',
    };
    const categoryIcons = {
      'policy': '🟢',
      'ui_mockup': '🟡',
      'icon': '⚪',
      'large_diagram': '🔴',
      'auto': '⚫',
    };
    stdout.writeln('   📊 분류:');
    for (final entry in categoryLabels.entries) {
      final count = byCategory[entry.key] ?? 0;
      if (count > 0) {
        stdout.writeln('      ${entry.value}: ${count}개');
      }
    }
    stdout.writeln();

    for (var i = 0; i < frames.length; i++) {
      final a = analyses[i];
      final id = frames[i]['id'];
      final w = a.warning != null ? ' ⚠️  ${a.warning}' : '';
      final cat = categoryIcons[a.category] ?? '◯';
      stdout.writeln(
        '   [${i + 1}] $cat $id  ${frames[i]['name']} (${a.width}x${a.height}, scale ${a.scale})$w',
      );
    }

    final largeFrames = <int>[];
    for (var i = 0; i < analyses.length; i++) {
      if (analyses[i].requiresDecomp) largeFrames.add(i);
    }
    if (largeFrames.isNotEmpty) {
      stdout.writeln('\n   🔴 분해 권장: ${largeFrames.length}개 (sub-agent 위임 추천)');
      stdout.writeln('   분해 권장 ID:');
      for (final i in largeFrames) {
        stdout.writeln('     - ${frames[i]['id']}  (${frames[i]['name']})');
      }
    }

    if (dryRun) {
      stdout.writeln('\n💡 Dry Run 모드 — 실제 추출 안 함');
      return;
    }

    // 출력 폴더 (--out-direct면 outDir을 그대로 사용)
    final outDirect = args.contains('--out-direct');
    final forceOverwrite = args.contains('--force-overwrite');
    final dir = outDirect
        ? Directory(outDir)
        : Directory('$outDir/${_toSafeDirName(targetName)}');
    await dir.create(recursive: true);
    stdout.writeln('\n📁 출력: ${dir.path}');
    if (!forceOverwrite) {
      stdout.writeln('   🔒 기존 MD/README 보호 모드 (새로 생성되면 .new.md 접미사)');
    }
    stdout.writeln();

    // 각 frame export
    final usedNames = <String, int>{};
    final extractionLog = <Map<String, dynamic>>[];

    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final analysis = analyses[i];
      final id = frame['id'] as String;
      final name = (frame['name'] as String?) ?? id;

      final baseName = _toSafeFileName(name);
      final count = usedNames[baseName] ?? 0;
      final fileName = count == 0 ? baseName : '${baseName}_${count + 1}';
      usedNames[baseName] = count + 1;

      stdout.writeln('🔍 [${i + 1}/${frames.length}] $name');

      String? imageFile;
      String? treeFile;
      String? mdFile;

      // PNG export
      try {
        stdout.writeln('   🖼️  PNG (scale ${analysis.scale})...');
        final urls = await api.exportImages([id], scale: analysis.scale);
        final imgUrl = urls[id];
        if (imgUrl != null && imgUrl.toString().isNotEmpty) {
          final imgFileObj = File('${dir.path}/$fileName.png');
          await api.downloadFile(imgUrl.toString(), imgFileObj);
          imageFile = '$fileName.png';
          stdout.writeln('      ✅ $imageFile');
        } else {
          stderr.writeln('      ❌ PNG URL 없음');
        }
      } catch (e) {
        stderr.writeln('      ❌ PNG 실패: $e');
      }

      // tree.json + md.skeleton + texts.json + typography.md
      String? textsFile;
      String? typographyFile;
      FrameScale? frameScale;
      try {
        stdout.writeln('   🌳 tree.json...');
        final fullData = await api.fetchNodes([id]);
        final fullNode =
            fullData['nodes'][id]['document'] as Map<String, dynamic>;

        // 프레임 스케일 감지 (bbox-heuristic) — 이후 _extractTree 정규화에 사용.
        frameScale = _detectScale(fullNode);
        if (frameScale.isScaled) {
          stdout.writeln(
            '      🔍 스케일 왜곡 감지: ${frameScale.scale}× from ${frameScale.baseWidth.toInt()}-base (${frameScale.confidence})',
          );
        }

        final tree = _extractTree(fullNode, scale: frameScale);
        // 루트에 scale 메타 주입
        tree['_meta'] = {
          'frameScale': frameScale.toJson(),
          'extractedAt': DateTime.now().toIso8601String(),
          'extractorVersion': 2,
        };

        final treeFileObj = File('${dir.path}/$fileName.tree.json');
        await treeFileObj.writeAsString(
          const JsonEncoder.withIndent('  ').convert(tree),
        );
        treeFile = '$fileName.tree.json';
        stdout.writeln('      ✅ $treeFile');

        // texts.json: 모든 TEXT 노드 평탄화 카탈로그
        stdout.writeln('   📇 texts.json...');
        final textCatalog = _buildTextCatalog(tree);
        final textsFileObj = File('${dir.path}/$fileName.texts.json');
        await textsFileObj.writeAsString(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({'frameScale': frameScale.toJson(), 'texts': textCatalog}),
        );
        textsFile = '$fileName.texts.json';
        stdout.writeln('      ✅ $textsFile (${textCatalog.length}개 TEXT 노드)');

        // typography.md: unique style 그룹 요약
        stdout.writeln('   🔠 typography.md...');
        final typography = _buildTypographyMd(textCatalog, frameScale);
        final typographyFileObj = File('${dir.path}/$fileName.typography.md');
        await typographyFileObj.writeAsString(typography);
        typographyFile = '$fileName.typography.md';
        stdout.writeln('      ✅ $typographyFile');

        stdout.writeln('   📝 md.skeleton...');
        final skeleton = _generateSkeleton(
          tree,
          fileKey,
          analysis.scale,
          imageFile: imageFile,
          frameScale: frameScale,
        );
        final mdFileObj = File('${dir.path}/$fileName.md');
        if (mdFileObj.existsSync() && !forceOverwrite) {
          final newMdFile = File('${dir.path}/$fileName.new.md');
          await newMdFile.writeAsString(skeleton);
          mdFile = '$fileName.new.md';
          stdout.writeln('      🔒 기존 MD 보호 → $fileName.new.md');
        } else {
          await mdFileObj.writeAsString(skeleton);
          mdFile = '$fileName.md';
          stdout.writeln('      ✅ $mdFile');
        }
      } catch (e) {
        stderr.writeln('      ❌ tree/md 실패: $e');
      }

      extractionLog.add({
        'name': name,
        'id': id,
        'imageFile': imageFile,
        'treeFile': treeFile,
        'mdFile': mdFile,
        'textsFile': textsFile,
        'typographyFile': typographyFile,
        'scale': analysis.scale,
        'width': analysis.width,
        'height': analysis.height,
        'warning': analysis.warning,
        'requiresDecomp': analysis.requiresDecomp,
        if (frameScale != null && frameScale.isScaled)
          'frameScaleWarning':
              '${frameScale.scale}x from ${frameScale.baseWidth.toInt()}-base',
      });

      stdout.writeln();
    }

    // 추출 로그
    final logFile = File('${dir.path}/.extraction-log.json');
    await logFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'extractedAt': DateTime.now().toIso8601String(),
        'fileKey': fileKey,
        'rootNodeId': targetNodeId,
        'rootName': targetName,
        'tool': 'extract_doc.dart',
        'frames': extractionLog,
      }),
    );
    stdout.writeln('📋 .extraction-log.json 저장');

    // README 자동 생성
    final readme = _generateFolderReadme(
      targetName,
      fileKey,
      targetNodeId,
      extractionLog,
    );
    final readmeFile = File('${dir.path}/README.md');
    if (readmeFile.existsSync() && !forceOverwrite) {
      final newReadmeFile = File('${dir.path}/README.new.md');
      await newReadmeFile.writeAsString(readme);
      stdout.writeln('🔒 기존 README 보호 → README.new.md');
    } else {
      await readmeFile.writeAsString(readme);
      stdout.writeln('📚 README.md 저장');
    }

    stdout.writeln('\n✅ 완료: ${dir.path}');
  } finally {
    client.close();
  }
}

// ─── Frame 분석 (Dry Run + scale 자동 계산) ────────────────────

class FrameAnalysis {
  final num width;
  final num height;
  final double scale;
  final String? warning;
  final bool requiresDecomp;
  final String category; // policy | ui_mockup | icon | large_diagram | auto

  FrameAnalysis({
    required this.width,
    required this.height,
    required this.scale,
    required this.category,
    this.warning,
    this.requiresDecomp = false,
  });
}

/// Frame 분류 휴리스틱.
/// - large_diagram: maxDim > 8000px (sub-agent 분해 필요)
/// - ui_mockup: 모바일 사이즈 (375/390/414/430 × 600~1000)
/// - icon: < 200×200 (작은 아이콘/버튼)
/// - auto: Frame/Group + 숫자 자동 이름
/// - policy: 그 외 (정책 문서, 다이어그램)
String _classifyFrame(Map<String, dynamic> frame) {
  final bbox = frame['absoluteBoundingBox'] as Map<String, dynamic>?;
  final w = (bbox?['width'] as num?) ?? 0;
  final h = (bbox?['height'] as num?) ?? 0;
  final name = (frame['name'] as String?) ?? '';
  final maxDim = math.max(w, h);

  if (maxDim > 8000) return 'large_diagram';

  // 표준 모바일 UI mockup (375/390/414/430 × 600~1000)
  const mobileWidths = [375, 390, 414, 430];
  final isMobileWidth = mobileWidths.any((mw) => (w - mw).abs() < 10);
  if (isMobileWidth && h > 600 && h < 1000) return 'ui_mockup';

  // 작은 세로 mockup (너비 < 200 + 세로 비율 ≥ 1.8) — chatbot multi 등
  if (w > 0 && w < 200 && h >= 200 && h < 600 && (h / w) >= 1.8) {
    return 'ui_mockup';
  }

  if (w < 200 && h < 200) return 'icon';

  if (RegExp(r'^(Frame|Group|Rectangle) ?\d+$').hasMatch(name)) return 'auto';

  return 'policy';
}

FrameAnalysis _analyzeFrame(Map<String, dynamic> frame, String? manualScale) {
  final bbox = frame['absoluteBoundingBox'] as Map<String, dynamic>?;
  final w = (bbox?['width'] as num?) ?? 1000;
  final h = (bbox?['height'] as num?) ?? 1000;
  final maxDim = math.max(w, h);

  double scale;
  if (manualScale != null) {
    scale = double.tryParse(manualScale) ?? 1.0;
  } else {
    final maxScale = _maxImageSide / maxDim;
    scale = (maxScale * _safetyMargin).clamp(0.05, 4.0);
    // 일반 frame은 너무 크게 export할 필요 없음
    if (maxDim < 5000) scale = scale.clamp(0.05, 2.0);
  }

  final warnings = <String>[];
  bool requiresDecomp = false;

  if (maxDim > 8000) {
    warnings.add('큰 다이어그램 (${maxDim.round()}px)');
    requiresDecomp = true;
  }

  final smallTextCount = _countSmallText(frame, scale);
  if (smallTextCount > 5) {
    warnings.add('${smallTextCount}개 텍스트 < ${_minReadableTextPx}px (가독성↓)');
    requiresDecomp = true;
  }

  return FrameAnalysis(
    width: w.round(),
    height: h.round(),
    scale: double.parse(scale.toStringAsFixed(2)),
    warning: warnings.isEmpty ? null : warnings.join(' / '),
    requiresDecomp: requiresDecomp,
    category: _classifyFrame(frame),
  );
}

int _countSmallText(Map<String, dynamic> node, double scale) {
  var count = 0;
  void walk(Map<String, dynamic> n) {
    if (n['type'] == 'TEXT') {
      final fontSize = (n['style'] as Map?)?['fontSize'] as num?;
      if (fontSize != null && fontSize * scale < _minReadableTextPx) {
        count++;
      }
    }
    final children = n['children'] as List?;
    if (children != null) {
      for (final c in children) {
        walk(c as Map<String, dynamic>);
      }
    }
  }

  walk(node);
  return count;
}

// ─── 트리 추출 (텍스트 + 좌표 + 타이포 + 레이아웃 + 시각 속성) ──

/// Figma 노드를 tree.json 친화 구조로 변환.
///
/// v2 스키마 (2026-04-21): auto-layout / 타이포 풀 세트 / fills / effects /
/// cornerRadius 저장. 기존 스키마와 호환 (기존 key는 유지).
Map<String, dynamic> _extractTree(
  Map<String, dynamic> node, {
  FrameScale? scale,
}) {
  final tree = <String, dynamic>{
    'id': node['id'],
    'name': node['name'],
    'type': node['type'],
  };

  // 공통: visibility / opacity / blendMode
  if (node['visible'] == false) tree['visible'] = false;
  final opacity = node['opacity'];
  if (opacity is num && opacity < 1.0) tree['opacity'] = _round(opacity);
  final blendMode = node['blendMode'] as String?;
  if (blendMode != null && blendMode != 'PASS_THROUGH') {
    tree['blendMode'] = blendMode;
  }

  final bbox = node['absoluteBoundingBox'] as Map?;
  if (bbox != null) {
    tree['bbox'] = {
      'x': _round(bbox['x']),
      'y': _round(bbox['y']),
      'w': _round(bbox['width']),
      'h': _round(bbox['height']),
    };
  }

  // relativeTransform (있을 때만) — 부모 대비 affine
  final rt = node['relativeTransform'];
  if (rt is List) tree['relativeTransform'] = rt;

  // ─── TEXT 전용 ───────────────────────
  if (node['type'] == 'TEXT') {
    final style = (node['style'] as Map?) ?? const {};
    final chars = node['characters'] as String?;
    final fontSize = style['fontSize'] as num?;
    final color = _extractPrimaryColor(node);
    final fakeBold = _detectFakeBold(node);

    tree['text'] = {
      'characters': chars,
      'fontFamily': style['fontFamily'],
      'fontPostScriptName': style['fontPostScriptName'],
      'fontWeight': style['fontWeight'],
      'italic': style['italic'] == true ? true : null,
      'fontSize': fontSize,
      if (scale != null && scale.isScaled && fontSize != null)
        'fontSizeNormalized': _round(fontSize / scale.scale),
      'lineHeightPx': style['lineHeightPx'],
      'lineHeightPercent': style['lineHeightPercent'],
      'lineHeightUnit': style['lineHeightUnit'],
      'letterSpacing': style['letterSpacing'],
      'paragraphSpacing': style['paragraphSpacing'],
      'paragraphIndent': style['paragraphIndent'],
      'textAlignHorizontal': style['textAlignHorizontal'],
      'textAlignVertical': style['textAlignVertical'],
      'textCase': style['textCase'],
      'textDecoration': style['textDecoration'],
      'textAutoResize': style['textAutoResize'],
      if (color != null) 'color': color,
      if (fakeBold != null) 'fakeBold': fakeBold,
    }..removeWhere((k, v) => v == null);
  }

  // ─── 컨테이너: auto-layout / visual ──
  final type = node['type'] as String?;
  final isContainer =
      type == 'FRAME' ||
      type == 'COMPONENT' ||
      type == 'COMPONENT_SET' ||
      type == 'INSTANCE' ||
      type == 'GROUP' ||
      type == 'SECTION';

  if (isContainer) {
    final layoutMode = node['layoutMode'] as String?;
    if (layoutMode != null && layoutMode != 'NONE') {
      final layout = <String, dynamic>{
        'mode': layoutMode,
        if (node['itemSpacing'] != null) 'itemSpacing': node['itemSpacing'],
        if (node['counterAxisSpacing'] != null)
          'counterAxisSpacing': node['counterAxisSpacing'],
        if (node['primaryAxisAlignItems'] != null)
          'primaryAxisAlign': node['primaryAxisAlignItems'],
        if (node['counterAxisAlignItems'] != null)
          'counterAxisAlign': node['counterAxisAlignItems'],
        if (node['primaryAxisSizingMode'] != null)
          'primarySizing': node['primaryAxisSizingMode'],
        if (node['counterAxisSizingMode'] != null)
          'counterSizing': node['counterAxisSizingMode'],
        if (node['layoutSizingHorizontal'] != null)
          'sizingH': node['layoutSizingHorizontal'],
        if (node['layoutSizingVertical'] != null)
          'sizingV': node['layoutSizingVertical'],
        if (node['layoutWrap'] != null) 'wrap': node['layoutWrap'],
      };
      // padding (0이 아닌 것만)
      final pad = {
        't': node['paddingTop'],
        'r': node['paddingRight'],
        'b': node['paddingBottom'],
        'l': node['paddingLeft'],
      }..removeWhere((k, v) => v == null || (v is num && v == 0));
      if (pad.isNotEmpty) layout['padding'] = pad;

      if (scale != null && scale.isScaled) {
        final sp = layout['itemSpacing'];
        if (sp is num)
          layout['itemSpacingNormalized'] = _round(sp / scale.scale);
      }
      tree['layout'] = layout;
    }

    if (node['clipsContent'] == true) tree['clipsContent'] = true;
  }

  // fills — 컨테이너/TEXT/RECTANGLE 공통
  final fills = node['fills'];
  if (fills is List && fills.isNotEmpty) {
    final summary = _summarizeFills(fills);
    if (summary.isNotEmpty) tree['fills'] = summary;
  }

  // strokes (stroke가 있는 경우에만)
  final strokes = node['strokes'];
  if (strokes is List && strokes.isNotEmpty) {
    tree['strokes'] = _summarizeFills(strokes);
    if (node['strokeWeight'] != null) {
      tree['strokeWeight'] = node['strokeWeight'];
    }
  }

  // cornerRadius (균일 or 개별)
  if (node['cornerRadius'] != null) {
    tree['cornerRadius'] = node['cornerRadius'];
  }
  if (node['rectangleCornerRadii'] != null) {
    tree['rectangleCornerRadii'] = node['rectangleCornerRadii'];
  }

  // effects (shadow/blur)
  final effects = node['effects'];
  if (effects is List && effects.isNotEmpty) {
    final visible = effects
        .where((e) => (e as Map)['visible'] != false)
        .map((e) => _summarizeEffect(e as Map<String, dynamic>))
        .toList();
    if (visible.isNotEmpty) tree['effects'] = visible;
  }

  // Prototype Mode 정보 (전환 대상, 애니메이션)
  if (node['transitionNodeID'] != null) {
    tree['prototype'] = {
      'transitionNodeID': node['transitionNodeID'],
      if (node['transitionDuration'] != null)
        'transitionDuration': node['transitionDuration'],
      if (node['transitionEasing'] != null)
        'transitionEasing': node['transitionEasing'],
    };
  }

  // 인터랙션 정보 (있으면)
  final interactions = node['interactions'] as List?;
  if (interactions != null && interactions.isNotEmpty) {
    tree['interactions'] = interactions;
  }

  // Dev Mode 어노테이션 (있으면). TEXT 뿐 아니라 VECTOR/FRAME/INSTANCE 등 어느 타입에도 붙는다 —
  // 기획 정책이 여기에만 적힌 경우가 있어(마이 닉네임·출생연도) 빠뜨리면 texts.json grep 으로도 못 찾는다.
  final annotations = node['annotations'] as List?;
  if (annotations != null && annotations.isNotEmpty) {
    tree['annotations'] = annotations;
  }

  final children = node['children'] as List?;
  if (children != null && children.isNotEmpty) {
    tree['children'] = children
        .map((c) => _extractTree(c as Map<String, dynamic>, scale: scale))
        .toList();
  }

  return tree;
}

/// fills 배열을 요약. SOLID/GRADIENT/IMAGE 각 타입별 핵심만.
List<Map<String, dynamic>> _summarizeFills(List<dynamic> fills) {
  final out = <Map<String, dynamic>>[];
  for (final raw in fills) {
    if (raw is! Map) continue;
    final f = raw as Map<String, dynamic>;
    if (f['visible'] == false) continue;
    final type = f['type'] as String?;
    final entry = <String, dynamic>{
      'type': type,
      if (f['blendMode'] != null && f['blendMode'] != 'NORMAL')
        'blendMode': f['blendMode'],
      if (f['opacity'] != null) 'opacity': f['opacity'],
    };
    switch (type) {
      case 'SOLID':
        final c = f['color'];
        if (c is Map) entry['color'] = _rgbaToHex(c, f['opacity']);
        break;
      case 'GRADIENT_LINEAR':
      case 'GRADIENT_RADIAL':
      case 'GRADIENT_ANGULAR':
      case 'GRADIENT_DIAMOND':
        entry['handlePositions'] = f['gradientHandlePositions'];
        entry['stops'] = (f['gradientStops'] as List?)
            ?.map(
              (s) => {
                'position': _round((s as Map)['position']),
                'color': _rgbaToHex(s['color'] as Map?, null),
              },
            )
            .toList();
        break;
      case 'IMAGE':
        entry['imageRef'] = f['imageRef'];
        entry['scaleMode'] = f['scaleMode'];
        break;
    }
    out.add(entry);
  }
  return out;
}

Map<String, dynamic> _summarizeEffect(Map<String, dynamic> e) {
  return {
    'type': e['type'],
    if (e['color'] is Map) 'color': _rgbaToHex(e['color'] as Map, null),
    if (e['offset'] is Map)
      'offset': {
        'x': _round((e['offset'] as Map)['x']),
        'y': _round((e['offset'] as Map)['y']),
      },
    if (e['radius'] != null) 'radius': e['radius'],
    if (e['spread'] != null) 'spread': e['spread'],
    if (e['blendMode'] != null && e['blendMode'] != 'NORMAL')
      'blendMode': e['blendMode'],
  };
}

/// TEXT 노드의 대표 색상: node.fills[0] 우선 → style.fills[0] fallback.
String? _extractPrimaryColor(Map<String, dynamic> node) {
  List<dynamic>? fills = node['fills'] as List<dynamic>?;
  if (fills == null || fills.isEmpty) {
    final style = node['style'] as Map<String, dynamic>?;
    fills = style?['fills'] as List<dynamic>?;
  }
  if (fills == null || fills.isEmpty) return null;
  for (final raw in fills) {
    if (raw is! Map) continue;
    if (raw['visible'] == false) continue;
    if (raw['type'] == 'SOLID' && raw['color'] is Map) {
      return _rgbaToHex(raw['color'] as Map<dynamic, dynamic>, raw['opacity']);
    }
  }
  return null;
}

/// TEXT 노드의 "fake bold" 패턴 감지 (하이브리드 + confidence).
///
/// 디자이너 트릭: Bold variant이 없는 폰트(픽셀 폰트 등)에서 fill과 같은/유사한
/// 색의 얇은 stroke (≤1px, 보통 0.2)를 얹어 글자가 두꺼워 보이게 만드는 기법.
///
/// 판정 로직 (strokeWeight 기반 우선):
/// - sw > 1.0 → null (outline/border 의도)
/// - sw ≤ 0.3 → fake-bold 거의 확실. 색 매칭: high / 미스매치: medium
///   (아주 얇은 stroke를 TEXT에 장식 목적으로 쓰는 경우는 극히 드묾)
/// - 0.3 < sw ≤ 1.0 → 색 매칭 필수. 매칭: medium / 미스매치: null
///
/// 색 비교 관용도: ±10/255 (디자이너가 팔레트 내 유사 색을 쓰는 경우 허용).
Map<String, dynamic>? _detectFakeBold(Map<String, dynamic> node) {
  if (node['type'] != 'TEXT') return null;

  final strokes = node['strokes'];
  if (strokes is! List || strokes.isEmpty) return null;

  Map<dynamic, dynamic>? strokePaint;
  for (final s in strokes) {
    if (s is! Map) continue;
    if (s['visible'] == false) continue;
    if (s['type'] != 'SOLID') continue;
    strokePaint = s;
    break;
  }
  if (strokePaint == null) return null;

  final sw = node['strokeWeight'];
  if (sw is! num) return null;
  if (sw <= 0 || sw > 1.0) return null;

  final strokeColor = _rgbaToHex(
    strokePaint['color'] as Map?,
    strokePaint['opacity'],
  );
  final fillColor = _extractPrimaryColor(node);
  if (fillColor == null) return null;

  final colorsClose = _colorsApproxEqual(fillColor, strokeColor, 10);

  String confidence;
  String reason;
  if (sw <= 0.3) {
    if (colorsClose) {
      confidence = 'high';
      reason = 'thin stroke + colors match';
    } else {
      confidence = 'medium';
      reason = 'thin stroke (strong signal), but fill/stroke colors differ';
    }
  } else {
    // 0.3 < sw ≤ 1.0
    if (!colorsClose) return null; // 장식용 stroke 가능성 — 제외
    confidence = 'medium';
    reason = 'moderate stroke, colors match';
  }

  return {
    'strokeWidth': sw,
    'strokeColor': strokeColor,
    'fillColor': fillColor,
    'strokeAlign': node['strokeAlign'], // CENTER | OUTSIDE | INSIDE
    'confidence': confidence,
    'reason': reason,
    'hint':
        'fake-bold — Flutter 구현: FakeBoldText(data, style: ..., strokeWidth: $sw)',
  };
}

/// 두 hex 색상이 채널별 ±tolerance/255 이내 같은지. 대소문자/# 유무 무관.
bool _colorsApproxEqual(String a, String b, [int tolerance = 2]) {
  int? chan(String hex, int i) {
    final h = hex.replaceFirst('#', '');
    if (h.length < 6) return null;
    return int.tryParse(h.substring(i, i + 2), radix: 16);
  }

  for (var i = 0; i < 6; i += 2) {
    final ca = chan(a, i);
    final cb = chan(b, i);
    if (ca == null || cb == null) return false;
    if ((ca - cb).abs() > tolerance) return false;
  }
  return true;
}

/// Figma {r,g,b,a} (0~1 float) + optional paint.opacity → `#RRGGBBAA`.
String _rgbaToHex(Map<dynamic, dynamic>? color, dynamic paintOpacity) {
  if (color == null) return '';
  double f(dynamic v) => ((v as num?)?.toDouble() ?? 0).clamp(0, 1);
  final r = (f(color['r']) * 255).round();
  final g = (f(color['g']) * 255).round();
  final b = (f(color['b']) * 255).round();
  final aRaw = f(color['a']);
  final pOpacity = paintOpacity is num ? paintOpacity.toDouble() : 1.0;
  final a = (aRaw * pOpacity.clamp(0, 1) * 255).round().clamp(0, 255);
  String hex(int n) => n.toRadixString(16).padLeft(2, '0');
  final base = '${hex(r)}${hex(g)}${hex(b)}';
  return a == 255 ? '#$base' : '#$base${hex(a)}';
}

// ─── 프레임 스케일 감지 (bbox-heuristic) ───────────────────────

/// 루트 프레임이 "디자인 의도 폭"에서 얼마나 스케일됐는지 추정.
/// 예: bbox 357.63 → base 375면 scale=0.9537, fontSize 14.3 → 정상화 15.0.
class FrameScale {
  final double scale;
  final double baseWidth;
  final String confidence; // high | medium | low | unknown
  final String method; // bbox-heuristic | relativeTransform | identity
  final int fontSizeSamples;

  const FrameScale({
    required this.scale,
    required this.baseWidth,
    required this.confidence,
    required this.method,
    this.fontSizeSamples = 0,
  });

  factory FrameScale.identity() => const FrameScale(
    scale: 1.0,
    baseWidth: 0,
    confidence: 'unknown',
    method: 'identity',
  );

  bool get isScaled => (scale - 1.0).abs() > 0.01;

  Map<String, dynamic> toJson() => {
    'scale': _round(scale),
    'baseWidth': baseWidth == 0 ? null : baseWidth,
    'method': method,
    'confidence': confidence,
    'fontSizeSamples': fontSizeSamples,
  }..removeWhere((k, v) => v == null);
}

/// 프레임 스케일 감지:
/// 1) 후보 base 폭(375/390/393/414/428/360) 각각에 대해 scale 계산.
/// 2) 해당 scale로 descendant TEXT의 fontSize를 나눈 normalized 값이 얼마나
///    정수 근사인지 점수화.
/// 3) 가장 점수 좋은 base를 선택.
FrameScale _detectScale(Map<String, dynamic> rootNode) {
  final bbox = rootNode['absoluteBoundingBox'] as Map?;
  final w = (bbox?['width'] as num?)?.toDouble() ?? 0;
  if (w == 0) return FrameScale.identity();

  // 풀 페이지 프레임에만 적용 (작은 sub-frame은 부모 스케일 상속이 맞음).
  // 300~500px 범위만 mobile 풀 페이지로 간주.
  if (w < 300 || w > 500) return FrameScale.identity();

  final fontSizes = <double>[];
  void walk(Map<String, dynamic> n) {
    if (n['type'] == 'TEXT') {
      final fs = (n['style'] as Map?)?['fontSize'];
      if (fs is num) fontSizes.add(fs.toDouble());
    }
    final children = n['children'] as List?;
    if (children == null) return;
    for (final c in children) {
      walk(c as Map<String, dynamic>);
    }
  }

  walk(rootNode);
  if (fontSizes.isEmpty) return FrameScale.identity();

  const candidateBases = [360.0, 375.0, 390.0, 393.0, 414.0, 428.0];

  FrameScale best = FrameScale.identity();
  double bestScore = double.infinity;

  for (final base in candidateBases) {
    final scale = w / base;
    if (scale < 0.5 || scale > 2.0) continue;

    double sum = 0;
    var n = 0;
    for (final fs in fontSizes) {
      final norm = fs / scale;
      final rounded = norm.round();
      if (rounded == 0) continue;
      sum += (norm - rounded).abs() / rounded;
      n++;
    }
    if (n == 0) continue;
    final score = sum / n;

    if (score < bestScore) {
      bestScore = score;
      String conf;
      if (score < 0.005) {
        conf = 'high';
      } else if (score < 0.02) {
        conf = 'medium';
      } else {
        conf = 'low';
      }
      best = FrameScale(
        scale: scale,
        baseWidth: base,
        confidence: conf,
        method: 'bbox-heuristic',
        fontSizeSamples: n,
      );
    }
  }

  // 스케일 1.0 근처이면 identity로
  if ((best.scale - 1.0).abs() < 0.01) {
    return FrameScale(
      scale: 1.0,
      baseWidth: best.baseWidth,
      confidence: best.confidence,
      method: best.method,
      fontSizeSamples: best.fontSizeSamples,
    );
  }
  return best;
}

// ─── 텍스트 카탈로그 (texts.json + typography.md) ──────────────

/// tree를 평탄화해서 모든 TEXT 노드를 한 배열로.
List<Map<String, dynamic>> _buildTextCatalog(
  Map<String, dynamic> tree, {
  List<String>? path,
  Map<String, dynamic>? parent,
}) {
  final out = <Map<String, dynamic>>[];
  final currentPath = <String>[
    ...(path ?? const []),
    (tree['name']?.toString() ?? tree['id']?.toString() ?? '?'),
  ];

  if (tree['type'] == 'TEXT' && tree['text'] is Map) {
    final t = tree['text'] as Map<String, dynamic>;
    final parentLayout = parent?['layout'] as Map?;
    out.add(
      {
        'id': tree['id'],
        'path': currentPath.join(' / '),
        'characters': t['characters'],
        'fontFamily': t['fontFamily'],
        'fontWeight': t['fontWeight'],
        'fontSize': t['fontSize'],
        if (t['fontSizeNormalized'] != null)
          'fontSizeNormalized': t['fontSizeNormalized'],
        'lineHeightPx': t['lineHeightPx'],
        'lineHeightUnit': t['lineHeightUnit'],
        'letterSpacing': t['letterSpacing'],
        'paragraphSpacing': t['paragraphSpacing'],
        'textAlignHorizontal': t['textAlignHorizontal'],
        'textCase': t['textCase'],
        'textDecoration': t['textDecoration'],
        'color': t['color'],
        if (t['fakeBold'] != null) 'fakeBold': t['fakeBold'],
        if (parentLayout != null) 'parentLayout': parentLayout,
        'bbox': tree['bbox'],
      }..removeWhere((k, v) => v == null),
    );
  }

  final children = tree['children'] as List?;
  if (children != null) {
    for (final c in children) {
      out.addAll(
        _buildTextCatalog(
          c as Map<String, dynamic>,
          path: currentPath,
          parent: tree,
        ),
      );
    }
  }
  return out;
}

/// 유니크한 타이포 스타일 튜플별로 집계.
String _buildTypographyMd(
  List<Map<String, dynamic>> catalog,
  FrameScale scale,
) {
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final t in catalog) {
    // 정규화 fontSize 있으면 그걸 키에 쓰고 괄호로 raw 병기
    final fsRaw = t['fontSize'];
    final fsNorm = t['fontSizeNormalized'];
    final fakeBold = t['fakeBold'] as Map?;
    final key = [
      t['fontFamily'] ?? '?',
      fsNorm ?? fsRaw ?? '?',
      t['fontWeight'] ?? '?',
      t['lineHeightPx'] ?? '?',
      t['textAlignHorizontal'] ?? '?',
      t['color'] ?? '?',
      fakeBold != null ? 'fb${fakeBold['strokeWidth']}' : '',
    ].join('|');
    groups.putIfAbsent(key, () => []).add(t);
  }

  final sortedEntries = groups.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));

  final buf = StringBuffer();
  buf.writeln('# Typography Catalog');
  buf.writeln();
  if (scale.isScaled) {
    final inv = _round(1.0 / scale.scale);
    buf.writeln(
      '> ⚠️ **프레임 스케일 왜곡 감지**: `${scale.scale}×` from base `${scale.baseWidth.toInt()}` (confidence: ${scale.confidence}).',
    );
    buf.writeln('> → raw fontSize × $inv = 디자이너 의도 값. 아래 표는 `정규화/raw` 순서.');
    buf.writeln();
  }
  buf.writeln(
    '| 사용횟수 | font | size | weight | lineHeight | align | color | ⚡fake-bold | Flutter 구현 힌트 | 예시 |',
  );
  buf.writeln('|---|---|---|---|---|---|---|---|---|---|');
  for (final entry in sortedEntries) {
    final items = entry.value;
    final t = items.first;
    final sizeCell = t['fontSizeNormalized'] != null
        ? '${_fmtNum(t['fontSizeNormalized'])} (raw ${_fmtNum(t['fontSize'])})'
        : _fmtNum(t['fontSize']);
    final example = (t['characters']?.toString() ?? '')
        .replaceAll('\n', ' ')
        .trim();
    final exampleShort = example.length > 24
        ? '${example.substring(0, 24)}…'
        : example;
    final fb = t['fakeBold'] as Map?;
    final fbCell = fb != null
        ? 'stroke ${_fmtNum(fb['strokeWidth'])} · ${fb['strokeAlign'] ?? '?'} · ${fb['confidence']}'
        : '—';
    final flutterHint = fb != null
        ? '`FakeBoldText(strokeWidth: ${_fmtNum(fb['strokeWidth'])})`'
        : '`Text`';
    buf.writeln(
      '| ${items.length} | ${t['fontFamily'] ?? '?'} | '
      '$sizeCell | ${_fmtNum(t['fontWeight'])} | ${_fmtNum(t['lineHeightPx'])} | '
      '${t['textAlignHorizontal'] ?? '?'} | `${t['color'] ?? '?'}` | $fbCell | $flutterHint | $exampleShort |',
    );
  }
  buf.writeln();
  buf.writeln('## 전체 텍스트 목록 (${catalog.length}개)');
  buf.writeln();
  for (final t in catalog) {
    final chars = (t['characters']?.toString() ?? '').replaceAll('\n', ' ');
    buf.writeln('- **$chars**');
    final specs = <String>[];
    if (t['fontSizeNormalized'] != null) {
      specs.add(
        '${_fmtNum(t['fontSizeNormalized'])}px (raw ${_fmtNum(t['fontSize'])})',
      );
    } else if (t['fontSize'] != null) {
      specs.add('${_fmtNum(t['fontSize'])}px');
    }
    if (t['fontWeight'] != null) specs.add('w${_fmtNum(t['fontWeight'])}');
    if (t['lineHeightPx'] != null) specs.add('lh${_fmtNum(t['lineHeightPx'])}');
    if (t['color'] != null) specs.add('${t['color']}');
    if (t['textAlignHorizontal'] != null) {
      specs.add(t['textAlignHorizontal'].toString());
    }
    buf.writeln('  - ${specs.join(' · ')}');
    buf.writeln('  - path: `${t['path']}`');
  }
  return buf.toString();
}

// ─── MD 골격 생성 (Frame = 헤딩, TEXT = 본문) ────────────────

String _generateSkeleton(
  Map<String, dynamic> tree,
  String fileKey,
  double scale, {
  String? imageFile,
  FrameScale? frameScale,
}) {
  final buf = StringBuffer();

  // Frontmatter
  final id = tree['id'] as String;
  final urlNodeId = id.replaceAll(':', '-');
  buf.writeln('---');
  buf.writeln('figma_file_key: $fileKey');
  buf.writeln('figma_node_id: $id');
  buf.writeln(
    'figma_url: https://www.figma.com/file/$fileKey/?node-id=$urlNodeId',
  );
  buf.writeln('extracted_at: ${DateTime.now().toIso8601String()}');
  buf.writeln('extracted_scale: $scale');
  buf.writeln('extracted_by: extract_doc.dart');
  if (frameScale != null && frameScale.isScaled) {
    buf.writeln(
      'frame_scale_warning: "${frameScale.scale}x from ${frameScale.baseWidth.toInt()}-base"',
    );
  }
  buf.writeln('---');
  buf.writeln();

  buf.writeln('# ${tree['name']}');
  buf.writeln();
  if (imageFile != null) {
    buf.writeln('![${tree['name']}]($imageFile)');
    buf.writeln();
  }

  // 스케일 왜곡 경고 배너 (디자이너 의도 복원 가이드)
  if (frameScale != null && frameScale.isScaled) {
    final inv = _round(1.0 / frameScale.scale);
    buf.writeln(
      '> ⚠️ **프레임 스케일 왜곡 감지** (confidence: ${frameScale.confidence})',
    );
    buf.writeln('>');
    buf.writeln(
      '> 이 프레임의 bbox 폭은 `${tree['bbox']?['w']}px`이지만 디자인 의도는 `${frameScale.baseWidth.toInt()}px` base로 추정됨.',
    );
    buf.writeln(
      '> → 모든 raw fontSize/gap/cornerRadius 에 **× ${inv}** 해야 디자이너 의도 값 복원.',
    );
    buf.writeln('>');
    buf.writeln(
      '> 아래 TEXT 스펙은 `정규화(raw)` 순서로 표시됨. 구현 시 정규화 값을 사용하되, Figma에서 재디자인 시 raw가 맞음.',
    );
    buf.writeln();
  }

  buf.writeln('> 🤖 Figma에서 자동 추출된 골격 — Frame 구조를 따라 생성됨.');
  buf.writeln('> 텍스트가 누락 없이 다 들어있는지 확인 후 의미적으로 다듬어 사용.');
  buf.writeln('> 원본은 위 frontmatter의 figma_url 참조.');
  buf.writeln();

  // Dev Mode 어노테이션 수집 (있으면 별도 섹션 — 기획 정책이 여기에만 적히는 경우가 많아 맨 위에 둔다)
  final annotations = <Map<String, dynamic>>[];
  _collectAnnotations(tree, annotations);
  if (annotations.isNotEmpty) {
    buf.writeln('## 📌 Figma Dev Mode 어노테이션 (${annotations.length}개)');
    buf.writeln();
    buf.writeln(
      '> ⚠️ 기획 정책이 **여기에만** 적혀 있을 수 있다 — TEXT 노드가 아니라 texts.json·본문 어디에도 안 나온다.',
    );
    buf.writeln('> 구현 전 반드시 읽을 것. 원문 그대로이며 요약하지 않았다.');
    buf.writeln();
    for (final a in annotations) {
      final cat = a['categoryId'] != null ? ' · `${a['categoryId']}`' : '';
      buf.writeln(
        '### `${a['hostName']}` (${a['hostType']} · `${a['hostId']}`)$cat',
      );
      buf.writeln();
      for (final line in (a['label'] as String).split('\n')) {
        buf.writeln('> $line');
      }
      buf.writeln();
    }
  }

  // Prototype 인터랙션 수집 (있으면 별도 섹션)
  final interactions = <Map<String, dynamic>>[];
  _collectInteractions(tree, interactions);
  if (interactions.isNotEmpty) {
    buf.writeln('## 🔗 Figma Prototype 인터랙션 (${interactions.length}개)');
    buf.writeln();
    buf.writeln('| From | To | 전환 |');
    buf.writeln('|---|---|---|');
    for (final inter in interactions) {
      final easing = inter['easing'] ?? '';
      final duration = inter['duration'] != null
          ? '${inter['duration']}ms'
          : '';
      final transition = [easing, duration].where((s) => s != '').join(', ');
      buf.writeln(
        '| `${inter['fromName'] ?? inter['from']}` | `${inter['to']}` | $transition |',
      );
    }
    buf.writeln();
    buf.writeln(
      '→ 구현 시 `Navigator.push` / `PageView.animateToPage` / `AnimatedSwitcher` 등 매핑 결정 필요.',
    );
    buf.writeln();
  }

  _writeNodeBody(buf, tree, depth: 2);

  return buf.toString();
}

void _writeNodeBody(
  StringBuffer buf,
  Map<String, dynamic> node, {
  int depth = 2,
}) {
  // TEXT 노드 → 본문 (fontSize/weight로 강조) + 스펙 마커
  if (node['type'] == 'TEXT') {
    final text = node['text'] as Map<String, dynamic>?;
    if (text == null) return;
    final chars = text['characters'] as String? ?? '';
    if (chars.trim().isEmpty) return;

    final size = (text['fontSize'] as num?) ?? 16;
    final weight = (text['fontWeight'] as num?) ?? 400;

    if (size >= 32) {
      final h = '#' * depth.clamp(2, 6);
      buf.writeln('$h $chars');
    } else if (size >= 24 || weight >= 700) {
      buf.writeln('**$chars**');
    } else {
      buf.writeln(chars);
    }

    // 스펙 마커: <sub>15px/w600/lh18 · #fff · center</sub>
    final marker = _buildTextSpecMarker(text);
    if (marker.isNotEmpty) {
      buf.writeln('<sub>$marker</sub>');
    }
    buf.writeln();
    return;
  }

  // 컨테이너 노드 → 의미 있는 이름이면 헤딩
  final name = node['name'] as String?;
  final type = node['type'] as String?;
  final isContainer =
      type == 'FRAME' ||
      type == 'SECTION' ||
      type == 'GROUP' ||
      type == 'INSTANCE' ||
      type == 'COMPONENT';
  final shouldEmitHeading =
      isContainer && name != null && _isMeaningfulName(name);

  if (shouldEmitHeading) {
    final h = '#' * depth.clamp(2, 6);
    buf.writeln('$h $name');
    buf.writeln();
  }

  // auto-layout 요약 블록 (헤딩 없이 노드 시작해도 중요함)
  final layoutSummary = _buildLayoutSummary(node);
  if (layoutSummary.isNotEmpty) {
    buf.writeln('> $layoutSummary');
    buf.writeln();
  }

  final children = node['children'] as List?;
  if (children != null) {
    final nextDepth = shouldEmitHeading ? depth + 1 : depth;
    // Phase 2-A: 좌표 기반 정렬 (y 우선, 같은 y면 x)
    final sorted = _sortByPosition(children);
    for (final child in sorted) {
      _writeNodeBody(buf, child as Map<String, dynamic>, depth: nextDepth);
    }
  }
}

/// TEXT 노드용 스펙 한 줄 — `15px · w600 · lh18 · #fff · center`.
/// fontSizeNormalized 있으면 우선 (정규화(raw) 형식).
/// fake-bold가 감지되면 `⚡fake-bold(0.2)` 배지 추가.
String _buildTextSpecMarker(Map<String, dynamic> text) {
  final parts = <String>[];
  final sizeNorm = text['fontSizeNormalized'];
  final sizeRaw = text['fontSize'];
  if (sizeNorm != null) {
    parts.add('${_fmtNum(sizeNorm)}px (raw ${_fmtNum(sizeRaw)})');
  } else if (sizeRaw != null) {
    parts.add('${_fmtNum(sizeRaw)}px');
  }
  if (text['fontWeight'] != null) parts.add('w${_fmtNum(text['fontWeight'])}');
  final lh = text['lineHeightPx'];
  if (lh is num) parts.add('lh${_fmtNum(lh)}');
  if (text['letterSpacing'] is num && (text['letterSpacing'] as num) != 0) {
    parts.add('ls${_fmtNum(text['letterSpacing'])}');
  }
  final align = text['textAlignHorizontal'];
  if (align != null && align != 'LEFT') {
    parts.add((align as String).toLowerCase());
  }
  if (text['color'] != null) parts.add('${text['color']}');
  final fakeBold = text['fakeBold'] as Map?;
  if (fakeBold != null) {
    parts.add('⚡fake-bold(${_fmtNum(fakeBold['strokeWidth'])})');
  }
  return parts.join(' · ');
}

/// 컨테이너 노드의 auto-layout 요약 — `Layout: vertical · gap 12 · align center · padding 0-16-0-16`.
String _buildLayoutSummary(Map<String, dynamic> node) {
  final layout = node['layout'] as Map<String, dynamic>?;
  if (layout == null) return '';

  final parts = <String>[];
  final mode = (layout['mode'] as String?)?.toLowerCase() ?? '?';
  parts.add('Layout: $mode');

  final gapNorm = layout['itemSpacingNormalized'];
  final gapRaw = layout['itemSpacing'];
  if (gapNorm != null) {
    parts.add('gap ${_fmtNum(gapNorm)} (raw ${_fmtNum(gapRaw)})');
  } else if (gapRaw != null) {
    parts.add('gap ${_fmtNum(gapRaw)}');
  }

  final primary = layout['primaryAxisAlign'];
  final counter = layout['counterAxisAlign'];
  if (primary != null || counter != null) {
    final p = (primary as String?)?.toLowerCase() ?? '-';
    final c = (counter as String?)?.toLowerCase() ?? '-';
    parts.add('align $p/$c');
  }

  final pad = layout['padding'] as Map?;
  if (pad != null && pad.isNotEmpty) {
    final t = _fmtNum(pad['t'] ?? 0);
    final r = _fmtNum(pad['r'] ?? 0);
    final b = _fmtNum(pad['b'] ?? 0);
    final l = _fmtNum(pad['l'] ?? 0);
    parts.add('padding $t-$r-$b-$l');
  }

  // cornerRadius도 여기 묶어서 출력 (컨테이너에 있으면 의미 있음)
  final cr = node['cornerRadius'];
  if (cr != null) parts.add('radius ${_fmtNum(cr)}');

  return parts.join(' · ');
}

/// 숫자 표시용 — float 노이즈 제거.
/// - 0.01 오차 내 정수: 정수로 ("15.000000953674316" → "15")
/// - 그 외: 2자리 반올림 후 trailing 0 정리 ("17.9003..." → "17.9")
String _fmtNum(dynamic v) {
  if (v is! num) return v?.toString() ?? '?';
  final rounded2 = (v * 100).round() / 100;
  if ((rounded2 - rounded2.roundToDouble()).abs() < 0.001) {
    return rounded2.toInt().toString();
  }
  var s = rounded2.toStringAsFixed(2);
  // trailing zero 제거
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// 자식 노드를 시각적 순서(위→아래, 좌→우)로 정렬.
/// y 좌표가 ±10px 이내면 같은 행으로 간주하고 x로 정렬.
List<dynamic> _sortByPosition(List<dynamic> children) {
  const yTolerance = 10.0;
  return [...children]..sort((a, b) {
    final ay = ((a as Map)['bbox']?['y'] as num?) ?? 0;
    final by = ((b as Map)['bbox']?['y'] as num?) ?? 0;
    if ((ay - by).abs() > yTolerance) return ay.compareTo(by);
    final ax = (a['bbox']?['x'] as num?) ?? 0;
    final bx = (b['bbox']?['x'] as num?) ?? 0;
    return ax.compareTo(bx);
  });
}

/// tree를 재귀하며 Dev Mode 어노테이션 수집.
///
/// 어노테이션 host 는 TEXT 가 아닌 경우가 대부분이다(실측: 마이 기획 페이지 71개 host 중 69% 가
/// VECTOR/FRAME/INSTANCE/RECTANGLE/ELLIPSE). 그래서 texts.json(TEXT 전용)·md 본문(TEXT/컨테이너 전용)
/// 어느 쪽으로도 안 새어나온다 → 트리 전체를 훑어 별도 섹션으로 뽑는다.
void _collectAnnotations(
  Map<String, dynamic> tree,
  List<Map<String, dynamic>> out,
) {
  final annotations = tree['annotations'] as List?;
  if (annotations != null) {
    for (final a in annotations) {
      final map = a as Map<String, dynamic>;
      final label = (map['label'] ?? '').toString();
      if (label.trim().isEmpty) continue;
      out.add({
        'hostId': tree['id'],
        'hostName': tree['name'],
        'hostType': tree['type'],
        'label': label,
        if (map['categoryId'] != null) 'categoryId': map['categoryId'],
      });
    }
  }
  final children = tree['children'] as List?;
  if (children != null) {
    for (final c in children) {
      _collectAnnotations(c as Map<String, dynamic>, out);
    }
  }
}

/// tree를 재귀하며 prototype 인터랙션 수집.
void _collectInteractions(
  Map<String, dynamic> tree,
  List<Map<String, dynamic>> out,
) {
  final proto = tree['prototype'] as Map?;
  if (proto != null && proto['transitionNodeID'] != null) {
    out.add({
      'from': tree['id'],
      'fromName': tree['name'],
      'to': proto['transitionNodeID'],
      'duration': proto['transitionDuration'],
      'easing': proto['transitionEasing'],
    });
  }
  final children = tree['children'] as List?;
  if (children != null) {
    for (final c in children) {
      _collectInteractions(c as Map<String, dynamic>, out);
    }
  }
}

bool _isMeaningfulName(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;

  // 1) Figma 자동 생성 이름
  if (RegExp(
    r'^(Frame|Group|Rectangle|Ellipse|Vector|Line|Component|Instance) ?\d*$',
  ).hasMatch(trimmed))
    return false;

  // 2) Component slug (humbleicons:exclamation, material-symbols:check 등)
  if (RegExp(r'^[a-z0-9-]+:[a-z0-9-]+$').hasMatch(trimmed)) return false;

  // 3) 일반 UI element 이름 (대소문자 무시)
  if (RegExp(
    r'^(warning|text|icon|image|img|button|btn|container|card|badge|label|input|placeholder|wrapper|divider|shadow|background|bg|fill|stroke|box|row|col|column|stack|list|item|group)$',
    caseSensitive: false,
  ).hasMatch(trimmed))
    return false;

  return true;
}

// ─── 폴더 README 자동 생성 ──────────────────────────────────

String _generateFolderReadme(
  String name,
  String fileKey,
  String rootNodeId,
  List<Map<String, dynamic>> log,
) {
  final buf = StringBuffer();
  final urlNodeId = rootNodeId.replaceAll(':', '-');

  buf.writeln('# $name');
  buf.writeln();
  buf.writeln('> 🤖 Figma에서 자동 추출 — `extract_doc.dart`');
  buf.writeln(
    '> [Figma 원본 열기](https://www.figma.com/file/$fileKey/?node-id=$urlNodeId)',
  );
  buf.writeln('> 추출 시각: ${DateTime.now().toIso8601String()}');
  buf.writeln();

  // 스케일 왜곡 프레임 요약 (있으면 상단에 눈에 띄게)
  final scaleWarnings = log
      .where((f) => f['frameScaleWarning'] != null)
      .toList();
  if (scaleWarnings.isNotEmpty) {
    buf.writeln('## ⚠️ 프레임 스케일 왜곡 감지 (${scaleWarnings.length}개)');
    buf.writeln();
    buf.writeln(
      '다음 프레임은 Figma에서 그룹 스케일된 상태로 저장되어 있음. '
      'raw fontSize/gap 값이 디자이너 의도 값과 다름.',
    );
    buf.writeln();
    for (final f in scaleWarnings) {
      buf.writeln(
        '- **${f['name']}**: `${f['frameScaleWarning']}` — '
        '정규화 값은 `${f['textsFile']}` / `${f['typographyFile']}` 참조',
      );
    }
    buf.writeln();
  }

  buf.writeln('## 📋 Frame 목록 (${log.length}개)');
  buf.writeln();
  buf.writeln('| # | Frame | Size | Scale | 파일 |');
  buf.writeln('|---|---|---|---|---|');
  for (var i = 0; i < log.length; i++) {
    final f = log[i];
    final files = <String>[];
    if (f['imageFile'] != null) files.add('[PNG](./${f['imageFile']})');
    if (f['mdFile'] != null) files.add('[MD](./${f['mdFile']})');
    if (f['treeFile'] != null) files.add('[Tree](./${f['treeFile']})');
    if (f['textsFile'] != null) files.add('[Texts](./${f['textsFile']})');
    if (f['typographyFile'] != null) {
      files.add('[Typo](./${f['typographyFile']})');
    }
    final warnMark = f['frameScaleWarning'] != null ? ' ⚠️' : '';
    buf.writeln(
      '| ${i + 1} | ${f['name']}$warnMark | ${f['width']}×${f['height']} | '
      '${f['scale']} | ${files.join(' · ')} |',
    );
  }
  buf.writeln();

  final warnings = log.where((f) => f['warning'] != null).toList();
  if (warnings.isNotEmpty) {
    buf.writeln('## ⚠️  분해 권장');
    buf.writeln();

    // name별 그룹핑 (중복 경고 묶음)
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final w in warnings) {
      grouped.putIfAbsent(w['name'] as String, () => []).add(w);
    }

    grouped.forEach((name, items) {
      if (items.length == 1) {
        buf.writeln('- **$name**: ${items.first['warning']}');
      } else {
        final uniqueWarnings = items.map((i) => i['warning'] as String).toSet();
        if (uniqueWarnings.length == 1) {
          buf.writeln('- **$name** × ${items.length}: ${uniqueWarnings.first}');
        } else {
          buf.writeln('- **$name** × ${items.length}: 여러 경고 (개별 파일 확인)');
        }
      }
    });

    buf.writeln();
    buf.writeln('→ sub-agent 위임으로 sub-frame 단위 재추출 권장');
    buf.writeln();
  }

  buf.writeln('## 📁 파일 구조');
  buf.writeln();
  buf.writeln('각 frame당 3개 파일:');
  buf.writeln('- `*.png` — 시각 확인용');
  buf.writeln('- `*.tree.json` — 노드 트리 + 텍스트 + 좌표 (LLM 변환 시 정확도 보장)');
  buf.writeln('- `*.md` — 자동 생성 골격 (의미적 정제 필요)');
  buf.writeln();

  buf.writeln('## 🔄 재실행');
  buf.writeln();
  buf.writeln('```bash');
  buf.writeln('cd tools/figma_extractor');
  buf.writeln('dart run bin/extract_doc.dart --node "$rootNodeId"');
  buf.writeln('```');
  buf.writeln();

  return buf.toString();
}

// ─── Figma URL 파싱 ──────────────────────────────────────────

Map<String, String>? _parseFigmaUrl(String url) {
  final m = RegExp(
    r'figma\.com/(?:file|design)/([a-zA-Z0-9]+)',
  ).firstMatch(url);
  if (m == null) return null;
  final fileKey = m.group(1)!;

  final nodeMatch = RegExp(r'node-id=([^&\s]+)').firstMatch(url);
  final nodeId = nodeMatch?.group(1)?.replaceAll('-', ':');

  return {'fileKey': fileKey, if (nodeId != null) 'nodeId': nodeId};
}

// ─── SECTION 검색 ──────────────────────────────────────────

Map<String, dynamic>? _findSection(Map<String, dynamic> node, String name) {
  if (node['type'] == 'SECTION' &&
      (node['name'] as String?)?.contains(name) == true) {
    return node;
  }
  final children = node['children'] as List?;
  if (children == null) return null;
  for (final c in children) {
    final result = _findSection(c as Map<String, dynamic>, name);
    if (result != null) return result;
  }
  return null;
}

// ─── Frame 수집 (extract.dart와 동일) ────────────────────

void _collectFrames(
  List<dynamic> children,
  List<Map<String, dynamic>> frames,
  Map<String, String> sectionMap, {
  String? currentSection,
}) {
  for (final c in children) {
    final node = c as Map<String, dynamic>;
    final type = node['type'] as String?;
    final id = node['id'] as String?;
    final name = node['name'] as String?;

    if (type == 'FRAME' || type == 'COMPONENT') {
      frames.add(node);
      if (currentSection != null && id != null) {
        sectionMap[id] = currentSection;
      }
    } else if (type == 'SECTION' || type == 'GROUP') {
      final sectionName = name ?? type ?? 'unnamed';
      final subChildren = node['children'] as List?;
      if (subChildren != null) {
        _collectFrames(
          subChildren,
          frames,
          sectionMap,
          currentSection: type == 'SECTION' ? sectionName : currentSection,
        );
      }
    }
  }
}

// ─── Figma API 클라이언트 ────────────────────────────────────

class FigmaApi {
  final HttpClient client;
  final String token;
  final String fileKey;

  FigmaApi({required this.client, required this.token, required this.fileKey});

  Future<Map<String, dynamic>> fetchFile({int depth = 1}) async {
    return _get('$_baseUrl/files/$fileKey?depth=$depth');
  }

  Future<Map<String, dynamic>> fetchNodes(List<String> nodeIds) async {
    final ids = nodeIds.join(',');
    return _get('$_baseUrl/files/$fileKey/nodes?ids=$ids');
  }

  Future<Map<String, dynamic>> exportImages(
    List<String> nodeIds, {
    double scale = 1.0,
  }) async {
    final ids = nodeIds.join(',');
    final result = await _get(
      '$_baseUrl/images/$fileKey?ids=$ids&format=png&scale=$scale',
    );
    return result['images'] as Map<String, dynamic>? ?? {};
  }

  Future<void> downloadFile(String url, File file) async {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    await response.pipe(file.openWrite());
  }

  Future<Map<String, dynamic>> _get(String url) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('X-Figma-Token', token);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }
}

// ─── 유틸 ──────────────────────────────────────────────────

Map<String, String> _loadEnv() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = File('${dir.path}/.env');
    if (candidate.existsSync()) {
      final env = <String, String>{};
      for (final line in candidate.readAsLinesSync()) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final eq = trimmed.indexOf('=');
        if (eq > 0) {
          env[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
        }
      }
      return env;
    }
    dir = dir.parent;
  }
  stderr.writeln('오류: .env 못 찾음');
  exit(1);
}

String? _argValue(List<String> args, String key) {
  final i = args.indexOf(key);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

num? _round(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return (v * 10).round() / 10;
  return null;
}

String _toSafeDirName(String name) {
  return name
      .replaceAll(
        RegExp(r'[📁🚩🗓️🟢🔴🗺️🗃️🔎🤖⭐🟡🟠🔵🟣⚫⚪✨🎯💡📋📝🌳🖼️📚🔍🎨📊]+'),
        '',
      )
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '')
      .trim();
}

String _toSafeFileName(String name) {
  return name
      .replaceAll(RegExp(r'[^\w가-힣\-]'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '')
      .toLowerCase();
}

void _printUsage() {
  stdout.writeln('''
extract_doc.dart — Figma 정책/문서 추출 (PNG + tree.json + md.skeleton)

사용법:
  dart run bin/extract_doc.dart --url "https://figma.com/file/.../?node-id=..."
  dart run bin/extract_doc.dart --page "페이지명"
  dart run bin/extract_doc.dart --page "페이지명" --section "1차"
  dart run bin/extract_doc.dart --node "1097:63359"

옵션:
  --dry-run              실제 추출 없이 예상만 출력
  --out <dir>            출력 루트 (기본: ../../../../docs/designs = 리포 루트의 docs/designs)
  --out-direct           out을 직접 폴더로 사용 (자동 슬러그 폴더 안 만듦)
  --scale <n>            PNG scale 강제 (기본: 자동 계산, 10000px 한계 회피)
  --include-ids "a,b"    특정 frame ID만
  --exclude-ids "a,b"    특정 frame ID 제외
  --force-overwrite      기존 MD/README 덮어쓰기 (기본: .new.md로 보호)

출력:
  {out}/{name-slug}/
  ├── README.md              자동 생성 인덱스
  ├── .extraction-log.json   추출 메타
  ├── *.png                  각 frame 이미지
  ├── *.tree.json            노드 트리 + 텍스트 + 좌표
  └── *.md                   자동 생성 골격 (의미적 정제 필요)

워크플로우 (.claude/skills/figma-extract/SKILL.md 참조):
  1) --dry-run으로 예상 확인
  2) ⚠️ 분해 권장 frame은 sub-agent 위임
  3) 일반 frame은 그대로 추출
  4) 생성된 *.md를 확인하면서 의미적으로 정제
''');
}
