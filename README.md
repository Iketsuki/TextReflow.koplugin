# TextReflow

TextReflow creates a reflowable TXT companion for a PDF and uses KOReader's PDF text-box API to extract existing text or OCR pages without a text layer. OCR uses the installed KOReader Tesseract languages. The current PDF page is recognized first within the selected range; later runs reuse matching page results from the local cache.

Open the KOReader **Document** menu and choose **TextReflow → Toggle to text companion**. This creates or updates the companion if needed, then opens it. In the TXT companion, choose **Toggle back to PDF and sync highlights** to return to the source PDF. **OCR settings** lets you select an installed OCR language, set a page range, and toggle **Force OCR**. The first-page and last-page shortcuts adjust the range without opening the range dialog. Without Force OCR, KOReader uses PDF text when available and OCRs pages without a usable text layer.

TextReflow also registers **TextReflow: toggle PDF and text companion** and **TextReflow: extract PDF text** in KOReader's gesture manager. Assign either action to a gesture under **Settings → Taps and gestures → Gesture manager**; TextReflow does not take over a gesture automatically.

The companion is generated even when some pages fail or are outside the selected range. It includes a marked section for every PDF page, with a reason for failed pages and a not-processed marker for pages that have not been recognized. **Retry failed pages** runs recognition only on pages that failed previously and preserves successful page results. **Re-OCR all pages with selected language** force-recognizes the full PDF with the selected language and replaces the cached page text.

The generated TXT marks each source PDF page. On return, TextReflow matches the visible TXT text to a unique source page and navigates there; if it cannot identify one confidently, KOReader restores the PDF's previous position. Returning to the PDF also maps unique, single-page text highlights and notes back to PDF page coordinates. Annotations whose selected text is missing or ambiguous are left in the TXT companion and reported rather than being placed at an uncertain location.

The original PDF is not modified. Mapped annotations are saved in KOReader's PDF document settings, so they can be rendered in the normal PDF view and survive reflow changes.
