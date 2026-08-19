(function () {
  const { Loader } = window.ShotStitcher;
  const Engine = window.ShotStitcher.Engine;

  const el = (id) => document.getElementById(id);
  const dropScreen = el('dropScreen'), dropZone = el('dropZone'), dropStatus = el('dropStatus');
  const appScreen = el('appScreen'), sourceBadge = el('sourceBadge'), closeServerBtn = el('closeServerBtn');
  const grid = el('grid'), gridCount = el('gridCount');
  const outNameInput = el('outNameInput'), outNamePreview = el('outNamePreview');
  const advancedToggle = el('advancedToggle'), advancedPanel = el('advancedPanel'), settingsGrid = el('settingsGrid');
  const stitchBtn = el('stitchBtn'), stitchStatus = el('stitchStatus'), stitchLog = el('stitchLog'), resultsBlock = el('resultsBlock');
  const previewOverlay = el('previewOverlay'), previewImg = el('previewImg'), previewModalTitle = el('previewModalTitle'), previewModalNote = el('previewModalNote');
  const previewIncludeChk = el('previewIncludeChk');

  const SETTINGS_KEY = 'shotStitcherSettings';
  const NAME_KEY = 'shotStitcherOutName';

  const state = {
    entries: [],     // in display/stitch order
    previewIndex: -1,
    config: loadSettings(),
    fromServer: false,
  };

  // ------------------------------------------------------------ settings

  function loadSettings() {
    try {
      const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || 'null');
      if (saved) return Object.assign({}, Engine.DEFAULT_CONFIG, saved);
    } catch (e) { /* ignore malformed storage */ }
    return Object.assign({}, Engine.DEFAULT_CONFIG);
  }
  function saveSettings() {
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(state.config)); } catch (e) { /* ignore */ }
  }

  const INT_FIELDS = new Set(['RowSamples', 'MinOverlapPixels', 'MaxOverlapSearchPixels', 'MaxOutputHeightPixels', 'FeatherPixels']);
  const FIELD_LABELS = {
    RowSamples: 'Row samples', MinOverlapPixels: 'Min overlap (px)', MaxAvgError: 'Max avg error',
    MaxOverlapSearchPixels: 'Max overlap search (px, 0=unlimited)', MaxOutputHeightPixels: 'Max sheet height (px)',
    SortMode: 'Sort mode', MinConfidence: 'Min confidence', FeatherPixels: 'Feather (px)',
    SideMarginPercent: 'Side margin %', MaxDiffPixelFraction: 'Max diff pixel fraction',
    MaxOverlapFraction: 'Max overlap fraction', DuplicateFrameMaxAvgError: 'Duplicate frame max error',
    AmbiguityMinRatio: 'Ambiguity min ratio', OverlapSharpnessRatio: 'Overlap sharpness ratio',
  };

  function buildSettingsGrid() {
    settingsGrid.innerHTML = '';
    Object.keys(Engine.DEFAULT_CONFIG).forEach(key => {
      const field = document.createElement('div');
      field.className = 'field';
      const label = document.createElement('label');
      label.textContent = FIELD_LABELS[key] || key;
      field.appendChild(label);

      if (key === 'SortMode') {
        const sel = document.createElement('select');
        ['Name', 'Date'].forEach(opt => {
          const o = document.createElement('option'); o.value = opt; o.textContent = opt;
          if (state.config.SortMode === opt) o.selected = true;
          sel.appendChild(o);
        });
        sel.addEventListener('change', () => { state.config.SortMode = sel.value; saveSettings(); });
        field.appendChild(sel);
      } else {
        const input = document.createElement('input');
        input.type = 'number';
        input.step = INT_FIELDS.has(key) ? '1' : '0.01';
        input.value = state.config[key];
        input.addEventListener('change', () => {
          const v = INT_FIELDS.has(key) ? parseInt(input.value, 10) : parseFloat(input.value);
          state.config[key] = Number.isFinite(v) ? v : Engine.DEFAULT_CONFIG[key];
          input.value = state.config[key];
          saveSettings();
        });
        field.appendChild(input);
      }
      settingsGrid.appendChild(field);
    });
  }

  el('resetSettingsBtn').addEventListener('click', () => {
    state.config = Object.assign({}, Engine.DEFAULT_CONFIG);
    saveSettings();
    buildSettingsGrid();
  });

  advancedToggle.addEventListener('click', () => {
    const open = advancedPanel.style.display === 'block';
    advancedPanel.style.display = open ? 'none' : 'block';
    advancedToggle.textContent = open ? 'Advanced settings ▾' : 'Advanced settings ▴';
  });

  outNameInput.addEventListener('input', () => {
    localStorage.setItem(NAME_KEY, outNameInput.value);
    updateOutNamePreview();
  });
  function updateOutNamePreview() {
    const name = (outNameInput.value || 'stitched').trim() || 'stitched';
    outNamePreview.textContent = `${name}.png  (or ${name}_1.png, ${name}_2.png, … if it splits into multiple sheets)`;
  }
  outNameInput.value = localStorage.getItem(NAME_KEY) || 'stitched';

  // -------------------------------------------------------------- loading

  async function addBlobs(items) {
    // items: array of { blob, name }
    for (const item of items) {
      const ext = Loader.extOf(item.name);
      if (!Loader.SUPPORTED_EXT.has(ext)) continue;
      try {
        const entry = await Loader.fromBlob(item.blob, item.name);
        state.entries.push(entry);
      } catch (err) {
        console.error('Failed to load', item.name, err);
      }
    }
    renderGrid();
    showAppScreen();
  }

  async function tryLoadFromServer() {
    dropStatus.textContent = 'Checking for a running capture session…';
    try {
      const res = await fetch('/api/list', { cache: 'no-store' });
      if (!res.ok) throw new Error('no server');
      const data = await res.json();
      const files = data.files || [];
      if (files.length === 0) {
        dropStatus.textContent = 'No screenshots found in that session yet. Drop files in, or choose them.';
        return;
      }
      dropStatus.textContent = `Loading ${files.length} screenshot(s) from ${data.folder || 'the session folder'}…`;
      const items = [];
      for (const name of files) {
        const r = await fetch('/shots/' + encodeURIComponent(name), { cache: 'no-store' });
        if (r.ok) items.push({ blob: await r.blob(), name });
      }
      state.fromServer = true;
      sourceBadge.textContent = data.folder ? `Session: ${data.folder}` : 'Loaded from capture session';
      closeServerBtn.style.display = '';
      await addBlobs(items);
      // The last shot in an auto-capture session is often a stray/partial
      // frame (e.g. the tick right before Stop was hit) - leave it in the
      // list but unchecked by default so it doesn't silently end up in the
      // stitched sheet unless the user deliberately re-checks it.
      if (state.entries.length) {
        state.entries[state.entries.length - 1].included = false;
        renderGrid();
      }
    } catch (err) {
      dropStatus.textContent = '';
    }
  }

  function showAppScreen() {
    if (state.entries.length === 0) return;
    dropScreen.style.display = 'none';
    appScreen.style.display = 'flex';
  }
  function showDropScreen() {
    appScreen.style.display = 'none';
    dropScreen.style.display = 'flex';
    dropStatus.textContent = '';
  }

  // ---------------------------------------------------------------- grid

  function renderGrid() {
    grid.innerHTML = '';
    gridCount.textContent = state.entries.length ? `(${state.entries.filter(e => e.included).length} of ${state.entries.length} kept)` : '';
    state.entries.forEach((entry, idx) => {
      const card = document.createElement('div');
      card.className = 'shotCard' + (entry.included ? '' : ' excluded');
      card.draggable = true;
      card.dataset.idx = idx;

      const top = document.createElement('div'); top.className = 'shotCardTop';
      const order = document.createElement('div'); order.className = 'shotOrder'; order.textContent = idx + 1;
      const chk = document.createElement('input'); chk.type = 'checkbox'; chk.className = 'shotCheck'; chk.checked = entry.included;
      chk.addEventListener('change', () => { entry.included = chk.checked; card.classList.toggle('excluded', !chk.checked); gridCount.textContent = `(${state.entries.filter(e => e.included).length} of ${state.entries.length} kept)`; });
      const spacer = document.createElement('div'); spacer.className = 'shotSpacer';
      const remove = document.createElement('button'); remove.className = 'shotRemove'; remove.textContent = '×'; remove.title = 'Remove';
      remove.addEventListener('click', (e) => { e.stopPropagation(); removeEntry(idx); });
      top.append(order, chk, spacer, remove);

      const thumbWrap = document.createElement('div'); thumbWrap.className = 'shotThumbWrap';
      const img = document.createElement('img'); img.src = entry.thumbUrl; img.alt = entry.name;
      img.addEventListener('click', () => openPreview(idx));
      thumbWrap.appendChild(img);

      const name = document.createElement('div'); name.className = 'shotName'; name.textContent = entry.name;
      const meta = document.createElement('div'); meta.className = 'shotMeta'; meta.textContent = `${entry.width}×${entry.height}`;

      card.append(top, thumbWrap, name, meta);

      card.addEventListener('dragstart', (e) => {
        card.classList.add('dragging');
        e.dataTransfer.setData('text/plain', String(idx));
        e.dataTransfer.effectAllowed = 'move';
      });
      card.addEventListener('dragend', () => card.classList.remove('dragging'));
      card.addEventListener('dragover', (e) => { e.preventDefault(); card.classList.add('dragOver'); });
      card.addEventListener('dragleave', () => card.classList.remove('dragOver'));
      card.addEventListener('drop', (e) => {
        e.preventDefault();
        card.classList.remove('dragOver');
        const from = parseInt(e.dataTransfer.getData('text/plain'), 10);
        const to = idx;
        if (from === to || Number.isNaN(from)) return;
        const [moved] = state.entries.splice(from, 1);
        state.entries.splice(to, 0, moved);
        renderGrid();
      });

      grid.appendChild(card);
    });
  }

  function removeEntry(idx) {
    const [removed] = state.entries.splice(idx, 1);
    if (removed) URL.revokeObjectURL(removed.blobUrl);
    if (state.entries.length === 0) { showDropScreen(); }
    renderGrid();
  }

  el('selectAllBtn').addEventListener('click', () => { state.entries.forEach(e => e.included = true); renderGrid(); });
  el('selectNoneBtn').addEventListener('click', () => { state.entries.forEach(e => e.included = false); renderGrid(); });

  el('clearAllBtn').addEventListener('click', () => {
    state.entries.forEach(e => URL.revokeObjectURL(e.blobUrl));
    state.entries = [];
    resultsBlock.innerHTML = '';
    stitchStatus.textContent = '';
    stitchLog.textContent = '';
    showDropScreen();
  });

  closeServerBtn.addEventListener('click', async () => {
    try { await fetch('/api/shutdown', { method: 'POST' }); } catch (e) { /* ignore */ }
    closeServerBtn.textContent = 'Server closed';
    closeServerBtn.disabled = true;
  });

  // ------------------------------------------------------------- preview

  function openPreview(idx) {
    state.previewIndex = idx;
    renderPreview();
    previewOverlay.style.display = 'flex';
  }
  function renderPreview() {
    const entry = state.entries[state.previewIndex];
    if (!entry) { previewOverlay.style.display = 'none'; return; }
    previewImg.src = entry.blobUrl;
    previewModalTitle.textContent = entry.name;
    previewModalNote.textContent = `${state.previewIndex + 1} of ${state.entries.length} · ${entry.width}×${entry.height}`;
    previewIncludeChk.checked = entry.included;
  }
  el('previewCloseBtn').addEventListener('click', () => { previewOverlay.style.display = 'none'; renderGrid(); });
  el('previewPrevBtn').addEventListener('click', () => { if (state.previewIndex > 0) { state.previewIndex--; renderPreview(); } });
  el('previewNextBtn').addEventListener('click', () => { if (state.previewIndex < state.entries.length - 1) { state.previewIndex++; renderPreview(); } });
  previewIncludeChk.addEventListener('change', () => {
    const entry = state.entries[state.previewIndex];
    if (entry) entry.included = previewIncludeChk.checked;
  });
  previewOverlay.addEventListener('click', (e) => { if (e.target === previewOverlay) { previewOverlay.style.display = 'none'; renderGrid(); } });
  document.addEventListener('keydown', (e) => {
    if (previewOverlay.style.display !== 'flex') return;
    if (e.key === 'Escape') { previewOverlay.style.display = 'none'; renderGrid(); }
    if (e.key === 'ArrowLeft') el('previewPrevBtn').click();
    if (e.key === 'ArrowRight') el('previewNextBtn').click();
  });

  // -------------------------------------------------------------- stitch

  function logLine(msg) {
    stitchLog.textContent += (stitchLog.textContent ? '\n' : '') + msg;
    stitchLog.scrollTop = stitchLog.scrollHeight;
  }

  function canvasToBlob(canvas) {
    return new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
  }

  function downloadBlob(filename, blob) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
  }

  // Uploads one stitched sheet to the CodeOCR tool's hand-off queue and
  // returns the URL to open it in. Only works when this page itself is
  // being served by Start-ReviewWebServer.ps1 (which is what exposes
  // /api/send-to-ocr) - a plain file:// / drag-drop load has nowhere to
  // POST to, so that surfaces as a normal thrown error.
  async function uploadToOcr(item) {
    const blob = await canvasToBlob(item.canvas);
    const res = await fetch('/api/send-to-ocr?name=' + encodeURIComponent(item.filename), {
      method: 'POST',
      headers: { 'Content-Type': 'image/png' },
      body: blob,
    });
    let data = {};
    try { data = await res.json(); } catch (e) { /* non-JSON error body, fall through */ }
    if (!res.ok || !data.ok) throw new Error(data.error || `Server responded ${res.status}`);
    return data.url;
  }

  // Hands a single stitched sheet off to CodeOCR and opens it in its own tab.
  async function sendToOcr(item, btn, statusEl) {
    btn.disabled = true;
    statusEl.className = 'ocrStatus';
    statusEl.textContent = 'Sending…';
    try {
      const url = await uploadToOcr(item);
      window.open(url, '_blank');
      statusEl.textContent = 'Opened in OCR tool ✓';
    } catch (err) {
      console.error('Send to OCR failed', err);
      statusEl.className = 'ocrStatus error';
      statusEl.textContent = "Couldn't send — " + (err.message || 'is the review server running?');
    } finally {
      btn.disabled = false;
    }
  }

  // Hands every stitched sheet off to CodeOCR's hand-off queue, one upload
  // at a time, then opens a single OCR tab that picks up the whole batch at
  // once (see ocr-handoff.js's /api/pending-images fetch on that end).
  async function sendAllToOcr(items, btn, statusEl) {
    btn.disabled = true;
    statusEl.className = 'ocrStatus';
    statusEl.textContent = `Sending ${items.length} sheet(s)…`;
    let url = null;
    let failCount = 0;
    for (const item of items) {
      try {
        url = await uploadToOcr(item);
      } catch (err) {
        console.error('Send to OCR failed for', item.filename, err);
        failCount++;
      }
    }
    btn.disabled = false;
    if (!url) {
      statusEl.className = 'ocrStatus error';
      statusEl.textContent = "Couldn't send — is the review server running?";
      return;
    }
    window.open(url, '_blank');
    statusEl.textContent = failCount
      ? `Opened in OCR tool ✓ (${failCount} of ${items.length} failed to send)`
      : `Sent all ${items.length} sheet(s) — opened in OCR tool ✓`;
  }

  stitchBtn.addEventListener('click', async () => {
    const included = state.entries.filter(e => e.included);
    if (included.length === 0) {
      stitchStatus.textContent = 'Nothing selected — check at least one screenshot to stitch.';
      stitchStatus.className = 'error';
      return;
    }

    stitchBtn.disabled = true;
    stitchStatus.className = '';
    stitchStatus.textContent = 'Stitching…';
    stitchLog.textContent = '';
    resultsBlock.innerHTML = '';

    const stitchEntries = included.map(e => ({ name: e.name, getImage: () => Loader.loadFullImage(e) }));

    try {
      const sheets = await Engine.stitchAll(stitchEntries, state.config, logLine);
      stitchStatus.textContent = `Done — ${sheets.length} sheet(s) ready below.`;
      const baseName = (outNameInput.value || 'stitched').trim() || 'stitched';

      // Build canvases + filenames first so every download action can be
      // stacked in one list up top, before the (potentially long) image
      // previews — no more scrolling past every sheet to find its button.
      const built = sheets.map((sheet, i) => {
        const canvas = document.createElement('canvas');
        canvas.width = sheet.width; canvas.height = sheet.height;
        canvas.getContext('2d').putImageData(Engine.toImageData(sheet), 0, 0);
        const filename = sheets.length > 1 ? `${baseName}_${i + 1}.png` : `${baseName}.png`;
        return { sheet, canvas, filename };
      });

      const downloadsBar = document.createElement('div'); downloadsBar.className = 'downloadsBar';

      if (built.length > 1) {
        const allBtn = document.createElement('button');
        allBtn.className = 'downloadAllBtn';
        allBtn.textContent = `Download all (${built.length})`;
        allBtn.addEventListener('click', async () => {
          for (const item of built) {
            downloadBlob(item.filename, await canvasToBlob(item.canvas));
            // Small stagger — firing many downloadBlob() calls back-to-back
            // can get silently dropped by the browser's multi-download guard.
            await new Promise(r => setTimeout(r, 300));
          }
        });
        downloadsBar.appendChild(allBtn);

        const allOcrRow = document.createElement('div'); allOcrRow.className = 'sendAllOcrRow';
        const allOcrBtn = document.createElement('button');
        allOcrBtn.className = 'sendAllOcrBtn';
        allOcrBtn.textContent = `Send all to OCR (${built.length})`;
        const allOcrStatus = document.createElement('span'); allOcrStatus.className = 'ocrStatus';
        allOcrBtn.addEventListener('click', () => sendAllToOcr(built, allOcrBtn, allOcrStatus));
        allOcrRow.append(allOcrBtn, allOcrStatus);
        downloadsBar.appendChild(allOcrRow);
      }

      for (const item of built) {
        const row = document.createElement('div'); row.className = 'downloadRow';
        const name = document.createElement('span'); name.className = 'downloadRowName';
        name.textContent = `${item.filename} — ${item.sheet.width}×${item.sheet.height}px`;
        const btn = document.createElement('button'); btn.textContent = 'Download';
        btn.addEventListener('click', async () => downloadBlob(item.filename, await canvasToBlob(item.canvas)));
        const ocrBtn = document.createElement('button'); ocrBtn.className = 'ocrBtn'; ocrBtn.textContent = 'Send to OCR';
        const ocrStatus = document.createElement('span'); ocrStatus.className = 'ocrStatus';
        ocrBtn.addEventListener('click', () => sendToOcr(item, ocrBtn, ocrStatus));
        row.append(name, btn, ocrBtn, ocrStatus);
        downloadsBar.appendChild(row);
      }

      resultsBlock.appendChild(downloadsBar);

      for (const item of built) {
        const card = document.createElement('div'); card.className = 'sheetCard';
        const img = document.createElement('img'); img.src = item.canvas.toDataURL('image/png');
        const meta = document.createElement('div'); meta.className = 'sheetMeta';
        meta.textContent = `${item.filename} — ${item.sheet.width}×${item.sheet.height}px`;
        card.append(img, meta);
        resultsBlock.appendChild(card);
      }
    } catch (err) {
      console.error(err);
      stitchStatus.textContent = 'Stitching failed: ' + err.message;
      stitchStatus.className = 'error';
    } finally {
      stitchBtn.disabled = false;
    }
  });

  // ------------------------------------------------------------- input UI

  el('chooseBtn').addEventListener('click', () => el('fileInput').click());
  el('fileInput').addEventListener('change', (e) => {
    addBlobs(Array.from(e.target.files).map(f => ({ blob: f, name: f.name })));
    e.target.value = '';
  });
  el('addMoreBtn').addEventListener('click', () => el('addMoreInput').click());
  el('addMoreInput').addEventListener('change', (e) => {
    addBlobs(Array.from(e.target.files).map(f => ({ blob: f, name: f.name })));
    e.target.value = '';
  });

  ['dragover', 'dragenter'].forEach(evt => dropZone.addEventListener(evt, (e) => { e.preventDefault(); dropZone.classList.add('drag'); }));
  ['dragleave', 'drop'].forEach(evt => dropZone.addEventListener(evt, (e) => { e.preventDefault(); dropZone.classList.remove('drag'); }));
  dropZone.addEventListener('drop', (e) => {
    const files = Array.from(e.dataTransfer.files || []);
    if (files.length) addBlobs(files.map(f => ({ blob: f, name: f.name })));
  });

  // ------------------------------------------------------------------ go

  buildSettingsGrid();
  updateOutNamePreview();
  tryLoadFromServer();
})();
