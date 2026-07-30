# tree.json 평탄화 — 모든 노드를 frame-relative 실측 표로 (위젯 단위 대조용 SSOT)
#
# extract_doc.dart 가 뽑은 *.tree.json 을 읽어 노드별 실측을 한 줄씩 찍는다.
# texts.json 은 TEXT 노드만 담지만 이 도구는 컨테이너/벡터 포함 전 노드를 다룬다.
# 좌표는 frame-relative(= node.bbox - root.bbox) — root 는 tree 의 최상위 노드.
#
# 사용:
#   python3 tree_flatten.py <tree.json> [--device-width 402] [--min-w 4]
#   --device-width  주면 device-point 환산값도 같이((×W/375), screenutil 비교용). 생략 시 375 baseline 그대로.
#   --min-w         이 폭 미만(px) 노드 숨김(노이즈 컷, 기본 0).
#
# 출력 컬럼: depth name | type | x y w h | fill | stroke | radius | font | color | gap | text
# 모든 값은 tree.json 실측 그대로 — 눈대중 금지. 구현 측 실측은 ios-simulator ui_describe_all(points).
import json
import sys


def arg(flag, default=None):
    if flag in sys.argv:
        i = sys.argv.index(flag)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def num(v):
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return round(v, 2) if isinstance(v, float) else v
    return v


def fmt(v):
    return "-" if v is None else str(v)


def main():
    path = sys.argv[1]
    device_width = float(arg("--device-width", "0") or 0)
    min_w = float(arg("--min-w", "0") or 0)
    with open(path) as f:
        tree = json.load(f)

    root_bbox = tree.get("bbox") or {"x": 0, "y": 0, "w": 375, "h": 0}
    rx, ry = root_bbox.get("x", 0), root_bbox.get("y", 0)
    base_w = root_bbox.get("w", 375) or 375
    scale = device_width / base_w if device_width else 1.0

    rows = []

    def fill_hex(node):
        fills = node.get("fills") or []
        for fl in fills:
            if fl.get("type") == "SOLID" and fl.get("color"):
                return fl["color"]
            if str(fl.get("type", "")).startswith("GRADIENT"):
                return f"grad({fl.get('type', '')[-6:].lower()})"
        return None

    def walk(node, depth):
        bbox = node.get("bbox")
        x = y = w = h = None
        if bbox:
            x = num(bbox.get("x", 0) - rx)
            y = num(bbox.get("y", 0) - ry)
            w = num(bbox.get("w"))
            h = num(bbox.get("h"))
        if w is not None and w < min_w:
            # 작은 노드는 건너뛰되 자식은 계속 본다
            for c in node.get("children", []):
                walk(c, depth + 1)
            return

        text = node.get("text") or {}
        font = None
        color = None
        if text:
            fs = text.get("fontSizeNormalized") or text.get("fontSize")
            fw = text.get("fontWeight")
            lh = text.get("lineHeightPx")
            font = f"{fmt(num(fs))}/{fmt(fw)}/lh{fmt(num(lh))}"
            color = text.get("color")
        stroke = None
        if node.get("strokes"):
            sc = None
            for s in node["strokes"]:
                if s.get("color"):
                    sc = s["color"]
                    break
            stroke = f"{fmt(sc)} w{fmt(num(node.get('strokeWeight')))}"
        radius = node.get("cornerRadius") or node.get("rectangleCornerRadii")
        layout = node.get("layout") or {}
        gap = layout.get("itemSpacingNormalized") or layout.get("itemSpacing")
        pad = layout.get("padding")
        gap_cell = None
        if gap is not None or pad:
            gap_cell = f"gap{fmt(num(gap))}" + (f" pad{pad}" if pad else "")
        chars = (text.get("characters") or "").replace("\n", " ").strip()
        if len(chars) > 28:
            chars = chars[:28] + "…"

        coord = "-"
        if x is not None:
            coord = f"x{x} y{y} w{w} h{h}"
            if device_width:
                coord += f"  [dev x{num(x * scale)} y{num(y * scale)} w{num(w * scale)} h{num(h * scale)}]"

        rows.append(
            {
                "indent": "  " * depth,
                "name": node.get("name", "?"),
                "type": node.get("type", "?"),
                "coord": coord,
                "fill": fill_hex(node),
                "stroke": stroke,
                "radius": radius,
                "font": font,
                "color": color,
                "gap": gap_cell,
                "text": chars or None,
            }
        )
        for c in node.get("children", []):
            walk(c, depth + 1)

    walk(tree, 0)

    print(f"# {path}")
    print(f"# root frame = {base_w}×{root_bbox.get('h')}  (frame-relative 좌표)")
    if device_width:
        print(f"# device-width {device_width} → scale ×{round(scale, 4)} (screenutil .w 비교용)")
    print(f"# 노드 {len(rows)}개\n")
    for r in rows:
        head = f"{r['indent']}{r['name']} [{r['type']}]"
        print(head)
        bits = []
        if r["coord"] != "-":
            bits.append(r["coord"])
        if r["fill"]:
            bits.append(f"fill {r['fill']}")
        if r["stroke"]:
            bits.append(f"stroke {r['stroke']}")
        if r["radius"] is not None:
            bits.append(f"radius {r['radius']}")
        if r["font"]:
            bits.append(f"font {r['font']}")
        if r["color"]:
            bits.append(f"color {r['color']}")
        if r["gap"]:
            bits.append(r["gap"])
        if r["text"]:
            bits.append(f'"{r["text"]}"')
        if bits:
            print(f"{r['indent']}  · " + " · ".join(bits))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("사용: python3 tree_flatten.py <tree.json> [--device-width 402] [--min-w 4]")
        sys.exit(1)
    main()
