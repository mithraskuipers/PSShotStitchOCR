/*!
 * Application logic for the offline OCR tool.
 *
 * Handles: drag/drop + file input, image preview, the OCR job queue
 * (single or parallel workers via a reusable worker-pool singleton),
 * language presets, and rendering results/progress in the UI.
 *
 * Depends on tesseract-assets.js being loaded first (defines `Tesseract`
 * and the embedded <script type="text/plain"> data blobs this file reads
 * via document.getElementById(...).textContent).
 */

(() => {
  const dropzone = document.getElementById('dropzone');
  const fileInput = document.getElementById('fileInput');
  const previewWrap = document.getElementById('previewWrap');
  const previewCanvas = document.getElementById('previewCanvas');
  const runBtn = document.getElementById('runBtn');
  const scaleInput = document.getElementById('scale');
  const scaleVal = document.getElementById('scaleVal');
  const preprocessChk = document.getElementById('preprocess');
  const strictChk = document.getElementById('strictCharset');
  const strictLabel = document.getElementById('strictLabel');
  const progress = document.getElementById('progress');
  const progressBar = document.getElementById('progressBar');
  const statusEl = document.getElementById('status');
  const output = document.getElementById('output');
  const ruler = document.getElementById('ruler');
  const langSelect = document.getElementById('langSelect');
  const langHint = document.getElementById('langHint');
  const queueField = document.getElementById('queueField');
  const queueCount = document.getElementById('queueCount');
  const jobList = document.getElementById('jobList');
  const sortButtons = Array.from(document.querySelectorAll('.job-toolbar button[data-sort]'));
  const combineBtn = document.getElementById('combineBtn');
  const concurrencyInput = document.getElementById('concurrency');
  const concurrencyVal = document.getElementById('concurrencyVal');

  // ---------- Job queue (multiple images, parallel or one-at-a-time) ----------
  // Every loaded image becomes a "job" sitting in this array. Jobs run either
  // one at a time (queue) or several at once (parallel), controlled by the
  // "Parallel workers" slider.
  let jobs = [];
  let jobSeq = 0;
  let selectedJobId = null;
  let dragJobId = null;
  let activeSort = null; // 'alpha-asc' | 'alpha-desc' | 'num-asc' | 'num-desc' | null (manual order)
  // True while the output box is showing the combined text of every
  // finished job (see combineBtn below) rather than a single job's
  // output, so typed edits don't get written back into one job's record.
  let viewingCombined = false;

  function selectedJob(){
    return jobs.find(j => j.id === selectedJobId) || null;
  }

  // ---------- Worker pool ----------
  // Spinning up a Tesseract worker means instantiating the WASM engine and
  // loading/initializing the language data — by far the most expensive part
  // of a "recognize" call. Previously a fresh worker was created and then
  // terminated on every single Run-OCR click, so every run paid that full
  // startup cost again. Instead we keep one long-lived worker per parallel
  // slot (lazily created), reused across every job that slot processes;
  // only setParameters (cheap) runs each time. Each slot's logger reports
  // progress for whichever job currently occupies that slot.
  let workerPool = [];
  let activeJobBySlot = [];
  function getPoolWorker(slot){
    if(!workerPool[slot]){
      const logger = m => {
        const job = activeJobBySlot[slot];
        if(!job) return;
        if(m.status){
          job.statusText = m.status + (m.progress ? ` (${Math.round(m.progress*100)}%)` : '');
        }
        if(typeof m.progress === 'number'){
          job.progressPct = Math.round(m.progress*100);
        }
        if(job.id === selectedJobId) reflectSelectedJobProgress(job);
      };
      const options = {
        // Fully offline: point Tesseract.js at the vendored worker/core blobs
        // built from the <script type="text/plain"> payloads above, instead
        // of its normal jsdelivr CDN defaults.
        ...buildOfflineTesseractOptions(),
        logger
      };
      workerPool[slot] = Tesseract.createWorker([{ code: 'eng', data: getEmbeddedLangData() }], 1, options);
    }
    return workerPool[slot];
  }

  // ---------- Offline Tesseract.js wiring ----------
  // Turns the embedded <script type="text/plain"> payloads into the
  // workerPath/corePath/lang-data Tesseract.js needs, so it never has to
  // fetch anything from jsdelivr at runtime.
  let offlineOptionsCache = null;
  function buildOfflineTesseractOptions(){
    if(offlineOptionsCache) return offlineOptionsCache;

    let workerSrc = document.getElementById('ts-worker-src').textContent;
    // Patch a bug in the vendored tesseract.js worker: when languages are
    // passed as {code, data} objects (required for fully-offline embedded
    // language data, since there's no URL to fetch from), the "initialize"
    // handler builds the language string for TessBaseAPI.Init() from
    // `t.data` (the raw traineddata bytes) instead of `t.code` ("eng").
    // That turns the language argument into a garbage "137,80,..." string,
    // so Tesseract can't find any language and initialization always fails
    // with "Tesseract couldn't load any languages!". The loadLanguage
    // handler elsewhere already reads `.code` correctly; this just aligns
    // the initialize handler with it.
    workerSrc = workerSrc.replace(
      '"string"==typeof t?t:t.data})).join("+")',
      '"string"==typeof t?t:t.code})).join("+")'
    );
    const workerBlobUrl = URL.createObjectURL(
      new Blob([workerSrc], { type: 'application/javascript' })
    );

    const coreSrc = document.getElementById('ts-core-src').textContent;
    // Tesseract.js only treats corePath as a direct file (rather than a
    // directory it should append a filename to) when the string ends in
    // "js". Blob URLs don't naturally end that way, so we tack on a harmless
    // "#core.js" fragment — browsers strip fragments before resolving the
    // blob, but the string itself still satisfies that check.
    const coreBlobUrl = URL.createObjectURL(
      new Blob([coreSrc], { type: 'application/javascript' })
    ) + '#core.js';

    offlineOptionsCache = {
      workerPath: workerBlobUrl,
      workerBlobURL: false, // workerPath is already the real worker script; don't double-wrap it
      corePath: coreBlobUrl,
    };
    return offlineOptionsCache;
  }

  let langDataCache = null;
  function getEmbeddedLangData(){
    if(langDataCache) return langDataCache;
    const b64 = document.getElementById('ts-lang-eng-b64').textContent;
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for(let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    langDataCache = bytes; // still gzipped — Tesseract.js gunzips it automatically
    return langDataCache;
  }

  // ---------- Language presets ----------
  // Add a new language by adding an entry here. `zones` (optional) draws a
  // fixed-column ruler like COBOL's coding sheet; leave it out for free-form
  // languages and only a plain column ruler is shown.
  const LANGUAGES = {
    cobol: {
      label: 'COBOL (fixed-format columns)',
      hint: 'Classic coding-sheet columns: 1–6 sequence, 7 indicator, 8–11 Area A, 12+ Area B.',
      extension: 'cbl',
      charset: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,'\"-+*/=():$<>_",
      zones: [
        { end: 6, cls: 'seq' },
        { end: 7, cls: 'ind' },
        { end: 11, cls: 'areaA' },
        { end: Infinity, cls: 'areaB' }
      ],
      legend: [
        { cls: 'seq', text: '1–6 sequence' },
        { cls: 'ind', text: '7 indicator' },
        { cls: 'areaA', text: '8–11 Area A' },
        { cls: 'areaB', text: '12+ Area B' }
      ]
    },
    plaintext: {
      label: 'Plain / free-format (generic)',
      hint: 'No fixed columns enforced — just a ruler for reference. Good starting point for other languages.',
      extension: 'txt',
      charset: null,
      zones: [{ end: Infinity, cls: 'areaB' }],
      legend: []
    }
  };

  function populateLanguageSelect(){
    langSelect.innerHTML = Object.entries(LANGUAGES)
      .map(([key, cfg]) => `<option value="${key}">${cfg.label}</option>`)
      .join('');
    langSelect.value = 'cobol';
  }
  populateLanguageSelect();

  function currentLang(){
    return LANGUAGES[langSelect.value] || LANGUAGES.plaintext;
  }

  function refreshLangUI(){
    const cfg = currentLang();
    langHint.textContent = cfg.hint;
    strictLabel.textContent = cfg.charset
      ? `Restrict to ${cfg.label.split(' ')[0]} character set`
      : 'Restrict to language character set (no preset charset for this language)';
    strictChk.disabled = !cfg.charset;
    if(!cfg.charset) strictChk.checked = false;
    const downloadExtEl = document.getElementById('downloadExt');
    if(downloadExtEl) downloadExtEl.textContent = cfg.extension;
    buildRuler(80);
  }
  langSelect.addEventListener('change', refreshLangUI);

  // ---------- Coding-sheet ruler (columns 1-80, zones from the active language preset) ----------
  function buildRuler(width){
    const cfg = currentLang();
    const cols = Math.max(width, 80);
    let zones = '';
    let numbers = '';
    for(let c = 1; c <= cols; c++){
      const zone = cfg.zones.find(z => c <= z.end);
      const cls = zone ? zone.cls : 'areaB';
      zones += `<span class="${cls}"> </span>`;
      const label = (c % 10 === 0) ? String(c) : '';
      numbers += `<span>${label ? label.slice(-1) : (c % 5 === 0 ? '·' : '')}</span>`;
    }
    const legendHtml = cfg.legend.length
      ? cfg.legend.map(l => `<span><i class="${l.cls}">&nbsp;&nbsp;</i> ${l.text}</span>`).join('')
      : '';
    ruler.innerHTML = `
      <div class="zones">${zones}</div>
      <div class="numbers">${numbers}</div>
      <div class="legend">${legendHtml}</div>`;
  }
  refreshLangUI();

  // ---------- File loading (multiple images) ----------
  function addJob(file){
    if(!file || !file.type.startsWith('image/')) return;
    const job = {
      id: ++jobSeq,
      file,
      name: file.name || `image-${jobSeq}`,
      img: null,
      status: 'queued', // queued | running | done | error
      statusText: '',
      progressPct: 0,
      output: '',
      error: null
    };
    jobs.push(job);
    const img = new Image();
    img.onload = () => {
      job.img = img;
      if(!selectedJobId) selectJob(job.id);
      renderJobList();
    };
    img.src = URL.createObjectURL(file);
    renderJobList();
  }

  function loadFiles(fileList){
    const files = Array.from(fileList || []).filter(f => f.type && f.type.startsWith('image/'));
    if(!files.length) return;
    files.forEach(addJob);
    if(activeSort) sortJobs(activeSort); // keep newly added files in the chosen sort order
    statusEl.textContent = files.length === 1
      ? `Loaded: ${files[0].name}`
      : `Loaded ${files.length} images`;
  }

  function escapeHtml(s){
    return String(s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
  }

  function statusBadge(job){
    switch(job.status){
      case 'running': return job.progressPct ? `Running ${job.progressPct}%` : 'Running…';
      case 'done': return 'Done';
      case 'error': return 'Error';
      default: return 'Queued';
    }
  }

  function renderJobList(){
    queueField.style.display = jobs.length ? 'block' : 'none';
    queueCount.textContent = jobs.length;
    jobList.innerHTML = jobs.map(job => `
      <div class="job-row${job.id === selectedJobId ? ' selected' : ''}" data-job-id="${job.id}" draggable="true">
        <span class="job-drag-handle" title="Drag to reorder">⠿</span>
        <span class="job-name">${escapeHtml(job.name)}</span>
        <span class="job-status ${job.status}">${statusBadge(job)}</span>
      </div>`).join('');
    jobList.querySelectorAll('.job-row').forEach(row => {
      row.addEventListener('click', (e) => {
        // Ignore clicks that were really the tail end of a drag on the handle.
        if(e.target.closest('.job-drag-handle') && dragJobId !== null) return;
        selectJob(parseInt(row.dataset.jobId, 10));
      });
      row.addEventListener('dragstart', (e) => {
        dragJobId = parseInt(row.dataset.jobId, 10);
        row.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
        // Manual reordering takes over from any active sort.
        activeSort = null;
        updateSortButtonStates();
      });
      row.addEventListener('dragend', () => {
        dragJobId = null;
        jobList.querySelectorAll('.job-row').forEach(r => r.classList.remove('dragging', 'drag-over'));
      });
      row.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        if(parseInt(row.dataset.jobId, 10) !== dragJobId) row.classList.add('drag-over');
      });
      row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
      row.addEventListener('drop', (e) => {
        e.preventDefault();
        row.classList.remove('drag-over');
        const targetId = parseInt(row.dataset.jobId, 10);
        if(dragJobId === null || dragJobId === targetId) return;
        reorderJobs(dragJobId, targetId);
      });
    });
    const runnable = jobs.some(j => j.status === 'queued' || j.status === 'error');
    runBtn.disabled = !runnable;
    runBtn.textContent = jobs.length > 1 ? `Extract code from ${jobs.length} images` : 'Extract code';
    combineBtn.style.display = jobs.length > 1 ? 'inline-block' : 'none';
  }

  // Moves the dragged job to sit just before the drop target, then re-renders.
  function reorderJobs(draggedId, targetId){
    const fromIndex = jobs.findIndex(j => j.id === draggedId);
    const toIndex = jobs.findIndex(j => j.id === targetId);
    if(fromIndex === -1 || toIndex === -1) return;
    const [moved] = jobs.splice(fromIndex, 1);
    jobs.splice(toIndex, 0, moved);
    renderJobList();
  }

  // Pulls a leading number out of a filename for numeric sort (e.g. "img2.png" -> 2).
  // Files without a leading number sort after numbered ones, in original order.
  function leadingNumber(name){
    const m = String(name).match(/\d+/);
    return m ? parseInt(m[0], 10) : null;
  }

  function sortJobs(mode){
    activeSort = mode;
    const withOriginalIndex = jobs.map((job, i) => ({ job, i }));
    withOriginalIndex.sort((a, b) => {
      if(mode === 'alpha-asc' || mode === 'alpha-desc'){
        const cmp = a.job.name.localeCompare(b.job.name, undefined, { numeric: true, sensitivity: 'base' });
        return mode === 'alpha-asc' ? cmp : -cmp;
      }
      // Numeric sort: entries without a detectable number sink to the bottom,
      // keeping their relative order, regardless of ascending/descending.
      const na = leadingNumber(a.job.name);
      const nb = leadingNumber(b.job.name);
      if(na === null && nb === null) return a.i - b.i;
      if(na === null) return 1;
      if(nb === null) return -1;
      const cmp = na - nb;
      return mode === 'num-asc' ? cmp : -cmp;
    });
    jobs = withOriginalIndex.map(x => x.job);
    updateSortButtonStates();
    renderJobList();
  }

  function updateSortButtonStates(){
    sortButtons.forEach(btn => btn.classList.toggle('active', btn.dataset.sort === activeSort));
  }

  sortButtons.forEach(btn => btn.addEventListener('click', () => sortJobs(btn.dataset.sort)));

  function reflectSelectedJobProgress(job){
    if(job.status === 'running'){
      statusEl.textContent = job.statusText || 'Processing…';
      progressBar.style.width = `${job.progressPct || 0}%`;
    } else if(job.status === 'error'){
      statusEl.textContent = 'Something went wrong reading this image: ' + job.error;
    } else if(job.status === 'done'){
      statusEl.textContent = 'Done. Check alignment against the ruler above — edit directly if needed.';
    } else {
      statusEl.textContent = job.img ? `Loaded: ${job.img.width}×${job.img.height}px` : 'Loading…';
    }
  }

  function selectJob(id){
    selectedJobId = id;
    viewingCombined = false;
    const job = selectedJob();
    if(!job) return;
    if(job.img){
      const ctx = previewCanvas.getContext('2d');
      previewCanvas.width = job.img.width;
      previewCanvas.height = job.img.height;
      ctx.drawImage(job.img, 0, 0);
      previewWrap.style.display = 'block';
    }
    output.value = job.output || '';
    if(job.output){
      const maxLineLen = Math.max(80, ...job.output.split('\n').map(l => l.length));
      buildRuler(maxLineLen);
    } else {
      buildRuler(80);
    }
    reflectSelectedJobProgress(job);
    renderJobList();
  }

  // Keep manual edits to the output box synced back onto the job it belongs
  // to, so switching away and back (or downloading) doesn't lose them.
  // Skipped while viewing the combined multi-image text, since that's not
  // any single job's output.
  output.addEventListener('input', () => {
    if(viewingCombined) return;
    const job = selectedJob();
    if(job) job.output = output.value;
  });

  // ---------- Combine all extracted texts ----------
  // Concatenates every finished job's output in queue order (first image
  // added on top, then each next image's text below it) into the output
  // box, so you don't have to copy each result out one at a time.
  combineBtn.addEventListener('click', () => {
    const doneJobs = jobs.filter(j => j.status === 'done' && j.output);
    if(!doneJobs.length){
      statusEl.textContent = 'No completed results yet to combine — run OCR first.';
      return;
    }
    const combined = doneJobs.map(j => j.output.replace(/\s+$/, '')).join('\n\n');
    selectedJobId = null;
    viewingCombined = true;
    output.value = combined;
    previewWrap.style.display = 'none';
    const maxLineLen = Math.max(80, ...combined.split('\n').map(l => l.length));
    buildRuler(maxLineLen);
    statusEl.textContent = doneJobs.length === jobs.length
      ? `Combined all ${doneJobs.length} results (top to bottom, in queue order).`
      : `Combined ${doneJobs.length} of ${jobs.length} finished results — the rest haven't been processed yet.`;
    renderJobList();
  });

  dropzone.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', e => { loadFiles(e.target.files); fileInput.value = ''; });
  ['dragenter','dragover'].forEach(evt =>
    dropzone.addEventListener(evt, e => { e.preventDefault(); dropzone.classList.add('drag'); }));
  ['dragleave','drop'].forEach(evt =>
    dropzone.addEventListener(evt, e => { e.preventDefault(); dropzone.classList.remove('drag'); }));
  dropzone.addEventListener('drop', e => loadFiles(e.dataTransfer.files));

  // ---------- Paste-to-load ----------
  // Listen globally so Ctrl/Cmd+V works anywhere on the page, not just when
  // the dropzone happens to be focused.
  function handlePaste(e){
    const items = (e.clipboardData || window.clipboardData)?.items;
    if(!items) return;
    const files = [];
    for(const item of items){
      if(item.type && item.type.startsWith('image/')){
        const file = item.getAsFile();
        if(file) files.push(file);
      }
    }
    if(files.length){
      e.preventDefault();
      loadFiles(files);
      statusEl.textContent = files.length === 1
        ? 'Loaded image from clipboard'
        : `Loaded ${files.length} images from clipboard`;
    }
  }

  document.addEventListener('paste', handlePaste);

  scaleInput.addEventListener('input', () => { scaleVal.textContent = `${parseFloat(scaleInput.value).toFixed(1)}×`; });

  concurrencyInput.addEventListener('input', () => {
    const n = parseInt(concurrencyInput.value, 10) || 1;
    concurrencyVal.textContent = n === 1 ? '1 (queue)' : `${n} (parallel)`;
  });

  // ---------- Preprocessing: build the canvas actually sent to the OCR engine ----------
  function buildProcessedCanvas(img){
    const scale = parseFloat(scaleInput.value);
    const w = Math.round(img.width * scale);
    const h = Math.round(img.height * scale);
    const canvas = document.createElement('canvas');
    canvas.width = w; canvas.height = h;
    const ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img, 0, 0, w, h);

    if(preprocessChk.checked){
      const imgData = ctx.getImageData(0, 0, w, h);
      const d = imgData.data;
      // grayscale + simple adaptive-ish threshold (Otsu-lite via global mean)
      let sum = 0;
      const gray = new Uint8ClampedArray(w * h);
      for(let i = 0, p = 0; i < d.length; i += 4, p++){
        const g = 0.299*d[i] + 0.587*d[i+1] + 0.114*d[i+2];
        gray[p] = g;
        sum += g;
      }
      const mean = sum / gray.length;
      // push contrast around the mean rather than a hard binary threshold,
      // to avoid destroying thin character strokes in low-res source images
      for(let i = 0, p = 0; i < d.length; i += 4, p++){
        const g = gray[p];
        const boosted = mean + (g - mean) * 1.6;
        const v = Math.max(0, Math.min(255, boosted));
        d[i] = d[i+1] = d[i+2] = v;
      }
      ctx.putImageData(imgData, 0, 0);
    }
    return canvas;
  }

  // ---------- Detect runs of a single repeated glyph (asterisk/dash/underscore borders) ----------
  // Tesseract's LSTM model is trained on natural text and has no real concept
  // of "this is a decorative border of stars" — long runs of '*' (or '-'/'_')
  // routinely get hallucinated into runs of unrelated letters (h, d, k, etc.)
  // because the engine is trying to force a language-model interpretation
  // onto a shape it doesn't recognize. Rather than trust the OCR text for
  // such runs, we inspect the actual pixels inside a word's bounding box: if
  // it's made up of several near-identical, evenly-spaced ink blobs, we
  // classify the blob shape geometrically and rebuild the text as that
  // character repeated exactly as many times as blobs were found — which is
  // far more reliable than the OCR guess for this specific failure mode.
  function detectRepeatedGlyph(canvas, bbox){
    if(!bbox) return null;
    const x0 = Math.max(0, Math.floor(bbox.x0));
    const y0 = Math.max(0, Math.floor(bbox.y0));
    const w = Math.min(canvas.width - x0, Math.ceil(bbox.x1 - bbox.x0));
    const h = Math.min(canvas.height - y0, Math.ceil(bbox.y1 - bbox.y0));
    if(w < 12 || h < 4) return null;

    let imgData;
    try {
      imgData = canvas.getContext('2d').getImageData(x0, y0, w, h).data;
    } catch(e){
      return null; // can't read pixels (e.g. tainted canvas) — fall back to OCR text
    }

    // Local grayscale + mean threshold, scoped to just this word's box so it
    // adapts regardless of global preprocessing settings.
    const gray = new Float32Array(w * h);
    let sum = 0;
    for(let i = 0, p = 0; i < imgData.length; i += 4, p++){
      const g = 0.299*imgData[i] + 0.587*imgData[i+1] + 0.114*imgData[i+2];
      gray[p] = g;
      sum += g;
    }
    const mean = sum / gray.length;
    const ink = new Uint8Array(w * h);
    for(let p = 0; p < gray.length; p++) ink[p] = gray[p] < mean ? 1 : 0;

    // Column ink profile -> group into blobs (runs of consecutive inked columns)
    const colTop = new Int16Array(w).fill(-1);
    const colBottom = new Int16Array(w).fill(-1);
    for(let x = 0; x < w; x++){
      let top = -1, bottom = -1;
      for(let y = 0; y < h; y++){
        if(ink[y*w + x]){
          if(top === -1) top = y;
          bottom = y;
        }
      }
      colTop[x] = top; colBottom[x] = bottom;
    }

    const blobs = [];
    let x = 0;
    while(x < w){
      if(colTop[x] === -1){ x++; continue; }
      const start = x;
      while(x < w && colTop[x] !== -1) x++;
      const end = x - 1;
      let top = Infinity, bottom = -Infinity;
      for(let cx = start; cx <= end; cx++){
        if(colTop[cx] < top) top = colTop[cx];
        if(colBottom[cx] > bottom) bottom = colBottom[cx];
      }
      blobs.push({ x0: start, x1: end, width: end - start + 1, top, bottom, height: bottom - top + 1 });
    }

    // Need enough repeats to be confident this is a decorative run, not a
    // short real word.
    if(blobs.length < 4) return null;

    const widths = blobs.map(b => b.width).sort((a,b) => a-b);
    const heights = blobs.map(b => b.height).sort((a,b) => a-b);
    const medW = widths[Math.floor(widths.length/2)];
    const medH = heights[Math.floor(heights.length/2)];
    if(medW <= 0 || medH <= 0) return null;

    const shapesConsistent = blobs.every(b =>
      Math.abs(b.width - medW) <= Math.max(2, medW*0.4) &&
      Math.abs(b.height - medH) <= Math.max(2, medH*0.4)
    );
    if(!shapesConsistent) return null;

    const gaps = [];
    for(let i = 1; i < blobs.length; i++) gaps.push(blobs[i].x0 - blobs[i-1].x1);
    gaps.sort((a,b) => a-b);
    const medGap = gaps[Math.floor(gaps.length/2)];
    const gapsConsistent = gaps.every(g => Math.abs(g - medGap) <= Math.max(3, medGap*0.6 + 2));
    if(!gapsConsistent) return null;

    // Geometrically classify what the repeated blob actually is.
    const avgTop = blobs.reduce((s,b) => s+b.top, 0) / blobs.length;
    const avgBottom = blobs.reduce((s,b) => s+b.bottom, 0) / blobs.length;
    const aspect = medW / medH;

    let inkCount = 0, boxCount = 0;
    blobs.forEach(b => {
      for(let by = b.top; by <= b.bottom; by++){
        for(let bx = b.x0; bx <= b.x1; bx++){
          boxCount++;
          if(ink[by*w + bx]) inkCount++;
        }
      }
    });
    const density = boxCount ? inkCount / boxCount : 0;

    const touchesTop = avgTop < h*0.15;
    const touchesBottom = avgBottom > h*0.85;

    if(aspect > 2.2 && touchesBottom && medH <= h*0.3){
      return { char: '_', count: blobs.length };
    }
    if(aspect > 1.6 && !touchesTop && !touchesBottom && medH <= h*0.35){
      return { char: '-', count: blobs.length };
    }
    if(aspect >= 0.5 && aspect <= 1.8 && density > 0.2 && density < 0.8 && !touchesBottom){
      return { char: '*', count: blobs.length };
    }
    return null;
  }

  // ---------- Reconstruct column-aligned text from Tesseract's word boxes ----------
  function reconstructLayout(ocrData, canvas){
    const lines = [];
    (ocrData.blocks || []).forEach(block => {
      (block.paragraphs || []).forEach(para => {
        (para.lines || []).forEach(line => lines.push(line));
      });
    });
    // Fallback for flatter result shapes some Tesseract.js builds return
    const flatLines = lines.length ? lines : (ocrData.lines || []);
    if(!flatLines.length) return '';

    // Estimate a monospace character pixel width from word boxes
    const widths = [];
    flatLines.forEach(l => (l.words || []).forEach(w => {
      const len = (w.text || '').trim().length;
      if(len > 0 && w.bbox){
        widths.push((w.bbox.x1 - w.bbox.x0) / len);
      }
    }));
    widths.sort((a,b) => a-b);
    const charWidth = widths.length ? widths[Math.floor(widths.length/2)] : 10;

    // Estimate typical line-to-line pitch (for detecting blank lines).
    // This must be the spacing BETWEEN consecutive lines' y-centers, not a
    // single line's own glyph bbox height -- source with visual line-spacing
    // has a glyph height much smaller than the actual line pitch, which was
    // causing every real gap to look like "2 lines" and inserting a phantom
    // blank line between every pair of lines.
    const centers = flatLines
      .filter(l => l.bbox)
      .map(l => (l.bbox.y0 + l.bbox.y1) / 2)
      .sort((a,b) => a-b);
    const gaps = [];
    for(let i = 1; i < centers.length; i++) gaps.push(centers[i] - centers[i-1]);
    gaps.sort((a,b) => a-b);
    const lineHeight = gaps.length ? gaps[Math.floor(gaps.length/2)] : charWidth * 2;

    let outLines = [];
    let prevY = null;
    flatLines.forEach(line => {
      const words = (line.words || []).filter(w => (w.text || '').trim().length);
      if(!words.length) return;
      const yCenter = line.bbox ? (line.bbox.y0 + line.bbox.y1) / 2 : null;

      if(prevY !== null && yCenter !== null){
        const gap = yCenter - prevY;
        const blankCount = Math.max(0, Math.round(gap / lineHeight) - 1);
        for(let i = 0; i < blankCount; i++) outLines.push('');
      }

      words.sort((a,b) => a.bbox.x0 - b.bbox.x0);
      let chars = [];
      words.forEach(w => {
        const col = Math.max(0, Math.round(w.bbox.x0 / charWidth));
        while(chars.length < col) chars.push(' ');
        const forced = canvas ? detectRepeatedGlyph(canvas, w.bbox) : null;
        const text = forced ? forced.char.repeat(forced.count) : w.text;
        for(let i = 0; i < text.length; i++){
          chars[col + i] = text[i];
        }
      });
      outLines.push(chars.join('').replace(/\s+$/,''));
      if(yCenter !== null) prevY = yCenter;
    });

    return outLines.join('\n');
  }

  // ---------- Run OCR (queue / parallel worker pool) ----------
  // Runs every "queued" (or previously-errored) job in `jobs`. The
  // "Parallel workers" slider controls how many jobs run at once: at 1,
  // jobs run strictly one after another (a queue); above 1, that many
  // persistent Tesseract workers (see getPoolWorker) each pull the next
  // job off the queue as soon as they're free, so several images are
  // OCR'd concurrently.
  function nextRunnableJob(){
    return jobs.find(j => j.status === 'queued' || j.status === 'error') || null;
  }

  function waitForImage(job){
    if(job.img) return Promise.resolve();
    return new Promise(resolve => {
      const check = () => {
        if(job.img) resolve();
        else setTimeout(check, 30);
      };
      check();
    });
  }

  async function runJobOnSlot(job, slot){
    job.status = 'running';
    job.statusText = 'Preparing image…';
    job.progressPct = 0;
    job.error = null;
    activeJobBySlot[slot] = job;
    if(job.id === selectedJobId) reflectSelectedJobProgress(job);
    renderJobList();

    try {
      await waitForImage(job);
      const canvas = buildProcessedCanvas(job.img);

      const worker = await getPoolWorker(slot);
      await worker.setParameters({
        tessedit_pageseg_mode: '6', // uniform block of text — fits a single stacked column of code lines
        preserve_interword_spaces: '1',
        // Explicitly clear the whitelist when strict mode is off, since the
        // worker (and its parameters) now persist across runs and would
        // otherwise keep enforcing a whitelist set on a previous run.
        tessedit_char_whitelist: (strictChk.checked && currentLang().charset) ? currentLang().charset : ''
      });

      const result = await worker.recognize(canvas);
      const rebuilt = reconstructLayout(result.data, canvas);
      job.output = rebuilt || result.data.text || '';
      job.status = 'done';
    } catch(err){
      console.error(err);
      job.status = 'error';
      job.error = err && err.message ? err.message : String(err);
    } finally {
      activeJobBySlot[slot] = null;
      if(job.id === selectedJobId){
        output.value = job.output || '';
        if(job.output){
          const maxLineLen = Math.max(80, ...job.output.split('\n').map(l => l.length));
          buildRuler(maxLineLen);
        }
        reflectSelectedJobProgress(job);
      }
      renderJobList();
    }
  }

  // One "lane" per parallel slot: repeatedly grabs the next runnable job
  // and processes it until none are left. With concurrency 1 there's a
  // single lane, so this is just a queue.
  async function runLane(slot){
    let job;
    while((job = nextRunnableJob())){
      await runJobOnSlot(job, slot);
    }
  }

  runBtn.addEventListener('click', async () => {
    if(!jobs.length) return;
    const concurrency = Math.max(1, Math.min(6, parseInt(concurrencyInput.value, 10) || 1));

    runBtn.disabled = true;
    progress.classList.add('active');

    // Show progress for whichever job will run first, if nothing runnable
    // is currently selected.
    const firstRunnable = nextRunnableJob();
    if(firstRunnable && !(selectedJob() && (selectedJob().status === 'queued' || selectedJob().status === 'error'))){
      selectJob(firstRunnable.id);
    }
    if(jobs.length > 1){
      statusEl.textContent = concurrency > 1
        ? `Processing ${jobs.length} images with ${concurrency} parallel workers…`
        : `Processing ${jobs.length} images (queued, one at a time)…`;
    }

    const lanes = [];
    for(let slot = 0; slot < concurrency; slot++) lanes.push(runLane(slot));
    await Promise.all(lanes);

    progress.classList.remove('active');
    runBtn.disabled = false;
    renderJobList();

    const errorCount = jobs.filter(j => j.status === 'error').length;
    if(jobs.length > 1){
      statusEl.textContent = errorCount
        ? `Finished with ${errorCount} error${errorCount === 1 ? '' : 's'} — check the queue list above.`
        : `Finished ${jobs.length} images. Select any of them above to view its result.`;
    } else if(errorCount && selectedJob()){
      reflectSelectedJobProgress(selectedJob());
    }
  });

  // ---------- Output actions ----------
  document.getElementById('copyBtn').addEventListener('click', async () => {
    await navigator.clipboard.writeText(output.value);
    statusEl.textContent = 'Copied to clipboard.';
  });

  function download(filename, text){
    const blob = new Blob([text], {type:'text/plain'});
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }
  document.getElementById('downloadCbl').addEventListener('click', () => download(`extracted.${currentLang().extension}`, output.value));
  document.getElementById('downloadTxt').addEventListener('click', () => download('extracted.txt', output.value));

  // ---------- Handoff from Screenshot Stitcher ----------
  // If we were navigated here via the stitcher's "Send to OCR" button
  // (?from=stitch), pull the staged stitched sheet(s) back out of
  // IndexedDB and load them through the exact same path a manual file
  // drop uses, so nothing downstream needs to know where they came from.
  if (window.AppHandoff && new URLSearchParams(location.search).get('from') === 'stitch') {
    window.AppHandoff.receive().then(items => {
      if (!items || !items.length) return;
      const files = items.map(it => new File([it.blob], it.name, { type: 'image/png' }));
      loadFiles(files);
      statusEl.textContent = `Received ${files.length} stitched sheet${files.length > 1 ? 's' : ''} from Screenshot Stitcher.`;
      // Tidy the URL so a later manual reload doesn't look like a fresh handoff.
      history.replaceState(null, '', location.pathname);
    }).catch(err => console.error('Handoff receive failed', err));
  }
})();
