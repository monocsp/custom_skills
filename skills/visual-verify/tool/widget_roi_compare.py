# widget_roi_compare — 위젯-ROI 단위 Figma↔구현 대조 입력 생성기 (visual-verify ③의 1차 경로)
#
# 철학(codex GO 확정): 검증 단위 = 픽셀 diff 핫스팟이 아니라 '명시된 중요 위젯(ROI)'.
#   에이전트가 "이 박스가 무슨 위젯인지" 알면 훨씬 확실히 비교한다(Set-of-Mark + 명시 ROI).
#   각 ROI 를 Figma tree.json 노드 ↔ 구현 ui_describe_all 위젯으로 이어, ① 라벨없는 좌Figma·우구현
#   줌 크롭 페어(=judge 판정 단위) ② 전체 캡처에 번호박스만 얹은 문맥 오버뷰 ③ 대략 위치·크기 델타를 만든다.
#
# 경계(codex 반영):
#   - ui_describe_all frame 은 a11y bounds(paint 아님) → 크롭 앵커·rough_metric·이상치 플래그로만.
#     위치·크기 단독 PASS/FAIL 근거로 쓰지 마라. 최종 판정은 크롭 시각 + tree 수치 보조 + 다수결.
#   - 검증 대상은 map.json 의 ROI 만(전체 a11y 노드 X — Stack/리스트셀 폭증 방지). 상태당 10~25개.
#   - a11y 가 놓치는 장식/그림자는 여기 안 뜸 → align_crop_diff(backstop)의 unmapped hotspot 으로 보완.
#   - 라벨은 '오버뷰'에만. 크롭 페어엔 라벨 안 넣음(조밀화면 SoM 저하 회피).
#
# 입력:
#   --figma-png <png>       Figma frame 렌더(375 프레임 @Nx)
#   --figma-tree <tree.json> extract_doc 산출(노드 bbox·색·폰트). (--map 에 figma bbox 직접 주면 생략 가능)
#   --sim-png <png>         iPhone 16 Pro 캡처(402 논리 @3x)
#   --sim-describe <json>   ios-simulator ui_describe_all 저장본(위젯 label/id/frame=논리좌표)
#   --map <rois.json>       impl/settings/<feature>.rois.json (P1 산출 기계 계약) — entry =
#                           {screen, state, roi_id, label, qa_key?, importance, figma_bbox[x,y,w,h 375pt]|figma_node}.
#                           {"_doc": ...} 헤더 entry 는 자동 무시. §3 md 표는 이 파일의 뷰(표 파싱 입력 금지).
#   --out <dir>
# 산출(<dir>/):
#   overview.png            sim 캡처 + ROI 번호박스(문맥용)
#   roi_<id>.png            ROI별 좌Figma·우구현 줌 크롭(=judge 입력, 라벨 없음)
#   roi_compare.json        [{roi_id, qa_key, figma_node, importance, present, rough_metric, crop, notes}]
#
# 의존: Pillow. (numpy 불필요)
import json
import os
import sys

from PIL import Image, ImageDraw

FIGMA_FRAME_PT = 375.0   # Figma baseline 프레임 폭
SIM_LOGICAL_PT = 402.0   # 기본값(iPhone 16 Pro) — main 에서 --sim-width 로 부팅 sim 실제 논리폭 오버라이드


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


# ---------- Figma tree.json ----------
def index_tree(tree):
    """tree.json → {id: node, name: node}. bbox 는 frame-relative(pt) 로 환산해 붙인다."""
    root = tree.get("bbox") or {"x": 0, "y": 0}
    rx, ry = root.get("x", 0), root.get("y", 0)
    by_id, by_name = {}, {}

    def walk(n):
        bb = n.get("bbox")
        if bb:
            n["_rel"] = {"x": bb.get("x", 0) - rx, "y": bb.get("y", 0) - ry,
                         "w": bb.get("w", 0), "h": bb.get("h", 0)}
        if n.get("id"):
            by_id[str(n["id"])] = n
        if n.get("name"):
            by_name.setdefault(n["name"], n)
        for c in n.get("children", []):
            walk(c)

    walk(tree)
    return by_id, by_name


def figma_bbox_pt(map_entry, by_id, by_name):
    """map 의 figma_node(id 또는 name) 또는 figma_bbox 직접값 → frame-relative pt bbox."""
    if map_entry.get("figma_bbox"):  # [x,y,w,h] pt 직접
        x, y, w, h = map_entry["figma_bbox"]
        return {"x": x, "y": y, "w": w, "h": h}
    key = str(map_entry.get("figma_node", ""))
    node = by_id.get(key) or by_name.get(key)
    if node and node.get("_rel"):
        return node["_rel"]
    return None


# ---------- ui_describe_all ----------
def flatten_describe(node, acc):
    """ui_describe_all 은 sim 마다 스키마가 조금씩 다르다 — 흔한 키 철자를 관대하게 흡수한다.
    각 원소에서 (id, label, frame{x,y,w,h} 논리좌표)를 뽑는다."""
    if isinstance(node, list):
        for c in node:
            flatten_describe(c, acc)
        return
    if not isinstance(node, dict):
        return
    ident = (node.get("identifier") or node.get("AXUniqueId") or node.get("AXIdentifier")
             or node.get("id") or node.get("key") or node.get("name"))
    label = (node.get("label") or node.get("AXLabel") or node.get("title")
             or node.get("text") or node.get("value"))
    fr = (node.get("frame") or node.get("AXFrame") or node.get("rect") or node.get("bounds"))
    fx = fw = None
    if isinstance(fr, dict):
        fx = fr.get("x", fr.get("X"))
        fy = fr.get("y", fr.get("Y"))
        fw = fr.get("width", fr.get("w", fr.get("Width")))
        fh = fr.get("height", fr.get("h", fr.get("Height")))
    elif isinstance(fr, (list, tuple)) and len(fr) == 4:
        fx, fy, fw, fh = fr
    if fw is not None:
        acc.append({"id": str(ident) if ident else None,
                    "label": str(label).strip() if label else None,
                    "frame": {"x": fx, "y": fy, "w": fw, "h": fh}})
    for k in ("children", "elements", "subviews", "nodes", "AXChildren"):
        if node.get(k):
            flatten_describe(node[k], acc)


def find_widget(map_entry, widgets):
    """map 의 qa_key(정확일치 우선) 또는 label 로 구현 위젯 찾기. (widget, match_method, error) 반환.

    codex 지적 반영: substring 매칭은 리스트/overlay 중복 오탐 위험 → identifier 는 **정확일치**만,
    중복이면 fail(preflight 에서 걸러 P3 진입 차단 근거). label 은 exact → substring 순 폴백."""
    qa = map_entry.get("qa_key")
    if qa:
        hits = [w for w in widgets if w["id"] == qa]
        if len(hits) == 1:
            return hits[0], "qa_key_exact", None
        if len(hits) > 1:
            return None, None, f"duplicate qa_key '{qa}' x{len(hits)}"
        # 정확일치 0건 → qa_key 가 노출 안 된 것(preflight 경고), label 폴백 시도
    lab = map_entry.get("label")
    if lab:
        exact = [w for w in widgets if w["label"] == lab]
        if len(exact) == 1:
            return exact[0], "label_exact", ("qa_key_not_exposed" if qa else None)
        if len(exact) > 1:
            return None, None, f"duplicate label '{lab}' x{len(exact)}"
        sub = [w for w in widgets if w["label"] and lab in w["label"]]
        if len(sub) == 1:
            return sub[0], "label_substring", ("qa_key_not_exposed" if qa else None)
        if len(sub) > 1:
            return None, None, f"ambiguous label '{lab}' x{len(sub)}"
    return None, None, ("qa_key_not_exposed" if qa else "no_match")


# ---------- 대략 델타(비율) — 2-tier ----------
# tier1 outlier(약한 플래그): a11y≠paint 근사 오차 가능 — 시각 확인 필요.
# tier2 MACHINE VOTE(강한 판정): |dw|/|dcx| ≥ 0.06 은 근사 오차로 설명 안 되는 크기 —
#   크롭 시각 판정과 무관하게 confirmed 후보로 자동 승격(다수결에 기계표 1로 합류).
#   근거(2026-07-02 통제 실험): 버튼 폭 ~11% 결함(dw=0.1)을 격리 시각 3인 중 2인이 놓침 —
#   타이트 크롭이 대칭 여백을 정규화로 지워서. 기계 metric 이 이 결함 클래스의 1차 안전망.
MACHINE_VOTE_THRESH = 0.06


def rough_metric(fig_pt, sim_frame):
    """비율(프레임폭 대비) 위치·크기 델타. outlier=약한 플래그, machine_vote=confirmed 후보."""
    if not fig_pt or not sim_frame:
        return None
    fcx = (fig_pt["x"] + fig_pt["w"] / 2) / FIGMA_FRAME_PT
    fcy = (fig_pt["y"] + fig_pt["h"] / 2) / FIGMA_FRAME_PT  # 주: 세로도 폭기준 비율(대략치)
    scx = (sim_frame["x"] + sim_frame["w"] / 2) / SIM_LOGICAL_PT
    scy = (sim_frame["y"] + sim_frame["h"] / 2) / SIM_LOGICAL_PT
    fw, fh = fig_pt["w"] / FIGMA_FRAME_PT, fig_pt["h"] / FIGMA_FRAME_PT
    sw, sh = sim_frame["w"] / SIM_LOGICAL_PT, sim_frame["h"] / SIM_LOGICAL_PT
    d = {"dcx": round(abs(fcx - scx), 3), "dcy": round(abs(fcy - scy), 3),
         "dw": round(abs(fw - sw), 3), "dh": round(abs(fh - sh), 3)}
    d["outlier"] = d["dcx"] > 0.03 or d["dw"] > 0.04 or d["dh"] > 0.04
    if d["dw"] >= MACHINE_VOTE_THRESH or d["dcx"] >= MACHINE_VOTE_THRESH:
        d["machine_vote"] = f"width/position drift (dw={d['dw']}, dcx={d['dcx']}) ≥ {MACHINE_VOTE_THRESH}"
    return d


def alignment_check(results):
    """cross-ROI 정렬 일관성: figma 에서 좌x 가 서로 일치하는 ROI 들(정렬 그룹)을 찾고,
    impl 에서 혼자 어긋난 위젯을 플래그. (통제 실험에서 격리 B 가 수동으로 잡은 신호의 도구화 —
    '버튼만 홀로 inset' 류. figma 가 정렬을 약속할 때만 impl 어긋남을 결함 후보로 본다.)"""
    rows = [r for r in results if r.get("_fig_lx") is not None and r.get("_sim_lx") is not None]
    if len(rows) < 3:
        return
    from collections import Counter
    # figma 좌x비율을 0.01 단위로 양자화해 최빈 정렬선 찾기
    quant = Counter(round(r["_fig_lx"], 2) for r in rows)
    align_lx, n = quant.most_common(1)[0]
    if n < 3:
        return  # 정렬 그룹이라 부를 근거 부족
    group = [r for r in rows if abs(r["_fig_lx"] - align_lx) <= 0.012]
    sim_lxs = sorted(r["_sim_lx"] for r in group)
    median = sim_lxs[len(sim_lxs) // 2]
    for r in group:
        if abs(r["_sim_lx"] - median) > 0.02:
            r["alignment_outlier"] = (
                f"figma 좌x({align_lx:.2f}) 정렬 그룹 {len(group)}개 중 혼자 어긋남 "
                f"(impl 좌x {r['_sim_lx']:.3f} vs 그룹 중앙값 {median:.3f})")


def band_crop(fig_im, sim_im, fig_pt, sim_frame, fscale, sscale, out_path, pad_pt=10):
    """풀-밴드 크롭: ROI 의 y대역을 **화면 좌우 끝까지** 잘라 위(FIGMA)/아래(IMPL)로 쌓는다.
    타이트 크롭이 지우는 '가장자리 대비 위치·대칭 여백'이 보이게 — 폭/마진 결함 클래스 전용.
    빨간 틱 = figma 가 약속한 위젯 좌우 경계(양쪽 밴드에 같은 비율 위치로 그림)."""
    def band(im, pt, scale, W_px):
        y0 = max(0, int((pt["y"] - pad_pt) * scale))
        y1 = min(im.height, int((pt["y"] + pt["h"] + pad_pt) * scale))
        return im.crop((0, y0, W_px, y1))

    bf = band(fig_im, fig_pt, fscale, fig_im.width)
    bs = band(sim_im, sim_frame, sscale, sim_im.width)
    W = 1100  # 공통 폭으로 리사이즈(비율 보존)
    bf = bf.resize((W, max(1, int(bf.height * W / bf.width))))
    bs = bs.resize((W, max(1, int(bs.height * W / bs.width))))
    canvas = Image.new("RGB", (W + 20, bf.height + bs.height + 56), "white")
    d = ImageDraw.Draw(canvas)
    d.text((10, 2), "FIGMA band (full-width)", fill="black")
    canvas.paste(bf, (10, 18))
    d.text((10, 18 + bf.height + 2), "IMPL band (full-width)", fill="black")
    canvas.paste(bs, (10, 36 + bf.height))
    # figma 기대 좌우 경계 틱(비율 → 공통폭 px) — 양쪽 밴드에 동일 위치
    for ratio in (fig_pt["x"] / FIGMA_FRAME_PT, (fig_pt["x"] + fig_pt["w"]) / FIGMA_FRAME_PT):
        x = 10 + int(ratio * W)
        for (ya, yb) in ((18, 18 + bf.height), (36 + bf.height, 36 + bf.height + bs.height)):
            d.line([(x, ya), (x, yb)], fill="red", width=2)
    canvas.save(out_path)


def crop_pair(fig_im, sim_im, fig_pt, sim_frame, fscale, sscale, out_path, pad_pt=12, zoom_h=360):
    def box(pt, scale):
        x0 = max(0, (pt["x"] - pad_pt) * scale)
        y0 = max(0, (pt["y"] - pad_pt) * scale)
        x1 = (pt["x"] + pt["w"] + pad_pt) * scale
        y1 = (pt["y"] + pt["h"] + pad_pt) * scale
        return (int(x0), int(y0), int(x1), int(y1))

    parts = []
    if fig_pt:
        c = fig_im.crop(box(fig_pt, fscale))
        h = max(1, c.height)
        parts.append(("FIGMA", c.resize((max(1, int(c.width * zoom_h / h)), zoom_h))))
    if sim_frame:
        c = sim_im.crop(box(sim_frame, sscale))
        h = max(1, c.height)
        parts.append(("IMPL", c.resize((max(1, int(c.width * zoom_h / h)), zoom_h))))
    if not parts:
        return False
    W = sum(p[1].width for p in parts) + 20 * (len(parts) + 1)
    canvas = Image.new("RGB", (W, zoom_h + 30), "white")
    d = ImageDraw.Draw(canvas)
    x = 20
    for name, im in parts:
        canvas.paste(im, (x, 20))
        d.text((x, 4), name, fill="black")  # 패널 헤더만(위젯 라벨은 크롭에 안 넣음)
        x += im.width + 20
    canvas.save(out_path)
    return True


def main():
    global SIM_LOGICAL_PT
    SIM_LOGICAL_PT = float(arg("--sim-width", str(SIM_LOGICAL_PT)))  # 부팅 sim 논리폭(SE 375·16 Pro 402 등); 기본 16 Pro
    figma_png, sim_png = arg("--figma-png"), arg("--sim-png")
    out = arg("--out", "vv_roi")
    os.makedirs(out, exist_ok=True)
    mp = json.load(open(arg("--map")))
    # 기능당 1개 rois.json(P1 산출물, 커밋 계약) 지원: entries 의 screen/state 필드로 필터.
    # 필드 없는 entry 는 전 화면 공통으로 간주(하위호환 — 상태별 단일 파일도 그대로 동작).
    mp = [m for m in mp if m.get("roi_id")]  # {"_doc": ...} 헤더/주석 entry 제거(없으면 KeyError crash)
    want_screen, want_state = arg("--screen"), arg("--state")
    if want_screen:
        mp = [m for m in mp if m.get("screen") in (None, want_screen)]
    if want_state:
        mp = [m for m in mp if m.get("state") in (None, want_state)]

    fig_im = Image.open(figma_png).convert("RGB")
    sim_im = Image.open(sim_png).convert("RGB")
    fscale = fig_im.width / FIGMA_FRAME_PT   # figma pt → figma png px
    sscale = sim_im.width / SIM_LOGICAL_PT   # sim  pt → sim  png px

    by_id, by_name = ({}, {})
    if arg("--figma-tree"):
        by_id, by_name = index_tree(json.load(open(arg("--figma-tree"))))
    widgets = []
    if arg("--sim-describe"):
        flatten_describe(json.load(open(arg("--sim-describe"))), widgets)

    overview = sim_im.copy()
    od = ImageDraw.Draw(overview)
    results = []
    preflight_fails = []
    for i, m in enumerate(mp, 1):
        fig_pt = figma_bbox_pt(m, by_id, by_name)
        w, match_method, match_err = find_widget(m, widgets)
        sim_frame = w["frame"] if w else None
        present = "both" if (fig_pt and sim_frame) else (
            "figma_only(구현 누락?)" if fig_pt else "impl_only(시안 누락?)" if sim_frame else "none(매핑 오류)")
        if match_err and m.get("importance") == "blocker":
            preflight_fails.append(f"{m['roi_id']}: {match_err}")
        crop = f"roi_{m['roi_id']}.png"
        ok = crop_pair(fig_im, sim_im, fig_pt, sim_frame, fscale, sscale, f"{out}/{crop}")
        # 오버뷰에 번호박스(sim 좌표)
        if sim_frame:
            x0, y0 = sim_frame["x"] * sscale, sim_frame["y"] * sscale
            x1 = (sim_frame["x"] + sim_frame["w"]) * sscale
            y1 = (sim_frame["y"] + sim_frame["h"]) * sscale
            od.rectangle([x0, y0, x1, y1], outline="red", width=3)
            od.text((x0 + 2, max(0, y0 - 16)), f"#{i}", fill="red")
        rm = rough_metric(fig_pt, sim_frame)
        row = {
            "n": i, "roi_id": m["roi_id"], "qa_key": m.get("qa_key"),
            "figma_node": m.get("figma_node"), "importance": m.get("importance", "normal"),
            "present": present, "match_method": match_method, "match_error": match_err,
            "rough_metric": rm,
            "crop": crop if ok else None, "label": m.get("label"),
            # 정렬 체크용 좌x비율(내부 필드 — json 저장 전 제거)
            "_fig_lx": (fig_pt["x"] / FIGMA_FRAME_PT) if fig_pt else None,
            "_sim_lx": (sim_frame["x"] / SIM_LOGICAL_PT) if sim_frame else None,
        }
        # 풀-밴드 크롭: edge_sensitive 명시 또는 기계 metric 이 폭/위치 드리프트를 감지한 ROI
        if fig_pt and sim_frame and (m.get("edge_sensitive") or (rm and rm.get("machine_vote"))):
            band_name = f"roi_{m['roi_id']}_band.png"
            band_crop(fig_im, sim_im.convert("RGB"), fig_pt, sim_frame, fscale, sscale,
                      f"{out}/{band_name}")
            row["band_crop"] = band_name
        results.append(row)
    alignment_check(results)
    for r in results:
        r.pop("_fig_lx", None)
        r.pop("_sim_lx", None)
    machine_votes = [f"{r['roi_id']}: {r['rough_metric']['machine_vote']}"
                     for r in results if r.get("rough_metric") and r["rough_metric"].get("machine_vote")]
    align_flags = [f"{r['roi_id']}: {r['alignment_outlier']}" for r in results if r.get("alignment_outlier")]
    overview.save(f"{out}/overview.png")
    json.dump({"preflight_fails": preflight_fails, "machine_votes": machine_votes,
               "alignment_outliers": align_flags, "rois": results},
              open(f"{out}/roi_compare.json", "w"), ensure_ascii=False, indent=2)

    print(f"# widget-ROI 대조: {len(results)}개 ROI → {out}/roi_compare.json, overview.png, roi_*.png")
    for r in results:
        rm = r["rough_metric"]
        flag = " ⚠outlier" if (rm and rm.get("outlier")) else ""
        mv = " 🔴MACHINE-VOTE" if (rm and rm.get("machine_vote")) else ""
        al = " 🔴ALIGN-OUTLIER" if r.get("alignment_outlier") else ""
        err = f" ✗{r['match_error']}" if r["match_error"] else ""
        band = f" +{r['band_crop']}" if r.get("band_crop") else ""
        print(f"  #{r['n']} {r['roi_id']}({r['importance']}) present={r['present']} "
              f"match={r['match_method']}{flag}{mv}{al}{err} → {r['crop']}{band}")
    if machine_votes:
        # 기계표 = confirmed 후보(다수결에 1표로 합류) — 크롭 시각 판정이 놓쳐도 여기서 잡힌다.
        print(f"# 🔴 MACHINE VOTES ({len(machine_votes)}): " + " | ".join(machine_votes))
    if align_flags:
        print(f"# 🔴 ALIGNMENT OUTLIERS ({len(align_flags)}): " + " | ".join(align_flags))
    if preflight_fails:
        # blocker ROI 의 키 누락/중복 = P3 진입 차단 신호(키 드리프트·미노출 fail-fast).
        # non-zero exit — stdout/JSON 을 안 읽는 호출자(셸 &&·CI)도 여기서 멈추게 강제.
        print(f"# ⛔ PREFLIGHT FAIL ({len(preflight_fails)}): " + " | ".join(preflight_fails))
        sys.exit(2)


if __name__ == "__main__":
    if not (arg("--figma-png") and arg("--sim-png") and arg("--map")):
        print("사용: python3 widget_roi_compare.py --figma-png F --sim-png S --map <feature>.rois.json "
              "[--screen <screen>] [--state <state>] [--figma-tree tree.json] "
              "[--sim-describe describe.json] --out DIR")
        sys.exit(1)
    main()
