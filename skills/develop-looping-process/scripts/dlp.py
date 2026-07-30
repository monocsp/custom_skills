#!/usr/bin/env python3
# scripts/dlp.py — develop-looping-process 검증 가능한 상태 머신 도구.
#
# 무엇: 설정/홈 개발 7-Phase 루프의 상태를 기계가독 JSON(SSOT)으로 두고,
#   불변식을 validator 로 강제하며 라우팅을 순수 함수 route(state) 로 계산한다.
#   status.md 는 이 파일에서 생성되는 뷰다. (구: LLM 이 손상된 마크다운을 해석 → 폐기)
#
# 왜: 결정적이어야 할 라우팅을 사람/LLM 이 마크다운을 읽어 해석하면 검증 불가능하다.
#   route·validator 가 단일 completion_predicate 를 공유하고, 불변식이 모순·미검증 상태를
#   거부하면 상태 머신이 검증 가능해진다(특히 검증증거 없는 완료=자평을 코드가 막는다).
#
# 설계 정본 = docs/renew-guide/impl/settings/dlp-state-machine-design.md (v2·v3 절이 상위 규정).
# python3 stdlib only. 앱 dart 게이트와 격리(lib/·test/ 밖 → flutter analyze/test 무관).

import argparse
import hashlib
import os
import subprocess
import sys
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parent.parent
_D = ROOT / "docs/renew-guide/impl/settings"
STATE_PATH = Path(os.environ.get("DLP_STATE", _D / "develop-looping-process-state.json"))
STATUS_MD = Path(os.environ.get("DLP_STATUS", _D / "develop-looping-process-status.md"))
REPORT_MD = _D / "develop-looping-process-migration-report.md"
ORIG_PRESERVED = _D / "dlp-notes/_original-status-260724.md"

# ── 상수/스키마 ─────────────────────────────────────────────────────────────
PHASE_KEYS = {"P1", "P2", "P3", "P4", "P5", "P6"}      # 정확 집합(P7 등 여분 금지 — R2/R9)
MAIN_PHASES = ["P2", "P3", "P4", "P5", "P6"]           # 파이프라인 본체(P1=승인, 릴리스=branch.release)
MONO_PHASES = ["P1", "P2", "P3", "P4", "P5", "P6"]     # 단조성 체인(P1 포함 — codex/panel)
SPLIT_PHASES = {"P1", "P2"}                            # logic/ui 절반 (§1.5)
GATE_PHASES = {"P2"}
REVIEW_PHASES = {"P3", "P4", "P5"}                     # 정족수 리뷰증거 요구(I-Q, R12)
PHASE_SKILL = {"P1": "feature-plan", "P2": "feature-implement", "P3": "visual-verify",
               "P4": "feature-runtime-qa", "P5": "feature-scenario-audit", "P6": "feature-gap-fix"}
SIM_PHASES_SKILL = {"visual-verify", "feature-runtime-qa"}   # sim 점유 필요(R7 lease)
PHASE_STATUS = {"unknown", "wip", "pass", "skip"}
NO_SKIP_PHASES = {"P1", "P2", "P4", "P5"}
SKIP_REASONS = {"structural", "norev", "derived"}      # R11 skip 서브타입
TRACK_STATUS = {"active", "parked", "done"}
RELEASE_STATUS = {"pending", "parked", "pr_open", "merged"}
EVIDENCE_KINDS = {"gate", "review", "live_e2e", "regression", "merge", "approval",
                  "harness_feedback", "note", "handoff"}
# kind별 필수필드(head_commit 은 완료판정에서만 요구 — 마이그레이션 관용, R3)
EVIDENCE_REQUIRED = {   # 존재 필수 필드(review 정족수 = codex|verifier_count≥3 는 별도 검사)
    "gate": ["phase", "result"], "review": ["phase", "verdict"],
    "live_e2e": ["device"], "approval": ["scope", "actor"], "regression": ["test_ref"],
    "merge": ["base"], "harness_feedback": ["desc"], "note": [], "handoff": [],
}
BLOCK_STATUS = {"open", "resolved", "superseded"}
STREAK_CONVERGE = 2
ESCALATE_ROUND = 3
REVIEW_MIN = 3                                          # 정족수(격리 ≥3) 또는 codex


# ── 상태 IO ─────────────────────────────────────────────────────────────────
def load_state(path=STATE_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_state(state, path=STATE_PATH):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
        f.write("\n")


# ── 접근 헬퍼 ────────────────────────────────────────────────────────────────
def rev_of(track):
    if not isinstance(track, dict):
        return None
    cur = track.get("current_rev")
    revs = track.get("revisions", [])
    for r in (revs if isinstance(revs, list) else []):
        if isinstance(r, dict) and r.get("rev") == cur:
            return r
    return None


def _d(x):
    """dict 면 그대로, 아니면 빈 dict — 비-dict 값(str/list 등)에 .get 크래시 방지."""
    return x if isinstance(x, dict) else {}


def _len(x):
    """리스트면 길이, 아니면 0 — 스칼라 값에 len 크래시 방지(render 표시용)."""
    return len(x) if isinstance(x, list) else 0


def half(rev, phase, side):
    return _d(_d(_d(rev.get("phases")).get(phase)).get(side)).get("status", "unknown")


def pstat(rev, phase):
    return _d(_d(rev.get("phases")).get(phase)).get("status", "unknown")


def pfield(rev, phase, field, default=None):
    return _d(_d(rev.get("phases")).get(phase)).get(field, default)


def _nnint(v):
    """비-bool 음이 아닌 정수만 그 값, 아니면 None (float·bool·문자열은 무효)."""
    return v if (isinstance(v, int) and not isinstance(v, bool) and v >= 0) else None


def streak(rev, phase):
    return _nnint(pfield(rev, phase, "clean_streak", 0)) or 0


def rnd(rev, phase):
    return _nnint(pfield(rev, phase, "round", 0)) or 0


def track_branch(track):
    rev = rev_of(track)
    ex = _d(rev.get("exec")) if rev else {}
    if ex.get("branch"):
        return ex["branch"]
    return track.get("branch")


def counts_of(rev):
    c = _d(rev.get("counts"))
    return c.get("open_gaps", None), c.get("needs_sim", None)


def _int_or_none(v):
    return v if (v is None or (isinstance(v, int) and not isinstance(v, bool))) else "BAD"   # bool 은 정수 아님


def _evlist(rev):
    ev = rev.get("evidence", [])
    return ev if isinstance(ev, list) else []


def _dicts(container):
    """리스트 안의 dict 항목만(손편집 손상 SSOT 에서 .get 크래시 방지). 비-리스트는 빈 리스트."""
    return [x for x in container if isinstance(x, dict)] if isinstance(container, list) else []


def open_blocks(rev):
    bs = rev.get("blocks", [])
    return [b for b in bs if isinstance(b, dict) and b.get("status", "open") == "open"] if isinstance(bs, list) else []


def open_awaiting(rev):
    aw = (rev or {}).get("awaiting", [])
    return [w for w in aw if isinstance(w, dict)] if isinstance(aw, list) else []


def approval_evidence(rev, scope):
    return [e for e in _evlist(rev) if isinstance(e, dict) and e.get("kind") == "approval" and e.get("scope") == scope]


def latest_gate(rev, phase):
    gates = [e for e in _evlist(rev) if isinstance(e, dict) and e.get("kind") == "gate" and e.get("phase") == phase]
    return gates[-1] if gates else None


def latest_review(rev, phase):
    revs = [e for e in _evlist(rev) if isinstance(e, dict) and e.get("kind") == "review" and e.get("phase") == phase]
    return revs[-1] if revs else None


def _review_ok(e):
    """이 리뷰 증거가 정족수·SOUND 인가 — bool/int 타입 엄격(문자열 truthy·캐스팅 예외 방지)."""
    if not e or e.get("verdict") != "SOUND":
        return False
    if e.get("codex") is True:
        return True
    vc = e.get("verifier_count")
    return isinstance(vc, int) and not isinstance(vc, bool) and vc >= REVIEW_MIN


def has_review(rev, phase):
    """**최신** 리뷰 증거가 정족수·SOUND 인가(I-Q, R12). 옛 SOUND + 최신 UNSOUND 합성 차단."""
    return _review_ok(latest_review(rev, phase))


# ── 완료 판정: phase_done → completion_predicate (route·validator 공유, R1) ───
def approved_state(rev):
    a = _d(rev.get("approved"))
    if a.get("logic") is not True:                # 문자열 truthy·비-bool 은 미승인
        return "no"
    if a.get("ui") is not True:
        return "logic_only"
    return "yes"


def phase_done(rev, phase, track=None):
    """한 phase '완전 통과' — route·validator·completion 공유. P3/P4/P5 pass 는 리뷰증거 필수(I-Q)."""
    if phase == "P1":
        return half(rev, "P1", "logic") == "pass" and half(rev, "P1", "ui") == "pass"
    if phase == "P2":
        g = latest_gate(rev, "P2")
        return (half(rev, "P2", "logic") == "pass" and half(rev, "P2", "ui") == "pass"
                and bool(g) and g.get("result") == "GREEN")
    if phase == "P3":
        s = pstat(rev, "P3")
        if s == "skip":
            return bool(track) and track.get("visual_exempt") is True   # R11: webview 등만(문자열 truthy 차단)
        return s == "pass" and streak(rev, "P3") >= STREAK_CONVERGE and has_review(rev, "P3")
    if phase == "P4":
        return pstat(rev, "P4") == "pass" and has_review(rev, "P4")
    if phase == "P5":
        return pstat(rev, "P5") == "pass" and streak(rev, "P5") >= STREAK_CONVERGE and has_review(rev, "P5")
    if phase == "P6":
        s = pstat(rev, "P6")
        og, ns = counts_of(rev)
        if s == "skip":
            return _nnint(og) == 0 and _nnint(ns) == 0
        return s == "pass"
    return False


def _head_ok(rev):
    """R3: 완료엔 실 head 바인딩 — P2 gate + P3/P4/P5 **최신** 리뷰(SOUND·정족수)가 exec.head_commit 과 단일 일치."""
    head = _d(rev.get("exec")).get("head_commit")
    if not isinstance(head, str) or not head:              # 실 커밋 문자열만(숫자 head 거부)
        return False
    g = latest_gate(rev, "P2")
    if not g or g.get("head_commit") != head:
        return False
    for p in REVIEW_PHASES:
        if pstat(rev, p) == "skip":
            continue
        lr = latest_review(rev, p)                      # has_review 와 동일 객체
        if not (_review_ok(lr) and lr.get("head_commit") == head):
            return False
    return True


def _wellformed(rev):
    """완료판정 관련 컨테이너·스칼라가 전부 정상 shape 인가 — 손상 시 완료 fail-closed (위조/크래시 차단)."""
    if not isinstance(rev, dict) or not isinstance(rev.get("phases"), dict):
        return False
    for pk, pv in rev["phases"].items():
        if not isinstance(pv, dict):
            return False
        if pk in SPLIT_PHASES and any(s in pv and not isinstance(pv[s], dict) for s in ("logic", "ui")):
            return False
    for fld in ("exec", "counts", "approved"):
        if rev.get(fld) is not None and not isinstance(rev[fld], dict):
            return False
    ex = _d(rev.get("exec"))
    if any(k in ex and ex[k] is not None and not isinstance(ex[k], str) for k in ("branch", "head_commit")):
        return False
    c = _d(rev.get("counts"))
    if any(not (c.get(k) is None or (isinstance(c.get(k), int) and not isinstance(c.get(k), bool))) for k in ("open_gaps", "needs_sim")):
        return False
    a = _d(rev.get("approved"))
    if any(k in a and not isinstance(a[k], bool) for k in ("logic", "ui")):
        return False
    for cont in ("blocks", "awaiting", "deferred", "evidence", "cycles"):
        cv = rev.get(cont)
        if cv is not None and (not isinstance(cv, list) or not all(isinstance(x, dict) for x in cv)):
            return False
    return True


def completion_predicate(rev, track):
    """리비전이 완료(track done 가능)인가 — route DONE·validator·mark-track-done 이 이 함수 하나만 본다."""
    if not _wellformed(rev):                                        # 손상 리비전은 완료 불가(fail-closed)
        return False
    if approved_state(rev) != "yes":
        return False
    if not phase_done(rev, "P1", track):
        return False
    if open_blocks(rev):
        return False
    og, ns = counts_of(rev)
    if _nnint(og) != 0 or _nnint(ns) != 0:                          # 실 정수 0 만(bool·float·null 거부)
        return False
    if not all(phase_done(rev, p, track) for p in MAIN_PHASES):
        return False
    return _head_ok(rev)                                            # R3 실 head 바인딩


# ── 순수 route ──────────────────────────────────────────────────────────────
def _act(skill, reason, kind="ACTION"):
    return {"kind": kind, "skill": skill, "reason": reason}


def _stop(reason):
    return {"kind": "STOP", "skill": None, "reason": reason}


def route_rev(rev, track=None):
    """리비전 상태 → 정확히 하나의 결과(총함수). 모든 phase 상태 처리 + 에스컬레이션=STOP."""
    if open_blocks(rev):
        return _stop("미해소 ⛔BLOCK: " + ", ".join(str(b.get("id", "?")) for b in open_blocks(rev)))
    a = approved_state(rev)
    if a == "no":
        if half(rev, "P1", "logic") in ("unknown", "wip"):
            return _act("feature-plan", "P1 로직 계획·승인 대상 산출")
        return _stop("P1-logic 승인 대기 (State·Cubit API 동결)")
    if a == "logic_only":
        if not (half(rev, "P2", "logic") == "pass"):
            return _act("feature-implement", "P2 로직 절반 (logic-only 승인)")
        if half(rev, "P1", "ui") in ("unknown", "wip"):
            return _act("feature-plan", "P1-ui 산출 (rois.json)")
        return _stop("P1-ui 승인 대기 (rois.json 동결)")
    # a == "yes"
    if not phase_done(rev, "P2", track):
        return _act("feature-implement", "P2 미완/게이트 RED")
    if pfield(rev, "P3", "preflight_fail", False):
        return _act("feature-implement", "P3 preflight FAIL → P2 되돌림 (blocker 키 미노출)")
    if not phase_done(rev, "P3", track):
        if rnd(rev, "P3") > ESCALATE_ROUND:
            return _stop("P3 에스컬레이션 (3회 초과 — 스펙/하네스 문제 가능)")
        return _act("visual-verify", "시각 대조/수렴 (clean_streak≥2 + 리뷰증거)")
    if not phase_done(rev, "P4", track):
        return _act("feature-runtime-qa", "런타임 QA (리뷰증거 필요)")
    if not phase_done(rev, "P5", track):
        if rnd(rev, "P5") > ESCALATE_ROUND:
            return _stop("P5 에스컬레이션 (3회 초과)")
        return _act("feature-scenario-audit", "시나리오 적대 감사 (clean_streak≥2 + 리뷰증거)")
    og, ns = _nnint(counts_of(rev)[0]), _nnint(counts_of(rev)[1])   # 손상/비정수 counts → None(재감사·크래시 방지)
    if og is None or ns is None:
        return _act("feature-scenario-audit", "카운트 미확정(null) → 재감사/set-counts")
    if og > 0 or ns > 0:                                           # 갭 남음 → gap-fix(미수렴 4회면 에스컬레이션)
        if rnd(rev, "P6") > ESCALATE_ROUND:
            return _stop("P6 에스컬레이션 (3회 초과)")
        return _act("feature-gap-fix", f"갭 수정 (open_gaps={og}, needs_sim={ns})")
    if not phase_done(rev, "P6", track):                           # counts 0 이나 P6 미수렴
        if rnd(rev, "P6") > ESCALATE_ROUND:
            return _stop("P6 에스컬레이션 (3회 초과 — counts=0 이나 P6 미수렴)")
        return _act("feature-gap-fix", "P6 미완 (counts=0 이나 P6 pass/skip 아님)")
    if completion_predicate(rev, track):                          # P6 완료(pass/skip) — round 무관 DONE
        return _act(None, "완료 술어 충족 → 트랙 done 마킹", kind="DONE")
    return _act("feature-implement", "완료 전 head-bound 게이트/리뷰 증거 보강 필요 (R3/R12)")


def non_parked(tracks):
    return [t for t in tracks if t.get("status") != "parked"]


def route(state):
    out = []
    branches = _d(state.get("branches"))
    tracks = state.get("tracks", [])
    by_branch = {}
    for t in (tracks if isinstance(tracks, list) else []):
        if isinstance(t, dict):
            by_branch.setdefault(track_branch(t), []).append(t)
    names = set(branches.keys()) | set(by_branch.keys())
    for bname in sorted(names, key=lambda x: "" if x is None else str(x)):   # 혼합 타입 정렬 크래시 방지
        binfo = _d(branches.get(bname))
        btracks = by_branch.get(bname, [])
        if bname is None:
            out.append({"branch": "(브랜치 미상)", **_stop("트랙에 branch 미지정 — exec.branch/track.branch 필요")})
            continue
        if binfo.get("needs_human"):
            out.append({"branch": bname, **_stop("branch needs_human: " + str(binfo["needs_human"]))})
            continue
        active = [t for t in btracks if t.get("status") == "active"]
        if len(active) > 1:
            out.append({"branch": bname, **_stop(
                "직렬 위반: active 트랙 2+ (" + ", ".join(t["id"] for t in active) + ")")})
            continue
        if len(active) == 1:
            t = active[0]
            r = rev_of(t)
            if r is None:
                out.append({"branch": bname, "track": t["id"], **_stop("current_rev 부재")})
                continue
            res = route_rev(r, t)
            # R7: sim 점유 필요 phase 인데 udid 미지정 → STOP(reinstall-gotcha 차단)
            if res["kind"] == "ACTION" and res["skill"] in SIM_PHASES_SKILL:
                if not (_d(binfo.get("sim")).get("udid")):
                    res = _stop(f"sim UDID 미지정 — {res['skill']} 전 `dlp set-sim {bname} <udid>` 필요 (R7 lease)")
            out.append({"branch": bname, "track": t["id"], **res})
            continue
        # active 0
        eligible = non_parked(btracks)
        if len(btracks) == 0:
            out.append({"branch": bname, **_stop("빈 브랜치 (트랙 0)")})
        elif len(eligible) == 0:
            out.append({"branch": bname, **_stop(
                "모든 트랙 parked — activate 결정 필요 (dlp set-track-status <t> active)")})
        elif all(t.get("status") == "done" for t in eligible):
            rel = _d(binfo.get("release")).get("status", "pending")
            awaiting_tracks = [t["id"] for t in eligible if open_awaiting(rev_of(t))]
            if rel == "pending" and awaiting_tracks:            # done_modulo_await — 외부대기 잔존 시 auto-pr 금지
                out.append({"branch": bname, **_stop(
                    f"done_modulo_await — awaiting 잔존({', '.join(awaiting_tracks)}) → 해소 후 pr, 또는 `dlp set-release {bname} pr_open` 로 명시 승인")})
            else:
                msg = {"pending": _act("pr", "non-parked 트랙 전부 done → P7 릴리스"),
                       "parked": _stop("PR 보류 (사용자)"), "pr_open": _stop("PR 열림 — 머지 대기"),
                       "merged": _act(None, "릴리스 완료", kind="DONE")}[rel]
                out.append({"branch": bname, **msg})
        else:
            out.append({"branch": bname, **_stop(
                "active 트랙 미지정 — parked 중 하나를 activate 결정 필요")})
    return out


# ── validator ───────────────────────────────────────────────────────────────
def validate(state):
    errs = []

    def err(code, where, msg):
        errs.append(f"[{code}] {where}: {msg}")

    branches = _d(state.get("branches"))
    tracks = state.get("tracks", [])
    if not isinstance(tracks, list):
        errs.append("[I1-type] tracks: 리스트여야")
        tracks = []
    tids = [t.get("id") for t in tracks if isinstance(t, dict)]

    for bname, b in branches.items():
        if not isinstance(b, dict):
            err("I1-type", f"branch {bname}", "브랜치 정보는 dict 여야")
            continue
        rel = _d(b.get("release")).get("status")
        if rel not in RELEASE_STATUS:
            err("I1-enum", f"branch {bname}", f"release.status '{rel}' 스키마 밖")
        nh = b.get("needs_human")
        if nh is not None and not isinstance(nh, str):
            err("I1-type", f"branch {bname}", "needs_human 은 null 또는 문자열이어야")
        udid = _d(b.get("sim")).get("udid")
        if udid is not None and not isinstance(udid, str):
            err("I1-type", f"branch {bname}", "sim.udid 는 null 또는 문자열이어야")

    seen = set()
    for t in tracks:
        if not isinstance(t, dict):
            err("I1-type", "track", f"트랙이 dict 아님: {t!r}")
            continue
        tid = t.get("id", "?")
        if tid in seen:
            err("I1-dup", f"track {tid}", "중복 track id")
        seen.add(tid)
        if t.get("status") not in TRACK_STATUS:
            err("I1-enum", f"track {tid}", f"status '{t.get('status')}' 스키마 밖")
        if "visual_exempt" in t and not isinstance(t["visual_exempt"], bool):
            err("I1-type", f"track {tid}", "visual_exempt 는 bool 이어야(문자열 truthy 금지)")
        tb = track_branch(t)
        if tb is None:
            err("I1-branch", f"track {tid}", "branch 미지정(exec.branch/track.branch 필요) — route 크래시 방지")
        elif not isinstance(tb, str):
            err("I1-branch", f"track {tid}", f"branch 는 문자열이어야(값 {tb!r})")
        rev = rev_of(t)
        if rev is None:
            err("I1-rev", f"track {tid}", f"current_rev '{t.get('current_rev')}' 실재 안 함")
            continue

        # 구조 pre-pass: 컨테이너 shape 검사(손편집 손상 SSOT 도 raw 스택트레이스 대신 클린 I1-type)
        if rev.get("phases") is not None and not isinstance(rev.get("phases"), dict):
            err("I1-type", f"{tid}.phases", "phases 는 dict 여야")
            continue
        for pk, pv in _d(rev.get("phases")).items():
            if not isinstance(pv, dict):
                err("I1-type", f"{tid}.{pk}", "phase 값은 dict 여야")
            elif pk in SPLIT_PHASES:
                for side in ("logic", "ui"):
                    if side in pv and not isinstance(pv[side], dict):
                        err("I1-type", f"{tid}.{pk}.{side}", "logic/ui 값은 dict 여야")
        for fld in ("exec", "counts", "approved"):
            fv = rev.get(fld)
            if fv is not None and not isinstance(fv, dict):
                err("I1-type", f"{tid}.{fld}", f"{fld} 는 dict 여야")
        ex0 = _d(rev.get("exec"))
        for k in ("branch", "head_commit"):
            if k in ex0 and ex0[k] is not None and not isinstance(ex0[k], str):
                err("I1-type", f"{tid}.exec.{k}", "문자열이어야")
        for cname in ("blocks", "awaiting", "deferred"):
            cv = rev.get(cname)
            if cv is not None and not isinstance(cv, list):
                err("I1-type", f"{tid}.{cname}", "리스트여야")
            for it in (cv if isinstance(cv, list) else []):
                if not isinstance(it, dict):
                    err("I1-type", f"{tid}.{cname}", f"항목이 dict 아님: {it!r}")
        au = _d(rev.get("approved")).get("unknowns")
        if au is not None and not isinstance(au, list):
            err("I1-type", f"{tid}.approved.unknowns", "리스트여야")
        for it in (au if isinstance(au, list) else []):
            if not isinstance(it, dict):
                err("I1-type", f"{tid}.approved.unknowns", f"항목이 dict 아님: {it!r}")

        # I-PK 정확 phase 키 집합(여분 P7/P9 금지 + 누락 금지)
        pks = set((rev.get("phases") or {}).keys())
        if pks - PHASE_KEYS:
            err("I-PK", f"{tid}", f"여분 phase 키 {sorted(pks - PHASE_KEYS)} (P7=branch.release)")
        if PHASE_KEYS - pks:
            err("I-PK", f"{tid}", f"누락 phase 키 {sorted(PHASE_KEYS - pks)}")
        for p in ["P1", "P2"]:
            for side in ("logic", "ui"):
                s = half(rev, p, side)
                if s not in PHASE_STATUS or s == "skip":
                    err("I1-enum", f"{tid}.{p}.{side}", f"status '{s}' 불가(split·skip 금지)")
        for p in ["P3", "P4", "P5", "P6"]:
            s = pstat(rev, p)
            if s not in PHASE_STATUS:
                err("I1-enum", f"{tid}.{p}", f"status '{s}' 스키마 밖")
            if s == "skip" and p in NO_SKIP_PHASES:
                err("I1-skip", f"{tid}.{p}", "이 phase 는 skip 불가")
            sr = pfield(rev, p, "skip_reason")
            if s == "skip" and sr is not None and sr not in SKIP_REASONS:
                err("I1-enum", f"{tid}.{p}", f"skip_reason '{sr}' 스키마 밖")
        og, ns = counts_of(rev)
        for nm, v in (("open_gaps", og), ("needs_sim", ns)):
            if _int_or_none(v) == "BAD" or (isinstance(v, int) and not isinstance(v, bool) and v < 0):
                err("I1-counts", f"{tid}.{nm}", f"'{v}' 는 정수≥0 또는 null 이어야(bool 금지)")
        a0 = rev.get("approved") or {}
        for s in ("logic", "ui"):
            if s in a0 and not isinstance(a0[s], bool):
                err("I1-type", f"{tid}.approved.{s}", "bool 이어야(문자열 truthy 금지)")
        for p in ["P3", "P5", "P6"]:
            for fld in ("clean_streak", "round"):
                fv = pfield(rev, p, fld)
                if fv is not None and _nnint(fv) is None:
                    err("I1-type", f"{tid}.{p}.{fld}", f"'{fv}' 는 비-bool 정수≥0 이어야")
        for b in _dicts(rev.get("blocks")):
            if b.get("status", "open") not in BLOCK_STATUS:
                err("I1-enum", f"{tid}.block {b.get('id')}", "status 스키마 밖")
            if "id" in b and not isinstance(b["id"], str):
                err("I1-type", f"{tid}.block", f"block id 는 문자열이어야: {b.get('id')!r}")
        evlist = rev.get("evidence", [])
        if not isinstance(evlist, list):
            err("I1-type", f"{tid}.evidence", "evidence 는 리스트여야")
            evlist = []
        for e in evlist:
            if not isinstance(e, dict):
                err("I1-type", f"{tid}.evidence", f"항목이 dict 아님: {e!r}")
                continue
            k = e.get("kind")
            if k not in EVIDENCE_KINDS:
                err("I1-enum", f"{tid}.evidence", f"kind '{k}' 스키마 밖")
                continue
            for f in EVIDENCE_REQUIRED.get(k, []):        # I-EV 타입드 payload(필드 존재)
                if e.get(f) in (None, ""):
                    err("I-EV", f"{tid}.evidence({k})", f"필수필드 '{f}' 누락")
            # 타입/enum (문자열 truthy·잘못된 값 차단)
            if "verifier_count" in e and not (isinstance(e["verifier_count"], int) and not isinstance(e["verifier_count"], bool) and e["verifier_count"] >= 0):
                err("I-EV", f"{tid}.evidence({k})", "verifier_count 는 정수≥0")
            if "codex" in e and not isinstance(e["codex"], bool):
                err("I-EV", f"{tid}.evidence({k})", "codex 는 bool")
            if "head_commit" in e and not isinstance(e["head_commit"], str):
                err("I-EV", f"{tid}.evidence({k})", "head_commit 는 문자열이어야")
            if k == "review" and e.get("verdict") not in ("SOUND", "UNSOUND"):
                err("I-EV", f"{tid}.evidence(review)", f"verdict '{e.get('verdict')}' 스키마 밖")
            if k == "gate" and e.get("result") not in ("GREEN", "RED"):
                err("I-EV", f"{tid}.evidence(gate)", f"result '{e.get('result')}' 스키마 밖")
            # head 필수(gate/review/live_e2e) — board-migration 만 예외(완료엔 못 씀, _head_ok 가 실 head 요구)
            if k in ("gate", "review", "live_e2e") and not e.get("head_commit") and e.get("source") != "board-migration":
                err("I-EV", f"{tid}.evidence({k})", "head_commit 필수(신규 증거) — board-migration 만 예외")

        # I-M 단조성(P1 포함): phase pass ⇒ 선행 전부 done
        def _is_pass(pp):
            if pp in ("P1", "P2"):
                return half(rev, pp, "logic") == "pass" and half(rev, pp, "ui") == "pass"
            return pstat(rev, pp) == "pass"
        for i, p in enumerate(MONO_PHASES):
            if _is_pass(p):
                for q in MONO_PHASES[:i]:
                    if not phase_done(rev, q, t):
                        err("I-M", f"{tid}.{p}", f"pass 인데 선행 {q} 미완(단조성 — 순서역행/미승인/RED/무증거 위 pass)")
        # P2 양 절반 pass ⇒ 최신 P2 gate GREEN (게이트 없는 P2 pass 차단)
        if half(rev, "P2", "logic") == "pass" and half(rev, "P2", "ui") == "pass":
            g = latest_gate(rev, "P2")
            if not g or g.get("result") != "GREEN":
                err("I-M", f"{tid}.P2", "P2 양 절반 pass 인데 최신 P2 gate 가 GREEN 아님")

        # I-W 리비전내 직렬: wip ≤1
        wips = [p for p in ["P3", "P4", "P5", "P6"] if pstat(rev, p) == "wip"]
        wips += [f"{p}.{s}" for p in ["P1", "P2"] for s in ("logic", "ui") if half(rev, p, s) == "wip"]
        if len(wips) > 1:
            err("I-W", f"{tid}", f"동시 wip {len(wips)}개({', '.join(wips)}) — 리비전내 직렬 위반")

        # I-A 승인 ↔ P1/P2 양방향
        a = _d(rev.get("approved"))
        if a.get("logic"):
            if half(rev, "P1", "logic") != "pass":
                err("I-A", f"{tid}", "approved.logic=true 인데 P1.logic!=pass")
            if not approval_evidence(rev, "logic"):
                err("I-A", f"{tid}", "approved.logic=true 인데 approval(logic) 증거 없음")
            for u in _dicts(a.get("unknowns")):
                if u.get("shakes_state") and u.get("resolution") != "answered":
                    err("I-A", f"{tid}", f"미해결 shakes_state '{u.get('desc')}' 있는데 logic 승인")
        if a.get("ui"):
            if half(rev, "P1", "ui") != "pass":
                err("I-A", f"{tid}", "approved.ui=true 인데 P1.ui!=pass")
            if not a.get("rois_digest"):
                err("I-A", f"{tid}", "approved.ui=true 인데 rois_digest 없음")
            if not approval_evidence(rev, "ui"):
                err("I-A", f"{tid}", "approved.ui=true 인데 approval(ui) 증거 없음")
        if half(rev, "P2", "logic") == "pass" and not a.get("logic"):
            err("I-A2", f"{tid}", "P2.logic=pass 인데 approved.logic 아님(구현이 승인 앞섬)")
        if half(rev, "P2", "ui") == "pass" and not a.get("ui"):
            err("I-A2", f"{tid}", "P2.ui=pass 인데 approved.ui 아님")

        # I-Q 정족수: P3/P4/P5 pass ⇒ 리뷰증거(자평 금지의 코드 강제)
        for p in REVIEW_PHASES:
            if pstat(rev, p) == "pass" and not has_review(rev, p):
                err("I-Q", f"{tid}.{p}", "pass 인데 SOUND 리뷰증거(격리≥3/codex) 없음 — 검증 없는 완료 차단")

        # I-V P3 skip ⇒ visual_exempt · skip_reason structural/norev
        if pstat(rev, "P3") == "skip":
            if t.get("visual_exempt") is not True:
                err("I-V", f"{tid}.P3", "P3=skip 인데 visual_exempt 아님(시각검증 무단 우회)")
        # I-PF preflight_fail ⇒ P3∈{unknown,wip}
        if pfield(rev, "P3", "preflight_fail", False) and pstat(rev, "P3") not in ("unknown", "wip"):
            err("I-PF", f"{tid}.P3", "preflight_fail=true 인데 P3 가 pass/skip")
        # I-P6 P6 skip ⇒ counts 0/0
        if pstat(rev, "P6") == "skip" and not (_nnint(og) == 0 and _nnint(ns) == 0):
            err("I-P6", f"{tid}.P6", f"P6=skip(derived) 인데 counts={og}/{ns}≠(정수0) (모순)")

        # I-C fabricated done 금지
        if t.get("status") == "done" and not completion_predicate(rev, t):
            err("I-C", f"{tid}", "track.status=done 인데 completion_predicate 거짓 (fabricated done)")

        # I-P parent_track 참조
        pt = t.get("parent_track")
        if pt and pt not in tids:
            err("I-P", f"{tid}", f"parent_track '{pt}' 실재 안 함")

        # I-T route 총함수
        try:
            r = route_rev(rev, t)
            assert r.get("kind") in ("ACTION", "STOP", "DONE")
        except Exception as ex:  # noqa: BLE001
            err("I-T", f"{tid}", f"route_rev 예외: {ex}")

    # I-B 브랜치 직렬 · I-S sim 상호배타(null udid on active 도 결함)
    by_branch = {}
    for t in tracks:
        if isinstance(t, dict):
            by_branch.setdefault(track_branch(t), []).append(t)
    udid_owner = {}
    for bname, bt in by_branch.items():
        act = [t["id"] for t in bt if t.get("status") == "active"]
        if len(act) > 1:
            err("I-B", f"branch {bname}", f"active 트랙 {len(act)}개({', '.join(act)}) — 직렬 위반")
        if not act:
            continue
        # active 브랜치의 sim.udid 검사(중복만 — null 은 route 가 sim-phase 진입 시 STOP 하므로 여기선 경고성)
        udid = _d(_d(branches.get(bname)).get("sim")).get("udid")
        if udid:
            if udid in udid_owner:
                err("I-S", f"branch {bname}", f"sim udid {udid} 를 {udid_owner[udid]} 와 공유(active 병렬 오염)")
            udid_owner[udid] = bname

    xcc = state.get("cross_cutting")
    if xcc is not None and not isinstance(xcc, list):
        err("I1-type", "cross_cutting", "리스트여야")
    for it in (xcc if isinstance(xcc, list) else []):
        if not isinstance(it, dict):
            err("I1-type", "cross_cutting", f"항목이 dict 아님: {it!r}")
    for xc in _dicts(xcc):
        if xc.get("status") not in ("open", "closed"):
            err("I-X", f"cross_cutting {xc.get('id')}", f"status '{xc.get('status')}' 불가")
        for nested in ("carry_items", "deferred", "evidence"):
            nv = xc.get(nested)
            if nv is not None and (not isinstance(nv, list) or not all(isinstance(x, dict) for x in nv)):
                err("I1-type", f"cross_cutting {xc.get('id')}.{nested}", "dict 리스트여야")

    return errs


# ── render ───────────────────────────────────────────────────────────────────
SYM = {"pass": "✅", "wip": "🔄", "unknown": "⬜", "skip": "⤫"}


def _cs(rev, p):
    return SYM.get(half(rev, p, "logic"), "?") + "/" + SYM.get(half(rev, p, "ui"), "?")


def _c(rev, p):
    s = pstat(rev, p)
    base = SYM.get(s, "?")
    if p in ("P3", "P5") and s == "pass":
        base += f"·{streak(rev, p)}"
    return base


def render(state):
    L = ["# 개발 7-Phase 진행판 (생성물 — 손편집 금지)", "",
         "> ⚠ 이 파일은 `develop-looping-process-state.json` 에서 `python3 scripts/dlp.py render` 로 생성됩니다. **직접 수정하지 마세요** — state.json 을 `dlp` 뮤테이션으로 고치면 자동 재생성됩니다.",
         "> phase 기호: ✅pass · 🔄wip · ⬜unknown · ⤫skip. P1/P2 는 L(logic)/U(ui) 절반. 완료 = `completion_predicate`(설계 §R1, 리뷰증거+head 바인딩). 직렬 = 브랜치당 active 1개.",
         "", "## 다음 액션 (route — 순수 함수 계산)", "",
         "| 브랜치 | 트랙 | 판정 | 다음 스킬 | 사유 |", "|---|---|---|---|---|"]
    for r in route(state):
        L.append(f"| {r['branch']} | {r.get('track', '—')} | {r['kind']} | {r.get('skill') or '—'} | {r['reason']} |")
    L.append("")
    by_branch = {}
    for t in (state.get("tracks", []) if isinstance(state.get("tracks"), list) else []):
        if isinstance(t, dict):
            by_branch.setdefault(track_branch(t), []).append(t)
    L.append("## 브랜치별 트랙")
    for bname in sorted(by_branch, key=lambda x: "" if x is None else str(x)):
        b = _d(_d(state.get("branches")).get(bname))
        sim, rel = _d(b.get("sim")), _d(b.get("release"))
        L += ["", f"### {bname}"]
        meta = []
        if sim.get("device"):
            meta.append(f"sim={sim['device']}" + (f"({sim['udid']})" if sim.get("udid") else "(udid 미지정)"))
        if rel.get("status"):
            meta.append(f"release={rel['status']}" + (f"(PR#{rel['pr']})" if rel.get("pr") else ""))
        if b.get("needs_human"):
            meta.append(f"⚠needs_human={b['needs_human']}")
        if meta:
            L.append("> " + " · ".join(meta))
        L += ["", "| 트랙 | 상태 | rev | P1 L/U | P2 L/U | P3 | P4 | P5 | P6 | gaps/sim | blk | awt | dfr |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for t in by_branch[bname]:
            rev = rev_of(t)
            if rev is None:
                L.append(f"| {t['id']} | {t.get('status')} | — | (rev 부재) | | | | | | | | | |")
                continue
            og, ns = counts_of(rev)
            cnt = f"{og if og is not None else '?'}/{ns if ns is not None else '?'}"
            L.append(f"| {t['id']} | {t.get('status')} | {t.get('current_rev', '?')} | {_cs(rev, 'P1')} "
                     f"| {_cs(rev, 'P2')} | {_c(rev, 'P3')} | {_c(rev, 'P4')} | {_c(rev, 'P5')} | {_c(rev, 'P6')} "
                     f"| {cnt} | {_len(open_blocks(rev)) or '—'} | {_len(rev.get('awaiting')) or '—'} "
                     f"| {_len(rev.get('deferred')) or '—'} |")
    xcs = state.get("cross_cutting", [])
    if xcs:
        L += ["", "## 교차 항목 (cross_cutting)", "", "| id | status | carry | deferred |", "|---|---|---|---|"]
        for xc in _dicts(xcs):
            L.append(f"| {xc.get('id')} | {xc.get('status')} | {_len(xc.get('carry_items'))} | {_len(xc.get('deferred'))} |")
    L.append("")
    return "\n".join(L) + "\n"


# ── needs-human (미결 사람-결정 다이제스트 — route STOP + 트랙별 미결 한 화면) ──
def needs_human_report(state):
    L = ["# 미결 사람-결정 다이제스트 (dlp needs-human)", "",
         "> route STOP(브랜치 결정점) + 트랙별 미결을 한 화면에. 각 항목 옆이 해소 뮤테이션.", ""]
    stops = [r for r in route(state) if r["kind"] == "STOP"]
    if stops:
        L.append("## 브랜치 결정점 (route STOP)")
        for r in stops:
            tr = f" [{r['track']}]" if r.get("track") else ""
            L.append(f"- **{r['branch']}**{tr}: {r['reason']}")
        L.append("")
    L.append("## 트랙별 미결 항목")
    any_track = False
    for t in state.get("tracks", []):
        if not isinstance(t, dict):
            continue
        rev = rev_of(t)
        if rev is None:
            continue
        items = []
        ob = open_blocks(rev)
        if ob:
            items.append(f"⛔BLOCK {len(ob)}({', '.join(str(b.get('id')) for b in ob)}) → resolve-block")
        aw = open_awaiting(rev)
        if aw:
            items.append(f"awaiting {len(aw)}({', '.join(str(w.get('party')) for w in aw)}) → resolve-await")
        og, ns = counts_of(rev)
        if og is None or ns is None:
            items.append("counts 미확정 → set-counts(P5 리뷰 선행)")
        unresolved = [u for u in _dicts(_d(rev.get("approved")).get("unknowns"))
                      if u.get("shakes_state") and u.get("resolution") != "answered"]
        if unresolved:
            items.append(f"미해결 shakes_state {len(unresolved)} → resolve-unknown")
        if (approved_state(rev) == "yes" and _nnint(og) == 0 and _nnint(ns) == 0
                and all(phase_done(rev, p, t) for p in MAIN_PHASES) and not _head_ok(rev)):
            items.append("done 후보이나 head 미포착 → capture-head")
        if items:
            any_track = True
            L.append(f"- **{t.get('id')}** [{t.get('status')}]: " + " · ".join(items))
    if not any_track:
        L.append("- (트랙별 미결 없음)")
    L.append("")
    return "\n".join(L) + "\n"


# ── audit (마이그레이션 모순 자동검출 — 원본보드 대상, 추정 금지) ────────────────
_SYM2ST = {"✅": "pass", "🔄": "wip", "⬜": "unknown", "N/A": "skip", "⏸": "hold", "": "unknown"}


def _read_source(source):
    """source 경로에서 원본 보드 텍스트. 'git:<ref>:<path>' 형식이면 git show."""
    if source and source.startswith("git:"):
        _, ref, path = source.split(":", 2)
        return subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT,
                              capture_output=True, text=True).stdout
    return Path(source).read_text(encoding="utf-8")


def audit(source):
    text = _read_source(source)
    lines = text.splitlines()
    hdr = next((i for i, l in enumerate(lines) if l.startswith("|") and "기능(feature)" in l), None)
    R = ["# develop-looping-process migration/audit 리포트", "",
         f"> 생성 = `dlp audit`. 원본 = {source}. **추정 금지** — 모순은 needs_human 으로 표면화, 자동 확정 금지.", ""]
    if hdr is None:
        R.append("**⛔ 표 헤더('기능(feature)') 못 찾음 → 전체 수동.** (원본 보드가 아닌 생성 뷰를 가리켰을 수 있음 — --source 확인)")
        return "\n".join(R) + "\n"
    header = [c.strip() for c in lines[hdr].strip().strip("|").split("|")]
    ncol = len(header)
    R += [f"헤더 {ncol}열. 위치: 0=feature,1..7=P1..P7,8=approved,9=gate,10=open_gaps,11=needs_sim,12=next,13=notes.", "", "## 행별 판정"]
    total = 0
    j = hdr + 2
    while j < len(lines):
        line = lines[j]
        if line.startswith("## "):
            break
        if not line.startswith("|") or set(line.strip()) <= set("-:| "):
            j += 1
            continue
        raw = line.rstrip()
        cells = [c.strip() for c in raw.strip().strip("|").split("|")]
        feat = cells[0] if cells else "?"
        if len(cells) != ncol:
            h = hashlib.sha1(raw.encode()).hexdigest()[:10]
            R += [f"\n### ⛔ `{feat[:44]}` — 파손행 {len(cells)}열≠{ncol}열 (pipe {raw.count('|')}, hash {h})",
                  "  - **needs_human**: 열 어긋남 → 부분파싱 위험. 프로즈 추정 금지, 수동 manifest 필요. raw 는 dlp-notes 보존."]
            total += 1
            j += 1
            continue
        ph = [_SYM2ST.get(cells[k], cells[k]) for k in range(1, 8)]
        approved = cells[8] if ncol > 8 else ""
        og_raw, ns_raw = (cells[10] if ncol > 10 else ""), (cells[11] if ncol > 11 else "")
        nxt = cells[12] if ncol > 12 else ""
        notes = cells[13] if ncol > 13 else ""

        def ac(x):
            x = x.strip()
            return None if x in ("?", "—", "-", "") else (int(x) if x.lstrip("-").isdigit() else None)
        og, ns = ac(og_raw), ac(ns_raw)
        flags = []
        for k in range(7):
            if ph[k] == "pass":
                for m in range(k):
                    if ph[m] not in ("pass", "skip"):
                        flags.append(f"(e)순서역행: P{k+1}=pass 인데 P{m+1}={ph[m]}")
                        break
        if sum(1 for s in ph if s == "wip") > 1:
            flags.append(f"(g)다중 wip {sum(1 for s in ph if s=='wip')}개(리비전내 직렬 위반)")
        if og is None or ns is None:
            if any(ph[k] == "pass" for k in range(3, 7)):
                flags.append(f"(i)완료판정 불가: counts={og_raw!r}/{ns_raw!r}(null) 인데 P4~ pass → done 확정 금지")
        elif ph[4] not in ("pass", "skip"):
            flags.append(f"(f)counts={og}/{ns} 정수인데 P5={ph[4]}(미완) — 갭 단정")
        m2 = {"feature-plan": 1, "feature-implement": 2, "visual-verify": 3, "feature-runtime-qa": 4,
              "feature-scenario-audit": 5, "feature-gap-fix": 6, "pr": 7}
        for sk, pn in m2.items():
            if sk != "pr" and ph[pn - 1] == "pass" and (nxt.strip() == sk or f"next={sk}" in notes.replace(" ", "")):
                flags.append(f"(h)next='{sk}'(P{pn}) 인데 P{pn} 셀=pass — 모순")
        if "hold" in ph:
            flags.append("(k)⏸ hold → branch.release=parked 로, phase 아님")
        if len(notes) > 1500:
            flags.append(f"(j)거대 notes {len(notes)}자 → 자동 분해 금지, raw 보존 + 수동 리비전 manifest")
        done_ok = (og == 0 and ns == 0 and all(ph[k] in ("pass", "skip") for k in range(6)))
        R += [f"\n### `{feat[:44]}`",
              f"  - phases P1..P7 = {ph} · approved={approved!r} · counts={og_raw!r}/{ns_raw!r} · next={nxt!r}",
              f"  - 초안 권고: **{'done(후보)' if done_ok else 'parked'}** (done 은 counts 0/0 + 전 phase pass/skip + 리뷰증거+head 일 때만)"]
        if flags:
            total += len(flags)
            R += [f"  - ⚠ {f} → **needs_human**" for f in flags]
        else:
            R.append("  - 모순 검출 없음(단, 프로즈 근거·검증증거는 사람 확인).")
        j += 1
    R += ["", f"## 요약: 검출 플래그 {total}건. 모두 사람이 state.json 저작 시 해소한다(추정 금지).",
          "> done 자동확정 금지 · P3~P6 provisional pass 는 리뷰증거 없으면 unknown 강등 · 거대셀 raw 보존 · 파손행 수동."]
    return "\n".join(R) + "\n"


# ── 뮤테이션 ──────────────────────────────────────────────────────────────────
def _find_track(state, tid):
    for t in state.get("tracks", []):
        if t.get("id") == tid:
            return t
    raise SystemExit(f"track '{tid}' 없음")


def _find_rev(track, rev_id):
    for r in track.get("revisions", []):
        if r.get("rev") == rev_id:
            return r
    raise SystemExit(f"track '{track.get('id')}' 에 rev '{rev_id}' 없음")


def _ensure_branch(s, name):
    """브랜치 항목을 release 기본값(pending)과 함께 보장 — 항목 신설이 release 누락으로 validate FAIL 나지 않게."""
    b = s.setdefault("branches", {}).setdefault(name, {})
    b.setdefault("release", {"status": "pending"})
    return b


def _apply(fn):
    state = load_state()
    fn(state)
    errs = validate(state)
    if errs:
        print(f"뮤테이션 거부 — validate FAIL ({len(errs)}) (파일 미변경):")
        for e in errs:
            print("  " + e)
        return 1
    save_state(state)
    STATUS_MD.write_text(render(state), encoding="utf-8")
    print("OK (validate GREEN · status.md 재생성)")
    return 0


def cmd_validate(args):
    errs = validate(load_state())
    if errs:
        print(f"VALIDATE FAIL ({len(errs)}):")
        for e in errs:
            print("  " + e)
        return 1
    print("VALIDATE OK")
    return 0


def cmd_route(args):
    state = load_state()
    errs = validate(state)
    if errs:                                    # route 는 성한 상태에서만(bad-type 크래시 방지)
        print(f"ROUTE 거부 — 먼저 validate 실패 ({len(errs)}). `dlp validate` 로 확인/복구.")
        for e in errs[:8]:
            print("  " + e)
        return 1
    for r in route(state):
        extra = f" → {r['skill']}" if r.get("skill") else ""
        tr = f" [{r['track']}]" if r.get("track") else ""
        print(f"{r['branch']}{tr}: {r['kind']}{extra} — {r['reason']}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="dlp", description="develop-looping-process 검증 가능 상태 머신")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate")
    sub.add_parser("route")
    sub.add_parser("selftest")
    rn = sub.add_parser("render")
    rn.add_argument("--check", action="store_true")
    au = sub.add_parser("audit")
    _src = str(ORIG_PRESERVED) if ORIG_PRESERVED.exists() else "git:HEAD:docs/renew-guide/impl/settings/develop-looping-process-status.md"
    au.add_argument("--source", default=_src)   # 보존 원본 우선(생성 뷰 커밋 후에도 안전), 없으면 git HEAD
    au.add_argument("--out", default=str(REPORT_MD))

    sp = sub.add_parser("set-phase")
    sp.add_argument("track"); sp.add_argument("rev"); sp.add_argument("phase", choices=sorted(PHASE_KEYS))
    sp.add_argument("status", choices=sorted(PHASE_STATUS)); sp.add_argument("--side", choices=["logic", "ui"])
    sp.add_argument("--clean-streak", type=int); sp.add_argument("--round", type=int)
    sp.add_argument("--preflight-fail", dest="pf", action="store_true"); sp.add_argument("--skip-reason", choices=sorted(SKIP_REASONS))

    sc = sub.add_parser("set-counts"); sc.add_argument("track"); sc.add_argument("rev")
    sc.add_argument("--open-gaps", type=int, required=True); sc.add_argument("--needs-sim", type=int, required=True)

    ap = sub.add_parser("approve"); ap.add_argument("track"); ap.add_argument("rev")
    ap.add_argument("--logic", action="store_true"); ap.add_argument("--ui", action="store_true")
    ap.add_argument("--by", default="사람"); ap.add_argument("--at", required=True); ap.add_argument("--rois-digest")

    ae = sub.add_parser("add-evidence"); ae.add_argument("track"); ae.add_argument("rev")
    ae.add_argument("kind", choices=sorted(EVIDENCE_KINDS))
    for o in ["--phase", "--result", "--commit", "--head-commit", "--command", "--scope", "--verdict",
              "--device", "--backend", "--test-ref", "--base", "--mechanism", "--note", "--desc", "--artifact-digest"]:
        ae.add_argument(o)
    ae.add_argument("--count", type=int); ae.add_argument("--verifier-count", type=int)
    ae.add_argument("--codex", action="store_true"); ae.add_argument("--red-proven", action="store_true")

    acy = sub.add_parser("add-cycle"); acy.add_argument("track"); acy.add_argument("rev")
    acy.add_argument("--phase", required=True); acy.add_argument("--found", type=int, default=0)
    acy.add_argument("--resolved", type=int, default=0); acy.add_argument("--remaining", type=int, default=0)
    acy.add_argument("--note", default="")

    ts = sub.add_parser("set-track-status"); ts.add_argument("track"); ts.add_argument("status", choices=sorted(TRACK_STATUS))
    sub.add_parser("mark-track-done").add_argument("track")

    at = sub.add_parser("add-track"); at.add_argument("id"); at.add_argument("--feature", required=True)
    at.add_argument("--title", required=True); at.add_argument("--branch", required=True)
    at.add_argument("--rev", default="v1"); at.add_argument("--parent")

    sr = sub.add_parser("set-release"); sr.add_argument("branch"); sr.add_argument("status", choices=sorted(RELEASE_STATUS)); sr.add_argument("--pr", type=int)
    ss = sub.add_parser("set-sim"); ss.add_argument("branch"); ss.add_argument("udid"); ss.add_argument("--device")
    sh = sub.add_parser("set-head"); sh.add_argument("track"); sh.add_argument("rev"); sh.add_argument("head_commit")
    cph = sub.add_parser("capture-head"); cph.add_argument("track"); cph.add_argument("rev")   # git rev-parse HEAD 자동
    sub.add_parser("needs-human")   # 미결 사람-결정 다이제스트(read-only)
    auk = sub.add_parser("add-unknown"); auk.add_argument("track"); auk.add_argument("rev")
    auk.add_argument("--desc", required=True); auk.add_argument("--shakes-state", action="store_true")
    ruk = sub.add_parser("resolve-unknown"); ruk.add_argument("track"); ruk.add_argument("rev")
    ruk.add_argument("--desc", required=True); ruk.add_argument("--resolution", default="answered")

    ab = sub.add_parser("add-block"); ab.add_argument("track"); ab.add_argument("rev")
    ab.add_argument("--id", required=True); ab.add_argument("--user-literal", required=True); ab.add_argument("--actor", default="사람")
    rb = sub.add_parser("resolve-block"); rb.add_argument("track"); rb.add_argument("rev")
    rb.add_argument("--id", required=True); rb.add_argument("--resolution", required=True); rb.add_argument("--actor", default="사람")

    aw = sub.add_parser("add-await"); aw.add_argument("track"); aw.add_argument("rev")
    aw.add_argument("--desc", required=True); aw.add_argument("--party", choices=["be", "designer", "user"], required=True)
    rw = sub.add_parser("resolve-await"); rw.add_argument("track"); rw.add_argument("rev"); rw.add_argument("--desc", required=True)

    ad = sub.add_parser("add-deferred"); ad.add_argument("track"); ad.add_argument("rev")
    ad.add_argument("--desc", required=True); ad.add_argument("--reason", choices=["intended", "followup", "harness"], required=True)
    ad.add_argument("--gate", choices=["designer", "be", "touch"], default="touch")

    ah = sub.add_parser("add-handoff"); ah.add_argument("track"); ah.add_argument("rev")
    ah.add_argument("--from-ctx", required=True); ah.add_argument("--to-ctx", required=True)
    ah.add_argument("--at", required=True); ah.add_argument("--reason", default="")

    ax = sub.add_parser("add-cross-cutting"); ax.add_argument("id"); ax.add_argument("--title", default="")
    cx = sub.add_parser("close-cross-cutting"); cx.add_argument("id"); cx.add_argument("--at", required=True)

    nh = sub.add_parser("set-needs-human"); nh.add_argument("branch"); nh.add_argument("msg")
    ch = sub.add_parser("clear-needs-human"); ch.add_argument("branch")

    a = p.parse_args(argv)
    c = a.cmd
    if c == "validate":
        return cmd_validate(a)
    if c == "route":
        return cmd_route(a)
    if c == "selftest":
        return selftest()
    if c == "render":
        state = load_state(); out = render(state)
        if a.check:
            cur = STATUS_MD.read_text(encoding="utf-8") if STATUS_MD.exists() else ""
            if cur != out:
                print("RENDER --check FAIL: status.md ≠ 생성 뷰(손편집/드리프트). 복구: `python3 scripts/dlp.py render`")
                return 1
            print("RENDER --check OK"); return 0
        STATUS_MD.write_text(out, encoding="utf-8"); print(f"RENDERED → {STATUS_MD}"); return 0
    if c == "audit":
        rep = audit(a.source)
        Path(a.out).write_text(rep, encoding="utf-8")
        print(f"AUDIT → {a.out}")
        return 0
    if c == "needs-human":
        print(needs_human_report(load_state()))
        return 0
    # ── 뮤테이션 dispatch ──
    if c == "set-phase":
        def f(s):
            rev = _find_rev(_find_track(s, a.track), a.rev)
            ph = rev.setdefault("phases", {})
            if a.phase in SPLIT_PHASES:
                if a.side not in ("logic", "ui"):
                    raise SystemExit(f"{a.phase} 는 --side logic|ui 필요")
                ph.setdefault(a.phase, {}).setdefault(a.side, {})["status"] = a.status
            else:
                node = ph.setdefault(a.phase, {}); node["status"] = a.status
                if a.clean_streak is not None:
                    node["clean_streak"] = a.clean_streak
                if a.round is not None:
                    node["round"] = a.round
                if a.pf:
                    node["preflight_fail"] = True
                if a.skip_reason:
                    node["skip_reason"] = a.skip_reason
            if a.phase == "P2" and a.status == "pass":
                ph.get("P3", {}).pop("preflight_fail", None)
        return _apply(f)
    if c == "set-counts":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            if not has_review(r, "P5"):
                raise SystemExit("set-counts 전 P5 리뷰증거 필요(감사 실행 근거) — add-evidence review --phase P5 …")
            r.setdefault("counts", {}).update(open_gaps=a.open_gaps, needs_sim=a.needs_sim)
        return _apply(f)
    if c == "approve":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev); ap_ = r.setdefault("approved", {})
            if a.logic:
                ap_["logic"] = True
                r.setdefault("evidence", []).append({"kind": "approval", "scope": "logic", "actor": a.by, "at": a.at})
            if a.ui:
                ap_["ui"] = True
                if a.rois_digest:
                    ap_["rois_digest"] = a.rois_digest
                r.setdefault("evidence", []).append({"kind": "approval", "scope": "ui", "actor": a.by, "at": a.at})
            ap_["by"] = a.by; ap_["at"] = a.at
        return _apply(f)
    if c == "add-evidence":
        vals = {k: getattr(a, k) for k in ["phase", "result", "commit", "head_commit", "command",
                "scope", "verdict", "device", "backend", "test_ref", "base", "mechanism", "note", "desc", "artifact_digest"]}
        merged = {**vals, "verifier_count": a.verifier_count, "count": a.count}   # typed arg 도 필수검사 대상
        for rf in EVIDENCE_REQUIRED.get(a.kind, []):
            if merged.get(rf) in (None, ""):
                raise SystemExit(f"{a.kind} 증거 필수필드 --{rf.replace('_', '-')} 누락")
        if a.kind in ("gate", "review", "live_e2e") and not a.head_commit:
            raise SystemExit(f"{a.kind} 증거는 --head-commit 필수(R3 stale-gate 차단)")
        if a.kind == "review" and not (a.codex or (a.verifier_count is not None and a.verifier_count >= REVIEW_MIN)):
            raise SystemExit(f"review 증거는 --codex 또는 --verifier-count≥{REVIEW_MIN} (정족수)")

        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            e = {"kind": a.kind}
            for k, v in vals.items():
                if v is not None:
                    e[k] = v
            if a.count is not None:
                e["count"] = a.count
            if a.verifier_count is not None:
                e["verifier_count"] = a.verifier_count
            if a.codex:
                e["codex"] = True
            if a.red_proven:
                e["red_proven"] = True
            # R3 downstream 무효화 — 새 head(코드변경) 일 때만(같은 head 재기록은 유지, M8).
            #   status 뿐 아니라 수렴 메타(streak·round·counts·P6 skip)도 폐기 — 옛 head 수렴 재사용 차단.
            if a.kind == "gate" and a.phase == "P2" and a.result == "GREEN":
                prev = latest_gate(r, "P2")
                if not (prev and prev.get("head_commit") == a.head_commit):
                    ph = r.setdefault("phases", {})
                    for dp in ["P3", "P4", "P5"]:                 # P3 skip(visual_exempt)=트랙속성이라 status 는 pass 만 되돌림
                        node = ph.setdefault(dp, {})
                        if node.get("status") == "pass":
                            node["status"] = "unknown"
                        node.pop("clean_streak", None)
                        node.pop("round", None)
                    p6 = ph.setdefault("P6", {})
                    if p6.get("status") in ("pass", "skip"):      # P6 derived-skip 은 counts 의존 → 무효
                        p6["status"] = "unknown"
                    p6.pop("skip_reason", None)
                    p6.pop("round", None)
                    r.setdefault("counts", {}).update(open_gaps=None, needs_sim=None)
            r.setdefault("evidence", []).append(e)
        return _apply(f)
    if c == "add-cycle":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev); cy = r.setdefault("cycles", [])
            cy.append({"n": len(cy) + 1, "phase": a.phase, "found": a.found, "resolved": a.resolved,
                       "remaining": a.remaining, "note": a.note})
        return _apply(f)
    if c == "set-track-status":
        def f(s):
            t = _find_track(s, a.track)
            if a.status == "done" and not completion_predicate(rev_of(t), t):
                raise SystemExit("완료 술어 미충족 — done 불가")
            t["status"] = a.status
            if a.status == "active":
                bn = track_branch(t)
                if bn in s.get("branches", {}):
                    s["branches"][bn]["needs_human"] = None
        return _apply(f)
    if c == "mark-track-done":
        def f(s):
            t = _find_track(s, a.track)
            if not completion_predicate(rev_of(t), t):
                raise SystemExit("완료 술어 미충족 — done 불가")
            t["status"] = "done"
        return _apply(f)
    if c == "add-track":
        def f(s):
            if any(t.get("id") == a.id for t in s.get("tracks", [])):
                raise SystemExit(f"track '{a.id}' 이미 존재")
            s.setdefault("tracks", []).append({
                "id": a.id, "feature": a.feature, "title": a.title, "branch": a.branch,
                "parent_track": a.parent, "status": "parked", "visual_exempt": False, "current_rev": a.rev,
                "revisions": [{"rev": a.rev, "exec": {"branch": a.branch}, "approved": {"logic": False, "ui": False},
                               "phases": {"P1": {"logic": {"status": "unknown"}, "ui": {"status": "unknown"}},
                                          "P2": {"logic": {"status": "unknown"}, "ui": {"status": "unknown"}},
                                          "P3": {"status": "unknown"}, "P4": {"status": "unknown"},
                                          "P5": {"status": "unknown"}, "P6": {"status": "unknown"}},
                               "counts": {"open_gaps": None, "needs_sim": None},
                               "blocks": [], "awaiting": [], "deferred": [], "evidence": [], "cycles": []}]})
            _ensure_branch(s, a.branch)   # 트랙의 브랜치를 release 기본값과 함께 등록
        return _apply(f)
    if c == "set-release":
        def f(s):
            b = _ensure_branch(s, a.branch); b["release"]["status"] = a.status
            if a.pr is not None:
                b["release"]["pr"] = a.pr
        return _apply(f)
    if c == "set-sim":
        def f(s):
            sm = _ensure_branch(s, a.branch).setdefault("sim", {})
            sm["udid"] = a.udid
            if a.device:
                sm["device"] = a.device
        return _apply(f)
    if c == "set-head":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev); r.setdefault("exec", {})["head_commit"] = a.head_commit
        return _apply(f)
    if c == "capture-head":
        if subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout.strip():
            raise SystemExit("워킹트리 dirty — 커밋 후 capture-head, 또는 set-head escape hatch 사용")
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        if not head:
            raise SystemExit("git rev-parse HEAD 실패")
        print(f"capture-head → {head}")
        return _apply(lambda s: _find_rev(_find_track(s, a.track), a.rev).setdefault("exec", {}).__setitem__("head_commit", head))
    if c == "add-unknown":
        return _apply(lambda s: _find_rev(_find_track(s, a.track), a.rev).setdefault("approved", {}).setdefault("unknowns", []).append(
            {"desc": a.desc, "shakes_state": bool(a.shakes_state), "resolution": "pending"}))
    if c == "resolve-unknown":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            for u in _dicts(_d(r.get("approved")).get("unknowns")):
                if u.get("desc") == a.desc:
                    u["resolution"] = a.resolution
                    return
            raise SystemExit(f"unknown '{a.desc}' 없음")
        return _apply(f)
    if c == "add-block":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            r.setdefault("blocks", []).append({"id": a.id, "user_literal": a.user_literal, "status": "open", "actor": a.actor})
        return _apply(f)
    if c == "resolve-block":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            for b in r.get("blocks", []):
                if b.get("id") == a.id:
                    b.update(status="resolved", resolution=a.resolution, actor=a.actor)
                    return
            raise SystemExit(f"block '{a.id}' 없음")
        return _apply(f)
    if c == "add-await":
        return _apply(lambda s: _find_rev(_find_track(s, a.track), a.rev).setdefault("awaiting", []).append(
            {"desc": a.desc, "party": a.party}))
    if c == "resolve-await":
        def f(s):
            r = _find_rev(_find_track(s, a.track), a.rev)
            r["awaiting"] = [w for w in r.get("awaiting", []) if w.get("desc") != a.desc]
        return _apply(f)
    if c == "add-deferred":
        return _apply(lambda s: _find_rev(_find_track(s, a.track), a.rev).setdefault("deferred", []).append(
            {"desc": a.desc, "reason": a.reason, "gate": a.gate, "status": "deferred"}))
    if c == "add-handoff":
        return _apply(lambda s: _find_rev(_find_track(s, a.track), a.rev).setdefault("handoffs", []).append(
            {"from_ctx": a.from_ctx, "to_ctx": a.to_ctx, "at": a.at, "reason": a.reason}))
    if c == "add-cross-cutting":
        return _apply(lambda s: s.setdefault("cross_cutting", []).append(
            {"id": a.id, "title": a.title, "status": "open", "evidence": [], "carry_items": [], "deferred": []}))
    if c == "close-cross-cutting":
        def f(s):
            for xc in s.get("cross_cutting", []):
                if xc.get("id") == a.id:
                    xc["status"] = "closed"; xc["closed_at"] = a.at
                    return
            raise SystemExit(f"cross_cutting '{a.id}' 없음")
        return _apply(f)
    if c == "set-needs-human":
        return _apply(lambda s: _ensure_branch(s, a.branch).__setitem__("needs_human", a.msg))
    if c == "clear-needs-human":
        return _apply(lambda s: _ensure_branch(s, a.branch).__setitem__("needs_human", None))
    return 2


# ── CLI end-to-end (실제 커맨드 경로 — 함수-only selftest 가 놓친 mutation 버그 잡음) ──
def clitest():
    import tempfile
    fails = []
    seed = {"schema_version": 1, "branches": {"b": {"release": {"status": "pending"}, "sim": {"udid": "U"}}},
            "tracks": [{"id": "t/x", "feature": "x", "title": "x", "branch": "b", "parent_track": None,
                        "status": "active", "visual_exempt": False, "current_rev": "v1",
                        "revisions": [{"rev": "v1", "exec": {"branch": "b"}, "approved": {"logic": False, "ui": False},
                                       "phases": {"P1": {"logic": {"status": "unknown"}, "ui": {"status": "unknown"}},
                                                  "P2": {"logic": {"status": "unknown"}, "ui": {"status": "unknown"}},
                                                  "P3": {"status": "unknown"}, "P4": {"status": "unknown"},
                                                  "P5": {"status": "unknown"}, "P6": {"status": "unknown"}},
                                       "counts": {"open_gaps": None, "needs_sim": None},
                                       "blocks": [], "awaiting": [], "deferred": [], "evidence": [], "cycles": []}]}],
            "cross_cutting": []}
    with tempfile.TemporaryDirectory() as d:
        sp, stp = Path(d) / "state.json", Path(d) / "status.md"
        sp.write_text(json.dumps(seed, ensure_ascii=False), encoding="utf-8")
        env = {**os.environ, "DLP_STATE": str(sp), "DLP_STATUS": str(stp)}

        def run(*args):
            r = subprocess.run([sys.executable, str(Path(__file__)), *args], env=env, capture_output=True, text=True)
            return r.returncode, (r.stdout + r.stderr)
        seq = [
            ["set-phase", "t/x", "v1", "P1", "pass", "--side", "logic"],
            ["set-phase", "t/x", "v1", "P1", "pass", "--side", "ui"],
            ["approve", "t/x", "v1", "--logic", "--ui", "--at", "2026-07", "--rois-digest", "d"],
            ["add-evidence", "t/x", "v1", "gate", "--phase", "P2", "--result", "GREEN", "--head-commit", "H"],
            ["set-phase", "t/x", "v1", "P2", "pass", "--side", "logic"],
            ["set-phase", "t/x", "v1", "P2", "pass", "--side", "ui"],
            ["add-evidence", "t/x", "v1", "review", "--phase", "P3", "--verifier-count", "3", "--verdict", "SOUND", "--head-commit", "H"],
            ["set-phase", "t/x", "v1", "P3", "pass", "--clean-streak", "2"],
            ["add-evidence", "t/x", "v1", "review", "--phase", "P4", "--verifier-count", "3", "--verdict", "SOUND", "--head-commit", "H"],
            ["set-phase", "t/x", "v1", "P4", "pass"],
            ["add-evidence", "t/x", "v1", "review", "--phase", "P5", "--verifier-count", "3", "--verdict", "SOUND", "--head-commit", "H"],
            ["set-phase", "t/x", "v1", "P5", "pass", "--clean-streak", "2"],
            ["set-counts", "t/x", "v1", "--open-gaps", "0", "--needs-sim", "0"],
            ["set-phase", "t/x", "v1", "P6", "skip", "--skip-reason", "derived"],
            ["set-head", "t/x", "v1", "H"],
        ]
        ok = True
        for args in seq:
            rc, out = run(*args)
            if rc != 0:
                fails.append(f"CLI 단계 실패: {' '.join(args)} → {out.strip()[:140]}")
                ok = False
                break
        if ok:
            rc, out = run("route")
            if "DONE" not in out:
                fails.append(f"CLI e2e route 가 DONE 아님: {out.strip()[:200]}")
            rc, out = run("mark-track-done", "t/x")
            if rc != 0:
                fails.append(f"CLI mark-track-done 실패: {out.strip()[:140]}")
            rc, out = run("validate")
            if "VALIDATE OK" not in out:
                fails.append(f"CLI 완료 후 validate 실패: {out.strip()[:140]}")
            # 새 head(코드변경) → 수렴 메타 폐기(옛 head 재사용 차단, R3)
            run("set-track-status", "t/x", "active")
            run("add-evidence", "t/x", "v1", "gate", "--phase", "P2", "--result", "GREEN", "--head-commit", "H2")
            rc, out = run("route")
            rev2 = json.loads(sp.read_text(encoding="utf-8"))["tracks"][0]["revisions"][0]
            if "DONE" in out or rev2["counts"]["open_gaps"] is not None or "clean_streak" in rev2["phases"].get("P5", {}):
                fails.append(f"CLI: 새 head 후 수렴 메타 stale 재사용 (route={out.strip()[:60]} counts={rev2['counts']})")
        # 음성: 정족수 미달 review 는 거부돼야
        rc, out = run("add-evidence", "t/x", "v1", "review", "--phase", "P3", "--verdict", "SOUND", "--head-commit", "H")
        if rc == 0:
            fails.append("CLI: 정족수 없는 review 가 통과됨(거부돼야)")
        # DO-NOW: needs-human · add-unknown(비-shaking) CLI 무크래시
        rc, out = run("needs-human")
        if rc != 0:
            fails.append(f"CLI needs-human 실패: {out.strip()[:100]}")
        rc, out = run("add-unknown", "t/x", "v1", "--desc", "미결질문")
        if rc != 0:
            fails.append(f"CLI add-unknown(비-shaking) 실패: {out.strip()[:100]}")
        # dogfood 회귀: add-track 이 브랜치를 release 기본값과 함께 등록 → set-sim GREEN
        rc, out = run("add-track", "demo/x", "--feature", "dx", "--title", "dx", "--branch", "demo/bx")
        if rc != 0:
            fails.append(f"CLI add-track 실패: {out.strip()[:100]}")
        rc, out = run("set-sim", "demo/bx", "UDID-Z")
        if rc != 0:
            fails.append(f"CLI set-sim(신규 브랜치) 실패: {out.strip()[:100]}")
    return fails


# ── selftest (리뷰가 찾은 구멍 전부를 회귀로 잠금) ──────────────────────────────
def _rev(**over):
    rev = {"rev": "v1", "exec": {"branch": "b", "head_commit": "H"},
           "approved": {"logic": True, "ui": True, "rois_digest": "d"},
           "phases": {"P1": {"logic": {"status": "pass"}, "ui": {"status": "pass"}},
                      "P2": {"logic": {"status": "pass"}, "ui": {"status": "pass"}},
                      "P3": {"status": "pass", "clean_streak": 2, "round": 2, "preflight_fail": False},
                      "P4": {"status": "pass"}, "P5": {"status": "pass", "clean_streak": 2, "round": 2},
                      "P6": {"status": "skip", "skip_reason": "derived"}},
           "counts": {"open_gaps": 0, "needs_sim": 0}, "blocks": [], "awaiting": [], "deferred": [],
           "evidence": [{"kind": "gate", "phase": "P2", "result": "GREEN", "head_commit": "H"},
                        {"kind": "approval", "scope": "logic", "actor": "u", "at": "d"},
                        {"kind": "approval", "scope": "ui", "actor": "u", "at": "d"},
                        {"kind": "review", "phase": "P3", "verifier_count": 3, "verdict": "SOUND", "head_commit": "H"},
                        {"kind": "review", "phase": "P4", "verifier_count": 3, "verdict": "SOUND", "head_commit": "H"},
                        {"kind": "review", "phase": "P5", "verifier_count": 3, "verdict": "SOUND", "head_commit": "H"}],
           "cycles": []}
    for k, v in over.items():
        rev[k] = v
    return rev


def _trk(rev, **over):
    t = {"id": "t/x", "feature": "x", "title": "x", "branch": "b", "status": "active",
         "visual_exempt": False, "current_rev": "v1", "revisions": [rev]}
    for k, v in over.items():
        t[k] = v
    return t


def _st(tracks, branches=None):
    return {"schema_version": 1, "branches": branches or {"b": {"release": {"status": "pending"},
            "sim": {"udid": "U1"}}}, "tracks": tracks, "cross_cutting": []}


def selftest():
    fails = []

    def chk(n, c):
        if not c:
            fails.append(n)

    r = _rev(); t = _trk(r)
    chk("complete→DONE", route_rev(r, t)["kind"] == "DONE")
    chk("complete predicate", completion_predicate(r, t) is True)
    chk("valid complete → no errors", validate(_st([t])) == [])
    # I-Q: P4 pass 인데 리뷰증거 없음 → validate FAIL + route back
    r = _rev(); r["evidence"] = [e for e in r["evidence"] if not (e["kind"] == "review" and e["phase"] == "P4")]
    chk("P4 pass no-review → I-Q", any("I-Q" in e for e in validate(_st([_trk(r, status="parked")]))))
    chk("P4 no-review → route P4", route_rev(r, _trk(r))["skill"] == "feature-runtime-qa")
    # head 미상 → 완료 불가(R3)
    r = _rev(); r["exec"] = {"branch": "b"}
    chk("no head → not complete", completion_predicate(r, _trk(r)) is False)
    chk("no head → route 보강", route_rev(r, _trk(r))["skill"] == "feature-implement")
    # stale gate head
    r = _rev(); r["evidence"][0]["head_commit"] = "OLD"
    chk("stale gate head → not complete", completion_predicate(r, _trk(r)) is False)
    # P2 skip 불가
    r = _rev(); r["phases"]["P2"]["logic"]["status"] = "skip"
    chk("P2 skip → validate FAIL", any("I1-enum" in e for e in validate(_st([_trk(r, status="parked")]))))
    # 여분 phase 키 P7
    r = _rev(); r["phases"]["P7"] = {"status": "pass"}
    chk("extra P7 → I-PK", any("I-PK" in e for e in validate(_st([_trk(r, status="parked")]))))
    # mid 모순 P4 pass P2 wip
    r = _rev(); r["phases"]["P2"]["logic"]["status"] = "wip"
    chk("mono P4>P2 → I-M", any("I-M" in e for e in validate(_st([_trk(r, status="parked")]))))
    # P1→P2: P2 pass 인데 P1 unknown/미승인
    r = _rev(); r["phases"]["P1"]["logic"]["status"] = "unknown"; r["approved"]["logic"] = False
    chk("P2 over P1 → I-M/I-A2", any(("I-M" in e or "I-A2" in e) for e in validate(_st([_trk(r, status="parked")]))))
    # counts null → 재감사
    r = _rev(); r["counts"] = {"open_gaps": None, "needs_sim": None}
    chk("counts null → audit", route_rev(r, _trk(r))["skill"] == "feature-scenario-audit")
    # P5 streak<2
    r = _rev(); r["phases"]["P5"]["clean_streak"] = 1
    chk("P5 streak<2 → P5", route_rev(r, _trk(r))["skill"] == "feature-scenario-audit")
    # approve ui without P1.ui
    r = _rev(); r["phases"]["P1"]["ui"]["status"] = "unknown"
    chk("approve without P1.ui → I-A", any("I-A" in e for e in validate(_st([_trk(r, status="parked")]))))
    # two active same branch
    chk("two active → I-B", any("I-B" in e for e in validate(_st([_trk(_rev(), id="t/a"), _trk(_rev(), id="t/b")]))))
    # shared sim udid
    ra, rb = _rev(), _rev(); ra["exec"]["branch"] = "b1"; rb["exec"]["branch"] = "b2"
    chk("shared sim → I-S", any("I-S" in e for e in validate(_st(
        [_trk(ra, id="t/a", branch="b1"), _trk(rb, id="t/b", branch="b2")],
        {"b1": {"release": {"status": "pending"}, "sim": {"udid": "U"}},
         "b2": {"release": {"status": "pending"}, "sim": {"udid": "U"}}}))))
    # P3 skip non-exempt: validate FAIL + completion 도 거짓(track 봄)
    r = _rev(); r["phases"]["P3"] = {"status": "skip"}
    chk("P3 skip non-exempt → I-V", any("I-V" in e for e in validate(_st([_trk(r, status="parked")]))))
    chk("P3 skip non-exempt → not complete", completion_predicate(r, _trk(r)) is False)
    chk("P3 skip exempt → complete", completion_predicate(r, _trk(r, visual_exempt=True)) is True)
    # open block → STOP
    r = _rev(); r["blocks"] = [{"id": "B1", "status": "open", "user_literal": "…"}]
    chk("open block → STOP", route_rev(r, _trk(r))["kind"] == "STOP")
    # P3 round>3 → STOP
    r = _rev(); r["phases"]["P3"] = {"status": "wip", "clean_streak": 0, "round": 4}
    chk("P3 round>3 → STOP", route_rev(r, _trk(r))["kind"] == "STOP")
    # P6 escalation counts 0
    r = _rev(); r["phases"]["P6"] = {"status": "wip", "round": 4}
    chk("P6 round>3 counts0 → STOP", route_rev(r, _trk(r))["kind"] == "STOP")
    # P6 skip nonzero counts → I-P6
    r = _rev(); r["counts"] = {"open_gaps": 5, "needs_sim": 0}
    chk("P6 skip counts>0 → I-P6", any("I-P6" in e for e in validate(_st([_trk(r, status="parked")]))))
    # fake done
    r = _rev(); r["counts"] = {"open_gaps": None, "needs_sim": None}
    chk("fake done → I-C", any("I-C" in e for e in validate(_st([_trk(r, status="done")]))))
    # None branch → route STOP (크래시 아님)
    r = _rev(); r["exec"] = {}
    try:
        res = route(_st([_trk(r, branch=None)], {"b": {"release": {"status": "pending"}}}))
        chk("None branch → no crash", isinstance(res, list))
    except Exception:
        chk("None branch → no crash", False)
    # sim udid None + active P3 route → STOP(lease)
    r = _rev(); r["phases"]["P3"] = {"status": "wip", "round": 1}
    st = _st([_trk(r)], {"b": {"release": {"status": "pending"}, "sim": {}}})
    chk("sim udid None P3 → STOP", route(st)[0]["kind"] == "STOP")
    # ── 라운드2 회귀 ──
    # C2: 최신 review UNSOUND 이 옛 SOUND 를 덮음 → 완료 불가 + I-Q
    r = _rev(); r["evidence"].append({"kind": "review", "phase": "P4", "verifier_count": 1, "verdict": "UNSOUND", "head_commit": "H"})
    chk("latest UNSOUND → not complete", completion_predicate(r, _trk(r)) is False)
    chk("latest UNSOUND → I-Q", any("I-Q" in e for e in validate(_st([_trk(r, status="parked")]))))
    # H3: verifier_count 문자열 → 크래시 없이 I-EV + 완료 불가
    r = _rev()
    for e in r["evidence"]:
        if e.get("phase") == "P4" and e["kind"] == "review":
            e["verifier_count"] = "many"
    chk("string verifier_count → I-EV", any("I-EV" in e for e in validate(_st([_trk(r, status="parked")]))))
    chk("string verifier_count → no crash, not complete", completion_predicate(r, _trk(r)) is False)
    # codex 문자열 → I-EV
    r = _rev(); r["evidence"].append({"kind": "note", "codex": "false"})
    chk("string codex → I-EV", any("I-EV" in e for e in validate(_st([_trk(r, status="parked")]))))
    # visual_exempt 문자열 → 면제 아님
    r = _rev(); r["phases"]["P3"] = {"status": "skip"}
    chk("visual_exempt string → not exempt", completion_predicate(r, _trk(r, visual_exempt="true")) is False)
    chk("visual_exempt string → I1-type", any("I1-type" in e for e in validate(_st([_trk(r, status="parked", visual_exempt="true")]))))
    # M5: P6 pass round4 counts0 완료 → DONE (에스컬레이션 아님)
    r = _rev(); r["phases"]["P6"] = {"status": "pass", "round": 4}
    chk("P6 pass round4 → DONE", route_rev(r, _trk(r))["kind"] == "DONE")
    # P6 wip round4 counts0 → STOP(에스컬레이션 보존)
    r = _rev(); r["phases"]["P6"] = {"status": "wip", "round": 4}
    chk("P6 wip round4 → STOP", route_rev(r, _trk(r))["kind"] == "STOP")
    # M6: phase 키 누락(P4 삭제) → I-PK
    r = _rev(); del r["phases"]["P4"]
    chk("missing P4 key → I-PK", any("I-PK" in e for e in validate(_st([_trk(r, status="parked")]))))
    # M7: 신규 gate head 없음(비 migration) → I-EV / migration 예외 → OK
    r = _rev(); r["evidence"][0].pop("head_commit")
    chk("gate no head → I-EV", any("I-EV" in e for e in validate(_st([_trk(r, status="parked")]))))
    r = _rev(); r["evidence"][0].pop("head_commit"); r["evidence"][0]["source"] = "board-migration"
    chk("gate no head + migration → OK", not any("I-EV" in e for e in validate(_st([_trk(r, status="parked")]))))
    # int branch → I1-branch + route 무크래시
    r = _rev(); r["exec"]["branch"] = 123
    chk("int branch → I1-branch", any("I1-branch" in e for e in validate(_st([_trk(r)], {"b": {"release": {"status": "pending"}}}))))
    try:
        r2 = _rev(); r2["exec"]["branch"] = 123
        route(_st([_trk(r2)], {"b": {"release": {"status": "pending"}}}))
        chk("int branch route → no crash", True)
    except Exception:
        chk("int branch route → no crash", False)
    # P2 양절반 pass 인데 gate 없음 → I-M
    r = _rev(); r["evidence"] = [e for e in r["evidence"] if e["kind"] != "gate"]
    chk("P2 pass no gate → I-M", any("I-M" in e for e in validate(_st([_trk(r, status="parked")]))))
    # ── 라운드3 회귀 (malformed/manual state + 타입 혼동) ──
    r = _rev(); r["counts"] = {"open_gaps": False, "needs_sim": False}
    chk("counts bool → I1-counts", any("I1-counts" in e for e in validate(_st([_trk(r, status="parked")]))))
    chk("counts bool → not complete", completion_predicate(r, _trk(r)) is False)
    r = _rev(); r["approved"]["logic"] = "false"; r["approved"]["ui"] = "false"
    chk("approved string → not yes", approved_state(r) == "no")
    chk("approved string → I1-type", any("I1-type" in e for e in validate(_st([_trk(r, status="parked")]))))
    r = _rev(); r["phases"]["P5"]["clean_streak"] = 2.9
    chk("float streak → I1-type", any("I1-type" in e for e in validate(_st([_trk(r, status="parked")]))))
    chk("float streak → not complete", completion_predicate(r, _trk(r)) is False)
    r = _rev(); r["evidence"].append("oops")
    try:
        errs2 = validate(_st([_trk(r, status="parked")])); completion_predicate(r, _trk(r))
        chk("non-dict evidence → no crash", True)
        chk("non-dict evidence → I1-type", any("I1-type" in e for e in errs2))
    except Exception:
        chk("non-dict evidence → no crash", False)
    st = _st([_trk(_rev(), status="parked")], {"b": {"release": {"status": "pending"}, "sim": {"udid": "U"}, "needs_human": 7}})
    chk("needs_human int → I1-type", any("I1-type" in e for e in validate(st)))
    try:
        route(st); chk("needs_human int route → no crash", True)
    except Exception:
        chk("needs_human int route → no crash", False)

    # 형제 컨테이너 shape 손상(blocks/unknowns/phases/cross_cutting) → 크래시 없이 I1-type
    def _nct(name, mut):
        r = _rev(); mut(r)
        try:
            e3 = validate(_st([_trk(r, status="parked")]))
            chk(f"{name} no-crash", True)
            chk(f"{name} I1-type", any("I1-type" in x for x in e3))
        except Exception:
            chk(f"{name} no-crash", False)
    _nct("blocks non-dict item", lambda r: r.__setitem__("blocks", ["oops"]))
    _nct("blocks non-list", lambda r: r.__setitem__("blocks", "nope"))
    _nct("numeric block id", lambda r: r.__setitem__("blocks", [{"id": 5, "status": "open", "user_literal": "x"}]))
    _nct("unknowns non-dict", lambda r: r["approved"].__setitem__("unknowns", ["x"]))
    _nct("phases non-dict", lambda r: r.__setitem__("phases", "bad"))
    try:
        stx = _st([_trk(_rev(), status="parked")]); stx["cross_cutting"] = ["oops"]
        chk("cross_cutting non-dict no-crash", isinstance(validate(stx), list) and any("I1-type" in x for x in validate(stx)))
    except Exception:
        chk("cross_cutting non-dict no-crash", False)
    # 심층 malformed 퍼즈 — validate/route/render 크래시 0 (비-dict 값·스칼라 컨테이너 방어)
    _fuzz = [lambda r: r.__setitem__("phases", []), lambda r: r["phases"].__setitem__("P3", "x"),
             lambda r: r["phases"]["P1"].__setitem__("logic", "x"), lambda r: r.__setitem__("exec", "x"),
             lambda r: r.__setitem__("exec", [1]), lambda r: r.__setitem__("counts", [0]),
             lambda r: r["counts"].__setitem__("open_gaps", "x"), lambda r: r.__setitem__("approved", []),
             lambda r: r.__setitem__("approved", "yes"), lambda r: r["evidence"].append(None),
             lambda r: r["evidence"].append("x"), lambda r: r.__setitem__("blocks", "x"),
             lambda r: r.__setitem__("awaiting", 7), lambda r: r.__setitem__("cycles", 5),
             lambda r: r["exec"].__setitem__("head_commit", 123)]
    for i, mut in enumerate(_fuzz):
        rr = _rev()
        try:
            mut(rr)
            sfz = _st([_trk(rr, status="parked")]); validate(sfz); route(sfz); render(sfz)
            chk(f"fuzz{i} no-crash", True)
        except Exception:
            chk(f"fuzz{i} no-crash", False)
    for kind, ov in [("branch str", ("branches", {"b": "x"})), ("branch list", ("branches", {"b": [1]})),
                     ("track int", ("tracks", [5])), ("track None", ("tracks", [None])),
                     ("tracks notlist", ("tracks", "x"))]:
        sfz = _st([_trk(_rev(), status="parked")]); sfz[ov[0]] = ov[1]
        try:
            validate(sfz); route(sfz); render(sfz); chk(f"{kind} no-crash", True)
        except Exception:
            chk(f"{kind} no-crash", False)
    rc = _rev(); rc["blocks"] = [1, "x"]                          # 손상 blocks → completion fail-closed
    chk("malformed blocks → fail-closed", completion_predicate(rc, _trk(rc)) is False)
    rh = _rev(); rh["exec"]["head_commit"] = 123                  # 숫자 head → I1-type
    chk("numeric head → I1-type", any("I1-type" in e for e in validate(_st([_trk(rh, status="parked")]))))
    scc = _st([_trk(_rev(), status="parked")]); scc["cross_cutting"] = [{"id": "X", "status": "closed", "carry_items": 7}]
    try:
        chk("cross carry scalar → I1-type", any("I1-type" in e for e in validate(scc)))
        render(scc); chk("cross carry render no-crash", True)
    except Exception:
        chk("cross carry render no-crash", False)

    # ── DO-NOW 배치 회귀 (needs-human·add-unknown·done_modulo_await) ──
    rdone = _rev(); rdone["awaiting"] = [{"desc": "BE 대기", "party": "be"}]
    sda = route(_st([_trk(rdone, id="t/d", status="done")], {"b": {"release": {"status": "pending"}, "sim": {"udid": "U"}}}))
    chk("done+await → release STOP", sda[0]["kind"] == "STOP" and "await" in sda[0]["reason"].lower())
    rdone2 = _rev()   # await 없으면 pr
    sda2 = route(_st([_trk(rdone2, id="t/e", status="done")], {"b": {"release": {"status": "pending"}, "sim": {"udid": "U"}}}))
    chk("done no-await → pr", sda2[0]["kind"] == "ACTION" and sda2[0]["skill"] == "pr")
    ru = _rev(); ru["approved"]["unknowns"] = [{"desc": "x", "shakes_state": True, "resolution": "pending"}]
    chk("unresolved shakes+approved → I-A", any("I-A" in e for e in validate(_st([_trk(ru, status="parked")]))))
    ru2 = _rev(); ru2["approved"]["unknowns"] = [{"desc": "x", "shakes_state": True, "resolution": "answered"}]
    chk("resolved shakes → no shakes-I-A", not any("shakes" in e for e in validate(_st([_trk(ru2, status="parked")]))))
    chk("needs-human no-crash", isinstance(needs_human_report(_st([_trk(_rev(), status="parked")])), str))

    fails += clitest()   # 실제 CLI 경로 P1→DONE + 새 head 수렴 메타 폐기

    if fails:
        print("SELFTEST FAIL:")
        for f in fails:
            print("  -", f)
        return 1
    print("SELFTEST OK (function 40+ cases + CLI e2e P1→DONE)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
