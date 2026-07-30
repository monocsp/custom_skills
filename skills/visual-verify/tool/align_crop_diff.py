# align_crop_diff — Figma PNG ↔ sim PNG 좌표 정렬 후 크롭단위 perceptual diff detector
#
# 역할: "어디를 볼지" 를 결정론적으로 좁힌다(judge 아님). 정렬→잔차 diff→핫스팟 영역 랭킹→
#       상위 영역을 좌Figma·우구현 줌 크롭으로 뽑아 LLM judge(격리 에이전트/codex)에게 1개씩 넘긴다.
#       "다르다" 판정은 이 도구가 안 한다 — Figma export↔Flutter 렌더는 폰트 AA 가 원래 달라
#       순수 픽셀 diff 는 false-positive 가 많다. 그래서 detector(주의 유도)와 judge(판정)를 분리한다.
#
# 정렬 정책(스파이크 결과, docs 참조): 가로=폭비율(둘 다 풀폭), 세로=단일 아핀 y'=a·y+b.
#   실측(notification/login/account 3화면) a=0.97~1.02(세로 stretch 거의 없음), b=8~15pt(상태바 델타).
#   → a 는 [0.97,1.03], b 는 세이프에어리어 델타 범위로 '좁게' 제한해 진짜 드리프트를 흡수하지 않게 한다.
#
# 사용:
#   python3 align_crop_diff.py <figma.png> <sim.png> --out <dir> [--topk 8] [--cell 64]
#            [--bmin-pt 0] [--bmax-pt 26] [--diff-thresh 26] [--min-area-cells 2]
# 산출(<dir>/):
#   align.json          정렬 파라미터(a,b,ncc,신뢰도)
#   overlay_aligned.png 어니언스킨(정렬본) — 사람이 정렬 품질 확인
#   diff_heatmap.png    잔차 diff 히트맵(sim 위) — 어디가 다른지 한눈에
#   regions.json        핫스팟 영역 랭킹 [{rank,bbox_px,bbox_ratio,score,crop}]
#   crop_<n>.png        상위 영역 좌Figma·우구현 줌 크롭(=judge 입력)
#
# 의존: numpy, Pillow (skimage 불필요 — NCC·CC 직접 구현).
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw


def arg(flag, default=None):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


def gray(im):
    return np.asarray(im.convert("L"), dtype=np.float32)


def row_edge_profile(g, H):
    # 행별 가로-그라디언트 에너지: 텍스트·아이콘·카드 경계에서 피크. 내용이 달라도 '구조 위치'는 공유.
    p = np.abs(np.diff(g, axis=1)).sum(axis=1)
    p = p / (p.max() + 1e-6)
    top, bot = int(H * 0.06), int(H * 0.965)  # 상태바/홈인디케이터 제외
    p[:top] = 0
    p[bot:] = 0
    return p


def ncc(a, b):
    a = a - a.mean()
    b = b - b.mean()
    return float((a * b).sum() / ((np.linalg.norm(a) * np.linalg.norm(b)) + 1e-9))


def resample(p, n):
    return np.interp(np.linspace(0, 1, n), np.linspace(0, 1, len(p)), p)


def align(fig_g, sim_g, SW, SH, bmin, bmax):
    """figma(폭정규화 후) → sim 프레임. 세로 아핀 y'=a·y+b, a·b 좁게 제한. (a,b,ncc) 반환."""
    fH = fig_g.shape[0]
    pf = row_edge_profile(fig_g, fH)
    ps = row_edge_profile(sim_g, SH)
    best = (-1.0, 1.0, 0)
    for a in np.linspace(0.97, 1.03, 25):
        L = int(fH * a)
        pr = resample(pf, L)
        for b in range(bmin, bmax + 1, 2):
            s, e = max(0, b), min(SH, b + L)
            fs = max(0, -b)
            fe = fs + (e - s)
            if e - s < SH * 0.5:
                continue
            v = ncc(pr[fs:fe], ps[s:e])
            if v > best[0]:
                best = (v, float(a), int(b))
    return best[1], best[2], best[0]  # a, b, ncc


def aligned_figma_canvas(fig_im, SW, SH, FW, FH, a, b):
    resized = fig_im.convert("RGB").resize((SW, int(FH * SW / FW * a)))
    canvas = Image.new("RGB", (SW, SH), (247, 247, 247))
    canvas.paste(resized, (0, b))
    return canvas


def label_grid(hot):
    """불리언 grid(hot) → 4연결 연결요소 라벨. BFS, 의존성 없음."""
    R, C = hot.shape
    lab = np.zeros((R, C), dtype=int)
    n = 0
    for i in range(R):
        for j in range(C):
            if hot[i, j] and lab[i, j] == 0:
                n += 1
                stack = [(i, j)]
                lab[i, j] = n
                while stack:
                    y, x = stack.pop()
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < R and 0 <= nx < C and hot[ny, nx] and lab[ny, nx] == 0:
                            lab[ny, nx] = n
                            stack.append((ny, nx))
    return lab, n


def main():
    fig_path, sim_path = sys.argv[1], sys.argv[2]
    out = arg("--out", "vv_out")
    topk = int(arg("--topk", "8"))
    cell = int(arg("--cell", "64"))  # detector grid 셀(px)
    diff_thresh = float(arg("--diff-thresh", "26"))  # AA 무시 임계(0~255 L)
    min_area = int(arg("--min-area-cells", "2"))
    os.makedirs(out, exist_ok=True)

    fig_im = Image.open(fig_path)
    sim_im = Image.open(sim_path)
    FW, FH = fig_im.size
    SW, SH = sim_im.size

    # 세로 오프셋 탐색 범위 = 세이프에어리어 델타(pt) → sim px(3x 가정: native/logical)
    dpr = SW / float(arg("--sim-width", "402.0"))  # 부팅 sim 논리폭 기준 배율(기본 402=16 Pro; --sim-width 로 SE 375 등 오버라이드)
    bmin = int(float(arg("--bmin-pt", "0")) * dpr)
    bmax = int(float(arg("--bmax-pt", "26")) * dpr)

    fig_wnorm_g = gray(fig_im.resize((SW, int(FH * SW / FW))))
    a, b, nccv = align(fig_wnorm_g, gray(sim_im), SW, SH, bmin, bmax)
    conf = "high" if nccv >= 0.9 else ("mid" if nccv >= 0.85 else "low")
    # 이 도구는 widget-ROI 대조(widget_roi_compare.py)의 backstop 이다 — 위젯목록(map.json)에 없는
    # 의심영역을 추가로 뽑는 역할. 그래서 NCC/경계 hit 는 gate 가 아니라 '정렬 신뢰 메타데이터'로만 낸다.
    # (구 버전은 정렬 실패를 '화면통째 judge' 로 에스컬레이션했으나, 그건 가장 약한 눈대중으로의 회귀라 폐기.
    #  정렬이 낮으면 판정을 포기하는 게 아니라 앵커기반 부분크롭으로 degrade — 절차는 SKILL.md ③ 참조.)
    hit_boundary = a <= 0.971 or a >= 1.029 or b <= bmin or b >= bmax - 1
    align_note = ("정렬 신뢰 낮음 — 스크롤/시트/키보드/큰드리프트 의심. hotspot 랭킹 신뢰 말고 "
                  "앵커기반 부분크롭으로 degrade") if (nccv < 0.85 or hit_boundary) else "정렬 양호"
    json.dump(
        {"a": round(a, 4), "b_px": b, "b_pt": round(b / dpr, 1), "ncc": round(nccv, 4),
         "align_confidence": conf, "hit_boundary": hit_boundary, "align_note": align_note,
         "role": "backstop(widget_roi_compare 보조) — NCC 는 메타데이터, gate 아님",
         "dpr": round(dpr, 3), "b_search_pt": [bmin / dpr, bmax / dpr]},
        open(f"{out}/align.json", "w"), ensure_ascii=False, indent=2)

    figA = aligned_figma_canvas(fig_im, SW, SH, FW, FH, a, b)

    # 어니언스킨(정렬 품질 확인용)
    onion = (np.asarray(sim_im.convert("RGB"), np.float32) * 0.5 + np.asarray(figA, np.float32) * 0.5)
    Image.fromarray(onion.astype("uint8")).save(f"{out}/overlay_aligned.png")

    # 잔차 diff = L채널(텍스트·아이콘 등 저↔고대비) + 엣지구조(저대비 카드·보더·그림자 이동).
    # 설정 카드는 흰색(#FFF)이 연회색(#F7F7F7) 위라 L잔차가 ~8뿐 → 카드 이동은 L 로 안 보인다.
    # 엣지맵(그라디언트)은 카드 라운드보더·그림자가 이동하면 구/신 위치 양쪽에서 잔차를 낸다.
    fL = gray(figA)
    sL = gray(sim_im)

    def edge_mag(g):
        e = np.zeros_like(g)
        e[:, 1:] += np.abs(np.diff(g, axis=1))
        e[1:, :] += np.abs(np.diff(g, axis=0))
        return e

    top, bot = int(SH * 0.06), int(SH * 0.965)
    resid_L = np.abs(fL - sL)
    resid_L[:top] = 0
    resid_L[bot:] = 0
    resid_L[resid_L < diff_thresh] = 0  # AA·미세 렌더차 억제
    eF, eS = edge_mag(fL), edge_mag(sL)

    # 히트맵(sim 위 빨강) — L잔차 기준(사람 확인용)
    heat = np.asarray(sim_im.convert("RGB"), np.float32).copy()
    r = np.clip(resid_L / resid_L.max() if resid_L.max() > 0 else resid_L, 0, 1)
    heat[..., 0] = np.clip(heat[..., 0] + r * 200, 0, 255)
    heat[..., 1] *= (1 - r * 0.6)
    heat[..., 2] *= (1 - r * 0.6)
    Image.fromarray(heat.astype("uint8")).save(f"{out}/diff_heatmap.png")

    # detector: 셀 grid 로 (a)L잔차 평균 + (b)엣지구조 셀차 결합 → 핫셀 → 연결요소 → 영역 bbox.
    # 엣지는 셀단위로 pool 후 차이를 봐서 서브픽셀 AA 는 상쇄되고 구조 이동만 남는다.
    R, C = SH // cell, SW // cell

    def pool(x):
        return x[:R * cell, :C * cell].reshape(R, cell, C, cell).mean(axis=(1, 3))

    cell_L = pool(resid_L)
    cell_E = np.abs(pool(eF) - pool(eS))
    cell_E[:int(R * 0.06)] = 0
    cell_E[int(R * 0.965):] = 0
    cellsum = cell_L + 1.5 * cell_E
    hot = cellsum > (diff_thresh * 0.35)
    lab, n = label_grid(hot)

    regions = []
    for k in range(1, n + 1):
        ys, xs = np.where(lab == k)
        if len(ys) < min_area:
            continue
        y0, y1 = ys.min() * cell, (ys.max() + 1) * cell
        x0, x1 = xs.min() * cell, (xs.max() + 1) * cell
        score = float(cellsum[ys, xs].sum())
        regions.append({"bbox": [int(x0), int(y0), int(x1), int(y1)], "score": round(score, 1)})
    regions.sort(key=lambda z: -z["score"])
    regions = regions[:topk]

    # 상위 영역 좌Figma·우구현 줌 크롭(judge 입력)
    PAD, ZOOM_H = int(cell * 0.4), 360
    for i, reg in enumerate(regions, 1):
        x0, y0, x1, y1 = reg["bbox"]
        x0, y0 = max(0, x0 - PAD), max(0, y0 - PAD)
        x1, y1 = min(SW, x1 + PAD), min(SH, y1 + PAD)
        cf = figA.crop((x0, y0, x1, y1))
        cs = sim_im.convert("RGB").crop((x0, y0, x1, y1))
        h = max(1, y1 - y0)
        zf = cf.resize((int(cf.width * ZOOM_H / h), ZOOM_H))
        zs = cs.resize((int(cs.width * ZOOM_H / h), ZOOM_H))
        pair = Image.new("RGB", (zf.width + zs.width + 30, ZOOM_H + 30), "white")
        pair.paste(zf, (10, 20))
        pair.paste(zs, (zf.width + 20, 20))
        d = ImageDraw.Draw(pair)
        d.text((10, 4), "FIGMA", fill="black")
        d.text((zf.width + 20, 4), "IMPL(sim)", fill="black")
        name = f"crop_{i}.png"
        pair.save(f"{out}/{name}")
        reg["rank"] = i
        reg["crop"] = name
        reg["bbox_ratio"] = [round(x0 / SW, 3), round(y0 / SH, 3), round(x1 / SW, 3), round(y1 / SH, 3)]

    json.dump(regions, open(f"{out}/regions.json", "w"), ensure_ascii=False, indent=2)

    print(f"# align(backstop): a={a:.3f} b={b}px({b/dpr:.1f}pt) ncc={nccv:.3f} [{conf}] — {align_note}")
    print(f"# hotspot 영역 {len(regions)}개 (topk={topk}) → {out}/regions.json, crop_*.png")
    print(f"# 확인용: {out}/overlay_aligned.png (정렬품질), {out}/diff_heatmap.png (잔차)")
    for reg in regions:
        print(f"  #{reg['rank']} score={reg['score']} bbox={reg['bbox']} → {reg['crop']}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("사용: python3 align_crop_diff.py <figma.png> <sim.png> --out <dir> [--topk 8] [--cell 64]")
        sys.exit(1)
    main()
