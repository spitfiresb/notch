# Codex character study

Open `index.html` directly in a browser, or serve this directory:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory docs/previews/codex-character
```

Preview only. No Swift app files are changed by this study.

`sprite.js` contains the original 20-column × 24-row flat pixel drawing and its state poses. The preview shows notification choreography based on `SessionToastView.swift`, a 14 pt collapsed indicator, and an adjustable 15–24 pt notification character. Browser zoom should stay at 100% for size comparisons; SwiftUI Canvas should be verified at native display scale when porting. This demonstrates visual states, not new monitoring capabilities.
