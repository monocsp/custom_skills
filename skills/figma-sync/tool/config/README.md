# Role map 디렉터리

`figma-snapshot-{slug}.json` — slug 1개당 1파일. `figma_sync.dart`의 입력.

각 씬의 root 노드 ID + 이름 붙인 element 노드 ID를 사람이(또는 Claude가 Figma URL을 받아) 작성한다.
Node ID는 Figma에서 레이어 선택 → URL의 `node-id=1569-47152` → 콜론 형식 `1569:47152` 로 변환.

```json
{
  "slug": "design-system",
  "description": "renew 디자인시스템 — 색/타이포/간격 기준 컴포넌트",
  "screens": {
    "buttons": {
      "rootNodeId": "1569:47152",
      "elements": {
        "primaryButton": "1569:47153",
        "primaryButtonLabel": "1569:47154"
      }
    }
  }
}
```

규칙 (fail-closed): `screens` 비어 있으면 exit 67, 노드 1개라도 못 찾으면 snapshot 미작성 + exit 2.
