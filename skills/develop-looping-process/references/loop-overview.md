# develop-looping-process 전체 개관 (도식)

기능 하나를 **계획 → 구현 → 시각검증 → QA → 시나리오감사 → 갭수정 → PR** 7단계로
끝까지 굴리는 오케스트레이터. 이 문서는 "이게 어떻게 돌아가는가"를 그림으로 잡는다.

- 개발·QA를 **어떤 방식으로** 하는지 → [`dev-and-qa-model.md`](dev-and-qa-model.md)
- `dlp.py` 도구의 커맨드·불변식 상세 → [`dlp-tool-reference.md`](dlp-tool-reference.md)
- 현재 상태 분석과 개선 후보 → [`findings-2026-07-30.md`](findings-2026-07-30.md)

## 목차

1. [한 장으로 보는 전체 루프](#1-한-장으로-보는-전체-루프)
2. [역할 분리 — 라우터는 판단하지 않는다](#2-역할-분리--라우터는-판단하지-않는다)
3. [7단계와 각 단계의 게이트](#3-7단계와-각-단계의-게이트)
4. [상태 데이터 모델](#4-상태-데이터-모델)
5. [한 바퀴 도는 시퀀스](#5-한-바퀴-도는-시퀀스)
6. [멈추는 지점 — STOP의 종류](#6-멈추는-지점--stop의-종류)
7. [루프백 — 되돌아가는 경로](#7-루프백--되돌아가는-경로)
8. [완료 판정](#8-완료-판정)

---

## 1. 한 장으로 보는 전체 루프

```mermaid
flowchart TD
    K["킥오프<br/>Figma 링크 + '이거 개발할거야'"] --> T["dlp add-track<br/>+ set-track-status active"]
    T --> P1

    subgraph 계획["P1 · 글로 못 박기"]
        P1["feature-plan<br/>1.1 Figma 실측 → 1.2 플로우<br/>1.3 개발계획서 → 1.4 QA 기준"]
    end

    P1 --> AP{"⛔ 사람 승인<br/>State·Cubit API<br/>+ ROI 계약 동결"}
    AP -->|반려| P1
    AP -->|승인| P2

    subgraph 구현["P2 · 코드"]
        P2["feature-implement<br/>TDD RED→GREEN<br/>ui→cubit→repo→provider"]
    end

    P2 --> G{"게이트 4종<br/>format·analyze<br/>custom_lint·test"}
    G -->|RED| P2
    G -->|GREEN| P3

    subgraph 검증["P3~P5 · 3중 검증"]
        P3["visual-verify<br/>Figma 픽셀 대조"]
        P4["feature-runtime-qa<br/>실빌드 sim 실행 검증"]
        P5["feature-scenario-audit<br/>코드 정독 엣지 감사"]
    end

    P3 -->|"clean_streak≥2"| P4
    P3 -->|FAIL| P2
    P4 -->|"지적 0"| P5
    P4 -->|"결함"| P2
    P5 --> GAP{"open_gaps + needs_sim"}

    GAP -->|"0 / 0"| P7
    GAP -->|"> 0"| P6

    subgraph 수정["P6 · 갭 닫기"]
        P6["feature-gap-fix<br/>루트원인 수정 + 회귀테스트<br/>+ 적대 재검증"]
    end

    P6 -->|"잔존"| P6
    P6 -->|"0 / 0"| P7

    P7["pr<br/>Phase 7"] --> DONE(["트랙 완료"])
    DONE --> NEXT{"남은 기능?"}
    NEXT -->|있음| P1
    NEXT -->|"전부 완료"| HANDOFF["designer-handoff-report<br/>종단 리포트"]

    style AP fill:#ffe0e0,stroke:#c00,stroke-width:2px
    style G fill:#fff4d0,stroke:#c90
    style GAP fill:#fff4d0,stroke:#c90
    style DONE fill:#e0f0e0,stroke:#0a0
```

**빨간 게이트(P1 승인)만 사람이 연다.** 나머지 노란 게이트는 실패해도 사람을 부르지 않고
루프백한다 — 이게 "루핑"의 핵심이다.

## 2. 역할 분리 — 라우터는 판단하지 않는다

이 시스템의 설계 요점은 **판정을 LLM에서 순수 함수로 빼낸 것**이다.

```mermaid
flowchart LR
    subgraph 기계["기계 · 결정론"]
        S[("state.json<br/>SSOT")]
        D["dlp.py route<br/>순수 계산"]
        V["dlp.py validate<br/>불변식 강제"]
        S --> D
        S --> V
    end

    subgraph 판단["LLM · 라우터"]
        R["develop-looping-process<br/>실행·기록만"]
    end

    subgraph 실행["LLM · Phase 스킬"]
        W["feature-plan<br/>feature-implement<br/>feature-runtime-qa<br/>…"]
    end

    D -->|"ACTION / STOP / DONE"| R
    R -->|"Skill 툴 호출"| W
    W -->|"결과"| R
    R -->|"뮤테이션"| S
    V -.->|"불변식 위반 시 거부"| R

    style 기계 fill:#eef5ff,stroke:#36c
    style 판단 fill:#f7f0ff,stroke:#93c
    style 실행 fill:#f0fff0,stroke:#3a3
```

| 주체 | 하는 일 | 안 하는 일 |
|---|---|---|
| `dlp.py` | 다음 액션 **계산**, 불변식 강제, 뷰 렌더 | 코드·문서 작성 |
| 오케스트레이터 | 계산 결과대로 스킬 **호출**, 결과 **기록** | 단계 절차를 스스로 판단 |
| Phase 스킬 | 그 단계의 실제 작업 | 자기 작업의 합격 판정 |
| 격리 검증자 | 적대적 판정 (≥3 다수결) | 코드 수정 |
| 사람 | P1 승인, BLOCK 해소, 에스컬레이션 대응 | 매 단계 개입 |

> **재발명 금지 원칙** — 각 Phase가 "무엇을 어떻게" 하는지는 Phase 스킬이 소유한다.
> 라우터는 그 절차를 자기 파일에 복붙하지 않는다.

## 3. 7단계와 각 단계의 게이트

```mermaid
flowchart LR
    P1["P1<br/>feature-plan"] --> P2["P2<br/>feature-implement"]
    P2 --> P3["P3<br/>visual-verify"]
    P3 --> P4["P4<br/>feature-runtime-qa"]
    P4 --> P5["P5<br/>feature-scenario-audit"]
    P5 --> P6["P6<br/>feature-gap-fix"]
    P6 --> P7["P7<br/>pr"]
```

| Phase | 스킬 | 산출 | 통과 조건 | 진행판을 스스로 갱신? |
|---|---|---|---|---|
| P1 | `feature-plan` | 이해도 문서, 승인 스펙, `<f>.rois.json`, QA 기준 | **사람 승인** → API·ROI 동결 | 예 (`approved` 기록은 P1 몫) |
| P2 | `feature-implement` | `lib/feature/<f>/` 전 레이어 + 테스트 | 게이트 4종 GREEN + RED 증거 + 키노출 preflight | 예 |
| P3 | `visual-verify` | Figma 대조 캡처·diff | **clean_streak ≥ 2** | ❌ **라우터가 대신 기록** |
| P4 | `feature-runtime-qa` | `<f>.md §QA-P4` | 열린 지적 0 (격리 ≥3 다수결) | 예 |
| P5 | `feature-scenario-audit` | `scenario-gaps.md` | 판정 완료 (수렴 2연속) | 예 |
| P6 | `feature-gap-fix` | 수정 코드 + 회귀 테스트 | `open_gaps=0` **그리고** `needs_sim=0` | 예 |
| P7 | `pr` | PR | 머지 | ❌ **라우터가 대신 기록** |

> **ledger-blind 스킬** — `visual-verify`(P3)·`pr`(P7)·`designer-handoff-report`(종단)는
> 진행판의 존재를 모르는 기존 스킬이다. 그래서 이 셋의 전이는 **라우터가 소유해서 기록**한다.
> 이 비대칭이 버그의 단골 출처다.

## 4. 상태 데이터 모델

```mermaid
erDiagram
    BRANCH ||--o{ TRACK : "active는 1개만"
    TRACK ||--o{ REVISION : "가짐"
    REVISION ||--o{ PHASE_RUN : "P1~P7"
    REVISION ||--o{ EVIDENCE : "게이트·리뷰·승인·머지"
    REVISION ||--o{ CYCLE : "라운드별 발견/해결/잔여"
    TRACK ||--o{ BLOCK : "⛔ 하드·차단"
    TRACK ||--o{ AWAIT : "소프트·비차단"

    TRACK {
        string id
        string feature
        string branch
        string status "active|parked|done"
    }
    PHASE_RUN {
        string phase "P1..P7"
        string result "unknown|pass|fail"
        int clean_streak
    }
    EVIDENCE {
        string kind "gate|review|approval|merge|e2e"
        string ref
    }
    CYCLE {
        int round
        int found
        int resolved
        int remaining
    }
```

**직렬성 규칙이 여기 박혀 있다.**

```mermaid
flowchart TD
    B1["브랜치 feat/settings"] --> T1["트랙 A · active"]
    B1 -.->|"❌ I-B 위반 · 뮤테이션 거부"| T2["트랙 B · active"]
    B1 --> T3["트랙 B · parked ✅"]

    B2["브랜치 feature/emotion-*"] --> T4["트랙 C · active ✅"]

    style T2 fill:#ffe0e0,stroke:#c00
    style T3 fill:#e0f0e0,stroke:#0a0
    style T4 fill:#e0f0e0,stroke:#0a0
```

한 브랜치에 active 트랙은 **1개**. 브랜치가 다르면 병렬 OK — 이 설계가 초기 버전의
"전역 직렬" 데드락을 푼 지점이다.

## 5. 한 바퀴 도는 시퀀스

```mermaid
sequenceDiagram
    autonumber
    participant H as 사람
    participant R as 라우터<br/>develop-looping-process
    participant D as dlp.py
    participant S as Phase 스킬
    participant V as 격리 검증자 ×3

    H->>R: "다음 뭐 해야 해"
    R->>D: validate && selftest && render --check
    alt 하나라도 실패
        D-->>R: FAIL
        R-->>H: 멈춤 — 상태 불변식 깨짐 보고
    end
    D-->>R: OK

    R->>D: route
    D-->>R: ACTION(→feature-runtime-qa) / STOP / DONE

    alt STOP
        R-->>H: 정지 사유 보고 (승인 대기·BLOCK·에스컬레이션…)
    else ACTION
        R->>S: Skill 툴로 호출
        S->>V: Agent 툴로 ≥3 병렬 스폰
        V-->>S: 각자 독립 판정
        S->>S: 다수결 · 동수는 "결함" 기본값
        S-->>R: 결과
        R->>D: set-phase / add-evidence / add-cycle …
        D->>D: 자동 validate + render
        alt 불변식 위반
            D-->>R: 거부 (파일 안 바뀜)
        end
        R->>D: route (다음 바퀴)
    end
```

**5번과 6번 사이가 이 시스템의 심장이다** — LLM이 "다음은 P4겠지"라고 추측하지 않고
순수 함수가 계산한 결과를 받는다.

## 6. 멈추는 지점 — STOP의 종류

```mermaid
flowchart TD
    RT["dlp route"] --> Q1{"승인 있나"}
    Q1 -->|없음| S1["STOP · 사람 승인 대기"]
    Q1 -->|있음| Q2{"⛔ BLOCK 있나"}
    Q2 -->|있음| S2["STOP · 명시 요청 이견"]
    Q2 -->|없음| Q3{"round > 3"}
    Q3 -->|예| S3["STOP · 에스컬레이션<br/>스펙·하네스 문제 의심"]
    Q3 -->|아니오| Q4{"active 트랙 지정됐나"}
    Q4 -->|아님| S4["STOP · 활성화 결정 필요"]
    Q4 -->|지정됨| Q5{"직렬 위반·sim 미지정<br/>needs_human"}
    Q5 -->|있음| S5["STOP · 사람 결정점"]
    Q5 -->|없음| Q6{"게이트 RED·미검증"}
    Q6 -->|있음| A1["ACTION · 루프백<br/>사람 개입 불필요"]
    Q6 -->|없음| A2["ACTION · 다음 Phase"]

    style S1 fill:#ffe0e0,stroke:#c00
    style S2 fill:#ffe0e0,stroke:#c00
    style S3 fill:#ffe0e0,stroke:#c00
    style S4 fill:#ffe0e0,stroke:#c00
    style S5 fill:#ffe0e0,stroke:#c00
    style A1 fill:#fff4d0,stroke:#c90
    style A2 fill:#e0f0e0,stroke:#0a0
```

**결정적 구분** — 게이트 RED는 STOP이 **아니다**. 사람을 부르지 않고 P2로 루프백한다.
사람이 불려 나오는 건 위 5가지 빨간 경우뿐이다.

> ⛔BLOCK vs AWAIT
> - `add-block` = **하드**. 사용자 명시 요청과 판단이 충돌. 해소 전엔 트랙 done 불가.
> - `add-await` = **소프트**. 외부 대기(BE·디자이너). 진행을 막지 않는다.
>
> 명시 요청 미반영을 "이미 정상"으로 강등·은폐하는 것이 금지 대상이다.

## 7. 루프백 — 되돌아가는 경로

```mermaid
stateDiagram-v2
    [*] --> P1
    P1 --> P1: 승인 반려
    P1 --> P2: approved=yes
    P2 --> P2: 게이트 RED (3회 → 에스컬레이션)
    P2 --> P3: GREEN
    P3 --> P2: 픽셀 불일치
    P3 --> P4: clean_streak≥2
    P4 --> P2: 결함 발견 → 고치고 6.1부터 재검
    P4 --> P5: 지적 0
    P5 --> P6: gaps>0 또는 needs_sim>0
    P5 --> P7: 0 / 0
    P6 --> P6: 잔존 (3회 → 에스컬레이션)
    P6 --> P7: 0 / 0
    P7 --> [*]

    note right of P2
        stale GREEN 차단:
        코드가 바뀌어 새 P2 게이트가 찍히면
        하위 P3~P6 pass가 자동 무효화된다
    end note
```

**stale GREEN 차단**이 이 상태머신에서 가장 미묘한 규칙이다. P5까지 갔다가 P2로
루프백해 코드를 고치면, 이미 통과했던 P3·P4·P5가 **자동으로 무효화**된다.
"아까 통과했으니 넘어가자"가 구조적으로 불가능하다.

## 8. 완료 판정

`completion_predicate` — route와 validator가 **공유하는 단일 술어**다.
어느 하나도 산출물만 보고 추정하지 않는다.

```mermaid
flowchart LR
    C1["승인<br/>logic & ui"] --> AND(("∧"))
    C2["P2 GREEN@head"] --> AND
    C3["P3<br/>streak≥2 또는 skip"] --> AND
    C4["P4 pass"] --> AND
    C5["P5<br/>streak≥2"] --> AND
    C6["counts<br/>0 / 0"] --> AND
    C7["P6 pass"] --> AND
    C8["미해소<br/>⛔BLOCK 없음"] --> AND
    AND --> DONE["트랙 done"]

    style AND fill:#eef5ff,stroke:#36c,stroke-width:2px
    style DONE fill:#e0f0e0,stroke:#0a0,stroke-width:2px
```

여덟 개 **전부** 참이어야 완료다. `@head`는 "현재 커밋 기준"이라는 뜻으로,
코드가 바뀌면 다시 찍어야 한다.
