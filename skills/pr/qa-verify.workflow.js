// qa-verify.workflow.js — /pr 의 3채널 QA 검증 중 isolate 2채널(1차 감사관 + 적대적 반증자).
// codex 3번째 채널은 스킬이 codex-verify.sh 로 병렬 실행한다.
//
// 호출: Workflow({ scriptPath: ".claude/skills/pr/qa-verify.workflow.js", args: { items: [...] } })
//   items[i] = { key, claim, files:[...], goldens:[...], kind: 'machine' | 'human' }
//     - kind 'machine' = CI/테스트/grep 로 검증 가능 → 반증자가 worktree 격리에서 mutation testing.
//     - kind 'human'   = 시각 정합/UX → 반증자는 read-only 적대 리뷰(자동 체크 금지, 사람 몫).
//
// ⚠️ 전제: 스킬이 **검증 전에 커밋**을 마쳤다(작업이 HEAD 에 있다). 반증자는 worktree 격리
//   (isolation:'worktree' → HEAD 사본)에서 변이하므로 공유 워킹트리의 미커밋 수정을 건드리지 않는다.
//   (이 격리가 없으면 mutation 의 git restore 가 메인 트리 미커밋분을 clobber 한다 — 실제 발생 사례.)

export const meta = {
  name: 'pr-qa-verify',
  description: 'PR QA 체크리스트 항목별 isolate 1차감사+적대적반증(machine 은 worktree mutation testing)',
  phases: [{ title: '1차 감사' }, { title: '적대적 반증' }],
}

const VERDICT = {
  type: 'object',
  additionalProperties: false,
  properties: {
    item: { type: 'string' },
    verdict: { type: 'string', enum: ['pass', 'fail', 'uncertain'] },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    evidence: { type: 'array', items: { type: 'string' } },
    mutationProof: { type: 'string' },
    visualObservation: { type: 'string' },
    gap: { type: 'string' },
  },
  required: ['item', 'verdict', 'confidence', 'evidence', 'mutationProof', 'visualObservation', 'gap'],
}

// args 가 문자열로 도착하는 런타임 버그 방어 — string 이면 JSON.parse.
let _args = args
if (typeof _args === 'string') {
  try {
    _args = JSON.parse(_args)
  } catch (_) {
    _args = null
  }
}
const items = (_args && _args.items) || []
if (!items.length) {
  log('qa-verify: args.items 가 비었다 — 검증할 체크리스트 항목이 없다.')
  return []
}

function filesBlock(it) {
  const fs = (it.files || []).map((f) => `  - ${f}`).join('\n')
  const gs = (it.goldens || []).length
    ? `\n골든/이미지(Read 로 직접 보기 — 배경색·그림자·줄수·폭 관찰):\n${it.goldens.map((g) => `  - ${g}`).join('\n')}`
    : ''
  return `직접 Read 할 파일:\n${fs}${gs}`
}

function primaryPrompt(it) {
  return [
    `너는 Flutter 코드/디자인 정합 감사관이다. 저장소 루트에서 아래 주장을 엄밀히 검증하라.`,
    `추측 금지 — 파일을 직접 Read 하고, claim 의 각 하위 주장을 코드 값/SSOT/테스트 어서션과 대조하라.`,
    ``,
    `CLAIM: ${it.claim}`,
    ``,
    filesBlock(it),
    ``,
    it.kind === 'machine'
      ? `이 항목은 [기계검증] 대상이다. 회귀테스트가 claim 의 load-bearing 동작을 진짜로 단언하는지(단순 렌더/존재 확인이 아니라) 확인하라.`
      : `이 항목은 [사람판단] 대상이다(시각 정합/UX). 골든/이미지를 보고 관찰을 visualObservation 에 적되, 최종 체크는 사람이 한다는 전제로 의견만 낸다.`,
    `모든 하위 주장이 구체 근거로 충족될 때만 verdict=pass. 하나라도 미충족/불명이면 fail/uncertain + gap. evidence 에 file:line.`,
    `mutationProof 는 1차에선 보통 'N/A'(반증자가 수행).`,
  ].join('\n')
}

function skepticPrompt(it, primary) {
  const common = [
    `너는 적대적(adversarial) 리뷰어다. 1차 감사관은 verdict="${primary && primary.verdict}" 로 결론냈다.`,
    `신뢰하지 말고 독립적으로 파일을 직접 Read 해 이 주장을 REFUTE(반증) 시도하라.`,
    ``,
    `CLAIM: ${it.claim}`,
    `1차 근거(검증 대상이지 신뢰 대상 아님): ${JSON.stringify((primary && primary.evidence) || [])}`,
    ``,
    filesBlock(it),
  ]
  if (it.kind === 'machine') {
    return [
      ...common,
      ``,
      `[기계검증] **mutation testing 으로 회귀테스트가 load-bearing 인지 실증하라**: 너는 격리된 worktree 사본에 있으니`,
      `구현/스펙 값을 일부러 망가뜨린 뒤(예: 폭 캡 160→400, duration 500→250, 가드 제거) 그 테스트가 실제로 FAIL 하는지`,
      `flutter test 로 확인하고, 원복 후 다시 통과하는지 본다. 변이해도 테스트가 통과하면(=무감각) verdict=fail.`,
      `mutationProof 에 변이→결과를 적어라. 테스트가 약하거나(존재만 확인) 우회 가능하면 fail.`,
      `반증을 못 찾을 때만 pass. 애매하면 uncertain.`,
    ].join('\n')
  }
  return [
    ...common,
    ``,
    `[사람판단] read-only 로 적대 리뷰하라(파일 변이 금지). 골든/이미지가 claim 의 시각 의도와 어긋나는지,`,
    `SSOT(figma-snapshots/tree.json) 수치와 구현 값이 다른지 확인. 어긋나면 fail + gap. visualObservation 필수.`,
    `이 항목은 자동 체크 대상이 아니다 — 네 verdict 는 사람 최종확인용 의견이다. mutationProof='N/A'.`,
  ].join('\n')
}

phase('1차 감사')
const results = await pipeline(
  items,
  (it) => agent(primaryPrompt(it), { label: `audit:${it.key}`, phase: '1차 감사', schema: VERDICT }),
  (primary, it) =>
    agent(skepticPrompt(it, primary), {
      label: `refute:${it.key}`,
      phase: '적대적 반증',
      schema: VERDICT,
      // machine 항목 반증자만 worktree 격리(mutation testing 안전). human 은 read-only 라 격리 불필요.
      ...(it.kind === 'machine' ? { isolation: 'worktree' } : {}),
    }).then((skeptic) => ({ key: it.key, kind: it.kind, claim: it.claim, primary, skeptic })),
)

return results.filter(Boolean)
