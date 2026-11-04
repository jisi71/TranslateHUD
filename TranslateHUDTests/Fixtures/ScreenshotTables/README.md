# Screenshot table fixtures

These three synthetic 1200×620 PNGs contain the same four-row, three-column English table. The third row's middle cell is empty.

- `ruled.png`: complete dark grid; both recognizers should recover all four rows and three columns.
- `unruled.png`: the grid was removed. On the macOS 26.6.2 test host Vision wrongly includes the page title as a merged table cell. The checker must reject this candidate.
- `merged.png`: the first row has a missing vertical border, representing a merged cell. On macOS 26.6.2 Vision misses the merge; the independent grid check rejects it.

To run a host-side probe independently of XCTest, from the repository root:

```sh
swiftc -parse-as-library scripts/probes/screenshot-table.swift TranslateHUD/Features/Screenshot/ScreenshotTableRecognizer.swift -o /tmp/translatehud-table-probe
for name in ruled unruled merged; do /tmp/translatehud-table-probe "TranslateHUDTests/Fixtures/ScreenshotTables/$name.png"; done
```

The Vision assertions require macOS 26; the grid fallback runs on supported older macOS versions. Results can differ with the operating system's OCR model. These samples do not establish accuracy for all real-world tables.
