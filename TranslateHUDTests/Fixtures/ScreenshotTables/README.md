# Screenshot table fixtures

The synthetic four-row, three-column English table has an empty cell in row three, column two.

- `ruled.png`: complete dark grid; both recognizers should recover all four rows and three columns.
- `unruled.png`: the grid was removed. On the macOS 26.6.2 test host Vision wrongly includes the page title as a merged table cell. The checker must reject this candidate.
- `borderless.png`: the unruled table without the separate page title. Vision and independent OCR both identify the same dense, regularly aligned cells; macOS 26 may accept it.
- `merged.png`: the first row has a missing vertical border, representing a merged cell. On macOS 26.6.2 Vision misses the merge; the independent grid check rejects it.
- `36rows.png` and `36rows-merged.png`: the same long ruled grid with one internal line segment intact or absent. Even one missing segment must be rejected.
- `mixed-zh.png`: Chinese and English text with gray borders; expected positions match the original 4×3 grid.
- `multiline.png`: two OCR text lines appear in one ruled cell and must remain together in that cell.
- `two-tables.png` and `merged-fullwidth.png`: two separated grids are visually indistinguishable from a table with a full-width middle row and no vertical borders. Both must be declined rather than guessed.
- `merged-fullwidth-framed.png`: the same merged row with outer vertical borders; it must be declined as a merged cell.
- `ruled-and-borderless.png`: one ruled and one borderless table. macOS 26 checks each candidate's own bounds; the ruled table must not block the borderless one.

To run a host-side probe independently of XCTest, from the repository root:

```sh
swiftc -parse-as-library scripts/probes/screenshot-table.swift TranslateHUD/Features/Screenshot/ScreenshotTableRecognizer.swift -o /tmp/translatehud-table-probe
for name in ruled unruled merged borderless 36rows 36rows-merged mixed-zh multiline two-tables merged-fullwidth merged-fullwidth-framed ruled-and-borderless; do /tmp/translatehud-table-probe "TranslateHUDTests/Fixtures/ScreenshotTables/$name.png"; done
```

The Vision assertions require macOS 26; the grid fallback runs on supported older macOS versions. Borderless acceptance requires at least three regular rows, two occupied cells per row, and repeated column anchors. Multiple ambiguous grids, merged cells, faint lines, multi-line cells in borderless tables and sparse layouts may still fall back to ordinary OCR. Results can differ with the operating system's OCR model. These samples do not establish accuracy for all real-world tables.
